package duckdb_tests

// ============================================================================
// Layer 2: Domain-Specific Language (`tests/dsl.odin`)
// ============================================================================
// Architecture Reference:
// - 4-Layer ATDD Architecture (`/home/pauli/.gemini/config/skills/atdd-executable-specifications/SKILL.md`)
// - Upstream Reference Fixtures:
//   - `test_capi_v2::EnvFixture` (`references/c/duckdb-capi-2.0/test/api/capi/v2/test_capi_v2.hpp` lines 71-94)
//   - `test_cpp_api_core.cpp` lines 37-64 (`Environment::GetInstanceCount()` zero-leak contract)
// ============================================================================

import "core:testing"
import duckdb "../duckdb"

// Scoped V2 ATDD Test Context.
// Automatically pre-creates common primitive `V2_Logical_Type_Handle`s (`bool_type`, `int_type`, `bigint_type`,
// `double_type`, `varchar_type`, `any_type`) and a reusable `err` handle, and verifies on scope exit that
// `duckdb_v2_environment_get_instance_count(env) == 0` and `duckdb_v2_environment_destroy(&env) == .NONE`,
// guaranteeing zero leaked instances or open result handles in any spec!
Test_Env :: struct {
	t:            ^testing.T,
	env:          duckdb.V2_Environment_Handle,
	instance:     duckdb.V2_Instance_Handle,
	conn:         duckdb.V2_Connection_Handle,
	factory:      duckdb.V2_Factory_Handle,
	err:          duckdb.V2_Error_Info_Handle,
	bool_type:    duckdb.V2_Logical_Type_Handle,
	int_type:     duckdb.V2_Logical_Type_Handle,
	bigint_type:  duckdb.V2_Logical_Type_Handle,
	double_type:  duckdb.V2_Logical_Type_Handle,
	varchar_type: duckdb.V2_Logical_Type_Handle,
	any_type:     duckdb.V2_Logical_Type_Handle,
}

@(deferred_out = dsl_teardown_env)
dsl_with_memory_db :: proc(t: ^testing.T) -> Test_Env {
	fx := Test_Env{t = t}

	rc := duckdb.duckdb_v2_environment_create(&fx.env, &fx.err)
	expect_v2_ok(t, rc, &fx.err, "duckdb_v2_environment_create")

	rc = driver_open_instance(fx.env, "", &fx.instance, &fx.err)
	expect_v2_ok(t, rc, &fx.err, "driver_open_instance(:memory:)")

	rc = duckdb.duckdb_v2_connection_create(fx.instance, &fx.conn, &fx.err)
	expect_v2_ok(t, rc, &fx.err, "duckdb_v2_connection_create")

	rc = duckdb.duckdb_v2_connection_get_factory(fx.conn, &fx.factory, &fx.err)
	expect_v2_ok(t, rc, &fx.err, "duckdb_v2_connection_get_factory")

	if fx.factory != nil {
		_ = duckdb.duckdb_v2_factory_create_type_from_id(fx.factory, .BOOLEAN, nil, nil, 0, &fx.bool_type, &fx.err)
		_ = duckdb.duckdb_v2_factory_create_type_from_id(fx.factory, .INTEGER, nil, nil, 0, &fx.int_type, &fx.err)
		_ = duckdb.duckdb_v2_factory_create_type_from_id(fx.factory, .BIGINT, nil, nil, 0, &fx.bigint_type, &fx.err)
		_ = duckdb.duckdb_v2_factory_create_type_from_id(fx.factory, .DOUBLE, nil, nil, 0, &fx.double_type, &fx.err)
		_ = duckdb.duckdb_v2_factory_create_type_from_id(fx.factory, .VARCHAR, nil, nil, 0, &fx.varchar_type, &fx.err)
		_ = duckdb.duckdb_v2_factory_create_type_from_id(fx.factory, .ANY, nil, nil, 0, &fx.any_type, &fx.err)
	}

	return fx
}

dsl_teardown_env :: proc(fx: Test_Env) {
	err := fx.err
	if err != nil {
		_ = duckdb.duckdb_v2_error_info_destroy(&err)
	}

	bool_t := fx.bool_type
	int_t := fx.int_type
	bigint_t := fx.bigint_type
	double_t := fx.double_type
	varchar_t := fx.varchar_type
	any_t := fx.any_type
	_ = duckdb.duckdb_v2_logical_type_destroy(&bool_t)
	_ = duckdb.duckdb_v2_logical_type_destroy(&int_t)
	_ = duckdb.duckdb_v2_logical_type_destroy(&bigint_t)
	_ = duckdb.duckdb_v2_logical_type_destroy(&double_t)
	_ = duckdb.duckdb_v2_logical_type_destroy(&varchar_t)
	_ = duckdb.duckdb_v2_logical_type_destroy(&any_t)

	conn := fx.conn
	instance := fx.instance
	env := fx.env

	if conn != nil {
		rc := duckdb.duckdb_v2_connection_destroy(&conn)
		testing.expect_value(fx.t, rc, duckdb.V2_Error.NONE)
	}
	if instance != nil {
		rc := duckdb.duckdb_v2_instance_destroy(&instance)
		testing.expect_value(fx.t, rc, duckdb.V2_Error.NONE)
	}
	if env != nil {
		live_instances: duckdb.V2_Idx = 999
		rc := duckdb.duckdb_v2_environment_get_instance_count(env, &live_instances, nil)
		testing.expect_value(fx.t, rc, duckdb.V2_Error.NONE)
		testing.expectf(
			fx.t,
			live_instances == 0,
			"Expected 0 live instances in V2 environment at test teardown, got %d",
			live_instances,
		)

		rc = duckdb.duckdb_v2_environment_destroy(&env)
		testing.expect_value(fx.t, rc, duckdb.V2_Error.NONE)
	}
}

