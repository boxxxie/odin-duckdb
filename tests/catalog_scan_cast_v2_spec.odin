package duckdb_tests

// ============================================================================
// Layer 1: Executable Specifications — Catalog, Replacement Scan & Cast Function
// (`tests/catalog_scan_cast_v2_spec.odin`)
// ============================================================================
// Ported from Authoritative DuckDB 2.0 C API v2 & C++20 Test Suites:
// 1. `references/c/duckdb-capi-2.0/tools/cpp/tests/test_cpp_api_catalog.cpp`
//    - `duckdb_v2_connection_describe_table`: partial `qname` resolution to `"memory.s.Facts"`,
//      `is_readonly`, `get_column_count`, `get_column`, `get_name`, `get_type`, `has_default`,
//      `has_generated`, snapshot surviving `DROP TABLE`, out-of-range column index (`INPUT_OUT_OF_RANGE`),
//      and missing table / view rejection (`DATABASE_CATALOG`).
// 2. `references/c/duckdb-capi-2.0/tools/cpp/tests/test_cpp_api_replacement_scan.cpp`
//    - `duckdb_v2_qname_create` / `parse` / `render` / `equals` / `hash` / `get_part_count` / `get_part`.
//    - Replacement scan claiming a table function (`range(2)` with alias), claiming a `ColumnDataCollection`
//      for zero-copy `INSERT INTO sink SELECT * FROM my_batch`, claiming a `SELECT` subquery,
//      connection vs instance scoping, decline & callback error propagation.
// 3. `references/c/duckdb-capi-2.0/tools/cpp/tests/test_cpp_api_cast_function.cpp`
//    - `duckdb_v2_custom_type_create` / `set_name` / `set_base_type` / `connection_register_custom_type`.
//    - `duckdb_v2_cast_function_create` / `set_source_type` / `set_target_type` / `set_implicit_cast_cost` /
//      `set_exec_callback` / `exec_get_mode` (`NORMAL` vs `TRY`).
// ============================================================================

import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:testing"
import duckdb "../duckdb"

// ----------------------------------------------------------------------------
// 1. Catalog (`TableDescription` & `ColumnDescription`)
// ----------------------------------------------------------------------------

