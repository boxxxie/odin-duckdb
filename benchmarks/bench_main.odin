package duckdb_benchmarks

// ============================================================================
// `odin-duckdb` Performance & Throughput Benchmark Suite (`benchmarks/bench_main.odin`)
// ============================================================================
// Benchmarks the 3-layer Odin DuckDB 2.0 stack:
// 1. Bulk Ingestion: V2 Prepared Statement Loop vs. V1 Appender vs. V2 ColumnDataCollection (`append_slice`)
// 2. Result Scan & Unmarshaling: Raw `V2_Vector_View` Zero-Copy Scan vs. Arrow C Data Interface (`Arrow_Array_Stream`) vs. `core:reflect` (`query_as`)
// 3. `V2_Bytes` String Storage: Inline (<= 12 B) vs. Arena Pointer (> 12 B) Read/Write Throughput
// 4. `duckdb:"...,json"` Struct Tag Round-Trip (`append_slice` + `query_as`)
// 5. Query Builder DSL (`query_to_sql`) & Zero-Execution Schema Codegen (`introspect_table_schema` + Odin/CUE codegen)
// ============================================================================

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:thread"
import "core:time"
import duckdb "../duckdb"

Bench_Result :: struct {
	name:       string,
	rows:       int,
	iterations: int,
	median_ns:  i64,
	min_ns:     i64,
	max_ns:     i64,
	bytes_row:  int,
}

Telemetry_Row :: struct {
	id:         i64    `duckdb:"id"`,
	device_id:  string `duckdb:"device_id"`,
	latency_ns: i64    `duckdb:"latency_ns"`,
	cpu_load:   f64    `duckdb:"cpu_load"`,
	healthy:    bool   `duckdb:"healthy"`,
}

Nullable_Telemetry_Row :: struct {
	id:         i64           `duckdb:"id"`,
	device_id:  Maybe(string) `duckdb:"device_id"`,
	latency_ns: Maybe(i64)    `duckdb:"latency_ns"`,
	cpu_load:   Maybe(f64)    `duckdb:"cpu_load"`,
	healthy:    Maybe(bool)   `duckdb:"healthy"`,
}

Sensor_Meta :: struct {
	firmware: string,
	tags:     []string,
	gain:     f64,
}

Json_Row :: struct {
	id:   i64         `duckdb:"id"`,
	meta: Sensor_Meta `duckdb:"meta,json"`,
}

run_timed :: proc(
	name: string,
	rows: int,
	bytes_per_row: int,
	iterations: int,
	fn: proc(),
) -> Bench_Result {
	// Warmup iteration
	fn()
	free_all(context.temp_allocator)

	samples := make([]i64, iterations)
	defer delete(samples)

	for i := 0; i < iterations; i += 1 {
		sw: time.Stopwatch
		time.stopwatch_start(&sw)
		fn()
		time.stopwatch_stop(&sw)
		samples[i] = time.duration_nanoseconds(time.stopwatch_duration(sw))
		free_all(context.temp_allocator)
	}

	slice.sort(samples)
	return Bench_Result{
		name       = name,
		rows       = rows,
		iterations = iterations,
		median_ns  = samples[iterations / 2],
		min_ns     = samples[0],
		max_ns     = samples[iterations - 1],
		bytes_row  = bytes_per_row,
	}
}

print_results_table :: proc(results: []Bench_Result) {
	fmt.println()
	fmt.println("| Benchmark | Items / Op | Median Time | Min Time | Throughput (ops/s) | Bandwidth (MB/s) | Latency (ns/item) |")
	fmt.println("| :--- | ---: | ---: | ---: | ---: | ---: | ---: |")
	for r in results {
		median_ms := f64(r.median_ns) / 1e6
		min_ms := f64(r.min_ns) / 1e6
		sec := f64(r.median_ns) / 1e9
		items_per_sec := f64(r.rows) / sec
		ns_per_item := f64(r.median_ns) / f64(max(r.rows, 1))
		mb_per_sec := (items_per_sec * f64(r.bytes_row)) / (1024.0 * 1024.0)

		bw_str := "-"
		if r.bytes_row > 0 {
			bw_str = fmt.tprintf("%.1f MB/s", mb_per_sec)
		}

		tp_str: string
		if items_per_sec >= 1e6 {
			tp_str = fmt.tprintf("%.2f M/s", items_per_sec / 1e6)
		} else {
			tp_str = fmt.tprintf("%.2f K/s", items_per_sec / 1e3)
		}

		fmt.printf(
			"| %s | %d | %.3f ms | %.3f ms | %s | %s | %.1f ns |\n",
			r.name,
			r.rows,
			median_ms,
			min_ms,
			tp_str,
			bw_str,
			ns_per_item,
		)
	}
	fmt.println()
}

// ----------------------------------------------------------------------------
// Shared Benchmark State
// ----------------------------------------------------------------------------

g_db: duckdb.V2_Database
g_v1_db: duckdb.Database
g_ingest_batch_100k: []Telemetry_Row
g_ingest_batch_2k: []Telemetry_Row
g_nullable_batch_100k: []Nullable_Telemetry_Row
g_json_batch_10k: []Json_Row
g_point_prep: duckdb.V2_Prepared_Statement_Handle
g_dsl_pq: duckdb.Prepared_Query(Telemetry_Row)
g_struct_appender: duckdb.Struct_Appender(Telemetry_Row)
g_sqllogic_script: string
g_table_udf_state: Bench_Table_Udf_State
g_collection_1m: duckdb.V2_Column_Data_Collection_Handle
g_collection_scan_chunk: duckdb.V2_Data_Chunk_Handle
g_copy_sink_state: Bench_Copy_Sink_State
g_tokenize_sql_text: string
g_describe_qname: duckdb.V2_Qname_Handle
g_pushdown_udf_state: Bench_Pushdown_Udf_State
g_vfs_fs: duckdb.V2_File_System_Handle
g_vfs_buf_64k: []u8
g_quack_tpl_vars: map[string]string
g_worker_chunks: [4]duckdb.V2_Data_Chunk_Handle
g_repl_collection_1k: duckdb.V2_Column_Data_Collection_Handle
g_repl_state: Bench_Replacement_State
g_log_sink_state: Bench_Log_Sink_State
g_ext_state: Bench_Extensibility_State
g_tx_counter: int

DDL_Complex_Event :: struct {
	event_id:    i64           `duckdb:"event_id,pk,not_null"`,
	select_col:  string        `duckdb:"select,not_null,default='ok'"`,
	order_col:   i32           `duckdb:"order,unique"`,
	latency_ns:  Maybe(i64)    `duckdb:"latency_ns"`,
	payload:     Sensor_Meta   `duckdb:"payload,json"`,
	internal_id: u64           `duckdb:"-"`,
}

Bench_Extensibility_State :: struct {
	pragma_calls: int,
	pragma_sum:   i64,
	option_calls: int,
	last_budget:  i64,
}

bench_pragma_bump_exec_cb :: proc "c" (
	info: duckdb.V2_Function_Bind_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	ud: rawptr
	_ = duckdb.duckdb_v2_function_bind_get_user_data(info, &ud, nil)
	st := cast(^Bench_Extensibility_State)ud
	pos_fixed, pos_var, named_fixed, named_var: duckdb.V2_Idx
	_ = duckdb.duckdb_v2_function_bind_get_arg_count(info, &pos_fixed, &pos_var, &named_fixed, &named_var, nil)
	total_args := pos_fixed + pos_var
	for i: duckdb.V2_Idx = 0; i < total_args; i += 1 {
		val: duckdb.V2_Value_Handle
		_ = duckdb.duckdb_v2_function_bind_get_arg_value(info, i, &val, nil)
		v: i64
		_ = duckdb.duckdb_v2_value_get_bigint(val, &v, nil)
		_ = duckdb.duckdb_v2_value_destroy(&val)
		st.pragma_sum += v
	}
	st.pragma_calls += 1
}

bench_custom_option_update_cb :: proc "c" (
	info: duckdb.V2_Custom_Option_Update_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	ud: rawptr
	_ = duckdb.duckdb_v2_custom_option_update_get_user_data(info, &ud, nil)
	st := cast(^Bench_Extensibility_State)ud
	st.option_calls += 1

	is_reset := false
	_ = duckdb.duckdb_v2_custom_option_update_is_reset(info, &is_reset, nil)
	if is_reset {
		st.last_budget = 10
		return
	}
	val: duckdb.V2_Value_Handle
	_ = duckdb.duckdb_v2_custom_option_update_get_value(info, &val, nil)
	defer duckdb.duckdb_v2_value_destroy(&val)
	v: i64
	_ = duckdb.duckdb_v2_value_get_bigint(val, &v, nil)
	st.last_budget = v
}

Bench_Worker_Scan_Ctx :: struct {
	shared: duckdb.V2_Column_Data_Collection_Shared_Scan_State_Handle,
	chunk:  duckdb.V2_Data_Chunk_Handle,
	rows:   duckdb.V2_Idx,
	sum:    i64,
}

Bench_Replacement_State :: struct {
	collection: duckdb.V2_Column_Data_Collection_Handle,
	calls:      int,
}

Bench_Log_Sink_State :: struct {
	entries: int,
}

bench_replacement_scan_cb :: proc "c" (
	info: duckdb.V2_Replacement_Scan_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	ud: rawptr
	_ = duckdb.duckdb_v2_replacement_scan_get_user_data(info, &ud, nil)
	st := cast(^Bench_Replacement_State)ud

	qname: duckdb.V2_Qname_Handle
	_ = duckdb.duckdb_v2_replacement_scan_get_name(info, &qname, nil)
	defer duckdb.duckdb_v2_qname_destroy(&qname)

	pcount: duckdb.V2_Idx
	_ = duckdb.duckdb_v2_qname_get_part_count(qname, &pcount, nil)
	if pcount != 1 {
		return
	}
	part0: duckdb.V2_Identifier
	_ = duckdb.duckdb_v2_qname_get_part(qname, 0, &part0, nil)
	if duckdb.v2_str_to_string(part0) != "virtual_metrics_batch" {
		return
	}
	st.calls += 1
	col_names := [2]duckdb.V2_Identifier{
		duckdb.v2_str_from_string("id"),
		duckdb.v2_str_from_string("latency_ns"),
	}
	_ = duckdb.duckdb_v2_replacement_scan_set_collection(info, st.collection, &col_names[0], 2, err)
}

bench_log_sink_write_cb :: proc "c" (
	info: duckdb.V2_Log_Sink_Write_Info_Handle,
	user_data: rawptr,
	timestamp: i64,
	level: duckdb.V2_Log_Level,
	scope: duckdb.V2_Log_Scope,
	log_type: ^duckdb.V2_Str,
	message: ^duckdb.V2_Str,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	st := cast(^Bench_Log_Sink_State)user_data
	st.entries += 1
}

Bench_Pushdown_Udf_State :: struct {
	limit:         i64,
	min_id:        i64,
	current:       i64,
	proj_count:    duckdb.V2_Idx,
	proj_cols:     [4]duckdb.V2_Idx,
}

Bench_Copy_Sink_State :: struct {
	flushed_rows: duckdb.V2_Idx,
	from_goal:    i64,
	from_cursor:  i64,
}

Bench_Table_Udf_State :: struct {
	limit:   i64,
	current: i64,
}

Bench_Agg_Sum_State :: struct {
	sum:   i64,
	has_v: bool,
}

bench_agg_sum_size_cb :: proc "c" (
	info: duckdb.V2_Aggregate_Function_Size_Info_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	_ = duckdb.duckdb_v2_aggregate_function_size_set_state_size(info, size_of(Bench_Agg_Sum_State), nil)
}

bench_agg_sum_init_cb :: proc "c" (
	info: duckdb.V2_Aggregate_Function_Init_Info_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	count: duckdb.V2_Idx
	states: [^]rawptr
	_ = duckdb.duckdb_v2_aggregate_function_init_get_state_count(info, &count, nil)
	_ = duckdb.duckdb_v2_aggregate_function_init_get_states(info, &states, nil)
	for i: duckdb.V2_Idx = 0; i < count; i += 1 {
		st := cast(^Bench_Agg_Sum_State)states[i]
		st.sum = 0
		st.has_v = false
	}
}

bench_agg_sum_update_cb :: proc "c" (
	info: duckdb.V2_Aggregate_Function_Update_Info_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	count: duckdb.V2_Idx
	_ = duckdb.duckdb_v2_aggregate_function_update_get_row_count(info, &count, nil)

	col0: duckdb.V2_Vector_Handle
	_ = duckdb.duckdb_v2_aggregate_function_update_get_arg(info, 0, &col0, nil)
	states: [^]rawptr
	_ = duckdb.duckdb_v2_aggregate_function_update_get_states(info, &states, nil)

	view: duckdb.V2_Vector_View
	_ = duckdb.v2_vector_get_readable_view(col0, &view, nil)
	data := cast([^]i64)view.data

	if view.validity == nil && view.sel == nil {
		for i: duckdb.V2_Idx = 0; i < count; i += 1 {
			st := cast(^Bench_Agg_Sum_State)states[i]
			st.sum += data[i]
			st.has_v = true
		}
	} else {
		for i: duckdb.V2_Idx = 0; i < count; i += 1 {
			if !duckdb.v2_row_is_valid(view, i) {
				continue
			}
			st := cast(^Bench_Agg_Sum_State)states[i]
			st.sum += data[duckdb.v2_sel_at(view.sel, i)]
			st.has_v = true
		}
	}
}

bench_agg_sum_combine_cb :: proc "c" (
	info: duckdb.V2_Aggregate_Function_Combine_Info_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	count: duckdb.V2_Idx
	source, target: [^]rawptr
	_ = duckdb.duckdb_v2_aggregate_function_combine_get_state_count(info, &count, nil)
	_ = duckdb.duckdb_v2_aggregate_function_combine_get_sources(info, &source, nil)
	_ = duckdb.duckdb_v2_aggregate_function_combine_get_targets(info, &target, nil)
	for i: duckdb.V2_Idx = 0; i < count; i += 1 {
		src := cast(^Bench_Agg_Sum_State)source[i]
		tgt := cast(^Bench_Agg_Sum_State)target[i]
		if src.has_v {
			tgt.sum += src.sum
			tgt.has_v = true
		}
	}
}

bench_agg_sum_finalize_cb :: proc "c" (
	info: duckdb.V2_Aggregate_Function_Finalize_Info_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	count, offset: duckdb.V2_Idx
	source: [^]rawptr
	result: duckdb.V2_Vector_Handle
	_ = duckdb.duckdb_v2_aggregate_function_finalize_get_state_count(info, &count, nil)
	_ = duckdb.duckdb_v2_aggregate_function_finalize_get_states(info, &source, nil)
	_ = duckdb.duckdb_v2_aggregate_function_finalize_get_result(info, &result, nil)
	_ = duckdb.duckdb_v2_aggregate_function_finalize_get_result_offset(info, &offset, nil)

	raw: rawptr
	_ = duckdb.duckdb_v2_vector_get_data_mutable(result, &raw, nil)
	out_data := cast([^]i64)raw
	for i: duckdb.V2_Idx = 0; i < count; i += 1 {
		st := cast(^Bench_Agg_Sum_State)source[i]
		row := offset + i
		if !st.has_v {
			_ = duckdb.duckdb_v2_vector_set_null(result, row, nil)
		} else {
			out_data[row] = st.sum
		}
	}
}

bench_scalar_fma_cb :: proc "c" (
	info: duckdb.V2_Scalar_Function_Exec_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	col_lat, col_cpu, output: duckdb.V2_Vector_Handle
	_ = duckdb.duckdb_v2_scalar_function_exec_get_arg(info, 0, &col_lat, nil)
	_ = duckdb.duckdb_v2_scalar_function_exec_get_arg(info, 1, &col_cpu, nil)
	_ = duckdb.duckdb_v2_scalar_function_exec_get_result(info, &output, nil)

	count: duckdb.V2_Idx
	_ = duckdb.duckdb_v2_scalar_function_exec_get_row_count(info, &count, nil)

	view_lat, view_cpu: duckdb.V2_Vector_View
	_ = duckdb.v2_vector_get_readable_view(col_lat, &view_lat, nil)
	_ = duckdb.v2_vector_get_readable_view(col_cpu, &view_cpu, nil)

	out_raw: rawptr
	_ = duckdb.duckdb_v2_vector_get_data_mutable(output, &out_raw, nil)
	out_data := cast([^]f64)out_raw
	lat_data := cast([^]i64)view_lat.data
	cpu_data := cast([^]f64)view_cpu.data

	if view_lat.sel == nil && view_cpu.sel == nil {
		for i: duckdb.V2_Idx = 0; i < count; i += 1 {
			out_data[i] = f64(lat_data[i]) * cpu_data[i] + 1.0
		}
	} else {
		for i: duckdb.V2_Idx = 0; i < count; i += 1 {
			out_data[i] = f64(lat_data[duckdb.v2_sel_at(view_lat.sel, i)]) * cpu_data[duckdb.v2_sel_at(view_cpu.sel, i)] + 1.0
		}
	}
}

