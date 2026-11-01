package duckdb_tests

// ============================================================================
// Layer 1: Executable Specifications (`tests/expression_macro_v2_spec.odin`)
// ============================================================================
// Direct ATDD port of the C API v2 Expression Filter Pushdown, MacroFunction,
// MultiFileFunction & Transactional Registration suites:
// 1. `references/c/duckdb-capi-2.0/test/api/capi/v2/test_capi_v2_expression.cpp`
// 2. `references/c/duckdb-capi-2.0/test/api/capi/v2/test_capi_v2_registration.cpp`
// 3. `duckdb_v2.h` (`MODULE: macro`, `MODULE: table` multi-file)
// ============================================================================

import "base:runtime"
import "core:testing"
import duckdb "../duckdb"

// ----------------------------------------------------------------------------
// 1. Table Function Filter Pushdown & Expression AST (`test_capi_v2_expression.cpp`)
// ----------------------------------------------------------------------------

Filter_Pushdown_Probe :: struct {
	filter_count: duckdb.V2_Idx,
	root_type:    duckdb.V2_Expression_Type,
	col_index:    duckdb.V2_Idx,
	const_val:    i64,
	accepted:     bool,
	done:         bool,
}

@(private = "file")
filter_probe_bind_cb :: proc "c" (
	info: duckdb.V2_Function_Bind_Info_Handle,
	result: duckdb.V2_Table_Function_Bind_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	ud: rawptr
	_ = duckdb.duckdb_v2_function_bind_get_user_data(info, &ud, err)
	factory: duckdb.V2_Factory_Handle
	if duckdb.duckdb_v2_context_get_factory(ctx, &factory, err) != .NONE {
		return
	}
	bigint_type: duckdb.V2_Logical_Type_Handle
	if duckdb.duckdb_v2_factory_create_type_from_id(factory, .BIGINT, nil, nil, 0, &bigint_type, err) != .NONE {
		return
	}
	defer duckdb.duckdb_v2_logical_type_destroy(&bigint_type)

	c0 := duckdb.v2_str_from_string("k")
	c1 := duckdb.v2_str_from_string("v")
	_ = duckdb.duckdb_v2_table_function_bind_add_result_column(result, &c0, bigint_type, err)
	_ = duckdb.duckdb_v2_table_function_bind_add_result_column(result, &c1, bigint_type, err)

	bd := duckdb.V2_Opaque{ptr = ud}
	_ = duckdb.duckdb_v2_function_bind_set_bind_data(info, &bd, err)
}

@(private = "file")
filter_probe_pushdown_cb :: proc "c" (
	info: duckdb.V2_Table_Function_Filter_Pushdown_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	bd: rawptr
	if duckdb.duckdb_v2_table_function_filter_pushdown_get_bind_data(info, &bd, err) != .NONE || bd == nil {
		return
	}
	probe := cast(^Filter_Pushdown_Probe)bd
	if duckdb.duckdb_v2_table_function_filter_pushdown_get_filter_count(info, &probe.filter_count, err) != .NONE ||
	   probe.filter_count == 0 {
		return
	}

	expr: duckdb.V2_Expression_Handle
	if duckdb.duckdb_v2_table_function_filter_pushdown_get_filter(info, 0, &expr, err) != .NONE {
		return
	}
	_ = duckdb.duckdb_v2_expression_get_type(expr, &probe.root_type, err)

	child_count: duckdb.V2_Idx
	_ = duckdb.duckdb_v2_expression_get_child_count(expr, &child_count, err)
	if child_count == 2 {
		left, right: duckdb.V2_Expression_Handle
		_ = duckdb.duckdb_v2_expression_get_child(expr, 0, &left, err)
		_ = duckdb.duckdb_v2_expression_get_child(expr, 1, &right, err)

		ref_idx: duckdb.V2_Idx
		if duckdb.duckdb_v2_expression_column_ref_get_index(left, &ref_idx, err) == .NONE {
			_ = duckdb.duckdb_v2_table_function_filter_pushdown_get_column_index(info, ref_idx, &probe.col_index, err)
		}

		cval: duckdb.V2_Value_Handle
		if duckdb.duckdb_v2_expression_constant_get_value(right, &cval, err) == .NONE {
			_ = duckdb.duckdb_v2_value_get_bigint(cval, &probe.const_val, err)
			duckdb.duckdb_v2_value_destroy(&cval)
		}
	}

	if duckdb.duckdb_v2_table_function_filter_pushdown_accept(info, 0, err) == .NONE {
		probe.accepted = true
	}
}

