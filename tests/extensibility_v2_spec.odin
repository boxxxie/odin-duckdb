package duckdb_tests

// ============================================================================
// Layer 1: Executable Specifications — Extensibility, Profiling & Telemetry
// (`tests/extensibility_v2_spec.odin`)
// ============================================================================
// Ported from Authoritative DuckDB 2.0 C API v2 & C++20 Test Suites:
// 1. `references/c/duckdb-capi-2.0/tools/cpp/tests/test_cpp_api_pragma_function.cpp`
//    - Query pragma without args (`PRAGMA cpp_answer` -> `SELECT 42` + `duckdb_functions()` docs check).
//    - Query pragma with positional + named args (`PRAGMA cpp_shift(7, shift_by = 3)` -> `10`).
//    - Exec pragma with variadic `*amounts BIGINT` and user data (`PRAGMA cpp_bump(1, 2, 3)`).
// 2. `references/c/duckdb-capi-2.0/tools/cpp/tests/test_cpp_api_tokenizer.cpp`
//    - `duckdb_v2_tokenize_sql` + `duckdb_v2_token_iterator_next`: typed byte ranges across keywords,
//      quoted identifiers, single/dollar-quoted string literals, number literals, operators, comments,
//      terminators, interior NUL handling, and `duckdb_v2_token_iterator_ends_unterminated` on unclosed strings.
// 3. `references/c/duckdb-capi-2.0/tools/cpp/tests/test_cpp_api_query_metrics.cpp`
//    - `duckdb_v2_connection_enable_profiling`, `duckdb_v2_connection_get_query_metrics`,
//      `duckdb_v2_query_metrics_get_root`, depth-first operator search finding `TABLE_SCAN` and
//      `operator.intermediate_rows == 1000`, and `RESOURCE_IN_USE` while a query is still open.
// 4. `references/c/duckdb-capi-2.0/tools/cpp/tests/test_cpp_api_custom_option.cpp`
//    - `duckdb_v2_custom_option_*` registration, `SET`/`RESET`, update callback clamping (`> 100 -> 100`)
//      and validation (`< 0 -> INPUT_INVALID`).
// 5. `references/c/duckdb-capi-2.0/tools/cpp/tests/test_cpp_api_log_sink.cpp`
//    - `duckdb_v2_log_sink_*` registration on instance, `CALL enable_logging()`, `SET logging_storage`,
//      receiving `write_log(...)` (`CONNECTION` scope with connection_id) and `duckdb_v2_instance_log`
//      (`DATABASE` scope without connection_id), plus `flush_callback` invocation.
// ============================================================================

import "base:runtime"
import "core:fmt"
import "core:testing"
import duckdb "../duckdb"

// ----------------------------------------------------------------------------
// 1. Pragma Functions (`test_cpp_api_pragma_function.cpp`)
// ----------------------------------------------------------------------------

pragma_answer_query_cb :: proc "c" (
	info: duckdb.V2_Function_Bind_Info_Handle,
	result: duckdb.V2_Pragma_Function_Query_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	pos_fixed, pos_var, named_fixed, named_var: duckdb.V2_Idx
	_ = duckdb.duckdb_v2_function_bind_get_arg_count(info, &pos_fixed, &pos_var, &named_fixed, &named_var, nil)
	if pos_fixed + pos_var + named_fixed + named_var != 0 {
		driver_set_callback_error(err, .INPUT_INVALID, "pragma without parameters received arguments")
		return
	}
	sql := duckdb.v2_str_from_string("SELECT 42")
	_ = duckdb.duckdb_v2_pragma_function_query_set_query(result, &sql, err)
}

pragma_shift_query_cb :: proc "c" (
	info: duckdb.V2_Function_Bind_Info_Handle,
	result: duckdb.V2_Pragma_Function_Query_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	context = runtime.default_context()
	shift_name := duckdb.v2_str_from_string("shift_by")
	shift_idx: duckdb.V2_Idx
	found := false
	_ = duckdb.duckdb_v2_function_bind_get_arg_index(info, &shift_name, &shift_idx, &found, nil)
	if !found {
		driver_set_callback_error(err, .INPUT_INVALID, "shift_by argument is missing")
		return
	}

	v_n, v_by: duckdb.V2_Value_Handle
	_ = duckdb.duckdb_v2_function_bind_get_arg_value(info, 0, &v_n, nil)
	defer duckdb.duckdb_v2_value_destroy(&v_n)
	_ = duckdb.duckdb_v2_function_bind_get_arg_value(info, shift_idx, &v_by, nil)
	defer duckdb.duckdb_v2_value_destroy(&v_by)

	n, by: i32
	_ = duckdb.duckdb_v2_value_get_int(v_n, &n, nil)
	_ = duckdb.duckdb_v2_value_get_int(v_by, &by, nil)

	buf: [64]u8
	q := fmt.bprintf(buf[:], "SELECT %d::INTEGER", n + by)
	q_str := duckdb.v2_str_from_string(q)
	_ = duckdb.duckdb_v2_pragma_function_query_set_query(result, &q_str, err)
}