// High-signal assertion helper for `V2_Error` + `V2_Error_Info_Handle`.
expect_v2_ok :: proc(
	t: ^testing.T,
	rc: duckdb.V2_Error,
	err: ^duckdb.V2_Error_Info_Handle = nil,
	context_label: string = "",
	loc := #caller_location,
) -> bool {
	if rc == .NONE {
		if err != nil && err^ != nil {
			duckdb.duckdb_v2_error_info_destroy(err)
		}
		return true
	}
	_, msg := driver_consume_error_text(err)
	testing.expectf(t, false, "[%s] expected V2_Error.NONE, got %v: %s", context_label, rc, msg, loc = loc)
	return false
}

// High-signal assertion that a C API v2 operation fails with `expected_err`.
expect_v2_error :: proc(
	t: ^testing.T,
	rc: duckdb.V2_Error,
	expected_err: duckdb.V2_Error,
	err: ^duckdb.V2_Error_Info_Handle = nil,
	loc := #caller_location,
) -> string {
	info_code, msg := driver_consume_error_text(err)
	testing.expect_value(t, rc, expected_err, loc = loc)
	if info_code != .NONE {
		testing.expect_value(t, info_code, expected_err, loc = loc)
	}
	return msg
}

// Asserts that `sql` executes cleanly and drains with `expected_changed_rows`.
expect_exec_changed_rows :: proc(
	fx: ^Test_Env,
	sql: string,
	expected_changed_rows: duckdb.V2_Idx,
	loc := #caller_location,
) {
	changed: duckdb.V2_Idx
	rc := driver_exec_drain(fx.conn, sql, &changed, &fx.err)
	if expect_v2_ok(fx.t, rc, &fx.err, sql, loc = loc) {
		testing.expect_value(fx.t, changed, expected_changed_rows, loc = loc)
	}
}

// Executes `sql`, collects column `col_idx` as `[]T`, and asserts it matches `expected`.
expect_query_column :: proc(
	fx: ^Test_Env,
	sql: string,
	expected: []$T,
	col_idx: duckdb.V2_Idx = 0,
	loc := #caller_location,
) {
	res: duckdb.V2_Result_Handle
	rc := driver_query(fx.conn, sql, &res, &fx.err)
	if !expect_v2_ok(fx.t, rc, &fx.err, sql, loc = loc) {
		return
	}
	rows, collect_rc := driver_collect_column(T, &res, col_idx)
	if expect_v2_ok(fx.t, collect_rc, nil, sql, loc = loc) {
		expect_slice_equal(fx.t, rows[:], expected, loc = loc)
	}
}

// Asserts that column `col_idx` of `result` has `expected_name` and `expected_type`.
// Mirrors `test_capi_v2::RequireColumn` in `references/c/duckdb-capi-2.0/test/api/capi/v2/test_capi_v2.hpp` lines 283-294.
expect_result_column :: proc(
	t: ^testing.T,
	result: duckdb.V2_Result_Handle,
	col_idx: duckdb.V2_Idx,
	expected_name: string,
	expected_type: duckdb.V2_Logical_Type_Id,
	loc := #caller_location,
) {
	schema: duckdb.V2_Schema_Handle
	rc := duckdb.duckdb_v2_result_get_schema(result, &schema, nil)
	testing.expect_value(t, rc, duckdb.V2_Error.NONE, loc = loc)
	defer duckdb.duckdb_v2_schema_destroy(&schema)

	field_name: duckdb.V2_Identifier
	field_type: duckdb.V2_Logical_Type_Handle // Borrowed from `schema` — MUST NOT destroy!
	rc = duckdb.duckdb_v2_schema_get_field(schema, col_idx, &field_name, &field_type, nil)
	testing.expect_value(t, rc, duckdb.V2_Error.NONE, loc = loc)
	testing.expect_value(t, duckdb.v2_str_to_string(field_name), expected_name, loc = loc)

	got_id: duckdb.V2_Logical_Type_Id
	rc = duckdb.duckdb_v2_logical_type_get_id(field_type, &got_id, nil)
	testing.expect_value(t, rc, duckdb.V2_Error.NONE, loc = loc)
	testing.expect_value(t, got_id, expected_type, loc = loc)
}

// Polymorphic slice equality assertion.
expect_slice_equal :: proc(
	t: ^testing.T,
	actual: []$T,
	expected: []T,
	loc := #caller_location,
) {
	testing.expect_value(t, len(actual), len(expected), loc = loc)
	count := min(len(actual), len(expected))
	for i in 0 ..< count {
		testing.expect_value(t, actual[i], expected[i], loc = loc)
	}
}