@(private = "file")
filter_probe_exec_cb :: proc "c" (
	info: duckdb.V2_Table_Function_Exec_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	bd: rawptr
	if duckdb.duckdb_v2_table_function_exec_get_bind_data(info, &bd, err) != .NONE || bd == nil {
		return
	}
	probe := cast(^Filter_Pushdown_Probe)bd
	chunk: duckdb.V2_Data_Chunk_Handle
	if duckdb.duckdb_v2_table_function_exec_get_output_chunk(info, &chunk, err) != .NONE {
		return
	}
	v0, v1: duckdb.V2_Vector_Handle
	_ = duckdb.duckdb_v2_data_chunk_get_vector(chunk, 0, &v0, err)
	_ = duckdb.duckdb_v2_data_chunk_get_vector(chunk, 1, &v1, err)

	if probe.done {
		_ = duckdb.duckdb_v2_vector_set_size(v0, 0, err)
		return
	}
	probe.done = true

	r0, r1: rawptr
	_ = duckdb.duckdb_v2_vector_get_data_mutable(v0, &r0, err)
	_ = duckdb.duckdb_v2_vector_get_data_mutable(v1, &r1, err)
	(cast([^]i64)r0)[0] = 1
	(cast([^]i64)r1)[0] = probe.const_val
	_ = duckdb.duckdb_v2_vector_set_size(v0, 1, err)
	_ = duckdb.duckdb_v2_vector_set_size(v1, 1, err)
}

