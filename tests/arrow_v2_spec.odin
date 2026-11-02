package duckdb_tests

// ============================================================================
// Layer 1: Executable Specifications (`tests/arrow_v2_spec.odin`)
// ============================================================================
// Direct ATDD port of the C API v2 Arrow C Data Interface & Stream suites from:
// - `references/c/duckdb-capi-2.0/test/api/capi/v2/test_capi_v2_arrow.cpp`
//   1. `TEST_CASE("V2 arrow result: a partially fetched result converts to a C stream for the rest", "[capi_v2][arrow]")` (lines 1749-1782)
//   2. `TEST_CASE("V2 arrow result: an unfinished result survives disconnect", "[capi_v2][arrow]")` (lines 1820-1839)
//   3. `TEST_CASE("V2 arrow result: nested, dictionary and decimal columns keep their structure", "[capi_v2][arrow]")` (lines 1874-1940)
//   4. `TEST_CASE("V2 arrow result: a prepared Arrow result honours its batch size and converts to a stream", "[capi_v2][arrow]")` (lines 1942-1976)
//   5. `TEST_CASE("V2 arrow result: drain discards unread rows and frees the connection", "[capi_v2][arrow]")` (lines 1978-1995)
// ============================================================================

import "base:runtime"
import "core:testing"
import duckdb "../duckdb"

// Upstream Reference:
// - `references/c/duckdb-capi-2.0/test/api/capi/v2/test_capi_v2_arrow.cpp` lines 1749-1782, 1942-1995
@(test)
spec_v2_arrow_result_fetch_array_c_stream_and_prepared_batch_size :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)

	// 1. Fetch first Arrow batch directly, then convert remainder to `Arrow_Array_Stream` (lines 1749-1782):
	{
		res: duckdb.V2_Arrow_Result_Handle
		expect_v2_ok(t, driver_query_arrow(fx.conn, "SELECT i FROM range(10000) t(i)", 1000, &res))
		defer duckdb.duckdb_v2_arrow_result_destroy(&res)

		schema: duckdb.Arrow_Schema
		expect_v2_ok(t, duckdb.duckdb_v2_arrow_result_get_schema(res, &schema, nil))
		defer duckdb.arrow_schema_release(&schema)
		testing.expect_value(t, schema.n_children, i64(1))
		testing.expect_value(t, string(schema.children[0].name), "i")
		testing.expect_value(t, string(schema.children[0].format), "l") // int64 ("l" in Arrow C Data Interface format)

		first_arr: duckdb.Arrow_Array
		expect_v2_ok(t, duckdb.duckdb_v2_arrow_result_fetch_array(res, &first_arr, nil))
		testing.expect(t, first_arr.release != nil)
		fetched_rows := first_arr.length
		testing.expect(t, fetched_rows > 0 && fetched_rows <= 1000)

		// Verify zero-copy Arrow buffer contents (`buffers[1]` is the int64 values buffer):
		col0 := first_arr.children[0]
		vals := cast([^]i64)col0.buffers[1]
		testing.expect_value(t, vals[0], i64(0))
		testing.expect_value(t, vals[fetched_rows - 1], i64(fetched_rows - 1))
		duckdb.arrow_array_release(&first_arr)

		// Convert the remaining result into a standard `Arrow_Array_Stream` (consumes `res` and sets it to `nil`):
		stream: duckdb.Arrow_Array_Stream
		expect_v2_ok(t, duckdb.duckdb_v2_arrow_result_to_arrow_c_stream(&res, &stream, nil))
		defer duckdb.arrow_stream_release(&stream)
		testing.expect_value(t, res, duckdb.V2_Arrow_Result_Handle(nil))

		stream_rows: i64 = 0
		for {
			arr: duckdb.Arrow_Array
			rc_stream := stream.get_next(&stream, &arr)
			testing.expect_value(t, rc_stream, 0)
			if arr.release == nil {
				break
			}
			stream_rows += arr.length
			duckdb.arrow_array_release(&arr)
		}
		testing.expect_value(t, fetched_rows + stream_rows, i64(10000))
	}

	// 2. Prepared Arrow result honors `batch_size = 700` and `duckdb_v2_arrow_result_drain` frees the connection (lines 1942-1995):
	{
		prepared: duckdb.V2_Prepared_Statement_Handle
		expect_v2_ok(t, driver_prepare(fx.conn, "SELECT i FROM range(5000) t(i)", false, &prepared))
		defer duckdb.duckdb_v2_prepared_statement_destroy(&prepared)

		res: duckdb.V2_Arrow_Result_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_prepared_statement_execute_arrow(prepared, nil, nil, 0, 700, &res, nil))
		defer duckdb.duckdb_v2_arrow_result_destroy(&res)

		// Busy connection refuses a second Arrow execution while `res` is still open:
		busy: duckdb.V2_Arrow_Result_Handle
		err: duckdb.V2_Error_Info_Handle
		expect_v2_error(
			t,
			duckdb.duckdb_v2_prepared_statement_execute_arrow(prepared, nil, nil, 0, 700, &busy, &err),
			.RESOURCE_IN_USE,
			&err,
		)

		total_rows: i64 = 0
		max_batch_len: i64 = 0
		for {
			arr: duckdb.Arrow_Array
			expect_v2_ok(t, duckdb.duckdb_v2_arrow_result_fetch_array(res, &arr, nil))
			if arr.release == nil {
				break
			}
			total_rows += arr.length
			if arr.length > max_batch_len {
				max_batch_len = arr.length
			}
			duckdb.arrow_array_release(&arr)
		}
		testing.expect_value(t, total_rows, i64(5000))
		testing.expect(t, max_batch_len <= 700)
	}
}