bench_table_gen_bind_cb :: proc "c" (
	info: duckdb.V2_Function_Bind_Info_Handle,
	result: duckdb.V2_Table_Function_Bind_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	ud: rawptr
	_ = duckdb.duckdb_v2_function_bind_get_user_data(info, &ud, nil)
	st := cast(^Bench_Table_Udf_State)ud

	arg0: duckdb.V2_Value_Handle
	_ = duckdb.duckdb_v2_function_bind_get_arg_value(info, 0, &arg0, nil)
	_ = duckdb.duckdb_v2_value_get_bigint(arg0, &st.limit, nil)
	_ = duckdb.duckdb_v2_value_destroy(&arg0)

	factory: duckdb.V2_Factory_Handle
	_ = duckdb.duckdb_v2_context_get_factory(ctx, &factory, nil)
	bigint_type, double_type: duckdb.V2_Logical_Type_Handle
	_ = duckdb.duckdb_v2_factory_create_type_from_id(factory, .BIGINT, nil, nil, 0, &bigint_type, nil)
	_ = duckdb.duckdb_v2_factory_create_type_from_id(factory, .DOUBLE, nil, nil, 0, &double_type, nil)
	defer duckdb.duckdb_v2_logical_type_destroy(&bigint_type)
	defer duckdb.duckdb_v2_logical_type_destroy(&double_type)

	c0 := duckdb.v2_str_from_string("id")
	c1 := duckdb.v2_str_from_string("metric")
	_ = duckdb.duckdb_v2_table_function_bind_add_result_column(result, &c0, bigint_type, nil)
	_ = duckdb.duckdb_v2_table_function_bind_add_result_column(result, &c1, double_type, nil)
	_ = duckdb.duckdb_v2_table_function_bind_set_cardinality(result, duckdb.V2_Idx(st.limit), true, nil)

	bd := duckdb.V2_Opaque{ptr = st}
	_ = duckdb.duckdb_v2_function_bind_set_bind_data(info, &bd, nil)
}

bench_table_gen_init_global_cb :: proc "c" (
	info: duckdb.V2_Table_Function_Init_Global_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	bd: rawptr
	_ = duckdb.duckdb_v2_table_function_init_global_get_bind_data(info, &bd, nil)
	st := cast(^Bench_Table_Udf_State)bd
	st.current = 0

	gs := duckdb.V2_Opaque{ptr = st}
	_ = duckdb.duckdb_v2_table_function_init_global_set_global_state(info, &gs, nil)
	_ = duckdb.duckdb_v2_table_function_init_global_set_max_threads(info, 1, nil)
}

bench_table_gen_exec_cb :: proc "c" (
	info: duckdb.V2_Table_Function_Exec_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	gs: rawptr
	_ = duckdb.duckdb_v2_table_function_exec_get_global_state(info, &gs, nil)
	st := cast(^Bench_Table_Udf_State)gs

	output: duckdb.V2_Data_Chunk_Handle
	_ = duckdb.duckdb_v2_table_function_exec_get_output_chunk(info, &output, nil)
	col0, col1: duckdb.V2_Vector_Handle
	_ = duckdb.duckdb_v2_data_chunk_get_vector(output, 0, &col0, nil)
	_ = duckdb.duckdb_v2_data_chunk_get_vector(output, 1, &col1, nil)

	if st.current >= st.limit {
		_ = duckdb.duckdb_v2_vector_set_size(col0, 0, nil)
		_ = duckdb.duckdb_v2_vector_set_size(col1, 0, nil)
		return
	}

	cap: duckdb.V2_Idx
	_ = duckdb.duckdb_v2_data_chunk_get_capacity(output, &cap, nil)
	remaining := duckdb.V2_Idx(st.limit - st.current)
	emit := min(cap, remaining)

	raw0, raw1: rawptr
	_ = duckdb.duckdb_v2_vector_get_data_mutable(col0, &raw0, nil)
	_ = duckdb.duckdb_v2_vector_get_data_mutable(col1, &raw1, nil)
	d0 := cast([^]i64)raw0
	d1 := cast([^]f64)raw1

	base := st.current
	for i: duckdb.V2_Idx = 0; i < emit; i += 1 {
		v := base + i64(i)
		d0[i] = v
		d1[i] = f64(v) * 0.5
	}
	st.current += i64(emit)
	_ = duckdb.duckdb_v2_vector_set_size(col0, emit, nil)
	_ = duckdb.duckdb_v2_vector_set_size(col1, emit, nil)
}

bench_copy_to_bind_cb :: proc "c" (
	info: duckdb.V2_Copy_To_Bind_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	ud: rawptr
	_ = duckdb.duckdb_v2_copy_to_bind_get_user_data(info, &ud, nil)
	st := cast(^Bench_Copy_Sink_State)ud
	st.flushed_rows = 0
	bd := duckdb.V2_Opaque{ptr = st}
	_ = duckdb.duckdb_v2_copy_to_bind_set_bind_data(info, &bd, nil)
}

bench_copy_to_batch_size_cb :: proc "c" (
	info: duckdb.V2_Copy_To_Batch_Size_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	_ = duckdb.duckdb_v2_copy_to_batch_size_set_target(info, 65536, nil)
}

bench_copy_to_init_cb :: proc "c" (
	info: duckdb.V2_Copy_To_Init_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	bd: rawptr
	_ = duckdb.duckdb_v2_copy_to_init_get_bind_data(info, &bd, nil)
	id := duckdb.V2_Opaque{ptr = bd}
	_ = duckdb.duckdb_v2_copy_to_init_set_init_data(info, &id, nil)
}

bench_copy_to_batch_cb :: proc "c" (
	info: duckdb.V2_Copy_To_Batch_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	coll: duckdb.V2_Column_Data_Collection_Handle
	if duckdb.duckdb_v2_copy_to_batch_take_input(info, &coll, nil) != .NONE {
		return
	}
	rows: duckdb.V2_Idx
	_ = duckdb.duckdb_v2_column_data_collection_row_count(coll, &rows, nil)
	duckdb.duckdb_v2_column_data_collection_destroy(&coll)

	batch_op := duckdb.V2_Opaque{ptr = rawptr(uintptr(rows))}
	_ = duckdb.duckdb_v2_copy_to_batch_set_batch_data(info, &batch_op, nil)
}

bench_copy_to_flush_cb :: proc "c" (
	info: duckdb.V2_Copy_To_Flush_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	id, batch_ptr: rawptr
	_ = duckdb.duckdb_v2_copy_to_flush_get_init_data(info, &id, nil)
	_ = duckdb.duckdb_v2_copy_to_flush_get_batch_data(info, &batch_ptr, nil)
	if id != nil {
		(cast(^Bench_Copy_Sink_State)id).flushed_rows += duckdb.V2_Idx(uintptr(batch_ptr))
	}
}

bench_copy_to_finalize_cb :: proc "c" (
	info: duckdb.V2_Copy_To_Finalize_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
}

bench_copy_from_bind_cb :: proc "c" (
	info: duckdb.V2_Copy_From_Bind_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	ud: rawptr
	_ = duckdb.duckdb_v2_copy_from_bind_get_user_data(info, &ud, nil)
	st := cast(^Bench_Copy_Sink_State)ud
	st.from_cursor = 0
	_ = duckdb.duckdb_v2_copy_from_bind_set_cardinality(info, duckdb.V2_Idx(st.from_goal), true, nil)
	bd := duckdb.V2_Opaque{ptr = st}
	_ = duckdb.duckdb_v2_copy_from_bind_set_bind_data(info, &bd, nil)
}

bench_copy_from_init_global_cb :: proc "c" (
	info: duckdb.V2_Copy_From_Init_Global_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	bd: rawptr
	_ = duckdb.duckdb_v2_copy_from_init_global_get_bind_data(info, &bd, nil)
	gd := duckdb.V2_Opaque{ptr = bd}
	_ = duckdb.duckdb_v2_copy_from_init_global_set_global_state(info, &gd, nil)
	_ = duckdb.duckdb_v2_copy_from_init_global_set_max_threads(info, 1, nil)
}

bench_copy_from_exec_cb :: proc "c" (
	info: duckdb.V2_Copy_From_Exec_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	gd: rawptr
	_ = duckdb.duckdb_v2_copy_from_exec_get_global_state(info, &gd, nil)
	st := cast(^Bench_Copy_Sink_State)gd

	chunk: duckdb.V2_Data_Chunk_Handle
	_ = duckdb.duckdb_v2_copy_from_exec_get_output_chunk(info, &chunk, nil)
	v0, v1: duckdb.V2_Vector_Handle
	_ = duckdb.duckdb_v2_data_chunk_get_vector(chunk, 0, &v0, nil)
	_ = duckdb.duckdb_v2_data_chunk_get_vector(chunk, 1, &v1, nil)

	if st.from_cursor >= st.from_goal {
		_ = duckdb.duckdb_v2_vector_set_size(v0, 0, nil)
		_ = duckdb.duckdb_v2_vector_set_size(v1, 0, nil)
		return
	}

	cap: duckdb.V2_Idx
	_ = duckdb.duckdb_v2_data_chunk_get_capacity(chunk, &cap, nil)
	emit := min(cap, duckdb.V2_Idx(st.from_goal - st.from_cursor))

	r0, r1: rawptr
	_ = duckdb.duckdb_v2_vector_get_data_mutable(v0, &r0, nil)
	_ = duckdb.duckdb_v2_vector_get_data_mutable(v1, &r1, nil)
	d0 := cast([^]i64)r0
	d1 := cast([^]i64)r1

	base := st.from_cursor
	for i: duckdb.V2_Idx = 0; i < emit; i += 1 {
		v := base + i64(i) + 1
		d0[i] = v
		d1[i] = v * 15
	}
	st.from_cursor += i64(emit)
	_ = duckdb.duckdb_v2_vector_set_size(v0, emit, nil)
	_ = duckdb.duckdb_v2_vector_set_size(v1, emit, nil)
}

bench_arrow_converter_udf_cb :: proc "c" (
	info: duckdb.V2_Scalar_Function_Exec_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	factory: duckdb.V2_Factory_Handle
	_ = duckdb.duckdb_v2_context_get_factory(ctx, &factory, nil)

	bigint_t: duckdb.V2_Logical_Type_Handle
	_ = duckdb.duckdb_v2_factory_create_type_from_id(factory, .BIGINT, nil, nil, 0, &bigint_t, nil)
	defer duckdb.duckdb_v2_logical_type_destroy(&bigint_t)

	types := [2]duckdb.V2_Logical_Type_Handle{bigint_t, bigint_t}
	names := [2]duckdb.V2_Str{duckdb.v2_str_from_string("id"), duckdb.v2_str_from_string("latency_ns")}

	exporter: duckdb.V2_Arrow_Exporter_Handle
	_ = duckdb.duckdb_v2_arrow_exporter_create(ctx, raw_data(types[:]), raw_data(names[:]), 2, 0, &exporter, nil)
	defer duckdb.duckdb_v2_arrow_exporter_destroy(&exporter)

	arrow_schema: duckdb.Arrow_Schema
	_ = duckdb.duckdb_v2_arrow_exporter_get_schema(exporter, &arrow_schema, nil)
	defer duckdb.arrow_schema_release(&arrow_schema)

	importer: duckdb.V2_Arrow_Importer_Handle
	_ = duckdb.duckdb_v2_arrow_importer_create(ctx, &arrow_schema, 0, &importer, nil)
	defer duckdb.duckdb_v2_arrow_importer_destroy(&importer)

	total_rows: duckdb.V2_Idx = 0
	for batch := 0; batch < 100; batch += 1 {
		chunk: duckdb.V2_Data_Chunk_Handle
		_ = duckdb.duckdb_v2_data_chunk_create(factory, raw_data(types[:]), 2, &chunk, nil)
		v0, v1: duckdb.V2_Vector_Handle
		_ = duckdb.duckdb_v2_data_chunk_get_vector(chunk, 0, &v0, nil)
		_ = duckdb.duckdb_v2_data_chunk_get_vector(chunk, 1, &v1, nil)
		_ = duckdb.duckdb_v2_vector_set_size(v0, 2000, nil)
		_ = duckdb.duckdb_v2_vector_set_size(v1, 2000, nil)

		r0, r1: rawptr
		_ = duckdb.duckdb_v2_vector_get_data_mutable(v0, &r0, nil)
		_ = duckdb.duckdb_v2_vector_get_data_mutable(v1, &r1, nil)
		d0 := cast([^]i64)r0
		d1 := cast([^]i64)r1
		for i := 0; i < 2000; i += 1 {
			d0[i] = i64(i + 1)
			d1[i] = i64((i + 1) * 15)
		}

		_ = duckdb.duckdb_v2_arrow_exporter_append(exporter, &chunk, true, true, nil)
		for {
			arr: duckdb.Arrow_Array
			if duckdb.duckdb_v2_arrow_exporter_next_array(exporter, &arr, nil) != .NONE || arr.release == nil {
				break
			}
			_ = duckdb.duckdb_v2_arrow_importer_append(importer, &arr, true, true, nil)
			imported: duckdb.V2_Data_Chunk_Handle
			for duckdb.duckdb_v2_arrow_importer_next_chunk(importer, &imported, nil) == .NONE && imported != nil {
				iv0: duckdb.V2_Vector_Handle
				_ = duckdb.duckdb_v2_data_chunk_get_vector(imported, 0, &iv0, nil)
				view: duckdb.V2_Vector_View
				_ = duckdb.duckdb_v2_vector_get_view(iv0, &view, nil)
				total_rows += view.count
				duckdb.duckdb_v2_data_chunk_destroy(&imported)
			}
		}
	}

	out_vec: duckdb.V2_Vector_Handle
	_ = duckdb.duckdb_v2_scalar_function_exec_get_result(info, &out_vec, nil)
	raw_out: rawptr
	_ = duckdb.duckdb_v2_vector_get_data_mutable(out_vec, &raw_out, nil)
	(cast([^]i64)raw_out)[0] = i64(total_rows)
}

bench_cast_ns_to_ms_cb :: proc "c" (
	info: duckdb.V2_Cast_Function_Exec_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	in_vec, out_vec: duckdb.V2_Vector_Handle
	count: duckdb.V2_Idx
	_ = duckdb.duckdb_v2_cast_function_exec_get_input(info, &in_vec, nil)
	_ = duckdb.duckdb_v2_cast_function_exec_get_output(info, &out_vec, nil)
	_ = duckdb.duckdb_v2_cast_function_exec_get_row_count(info, &count, nil)

	view: duckdb.V2_Vector_View
	_ = duckdb.v2_vector_get_readable_view(in_vec, &view, nil)
	raw_out: rawptr
	_ = duckdb.duckdb_v2_vector_get_data_mutable(out_vec, &raw_out, nil)
	out_data := cast([^]f64)raw_out
	in_data := cast([^]i64)view.data

	if view.sel == nil {
		for i: duckdb.V2_Idx = 0; i < count; i += 1 {
			out_data[i] = f64(in_data[i]) * 1e-6
		}
	} else {
		for i: duckdb.V2_Idx = 0; i < count; i += 1 {
			out_data[i] = f64(in_data[duckdb.v2_sel_at(view.sel, i)]) * 1e-6
		}
	}
}

bench_pushdown_bind_cb :: proc "c" (
	info: duckdb.V2_Function_Bind_Info_Handle,
	result: duckdb.V2_Table_Function_Bind_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	ud: rawptr
	_ = duckdb.duckdb_v2_function_bind_get_user_data(info, &ud, nil)
	st := cast(^Bench_Pushdown_Udf_State)ud

	arg0: duckdb.V2_Value_Handle
	_ = duckdb.duckdb_v2_function_bind_get_arg_value(info, 0, &arg0, nil)
	_ = duckdb.duckdb_v2_value_get_bigint(arg0, &st.limit, nil)
	_ = duckdb.duckdb_v2_value_destroy(&arg0)
	st.min_id = 0

	factory: duckdb.V2_Factory_Handle
	_ = duckdb.duckdb_v2_context_get_factory(ctx, &factory, nil)
	bigint_t, double_t, varchar_t: duckdb.V2_Logical_Type_Handle
	_ = duckdb.duckdb_v2_factory_create_type_from_id(factory, .BIGINT, nil, nil, 0, &bigint_t, nil)
	_ = duckdb.duckdb_v2_factory_create_type_from_id(factory, .DOUBLE, nil, nil, 0, &double_t, nil)
	_ = duckdb.duckdb_v2_factory_create_type_from_id(factory, .VARCHAR, nil, nil, 0, &varchar_t, nil)
	defer duckdb.duckdb_v2_logical_type_destroy(&bigint_t)
	defer duckdb.duckdb_v2_logical_type_destroy(&double_t)
	defer duckdb.duckdb_v2_logical_type_destroy(&varchar_t)

	c0 := duckdb.v2_str_from_string("id")
	c1 := duckdb.v2_str_from_string("unused_tag")
	c2 := duckdb.v2_str_from_string("unused_payload")
	c3 := duckdb.v2_str_from_string("metric")
	_ = duckdb.duckdb_v2_table_function_bind_add_result_column(result, &c0, bigint_t, nil)
	_ = duckdb.duckdb_v2_table_function_bind_add_result_column(result, &c1, varchar_t, nil)
	_ = duckdb.duckdb_v2_table_function_bind_add_result_column(result, &c2, varchar_t, nil)
	_ = duckdb.duckdb_v2_table_function_bind_add_result_column(result, &c3, double_t, nil)

	bd := duckdb.V2_Opaque{ptr = st}
	_ = duckdb.duckdb_v2_function_bind_set_bind_data(info, &bd, nil)
}

bench_pushdown_filter_cb :: proc "c" (
	info: duckdb.V2_Table_Function_Filter_Pushdown_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	bd: rawptr
	if duckdb.duckdb_v2_table_function_filter_pushdown_get_bind_data(info, &bd, nil) != .NONE || bd == nil {
		return
	}
	st := cast(^Bench_Pushdown_Udf_State)bd

	fcount: duckdb.V2_Idx
	if duckdb.duckdb_v2_table_function_filter_pushdown_get_filter_count(info, &fcount, nil) != .NONE || fcount == 0 {
		return
	}
	expr: duckdb.V2_Expression_Handle
	if duckdb.duckdb_v2_table_function_filter_pushdown_get_filter(info, 0, &expr, nil) != .NONE {
		return
	}
	etype: duckdb.V2_Expression_Type
	_ = duckdb.duckdb_v2_expression_get_type(expr, &etype, nil)
	if etype == .COMPARE_GREATERTHANOREQUALTO || etype == .COMPARE_GREATERTHAN {
		ccount: duckdb.V2_Idx
		_ = duckdb.duckdb_v2_expression_get_child_count(expr, &ccount, nil)
		if ccount == 2 {
			right: duckdb.V2_Expression_Handle
			_ = duckdb.duckdb_v2_expression_get_child(expr, 1, &right, nil)
			cval: duckdb.V2_Value_Handle
			if duckdb.duckdb_v2_expression_constant_get_value(right, &cval, nil) == .NONE {
				v: i64
				_ = duckdb.duckdb_v2_value_get_bigint(cval, &v, nil)
				duckdb.duckdb_v2_value_destroy(&cval)
				st.min_id = v if etype == .COMPARE_GREATERTHANOREQUALTO else v + 1
				_ = duckdb.duckdb_v2_table_function_filter_pushdown_accept(info, 0, nil)
			}
		}
	}
}