@(test)
spec_v2_catalog_table_description_columns_snapshot_and_errors :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)
	err: duckdb.V2_Error_Info_Handle

	expect_v2_ok(t, driver_exec_drain(fx.conn, "CREATE SCHEMA s", nil, &err), &err)
	expect_v2_ok(
		t,
		driver_exec_drain(
			fx.conn,
			`CREATE TABLE s."Facts"(i INTEGER, j VARCHAR DEFAULT 'x', k INTEGER GENERATED ALWAYS AS (i + 1))`,
			nil,
			&err,
		),
		&err,
	)

	// 1. Partial `qname` resolves to `"memory.s.Facts"` with declared casing
	parts := [2]duckdb.V2_Identifier{
		duckdb.v2_str_from_string("s"),
		duckdb.v2_str_from_string("facts"),
	}
	lookup_qname: duckdb.V2_Qname_Handle
	expect_v2_ok(t, duckdb.duckdb_v2_qname_create(&parts[0], 2, &lookup_qname, &err), &err)
	defer duckdb.duckdb_v2_qname_destroy(&lookup_qname)

	desc: duckdb.V2_Table_Description_Handle
	expect_v2_ok(t, duckdb.duckdb_v2_connection_describe_table(fx.conn, lookup_qname, &desc, &err), &err)
	defer duckdb.duckdb_v2_table_description_destroy(&desc)

	resolved_qname: duckdb.V2_Qname_Handle
	expect_v2_ok(t, duckdb.duckdb_v2_table_description_get_qname(desc, &resolved_qname, &err), &err)
	defer duckdb.duckdb_v2_qname_destroy(&resolved_qname)

	rendered, q_rc := driver_render_qname(resolved_qname)
	testing.expect_value(t, q_rc, duckdb.V2_Error.NONE)
	testing.expect_value(t, rendered, "memory.s.Facts")

	readonly := true
	expect_v2_ok(t, duckdb.duckdb_v2_table_description_is_readonly(desc, &readonly, &err), &err)
	testing.expect(t, !readonly, "expected memory table to be writable")

	// 2. Column metadata in declared order (including generated column)
	col_count: duckdb.V2_Idx
	expect_v2_ok(t, duckdb.duckdb_v2_table_description_get_column_count(desc, &col_count, &err), &err)
	testing.expect_value(t, col_count, duckdb.V2_Idx(3))

	expected_names := [3]string{"i", "j", "k"}
	expected_types := [3]duckdb.V2_Logical_Type_Id{.INTEGER, .VARCHAR, .INTEGER}
	expected_defaults := [3]bool{false, true, false}
	expected_generated := [3]bool{false, false, true}

	for idx in 0 ..< 3 {
		col: duckdb.V2_Column_Description_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_table_description_get_column(desc, duckdb.V2_Idx(idx), &col, &err), &err)
		defer duckdb.duckdb_v2_column_description_destroy(&col)

		c_name: duckdb.V2_Identifier
		expect_v2_ok(t, duckdb.duckdb_v2_column_description_get_name(col, &c_name, &err), &err)
		testing.expect_value(t, duckdb.v2_str_to_string(c_name), expected_names[idx])

		c_type: duckdb.V2_Logical_Type_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_column_description_get_type(col, &c_type, &err), &err)
		defer duckdb.duckdb_v2_logical_type_destroy(&c_type)
		tid: duckdb.V2_Logical_Type_Id
		expect_v2_ok(t, duckdb.duckdb_v2_logical_type_get_id(c_type, &tid, &err), &err)
		testing.expect_value(t, tid, expected_types[idx])

		has_def, has_gen: bool
		expect_v2_ok(t, duckdb.duckdb_v2_column_description_has_default(col, &has_def, &err), &err)
		expect_v2_ok(t, duckdb.duckdb_v2_column_description_has_generated(col, &has_gen, &err), &err)
		testing.expect_value(t, has_def, expected_defaults[idx])
		testing.expect_value(t, has_gen, expected_generated[idx])
	}

	// 3. Snapshot outlives `DROP TABLE`, and OOB column index returns `INPUT_OUT_OF_RANGE`
	expect_v2_ok(t, driver_exec_drain(fx.conn, `DROP TABLE s."Facts"`, nil, &err), &err)
	expect_v2_ok(t, duckdb.duckdb_v2_table_description_get_column_count(desc, &col_count, &err), &err)
	testing.expect_value(t, col_count, duckdb.V2_Idx(3))

	oob_col: duckdb.V2_Column_Description_Handle
	oob_err: duckdb.V2_Error_Info_Handle
	testing.expect_value(
		t,
		duckdb.duckdb_v2_table_description_get_column(desc, 3, &oob_col, &oob_err),
		duckdb.V2_Error.INPUT_OUT_OF_RANGE,
	)
	_ = duckdb.duckdb_v2_error_info_destroy(&oob_err)

	// 4. Views and missing tables are rejected with `DATABASE_CATALOG`
	expect_v2_ok(t, driver_exec_drain(fx.conn, "CREATE VIEW v AS SELECT 42 AS i", nil, &err), &err)
	v_str := duckdb.v2_str_from_string("v")
	v_qname: duckdb.V2_Qname_Handle
	expect_v2_ok(t, duckdb.duckdb_v2_qname_parse(&v_str, &v_qname, &err), &err)
	defer duckdb.duckdb_v2_qname_destroy(&v_qname)

	bad_desc: duckdb.V2_Table_Description_Handle
	bad_err: duckdb.V2_Error_Info_Handle
	testing.expect_value(
		t,
		duckdb.duckdb_v2_connection_describe_table(fx.conn, v_qname, &bad_desc, &bad_err),
		duckdb.V2_Error.DATABASE_CATALOG,
	)
	_ = duckdb.duckdb_v2_error_info_destroy(&bad_err)
}