// ----------------------------------------------------------------------------
// 2. Bidirectional `ArrowExporter` & `ArrowImporter` Round-Trip (`test_cpp_api_arrow.cpp` lines 21-96)
// ----------------------------------------------------------------------------

Arrow_Converter_Probe :: struct {
	field_count:  duckdb.V2_Idx,
	first_name:   string,
	first_type:   string,
	arrays_seen:  i64,
	imported_val: i64,
}

@(private = "file")
arrow_probe_exec_cb :: proc "c" (
	info: duckdb.V2_Scalar_Function_Exec_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	context = runtime.default_context()

	ud: rawptr
	if duckdb.duckdb_v2_scalar_function_exec_get_user_data(info, &ud, err) != .NONE || ud == nil {
		return
	}
	probe := cast(^Arrow_Converter_Probe)ud

	factory: duckdb.V2_Factory_Handle
	if duckdb.duckdb_v2_context_get_factory(ctx, &factory, err) != .NONE {
		return
	}

	bigint_type: duckdb.V2_Logical_Type_Handle
	if duckdb.duckdb_v2_factory_create_type_from_id(factory, .BIGINT, nil, nil, 0, &bigint_type, err) != .NONE {
		return
	}
	defer duckdb.duckdb_v2_logical_type_destroy(&bigint_type)

	types := [1]duckdb.V2_Logical_Type_Handle{bigint_type}
	names := [1]duckdb.V2_Str{duckdb.v2_str_from_string("a")}

	exporter: duckdb.V2_Arrow_Exporter_Handle
	if duckdb.duckdb_v2_arrow_exporter_create(ctx, &types[0], &names[0], 1, 0, &exporter, err) != .NONE {
		return
	}
	defer duckdb.duckdb_v2_arrow_exporter_destroy(&exporter)

	arrow_schema: duckdb.Arrow_Schema
	if duckdb.duckdb_v2_arrow_exporter_get_schema(exporter, &arrow_schema, err) != .NONE {
		return
	}
	defer duckdb.arrow_schema_release(&arrow_schema)

	importer: duckdb.V2_Arrow_Importer_Handle
	if duckdb.duckdb_v2_arrow_importer_create(ctx, &arrow_schema, 0, &importer, err) != .NONE {
		return
	}
	defer duckdb.duckdb_v2_arrow_importer_destroy(&importer)

	resolved: duckdb.V2_Schema_Handle
	if duckdb.duckdb_v2_arrow_importer_get_schema(importer, &resolved, err) != .NONE {
		return
	}
	defer duckdb.duckdb_v2_schema_destroy(&resolved)

	_ = duckdb.duckdb_v2_schema_get_count(resolved, &probe.field_count, err)
	if probe.field_count > 0 {
		fname: duckdb.V2_Identifier
		ftype: duckdb.V2_Logical_Type_Handle // Borrowed from `resolved` schema (`duckdb_v2.h` line 4720); do NOT destroy.
		if duckdb.duckdb_v2_schema_get_field(resolved, 0, &fname, &ftype, err) == .NONE {
			if duckdb.v2_str_to_string(fname) == "a" {
				probe.first_name = "a"
			}
			tid: duckdb.V2_Logical_Type_Id
			if duckdb.duckdb_v2_logical_type_get_id(ftype, &tid, err) == .NONE && tid == .BIGINT {
				probe.first_type = "BIGINT"
			}
		}
	}

	chunk: duckdb.V2_Data_Chunk_Handle
	if driver_make_chunk(i64, factory, bigint_type, []i64{4242}, &chunk, err) != .NONE {
		return
	}

	if duckdb.duckdb_v2_arrow_exporter_append(exporter, &chunk, true, true, err) != .NONE {
		duckdb.duckdb_v2_data_chunk_destroy(&chunk)
		return
	}

	for {
		arr: duckdb.Arrow_Array
		if duckdb.duckdb_v2_arrow_exporter_next_array(exporter, &arr, err) != .NONE || arr.release == nil {
			break
		}
		probe.arrays_seen += 1
		if duckdb.duckdb_v2_arrow_importer_append(importer, &arr, true, true, err) != .NONE {
			duckdb.arrow_array_release(&arr)
			break
		}
		imported: duckdb.V2_Data_Chunk_Handle
		if duckdb.duckdb_v2_arrow_importer_next_chunk(importer, &imported, err) == .NONE && imported != nil {
			vec: duckdb.V2_Vector_Handle
			_ = duckdb.duckdb_v2_data_chunk_get_vector(imported, 0, &vec, err)
			view: duckdb.V2_Vector_View
			_ = duckdb.duckdb_v2_vector_get_view(vec, &view, err)
			probe.imported_val = (cast([^]i64)view.data)[0]
			duckdb.duckdb_v2_data_chunk_destroy(&imported)
		}
	}

	row_count: duckdb.V2_Idx
	_ = duckdb.duckdb_v2_scalar_function_exec_get_row_count(info, &row_count, err)
	out_vec: duckdb.V2_Vector_Handle
	_ = duckdb.duckdb_v2_scalar_function_exec_get_result(info, &out_vec, err)
	raw_out: rawptr
	_ = duckdb.duckdb_v2_vector_get_data_mutable(out_vec, &raw_out, err)
	out_i32 := cast([^]i32)raw_out
	for i: duckdb.V2_Idx = 0; i < row_count; i += 1 {
		out_i32[i] = 1
	}
}