bench_pushdown_init_global_cb :: proc "c" (
	info: duckdb.V2_Table_Function_Init_Global_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	bd: rawptr
	_ = duckdb.duckdb_v2_table_function_init_global_get_bind_data(info, &bd, nil)
	st := cast(^Bench_Pushdown_Udf_State)bd
	st.current = st.min_id

	_ = duckdb.duckdb_v2_table_function_init_global_get_column_count(info, &st.proj_count, nil)
	for i: duckdb.V2_Idx = 0; i < min(st.proj_count, 4); i += 1 {
		_ = duckdb.duckdb_v2_table_function_init_global_get_column_index(info, i, &st.proj_cols[i], nil)
	}

	gs := duckdb.V2_Opaque{ptr = st}
	_ = duckdb.duckdb_v2_table_function_init_global_set_global_state(info, &gs, nil)
	_ = duckdb.duckdb_v2_table_function_init_global_set_max_threads(info, 1, nil)
}

bench_pushdown_exec_cb :: proc "c" (
	info: duckdb.V2_Table_Function_Exec_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	gs: rawptr
	_ = duckdb.duckdb_v2_table_function_exec_get_global_state(info, &gs, nil)
	st := cast(^Bench_Pushdown_Udf_State)gs

	output: duckdb.V2_Data_Chunk_Handle
	_ = duckdb.duckdb_v2_table_function_exec_get_output_chunk(info, &output, nil)

	if st.current >= st.limit {
		v0: duckdb.V2_Vector_Handle
		_ = duckdb.duckdb_v2_data_chunk_get_vector(output, 0, &v0, nil)
		_ = duckdb.duckdb_v2_vector_set_size(v0, 0, nil)
		return
	}

	cap: duckdb.V2_Idx
	_ = duckdb.duckdb_v2_data_chunk_get_capacity(output, &cap, nil)
	emit := min(cap, duckdb.V2_Idx(st.limit - st.current))
	base := st.current

	for p: duckdb.V2_Idx = 0; p < st.proj_count; p += 1 {
		vec: duckdb.V2_Vector_Handle
		_ = duckdb.duckdb_v2_data_chunk_get_vector(output, p, &vec, nil)
		col_idx := st.proj_cols[p]
		if col_idx == 0 {
			raw: rawptr
			_ = duckdb.duckdb_v2_vector_get_data_mutable(vec, &raw, nil)
			dst := cast([^]i64)raw
			for i: duckdb.V2_Idx = 0; i < emit; i += 1 {
				dst[i] = base + i64(i)
			}
		} else if col_idx == 3 {
			raw: rawptr
			_ = duckdb.duckdb_v2_vector_get_data_mutable(vec, &raw, nil)
			dst := cast([^]f64)raw
			for i: duckdb.V2_Idx = 0; i < emit; i += 1 {
				dst[i] = f64(base + i64(i)) * 0.5
			}
		}
		_ = duckdb.duckdb_v2_vector_set_size(vec, emit, nil)
	}
	st.current += i64(emit)
}

// 1a. V2 Prepared Statement row-by-row ingestion (2,000 rows inside 1 transaction)
bench_ingest_v2_prepared_2k :: proc() {
	_ = duckdb.v2_exec_drain(g_db.conn, "DELETE FROM bench_ingest_v2")
	_ = duckdb.v2_exec_drain(g_db.conn, "BEGIN TRANSACTION")

	prep: duckdb.V2_Prepared_Statement_Handle
	_ = duckdb.v2_prepare(g_db.conn, "INSERT INTO bench_ingest_v2 VALUES ($1, $2, $3, $4, $5)", false, &prep)
	defer duckdb.duckdb_v2_prepared_statement_destroy(&prep)

	vals: [5]duckdb.V2_Value_Handle
	for r in g_ingest_batch_2k {
		_ = duckdb.duckdb_v2_value_create_bigint(g_db.factory, r.id, &vals[0], nil)
		s := duckdb.v2_str_from_string(r.device_id)
		_ = duckdb.duckdb_v2_value_create_varchar(g_db.factory, &s, &vals[1], nil)
		_ = duckdb.duckdb_v2_value_create_bigint(g_db.factory, r.latency_ns, &vals[2], nil)
		_ = duckdb.duckdb_v2_value_create_double(g_db.factory, r.cpu_load, &vals[3], nil)
		_ = duckdb.duckdb_v2_value_create_bool(g_db.factory, r.healthy, &vals[4], nil)

		res: duckdb.V2_Result_Handle
		_ = duckdb.duckdb_v2_prepared_statement_execute(prep, nil, raw_data(vals[:]), 5, &res, nil)
		changed: duckdb.V2_Idx
		_ = duckdb.duckdb_v2_result_drain(res, &changed, nil)
		_ = duckdb.duckdb_v2_result_destroy(&res)

		for &v in vals {
			_ = duckdb.duckdb_v2_value_destroy(&v)
		}
	}
	_ = duckdb.v2_exec_drain(g_db.conn, "COMMIT")
}

// 1b. Legacy V1 Appender API (100,000 rows)
bench_ingest_v1_appender_100k :: proc() {
	duckdb.exec(&g_v1_db, "DELETE FROM bench_ingest_v1")
	app: duckdb.duckdb_appender
	_ = duckdb.duckdb_appender_create(g_v1_db.conn, nil, "bench_ingest_v1", &app)
	defer duckdb.duckdb_appender_destroy(&app)

	for r in g_ingest_batch_100k {
		_ = duckdb.duckdb_append_int64(app, r.id)
		_ = duckdb.duckdb_append_varchar(app, "edge-node-01")
		_ = duckdb.duckdb_append_int64(app, r.latency_ns)
		_ = duckdb.duckdb_append_double(app, r.cpu_load)
		_ = duckdb.duckdb_append_bool(app, r.healthy)
		_ = duckdb.duckdb_appender_end_row(app)
	}
	_ = duckdb.duckdb_appender_flush(app)
	_ = duckdb.duckdb_appender_close(app)
}

// 1c. V2 ColumnDataCollection `append_slice` (100,000 rows)
bench_ingest_v2_append_slice_100k :: proc() {
	_ = duckdb.v2_exec_drain(g_db.conn, "DELETE FROM bench_ingest_v2")
	rc := duckdb.append_slice(g_db.conn, "bench_ingest_v2", g_ingest_batch_100k)
	assert(rc == .NONE)
}

// 2a. Zero-copy V2_Vector_View scan over 1,000,000 rows (4 numeric/boolean columns = 25 bytes/row)
bench_scan_v2_vector_view_1m :: proc() {
	res: duckdb.V2_Result_Handle
	rc := duckdb.v2_query(g_db.conn, "SELECT id, latency_ns, cpu_load, healthy FROM bench_scan_1m", &res)
	assert(rc == .NONE)
	defer duckdb.duckdb_v2_result_destroy(&res)

	total_rows: duckdb.V2_Idx = 0
	acc: i64 = 0
	for {
		chunk: duckdb.V2_Data_Chunk_Handle
		if duckdb.duckdb_v2_result_fetch_chunk(res, &chunk, nil) != .NONE || chunk == nil {
			break
		}
		defer duckdb.duckdb_v2_data_chunk_destroy(&chunk)

		sz: duckdb.V2_Idx
		_ = duckdb.duckdb_v2_data_chunk_get_size(chunk, &sz, nil)

		v_id, v_lat: duckdb.V2_Vector_Handle
		_ = duckdb.duckdb_v2_data_chunk_get_vector(chunk, 0, &v_id, nil)
		_ = duckdb.duckdb_v2_data_chunk_get_vector(chunk, 1, &v_lat, nil)

		view_id, view_lat: duckdb.V2_Vector_View
		_ = duckdb.v2_vector_get_readable_view(v_id, &view_id, nil)
		_ = duckdb.v2_vector_get_readable_view(v_lat, &view_lat, nil)

		ids := cast([^]i64)view_id.data
		lats := cast([^]i64)view_lat.data
		for i: duckdb.V2_Idx = 0; i < sz; i += 1 {
			acc += ids[duckdb.v2_sel_at(view_id.sel, i)] + lats[duckdb.v2_sel_at(view_lat.sel, i)]
		}
		total_rows += sz
	}
	assert(total_rows == 1_000_000 && acc > 0)
}

// 2b. Zero-copy Arrow C Data Interface (`Arrow_Array_Stream`) scan over 1,000,000 rows
bench_scan_v2_arrow_stream_1m :: proc() {
	stmt: duckdb.V2_Sql_Statement_Handle
	_ = duckdb.v2_parse_single_stmt(g_db.conn, "SELECT id, latency_ns, cpu_load, healthy FROM bench_scan_1m", &stmt)
	defer duckdb.duckdb_v2_sql_statement_destroy(&stmt)

	arrow_res: duckdb.V2_Arrow_Result_Handle
	_ = duckdb.duckdb_v2_statement_execute_arrow(g_db.conn, stmt, nil, nil, 0, 2048, &arrow_res, nil)

	stream: duckdb.Arrow_Array_Stream
	_ = duckdb.duckdb_v2_arrow_result_to_arrow_c_stream(&arrow_res, &stream, nil)
	defer duckdb.arrow_stream_release(&stream)

	total_rows: i64 = 0
	for {
		batch: duckdb.Arrow_Array
		if stream.get_next(&stream, &batch) != 0 || batch.release == nil {
			break
		}
		total_rows += batch.length
		duckdb.arrow_array_release(&batch)
	}
	assert(total_rows == 1_000_000)
}

// 2c. Typed `core:reflect` struct unmarshaling (`duckdb.query_as`) over 100,000 rows
bench_query_as_struct_100k :: proc() {
	rows, rc := duckdb.query_as(
		g_db.conn,
		Telemetry_Row,
		"SELECT id, device_id, latency_ns, cpu_load, healthy FROM bench_scan_100k",
		context.temp_allocator,
	)
	assert(rc == .NONE && len(rows) == 100_000)
}

// 2d. Nullable `Maybe(T)` struct round-trip (`append_slice` + `query_as`) with 25% SQL NULLs (100,000 rows)
bench_nullable_maybe_ingest_100k :: proc() {
	_ = duckdb.v2_exec_drain(g_db.conn, "DELETE FROM bench_nullable_v2")
	rc := duckdb.append_slice(g_db.conn, "bench_nullable_v2", g_nullable_batch_100k)
	assert(rc == .NONE)
}

bench_nullable_maybe_query_as_100k :: proc() {
	rows, rc := duckdb.query_as(
		g_db.conn,
		Nullable_Telemetry_Row,
		"SELECT id, device_id, latency_ns, cpu_load, healthy FROM bench_nullable_seed_100k",
		context.temp_allocator,
	)
	assert(rc == .NONE && len(rows) == 100_000)
}

// 2e. Selection Vector (`V2_Selection_Vector_Handle`) filtered scan over 1,000,000 source rows (~500K matching rows)
bench_scan_selection_vector_1m :: proc() {
	res: duckdb.V2_Result_Handle
	rc := duckdb.v2_query(
		g_db.conn,
		"SELECT id, latency_ns, cpu_load, healthy FROM bench_scan_1m WHERE healthy AND cpu_load > 10.0",
		&res,
	)
	assert(rc == .NONE)
	defer duckdb.duckdb_v2_result_destroy(&res)

	total_rows: duckdb.V2_Idx = 0
	acc: i64 = 0
	for {
		chunk: duckdb.V2_Data_Chunk_Handle
		if duckdb.duckdb_v2_result_fetch_chunk(res, &chunk, nil) != .NONE || chunk == nil {
			break
		}
		defer duckdb.duckdb_v2_data_chunk_destroy(&chunk)

		sz: duckdb.V2_Idx
		_ = duckdb.duckdb_v2_data_chunk_get_size(chunk, &sz, nil)

		v_id, v_lat: duckdb.V2_Vector_Handle
		_ = duckdb.duckdb_v2_data_chunk_get_vector(chunk, 0, &v_id, nil)
		_ = duckdb.duckdb_v2_data_chunk_get_vector(chunk, 1, &v_lat, nil)

		view_id, view_lat: duckdb.V2_Vector_View
		_ = duckdb.v2_vector_get_readable_view(v_id, &view_id, nil)
		_ = duckdb.v2_vector_get_readable_view(v_lat, &view_lat, nil)

		ids := cast([^]i64)view_id.data
		lats := cast([^]i64)view_lat.data
		for i: duckdb.V2_Idx = 0; i < sz; i += 1 {
			acc += ids[duckdb.v2_sel_at(view_id.sel, i)] + lats[duckdb.v2_sel_at(view_lat.sel, i)]
		}
		total_rows += sz
	}
	assert(total_rows > 0 && acc > 0)
}

// 2f. Direct In-Memory `ColumnDataCollection` Shared + Worker Scan (1,000,000 rows, 16 B/row)
bench_scan_collection_direct_1m :: proc() {
	shared: duckdb.V2_Column_Data_Collection_Shared_Scan_State_Handle
	_ = duckdb.duckdb_v2_column_data_collection_shared_scan_state_create(g_collection_1m, &shared, nil)
	defer duckdb.duckdb_v2_column_data_collection_shared_scan_state_destroy(&shared)

	worker: duckdb.V2_Column_Data_Collection_Worker_Scan_State_Handle
	_ = duckdb.duckdb_v2_column_data_collection_worker_scan_state_create(g_collection_1m, &worker, nil)
	defer duckdb.duckdb_v2_column_data_collection_worker_scan_state_destroy(&worker)

	total_rows: duckdb.V2_Idx = 0
	acc: i64 = 0
	for {
		did_produce := false
		_ = duckdb.duckdb_v2_column_data_collection_scan(g_collection_1m, shared, worker, g_collection_scan_chunk, &did_produce, nil)
		if !did_produce {
			break
		}
		sz: duckdb.V2_Idx
		_ = duckdb.duckdb_v2_data_chunk_get_size(g_collection_scan_chunk, &sz, nil)

		v_id, v_lat: duckdb.V2_Vector_Handle
		_ = duckdb.duckdb_v2_data_chunk_get_vector(g_collection_scan_chunk, 0, &v_id, nil)
		_ = duckdb.duckdb_v2_data_chunk_get_vector(g_collection_scan_chunk, 1, &v_lat, nil)

		view_id, view_lat: duckdb.V2_Vector_View
		_ = duckdb.duckdb_v2_vector_get_view(v_id, &view_id, nil)
		_ = duckdb.duckdb_v2_vector_get_view(v_lat, &view_lat, nil)

		ids := cast([^]i64)view_id.data
		lats := cast([^]i64)view_lat.data
		for i: duckdb.V2_Idx = 0; i < sz; i += 1 {
			acc += ids[i] + lats[i]
		}
		total_rows += sz
	}
	assert(total_rows == 1_000_000 && acc > 0)
}

// 3a. `V2_Bytes` Inline (<= 12 B) vs. Arena Pointer (> 12 B) Vector Write (200,000 strings)
bench_v2_bytes_inline_write_200k :: proc() {
	str_type: duckdb.V2_Logical_Type_Handle
	_ = duckdb.duckdb_v2_factory_create_type_from_id(g_db.factory, .VARCHAR, nil, nil, 0, &str_type, nil)
	defer duckdb.duckdb_v2_logical_type_destroy(&str_type)

	types := [1]duckdb.V2_Logical_Type_Handle{str_type}
	chunk: duckdb.V2_Data_Chunk_Handle
	_ = duckdb.duckdb_v2_data_chunk_create(g_db.factory, raw_data(types[:]), 1, &chunk, nil)
	defer duckdb.duckdb_v2_data_chunk_destroy(&chunk)

	vec: duckdb.V2_Vector_Handle
	_ = duckdb.duckdb_v2_data_chunk_get_vector(chunk, 0, &vec, nil)

	for batch := 0; batch < 100; batch += 1 {
		for i: duckdb.V2_Idx = 0; i < 2000; i += 1 {
			_ = duckdb.v2_vector_assign_string(vec, i, "inline-12byt")
		}
	}
}

bench_v2_bytes_arena_write_200k :: proc() {
	str_type: duckdb.V2_Logical_Type_Handle
	_ = duckdb.duckdb_v2_factory_create_type_from_id(g_db.factory, .VARCHAR, nil, nil, 0, &str_type, nil)
	defer duckdb.duckdb_v2_logical_type_destroy(&str_type)

	types := [1]duckdb.V2_Logical_Type_Handle{str_type}
	chunk: duckdb.V2_Data_Chunk_Handle
	_ = duckdb.duckdb_v2_data_chunk_create(g_db.factory, raw_data(types[:]), 1, &chunk, nil)
	defer duckdb.duckdb_v2_data_chunk_destroy(&chunk)

	vec: duckdb.V2_Vector_Handle
	_ = duckdb.duckdb_v2_data_chunk_get_vector(chunk, 0, &vec, nil)

	for batch := 0; batch < 100; batch += 1 {
		_ = duckdb.duckdb_v2_data_chunk_clear(chunk, nil)
		for i: duckdb.V2_Idx = 0; i < 2000; i += 1 {
			_ = duckdb.v2_vector_assign_string(vec, i, "arena-allocated-payload-32-bytes")
		}
	}
}

