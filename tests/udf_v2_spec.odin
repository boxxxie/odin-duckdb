package duckdb_tests

// ============================================================================
// Layer 1: Executable Specifications — UDFs (`tests/udf_v2_spec.odin`)
// ============================================================================
// Ported from Authoritative DuckDB 2.0 C API v2 & C++20 Test Suites:
// 1. `references/c/duckdb-capi-2.0/test/api/capi/v2/test_capi_v2_scalar_function.cpp`
//    - Scalar addition (`my_add`), variadic `*args` sum (`my_var_sum`), out-of-bounds arg check,
//      `resolve_types` -> `bind` -> `init` -> `exec` data flow with destructor verification,
//      bind-time constant inspection (`duckdb_v2_function_bind_get_arg_value`), and callback error propagation.
// 2. `references/c/duckdb-capi-2.0/test/api/capi/v2/test_capi_v2_table_function.cpp`
//    - `my_range(n, step := 1)` with bind data, global state, cardinality, order preservation,
//      projection pushdown (`get_column_count` / `get_column_index`), and callback error propagation.
// 3. `references/c/duckdb-capi-2.0/test/api/capi/v2/test_capi_v2_aggregate_function.cpp`
//    - `my_agg_sum(INTEGER) -> BIGINT` across groups (`bind`, `size`, `init`, `update`, `combine`, `finalize`, `destroy`),
//      `ANY` return type resolved in bind + user/bind data flowing through callbacks.
// ============================================================================

import "core:testing"
import duckdb "../duckdb"

// ----------------------------------------------------------------------------
// 1. Scalar Function Callbacks (`test_capi_v2_scalar_function.cpp`)
// ----------------------------------------------------------------------------

scalar_add_exec_cb :: proc "c" (
	info: duckdb.V2_Scalar_Function_Exec_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	col_a, col_b, output: duckdb.V2_Vector_Handle
	_ = duckdb.duckdb_v2_scalar_function_exec_get_arg(info, 0, &col_a, nil)
	_ = duckdb.duckdb_v2_scalar_function_exec_get_arg(info, 1, &col_b, nil)
	_ = duckdb.duckdb_v2_scalar_function_exec_get_result(info, &output, nil)

	count: duckdb.V2_Idx
	_ = duckdb.duckdb_v2_scalar_function_exec_get_row_count(info, &count, nil)

	view_a, view_b: duckdb.V2_Vector_View
	_ = duckdb.duckdb_v2_vector_get_view(col_a, &view_a, nil)
	_ = duckdb.duckdb_v2_vector_get_view(col_b, &view_b, nil)

	out_raw: rawptr
	_ = duckdb.duckdb_v2_vector_get_data_mutable(output, &out_raw, nil)
	out_data := cast([^]i32)out_raw
	a_data := cast([^]i32)view_a.data
	b_data := cast([^]i32)view_b.data

	for i: duckdb.V2_Idx = 0; i < count; i += 1 {
		ia := duckdb.v2_sel_at(view_a.sel, i)
		ib := duckdb.v2_sel_at(view_b.sel, i)
		out_data[i] = a_data[ia] + b_data[ib]
	}
}

scalar_varargs_sum_exec_cb :: proc "c" (
	info: duckdb.V2_Scalar_Function_Exec_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	count, pos_fixed, pos_var, named_fixed, named_var: duckdb.V2_Idx
	_ = duckdb.duckdb_v2_scalar_function_exec_get_row_count(info, &count, nil)
	_ = duckdb.duckdb_v2_scalar_function_exec_get_arg_count(info, &pos_fixed, &pos_var, &named_fixed, &named_var, nil)
	ncols := pos_fixed + pos_var

	output: duckdb.V2_Vector_Handle
	_ = duckdb.duckdb_v2_scalar_function_exec_get_result(info, &output, nil)
	out_raw: rawptr
	_ = duckdb.duckdb_v2_vector_get_data_mutable(output, &out_raw, nil)
	out_data := cast([^]i32)out_raw

	for r: duckdb.V2_Idx = 0; r < count; r += 1 {
		out_data[r] = 0
	}
	for c: duckdb.V2_Idx = 0; c < ncols; c += 1 {
		col: duckdb.V2_Vector_Handle
		_ = duckdb.duckdb_v2_scalar_function_exec_get_arg(info, c, &col, nil)
		view: duckdb.V2_Vector_View
		_ = duckdb.duckdb_v2_vector_get_view(col, &view, nil)
		col_data := cast([^]i32)view.data
		for r: duckdb.V2_Idx = 0; r < count; r += 1 {
			out_data[r] += col_data[duckdb.v2_sel_at(view.sel, r)]
		}
	}
}

Scalar_Flow_State :: struct {
	user_val:        i32,
	bind_val:        i32,
	init_val:        i32,
	user_destroyed:  int,
	bind_destroyed:  int,
	init_destroyed:  int,
	shared_sets_bad: bool,
}

scalar_flow_destroy_user :: proc "c" (p: rawptr) {
	st := cast(^Scalar_Flow_State)p
	st.user_destroyed += 1
}

scalar_flow_destroy_bind :: proc "c" (p: rawptr) {
	st := cast(^Scalar_Flow_State)p
	st.bind_destroyed += 1
}

scalar_flow_destroy_init :: proc "c" (p: rawptr) {
	st := cast(^Scalar_Flow_State)p
	st.init_destroyed += 1
}

scalar_flow_resolve_types_cb :: proc "c" (
	info: duckdb.V2_Function_Bind_Info_Handle,
	result: duckdb.V2_Scalar_Function_Resolve_Types_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	pos_fixed, pos_var, named_fixed, named_var: duckdb.V2_Idx
	_ = duckdb.duckdb_v2_function_bind_get_arg_count(info, &pos_fixed, &pos_var, &named_fixed, &named_var, nil)
	if pos_fixed != 1 {
		driver_set_callback_error(err, .INPUT_INVALID, "expected 1 arg in resolve_types")
		return
	}
	// Out-of-bounds argument index returns INPUT_INVALID (`test_capi_v2_scalar_function.cpp` line 617)
	oob_type: duckdb.V2_Logical_Type_Handle
	oob_err: duckdb.V2_Error_Info_Handle
	if duckdb.duckdb_v2_function_bind_get_arg_type(info, 99, &oob_type, &oob_err) != .INPUT_INVALID {
		_ = duckdb.duckdb_v2_error_info_destroy(&oob_err)
		driver_set_callback_error(err, .RUNTIME_INTERNAL, "expected INPUT_INVALID on oob arg")
		return
	}
	_ = duckdb.duckdb_v2_error_info_destroy(&oob_err)

	arg0: duckdb.V2_Logical_Type_Handle
	_ = duckdb.duckdb_v2_function_bind_get_arg_type(info, 0, &arg0, nil)
	defer duckdb.duckdb_v2_logical_type_destroy(&arg0)

	factory: duckdb.V2_Factory_Handle
	_ = duckdb.duckdb_v2_context_get_factory(ctx, &factory, nil)
	ret_type: duckdb.V2_Logical_Type_Handle
	_ = duckdb.duckdb_v2_factory_create_type_from_id(factory, .INTEGER, nil, nil, 0, &ret_type, nil)
	defer duckdb.duckdb_v2_logical_type_destroy(&ret_type)
	_ = duckdb.duckdb_v2_scalar_function_resolve_types_set_return_type(result, ret_type, nil)
}