// ----------------------------------------------------------------------------
// 2. Qualified Name & Replacement Scan
// ----------------------------------------------------------------------------

Replacement_Scan_Registry :: struct {
	target_name: string,
	collection:  duckdb.V2_Column_Data_Collection_Handle,
	calls:       int,
}

replacement_claim_collection_cb :: proc "c" (
	info: duckdb.V2_Replacement_Scan_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	ud: rawptr
	_ = duckdb.duckdb_v2_replacement_scan_get_user_data(info, &ud, nil)
	reg := cast(^Replacement_Scan_Registry)ud

	qname: duckdb.V2_Qname_Handle
	_ = duckdb.duckdb_v2_replacement_scan_get_name(info, &qname, nil)
	defer duckdb.duckdb_v2_qname_destroy(&qname)

	pcount: duckdb.V2_Idx
	_ = duckdb.duckdb_v2_qname_get_part_count(qname, &pcount, nil)
	if pcount != 1 {
		return // decline
	}
	part0: duckdb.V2_Identifier
	_ = duckdb.duckdb_v2_qname_get_part(qname, 0, &part0, nil)
	if duckdb.v2_str_to_string(part0) != reg.target_name {
		return // decline
	}

	reg.calls += 1
	col_names := [1]duckdb.V2_Identifier{duckdb.v2_str_from_string("amount")}
	_ = duckdb.duckdb_v2_replacement_scan_set_collection(info, reg.collection, &col_names[0], 1, err)
}

replacement_claim_subquery_cb :: proc "c" (
	info: duckdb.V2_Replacement_Scan_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	sql := duckdb.v2_str_from_string("SELECT 41 + 1 AS v")
	_ = duckdb.duckdb_v2_replacement_scan_set_subquery(info, &sql, err)
}