// 3c. Vectorized Type Casting Engine (`duckdb_v2_vector_cast` BIGINT -> DOUBLE, 200,000 items)
bench_vector_cast_bigint_to_double_200k :: proc() {
	bigint_t, double_t: duckdb.V2_Logical_Type_Handle
	_ = duckdb.duckdb_v2_factory_create_type_from_id(g_db.factory, .BIGINT, nil, nil, 0, &bigint_t, nil)
	_ = duckdb.duckdb_v2_factory_create_type_from_id(g_db.factory, .DOUBLE, nil, nil, 0, &double_t, nil)
	defer duckdb.duckdb_v2_logical_type_destroy(&bigint_t)
	defer duckdb.duckdb_v2_logical_type_destroy(&double_t)

	types := [2]duckdb.V2_Logical_Type_Handle{bigint_t, double_t}
	chunk: duckdb.V2_Data_Chunk_Handle
	_ = duckdb.duckdb_v2_data_chunk_create(g_db.factory, raw_data(types[:]), 2, &chunk, nil)
	defer duckdb.duckdb_v2_data_chunk_destroy(&chunk)

	src_vec, dst_vec: duckdb.V2_Vector_Handle
	_ = duckdb.duckdb_v2_data_chunk_get_vector(chunk, 0, &src_vec, nil)
	_ = duckdb.duckdb_v2_data_chunk_get_vector(chunk, 1, &dst_vec, nil)
	_ = duckdb.duckdb_v2_vector_set_size(src_vec, 2000, nil)

	raw: rawptr
	_ = duckdb.duckdb_v2_vector_get_data_mutable(src_vec, &raw, nil)
	src_data := cast([^]i64)raw
	for i: duckdb.V2_Idx = 0; i < 2000; i += 1 {
		src_data[i] = i64(i * 42)
	}

	converted := false
	for batch := 0; batch < 100; batch += 1 {
		_ = duckdb.duckdb_v2_vector_cast(g_db.factory, src_vec, dst_vec, .NORMAL, &converted, nil, nil)
	}
	assert(converted)
}

// 3d. Zero-Copy Vector Buffer Aliasing (`duckdb_v2_vector_reference`, 200,000 rows across 100 chunks)
bench_vector_zero_copy_reference_200k :: proc() {
	bigint_t: duckdb.V2_Logical_Type_Handle
	_ = duckdb.duckdb_v2_factory_create_type_from_id(g_db.factory, .BIGINT, nil, nil, 0, &bigint_t, nil)
	defer duckdb.duckdb_v2_logical_type_destroy(&bigint_t)

	types := [2]duckdb.V2_Logical_Type_Handle{bigint_t, bigint_t}
	chunk: duckdb.V2_Data_Chunk_Handle
	_ = duckdb.duckdb_v2_data_chunk_create(g_db.factory, raw_data(types[:]), 2, &chunk, nil)
	defer duckdb.duckdb_v2_data_chunk_destroy(&chunk)

	src_vec, ref_vec: duckdb.V2_Vector_Handle
	_ = duckdb.duckdb_v2_data_chunk_get_vector(chunk, 0, &src_vec, nil)
	_ = duckdb.duckdb_v2_data_chunk_get_vector(chunk, 1, &ref_vec, nil)
	_ = duckdb.duckdb_v2_vector_set_size(src_vec, 2000, nil)

	for batch := 0; batch < 100; batch += 1 {
		_ = duckdb.duckdb_v2_vector_reference(ref_vec, src_vec, nil)
	}
}

// 4b. Native Composite `STRUCT(firmware VARCHAR, gain DOUBLE, calibrated BOOLEAN)` Child Vector Write + Read (200,000 structs)
bench_native_struct_vector_200k :: proc() {
	struct_sql := duckdb.v2_str_from_string("STRUCT(firmware VARCHAR, gain DOUBLE, calibrated BOOLEAN)")
	struct_type: duckdb.V2_Logical_Type_Handle
	_ = duckdb.duckdb_v2_factory_create_type_from_text(g_db.factory, &struct_sql, &struct_type, nil)
	defer duckdb.duckdb_v2_logical_type_destroy(&struct_type)

	types := [1]duckdb.V2_Logical_Type_Handle{struct_type}
	chunk: duckdb.V2_Data_Chunk_Handle
	_ = duckdb.duckdb_v2_data_chunk_create(g_db.factory, raw_data(types[:]), 1, &chunk, nil)
	defer duckdb.duckdb_v2_data_chunk_destroy(&chunk)

	parent_vec, fw_vec, gain_vec, cal_vec: duckdb.V2_Vector_Handle
	_ = duckdb.duckdb_v2_data_chunk_get_vector(chunk, 0, &parent_vec, nil)
	_ = duckdb.duckdb_v2_vector_get_child(parent_vec, 0, &fw_vec, nil)
	_ = duckdb.duckdb_v2_vector_get_child(parent_vec, 1, &gain_vec, nil)
	_ = duckdb.duckdb_v2_vector_get_child(parent_vec, 2, &cal_vec, nil)

	arena: duckdb.V2_Arena_Handle
	_ = duckdb.duckdb_v2_vector_get_arena(fw_vec, &arena, nil)

	fw_raw, gain_raw, cal_raw: rawptr
	_ = duckdb.duckdb_v2_vector_get_data_mutable(fw_vec, &fw_raw, nil)
	_ = duckdb.duckdb_v2_vector_get_data_mutable(gain_vec, &gain_raw, nil)
	_ = duckdb.duckdb_v2_vector_get_data_mutable(cal_vec, &cal_raw, nil)

	fw_dst := cast([^]duckdb.V2_Bytes)fw_raw
	gain_dst := cast([^]f64)gain_raw
	cal_dst := cast([^]bool)cal_raw

	acc: f64 = 0
	for batch := 0; batch < 100; batch += 1 {
		_ = duckdb.duckdb_v2_vector_set_size(parent_vec, 2000, nil)
		for i: duckdb.V2_Idx = 0; i < 2000; i += 1 {
			_ = duckdb.v2_bytes_encode_in_arena(arena, transmute([]u8)string("v2.4.1"), &fw_dst[i], nil)
			gain_dst[i] = 1.25
			cal_dst[i] = true
		}
		gain_view: duckdb.V2_Vector_View
		_ = duckdb.duckdb_v2_vector_get_view(gain_vec, &gain_view, nil)
		acc += (cast([^]f64)gain_view.data)[0]
	}
	assert(acc > 0)
}

// 4. `duckdb:"...,json"` Struct Tag Round-Trip (`append_slice` + `query_as` for 10,000 nested structs)
bench_json_tag_roundtrip_10k :: proc() {
	_ = duckdb.v2_exec_drain(g_db.conn, "DELETE FROM bench_json")
	rc_in := duckdb.append_slice(g_db.conn, "bench_json", g_json_batch_10k)
	assert(rc_in == .NONE)

	rows, rc_out := duckdb.query_as(g_db.conn, Json_Row, "SELECT id, meta FROM bench_json", context.temp_allocator)
	assert(rc_out == .NONE && len(rows) == 10_000)
}

// 5a. Composable Friendly SQL Query Builder (`query_to_sql` 100,000 compilations)
bench_dsl_query_to_sql_100k :: proc() {
	total_len := 0
	for i := 0; i < 100_000; i += 1 {
		q := duckdb.query_from_quack("remote_eu", "telemetry_events", context.temp_allocator)
		duckdb.query_select(&q, "region", "device_id", "latency_ns")
		duckdb.query_exclude(&q, "internal_debug")
		duckdb.query_replace(&q, "lower(device_id) AS device_id")
		duckdb.query_where_bind(&q, "region = $1 AND latency_ns > $2", "eu-west-1", i64(500))
		duckdb.query_qualify(&q, "row_number() OVER (PARTITION BY device_id ORDER BY latency_ns DESC) = 1")
		duckdb.query_order_by(&q, "latency_ns DESC")
		duckdb.query_limit(&q, 50, 0)
		sql := duckdb.query_to_sql(q, context.temp_allocator)
		total_len += len(sql)
		if i % 1000 == 0 {
			free_all(context.temp_allocator)
		}
	}
	assert(total_len > 0)
}

// 5b. Zero-execution Schema Introspection + Odin & CUE Codegen (1,000 iterations)
bench_schema_introspect_and_codegen_1k :: proc() {
	for i := 0; i < 1_000; i += 1 {
		cols, rc := duckdb.introspect_table_schema(g_db.conn, "bench_scan_100k", context.temp_allocator)
		assert(rc == .NONE && len(cols) == 5)
		odin_code := duckdb.generate_odin_struct_code("models", "Telemetry_Row", cols[:], context.temp_allocator)
		cue_code := duckdb.generate_cue_schema_code("schemas", "Telemetry_Row", cols[:], context.temp_allocator)
		assert(len(odin_code) > 0 && len(cue_code) > 0)
		free_all(context.temp_allocator)
	}
}

// 5c. SQLLogicTest Script Parser (`sqllogic_parse_script`, 50,000 directives across 1,000 scripts)
bench_sqllogic_parse_50k :: proc() {
	total_directives := 0
	for i := 0; i < 1_000; i += 1 {
		dirs := duckdb.sqllogic_parse_script(g_sqllogic_script, context.temp_allocator)
		total_directives += len(dirs)
		free_all(context.temp_allocator)
	}
	assert(total_directives == 50_000)
}

// 6a. Vectorized Scalar UDF Callback (`odin_fma(latency_ns, cpu_load)` over 1,000,000 rows)
bench_udf_scalar_1m :: proc() {
	res: duckdb.V2_Result_Handle
	rc := duckdb.v2_query(g_db.conn, "SELECT sum(odin_fma(latency_ns, cpu_load)) FROM bench_scan_1m", &res)
	assert(rc == .NONE)
	defer duckdb.duckdb_v2_result_destroy(&res)

	chunk: duckdb.V2_Data_Chunk_Handle
	_ = duckdb.duckdb_v2_result_fetch_chunk(res, &chunk, nil)
	assert(chunk != nil)
	duckdb.duckdb_v2_data_chunk_destroy(&chunk)
}

// 6b. Streaming Table Function UDF Producer (`odin_gen_series(1000000)` over 1,000,000 rows)
bench_udf_table_1m :: proc() {
	res: duckdb.V2_Result_Handle
	rc := duckdb.v2_query(g_db.conn, "SELECT sum(id), sum(metric) FROM odin_gen_series(1000000)", &res)
	assert(rc == .NONE)
	defer duckdb.duckdb_v2_result_destroy(&res)

	chunk: duckdb.V2_Data_Chunk_Handle
	_ = duckdb.duckdb_v2_result_fetch_chunk(res, &chunk, nil)
	assert(chunk != nil)
	duckdb.duckdb_v2_data_chunk_destroy(&chunk)
}

// 6c. Grouped Hash Aggregate UDF (`odin_agg_sum(latency_ns) GROUP BY healthy` over 1,000,000 rows)
bench_udf_aggregate_1m :: proc() {
	res: duckdb.V2_Result_Handle
	rc := duckdb.v2_query(g_db.conn, "SELECT healthy, odin_agg_sum(latency_ns) FROM bench_scan_1m GROUP BY healthy", &res)
	assert(rc == .NONE)
	defer duckdb.duckdb_v2_result_destroy(&res)

	chunk: duckdb.V2_Data_Chunk_Handle
	_ = duckdb.duckdb_v2_result_fetch_chunk(res, &chunk, nil)
	assert(chunk != nil)
	duckdb.duckdb_v2_data_chunk_destroy(&chunk)
}

// 7a. Ad-Hoc Parameterized Query (`v2_query` parse + bind + execute, 1,000 point lookups)
bench_point_lookup_adhoc_1k :: proc() {
	for i := 0; i < 1_000; i += 1 {
		res: duckdb.V2_Result_Handle
		rc := duckdb.v2_query(
			g_db.conn,
			"SELECT latency_ns FROM bench_scan_100k WHERE id = $1",
			&res,
			nil,
			i64((i % 100_000) + 1),
		)
		assert(rc == .NONE)
		duckdb.duckdb_v2_result_destroy(&res)
	}
}

// 7b. Pre-Compiled Parameterized Query (`v2_prepared_execute` bind + execute, 1,000 point lookups)
bench_point_lookup_prepared_1k :: proc() {
	for i := 0; i < 1_000; i += 1 {
		res: duckdb.V2_Result_Handle
		rc := duckdb.v2_prepared_execute(
			g_db.conn,
			g_point_prep,
			&res,
			nil,
			i64((i % 100_000) + 1),
		)
		assert(rc == .NONE)
		duckdb.duckdb_v2_result_destroy(&res)
	}
}

// 1e. Custom `V2_Copy_Function_Handle` (`COPY ... FROM` source & `COPY ... TO` sink, 1,000,000 rows)
bench_copy_from_1m :: proc() {
	_ = duckdb.v2_exec_drain(g_db.conn, "DELETE FROM bench_copy_dest")
	g_copy_sink_state.from_goal = 1_000_000
	rc := duckdb.v2_exec_drain(g_db.conn, "COPY bench_copy_dest FROM 'virtual_src.odincopy' (FORMAT odin_bench_copy)")
	assert(rc == .NONE && g_copy_sink_state.from_cursor == 1_000_000)
}

bench_copy_to_1m :: proc() {
	rc := duckdb.v2_exec_drain(
		g_db.conn,
		"COPY (SELECT id, latency_ns FROM bench_scan_1m) TO 'virtual_sink.odincopy' (FORMAT odin_bench_copy, USE_TMP_FILE FALSE)",
	)
	assert(rc == .NONE && g_copy_sink_state.flushed_rows == 1_000_000)
}

// 2g. Bidirectional `Arrow_Exporter` -> `Arrow_Importer` Round-Trip (200,000 rows across 100 chunks)
bench_arrow_exporter_importer_roundtrip_200k :: proc() {
	res: duckdb.V2_Result_Handle
	rc := duckdb.v2_query(g_db.conn, "SELECT odin_arrow_roundtrip(1)", &res)
	assert(rc == .NONE)
	defer duckdb.duckdb_v2_result_destroy(&res)

	chunk: duckdb.V2_Data_Chunk_Handle
	_ = duckdb.duckdb_v2_result_fetch_chunk(res, &chunk, nil)
	assert(chunk != nil)
	duckdb.duckdb_v2_data_chunk_destroy(&chunk)
}

// 3e. Encoded Vector Materialization: `.OTHER` (`MakeSequence`) -> `duckdb_v2_vector_flatten` vs `.CONSTANT` (`MakeConstant`) (1,000,000 rows)
bench_vector_sequence_flatten_1m :: proc() {
	bigint_t: duckdb.V2_Logical_Type_Handle
	_ = duckdb.duckdb_v2_factory_create_type_from_id(g_db.factory, .BIGINT, nil, nil, 0, &bigint_t, nil)
	defer duckdb.duckdb_v2_logical_type_destroy(&bigint_t)

	types := [2]duckdb.V2_Logical_Type_Handle{bigint_t, bigint_t}
	chunk: duckdb.V2_Data_Chunk_Handle
	_ = duckdb.duckdb_v2_data_chunk_create(g_db.factory, raw_data(types[:]), 2, &chunk, nil)
	defer duckdb.duckdb_v2_data_chunk_destroy(&chunk)

	seq_vec, con_vec: duckdb.V2_Vector_Handle
	_ = duckdb.duckdb_v2_data_chunk_get_vector(chunk, 0, &seq_vec, nil)
	_ = duckdb.duckdb_v2_data_chunk_get_vector(chunk, 1, &con_vec, nil)

	con_val: duckdb.V2_Value_Handle
	_ = duckdb.duckdb_v2_value_create_bigint(g_db.factory, 15, &con_val, nil)
	defer duckdb.duckdb_v2_value_destroy(&con_val)
	_ = duckdb.duckdb_v2_vector_make_constant(con_vec, con_val, 2000, nil)

	cview: duckdb.V2_Vector_View
	_ = duckdb.duckdb_v2_vector_get_view(con_vec, &cview, nil)
	c_mult := (cast([^]i64)cview.data)[0]

	acc: i64 = 0
	for batch := 0; batch < 500; batch += 1 {
		_ = duckdb.duckdb_v2_vector_make_sequence(seq_vec, i64(batch * 2000), 1, 2000, nil)
		sview: duckdb.V2_Vector_View
		_ = duckdb.v2_vector_get_readable_view(seq_vec, &sview, nil)
		sdata := cast([^]i64)sview.data
		acc += sdata[0] * c_mult + sdata[1999]
	}
	assert(acc > 0)
}

// 5d. Native C API v2 SQL Tokenizer (`duckdb_v2_tokenize_sql` + `duckdb_v2_token_iterator_next`, 300,000 tokens across 1,000 runs)
bench_v2_tokenize_sql_300k :: proc() {
	sql_str := duckdb.v2_str_from_string(g_tokenize_sql_text)
	total_tokens := 0
	for i := 0; i < 1_000; i += 1 {
		iter: duckdb.V2_Token_Iterator_Handle
		_ = duckdb.duckdb_v2_tokenize_sql(g_db.conn, &sql_str, &iter, nil)
		for {
			tt: duckdb.V2_Token_Type
			st, ln: duckdb.V2_Idx
			_ = duckdb.duckdb_v2_token_iterator_next(iter, &tt, &st, &ln, nil)
			if tt == .END_OF_INPUT {
				break
			}
			total_tokens += 1
		}
		duckdb.duckdb_v2_token_iterator_destroy(&iter)
	}
	assert(total_tokens == 300_000)
}