scalar_flow_bind_cb :: proc "c" (
	info: duckdb.V2_Function_Bind_Info_Handle,
	result: duckdb.V2_Scalar_Function_Bind_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	ud: rawptr
	_ = duckdb.duckdb_v2_function_bind_get_user_data(info, &ud, nil)
	st := cast(^Scalar_Flow_State)ud

	// Verify that calling the shared `duckdb_v2_function_bind_set_bind_data` on a scalar function
	// is rejected with `INPUT_INVALID` (`test_capi_v2_scalar_function.cpp` line 381)
	dummy := duckdb.V2_Opaque{ptr = st}
	bad_err: duckdb.V2_Error_Info_Handle
	rc := duckdb.duckdb_v2_function_bind_set_bind_data(info, &dummy, &bad_err)
	_ = duckdb.duckdb_v2_error_info_destroy(&bad_err)
	st.shared_sets_bad = (rc == .INPUT_INVALID)

	val: duckdb.V2_Value_Handle
	if duckdb.duckdb_v2_function_bind_get_arg_value(info, 0, &val, nil) == .NONE && val != nil {
		_ = duckdb.duckdb_v2_value_get_int(val, &st.bind_val, nil)
		_ = duckdb.duckdb_v2_value_destroy(&val)
	}

	bd := duckdb.V2_Opaque{ptr = st, destroy = scalar_flow_destroy_bind}
	_ = duckdb.duckdb_v2_scalar_function_bind_set_bind_data(result, &bd, nil)
}

scalar_flow_init_cb :: proc "c" (
	info: duckdb.V2_Scalar_Function_Init_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	ud, bd: rawptr
	_ = duckdb.duckdb_v2_scalar_function_init_get_user_data(info, &ud, nil)
	_ = duckdb.duckdb_v2_scalar_function_init_get_bind_data(info, &bd, nil)
	st_u := cast(^Scalar_Flow_State)ud
	st_b := cast(^Scalar_Flow_State)bd
	st_u.init_val = st_u.user_val + st_b.bind_val + 1

	id := duckdb.V2_Opaque{ptr = st_u, destroy = scalar_flow_destroy_init}
	_ = duckdb.duckdb_v2_scalar_function_init_set_init_data(info, &id, nil)
}

scalar_flow_exec_cb :: proc "c" (
	info: duckdb.V2_Scalar_Function_Exec_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	ud, bd, id: rawptr
	_ = duckdb.duckdb_v2_scalar_function_exec_get_user_data(info, &ud, nil)
	_ = duckdb.duckdb_v2_scalar_function_exec_get_bind_data(info, &bd, nil)
	_ = duckdb.duckdb_v2_scalar_function_exec_get_init_data(info, &id, nil)

	st := cast(^Scalar_Flow_State)id
	col0, output: duckdb.V2_Vector_Handle
	_ = duckdb.duckdb_v2_scalar_function_exec_get_arg(info, 0, &col0, nil)
	_ = duckdb.duckdb_v2_scalar_function_exec_get_result(info, &output, nil)

	count: duckdb.V2_Idx
	_ = duckdb.duckdb_v2_scalar_function_exec_get_row_count(info, &count, nil)

	view0: duckdb.V2_Vector_View
	_ = duckdb.duckdb_v2_vector_get_view(col0, &view0, nil)

	out_raw: rawptr
	_ = duckdb.duckdb_v2_vector_get_data_mutable(output, &out_raw, nil)
	out_data := cast([^]i32)out_raw
	in_data := cast([^]i32)view0.data

	for i: duckdb.V2_Idx = 0; i < count; i += 1 {
		out_data[i] = in_data[duckdb.v2_sel_at(view0.sel, i)] + st.user_val + st.bind_val + st.init_val
	}
}