@(test)
spec_v2_qname_and_replacement_scan_collection_subquery_and_scoping :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)
	err: duckdb.V2_Error_Info_Handle

	// 1. QualifiedName (`create`, `parse`, `render`, case-insensitive `equals` + `hash`)
	{
		parts := [3]duckdb.V2_Identifier{
			duckdb.v2_str_from_string("cat"),
			duckdb.v2_str_from_string("sch"),
			duckdb.v2_str_from_string("tbl"),
		}
		q3, q_parsed: duckdb.V2_Qname_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_qname_create(&parts[0], 3, &q3, &err), &err)
		defer duckdb.duckdb_v2_qname_destroy(&q3)

		raw_upper := duckdb.v2_str_from_string("Cat.Sch.Tbl")
		expect_v2_ok(t, duckdb.duckdb_v2_qname_parse(&raw_upper, &q_parsed, &err), &err)
		defer duckdb.duckdb_v2_qname_destroy(&q_parsed)

		eq := false
		expect_v2_ok(t, duckdb.duckdb_v2_qname_equals(q3, q_parsed, &eq, &err), &err)
		testing.expect(t, eq, "expected case-insensitive qname equality")

		h1, h2: u64
		expect_v2_ok(t, duckdb.duckdb_v2_qname_hash(q3, &h1, &err), &err)
		expect_v2_ok(t, duckdb.duckdb_v2_qname_hash(q_parsed, &h2, &err), &err)
		testing.expect_value(t, h1, h2)
	}

	// 2. Replacement scan claiming a `ColumnDataCollection` for `INSERT INTO sink SELECT * FROM my_batch`
	{
		coll: duckdb.V2_Column_Data_Collection_Handle
		expect_v2_ok(t, driver_make_collection(i64, fx.factory, fx.bigint_type, []i64{10, 20}, &coll, &err), &err)
		defer duckdb.duckdb_v2_column_data_collection_destroy(&coll)

		reg := Replacement_Scan_Registry{target_name = "my_batch", collection = coll}
		scan: duckdb.V2_Replacement_Scan_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_replacement_scan_create(fx.factory, &scan, &err), &err)
		defer duckdb.duckdb_v2_replacement_scan_destroy(&scan)
		ud := duckdb.V2_Opaque{ptr = &reg}
		expect_v2_ok(t, duckdb.duckdb_v2_replacement_scan_set_callback(scan, replacement_claim_collection_cb, &err), &err)
		expect_v2_ok(t, duckdb.duckdb_v2_replacement_scan_set_user_data(scan, &ud, &err), &err)
		expect_v2_ok(t, duckdb.duckdb_v2_connection_register_replacement_scan(fx.conn, scan, &err), &err)

		expect_v2_ok(t, driver_exec_drain(fx.conn, "CREATE TABLE sink (v BIGINT)", nil, &err), &err)
		expect_v2_ok(t, driver_exec_drain(fx.conn, "INSERT INTO sink SELECT * FROM my_batch", nil, &err), &err)

		expect_query_column(&fx, "SELECT v FROM sink ORDER BY v", []i64{10, 20})
		testing.expect_value(t, reg.calls, 1)
	}

	// 3. Instance-scoped replacement scan reaches newly opened connections
	{
		inst_factory: duckdb.V2_Factory_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_instance_get_factory(fx.instance, &inst_factory, &err), &err)

		db_scan: duckdb.V2_Replacement_Scan_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_replacement_scan_create(inst_factory, &db_scan, &err), &err)
		defer duckdb.duckdb_v2_replacement_scan_destroy(&db_scan)
		expect_v2_ok(t, duckdb.duckdb_v2_replacement_scan_set_callback(db_scan, replacement_claim_subquery_cb, &err), &err)
		expect_v2_ok(t, duckdb.duckdb_v2_instance_register_replacement_scan(fx.instance, db_scan, &err), &err)

		conn2: duckdb.V2_Connection_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_connection_create(fx.instance, &conn2, &err), &err)
		defer duckdb.duckdb_v2_connection_destroy(&conn2)

		res2: duckdb.V2_Result_Handle
		expect_v2_ok(t, driver_query(conn2, "SELECT v::BIGINT FROM anything_at_all", &res2, &err), &err)
		rows2, rc2 := driver_collect_column(i64, &res2)
		testing.expect_value(t, rc2, duckdb.V2_Error.NONE)
		expect_slice_equal(t, rows2[:], []i64{42})
	}
}

// ----------------------------------------------------------------------------
// 3. Custom Type & Cast Function (`TEMPERATURE_CELSIUS` <-> `VARCHAR`)
// ----------------------------------------------------------------------------

TEMP_SUFFIX :: " degrees celsius"

Cast_Observer :: struct {
	last_mode: duckdb.V2_Cast_Mode,
}

cast_temp_to_text_cb :: proc "c" (
	info: duckdb.V2_Cast_Function_Exec_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	context = runtime.default_context()
	ud: rawptr
	_ = duckdb.duckdb_v2_cast_function_exec_get_user_data(info, &ud, nil)
	if ud != nil {
		obs := cast(^Cast_Observer)ud
		_ = duckdb.duckdb_v2_cast_function_exec_get_mode(info, &obs.last_mode, nil)
	}

	in_vec, out_vec: duckdb.V2_Vector_Handle
	count: duckdb.V2_Idx
	_ = duckdb.duckdb_v2_cast_function_exec_get_input(info, &in_vec, nil)
	_ = duckdb.duckdb_v2_cast_function_exec_get_output(info, &out_vec, nil)
	_ = duckdb.duckdb_v2_cast_function_exec_get_row_count(info, &count, nil)

	view: duckdb.V2_Vector_View
	_ = duckdb.duckdb_v2_vector_get_view(in_vec, &view, nil)
	validity: [^]u64
	_ = duckdb.duckdb_v2_vector_flat_get_validity_mutable(out_vec, &validity, nil)
	in_data := cast([^]i32)view.data

	var_buf: [64]u8
	for i: duckdb.V2_Idx = 0; i < count; i += 1 {
		if !duckdb.v2_row_is_valid(view, i) {
			duckdb.v2_validity_set_invalid(validity, i)
			continue
		}
		v := in_data[duckdb.v2_sel_at(view.sel, i)]
		s := fmt.bprintf(var_buf[:], "%d%s", v, TEMP_SUFFIX)
		_ = duckdb.v2_vector_assign_string(out_vec, i, s, nil)
	}
}