// 5e. Direct Catalog Table Description (`duckdb_v2_connection_describe_table` + `get_column`, 5,000 tables)
bench_catalog_describe_table_5k :: proc() {
	total_cols: duckdb.V2_Idx = 0
	for i := 0; i < 5_000; i += 1 {
		desc: duckdb.V2_Table_Description_Handle
		_ = duckdb.duckdb_v2_connection_describe_table(g_db.conn, g_describe_qname, &desc, nil)
		col_count: duckdb.V2_Idx
		_ = duckdb.duckdb_v2_table_description_get_column_count(desc, &col_count, nil)
		for c: duckdb.V2_Idx = 0; c < col_count; c += 1 {
			col: duckdb.V2_Column_Description_Handle
			_ = duckdb.duckdb_v2_table_description_get_column(desc, c, &col, nil)
			cname: duckdb.V2_Identifier
			_ = duckdb.duckdb_v2_column_description_get_name(col, &cname, nil)
			ctype: duckdb.V2_Logical_Type_Handle
			_ = duckdb.duckdb_v2_column_description_get_type(col, &ctype, nil)
			tid: duckdb.V2_Logical_Type_Id
			_ = duckdb.duckdb_v2_logical_type_get_id(ctype, &tid, nil)
			duckdb.duckdb_v2_logical_type_destroy(&ctype)
			duckdb.duckdb_v2_column_description_destroy(&col)
		}
		total_cols += col_count
		duckdb.duckdb_v2_table_description_destroy(&desc)
	}
	assert(total_cols == 25_000)
}

// 5f. Quack Protocol Builders, URI Normalization & Template Expansion (100,000 ops)
bench_quack_builders_uri_and_template_100k :: proc() {
	headers := [2]duckdb.Quack_Header{
		{key = "Authorization", value = "Bearer tok_123"},
		{key = "X-Trace-Id", value = "req-42"},
	}
	total_bytes := 0
	for i := 0; i < 20_000; i += 1 {
		uri, ok := duckdb.quack_normalize_uri("quack://10.0.0.1:8815", context.temp_allocator)
		assert(ok)
		s1 := duckdb.quack_serve_sql({endpoint = "quack:localhost:0", token = "asdf"}, context.temp_allocator)
		s2 := duckdb.quack_identify_sql({name = "edge-01", region = "eu-west-1", meta_json = `{"role":"worker"}`}, context.temp_allocator)
		s3 := duckdb.quack_attach_sql({
			endpoint      = "https://127.0.0.1:9999",
			alias         = "remote_eu",
			token         = "asdf",
			read_only     = true,
			extra_headers = headers[:],
		}, context.temp_allocator)
		s4 := duckdb.sqllogic_expand_template(
			"ATTACH '{server}' AS {alias} (TYPE quack, TOKEN '{token}');",
			g_quack_tpl_vars,
			context.temp_allocator,
		)
		total_bytes += len(uri) + len(s1) + len(s2) + len(s3) + len(s4)
		if i % 500 == 0 {
			free_all(context.temp_allocator)
		}
	}
	assert(total_bytes > 0)
}

// 6d. Table Function with Projection + Filter Pushdown (`WHERE id >= 900000`, 1,000,000 source rows -> 100K emitted)
bench_udf_table_pushdown_1m :: proc() {
	res: duckdb.V2_Result_Handle
	rc := duckdb.v2_query(g_db.conn, "SELECT sum(metric) FROM odin_gen_pushdown(1000000) WHERE id >= 900000", &res)
	assert(rc == .NONE)
	defer duckdb.duckdb_v2_result_destroy(&res)

	chunk: duckdb.V2_Data_Chunk_Handle
	_ = duckdb.duckdb_v2_result_fetch_chunk(res, &chunk, nil)
	assert(chunk != nil)
	duckdb.duckdb_v2_data_chunk_destroy(&chunk)
}

// 6e. Custom Domain Type & Vectorized `V2_Cast_Function_Handle` (`SELECT sum((latency_ns::ODIN_NANOS)::DOUBLE)` over 1,000,000 rows)
bench_udf_custom_cast_1m :: proc() {
	res: duckdb.V2_Result_Handle
	rc := duckdb.v2_query(g_db.conn, "SELECT sum((latency_ns::ODIN_NANOS)::DOUBLE) FROM bench_scan_1m", &res)
	assert(rc == .NONE)
	defer duckdb.duckdb_v2_result_destroy(&res)

	chunk: duckdb.V2_Data_Chunk_Handle
	_ = duckdb.duckdb_v2_result_fetch_chunk(res, &chunk, nil)
	assert(chunk != nil)
	duckdb.duckdb_v2_data_chunk_destroy(&chunk)
}

// 8a. Virtual FileSystem (`V2_File_System_Handle` + `V2_File_Handle`) `write_at` + `read_at` (1,000 x 64 KB = 64 MB)
bench_vfs_positional_io_1k :: proc() {
	path_str := duckdb.v2_str_from_string(".tmp/odin_bench_vfs.bin")
	opts: duckdb.V2_File_Open_Options_Handle
	_ = duckdb.duckdb_v2_file_open_options_create(g_vfs_fs, &opts, nil)
	defer duckdb.duckdb_v2_file_open_options_destroy(&opts)
	_ = duckdb.duckdb_v2_file_open_options_set_flag(opts, .READ, nil)
	_ = duckdb.duckdb_v2_file_open_options_set_flag(opts, .WRITE, nil)
	_ = duckdb.duckdb_v2_file_open_options_set_flag(opts, .CREATE, nil)
	_ = duckdb.duckdb_v2_file_open_options_set_flag(opts, .PARALLEL_ACCESS, nil)

	file: duckdb.V2_File_Handle
	rc := duckdb.duckdb_v2_file_system_open(g_vfs_fs, &path_str, opts, &file, nil)
	assert(rc == .NONE)
	defer duckdb.duckdb_v2_file_destroy(&file)

	read_buf: [65536]u8
	block_sz := duckdb.V2_Idx(len(g_vfs_buf_64k))
	for i := 0; i < 500; i += 1 {
		offset := duckdb.V2_Idx((i % 16) * 65536)
		_ = duckdb.duckdb_v2_file_write_at(file, raw_data(g_vfs_buf_64k), block_sz, offset, nil)
		_ = duckdb.duckdb_v2_file_read_at(file, &read_buf[0], block_sz, offset, nil)
	}
	assert(read_buf[0] == g_vfs_buf_64k[0])
}

// 2h. Multi-Worker Parallel `ColumnDataCollection` Scan (4 OS Threads sharing `Shared_Scan_State`, 1,000,000 rows)
bench_collection_worker_proc :: proc(t: ^thread.Thread) {
	ctx := cast(^Bench_Worker_Scan_Ctx)t.user_args[0]
	worker: duckdb.V2_Column_Data_Collection_Worker_Scan_State_Handle
	_ = duckdb.duckdb_v2_column_data_collection_worker_scan_state_create(g_collection_1m, &worker, nil)
	defer duckdb.duckdb_v2_column_data_collection_worker_scan_state_destroy(&worker)

	rows: duckdb.V2_Idx = 0
	acc: i64 = 0
	for {
		did_produce := false
		_ = duckdb.duckdb_v2_column_data_collection_scan(g_collection_1m, ctx.shared, worker, ctx.chunk, &did_produce, nil)
		if !did_produce {
			break
		}
		sz: duckdb.V2_Idx
		_ = duckdb.duckdb_v2_data_chunk_get_size(ctx.chunk, &sz, nil)

		v_id, v_lat: duckdb.V2_Vector_Handle
		_ = duckdb.duckdb_v2_data_chunk_get_vector(ctx.chunk, 0, &v_id, nil)
		_ = duckdb.duckdb_v2_data_chunk_get_vector(ctx.chunk, 1, &v_lat, nil)

		view_id, view_lat: duckdb.V2_Vector_View
		_ = duckdb.duckdb_v2_vector_get_view(v_id, &view_id, nil)
		_ = duckdb.duckdb_v2_vector_get_view(v_lat, &view_lat, nil)

		ids := cast([^]i64)view_id.data
		lats := cast([^]i64)view_lat.data
		for i: duckdb.V2_Idx = 0; i < sz; i += 1 {
			acc += ids[i] + lats[i]
		}
		rows += sz
	}
	ctx.rows = rows
	ctx.sum = acc
}

bench_scan_collection_parallel_4w_1m :: proc() {
	shared: duckdb.V2_Column_Data_Collection_Shared_Scan_State_Handle
	_ = duckdb.duckdb_v2_column_data_collection_shared_scan_state_create(g_collection_1m, &shared, nil)
	defer duckdb.duckdb_v2_column_data_collection_shared_scan_state_destroy(&shared)

	ctxs: [4]Bench_Worker_Scan_Ctx
	threads: [4]^thread.Thread
	for w := 0; w < 4; w += 1 {
		ctxs[w] = Bench_Worker_Scan_Ctx{
			shared = shared,
			chunk  = g_worker_chunks[w],
		}
		threads[w] = thread.create(bench_collection_worker_proc)
		threads[w].user_args[0] = &ctxs[w]
		thread.start(threads[w])
	}

	total_rows: duckdb.V2_Idx = 0
	total_sum: i64 = 0
	for w := 0; w < 4; w += 1 {
		thread.join(threads[w])
		thread.destroy(threads[w])
		total_rows += ctxs[w].rows
		total_sum += ctxs[w].sum
	}
	assert(total_rows == 1_000_000 && total_sum > 0)
}

// 4c. Variable-Length Nested `LIST(BIGINT)` Vector Write + Read (`V2_List_Entry` offset/length + child vector, 200K lists / 800K items)
bench_nested_list_vector_200k :: proc() {
	list_sql := duckdb.v2_str_from_string("BIGINT[]")
	list_type: duckdb.V2_Logical_Type_Handle
	_ = duckdb.duckdb_v2_factory_create_type_from_text(g_db.factory, &list_sql, &list_type, nil)
	defer duckdb.duckdb_v2_logical_type_destroy(&list_type)

	types := [1]duckdb.V2_Logical_Type_Handle{list_type}
	chunk: duckdb.V2_Data_Chunk_Handle
	_ = duckdb.duckdb_v2_data_chunk_create(g_db.factory, raw_data(types[:]), 1, &chunk, nil)
	defer duckdb.duckdb_v2_data_chunk_destroy(&chunk)

	parent_vec, child_vec: duckdb.V2_Vector_Handle
	_ = duckdb.duckdb_v2_data_chunk_get_vector(chunk, 0, &parent_vec, nil)
	_ = duckdb.duckdb_v2_vector_get_child(parent_vec, 0, &child_vec, nil)

	_ = duckdb.duckdb_v2_vector_set_size(parent_vec, 2000, nil)
	_ = duckdb.duckdb_v2_vector_set_size(child_vec, 8000, nil)

	p_raw, c_raw: rawptr
	_ = duckdb.duckdb_v2_vector_get_data_mutable(parent_vec, &p_raw, nil)
	_ = duckdb.duckdb_v2_vector_get_data_mutable(child_vec, &c_raw, nil)
	entries := cast([^]duckdb.V2_List_Entry)p_raw
	elems := cast([^]i64)c_raw

	acc: i64 = 0
	for batch := 0; batch < 100; batch += 1 {
		for i: duckdb.V2_Idx = 0; i < 2000; i += 1 {
			base := i * 4
			entries[i] = duckdb.V2_List_Entry{offset = base, length = 4}
			elems[base + 0] = i64(i)
			elems[base + 1] = i64(i + 1)
			elems[base + 2] = i64(i + 2)
			elems[base + 3] = i64(i + 3)
		}
		p_view, c_view: duckdb.V2_Vector_View
		_ = duckdb.duckdb_v2_vector_get_view(parent_vec, &p_view, nil)
		_ = duckdb.duckdb_v2_vector_get_view(child_vec, &c_view, nil)
		e0 := (cast([^]duckdb.V2_List_Entry)p_view.data)[0]
		acc += (cast([^]i64)c_view.data)[e0.offset + 3]
	}
	assert(acc > 0)
}

// 4d. Fixed-Size Inline `ARRAY(DOUBLE, 4)` Vector Write + Read (200K 4D arrays / 800K doubles)
bench_nested_array_vector_200k :: proc() {
	arr_sql := duckdb.v2_str_from_string("DOUBLE[4]")
	arr_type: duckdb.V2_Logical_Type_Handle
	_ = duckdb.duckdb_v2_factory_create_type_from_text(g_db.factory, &arr_sql, &arr_type, nil)
	defer duckdb.duckdb_v2_logical_type_destroy(&arr_type)

	types := [1]duckdb.V2_Logical_Type_Handle{arr_type}
	chunk: duckdb.V2_Data_Chunk_Handle
	_ = duckdb.duckdb_v2_data_chunk_create(g_db.factory, raw_data(types[:]), 1, &chunk, nil)
	defer duckdb.duckdb_v2_data_chunk_destroy(&chunk)

	parent_vec, child_vec: duckdb.V2_Vector_Handle
	_ = duckdb.duckdb_v2_data_chunk_get_vector(chunk, 0, &parent_vec, nil)
	_ = duckdb.duckdb_v2_vector_get_child(parent_vec, 0, &child_vec, nil)
	_ = duckdb.duckdb_v2_vector_set_size(parent_vec, 2000, nil)

	c_raw: rawptr
	_ = duckdb.duckdb_v2_vector_get_data_mutable(child_vec, &c_raw, nil)
	elems := cast([^]f64)c_raw

	acc: f64 = 0
	for batch := 0; batch < 100; batch += 1 {
		for i: duckdb.V2_Idx = 0; i < 2000; i += 1 {
			base := i * 4
			elems[base + 0] = 0.25
			elems[base + 1] = 0.50
			elems[base + 2] = 0.75
			elems[base + 3] = 1.00
		}
		c_view: duckdb.V2_Vector_View
		_ = duckdb.duckdb_v2_vector_get_view(child_vec, &c_view, nil)
		acc += (cast([^]f64)c_view.data)[3]
	}
	assert(acc > 0)
}

// 5g. Forward Reflection DDL (`create_table_sql`) + `v2_quote_identifier` (100,000 ops)
bench_ddl_create_table_and_quote_ident_100k :: proc() {
	total_bytes := 0
	for i := 0; i < 25_000; i += 1 {
		ddl := duckdb.create_table_sql(DDL_Complex_Event, "analytics.telemetry_events", true, context.temp_allocator)
		q1 := duckdb.v2_quote_identifier("sensor_readings", false, context.temp_allocator)
		q2 := duckdb.v2_quote_identifier("select", false, context.temp_allocator)
		q3 := duckdb.v2_quote_identifier("analytics.telemetry_events", true, context.temp_allocator)
		total_bytes += len(ddl) + len(q1) + len(q2) + len(q3)
		if i % 500 == 0 {
			free_all(context.temp_allocator)
		}
	}
	assert(total_bytes > 0)
}

// 6f. `V2_Replacement_Scan_Handle` Dynamic Virtual Table Resolution (`SELECT sum(latency_ns) FROM virtual_metrics_batch`, 1,000 queries)
bench_replacement_scan_collection_1k :: proc() {
	before_calls := g_repl_state.calls
	for i := 0; i < 1_000; i += 1 {
		res: duckdb.V2_Result_Handle
		rc := duckdb.v2_query(g_db.conn, "SELECT sum(latency_ns) FROM virtual_metrics_batch", &res)
		assert(rc == .NONE)
		chunk: duckdb.V2_Data_Chunk_Handle
		_ = duckdb.duckdb_v2_result_fetch_chunk(res, &chunk, nil)
		duckdb.duckdb_v2_data_chunk_destroy(&chunk)
		duckdb.duckdb_v2_result_destroy(&res)
	}
	assert(g_repl_state.calls == before_calls + 1_000)
}

// 8b. Observability & Telemetry: `V2_Query_Metrics_Handle` Tree Inspection + `V2_Log_Sink_Handle` Dispatch (10,000 ops)
bench_query_metrics_and_log_sink_10k :: proc() {
	_ = duckdb.v2_exec_drain(g_db.conn, "SET enable_profiling = 'no_output'")
	_ = duckdb.duckdb_v2_connection_enable_profiling(g_db.conn, true, nil)
	_ = duckdb.v2_exec_drain(g_db.conn, "SELECT sum(latency_ns) FROM bench_scan_100k")

	total_time_key := duckdb.v2_str_from_string("query.total_time")
	log_type := duckdb.v2_str_from_string("OdinBenchTelemetry")
	log_msg := duckdb.v2_str_from_string("operator_batch_completed")

	before_logs := g_log_sink_state.entries
	inspected := 0
	for i := 0; i < 5_000; i += 1 {
		metrics: duckdb.V2_Query_Metrics_Handle
		_ = duckdb.duckdb_v2_connection_get_query_metrics(g_db.conn, &metrics, nil)
		root: duckdb.V2_Query_Metrics_Node_Handle
		_ = duckdb.duckdb_v2_query_metrics_get_root(metrics, &root, nil)
		tval: duckdb.V2_Value_Handle
		present := false
		_ = duckdb.duckdb_v2_query_metrics_node_get_metric(root, &total_time_key, &tval, &present, nil)
		if present {
			inspected += 1
			duckdb.duckdb_v2_value_destroy(&tval)
		}
		duckdb.duckdb_v2_query_metrics_destroy(&metrics)

		_ = duckdb.duckdb_v2_instance_log(g_db.instance, .INFO, &log_type, &log_msg, nil)
	}
	_ = duckdb.duckdb_v2_connection_enable_profiling(g_db.conn, false, nil)
	assert(inspected == 5_000 && g_log_sink_state.entries == before_logs + 5_000)
}