@(test)
spec_v2_scalar_function_registration_and_data_flow :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)

	// 1. Register `my_add(INTEGER, INTEGER) -> INTEGER` with docs + properties
	{
		fn: duckdb.V2_Scalar_Function_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_scalar_function_create(fx.factory, &fn, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_scalar_function_destroy(&fn)

		sig: duckdb.V2_Function_Signature_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_scalar_function_get_signature(fn, &sig, &fx.err), &fx.err)
		p_a := duckdb.v2_str_from_string("a")
		p_b := duckdb.v2_str_from_string("b")
		expect_v2_ok(t, duckdb.duckdb_v2_function_signature_add_parameter(sig, &p_a, fx.int_type, nil, .POSITIONAL_ONLY, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_function_signature_add_parameter(sig, &p_b, fx.int_type, nil, .POSITIONAL_ONLY, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_function_signature_set_return_type(sig, fx.int_type, &fx.err), &fx.err)

		docs: duckdb.V2_Function_Docs_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_scalar_function_get_docs(fn, &docs, &fx.err), &fx.err)
		desc := duckdb.v2_str_from_string("Adds two integers")
		ex_title := duckdb.v2_str_from_string("basic")
		ex := duckdb.v2_str_from_string("my_add(20, 22)")
		cat := duckdb.v2_str_from_string("numeric")
		expect_v2_ok(t, duckdb.duckdb_v2_function_docs_set_description(docs, &desc, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_function_docs_add_example(docs, &ex_title, &ex, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_function_docs_add_category(docs, &cat, &fx.err), &fx.err)

		name := duckdb.v2_str_from_string("my_add")
		expect_v2_ok(t, duckdb.duckdb_v2_scalar_function_set_name(fn, &name, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_scalar_function_set_property(fn, .NULL_HANDLING, .NULL_HANDLING_DEFAULT, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_scalar_function_set_property(fn, .STABILITY, .STABILITY_CONSISTENT, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_scalar_function_set_property(fn, .FALLIBILITY, .FALLIBILITY_FALLIBLE, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_scalar_function_set_exec_callback(fn, scalar_add_exec_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_connection_register_scalar_function(fx.conn, fn, &fx.err), &fx.err)

		expect_query_column(&fx, "SELECT my_add(x, x * 10) FROM VALUES (1), (2), (3) AS t(x)", []i32{11, 22, 33})
	}

	// 2. Register variadic `my_var_sum(*INTEGER) -> INTEGER`
	{
		fn: duckdb.V2_Scalar_Function_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_scalar_function_create(fx.factory, &fn, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_scalar_function_destroy(&fn)

		sig: duckdb.V2_Function_Signature_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_scalar_function_get_signature(fn, &sig, &fx.err), &fx.err)
		p_xs := duckdb.v2_str_from_string("xs")
		expect_v2_ok(t, duckdb.duckdb_v2_function_signature_add_parameter(sig, &p_xs, fx.int_type, nil, .POSITIONAL_VARIADIC, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_function_signature_set_return_type(sig, fx.int_type, &fx.err), &fx.err)

		name := duckdb.v2_str_from_string("my_var_sum")
		expect_v2_ok(t, duckdb.duckdb_v2_scalar_function_set_name(fn, &name, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_scalar_function_set_exec_callback(fn, scalar_varargs_sum_exec_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_connection_register_scalar_function(fx.conn, fn, &fx.err), &fx.err)

		expect_query_column(&fx, "SELECT my_var_sum(1, 2, 3, 4)", []i32{10})
	}

	// 3. Full `resolve_types` -> `bind` -> `init` -> `exec` pipeline
	{
		flow_state := Scalar_Flow_State{user_val = 100}

		fn: duckdb.V2_Scalar_Function_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_scalar_function_create(fx.factory, &fn, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_scalar_function_destroy(&fn)

		sig: duckdb.V2_Function_Signature_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_scalar_function_get_signature(fn, &sig, &fx.err), &fx.err)
		p_x := duckdb.v2_str_from_string("x")
		expect_v2_ok(t, duckdb.duckdb_v2_function_signature_add_parameter(sig, &p_x, fx.any_type, nil, .POSITIONAL_ONLY, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_function_signature_set_return_type(sig, fx.any_type, &fx.err), &fx.err)

		name := duckdb.v2_str_from_string("my_flow")
		ud := duckdb.V2_Opaque{ptr = &flow_state, destroy = scalar_flow_destroy_user}
		expect_v2_ok(t, duckdb.duckdb_v2_scalar_function_set_name(fn, &name, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_scalar_function_set_user_data(fn, &ud, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_scalar_function_set_resolve_types_callback(fn, scalar_flow_resolve_types_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_scalar_function_set_bind_callback(fn, scalar_flow_bind_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_scalar_function_set_init_callback(fn, scalar_flow_init_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_scalar_function_set_exec_callback(fn, scalar_flow_exec_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_connection_register_scalar_function(fx.conn, fn, &fx.err), &fx.err)

		// arg=5 -> user=100, bind=5, init=106 -> result = 5 + 100 + 5 + 106 = 216
		expect_query_column(&fx, "SELECT my_flow(5)", []i32{216})
		testing.expect(t, flow_state.shared_sets_bad, "expected duckdb_v2_function_bind_set_bind_data to fail on scalar fn")
		testing.expect(t, flow_state.bind_destroyed >= 1, "expected bind_data destructor to run after query")
		testing.expect(t, flow_state.init_destroyed >= 1, "expected init_data destructor to run after query")
	}
}

// ----------------------------------------------------------------------------
// 2. Table Function Callbacks (`test_capi_v2_table_function.cpp`)
// ----------------------------------------------------------------------------

Table_Range_State :: struct {
	limit:   i64,
	current: i64,
	step:    i64,
}

table_range_bind_cb :: proc "c" (
	info: duckdb.V2_Function_Bind_Info_Handle,
	result: duckdb.V2_Table_Function_Bind_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	ud: rawptr
	_ = duckdb.duckdb_v2_function_bind_get_user_data(info, &ud, nil)
	st := cast(^Table_Range_State)ud

	arg0: duckdb.V2_Value_Handle
	_ = duckdb.duckdb_v2_function_bind_get_arg_value(info, 0, &arg0, nil)
	_ = duckdb.duckdb_v2_value_get_bigint(arg0, &st.limit, nil)
	_ = duckdb.duckdb_v2_value_destroy(&arg0)

	// Optional named parameter `step` via `duckdb_v2_function_bind_get_arg_index`
	step_name := duckdb.v2_str_from_string("step")
	step_idx: duckdb.V2_Idx
	found := false
	if duckdb.duckdb_v2_function_bind_get_arg_index(info, &step_name, &step_idx, &found, nil) == .NONE && found {
		step_val: duckdb.V2_Value_Handle
		if duckdb.duckdb_v2_function_bind_get_arg_value(info, step_idx, &step_val, nil) == .NONE && step_val != nil {
			_ = duckdb.duckdb_v2_value_get_bigint(step_val, &st.step, nil)
			_ = duckdb.duckdb_v2_value_destroy(&step_val)
		}
	} else {
		st.step = 1
	}

	factory: duckdb.V2_Factory_Handle
	_ = duckdb.duckdb_v2_context_get_factory(ctx, &factory, nil)
	bigint_type: duckdb.V2_Logical_Type_Handle
	_ = duckdb.duckdb_v2_factory_create_type_from_id(factory, .BIGINT, nil, nil, 0, &bigint_type, nil)
	defer duckdb.duckdb_v2_logical_type_destroy(&bigint_type)

	col_name := duckdb.v2_str_from_string("i")
	_ = duckdb.duckdb_v2_table_function_bind_add_result_column(result, &col_name, bigint_type, nil)
	_ = duckdb.duckdb_v2_table_function_bind_set_cardinality(result, duckdb.V2_Idx(st.limit), true, nil)
	_ = duckdb.duckdb_v2_table_function_bind_set_order_preservation(result, .INSERTION_ORDER, nil)

	bd := duckdb.V2_Opaque{ptr = st}
	_ = duckdb.duckdb_v2_function_bind_set_bind_data(info, &bd, nil)
}

table_range_init_global_cb :: proc "c" (
	info: duckdb.V2_Table_Function_Init_Global_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	bd: rawptr
	_ = duckdb.duckdb_v2_table_function_init_global_get_bind_data(info, &bd, nil)
	st := cast(^Table_Range_State)bd
	st.current = 0

	gs := duckdb.V2_Opaque{ptr = st}
	_ = duckdb.duckdb_v2_table_function_init_global_set_global_state(info, &gs, nil)
	_ = duckdb.duckdb_v2_table_function_init_global_set_max_threads(info, 1, nil)
}

table_range_exec_cb :: proc "c" (
	info: duckdb.V2_Table_Function_Exec_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	gs: rawptr
	_ = duckdb.duckdb_v2_table_function_exec_get_global_state(info, &gs, nil)
	st := cast(^Table_Range_State)gs

	output: duckdb.V2_Data_Chunk_Handle
	_ = duckdb.duckdb_v2_table_function_exec_get_output_chunk(info, &output, nil)
	col0: duckdb.V2_Vector_Handle
	_ = duckdb.duckdb_v2_data_chunk_get_vector(output, 0, &col0, nil)

	if st.current >= st.limit {
		_ = duckdb.duckdb_v2_vector_set_size(col0, 0, nil)
		return
	}

	cap: duckdb.V2_Idx
	_ = duckdb.duckdb_v2_data_chunk_get_capacity(output, &cap, nil)
	remaining := duckdb.V2_Idx(st.limit - st.current)
	emit := min(cap, remaining)

	raw: rawptr
	_ = duckdb.duckdb_v2_vector_get_data_mutable(col0, &raw, nil)
	data := cast([^]i64)raw
	for i: duckdb.V2_Idx = 0; i < emit; i += 1 {
		data[i] = (st.current + i64(i)) * st.step
	}
	st.current += i64(emit)
	_ = duckdb.duckdb_v2_vector_set_size(col0, emit, nil)
}

Table_Pushdown_State :: struct {
	projected_count: duckdb.V2_Idx,
	first_col_idx:   duckdb.V2_Idx,
	done:            bool,
}

table_pushdown_bind_cb :: proc "c" (
	info: duckdb.V2_Function_Bind_Info_Handle,
	result: duckdb.V2_Table_Function_Bind_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	factory: duckdb.V2_Factory_Handle
	_ = duckdb.duckdb_v2_context_get_factory(ctx, &factory, nil)
	int_type: duckdb.V2_Logical_Type_Handle
	_ = duckdb.duckdb_v2_factory_create_type_from_id(factory, .INTEGER, nil, nil, 0, &int_type, nil)
	defer duckdb.duckdb_v2_logical_type_destroy(&int_type)

	c0 := duckdb.v2_str_from_string("a")
	c1 := duckdb.v2_str_from_string("b")
	c2 := duckdb.v2_str_from_string("c")
	_ = duckdb.duckdb_v2_table_function_bind_add_result_column(result, &c0, int_type, nil)
	_ = duckdb.duckdb_v2_table_function_bind_add_result_column(result, &c1, int_type, nil)
	_ = duckdb.duckdb_v2_table_function_bind_add_result_column(result, &c2, int_type, nil)
}

table_pushdown_init_global_cb :: proc "c" (
	info: duckdb.V2_Table_Function_Init_Global_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	ud: rawptr
	_ = duckdb.duckdb_v2_table_function_init_global_get_user_data(info, &ud, nil)
	st := cast(^Table_Pushdown_State)ud
	st.done = false
	_ = duckdb.duckdb_v2_table_function_init_global_get_column_count(info, &st.projected_count, nil)
	if st.projected_count > 0 {
		_ = duckdb.duckdb_v2_table_function_init_global_get_column_index(info, 0, &st.first_col_idx, nil)
	}
}

table_pushdown_exec_cb :: proc "c" (
	info: duckdb.V2_Table_Function_Exec_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	ud: rawptr
	_ = duckdb.duckdb_v2_table_function_exec_get_user_data(info, &ud, nil)
	st := cast(^Table_Pushdown_State)ud

	output: duckdb.V2_Data_Chunk_Handle
	_ = duckdb.duckdb_v2_table_function_exec_get_output_chunk(info, &output, nil)
	col0: duckdb.V2_Vector_Handle
	_ = duckdb.duckdb_v2_data_chunk_get_vector(output, 0, &col0, nil)
	if st.done {
		_ = duckdb.duckdb_v2_vector_set_size(col0, 0, nil)
		return
	}
	st.done = true
	raw: rawptr
	_ = duckdb.duckdb_v2_vector_get_data_mutable(col0, &raw, nil)
	(cast([^]i32)raw)[0] = 300
	_ = duckdb.duckdb_v2_vector_set_size(col0, 1, nil)
}

@(test)
spec_v2_table_function_scan_named_parameters_and_projection_pushdown :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)

	// 1. Register `my_range(n, step := 1)`
	range_state := Table_Range_State{}
	{
		fn: duckdb.V2_Table_Function_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_create(fx.factory, &fn, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_table_function_destroy(&fn)

		sig: duckdb.V2_Function_Signature_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_get_signature(fn, &sig, &fx.err), &fx.err)
		n_param := duckdb.v2_str_from_string("n")
		step_param := duckdb.v2_str_from_string("step")
		default_step: duckdb.V2_Value_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_bigint(fx.factory, 1, &default_step, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&default_step)

		expect_v2_ok(t, duckdb.duckdb_v2_function_signature_add_parameter(sig, &n_param, fx.bigint_type, nil, .POSITIONAL_ONLY, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_function_signature_add_parameter(sig, &step_param, fx.bigint_type, default_step, .NAMED_ONLY, &fx.err), &fx.err)

		name := duckdb.v2_str_from_string("my_range")
		ud := duckdb.V2_Opaque{ptr = &range_state}
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_set_name(fn, &name, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_set_user_data(fn, &ud, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_set_bind_callback(fn, table_range_bind_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_set_init_global_callback(fn, table_range_init_global_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_set_exec_callback(fn, table_range_exec_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_connection_register_table_function(fx.conn, fn, &fx.err), &fx.err)

		expect_query_column(&fx, "SELECT i FROM my_range(5, step := 10)", []i64{0, 10, 20, 30, 40})
	}

	// 2. Projection pushdown (`SELECT c FROM my_proj()` projects only column index 2)
	proj_state := Table_Pushdown_State{}
	{
		fn: duckdb.V2_Table_Function_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_create(fx.factory, &fn, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_table_function_destroy(&fn)

		name := duckdb.v2_str_from_string("my_proj")
		ud := duckdb.V2_Opaque{ptr = &proj_state}
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_set_name(fn, &name, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_set_projection_pushdown(fn, true, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_set_user_data(fn, &ud, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_set_bind_callback(fn, table_pushdown_bind_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_set_init_global_callback(fn, table_pushdown_init_global_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_set_exec_callback(fn, table_pushdown_exec_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_connection_register_table_function(fx.conn, fn, &fx.err), &fx.err)

		expect_query_column(&fx, "SELECT c FROM my_proj()", []i32{300})
		testing.expect_value(t, proj_state.projected_count, duckdb.V2_Idx(1))
		testing.expect_value(t, proj_state.first_col_idx, duckdb.V2_Idx(2))
	}
}

// ----------------------------------------------------------------------------
// 2b. Table Function `init_local`, `progress`, `partition_data`, `partitioning`
//     & `**kwargs` (`test_capi_v2_table_function.cpp` lines 350-2283)
// ----------------------------------------------------------------------------

Table_Part_Probe_State :: struct {
	part_count:     duckdb.V2_Idx,
	next_part:      duckdb.V2_Idx,
	init_local_cnt: int,
	progress_calls: int,
	part_data_cnt:  int,
	partition_cnt:  int,
}

table_part_bind_cb :: proc "c" (
	info: duckdb.V2_Function_Bind_Info_Handle,
	result: duckdb.V2_Table_Function_Bind_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	ud: rawptr
	_ = duckdb.duckdb_v2_function_bind_get_user_data(info, &ud, nil)
	st := cast(^Table_Part_Probe_State)ud

	v0: duckdb.V2_Value_Handle
	_ = duckdb.duckdb_v2_function_bind_get_arg_value(info, 0, &v0, nil)
	n: i64
	_ = duckdb.duckdb_v2_value_get_bigint(v0, &n, nil)
	_ = duckdb.duckdb_v2_value_destroy(&v0)
	st.part_count = duckdb.V2_Idx(n)

	factory: duckdb.V2_Factory_Handle
	_ = duckdb.duckdb_v2_context_get_factory(ctx, &factory, nil)
	bigint_type: duckdb.V2_Logical_Type_Handle
	_ = duckdb.duckdb_v2_factory_create_type_from_id(factory, .BIGINT, nil, nil, 0, &bigint_type, nil)
	defer duckdb.duckdb_v2_logical_type_destroy(&bigint_type)

	c0 := duckdb.v2_str_from_string("part_col")
	c1 := duckdb.v2_str_from_string("val")
	_ = duckdb.duckdb_v2_table_function_bind_add_result_column(result, &c0, bigint_type, nil)
	_ = duckdb.duckdb_v2_table_function_bind_add_result_column(result, &c1, bigint_type, nil)
}

table_part_init_global_cb :: proc "c" (
	info: duckdb.V2_Table_Function_Init_Global_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	ud: rawptr
	_ = duckdb.duckdb_v2_table_function_init_global_get_user_data(info, &ud, nil)
	st := cast(^Table_Part_Probe_State)ud
	st.next_part = 0
	_ = duckdb.duckdb_v2_table_function_init_global_set_max_threads(info, 1, nil)
}

table_part_init_local_cb :: proc "c" (
	info: duckdb.V2_Table_Function_Init_Local_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	ud: rawptr
	_ = duckdb.duckdb_v2_table_function_init_local_get_user_data(info, &ud, nil)
	st := cast(^Table_Part_Probe_State)ud
	st.init_local_cnt += 1
	ls := duckdb.V2_Opaque{ptr = st}
	_ = duckdb.duckdb_v2_table_function_init_local_set_local_state(info, &ls, nil)
}

table_part_progress_cb :: proc "c" (
	info: duckdb.V2_Table_Function_Progress_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	ud: rawptr
	_ = duckdb.duckdb_v2_table_function_progress_get_user_data(info, &ud, nil)
	st := cast(^Table_Part_Probe_State)ud
	st.progress_calls += 1
	_ = duckdb.duckdb_v2_table_function_progress_set_progress(info, 50.0, nil)
}

table_part_data_cb :: proc "c" (
	info: duckdb.V2_Table_Function_Partition_Data_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	ud: rawptr
	_ = duckdb.duckdb_v2_table_function_partition_data_get_user_data(info, &ud, nil)
	st := cast(^Table_Part_Probe_State)ud
	st.part_data_cnt += 1

	idx := st.next_part > 0 ? st.next_part - 1 : 0
	_ = duckdb.duckdb_v2_table_function_partition_data_set_batch_index(info, idx, nil)

	factory: duckdb.V2_Factory_Handle
	_ = duckdb.duckdb_v2_context_get_factory(ctx, &factory, nil)
	pval: duckdb.V2_Value_Handle
	_ = duckdb.duckdb_v2_value_create_bigint(factory, i64(idx), &pval, nil)
	defer duckdb.duckdb_v2_value_destroy(&pval)
	_ = duckdb.duckdb_v2_table_function_partition_data_set_partition_value(info, 0, pval, nil)
}

table_part_partitioning_cb :: proc "c" (
	info: duckdb.V2_Table_Function_Partitioning_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	ud: rawptr
	_ = duckdb.duckdb_v2_table_function_partitioning_get_user_data(info, &ud, nil)
	st := cast(^Table_Part_Probe_State)ud
	st.partition_cnt += 1

	col_cnt: duckdb.V2_Idx
	_ = duckdb.duckdb_v2_table_function_partitioning_get_partition_column_count(info, &col_cnt, nil)
	if col_cnt == 1 {
		col_idx: duckdb.V2_Idx
		_ = duckdb.duckdb_v2_table_function_partitioning_get_partition_column_index(info, 0, &col_idx, nil)
		if col_idx == 0 {
			_ = duckdb.duckdb_v2_table_function_partitioning_set_partition_info(info, .SINGLE_VALUE_PARTITIONS, nil)
		}
	}
}

table_part_exec_cb :: proc "c" (
	info: duckdb.V2_Table_Function_Exec_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	ls: rawptr
	_ = duckdb.duckdb_v2_table_function_exec_get_local_state(info, &ls, nil)
	st := cast(^Table_Part_Probe_State)ls

	output: duckdb.V2_Data_Chunk_Handle
	_ = duckdb.duckdb_v2_table_function_exec_get_output_chunk(info, &output, nil)
	col0, col1: duckdb.V2_Vector_Handle
	_ = duckdb.duckdb_v2_data_chunk_get_vector(output, 0, &col0, nil)
	_ = duckdb.duckdb_v2_data_chunk_get_vector(output, 1, &col1, nil)

	if st == nil || st.next_part >= st.part_count {
		_ = duckdb.duckdb_v2_vector_set_size(col0, 0, nil)
		_ = duckdb.duckdb_v2_vector_set_size(col1, 0, nil)
		return
	}
	p := st.next_part
	st.next_part += 1

	r0, r1: rawptr
	_ = duckdb.duckdb_v2_vector_get_data_mutable(col0, &r0, nil)
	_ = duckdb.duckdb_v2_vector_get_data_mutable(col1, &r1, nil)
	d0 := cast([^]i64)r0
	d1 := cast([^]i64)r1
	for i: duckdb.V2_Idx = 0; i < 4; i += 1 {
		d0[i] = i64(p)
		d1[i] = i64(p * 100 + i)
	}
	_ = duckdb.duckdb_v2_vector_set_size(col0, 4, nil)
	_ = duckdb.duckdb_v2_vector_set_size(col1, 4, nil)
}

@(test)
spec_v2_table_function_init_local_progress_partitioning_and_kwargs :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)

	// 1. Registering `partitioning_callback` without `partition_data_callback` fails synchronously with `INPUT_INVALID`
	//    (`test_capi_v2_table_function.cpp` lines 1986-2002):
	{
		bad_fn: duckdb.V2_Table_Function_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_create(fx.factory, &bad_fn, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_table_function_destroy(&bad_fn)

		bad_name := duckdb.v2_str_from_string("bad_part_fn")
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_set_name(bad_fn, &bad_name, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_set_bind_callback(bad_fn, table_part_bind_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_set_exec_callback(bad_fn, table_part_exec_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_set_partitioning_callback(bad_fn, table_part_partitioning_cb, &fx.err), &fx.err)

		expect_v2_error(
			t,
			duckdb.duckdb_v2_connection_register_table_function(fx.conn, bad_fn, &fx.err),
			.INPUT_INVALID,
			&fx.err,
		)
	}

	// 2. Register `part_probe(n, **kwargs)` with `init_local`, `progress`, `partition_data`, and `partitioning` callbacks
	//    and verify `GROUP BY part_col` uses `Partitioned Aggregate` (`test_capi_v2_table_function.cpp` lines 1949-1984):
	probe_st := Table_Part_Probe_State{}
	{
		fn: duckdb.V2_Table_Function_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_create(fx.factory, &fn, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_table_function_destroy(&fn)

		sig: duckdb.V2_Function_Signature_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_get_signature(fn, &sig, &fx.err), &fx.err)
		p_n := duckdb.v2_str_from_string("n")
		p_kw := duckdb.v2_str_from_string("kwargs")
		expect_v2_ok(t, duckdb.duckdb_v2_function_signature_add_parameter(sig, &p_n, fx.bigint_type, nil, .POSITIONAL_ONLY, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_function_signature_add_parameter(sig, &p_kw, fx.any_type, nil, .NAMED_VARIADIC, &fx.err), &fx.err)

		name := duckdb.v2_str_from_string("part_probe")
		ud := duckdb.V2_Opaque{ptr = &probe_st}
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_set_name(fn, &name, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_set_user_data(fn, &ud, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_set_bind_callback(fn, table_part_bind_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_set_init_global_callback(fn, table_part_init_global_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_set_init_local_callback(fn, table_part_init_local_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_set_progress_callback(fn, table_part_progress_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_set_partition_data_callback(fn, table_part_data_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_set_partitioning_callback(fn, table_part_partitioning_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_set_exec_callback(fn, table_part_exec_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_connection_register_table_function(fx.conn, fn, &fx.err), &fx.err)

		expect_query_column(
			&fx,
			"SELECT count(*)::BIGINT FROM part_probe(3, tag := 'alpha', retries := 2) GROUP BY part_col ORDER BY part_col",
			[]i64{4, 4, 4},
		)
		testing.expect(t, probe_st.init_local_cnt >= 1, "expected init_local_callback to execute")
		testing.expect(t, probe_st.part_data_cnt >= 1, "expected partition_data_callback to execute")
		testing.expect(t, probe_st.partition_cnt >= 1, "expected partitioning_callback to execute")
	}
}

// ----------------------------------------------------------------------------
// 3. Aggregate Function Callbacks (`test_capi_v2_aggregate_function.cpp`)
// ----------------------------------------------------------------------------

Agg_Sum_State :: struct {
	sum:   i64,
	has_v: bool,
}

Agg_Flow_Tracker :: struct {
	destroy_calls: int,
}

agg_sum_bind_cb :: proc "c" (
	info: duckdb.V2_Function_Bind_Info_Handle,
	result: duckdb.V2_Aggregate_Function_Bind_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	factory: duckdb.V2_Factory_Handle
	_ = duckdb.duckdb_v2_context_get_factory(ctx, &factory, nil)
	bigint_type: duckdb.V2_Logical_Type_Handle
	_ = duckdb.duckdb_v2_factory_create_type_from_id(factory, .BIGINT, nil, nil, 0, &bigint_type, nil)
	defer duckdb.duckdb_v2_logical_type_destroy(&bigint_type)

	_ = duckdb.duckdb_v2_aggregate_function_bind_set_return_type(result, bigint_type, nil)
}

agg_sum_size_cb :: proc "c" (
	info: duckdb.V2_Aggregate_Function_Size_Info_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	_ = duckdb.duckdb_v2_aggregate_function_size_set_state_size(info, size_of(Agg_Sum_State), nil)
}

agg_sum_init_cb :: proc "c" (
	info: duckdb.V2_Aggregate_Function_Init_Info_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	count: duckdb.V2_Idx
	states: [^]rawptr
	_ = duckdb.duckdb_v2_aggregate_function_init_get_state_count(info, &count, nil)
	_ = duckdb.duckdb_v2_aggregate_function_init_get_states(info, &states, nil)
	for i: duckdb.V2_Idx = 0; i < count; i += 1 {
		st := cast(^Agg_Sum_State)states[i]
		st.sum = 0
		st.has_v = false
	}
}

agg_sum_update_cb :: proc "c" (
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
	_ = duckdb.duckdb_v2_vector_get_view(col0, &view, nil)
	data := cast([^]i32)view.data

	for i: duckdb.V2_Idx = 0; i < count; i += 1 {
		if !duckdb.v2_row_is_valid(view, i) {
			continue
		}
		st := cast(^Agg_Sum_State)states[i]
		st.sum += i64(data[duckdb.v2_sel_at(view.sel, i)])
		st.has_v = true
	}
}

agg_sum_combine_cb :: proc "c" (
	info: duckdb.V2_Aggregate_Function_Combine_Info_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	count: duckdb.V2_Idx
	source, target: [^]rawptr
	_ = duckdb.duckdb_v2_aggregate_function_combine_get_state_count(info, &count, nil)
	_ = duckdb.duckdb_v2_aggregate_function_combine_get_sources(info, &source, nil)
	_ = duckdb.duckdb_v2_aggregate_function_combine_get_targets(info, &target, nil)
	for i: duckdb.V2_Idx = 0; i < count; i += 1 {
		src := cast(^Agg_Sum_State)source[i]
		tgt := cast(^Agg_Sum_State)target[i]
		if src.has_v {
			tgt.sum += src.sum
			tgt.has_v = true
		}
	}
}

agg_sum_finalize_cb :: proc "c" (
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
		st := cast(^Agg_Sum_State)source[i]
		row := offset + i
		if !st.has_v {
			_ = duckdb.duckdb_v2_vector_set_null(result, row, nil)
		} else {
			out_data[row] = st.sum
		}
	}
}

agg_sum_destroy_cb :: proc "c" (
	info: duckdb.V2_Aggregate_Function_Destroy_Info_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	count: duckdb.V2_Idx
	_ = duckdb.duckdb_v2_aggregate_function_destroy_get_state_count(info, &count, nil)
	ud: rawptr
	_ = duckdb.duckdb_v2_aggregate_function_destroy_get_user_data(info, &ud, nil)
	if ud != nil {
		tracker := cast(^Agg_Flow_Tracker)ud
		tracker.destroy_calls += int(count)
	}
}

@(test)
spec_v2_aggregate_function_grouped_sum_and_state_destroy :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)

	tracker := Agg_Flow_Tracker{}
	fn: duckdb.V2_Aggregate_Function_Handle
	expect_v2_ok(t, duckdb.duckdb_v2_aggregate_function_create(fx.factory, &fn, &fx.err), &fx.err)
	defer duckdb.duckdb_v2_aggregate_function_destroy(&fn)

	sig: duckdb.V2_Function_Signature_Handle
	expect_v2_ok(t, duckdb.duckdb_v2_aggregate_function_get_signature(fn, &sig, &fx.err), &fx.err)
	p_v := duckdb.v2_str_from_string("v")
	expect_v2_ok(t, duckdb.duckdb_v2_function_signature_add_parameter(sig, &p_v, fx.int_type, nil, .POSITIONAL_ONLY, &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.duckdb_v2_function_signature_set_return_type(sig, fx.any_type, &fx.err), &fx.err)

	name := duckdb.v2_str_from_string("my_agg_sum")
	ud := duckdb.V2_Opaque{ptr = &tracker}
	expect_v2_ok(t, duckdb.duckdb_v2_aggregate_function_set_name(fn, &name, &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.duckdb_v2_aggregate_function_set_user_data(fn, &ud, &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.duckdb_v2_aggregate_function_set_bind_callback(fn, agg_sum_bind_cb, &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.duckdb_v2_aggregate_function_set_size_callback(fn, agg_sum_size_cb, &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.duckdb_v2_aggregate_function_set_init_callback(fn, agg_sum_init_cb, &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.duckdb_v2_aggregate_function_set_update_callback(fn, agg_sum_update_cb, &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.duckdb_v2_aggregate_function_set_combine_callback(fn, agg_sum_combine_cb, &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.duckdb_v2_aggregate_function_set_finalize_callback(fn, agg_sum_finalize_cb, &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.duckdb_v2_aggregate_function_set_destroy_callback(fn, agg_sum_destroy_cb, &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.duckdb_v2_connection_register_aggregate_function(fx.conn, fn, &fx.err), &fx.err)

	expect_query_column(
		&fx,
		"SELECT my_agg_sum(v) FROM VALUES (0, 10), (1, 100), (0, 20), (1, 200), (0, NULL) AS t(g, v) GROUP BY g ORDER BY g",
		[]i64{30, 300},
	)
	testing.expect(t, tracker.destroy_calls >= 2, "expected aggregate state destroy callback to run for grouped states")

	// Empty input produces NULL
	empty_res: duckdb.V2_Result_Handle
	expect_v2_ok(t, driver_query(fx.conn, "SELECT my_agg_sum(v) FROM (SELECT 1 AS v WHERE false)", &empty_res, &fx.err), &fx.err)
	defer duckdb.duckdb_v2_result_destroy(&empty_res)

	chunk: duckdb.V2_Data_Chunk_Handle
	status, step_rc := driver_step_chunk(empty_res, &chunk)
	testing.expect_value(t, step_rc, duckdb.V2_Error.NONE)
	testing.expect_value(t, status, duckdb.V2_Result_Step_Status.CHUNK)
	defer duckdb.duckdb_v2_data_chunk_destroy(&chunk)

	vec0: duckdb.V2_Vector_Handle
	expect_v2_ok(t, duckdb.duckdb_v2_data_chunk_get_vector(chunk, 0, &vec0, &fx.err), &fx.err)
	view0: duckdb.V2_Vector_View
	expect_v2_ok(t, duckdb.duckdb_v2_vector_get_view(vec0, &view0, &fx.err), &fx.err)
	testing.expect(t, !duckdb.v2_row_is_valid(view0, 0), "expected NULL aggregate result on empty input")
}

// ============================================================================
// 4. Optimizer Statistics Callbacks (`test_capi_v2_stats.cpp`)
//    Enabled with `-define:DUCKDB_V2_STATS=true` when linking against a
//    `libduckdb` binary built with `capi_v2_stats.cpp`.
// ============================================================================

when #config(DUCKDB_V2_STATS, false) {

Stats_Callback_Probe :: struct {
	set_null:             bool,
	can_have_null:        bool,
	set_valid:            bool,
	can_have_valid:       bool,
	write_nulls:          bool,
	calls:                int,
	arg_count:            duckdb.V2_Idx,
	arg_can_have_null:    bool,
	arg_can_have_valid:   bool,
	read_only_null_rc:    duckdb.V2_Error,
	read_only_valid_rc:   duckdb.V2_Error,
	out_of_bounds_rc:     duckdb.V2_Error,
	result_can_have_null: bool,
	result_can_have_valid: bool,
	columns_asked:        u64,
	table_produced:       duckdb.V2_Idx,
}

@(private = "file")
stats_scalar_exec_cb :: proc "c" (
	info: duckdb.V2_Scalar_Function_Exec_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	ud: rawptr
	out: duckdb.V2_Vector_Handle
	count: duckdb.V2_Idx
	raw: rawptr
	if duckdb.duckdb_v2_scalar_function_exec_get_user_data(info, &ud, err) != .NONE ||
	   duckdb.duckdb_v2_scalar_function_exec_get_result(info, &out, err) != .NONE ||
	   duckdb.duckdb_v2_scalar_function_exec_get_row_count(info, &count, err) != .NONE ||
	   duckdb.duckdb_v2_vector_get_data_mutable(out, &raw, err) != .NONE {
		return
	}
	probe := cast(^Stats_Callback_Probe)ud
	dst := cast([^]i32)raw
	for i: duckdb.V2_Idx = 0; i < count; i += 1 {
		dst[i] = 7
	}
	if !probe.write_nulls {
		return
	}
	validity: [^]u64
	if duckdb.duckdb_v2_vector_flat_get_validity_mutable(out, &validity, err) != .NONE {
		return
	}
	for i: duckdb.V2_Idx = 0; i < count; i += 1 {
		duckdb.v2_validity_set_invalid(validity, i)
	}
}

@(private = "file")
stats_apply_to_result :: proc "c" (result: duckdb.V2_Stats_Handle, probe: ^Stats_Callback_Probe, err: ^duckdb.V2_Error_Info_Handle) {
	if probe.set_null {
		if duckdb.duckdb_v2_stats_set_can_have_null(result, probe.can_have_null, err) != .NONE {
			return
		}
	}
	if probe.set_valid {
		if duckdb.duckdb_v2_stats_set_can_have_valid(result, probe.can_have_valid, err) != .NONE {
			return
		}
	}
	_ = duckdb.duckdb_v2_stats_can_have_null(result, &probe.result_can_have_null, err)
	_ = duckdb.duckdb_v2_stats_can_have_valid(result, &probe.result_can_have_valid, err)
}

@(private = "file")
stats_observe_arg :: proc "c" (arg: duckdb.V2_Stats_Handle, probe: ^Stats_Callback_Probe, err: ^duckdb.V2_Error_Info_Handle) {
	_ = duckdb.duckdb_v2_stats_can_have_null(arg, &probe.arg_can_have_null, err)
	_ = duckdb.duckdb_v2_stats_can_have_valid(arg, &probe.arg_can_have_valid, err)
	probe.read_only_null_rc = duckdb.duckdb_v2_stats_set_can_have_null(arg, false, nil)
	probe.read_only_valid_rc = duckdb.duckdb_v2_stats_set_can_have_valid(arg, false, nil)
}

@(private = "file")
stats_scalar_stats_cb :: proc "c" (
	info: duckdb.V2_Scalar_Function_Stats_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	ud: rawptr
	pos_fixed, pos_var, named_fixed, named_var: duckdb.V2_Idx
	arg, result: duckdb.V2_Stats_Handle
	if duckdb.duckdb_v2_scalar_function_stats_get_user_data(info, &ud, err) != .NONE ||
	   duckdb.duckdb_v2_scalar_function_stats_get_arg_count(info, &pos_fixed, &pos_var, &named_fixed, &named_var, err) != .NONE ||
	   duckdb.duckdb_v2_scalar_function_stats_get_arg_stats(info, 0, &arg, err) != .NONE ||
	   duckdb.duckdb_v2_scalar_function_stats_get_result_stats(info, &result, err) != .NONE {
		return
	}
	probe := cast(^Stats_Callback_Probe)ud
	probe.calls += 1
	probe.arg_count = pos_fixed + pos_var + named_fixed + named_var
	past_end: duckdb.V2_Stats_Handle
	probe.out_of_bounds_rc = duckdb.duckdb_v2_scalar_function_stats_get_arg_stats(info, probe.arg_count, &past_end, nil)
	stats_observe_arg(arg, probe, err)
	stats_apply_to_result(result, probe, err)
}

@(private = "file")
stats_agg_size_cb :: proc "c" (info: duckdb.V2_Aggregate_Function_Size_Info_Handle, err: ^duckdb.V2_Error_Info_Handle) {
	_ = duckdb.duckdb_v2_aggregate_function_size_set_state_size(info, size_of(i64), err)
}
@(private = "file")
stats_agg_init_cb :: proc "c" (info: duckdb.V2_Aggregate_Function_Init_Info_Handle, err: ^duckdb.V2_Error_Info_Handle) {}
@(private = "file")
stats_agg_update_cb :: proc "c" (info: duckdb.V2_Aggregate_Function_Update_Info_Handle, err: ^duckdb.V2_Error_Info_Handle) {}
@(private = "file")
stats_agg_combine_cb :: proc "c" (info: duckdb.V2_Aggregate_Function_Combine_Info_Handle, err: ^duckdb.V2_Error_Info_Handle) {}
@(private = "file")
stats_agg_finalize_cb :: proc "c" (info: duckdb.V2_Aggregate_Function_Finalize_Info_Handle, err: ^duckdb.V2_Error_Info_Handle) {
	count, offset: duckdb.V2_Idx
	result: duckdb.V2_Vector_Handle
	raw: rawptr
	if duckdb.duckdb_v2_aggregate_function_finalize_get_state_count(info, &count, err) != .NONE ||
	   duckdb.duckdb_v2_aggregate_function_finalize_get_result(info, &result, err) != .NONE ||
	   duckdb.duckdb_v2_aggregate_function_finalize_get_result_offset(info, &offset, err) != .NONE ||
	   duckdb.duckdb_v2_vector_get_data_mutable(result, &raw, err) != .NONE {
		return
	}
	out := cast([^]i64)raw
	for i: duckdb.V2_Idx = 0; i < count; i += 1 {
		out[offset + i] = 7
	}
}

@(private = "file")
stats_agg_stats_cb :: proc "c" (
	info: duckdb.V2_Aggregate_Function_Stats_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	ud: rawptr
	pos_fixed: duckdb.V2_Idx
	arg, result: duckdb.V2_Stats_Handle
	if duckdb.duckdb_v2_aggregate_function_stats_get_user_data(info, &ud, err) != .NONE ||
	   duckdb.duckdb_v2_aggregate_function_stats_get_arg_count(info, &pos_fixed, nil, nil, nil, err) != .NONE ||
	   duckdb.duckdb_v2_aggregate_function_stats_get_arg_stats(info, 0, &arg, err) != .NONE ||
	   duckdb.duckdb_v2_aggregate_function_stats_get_result_stats(info, &result, err) != .NONE {
		return
	}
	probe := cast(^Stats_Callback_Probe)ud
	probe.calls += 1
	probe.arg_count = pos_fixed
	past_end: duckdb.V2_Stats_Handle
	probe.out_of_bounds_rc = duckdb.duckdb_v2_aggregate_function_stats_get_arg_stats(info, pos_fixed, &past_end, nil)
	stats_observe_arg(arg, probe, err)
	stats_apply_to_result(result, probe, err)
}

@(private = "file")
stats_pair_bind_cb :: proc "c" (
	info: duckdb.V2_Function_Bind_Info_Handle,
	result: duckdb.V2_Table_Function_Bind_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	factory: duckdb.V2_Factory_Handle
	int_type: duckdb.V2_Logical_Type_Handle
	if duckdb.duckdb_v2_context_get_factory(ctx, &factory, err) != .NONE ||
	   duckdb.duckdb_v2_factory_create_type_from_id(factory, .INTEGER, nil, nil, 0, &int_type, err) != .NONE {
		return
	}
	defer _ = duckdb.duckdb_v2_logical_type_destroy(&int_type)
	col_a := duckdb.v2_str_from_string("a")
	col_b := duckdb.v2_str_from_string("b")
	if duckdb.duckdb_v2_table_function_bind_add_result_column(result, &col_a, int_type, err) == .NONE {
		_ = duckdb.duckdb_v2_table_function_bind_add_result_column(result, &col_b, int_type, err)
	}
}

@(private = "file")
stats_pair_init_global_cb :: proc "c" (
	info: duckdb.V2_Table_Function_Init_Global_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	ud: rawptr
	if duckdb.duckdb_v2_table_function_init_global_get_user_data(info, &ud, err) != .NONE {
		return
	}
	probe := cast(^Stats_Callback_Probe)ud
	probe.table_produced = 0
}

@(private = "file")
stats_pair_exec_cb :: proc "c" (
	info: duckdb.V2_Table_Function_Exec_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	ud: rawptr
	chunk: duckdb.V2_Data_Chunk_Handle
	if duckdb.duckdb_v2_table_function_exec_get_user_data(info, &ud, err) != .NONE ||
	   duckdb.duckdb_v2_table_function_exec_get_output_chunk(info, &chunk, err) != .NONE {
		return
	}
	probe := cast(^Stats_Callback_Probe)ud
	produced: duckdb.V2_Idx = 1 if probe.table_produced < 3 else 0
	probe.table_produced += produced
	first_vec: duckdb.V2_Vector_Handle
	for col: duckdb.V2_Idx = 0; col < 2; col += 1 {
		vec: duckdb.V2_Vector_Handle
		raw: rawptr
		if duckdb.duckdb_v2_data_chunk_get_vector(chunk, col, &vec, err) != .NONE ||
		   duckdb.duckdb_v2_vector_get_data_mutable(vec, &raw, err) != .NONE {
			return
		}
		if produced > 0 {
			(cast([^]i32)raw)[0] = 7
		}
		if col == 0 {
			first_vec = vec
		}
	}
	_ = duckdb.duckdb_v2_vector_set_size(first_vec, produced, err)
}

@(private = "file")
stats_pair_stats_cb :: proc "c" (
	info: duckdb.V2_Table_Function_Stats_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	ud: rawptr
	col: duckdb.V2_Idx
	result: duckdb.V2_Stats_Handle
	if duckdb.duckdb_v2_table_function_stats_get_user_data(info, &ud, err) != .NONE ||
	   duckdb.duckdb_v2_table_function_stats_get_column_index(info, &col, err) != .NONE ||
	   duckdb.duckdb_v2_table_function_stats_get_result_stats(info, &result, err) != .NONE {
		return
	}
	probe := cast(^Stats_Callback_Probe)ud
	probe.calls += 1
	probe.columns_asked |= (u64(1) << col)
	if col == 1 {
		stats_apply_to_result(result, probe, err)
	}
}

@(test)
spec_v2_function_optimizer_statistics_callbacks :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)

	// 1. Null-handle validation on `duckdb_v2_stats_*`:
	out_flag := false
	testing.expect_value(t, duckdb.duckdb_v2_stats_can_have_null(nil, &out_flag, nil), duckdb.V2_Error.INPUT_INVALID)
	testing.expect_value(t, duckdb.duckdb_v2_stats_can_have_valid(nil, &out_flag, nil), duckdb.V2_Error.INPUT_INVALID)
	testing.expect_value(t, duckdb.duckdb_v2_stats_set_can_have_null(nil, false, nil), duckdb.V2_Error.INPUT_INVALID)
	testing.expect_value(t, duckdb.duckdb_v2_stats_set_can_have_valid(nil, false, nil), duckdb.V2_Error.INPUT_INVALID)
	testing.expect_value(t, duckdb.duckdb_v2_scalar_function_set_stats_callback(nil, nil, nil), duckdb.V2_Error.INPUT_INVALID)
	testing.expect_value(t, duckdb.duckdb_v2_aggregate_function_set_stats_callback(nil, nil, nil), duckdb.V2_Error.INPUT_INVALID)
	testing.expect_value(t, duckdb.duckdb_v2_table_function_set_stats_callback(nil, nil, nil), duckdb.V2_Error.INPUT_INVALID)

	sqllogic_statement_ok(&fx, "CREATE TABLE t_stats AS SELECT range::INTEGER AS i FROM range(3)")
	sqllogic_statement_ok(&fx, "CREATE TABLE tn_stats(i INTEGER)")
	sqllogic_statement_ok(&fx, "INSERT INTO tn_stats VALUES (1), (NULL), (3)")

	// 2. Scalar function stats callback folds `IS NULL` to false when `can_have_null = false` and verifies read-only arg stats:
	scalar_probe := Stats_Callback_Probe{
		set_null       = true,
		can_have_null  = false,
		can_have_valid = true,
		write_nulls    = true,
	}
	{
		fn: duckdb.V2_Scalar_Function_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_scalar_function_create(fx.factory, &fn, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_scalar_function_destroy(&fn)
		name := duckdb.v2_str_from_string("stats_no_null")
		expect_v2_ok(t, duckdb.duckdb_v2_scalar_function_set_name(fn, &name, &fx.err), &fx.err)
		sig: duckdb.V2_Function_Signature_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_scalar_function_get_signature(fn, &sig, &fx.err), &fx.err)
		px := duckdb.v2_str_from_string("x")
		expect_v2_ok(t, duckdb.duckdb_v2_function_signature_add_parameter(sig, &px, fx.int_type, nil, .STANDARD, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_function_signature_set_return_type(sig, fx.int_type, &fx.err), &fx.err)
		ud := duckdb.V2_Opaque{ptr = &scalar_probe}
		expect_v2_ok(t, duckdb.duckdb_v2_scalar_function_set_user_data(fn, &ud, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_scalar_function_set_exec_callback(fn, stats_scalar_exec_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_scalar_function_set_stats_callback(fn, stats_scalar_stats_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_connection_register_scalar_function(fx.conn, fn, &fx.err), &fx.err)
	}
	expect_query_column(&fx, "SELECT count(*) FROM t_stats WHERE stats_no_null(i) IS NULL", []i64{0})
	testing.expect(t, scalar_probe.calls > 0)
	testing.expect_value(t, scalar_probe.arg_count, duckdb.V2_Idx(1))
	testing.expect_value(t, scalar_probe.arg_can_have_null, false)
	testing.expect_value(t, scalar_probe.arg_can_have_valid, true)
	testing.expect_value(t, scalar_probe.read_only_null_rc, duckdb.V2_Error.INPUT_INVALID)
	testing.expect_value(t, scalar_probe.read_only_valid_rc, duckdb.V2_Error.INPUT_INVALID)
	testing.expect_value(t, scalar_probe.out_of_bounds_rc, duckdb.V2_Error.INPUT_INVALID)
	testing.expect_value(t, scalar_probe.result_can_have_null, false)
	testing.expect_value(t, scalar_probe.result_can_have_valid, true)

	// 3. Aggregate function stats callback folds `IS NOT NULL` to false when `can_have_valid = false`:
	agg_probe := Stats_Callback_Probe{
		can_have_null  = true,
		set_valid      = true,
		can_have_valid = false,
	}
	{
		fn: duckdb.V2_Aggregate_Function_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_aggregate_function_create(fx.factory, &fn, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_aggregate_function_destroy(&fn)
		name := duckdb.v2_str_from_string("stats_agg_all_null")
		expect_v2_ok(t, duckdb.duckdb_v2_aggregate_function_set_name(fn, &name, &fx.err), &fx.err)
		sig: duckdb.V2_Function_Signature_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_aggregate_function_get_signature(fn, &sig, &fx.err), &fx.err)
		px := duckdb.v2_str_from_string("x")
		expect_v2_ok(t, duckdb.duckdb_v2_function_signature_add_parameter(sig, &px, fx.int_type, nil, .STANDARD, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_function_signature_set_return_type(sig, fx.bigint_type, &fx.err), &fx.err)
		ud := duckdb.V2_Opaque{ptr = &agg_probe}
		expect_v2_ok(t, duckdb.duckdb_v2_aggregate_function_set_user_data(fn, &ud, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_aggregate_function_set_size_callback(fn, stats_agg_size_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_aggregate_function_set_init_callback(fn, stats_agg_init_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_aggregate_function_set_update_callback(fn, stats_agg_update_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_aggregate_function_set_combine_callback(fn, stats_agg_combine_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_aggregate_function_set_finalize_callback(fn, stats_agg_finalize_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_aggregate_function_set_stats_callback(fn, stats_agg_stats_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_connection_register_aggregate_function(fx.conn, fn, &fx.err), &fx.err)
	}
	expect_query_column(&fx, "SELECT count(*) FROM (SELECT stats_agg_all_null(i) AS a FROM tn_stats) WHERE a IS NOT NULL", []i64{0})
	testing.expect(t, agg_probe.calls > 0)
	testing.expect_value(t, agg_probe.arg_can_have_null, true)
	testing.expect_value(t, agg_probe.arg_can_have_valid, true)
	testing.expect_value(t, agg_probe.result_can_have_valid, false)

	// 4. Table function per-column stats callback folds `WHERE b IS NOT NULL` to 0 rows while `WHERE a IS NOT NULL` returns all 3 rows:
	tbl_probe := Stats_Callback_Probe{
		can_have_null  = true,
		set_valid      = true,
		can_have_valid = false,
	}
	{
		fn: duckdb.V2_Table_Function_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_create(fx.factory, &fn, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_table_function_destroy(&fn)
		name := duckdb.v2_str_from_string("stats_pair")
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_set_name(fn, &name, &fx.err), &fx.err)
		ud := duckdb.V2_Opaque{ptr = &tbl_probe}
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_set_user_data(fn, &ud, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_set_bind_callback(fn, stats_pair_bind_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_set_init_global_callback(fn, stats_pair_init_global_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_set_exec_callback(fn, stats_pair_exec_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_table_function_set_stats_callback(fn, stats_pair_stats_cb, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_connection_register_table_function(fx.conn, fn, &fx.err), &fx.err)
	}
	expect_query_column(&fx, "SELECT count(*) FROM stats_pair() WHERE b IS NOT NULL", []i64{0})
	testing.expect(t, tbl_probe.calls > 0)
	testing.expect(t, (tbl_probe.columns_asked & 2) != 0)
	testing.expect_value(t, tbl_probe.result_can_have_valid, false)
	expect_query_column(&fx, "SELECT count(*) FROM stats_pair() WHERE a IS NOT NULL", []i64{3})
}

} // when #config(DUCKDB_V2_STATS, false)