cast_text_to_temp_cb :: proc "c" (
	info: duckdb.V2_Cast_Function_Exec_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	context = runtime.default_context()
	ud: rawptr
	_ = duckdb.duckdb_v2_cast_function_exec_get_user_data(info, &ud, nil)
	if ud != nil {
		obs := cast(^Cast_Observer)ud
		_ = duckdb.duckdb_v2_cast_function_exec_get_mode(info, &obs.last_mode, nil)
	}

	in_vec, out_vec: duckdb.V2_Vector_Handle
	count: duckdb.V2_Idx
	_ = duckdb.duckdb_v2_cast_function_exec_get_input(info, &in_vec, nil)
	_ = duckdb.duckdb_v2_cast_function_exec_get_output(info, &out_vec, nil)
	_ = duckdb.duckdb_v2_cast_function_exec_get_row_count(info, &count, nil)

	view: duckdb.V2_Vector_View
	_ = duckdb.duckdb_v2_vector_get_view(in_vec, &view, nil)
	validity: [^]u64
	_ = duckdb.duckdb_v2_vector_flat_get_validity_mutable(out_vec, &validity, nil)
	raw_out: rawptr
	_ = duckdb.duckdb_v2_vector_get_data_mutable(out_vec, &raw_out, nil)
	out_data := cast([^]i32)raw_out
	in_bytes := cast([^]duckdb.V2_Bytes)view.data

	failed := false
	for i: duckdb.V2_Idx = 0; i < count; i += 1 {
		if !duckdb.v2_row_is_valid(view, i) {
			duckdb.v2_validity_set_invalid(validity, i)
			continue
		}
		b := in_bytes[duckdb.v2_sel_at(view.sel, i)]
		s := duckdb.v2_bytes_to_string(&b)
		if !strings.has_suffix(s, TEMP_SUFFIX) {
			duckdb.v2_validity_set_invalid(validity, i)
			failed = true
			continue
		}
		num_part := s[:len(s) - len(TEMP_SUFFIX)]
		parsed, ok := strconv.parse_int(num_part, 10)
		if !ok {
			duckdb.v2_validity_set_invalid(validity, i)
			failed = true
			continue
		}
		out_data[i] = i32(parsed)
	}

	if failed {
		driver_set_callback_error(err, .INPUT_INVALID, "could not convert to TEMPERATURE_CELSIUS")
	}
}