// 2i. Cooperative Streaming Stepper: `v2_step_chunk` (`duckdb_v2_result_step` + `duckdb_v2_result_wait`) over 1,000,000 rows
bench_scan_v2_step_chunk_1m :: proc() {
	res: duckdb.V2_Result_Handle
	rc := duckdb.v2_query(g_db.conn, "SELECT id, latency_ns, cpu_load, healthy FROM bench_scan_1m", &res)
	assert(rc == .NONE)
	defer duckdb.duckdb_v2_result_destroy(&res)

	total_rows: duckdb.V2_Idx = 0
	acc: i64 = 0
	for {
		chunk: duckdb.V2_Data_Chunk_Handle
		status, step_rc := duckdb.v2_step_chunk(res, &chunk)
		assert(step_rc == .NONE)
		if status != .CHUNK || chunk == nil {
			break
		}
		defer duckdb.duckdb_v2_data_chunk_destroy(&chunk)

		sz: duckdb.V2_Idx
		_ = duckdb.duckdb_v2_data_chunk_get_size(chunk, &sz, nil)

		v_id, v_lat: duckdb.V2_Vector_Handle
		_ = duckdb.duckdb_v2_data_chunk_get_vector(chunk, 0, &v_id, nil)
		_ = duckdb.duckdb_v2_data_chunk_get_vector(chunk, 1, &v_lat, nil)

		view_id, view_lat: duckdb.V2_Vector_View
		_ = duckdb.v2_vector_get_readable_view(v_id, &view_id, nil)
		_ = duckdb.v2_vector_get_readable_view(v_lat, &view_lat, nil)

		ids := cast([^]i64)view_id.data
		lats := cast([^]i64)view_lat.data
		for i: duckdb.V2_Idx = 0; i < sz; i += 1 {
			acc += ids[duckdb.v2_sel_at(view_id.sel, i)] + lats[duckdb.v2_sel_at(view_lat.sel, i)]
		}
		total_rows += sz
	}
	assert(total_rows == 1_000_000 && acc > 0)
}

// 3f. 128-Bit `HUGEINT`/`UHUGEINT`, `INTERVAL`, `BIT` Bitstring & `BIGNUM` Codec (200,000 ops)
bench_128bit_bit_and_bignum_codec_200k :: proc() {
	huge_t, uhuge_t, iv_t: duckdb.V2_Logical_Type_Handle
	_ = duckdb.duckdb_v2_factory_create_type_from_id(g_db.factory, .HUGEINT, nil, nil, 0, &huge_t, nil)
	_ = duckdb.duckdb_v2_factory_create_type_from_id(g_db.factory, .UHUGEINT, nil, nil, 0, &uhuge_t, nil)
	_ = duckdb.duckdb_v2_factory_create_type_from_id(g_db.factory, .INTERVAL, nil, nil, 0, &iv_t, nil)
	defer duckdb.duckdb_v2_logical_type_destroy(&huge_t)
	defer duckdb.duckdb_v2_logical_type_destroy(&uhuge_t)
	defer duckdb.duckdb_v2_logical_type_destroy(&iv_t)

	types := [3]duckdb.V2_Logical_Type_Handle{huge_t, uhuge_t, iv_t}
	chunk: duckdb.V2_Data_Chunk_Handle
	_ = duckdb.duckdb_v2_data_chunk_create(g_db.factory, raw_data(types[:]), 3, &chunk, nil)
	defer duckdb.duckdb_v2_data_chunk_destroy(&chunk)

	vh, vuh, viv: duckdb.V2_Vector_Handle
	_ = duckdb.duckdb_v2_data_chunk_get_vector(chunk, 0, &vh, nil)
	_ = duckdb.duckdb_v2_data_chunk_get_vector(chunk, 1, &vuh, nil)
	_ = duckdb.duckdb_v2_data_chunk_get_vector(chunk, 2, &viv, nil)
	_ = duckdb.duckdb_v2_vector_set_size(vh, 2000, nil)
	_ = duckdb.duckdb_v2_vector_set_size(vuh, 2000, nil)
	_ = duckdb.duckdb_v2_vector_set_size(viv, 2000, nil)

	rh, ruh, riv: rawptr
	_ = duckdb.duckdb_v2_vector_get_data_mutable(vh, &rh, nil)
	_ = duckdb.duckdb_v2_vector_get_data_mutable(vuh, &ruh, nil)
	_ = duckdb.duckdb_v2_vector_get_data_mutable(viv, &riv, nil)
	dh := cast([^]duckdb.V2_Hugeint)rh
	duh := cast([^]duckdb.V2_Uhugeint)ruh
	div := cast([^]duckdb.V2_Interval)riv

	bit_storage := duckdb.V2_Bytes{}
	bit_storage.inlined.length = 3
	bit_storage.inlined.inlined[0] = 3 // 3 padding bits -> 13 active bits
	bit_storage.inlined.inlined[1] = 0b10101010
	bit_storage.inlined.inlined[2] = 0b11111000

	mag := [9]u8{1, 0, 0, 0, 0, 0, 0, 0, 0}
	enc_buf: [16]u8
	dec_buf: [16]u8

	acc: u64 = 0
	for batch := 0; batch < 100; batch += 1 {
		for i := 0; i < 2000; i += 1 {
			dh[i] = duckdb.V2_Hugeint{lower = u64(i + 1), upper = 1}
			duh[i] = duckdb.V2_Uhugeint{lower = u64(i + 2), upper = 2}
			div[i] = duckdb.V2_Interval{months = 12, days = i32(i & 31), micros = i64(i * 1000)}
			acc += dh[i].lower + duh[i].lower + duckdb.v2_bit_count(&bit_storage) + u64(duckdb.v2_bit_padding(&bit_storage))
		}
		enc_len, dec_len: duckdb.V2_Idx
		dec_neg := false
		_ = duckdb.duckdb_v2_bignum_encode(&mag[0], len(mag), (batch & 1) == 0, &enc_buf[0], len(enc_buf), &enc_len, nil)
		_ = duckdb.duckdb_v2_bignum_decode(&enc_buf[0], enc_len, &dec_buf[0], len(dec_buf), &dec_len, &dec_neg, nil)
		acc += u64(dec_len)
	}
	assert(acc > 0)
}

// 4e. Complex Composite Types & Values: `MAP`, `UNION`, `VARIANT` Vector Box/Unbox & `DECIMAL` (10,000 ops)
bench_complex_composite_types_and_variant_10k :: proc() {
	var_sql := duckdb.v2_str_from_string("VARIANT")
	variant_t: duckdb.V2_Logical_Type_Handle
	_ = duckdb.duckdb_v2_factory_create_type_from_text(g_db.factory, &var_sql, &variant_t, nil)
	defer duckdb.duckdb_v2_logical_type_destroy(&variant_t)

	u_sql := duckdb.v2_str_from_string("UNION(i BIGINT, s VARCHAR)")
	union_t: duckdb.V2_Logical_Type_Handle
	_ = duckdb.duckdb_v2_factory_create_type_from_text(g_db.factory, &u_sql, &union_t, nil)
	defer duckdb.duckdb_v2_logical_type_destroy(&union_t)

	bigint_t, varchar_t: duckdb.V2_Logical_Type_Handle
	_ = duckdb.duckdb_v2_factory_create_type_from_id(g_db.factory, .BIGINT, nil, nil, 0, &bigint_t, nil)
	_ = duckdb.duckdb_v2_factory_create_type_from_id(g_db.factory, .VARCHAR, nil, nil, 0, &varchar_t, nil)
	defer duckdb.duckdb_v2_logical_type_destroy(&bigint_t)
	defer duckdb.duckdb_v2_logical_type_destroy(&varchar_t)

	types := [1]duckdb.V2_Logical_Type_Handle{variant_t}
	chunk: duckdb.V2_Data_Chunk_Handle
	_ = duckdb.duckdb_v2_data_chunk_create(g_db.factory, &types[0], 1, &chunk, nil)
	defer duckdb.duckdb_v2_data_chunk_destroy(&chunk)

	vec: duckdb.V2_Vector_Handle
	_ = duckdb.duckdb_v2_data_chunk_get_vector(chunk, 0, &vec, nil)
	_ = duckdb.duckdb_v2_vector_set_size(vec, 2000, nil)

	k_str := duckdb.v2_str_from_string("sensor_region")
	k0: duckdb.V2_Value_Handle
	_ = duckdb.duckdb_v2_value_create_varchar(g_db.factory, &k_str, &k0, nil)
	defer duckdb.duckdb_v2_value_destroy(&k0)

	sum_val: i64 = 0
	for i := 0; i < 2_500; i += 1 {
		// 1. Box & unbox BIGINT in VARIANT vector
		v_in: duckdb.V2_Value_Handle
		_ = duckdb.duckdb_v2_value_create_bigint(g_db.factory, i64(i + 1), &v_in, nil)
		_ = duckdb.duckdb_v2_vector_set_value(vec, duckdb.V2_Idx(i % 2000), v_in, nil)

		v_box, v_unboxed: duckdb.V2_Value_Handle
		_ = duckdb.duckdb_v2_vector_get_value(vec, duckdb.V2_Idx(i % 2000), &v_box, nil)
		_ = duckdb.duckdb_v2_value_cast(g_db.factory, v_box, bigint_t, &v_unboxed, nil)
		got: i64
		_ = duckdb.duckdb_v2_value_get_bigint(v_unboxed, &got, nil)
		sum_val += got
		duckdb.duckdb_v2_value_destroy(&v_unboxed)
		duckdb.duckdb_v2_value_destroy(&v_box)

		// 2. Construct MAP(VARCHAR, BIGINT) value + UNION(i BIGINT, s VARCHAR) cast + DECIMAL(12, 4) value
		v_map: duckdb.V2_Value_Handle
		keys := [1]duckdb.V2_Value_Handle{k0}
		vals := [1]duckdb.V2_Value_Handle{v_in}
		_ = duckdb.duckdb_v2_value_create_map(g_db.factory, varchar_t, bigint_t, &keys[0], &vals[0], 1, &v_map, nil)

		v_union: duckdb.V2_Value_Handle
		_ = duckdb.duckdb_v2_value_cast(g_db.factory, v_in, union_t, &v_union, nil)

		dec_raw := duckdb.V2_Hugeint{lower = u64((i + 1) * 100), upper = 0}
		v_dec: duckdb.V2_Value_Handle
		_ = duckdb.duckdb_v2_value_create_decimal(g_db.factory, &dec_raw, 12, 4, &v_dec, nil)

		duckdb.duckdb_v2_value_destroy(&v_dec)
		duckdb.duckdb_v2_value_destroy(&v_union)
		duckdb.duckdb_v2_value_destroy(&v_map)
		duckdb.duckdb_v2_value_destroy(&v_in)
	}
	assert(sum_val > 0)
}

// 6g. Extensibility Hooks: `V2_Pragma_Function_Handle` + `V2_Custom_Option_Handle` + `V2_Macro_Function_Handle` (1,000 ops)
bench_pragma_custom_option_and_macro_1k :: proc() {
	before_pragmas := g_ext_state.pragma_calls
	before_opts := g_ext_state.option_calls
	for i := 0; i < 333; i += 1 {
		_ = duckdb.v2_exec_drain(g_db.conn, "PRAGMA odin_bench_bump(10, 20)")
		_ = duckdb.v2_exec_drain(g_db.conn, "SET odin_bench_budget = 250")

		macro_fn: duckdb.V2_Macro_Function_Handle
		_ = duckdb.duckdb_v2_macro_function_create(g_db.factory, .SCALAR, &macro_fn, nil)
		m_name := duckdb.v2_str_from_string("odin_fast_fma")
		m_body := duckdb.v2_str_from_string("lat * cpu + 1.0")
		_ = duckdb.duckdb_v2_macro_function_set_name(macro_fn, &m_name, nil)
		_ = duckdb.duckdb_v2_macro_function_set_body(macro_fn, &m_body, nil)
		duckdb.duckdb_v2_macro_function_destroy(&macro_fn)
	}
	_ = duckdb.v2_exec_drain(g_db.conn, "RESET odin_bench_budget")
	assert(g_ext_state.pragma_calls == before_pragmas + 333 && g_ext_state.option_calls == before_opts + 334)
}

// 7c. Composable DSL End-to-End Execution: `query_execute_as` (DSL build + `query_to_sql` + param bind + `query_as`, 1,000 queries)
bench_dsl_query_execute_as_1k :: proc() {
	total_rows := 0
	for i := 0; i < 1_000; i += 1 {
		target_id := i64((i % 100_000) + 1)
		q := duckdb.query_from("bench_scan_100k")
		duckdb.query_select(&q, "id", "device_id", "latency_ns", "cpu_load", "healthy")
		duckdb.query_where(&q, "id = $1")
		duckdb.query_bind(&q, target_id)
		duckdb.query_limit(&q, 1)

		rows, rc := duckdb.query_execute_as(g_db.conn, Telemetry_Row, q, context.temp_allocator)
		assert(rc == .NONE && len(rows) == 1 && rows[0].id == target_id)
		total_rows += len(rows)
		if i % 100 == 0 {
			free_all(context.temp_allocator)
		}
	}
	assert(total_rows == 1_000)
}

bench_tx_commit_body :: proc(conn: duckdb.V2_Connection_Handle, user_data: rawptr, err: ^duckdb.V2_Error_Info_Handle) -> duckdb.V2_Error {
	counter := cast(^int)user_data
	counter^ += 1
	return .NONE
}

bench_tx_rollback_body :: proc(conn: duckdb.V2_Connection_Handle, user_data: rawptr, err: ^duckdb.V2_Error_Info_Handle) -> duckdb.V2_Error {
	counter := cast(^int)user_data
	counter^ += 1
	return .INPUT_INVALID
}

// 7d. Transaction Lifecycle & Rollback Recovery: `v2_with_transaction` (`BEGIN` -> body -> `COMMIT` / `ROLLBACK`, 1,000 transactions)
bench_v2_with_transaction_1k :: proc() {
	before := g_tx_counter
	for i := 0; i < 500; i += 1 {
		rc_ok := duckdb.v2_with_transaction(g_db.conn, bench_tx_commit_body, &g_tx_counter)
		assert(rc_ok == .NONE)
		rc_rb := duckdb.v2_with_transaction(g_db.conn, bench_tx_rollback_body, &g_tx_counter)
		assert(rc_rb == .INPUT_INVALID)
	}
	assert(g_tx_counter == before + 1_000)
}

// 7e. Pre-Compiled DSL Pipeline: `Prepared_Query(T)` + `prepared_query_execute_as` (1,000 typed point lookups)
bench_dsl_prepared_query_execute_as_1k :: proc() {
	total_rows := 0
	for i := 0; i < 1_000; i += 1 {
		target_id := i64((i % 100_000) + 1)
		rows, rc := duckdb.prepared_query_execute_as(&g_dsl_pq, context.temp_allocator, nil, target_id)
		assert(rc == .NONE && len(rows) == 1 && rows[0].id == target_id)
		total_rows += len(rows)
		if i % 100 == 0 {
			free_all(context.temp_allocator)
		}
	}
	assert(total_rows == 1_000)
}

// 1g. Streaming Micro-Batches: `Struct_Appender(T)` (1,000 x 100-row micro-batches = 100,000 rows)
bench_struct_appender_microbatches_100k :: proc() {
	_ = duckdb.v2_exec_drain(g_db.conn, "DELETE FROM bench_ingest_v2")
	for b := 0; b < 1_000; b += 1 {
		start := b * 100
		rc := duckdb.struct_appender_append(&g_struct_appender, g_ingest_batch_100k[start : start + 100])
		assert(rc == .NONE)
	}
	rc_flush := duckdb.struct_appender_flush(&g_struct_appender)
	assert(rc_flush == .NONE)
}