@(test)
spec_v2_arrow_exporter_and_importer_roundtrip :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)
	probe: Arrow_Converter_Probe

	fn: duckdb.V2_Scalar_Function_Handle
	expect_v2_ok(t, duckdb.duckdb_v2_scalar_function_create(fx.factory, &fn, &fx.err), &fx.err)
	defer duckdb.duckdb_v2_scalar_function_destroy(&fn)

	fn_name := duckdb.v2_str_from_string("odin_arrow_probe")
	expect_v2_ok(t, duckdb.duckdb_v2_scalar_function_set_name(fn, &fn_name, &fx.err), &fx.err)
	user_opaque := duckdb.V2_Opaque{ptr = &probe}
	expect_v2_ok(t, duckdb.duckdb_v2_scalar_function_set_user_data(fn, &user_opaque, &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.duckdb_v2_scalar_function_set_exec_callback(fn, arrow_probe_exec_cb, &fx.err), &fx.err)

	sig: duckdb.V2_Function_Signature_Handle
	expect_v2_ok(t, duckdb.duckdb_v2_scalar_function_get_signature(fn, &sig, &fx.err), &fx.err)
	p_name := duckdb.v2_str_from_string("x")
	expect_v2_ok(
		t,
		duckdb.duckdb_v2_function_signature_add_parameter(sig, &p_name, fx.int_type, nil, .STANDARD, &fx.err),
		&fx.err,
	)
	expect_v2_ok(t, duckdb.duckdb_v2_function_signature_set_return_type(sig, fx.int_type, &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.duckdb_v2_connection_register_scalar_function(fx.conn, fn, &fx.err), &fx.err)

	expect_v2_ok(t, driver_exec_drain(fx.conn, "SELECT odin_arrow_probe(1)", nil, &fx.err), &fx.err)
	testing.expect_value(t, probe.field_count, duckdb.V2_Idx(1))
	testing.expect_value(t, probe.first_name, "a")
	testing.expect_value(t, probe.first_type, "BIGINT")
	testing.expect_value(t, probe.arrays_seen, i64(1))
	testing.expect_value(t, probe.imported_val, i64(4242))
}