@(test)
spec_v2_custom_type_and_cast_function_normal_and_try_modes :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)
	err: duckdb.V2_Error_Info_Handle

	int_type, vch_type, temp_type: duckdb.V2_Logical_Type_Handle
	expect_v2_ok(t, duckdb.duckdb_v2_factory_create_type_from_id(fx.factory, .INTEGER, nil, nil, 0, &int_type, &err), &err)
	defer duckdb.duckdb_v2_logical_type_destroy(&int_type)
	expect_v2_ok(t, duckdb.duckdb_v2_factory_create_type_from_id(fx.factory, .VARCHAR, nil, nil, 0, &vch_type, &err), &err)
	defer duckdb.duckdb_v2_logical_type_destroy(&vch_type)

	// 1. Register `TEMPERATURE_CELSIUS` custom type backed by `INTEGER`
	ct: duckdb.V2_Custom_Type_Handle
	expect_v2_ok(t, duckdb.duckdb_v2_custom_type_create(fx.factory, &ct, &err), &err)
	defer duckdb.duckdb_v2_custom_type_destroy(&ct)
	temp_name := duckdb.v2_str_from_string("TEMPERATURE_CELSIUS")
	expect_v2_ok(t, duckdb.duckdb_v2_custom_type_set_name(ct, &temp_name, &err), &err)
	expect_v2_ok(t, duckdb.duckdb_v2_custom_type_set_base_type(ct, int_type, &err), &err)
	expect_v2_ok(t, duckdb.duckdb_v2_connection_register_custom_type(fx.conn, ct, &err), &err)

	expect_v2_ok(t, duckdb.duckdb_v2_factory_create_type_with_alias(fx.factory, int_type, &temp_name, &temp_type, &err), &err)
	defer duckdb.duckdb_v2_logical_type_destroy(&temp_type)

	// 2. Register bidirectional casts (`TEMPERATURE_CELSIUS` <-> `VARCHAR`)
	obs := Cast_Observer{last_mode = .TRY}
	ud := duckdb.V2_Opaque{ptr = &obs}

	to_text_fn, from_text_fn: duckdb.V2_Cast_Function_Handle
	expect_v2_ok(t, duckdb.duckdb_v2_cast_function_create(fx.factory, &to_text_fn, &err), &err)
	defer duckdb.duckdb_v2_cast_function_destroy(&to_text_fn)
	expect_v2_ok(t, duckdb.duckdb_v2_cast_function_set_source_type(to_text_fn, temp_type, &err), &err)
	expect_v2_ok(t, duckdb.duckdb_v2_cast_function_set_target_type(to_text_fn, vch_type, &err), &err)
	expect_v2_ok(t, duckdb.duckdb_v2_cast_function_set_user_data(to_text_fn, &ud, &err), &err)
	expect_v2_ok(t, duckdb.duckdb_v2_cast_function_set_exec_callback(to_text_fn, cast_temp_to_text_cb, &err), &err)
	expect_v2_ok(t, duckdb.duckdb_v2_connection_register_cast_function(fx.conn, to_text_fn, &err), &err)

	expect_v2_ok(t, duckdb.duckdb_v2_cast_function_create(fx.factory, &from_text_fn, &err), &err)
	defer duckdb.duckdb_v2_cast_function_destroy(&from_text_fn)
	expect_v2_ok(t, duckdb.duckdb_v2_cast_function_set_source_type(from_text_fn, vch_type, &err), &err)
	expect_v2_ok(t, duckdb.duckdb_v2_cast_function_set_target_type(from_text_fn, temp_type, &err), &err)
	expect_v2_ok(t, duckdb.duckdb_v2_cast_function_set_implicit_cast_cost(from_text_fn, -1, &err), &err)
	expect_v2_ok(t, duckdb.duckdb_v2_cast_function_set_user_data(from_text_fn, &ud, &err), &err)
	expect_v2_ok(t, duckdb.duckdb_v2_cast_function_set_exec_callback(from_text_fn, cast_text_to_temp_cb, &err), &err)
	expect_v2_ok(t, duckdb.duckdb_v2_connection_register_cast_function(fx.conn, from_text_fn, &err), &err)

	// 3. Round-trip `CAST('100 degrees celsius' AS TEMPERATURE_CELSIUS)::INTEGER` -> 100
	expect_query_column(&fx, "SELECT CAST(CAST('100 degrees celsius' AS TEMPERATURE_CELSIUS) AS INTEGER)", []i32{100})
	testing.expect_value(t, obs.last_mode, duckdb.V2_Cast_Mode.NORMAL)

	// 4. `TRY_CAST('not-a-temp' AS TEMPERATURE_CELSIUS)` swallows error and produces NULL in `.TRY` mode
	expect_query_column(&fx, "SELECT COALESCE(TRY_CAST('not-a-temp' AS TEMPERATURE_CELSIUS)::INTEGER, -999)", []i32{-999})
	testing.expect_value(t, obs.last_mode, duckdb.V2_Cast_Mode.TRY)
}