main :: proc() {
	fmt.println("================================================================================")
	fmt.println(" odin-duckdb Benchmark Suite (DuckDB 2.0 C API v2 + Reflection + DSL + Arrow)")
	fmt.println("================================================================================")

	rc: duckdb.V2_Error
	g_db, rc = duckdb.v2_open("")
	assert(rc == .NONE)
	defer _ = duckdb.v2_close(&g_db)

	v1_ok: bool
	g_v1_db, _, v1_ok = duckdb.open("")
	assert(v1_ok)
	defer duckdb.close(&g_v1_db)

	// Prepare tables & datasets
	ddl := duckdb.create_table_sql(Telemetry_Row, "bench_ingest_v2")
	_ = duckdb.v2_exec_drain(g_db.conn, ddl)
	duckdb.exec(&g_v1_db, duckdb.create_table_sql(Telemetry_Row, "bench_ingest_v1"))
	_ = duckdb.v2_exec_drain(g_db.conn, duckdb.create_table_sql(Nullable_Telemetry_Row, "bench_nullable_v2"))
	_ = duckdb.v2_exec_drain(g_db.conn, duckdb.create_table_sql(Nullable_Telemetry_Row, "bench_nullable_seed_100k"))
	_ = duckdb.v2_exec_drain(g_db.conn, duckdb.create_table_sql(Json_Row, "bench_json"))

	// Seed 1,000,000 rows for zero-copy vector & Arrow scan benchmarks, and 100,000 rows for `query_as`
	_ = duckdb.v2_exec_drain(
		g_db.conn,
		"CREATE TABLE bench_scan_1m AS SELECT i AS id, 'edge-node-01' AS device_id, (i * 15)::BIGINT AS latency_ns, (i % 100)::DOUBLE * 0.75 AS cpu_load, (i % 2 = 0) AS healthy FROM range(1, 1000001) t(i)",
	)
	_ = duckdb.v2_exec_drain(
		g_db.conn,
		"CREATE TABLE bench_scan_100k AS SELECT * FROM bench_scan_1m LIMIT 100000",
	)

	g_ingest_batch_100k = make([]Telemetry_Row, 100_000)
	defer delete(g_ingest_batch_100k)
	for i := 0; i < 100_000; i += 1 {
		g_ingest_batch_100k[i] = Telemetry_Row{
			id         = i64(i + 1),
			device_id  = "edge-node-01",
			latency_ns = i64(i * 15),
			cpu_load   = f64(i % 100) * 0.75,
			healthy    = (i % 2 == 0),
		}
	}
	g_ingest_batch_2k = g_ingest_batch_100k[:2_000]

	g_nullable_batch_100k = make([]Nullable_Telemetry_Row, 100_000)
	defer delete(g_nullable_batch_100k)
	for i := 0; i < 100_000; i += 1 {
		is_null := (i % 4 == 0)
		g_nullable_batch_100k[i] = Nullable_Telemetry_Row{
			id         = i64(i + 1),
			device_id  = nil if is_null else "edge-node-01",
			latency_ns = nil if is_null else i64(i * 15),
			cpu_load   = nil if is_null else f64(i % 100) * 0.75,
			healthy    = nil if is_null else (i % 2 == 0),
		}
	}
	_ = duckdb.append_slice(g_db.conn, "bench_nullable_seed_100k", g_nullable_batch_100k)

	tags_sample := []string{"indoor", "calibrated"}
	g_json_batch_10k = make([]Json_Row, 10_000)
	defer delete(g_json_batch_10k)
	for i := 0; i < 10_000; i += 1 {
		g_json_batch_10k[i] = Json_Row{
			id   = i64(i + 1),
			meta = Sensor_Meta{firmware = "v2.4.1", tags = tags_sample, gain = 1.25},
		}
	}

	// Register Scalar UDF `odin_fma(BIGINT, DOUBLE) -> DOUBLE`
	{
		bigint_t, double_t: duckdb.V2_Logical_Type_Handle
		_ = duckdb.duckdb_v2_factory_create_type_from_id(g_db.factory, .BIGINT, nil, nil, 0, &bigint_t, nil)
		_ = duckdb.duckdb_v2_factory_create_type_from_id(g_db.factory, .DOUBLE, nil, nil, 0, &double_t, nil)
		defer duckdb.duckdb_v2_logical_type_destroy(&bigint_t)
		defer duckdb.duckdb_v2_logical_type_destroy(&double_t)

		sfn: duckdb.V2_Scalar_Function_Handle
		_ = duckdb.duckdb_v2_scalar_function_create(g_db.factory, &sfn, nil)
		defer duckdb.duckdb_v2_scalar_function_destroy(&sfn)

		sig: duckdb.V2_Function_Signature_Handle
		_ = duckdb.duckdb_v2_scalar_function_get_signature(sfn, &sig, nil)
		p0 := duckdb.v2_str_from_string("lat")
		p1 := duckdb.v2_str_from_string("cpu")
		_ = duckdb.duckdb_v2_function_signature_add_parameter(sig, &p0, bigint_t, nil, .POSITIONAL_ONLY, nil)
		_ = duckdb.duckdb_v2_function_signature_add_parameter(sig, &p1, double_t, nil, .POSITIONAL_ONLY, nil)
		_ = duckdb.duckdb_v2_function_signature_set_return_type(sig, double_t, nil)

		fn_name := duckdb.v2_str_from_string("odin_fma")
		_ = duckdb.duckdb_v2_scalar_function_set_name(sfn, &fn_name, nil)
		_ = duckdb.duckdb_v2_scalar_function_set_exec_callback(sfn, bench_scalar_fma_cb, nil)
		_ = duckdb.duckdb_v2_connection_register_scalar_function(g_db.conn, sfn, nil)

		// Register Table UDF `odin_gen_series(n BIGINT) -> (id BIGINT, metric DOUBLE)`
		tfn: duckdb.V2_Table_Function_Handle
		_ = duckdb.duckdb_v2_table_function_create(g_db.factory, &tfn, nil)
		defer duckdb.duckdb_v2_table_function_destroy(&tfn)

		tsig: duckdb.V2_Function_Signature_Handle
		_ = duckdb.duckdb_v2_table_function_get_signature(tfn, &tsig, nil)
		pn := duckdb.v2_str_from_string("n")
		_ = duckdb.duckdb_v2_function_signature_add_parameter(tsig, &pn, bigint_t, nil, .POSITIONAL_ONLY, nil)

		tname := duckdb.v2_str_from_string("odin_gen_series")
		ud := duckdb.V2_Opaque{ptr = &g_table_udf_state}
		_ = duckdb.duckdb_v2_table_function_set_name(tfn, &tname, nil)
		_ = duckdb.duckdb_v2_table_function_set_user_data(tfn, &ud, nil)
		_ = duckdb.duckdb_v2_table_function_set_bind_callback(tfn, bench_table_gen_bind_cb, nil)
		_ = duckdb.duckdb_v2_table_function_set_init_global_callback(tfn, bench_table_gen_init_global_cb, nil)
		_ = duckdb.duckdb_v2_table_function_set_exec_callback(tfn, bench_table_gen_exec_cb, nil)
		_ = duckdb.duckdb_v2_connection_register_table_function(g_db.conn, tfn, nil)

		// Register Grouped Aggregate UDF `odin_agg_sum(BIGINT) -> BIGINT`
		afn: duckdb.V2_Aggregate_Function_Handle
		_ = duckdb.duckdb_v2_aggregate_function_create(g_db.factory, &afn, nil)
		defer duckdb.duckdb_v2_aggregate_function_destroy(&afn)

		asig: duckdb.V2_Function_Signature_Handle
		_ = duckdb.duckdb_v2_aggregate_function_get_signature(afn, &asig, nil)
		pv := duckdb.v2_str_from_string("v")
		_ = duckdb.duckdb_v2_function_signature_add_parameter(asig, &pv, bigint_t, nil, .POSITIONAL_ONLY, nil)
		_ = duckdb.duckdb_v2_function_signature_set_return_type(asig, bigint_t, nil)

		aname := duckdb.v2_str_from_string("odin_agg_sum")
		_ = duckdb.duckdb_v2_aggregate_function_set_name(afn, &aname, nil)
		_ = duckdb.duckdb_v2_aggregate_function_set_size_callback(afn, bench_agg_sum_size_cb, nil)
		_ = duckdb.duckdb_v2_aggregate_function_set_init_callback(afn, bench_agg_sum_init_cb, nil)
		_ = duckdb.duckdb_v2_aggregate_function_set_update_callback(afn, bench_agg_sum_update_cb, nil)
		_ = duckdb.duckdb_v2_aggregate_function_set_combine_callback(afn, bench_agg_sum_combine_cb, nil)
		_ = duckdb.duckdb_v2_aggregate_function_set_finalize_callback(afn, bench_agg_sum_finalize_cb, nil)
		_ = duckdb.duckdb_v2_connection_register_aggregate_function(g_db.conn, afn, nil)

		// Seed 1,000,000-row `ColumnDataCollection` for 2f/2h direct & parallel scan benchmarks
		col_types := [2]duckdb.V2_Logical_Type_Handle{bigint_t, bigint_t}
		_ = duckdb.duckdb_v2_column_data_collection_create(g_db.factory, raw_data(col_types[:]), 2, &g_collection_1m, nil)
		_ = duckdb.duckdb_v2_data_chunk_create(g_db.factory, raw_data(col_types[:]), 2, &g_collection_scan_chunk, nil)
		for w := 0; w < 4; w += 1 {
			_ = duckdb.duckdb_v2_data_chunk_create(g_db.factory, raw_data(col_types[:]), 2, &g_worker_chunks[w], nil)
		}

		// Seed 1,000-row `ColumnDataCollection` + `V2_Replacement_Scan_Handle` for 6f replacement scan benchmark
		_ = duckdb.duckdb_v2_column_data_collection_create(g_db.factory, raw_data(col_types[:]), 2, &g_repl_collection_1k, nil)
		repl_app: duckdb.V2_Column_Data_Collection_Append_State_Handle
		_ = duckdb.duckdb_v2_column_data_collection_append_state_create(g_repl_collection_1k, &repl_app, nil)
		rv0, rv1: duckdb.V2_Vector_Handle
		_ = duckdb.duckdb_v2_data_chunk_get_vector(g_collection_scan_chunk, 0, &rv0, nil)
		_ = duckdb.duckdb_v2_data_chunk_get_vector(g_collection_scan_chunk, 1, &rv1, nil)
		_ = duckdb.duckdb_v2_vector_set_size(rv0, 1000, nil)
		_ = duckdb.duckdb_v2_vector_set_size(rv1, 1000, nil)
		rr0, rr1: rawptr
		_ = duckdb.duckdb_v2_vector_get_data_mutable(rv0, &rr0, nil)
		_ = duckdb.duckdb_v2_vector_get_data_mutable(rv1, &rr1, nil)
		rd0 := cast([^]i64)rr0
		rd1 := cast([^]i64)rr1
		for i := 0; i < 1000; i += 1 {
			rd0[i] = i64(i + 1)
			rd1[i] = i64((i + 1) * 10)
		}
		_ = duckdb.duckdb_v2_column_data_collection_append(g_repl_collection_1k, repl_app, g_collection_scan_chunk, nil)
		duckdb.duckdb_v2_column_data_collection_append_state_destroy(&repl_app)

		g_repl_state = Bench_Replacement_State{collection = g_repl_collection_1k}
		rscan: duckdb.V2_Replacement_Scan_Handle
		_ = duckdb.duckdb_v2_replacement_scan_create(g_db.factory, &rscan, nil)
		defer duckdb.duckdb_v2_replacement_scan_destroy(&rscan)
		rud := duckdb.V2_Opaque{ptr = &g_repl_state}
		_ = duckdb.duckdb_v2_replacement_scan_set_callback(rscan, bench_replacement_scan_cb, nil)
		_ = duckdb.duckdb_v2_replacement_scan_set_user_data(rscan, &rud, nil)
		_ = duckdb.duckdb_v2_connection_register_replacement_scan(g_db.conn, rscan, nil)

		// Register `V2_Log_Sink_Handle` on instance for 8b telemetry benchmark
		inst_factory: duckdb.V2_Factory_Handle
		_ = duckdb.duckdb_v2_instance_get_factory(g_db.instance, &inst_factory, nil)
		lsink: duckdb.V2_Log_Sink_Handle
		_ = duckdb.duckdb_v2_log_sink_create(inst_factory, &lsink, nil)
		defer duckdb.duckdb_v2_log_sink_destroy(&lsink)
		lsink_name := duckdb.v2_str_from_string("odin_bench_sink")
		lsink_ud := duckdb.V2_Opaque{ptr = &g_log_sink_state}
		_ = duckdb.duckdb_v2_log_sink_set_name(lsink, &lsink_name, nil)
		_ = duckdb.duckdb_v2_log_sink_set_user_data(lsink, &lsink_ud, nil)
		_ = duckdb.duckdb_v2_log_sink_set_write_callback(lsink, bench_log_sink_write_cb, nil)
		_ = duckdb.duckdb_v2_instance_register_log_sink(g_db.instance, lsink, nil)
		_ = duckdb.v2_exec_drain(g_db.conn, "CALL enable_logging()")
		_ = duckdb.v2_exec_drain(g_db.conn, "SET logging_storage = 'ODIN_BENCH_SINK'")

		app_state: duckdb.V2_Column_Data_Collection_Append_State_Handle
		_ = duckdb.duckdb_v2_column_data_collection_append_state_create(g_collection_1m, &app_state, nil)
		defer duckdb.duckdb_v2_column_data_collection_append_state_destroy(&app_state)

		v0, v1: duckdb.V2_Vector_Handle
		_ = duckdb.duckdb_v2_data_chunk_get_vector(g_collection_scan_chunk, 0, &v0, nil)
		_ = duckdb.duckdb_v2_data_chunk_get_vector(g_collection_scan_chunk, 1, &v1, nil)
		_ = duckdb.duckdb_v2_vector_set_size(v0, 2000, nil)
		_ = duckdb.duckdb_v2_vector_set_size(v1, 2000, nil)

		r0, r1: rawptr
		_ = duckdb.duckdb_v2_vector_get_data_mutable(v0, &r0, nil)
		_ = duckdb.duckdb_v2_vector_get_data_mutable(v1, &r1, nil)
		d0 := cast([^]i64)r0
		d1 := cast([^]i64)r1
		for i := 0; i < 2000; i += 1 {
			d0[i] = i64(i + 1)
			d1[i] = i64((i + 1) * 15)
		}
		for b := 0; b < 500; b += 1 {
			_ = duckdb.duckdb_v2_column_data_collection_append(g_collection_1m, app_state, g_collection_scan_chunk, nil)
		}

		// Register custom `V2_Copy_Function_Handle` (`odin_bench_copy`) for 1e/1f COPY benchmarks
		cfn: duckdb.V2_Copy_Function_Handle
		_ = duckdb.duckdb_v2_copy_function_create(g_db.factory, &cfn, nil)
		defer duckdb.duckdb_v2_copy_function_destroy(&cfn)

		cfn_name := duckdb.v2_str_from_string("odin_bench_copy")
		cfn_ext := duckdb.v2_str_from_string("odincopy")
		copy_ud := duckdb.V2_Opaque{ptr = &g_copy_sink_state}
		_ = duckdb.duckdb_v2_copy_function_set_name(cfn, &cfn_name, nil)
		_ = duckdb.duckdb_v2_copy_function_set_file_extension(cfn, &cfn_ext, nil)
		_ = duckdb.duckdb_v2_copy_function_set_user_data(cfn, &copy_ud, nil)
		_ = duckdb.duckdb_v2_copy_to_set_bind_callback(cfn, bench_copy_to_bind_cb, nil)
		_ = duckdb.duckdb_v2_copy_to_set_batch_size_callback(cfn, bench_copy_to_batch_size_cb, nil)
		_ = duckdb.duckdb_v2_copy_to_set_init_callback(cfn, bench_copy_to_init_cb, nil)
		_ = duckdb.duckdb_v2_copy_to_set_batch_callback(cfn, bench_copy_to_batch_cb, nil)
		_ = duckdb.duckdb_v2_copy_to_set_flush_callback(cfn, bench_copy_to_flush_cb, nil)
		_ = duckdb.duckdb_v2_copy_to_set_finalize_callback(cfn, bench_copy_to_finalize_cb, nil)
		_ = duckdb.duckdb_v2_copy_from_set_bind_callback(cfn, bench_copy_from_bind_cb, nil)
		_ = duckdb.duckdb_v2_copy_from_set_init_global_callback(cfn, bench_copy_from_init_global_cb, nil)
		_ = duckdb.duckdb_v2_copy_from_set_exec_callback(cfn, bench_copy_from_exec_cb, nil)
		_ = duckdb.duckdb_v2_connection_register_copy_function(g_db.conn, cfn, nil)
		_ = duckdb.v2_exec_drain(g_db.conn, "CREATE TABLE bench_copy_dest (id BIGINT, latency_ns BIGINT)")

		// Register scalar UDF `odin_arrow_roundtrip(BIGINT) -> BIGINT` for 2g Arrow Exporter/Importer benchmark
		arrow_fn: duckdb.V2_Scalar_Function_Handle
		_ = duckdb.duckdb_v2_scalar_function_create(g_db.factory, &arrow_fn, nil)
		defer duckdb.duckdb_v2_scalar_function_destroy(&arrow_fn)
		arrow_sig: duckdb.V2_Function_Signature_Handle
		_ = duckdb.duckdb_v2_scalar_function_get_signature(arrow_fn, &arrow_sig, nil)
		ap0 := duckdb.v2_str_from_string("x")
		_ = duckdb.duckdb_v2_function_signature_add_parameter(arrow_sig, &ap0, bigint_t, nil, .POSITIONAL_ONLY, nil)
		_ = duckdb.duckdb_v2_function_signature_set_return_type(arrow_sig, bigint_t, nil)
		arrow_name := duckdb.v2_str_from_string("odin_arrow_roundtrip")
		_ = duckdb.duckdb_v2_scalar_function_set_name(arrow_fn, &arrow_name, nil)
		_ = duckdb.duckdb_v2_scalar_function_set_exec_callback(arrow_fn, bench_arrow_converter_udf_cb, nil)
		_ = duckdb.duckdb_v2_connection_register_scalar_function(g_db.conn, arrow_fn, nil)

		// Register Table UDF `odin_gen_pushdown(n BIGINT)` with projection + filter pushdown for 6d
		pfn: duckdb.V2_Table_Function_Handle
		_ = duckdb.duckdb_v2_table_function_create(g_db.factory, &pfn, nil)
		defer duckdb.duckdb_v2_table_function_destroy(&pfn)
		psig: duckdb.V2_Function_Signature_Handle
		_ = duckdb.duckdb_v2_table_function_get_signature(pfn, &psig, nil)
		ppn := duckdb.v2_str_from_string("n")
		_ = duckdb.duckdb_v2_function_signature_add_parameter(psig, &ppn, bigint_t, nil, .POSITIONAL_ONLY, nil)
		pname := duckdb.v2_str_from_string("odin_gen_pushdown")
		pud := duckdb.V2_Opaque{ptr = &g_pushdown_udf_state}
		_ = duckdb.duckdb_v2_table_function_set_name(pfn, &pname, nil)
		_ = duckdb.duckdb_v2_table_function_set_user_data(pfn, &pud, nil)
		_ = duckdb.duckdb_v2_table_function_set_projection_pushdown(pfn, true, nil)
		_ = duckdb.duckdb_v2_table_function_set_bind_callback(pfn, bench_pushdown_bind_cb, nil)
		_ = duckdb.duckdb_v2_table_function_set_filter_pushdown_callback(pfn, bench_pushdown_filter_cb, nil)
		_ = duckdb.duckdb_v2_table_function_set_init_global_callback(pfn, bench_pushdown_init_global_cb, nil)
		_ = duckdb.duckdb_v2_table_function_set_exec_callback(pfn, bench_pushdown_exec_cb, nil)
		_ = duckdb.duckdb_v2_connection_register_table_function(g_db.conn, pfn, nil)

		// Register custom domain type `ODIN_NANOS` (backed by `BIGINT`) and vectorized cast `ODIN_NANOS -> DOUBLE` for 6e
		ct: duckdb.V2_Custom_Type_Handle
		_ = duckdb.duckdb_v2_custom_type_create(g_db.factory, &ct, nil)
		defer duckdb.duckdb_v2_custom_type_destroy(&ct)
		ct_name := duckdb.v2_str_from_string("ODIN_NANOS")
		_ = duckdb.duckdb_v2_custom_type_set_name(ct, &ct_name, nil)
		_ = duckdb.duckdb_v2_custom_type_set_base_type(ct, bigint_t, nil)
		_ = duckdb.duckdb_v2_connection_register_custom_type(g_db.conn, ct, nil)

		nanos_type: duckdb.V2_Logical_Type_Handle
		_ = duckdb.duckdb_v2_factory_create_type_with_alias(g_db.factory, bigint_t, &ct_name, &nanos_type, nil)
		defer duckdb.duckdb_v2_logical_type_destroy(&nanos_type)

		cast_fn: duckdb.V2_Cast_Function_Handle
		_ = duckdb.duckdb_v2_cast_function_create(g_db.factory, &cast_fn, nil)
		defer duckdb.duckdb_v2_cast_function_destroy(&cast_fn)
		_ = duckdb.duckdb_v2_cast_function_set_source_type(cast_fn, nanos_type, nil)
		_ = duckdb.duckdb_v2_cast_function_set_target_type(cast_fn, double_t, nil)
		_ = duckdb.duckdb_v2_cast_function_set_exec_callback(cast_fn, bench_cast_ns_to_ms_cb, nil)
		_ = duckdb.duckdb_v2_connection_register_cast_function(g_db.conn, cast_fn, nil)

		// Register `V2_Pragma_Function_Handle` (`odin_bench_bump`) and `V2_Custom_Option_Handle` (`odin_bench_budget`) for 6g
		pragma_fn: duckdb.V2_Pragma_Function_Handle
		_ = duckdb.duckdb_v2_pragma_function_create(g_db.factory, &pragma_fn, nil)
		defer duckdb.duckdb_v2_pragma_function_destroy(&pragma_fn)
		pragma_sig: duckdb.V2_Function_Signature_Handle
		_ = duckdb.duckdb_v2_pragma_function_get_signature(pragma_fn, &pragma_sig, nil)
		p_amounts := duckdb.v2_str_from_string("amounts")
		_ = duckdb.duckdb_v2_function_signature_add_parameter(pragma_sig, &p_amounts, bigint_t, nil, .POSITIONAL_VARIADIC, nil)
		pragma_name := duckdb.v2_str_from_string("odin_bench_bump")
		ext_ud := duckdb.V2_Opaque{ptr = &g_ext_state}
		_ = duckdb.duckdb_v2_pragma_function_set_name(pragma_fn, &pragma_name, nil)
		_ = duckdb.duckdb_v2_pragma_function_set_user_data(pragma_fn, &ext_ud, nil)
		_ = duckdb.duckdb_v2_pragma_function_set_exec_callback(pragma_fn, bench_pragma_bump_exec_cb, nil)
		_ = duckdb.duckdb_v2_connection_register_pragma_function(g_db.conn, pragma_fn, nil)

		def_budget: duckdb.V2_Value_Handle
		_ = duckdb.duckdb_v2_value_create_bigint(g_db.factory, 10, &def_budget, nil)
		defer duckdb.duckdb_v2_value_destroy(&def_budget)
		opt_fn: duckdb.V2_Custom_Option_Handle
		_ = duckdb.duckdb_v2_custom_option_create(g_db.factory, &opt_fn, nil)
		defer duckdb.duckdb_v2_custom_option_destroy(&opt_fn)
		opt_name := duckdb.v2_str_from_string("odin_bench_budget")
		_ = duckdb.duckdb_v2_custom_option_set_name(opt_fn, &opt_name, nil)
		_ = duckdb.duckdb_v2_custom_option_set_type(opt_fn, bigint_t, nil)
		_ = duckdb.duckdb_v2_custom_option_set_default_value(opt_fn, def_budget, nil)
		_ = duckdb.duckdb_v2_custom_option_set_user_data(opt_fn, &ext_ud, nil)
		_ = duckdb.duckdb_v2_custom_option_set_update_callback(opt_fn, bench_custom_option_update_cb, nil)
		_ = duckdb.duckdb_v2_connection_register_custom_option(g_db.conn, opt_fn, nil)
	}
	defer duckdb.duckdb_v2_column_data_collection_destroy(&g_collection_1m)
	defer duckdb.duckdb_v2_data_chunk_destroy(&g_collection_scan_chunk)
	defer duckdb.duckdb_v2_column_data_collection_destroy(&g_repl_collection_1k)
	defer {
		for w := 0; w < 4; w += 1 {
			duckdb.duckdb_v2_data_chunk_destroy(&g_worker_chunks[w])
		}
	}

	// Initialize VFS handle and 64 KB buffer for 8a benchmark
	_ = os.make_directory(".tmp")
	_ = duckdb.duckdb_v2_connection_get_file_system(g_db.conn, &g_vfs_fs, nil)
	g_vfs_buf_64k = make([]u8, 65536)
	for i := 0; i < len(g_vfs_buf_64k); i += 1 {
		g_vfs_buf_64k[i] = u8(i & 0xFF)
	}
	defer {
		delete(g_vfs_buf_64k)
		_ = os.remove(".tmp/odin_bench_vfs.bin")
	}

	// Initialize Quack template map for 5f benchmark
	g_quack_tpl_vars = make(map[string]string)
	g_quack_tpl_vars["server"] = "https://127.0.0.1:9999"
	g_quack_tpl_vars["alias"] = "remote_eu"
	g_quack_tpl_vars["token"] = "sec_tok_123"
	defer delete(g_quack_tpl_vars)

	// Pre-parse qname for 5e catalog `describe_table` benchmark
	qname_str := duckdb.v2_str_from_string("bench_scan_100k")
	_ = duckdb.duckdb_v2_qname_parse(&qname_str, &g_describe_qname, nil)
	defer duckdb.duckdb_v2_qname_destroy(&g_describe_qname)

	// Build a 300-token SQL script (20 statements x 15 tokens) for 5d native SQL tokenizer benchmark
	{
		tsb := strings.builder_make()
		for i := 0; i < 20; i += 1 {
			strings.write_string(&tsb, "SELECT \"my col\", 'it''s', $$d$$, 1e5, a <> b -- c\n/* d */;\n")
		}
		g_tokenize_sql_text = strings.to_string(tsb)
	}
	defer delete(g_tokenize_sql_text)

	// Pre-compile prepared statement for 7b point-lookup benchmark, 7e `Prepared_Query(T)`, and 1g `Struct_Appender(T)`
	_ = duckdb.v2_prepare(g_db.conn, "SELECT latency_ns FROM bench_scan_100k WHERE id = $1", false, &g_point_prep)
	defer duckdb.duckdb_v2_prepared_statement_destroy(&g_point_prep)

	{
		q_prep := duckdb.query_from("bench_scan_100k")
		duckdb.query_select(&q_prep, "id", "device_id", "latency_ns", "cpu_load", "healthy")
		duckdb.query_where(&q_prep, "id = $1")
		duckdb.query_limit(&q_prep, 1)
		_ = duckdb.query_prepare_as(g_db.conn, Telemetry_Row, q_prep, &g_dsl_pq)
	}
	defer duckdb.prepared_query_destroy(&g_dsl_pq)

	_ = duckdb.struct_appender_create(g_db.conn, Telemetry_Row, "bench_ingest_v2", &g_struct_appender)
	defer duckdb.struct_appender_destroy(&g_struct_appender)

	// Build a 50-directive SQLLogicTest script for 5c parser benchmark
	{
		sb := strings.builder_make()
		strings.write_string(&sb, "# SQLLogicTest benchmark script\nrequire quack\n\n")
		for i := 0; i < 24; i += 1 {
			fmt.sbprintf(&sb, "statement ok\nINSERT INTO events VALUES (%d, 'region-eu');\n\n", i)
			fmt.sbprintf(&sb, "query IT rowsort\nSELECT id, region FROM events WHERE id = %d\n----\n%d\tregion-eu\n\n", i, i)
		}
		strings.write_string(&sb, "statement error\nSELECT * FROM nonexistent_table\n----\ndoes not exist\n\n")
		g_sqllogic_script = strings.to_string(sb)
	}
	defer delete(g_sqllogic_script)

	results := make([dynamic]Bench_Result)
	defer delete(results)

	// sizeof(Telemetry_Row) on the wire ~ 8 + 12 + 8 + 8 + 1 = 37 bytes/row
	append(&results, run_timed("1a. Ingest: V2 Prepared Statement Loop (2K rows)", 2_000, 37, 5, bench_ingest_v2_prepared_2k))
	append(&results, run_timed("1b. Ingest: Legacy V1 Appender API (100K rows)", 100_000, 37, 5, bench_ingest_v1_appender_100k))
	append(&results, run_timed("1c. Ingest: V2 ColumnDataCollection `append_slice` (100K rows)", 100_000, 37, 5, bench_ingest_v2_append_slice_100k))
	append(&results, run_timed("1d. Ingest: Nullable `Maybe(T)` `append_slice` (100K rows, 25% NULL)", 100_000, 37, 5, bench_nullable_maybe_ingest_100k))
	append(&results, run_timed("1e. Ingest: Custom `V2_Copy_Function` `COPY ... FROM` (1M rows)", 1_000_000, 16, 5, bench_copy_from_1m))
	append(&results, run_timed("1f. Export: Custom `V2_Copy_Function` `COPY ... TO` Sink (1M rows)", 1_000_000, 16, 5, bench_copy_to_1m))
	append(&results, run_timed("1g. Ingest: `Struct_Appender(T)` 1K x 100-Row Micro-Batches (100K)", 100_000, 37, 5, bench_struct_appender_microbatches_100k))

	append(&results, run_timed("2a. Scan: Zero-Copy `V2_Vector_View` Flat (1M rows)", 1_000_000, 25, 7, bench_scan_v2_vector_view_1m))
	append(&results, run_timed("2b. Scan: Zero-Copy `V2_Selection_Vector` Filtered (1M source rows)", 1_000_000, 25, 7, bench_scan_selection_vector_1m))
	append(&results, run_timed("2c. Scan: Arrow C Data Interface `Arrow_Array_Stream` (1M rows)", 1_000_000, 25, 7, bench_scan_v2_arrow_stream_1m))
	append(&results, run_timed("2d. Unmarshal: `core:reflect` `query_as` Non-Null Structs (100K rows)", 100_000, 37, 5, bench_query_as_struct_100k))
	append(&results, run_timed("2e. Unmarshal: `core:reflect` `query_as` Nullable `Maybe(T)` (100K rows)", 100_000, 37, 5, bench_nullable_maybe_query_as_100k))
	append(&results, run_timed("2f. Scan: Direct `ColumnDataCollection` Worker Scan (1M rows)", 1_000_000, 16, 7, bench_scan_collection_direct_1m))
	append(&results, run_timed("2g. Bridge: `Arrow_Exporter` -> `Arrow_Importer` Round-Trip (200K)", 200_000, 16, 7, bench_arrow_exporter_importer_roundtrip_200k))
	append(&results, run_timed("2h. Scan: Multi-Worker `ColumnDataCollection` 4-Thread Scan (1M)", 1_000_000, 16, 7, bench_scan_collection_parallel_4w_1m))
	append(&results, run_timed("2i. Scan: Cooperative Stepper `v2_step_chunk` (1M rows)", 1_000_000, 25, 7, bench_scan_v2_step_chunk_1m))

	append(&results, run_timed("3a. `V2_Bytes` Write: Inline <= 12 B (`v2_vector_assign_string`, 200K)", 200_000, 12, 7, bench_v2_bytes_inline_write_200k))
	append(&results, run_timed("3b. `V2_Bytes` Write: Arena > 12 B (`v2_vector_assign_string`, 200K)", 200_000, 32, 7, bench_v2_bytes_arena_write_200k))
	append(&results, run_timed("3c. Vector Cast: `duckdb_v2_vector_cast` BIGINT -> DOUBLE (200K)", 200_000, 16, 7, bench_vector_cast_bigint_to_double_200k))
	append(&results, run_timed("3d. Zero-Copy Alias: `duckdb_v2_vector_reference` (200K rows)", 200_000, 16, 7, bench_vector_zero_copy_reference_200k))
	append(&results, run_timed("3e. Vector Flatten: `.OTHER` (`MakeSequence`) -> `.FLAT` (1M rows)", 1_000_000, 8, 7, bench_vector_sequence_flatten_1m))
	append(&results, run_timed("3f. Wire Codec: 128-Bit `HUGEINT`/`INTERVAL`/`BIT`/`BIGNUM` (200K)", 200_000, 48, 7, bench_128bit_bit_and_bignum_codec_200k))

	append(&results, run_timed("4a. JSON Tag Round-Trip: `append_slice` + `query_as` (10K structs)", 10_000, 64, 5, bench_json_tag_roundtrip_10k))
	append(&results, run_timed("4b. Native `STRUCT(...)` Child Vector Write+Read (200K structs)", 200_000, 25, 7, bench_native_struct_vector_200k))
	append(&results, run_timed("4c. Nested `LIST(BIGINT)` Vector Write+Read (200K lists / 800K items)", 200_000, 48, 7, bench_nested_list_vector_200k))
	append(&results, run_timed("4d. Fixed `ARRAY(DOUBLE, 4)` Vector Write+Read (200K arrays / 800K f64)", 200_000, 32, 7, bench_nested_array_vector_200k))
	append(&results, run_timed("4e. Composite Values: `VARIANT`/`MAP`/`UNION`/`DECIMAL` (10K ops)", 10_000, 0, 5, bench_complex_composite_types_and_variant_10k))

	append(&results, run_timed("5a. DSL: `query_to_sql` Pipeline Compilation (100K queries)", 100_000, 0, 5, bench_dsl_query_to_sql_100k))
	append(&results, run_timed("5b. Codegen: `introspect_table_schema` + Odin/CUE (1K tables)", 1_000, 0, 5, bench_schema_introspect_and_codegen_1k))
	append(&results, run_timed("5c. Parser: `sqllogic_parse_script` (50K directives / 1K scripts)", 50_000, 0, 5, bench_sqllogic_parse_50k))
	append(&results, run_timed("5d. Lexer: Native C API v2 `duckdb_v2_tokenize_sql` (300K tokens)", 300_000, 0, 5, bench_v2_tokenize_sql_300k))
	append(&results, run_timed("5e. Catalog: `duckdb_v2_connection_describe_table` (5K lookups)", 5_000, 0, 5, bench_catalog_describe_table_5k))
	append(&results, run_timed("5f. Quack: SQL Builders + URI Normalize + Template (100K ops)", 100_000, 0, 5, bench_quack_builders_uri_and_template_100k))
	append(&results, run_timed("5g. Reflection DDL: `create_table_sql` + `v2_quote_identifier` (100K)", 100_000, 0, 5, bench_ddl_create_table_and_quote_ident_100k))

	append(&results, run_timed("6a. UDF: Vectorized Scalar Callback `odin_fma` (1M rows)", 1_000_000, 24, 7, bench_udf_scalar_1m))
	append(&results, run_timed("6b. UDF: Streaming Table Function `odin_gen_series` (1M rows)", 1_000_000, 16, 7, bench_udf_table_1m))
	append(&results, run_timed("6c. UDF: Grouped Hash Aggregate `odin_agg_sum` (1M rows)", 1_000_000, 8, 7, bench_udf_aggregate_1m))
	append(&results, run_timed("6d. UDF: Table Function Projection + Filter Pushdown (1M rows)", 1_000_000, 16, 7, bench_udf_table_pushdown_1m))
	append(&results, run_timed("6e. UDF: Custom Type & Vectorized `V2_Cast_Function` (1M rows)", 1_000_000, 16, 7, bench_udf_custom_cast_1m))
	append(&results, run_timed("6f. UDF: `V2_Replacement_Scan` Virtual Table Scan (1K queries)", 1_000, 0, 5, bench_replacement_scan_collection_1k))
	append(&results, run_timed("6g. Extensibility: `V2_Pragma` + `V2_Custom_Option` + `V2_Macro` (1K)", 1_000, 0, 5, bench_pragma_custom_option_and_macro_1k))

	append(&results, run_timed("7a. Point Lookup: Ad-Hoc `v2_query` Parse+Bind+Exec (1K queries)", 1_000, 0, 5, bench_point_lookup_adhoc_1k))
	append(&results, run_timed("7b. Point Lookup: Pre-Compiled `v2_prepared_execute` (1K queries)", 1_000, 0, 5, bench_point_lookup_prepared_1k))
	append(&results, run_timed("7c. DSL Pipeline: `query_execute_as` Build+Bind+Unmarshal (1K)", 1_000, 37, 5, bench_dsl_query_execute_as_1k))
	append(&results, run_timed("7d. Transactions: `v2_with_transaction` Commit + Rollback (1K tx)", 1_000, 0, 5, bench_v2_with_transaction_1k))
	append(&results, run_timed("7e. Prepared DSL: `prepared_query_execute_as` Cached Plan+Schema (1K)", 1_000, 37, 5, bench_dsl_prepared_query_execute_as_1k))

	append(&results, run_timed("8a. VFS: Positional `write_at` + `read_at` (1K x 64 KB = 64 MB)", 1_000, 65536, 5, bench_vfs_positional_io_1k))
	append(&results, run_timed("8b. Telemetry: `V2_Query_Metrics` Tree + `V2_Log_Sink` (10K ops)", 10_000, 0, 5, bench_query_metrics_and_log_sink_10k))

	print_results_table(results[:])
}