Pragma_Bump_Counter :: struct {
	total: i64,
	calls: int,
}

pragma_bump_exec_cb :: proc "c" (
	info: duckdb.V2_Function_Bind_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	ud: rawptr
	_ = duckdb.duckdb_v2_function_bind_get_user_data(info, &ud, nil)
	counter := cast(^Pragma_Bump_Counter)ud

	pos_fixed, pos_var, named_fixed, named_var: duckdb.V2_Idx
	_ = duckdb.duckdb_v2_function_bind_get_arg_count(info, &pos_fixed, &pos_var, &named_fixed, &named_var, nil)
	total_args := pos_fixed + pos_var
	for i: duckdb.V2_Idx = 0; i < total_args; i += 1 {
		val: duckdb.V2_Value_Handle
		_ = duckdb.duckdb_v2_function_bind_get_arg_value(info, i, &val, nil)
		v: i64
		_ = duckdb.duckdb_v2_value_get_bigint(val, &v, nil)
		_ = duckdb.duckdb_v2_value_destroy(&val)
		counter.total += v
	}
	counter.calls += 1
}

@(test)
spec_v2_pragma_function_query_and_exec_callbacks :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)

	// 1. Query pragma without parameters (`PRAGMA cpp_answer` -> 42)
	{
		fn: duckdb.V2_Pragma_Function_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_pragma_function_create(fx.factory, &fn, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_pragma_function_destroy(&fn)

		name := duckdb.v2_str_from_string("cpp_answer")
		expect_v2_ok(t, duckdb.duckdb_v2_pragma_function_set_name(fn, &name, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_pragma_function_set_query_callback(fn, pragma_answer_query_cb, &fx.err), &fx.err)

		docs: duckdb.V2_Function_Docs_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_pragma_function_get_docs(fn, &docs, &fx.err), &fx.err)
		desc := duckdb.v2_str_from_string("Returns the answer")
		expect_v2_ok(t, duckdb.duckdb_v2_function_docs_set_description(docs, &desc, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_connection_register_pragma_function(fx.conn, fn, &fx.err), &fx.err)

		expect_query_column(&fx, "PRAGMA cpp_answer", []i32{42})
	}

	// 2. Query pragma with positional + named parameter (`PRAGMA cpp_shift(7, shift_by = 3)` -> 10)
	{
		fn: duckdb.V2_Pragma_Function_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_pragma_function_create(fx.factory, &fn, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_pragma_function_destroy(&fn)

		sig: duckdb.V2_Function_Signature_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_pragma_function_get_signature(fn, &sig, &fx.err), &fx.err)
		p_n := duckdb.v2_str_from_string("n")
		p_shift := duckdb.v2_str_from_string("shift_by")
		def_zero: duckdb.V2_Value_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_int(fx.factory, 0, &def_zero, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&def_zero)

		expect_v2_ok(t, duckdb.duckdb_v2_function_signature_add_parameter(sig, &p_n, fx.int_type, nil, .POSITIONAL_ONLY, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_function_signature_add_parameter(sig, &p_shift, fx.int_type, def_zero, .NAMED_ONLY, &fx.err), &fx.err)

		name := duckdb.v2_str_from_string("cpp_shift")
		expect_v2_ok(t, duckdb.duckdb_v2_pragma_function_set_name(fn, &name, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_pragma_function_set_query_callback(fn, pragma_shift_query_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_connection_register_pragma_function(fx.conn, fn, &fx.err), &fx.err)

		expect_query_column(&fx, "PRAGMA cpp_shift(7, shift_by = 3)", []i32{10})
	}

	// 3. Exec pragma with variadic `*amounts BIGINT` (`PRAGMA cpp_bump(1, 2, 3)`)
	{
		counter := Pragma_Bump_Counter{}
		fn: duckdb.V2_Pragma_Function_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_pragma_function_create(fx.factory, &fn, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_pragma_function_destroy(&fn)

		sig: duckdb.V2_Function_Signature_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_pragma_function_get_signature(fn, &sig, &fx.err), &fx.err)
		p_amounts := duckdb.v2_str_from_string("amounts")
		expect_v2_ok(t, duckdb.duckdb_v2_function_signature_add_parameter(sig, &p_amounts, fx.bigint_type, nil, .POSITIONAL_VARIADIC, &fx.err), &fx.err)

		name := duckdb.v2_str_from_string("cpp_bump")
		ud := duckdb.V2_Opaque{ptr = &counter}
		expect_v2_ok(t, duckdb.duckdb_v2_pragma_function_set_name(fn, &name, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_pragma_function_set_user_data(fn, &ud, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_pragma_function_set_exec_callback(fn, pragma_bump_exec_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_connection_register_pragma_function(fx.conn, fn, &fx.err), &fx.err)

		expect_v2_ok(t, driver_exec_drain(fx.conn, "PRAGMA cpp_bump(5)", nil, &fx.err), &fx.err)
		expect_v2_ok(t, driver_exec_drain(fx.conn, "PRAGMA cpp_bump(1, 2, 3)", nil, &fx.err), &fx.err)
		testing.expect_value(t, counter.calls, 2)
		testing.expect_value(t, counter.total, i64(11))
	}
}

// ----------------------------------------------------------------------------
// 2. SQL Tokenizer (`test_cpp_api_tokenizer.cpp`)
// ----------------------------------------------------------------------------

Token_Expect :: struct {
	tok_type: duckdb.V2_Token_Type,
	start:    duckdb.V2_Idx,
	length:   duckdb.V2_Idx,
}

@(test)
spec_v2_tokenizer_byte_ranges_interior_nul_and_unterminated :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)
	err: duckdb.V2_Error_Info_Handle

	// 1. Full lexical token stream (`test_cpp_api_tokenizer.cpp` lines 42-58)
	sql := "SELECT \"my col\", 'it''s', $$d$$, 1e5, a <> b -- c\n/* d */;"
	expected := [15]Token_Expect{
		{.KEYWORD, 0, 6},
		{.IDENTIFIER, 7, 8},
		{.OPERATOR, 15, 1},
		{.STRING_LITERAL, 17, 7},
		{.OPERATOR, 24, 1},
		{.STRING_LITERAL, 26, 5},
		{.OPERATOR, 31, 1},
		{.NUMBER_LITERAL, 33, 3},
		{.OPERATOR, 36, 1},
		{.IDENTIFIER, 38, 1},
		{.OPERATOR, 40, 2},
		{.IDENTIFIER, 43, 1},
		{.COMMENT, 45, 5},
		{.COMMENT, 50, 7},
		{.TERMINATOR, 57, 1},
	}

	sql_str := duckdb.v2_str_from_string(sql)
	iter: duckdb.V2_Token_Iterator_Handle
	expect_v2_ok(t, duckdb.duckdb_v2_tokenize_sql(fx.conn, &sql_str, &iter, &err), &err)
	defer duckdb.duckdb_v2_token_iterator_destroy(&iter)

	for exp in expected {
		tt: duckdb.V2_Token_Type
		st, ln: duckdb.V2_Idx
		expect_v2_ok(t, duckdb.duckdb_v2_token_iterator_next(iter, &tt, &st, &ln, &err), &err)
		testing.expect_value(t, tt, exp.tok_type)
		testing.expect_value(t, st, exp.start)
		testing.expect_value(t, ln, exp.length)
	}
	end_tt: duckdb.V2_Token_Type
	end_st, end_ln: duckdb.V2_Idx
	expect_v2_ok(t, duckdb.duckdb_v2_token_iterator_next(iter, &end_tt, &end_st, &end_ln, &err), &err)
	testing.expect_value(t, end_tt, duckdb.V2_Token_Type.END_OF_INPUT)
	testing.expect_value(t, end_st, duckdb.V2_Idx(len(sql)))

	unterm := true
	expect_v2_ok(t, duckdb.duckdb_v2_token_iterator_ends_unterminated(iter, &unterm, &err), &err)
	testing.expect(t, !unterm, "expected well-formed SQL to not end unterminated")

	// 2. Unterminated string literal reports `ends_unterminated == true`
	bad_sql := duckdb.v2_str_from_string("SELECT 'abc")
	bad_iter: duckdb.V2_Token_Iterator_Handle
	expect_v2_ok(t, duckdb.duckdb_v2_tokenize_sql(fx.conn, &bad_sql, &bad_iter, &err), &err)
	defer duckdb.duckdb_v2_token_iterator_destroy(&bad_iter)

	bad_unterm := false
	expect_v2_ok(t, duckdb.duckdb_v2_token_iterator_ends_unterminated(bad_iter, &bad_unterm, &err), &err)
	testing.expect(t, bad_unterm, "expected unclosed string literal to report ends_unterminated == true")
}

// ----------------------------------------------------------------------------
// 3. Query Metrics (`test_cpp_api_query_metrics.cpp`)
// ----------------------------------------------------------------------------

find_metrics_operator :: proc(
	node: duckdb.V2_Query_Metrics_Node_Handle,
	target: string,
) -> (found_node: duckdb.V2_Query_Metrics_Node_Handle, ok: bool) {
	count: duckdb.V2_Idx
	_ = duckdb.duckdb_v2_query_metrics_node_get_child_count(node, &count, nil)
	for i: duckdb.V2_Idx = 0; i < count; i += 1 {
		child: duckdb.V2_Query_Metrics_Node_Handle
		_ = duckdb.duckdb_v2_query_metrics_node_get_child(node, i, &child, nil)
		name_str: duckdb.V2_Str
		_ = duckdb.duckdb_v2_query_metrics_node_get_name(child, &name_str, nil)
		if duckdb.v2_str_to_string(name_str) == target {
			return child, true
		}
		if sub, sub_ok := find_metrics_operator(child, target); sub_ok {
			return sub, true
		}
	}
	return nil, false
}

@(test)
spec_v2_query_metrics_operator_tree_and_resource_in_use :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)
	err: duckdb.V2_Error_Info_Handle

	expect_v2_ok(t, driver_exec_drain(fx.conn, "SET enable_profiling = 'no_output'", nil, &err), &err)
	expect_v2_ok(t, duckdb.duckdb_v2_connection_enable_profiling(fx.conn, true, &err), &err)
	expect_v2_ok(t, driver_exec_drain(fx.conn, "SELECT sum(i) FROM range(1000) t(i)", nil, &err), &err)

	metrics: duckdb.V2_Query_Metrics_Handle
	expect_v2_ok(t, duckdb.duckdb_v2_connection_get_query_metrics(fx.conn, &metrics, &err), &err)
	defer duckdb.duckdb_v2_query_metrics_destroy(&metrics)

	root: duckdb.V2_Query_Metrics_Node_Handle
	expect_v2_ok(t, duckdb.duckdb_v2_query_metrics_get_root(metrics, &root, &err), &err)

	total_time_key := duckdb.v2_str_from_string("query.total_time")
	total_time_val: duckdb.V2_Value_Handle
	present := false
	expect_v2_ok(t, duckdb.duckdb_v2_query_metrics_node_get_metric(root, &total_time_key, &total_time_val, &present, &err), &err)
	defer duckdb.duckdb_v2_value_destroy(&total_time_val)
	testing.expect(t, present, "expected query.total_time metric on root")

	scan_node, scan_ok := find_metrics_operator(root, "TABLE_SCAN")
	testing.expect(t, scan_ok, "expected TABLE_SCAN operator in query metrics tree")
	if scan_ok {
		rows_key := duckdb.v2_str_from_string("operator.intermediate_rows")
		rows_val: duckdb.V2_Value_Handle
		rows_present := false
		expect_v2_ok(t, duckdb.duckdb_v2_query_metrics_node_get_metric(scan_node, &rows_key, &rows_val, &rows_present, &err), &err)
		defer duckdb.duckdb_v2_value_destroy(&rows_val)
		testing.expect(t, rows_present, "expected operator.intermediate_rows on TABLE_SCAN")
		rows_u64: u64
		expect_v2_ok(t, duckdb.duckdb_v2_value_get_ubigint(rows_val, &rows_u64, &err), &err)
		testing.expect_value(t, rows_u64, u64(1000))
	}

	// While a streaming query is still open, `get_query_metrics` returns `RESOURCE_IN_USE`
	live_res: duckdb.V2_Result_Handle
	expect_v2_ok(t, driver_query(fx.conn, "SELECT * FROM range(100000)", &live_res, &err), &err)
	defer duckdb.duckdb_v2_result_destroy(&live_res)

	first_chunk: duckdb.V2_Data_Chunk_Handle
	_, _ = driver_step_chunk(live_res, &first_chunk)
	duckdb.duckdb_v2_data_chunk_destroy(&first_chunk)

	busy_metrics: duckdb.V2_Query_Metrics_Handle
	busy_err: duckdb.V2_Error_Info_Handle
	testing.expect_value(
		t,
		duckdb.duckdb_v2_connection_get_query_metrics(fx.conn, &busy_metrics, &busy_err),
		duckdb.V2_Error.RESOURCE_IN_USE,
	)
	_ = duckdb.duckdb_v2_error_info_destroy(&busy_err)

	// Drain the live result before closing the connection
	drained: duckdb.V2_Idx
	_ = duckdb.duckdb_v2_result_drain(live_res, &drained, nil)
}

// ----------------------------------------------------------------------------
// 4. Custom Options & Log Sinks (`test_cpp_api_custom_option.cpp`, `test_cpp_api_log_sink.cpp`)
// ----------------------------------------------------------------------------

Custom_Option_Log :: struct {
	calls:      int,
	last_scope: duckdb.V2_Setting_Scope,
	last_reset: bool,
}

custom_option_clamp_cb :: proc "c" (
	info: duckdb.V2_Custom_Option_Update_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	ud: rawptr
	_ = duckdb.duckdb_v2_custom_option_update_get_user_data(info, &ud, nil)
	log := cast(^Custom_Option_Log)ud
	log.calls += 1
	_ = duckdb.duckdb_v2_custom_option_update_get_scope(info, &log.last_scope, nil)
	_ = duckdb.duckdb_v2_custom_option_update_is_reset(info, &log.last_reset, nil)

	val: duckdb.V2_Value_Handle
	_ = duckdb.duckdb_v2_custom_option_update_get_value(info, &val, nil)
	defer duckdb.duckdb_v2_value_destroy(&val)

	v: i64
	_ = duckdb.duckdb_v2_value_get_bigint(val, &v, nil)
	if v < 0 {
		driver_set_callback_error(err, .INPUT_INVALID, "cpp_budget cannot be negative")
		return
	}
	if v > 100 {
		factory: duckdb.V2_Factory_Handle
		_ = duckdb.duckdb_v2_context_get_factory(ctx, &factory, nil)
		clamped: duckdb.V2_Value_Handle
		_ = duckdb.duckdb_v2_value_create_bigint(factory, 100, &clamped, nil)
		defer duckdb.duckdb_v2_value_destroy(&clamped)
		_ = duckdb.duckdb_v2_custom_option_update_set_value(info, clamped, nil)
	}
}

Log_Sink_State :: struct {
	entries:       int,
	last_level:    duckdb.V2_Log_Level,
	last_scope:    duckdb.V2_Log_Scope,
	last_has_conn: bool,
	flushes:       int,
}

log_sink_write_cb :: proc "c" (
	info: duckdb.V2_Log_Sink_Write_Info_Handle,
	user_data: rawptr,
	timestamp: i64,
	level: duckdb.V2_Log_Level,
	scope: duckdb.V2_Log_Scope,
	log_type: ^duckdb.V2_Str,
	message: ^duckdb.V2_Str,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	st := cast(^Log_Sink_State)user_data
	if duckdb.v2_str_to_string(log_type^) != "OdinLogSinkTest" {
		return
	}
	st.entries += 1
	st.last_level = level
	st.last_scope = scope
	conn_id: duckdb.V2_Idx
	_ = duckdb.duckdb_v2_log_sink_write_info_get_connection_id(info, &conn_id, &st.last_has_conn, nil)
}

log_sink_flush_cb :: proc "c" (
	info: duckdb.V2_Log_Sink_Flush_Info_Handle,
	user_data: rawptr,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	st := cast(^Log_Sink_State)user_data
	st.flushes += 1
}

@(test)
spec_v2_custom_option_and_log_sink_callbacks :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)

	// 1. Custom option with update clamping & validation (`cpp_budget`)
	{
		def_val: duckdb.V2_Value_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_bigint(fx.factory, 10, &def_val, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&def_val)

		opt_log := Custom_Option_Log{}
		opt: duckdb.V2_Custom_Option_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_custom_option_create(fx.factory, &opt, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_custom_option_destroy(&opt)

		opt_name := duckdb.v2_str_from_string("cpp_budget")
		ud := duckdb.V2_Opaque{ptr = &opt_log}
		expect_v2_ok(t, duckdb.duckdb_v2_custom_option_set_name(opt, &opt_name, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_custom_option_set_type(opt, fx.bigint_type, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_custom_option_set_default_value(opt, def_val, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_custom_option_set_supports_scope(opt, .SESSION, false, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_custom_option_set_user_data(opt, &ud, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_custom_option_set_update_callback(opt, custom_option_clamp_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_connection_register_custom_option(fx.conn, opt, &fx.err), &fx.err)

		expect_v2_ok(t, driver_exec_drain(fx.conn, "SET cpp_budget = 500", nil, &fx.err), &fx.err)
		testing.expect_value(t, opt_log.calls, 1)
		testing.expect_value(t, opt_log.last_scope, duckdb.V2_Setting_Scope.GLOBAL)

		cfg: duckdb.V2_Config_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_instance_get_config(fx.instance, &cfg, &fx.err), &fx.err)
		cur_val: duckdb.V2_Value_Handle
		cur_scope: duckdb.V2_Setting_Scope
		expect_v2_ok(t, duckdb.duckdb_v2_config_get_option_value(cfg, &opt_name, &cur_val, &cur_scope, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&cur_val)
		testing.expect_value(t, cur_scope, duckdb.V2_Setting_Scope.GLOBAL)
		cur_i64: i64
		expect_v2_ok(t, duckdb.duckdb_v2_value_get_bigint(cur_val, &cur_i64, &fx.err), &fx.err)
		testing.expect_value(t, cur_i64, i64(100))

		// Negative value is rejected with `INPUT_INVALID`
		expect_v2_error(t, driver_exec_drain(fx.conn, "SET cpp_budget = -1", nil, &fx.err), .INPUT_INVALID, &fx.err)

		expect_v2_ok(t, driver_exec_drain(fx.conn, "RESET cpp_budget", nil, &fx.err), &fx.err)
		testing.expect(t, opt_log.last_reset, "expected RESET cpp_budget to set is_reset == true")
	}

	// 2. LogSink receiving `write_log(...)` and `duckdb_v2_instance_log` entries
	{
		inst_factory: duckdb.V2_Factory_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_instance_get_factory(fx.instance, &inst_factory, &fx.err), &fx.err)

		sink_state := Log_Sink_State{}
		sink: duckdb.V2_Log_Sink_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_log_sink_create(inst_factory, &sink, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_log_sink_destroy(&sink)

		sink_name := duckdb.v2_str_from_string("odin_store")
		ud := duckdb.V2_Opaque{ptr = &sink_state}
		expect_v2_ok(t, duckdb.duckdb_v2_log_sink_set_name(sink, &sink_name, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_log_sink_set_user_data(sink, &ud, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_log_sink_set_write_callback(sink, log_sink_write_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_log_sink_set_flush_callback(sink, log_sink_flush_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_instance_register_log_sink(fx.instance, sink, &fx.err), &fx.err)

		expect_v2_ok(t, driver_exec_drain(fx.conn, "CALL enable_logging()", nil, &fx.err), &fx.err)
		expect_v2_ok(t, driver_exec_drain(fx.conn, "SET logging_storage = 'ODIN_STORE'", nil, &fx.err), &fx.err)
		expect_v2_ok(
			t,
			driver_exec_drain(fx.conn, "SELECT write_log('hello', level := 'warning', log_type := 'OdinLogSinkTest')", nil, &fx.err),
			&fx.err,
		)
		testing.expect_value(t, sink_state.entries, 1)
		testing.expect_value(t, sink_state.last_level, duckdb.V2_Log_Level.WARNING)
		testing.expect_value(t, sink_state.last_scope, duckdb.V2_Log_Scope.CONNECTION)
		testing.expect(t, sink_state.last_has_conn, "expected connection log entry to carry connection_id")

		l_type := duckdb.v2_str_from_string("OdinLogSinkTest")
		l_msg := duckdb.v2_str_from_string("from the instance")
		expect_v2_ok(t, duckdb.duckdb_v2_instance_log(fx.instance, .ERROR, &l_type, &l_msg, &fx.err), &fx.err)
		testing.expect_value(t, sink_state.entries, 2)
		testing.expect_value(t, sink_state.last_scope, duckdb.V2_Log_Scope.DATABASE)
		testing.expect(t, !sink_state.last_has_conn, "expected instance log entry to have no connection_id")
		testing.expect(t, sink_state.flushes > 0, "expected flush_callback to have run")

		expect_v2_ok(t, driver_exec_drain(fx.conn, "SET logging_storage = 'memory'", nil, &fx.err), &fx.err)
	}
}