@(test)
spec_v2_table_function_filter_pushdown_and_expression_ast :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)

	probe := Filter_Pushdown_Probe{}
	tf: duckdb.V2_Table_Function_Handle
	expect_v2_ok(t, duckdb.duckdb_v2_table_function_create(fx.factory, &tf, &fx.err), &fx.err)
	defer duckdb.duckdb_v2_table_function_destroy(&tf)

	tf_name := duckdb.v2_str_from_string("odin_filter_probe")
	ud := duckdb.V2_Opaque{ptr = &probe}
	expect_v2_ok(t, duckdb.duckdb_v2_table_function_set_name(tf, &tf_name, &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.duckdb_v2_table_function_set_user_data(tf, &ud, &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.duckdb_v2_table_function_set_bind_callback(tf, filter_probe_bind_cb, &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.duckdb_v2_table_function_set_filter_pushdown_callback(tf, filter_probe_pushdown_cb, &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.duckdb_v2_table_function_set_exec_callback(tf, filter_probe_exec_cb, &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.duckdb_v2_connection_register_table_function(fx.conn, tf, &fx.err), &fx.err)

	expect_query_column(&fx, "SELECT v FROM odin_filter_probe() WHERE v = 77", []i64{77})
	testing.expect_value(t, probe.filter_count, duckdb.V2_Idx(1))
	testing.expect_value(t, probe.root_type, duckdb.V2_Expression_Type.COMPARE_EQUAL)
	testing.expect_value(t, probe.col_index, duckdb.V2_Idx(1)) // column `v` is declared column index 1
	testing.expect_value(t, probe.const_val, i64(77))
	testing.expect(t, probe.accepted)
}

// ----------------------------------------------------------------------------
// 2. MacroFunction, MultiFileFunction & Transactional Registration (`test_capi_v2_registration.cpp`)
// ----------------------------------------------------------------------------

@(test)
spec_v2_macro_function_multi_file_and_transaction_registration :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)

	// 1. MacroFunction builder lifecycle (`MODULE: macro`, `duckdb_v2.h` lines 9471-9605):
	{
		macro: duckdb.V2_Macro_Function_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_macro_function_create(fx.factory, .SCALAR, &macro, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_macro_function_destroy(&macro)

		m_name := duckdb.v2_str_from_string("odin_double_plus")
		m_body := duckdb.v2_str_from_string("x * 2 + y")
		expect_v2_ok(t, duckdb.duckdb_v2_macro_function_set_name(macro, &m_name, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_macro_function_set_body(macro, &m_body, &fx.err), &fx.err)

		sig: duckdb.V2_Function_Signature_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_macro_function_get_signature(macro, &sig, &fx.err), &fx.err)
		px := duckdb.v2_str_from_string("x")
		py := duckdb.v2_str_from_string("y")
		expect_v2_ok(
			t,
			duckdb.duckdb_v2_function_signature_add_parameter(sig, &px, fx.bigint_type, nil, .STANDARD, &fx.err),
			&fx.err,
		)
		expect_v2_ok(
			t,
			duckdb.duckdb_v2_function_signature_add_parameter(sig, &py, fx.bigint_type, nil, .STANDARD, &fx.err),
			&fx.err,
		)

		docs: duckdb.V2_Function_Docs_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_macro_function_get_docs(macro, &docs, &fx.err), &fx.err)
		desc := duckdb.v2_str_from_string("Doubles x and adds y")
		expect_v2_ok(t, duckdb.duckdb_v2_function_docs_set_description(docs, &desc, &fx.err), &fx.err)
	}

	// 2. MultiFileFunction builder lifecycle (`MODULE: table`, `duckdb_v2.h` lines 14211-14376):
	{
		mff: duckdb.V2_Multi_File_Function_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_multi_file_function_create(fx.factory, &mff, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_multi_file_function_destroy(&mff)

		mff_name := duckdb.v2_str_from_string("read_odin_multi")
		single_fn := duckdb.v2_str_from_string("unregistered_single_fn")
		rtype := duckdb.v2_str_from_string("OdinMulti")
		fext := duckdb.v2_str_from_string("odin")
		expect_v2_ok(t, duckdb.duckdb_v2_multi_file_function_set_name(mff, &mff_name, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_multi_file_function_set_single_file_function(mff, &single_fn, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_multi_file_function_set_reader_type(mff, &rtype, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_multi_file_function_set_file_extension(mff, &fext, &fx.err), &fx.err)

		// Registering a multi-file function wrapping an unregistered single-file function is rejected:
		expect_v2_error(
			t,
			duckdb.duckdb_v2_connection_register_multi_file_function(fx.conn, mff, &fx.err),
			.INPUT_INVALID,
			&fx.err,
		)
	}

	// 3. Transactional registration rollback & cross-database refusal (`test_capi_v2_registration.cpp` lines 35-66):
	{
		expect_v2_ok(t, driver_exec_drain(fx.conn, "BEGIN TRANSACTION", nil, &fx.err), &fx.err)

		ct: duckdb.V2_Custom_Type_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_custom_type_create(fx.factory, &ct, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_custom_type_destroy(&ct)

		alias_name := duckdb.v2_str_from_string("rolled_back_alias")
		expect_v2_ok(t, duckdb.duckdb_v2_custom_type_set_name(ct, &alias_name, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_custom_type_set_base_type(ct, fx.int_type, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_connection_register_custom_type(fx.conn, ct, &fx.err), &fx.err)

		expect_query_column(&fx, "SELECT 42::rolled_back_alias", []i32{42})
		expect_v2_ok(t, driver_exec_drain(fx.conn, "ROLLBACK", nil, &fx.err), &fx.err)

		rolled_res: duckdb.V2_Result_Handle
		expect_v2_error(
			t,
			driver_query(fx.conn, "SELECT 42::rolled_back_alias", &rolled_res, &fx.err),
			.DATABASE_CATALOG,
			&fx.err,
		)

		// Cross-database registration refusal (`INPUT_INVALID`):
		other_inst: duckdb.V2_Instance_Handle
		expect_v2_ok(t, driver_open_instance(fx.env, "", &other_inst, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_instance_destroy(&other_inst)

		other_conn: duckdb.V2_Connection_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_connection_create(other_inst, &other_conn, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_connection_destroy(&other_conn)

		expect_v2_error(
			t,
			duckdb.duckdb_v2_connection_register_custom_type(other_conn, ct, &fx.err),
			.INPUT_INVALID,
			&fx.err,
		)
	}
}
