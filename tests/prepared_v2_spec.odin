package duckdb_tests

// ============================================================================
// Layer 1: Executable Specifications (`tests/prepared_v2_spec.odin`)
// ============================================================================
// Direct ATDD port of all 5 Catch2 test suites from:
// - `references/c/duckdb-capi-2.0/tools/cpp/tests/test_cpp_api_prepared_statement.cpp`
//   1. `TEST_CASE("Stable C++API: PreparedStatement executes repeatedly", "[cpp_api][prepared_statement]")` (lines 34-60)
//   2. `TEST_CASE("Stable C++API: PreparedStatement binds named parameters", "[cpp_api][prepared_statement]")` (lines 62-81)
//   3. `TEST_CASE("Stable C++API: PreparedStatement reports plan reuse", "[cpp_api][prepared_statement]")` (lines 83-104)
//   4. `TEST_CASE("Stable C++API: PreparedStatement lifetimes", "[cpp_api][prepared_statement]")` (lines 106-137)
//   5. `TEST_CASE("Stable C++API: PreparedStatement error paths", "[cpp_api][prepared_statement]")` (lines 139-163)
// ============================================================================

import "core:testing"
import duckdb "../duckdb"

// Upstream Reference:
// - `references/c/duckdb-capi-2.0/tools/cpp/tests/test_cpp_api_prepared_statement.cpp` lines 34-81
@(test)
spec_v2_prepared_statement_positional_and_named_parameters :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)

	expect_exec_changed_rows(&fx, "CREATE TABLE t(x BIGINT)", 0)
	expect_exec_changed_rows(&fx, "INSERT INTO t VALUES (1), (2), (3), (4)", 4)

	// 1. Positional parameters (`$1`) executed repeatedly (`test_cpp_api_prepared_statement.cpp` lines 34-60):
	{
		prepared: duckdb.V2_Prepared_Statement_Handle
		expect_v2_ok(t, driver_prepare(fx.conn, "SELECT x FROM t WHERE x > $1 ORDER BY x", false, &prepared))
		defer duckdb.duckdb_v2_prepared_statement_destroy(&prepared)

		val_0, val_2: duckdb.V2_Value_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_bigint(fx.factory, 0, &val_0, nil))
		defer duckdb.duckdb_v2_value_destroy(&val_0)
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_bigint(fx.factory, 2, &val_2, nil))
		defer duckdb.duckdb_v2_value_destroy(&val_2)

		params_0 := [1]duckdb.V2_Value_Handle{val_0}
		params_2 := [1]duckdb.V2_Value_Handle{val_2}

		res1: duckdb.V2_Result_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_prepared_statement_execute(prepared, nil, &params_0[0], 1, &res1, &fx.err), &fx.err)
		rows1, rc1 := driver_collect_column(i64, &res1)
		expect_v2_ok(t, rc1)
		expect_slice_equal(t, rows1[:], []i64{1, 2, 3, 4})

		res2: duckdb.V2_Result_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_prepared_statement_execute(prepared, nil, &params_2[0], 1, &res2, &fx.err), &fx.err)
		rows2, rc2 := driver_collect_column(i64, &res2)
		expect_v2_ok(t, rc2)
		expect_slice_equal(t, rows2[:], []i64{3, 4})

		res3: duckdb.V2_Result_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_prepared_statement_execute(prepared, nil, &params_0[0], 1, &res3, &fx.err), &fx.err)
		rows3, rc3 := driver_collect_column(i64, &res3)
		expect_v2_ok(t, rc3)
		expect_slice_equal(t, rows3[:], []i64{1, 2, 3, 4})
	}

	// 2. Named parameters (`$a - $b`) are order-independent (`test_cpp_api_prepared_statement.cpp` lines 62-81):
	{
		prepared: duckdb.V2_Prepared_Statement_Handle
		expect_v2_ok(t, driver_prepare(fx.conn, "SELECT $a - $b", false, &prepared, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_prepared_statement_destroy(&prepared)

		val_10, val_4: duckdb.V2_Value_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_bigint(fx.factory, 10, &val_10, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&val_10)
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_bigint(fx.factory, 4, &val_4, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&val_4)

		names_ab := [2]duckdb.V2_Identifier{
			duckdb.v2_str_from_string("a"),
			duckdb.v2_str_from_string("b"),
		}
		vals_ab := [2]duckdb.V2_Value_Handle{val_10, val_4}

		res_ab: duckdb.V2_Result_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_prepared_statement_execute(prepared, &names_ab[0], &vals_ab[0], 2, &res_ab, &fx.err), &fx.err)
		rows_ab, _ := driver_collect_column(i64, &res_ab)
		expect_slice_equal(t, rows_ab[:], []i64{6})

		// Swapping `(b=4, a=10)` produces the exact same result:
		names_ba := [2]duckdb.V2_Identifier{
			duckdb.v2_str_from_string("b"),
			duckdb.v2_str_from_string("a"),
		}
		vals_ba := [2]duckdb.V2_Value_Handle{val_4, val_10}

		res_ba: duckdb.V2_Result_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_prepared_statement_execute(prepared, &names_ba[0], &vals_ba[0], 2, &res_ba, &fx.err), &fx.err)
		rows_ba, _ := driver_collect_column(i64, &res_ba)
		expect_slice_equal(t, rows_ba[:], []i64{6})
	}
}

// Upstream Reference:
// - `references/c/duckdb-capi-2.0/tools/cpp/tests/test_cpp_api_prepared_statement.cpp` lines 83-163
@(test)
spec_v2_prepared_statement_plan_reuse_lifetimes_and_errors :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)
	expect_exec_changed_rows(&fx, "CREATE TABLE t(x BIGINT)", 0)
	expect_exec_changed_rows(&fx, "INSERT INTO t VALUES (1), (2), (3), (4)", 4)

	// 1. Plan reuse reporting & `require_cacheable` (`test_cpp_api_prepared_statement.cpp` lines 83-104):
	{
		p_const: duckdb.V2_Prepared_Statement_Handle
		expect_v2_ok(t, driver_prepare(fx.conn, "SELECT 42", false, &p_const))
		defer duckdb.duckdb_v2_prepared_statement_destroy(&p_const)
		reuses := false
		expect_v2_ok(t, duckdb.duckdb_v2_prepared_statement_reuses_plan(p_const, &reuses, nil))
		testing.expect(t, reuses)

		p_typed_param: duckdb.V2_Prepared_Statement_Handle
		expect_v2_ok(t, driver_prepare(fx.conn, "SELECT $1::BIGINT + 1", true, &p_typed_param))
		defer duckdb.duckdb_v2_prepared_statement_destroy(&p_typed_param)
		expect_v2_ok(t, duckdb.duckdb_v2_prepared_statement_reuses_plan(p_typed_param, &reuses, nil))
		testing.expect(t, reuses)

		// Base table scan re-binds each execution so catalog changes are picked up:
		p_table: duckdb.V2_Prepared_Statement_Handle
		expect_v2_ok(t, driver_prepare(fx.conn, "SELECT x FROM t WHERE x = $1", false, &p_table))
		defer duckdb.duckdb_v2_prepared_statement_destroy(&p_table)
		expect_v2_ok(t, duckdb.duckdb_v2_prepared_statement_reuses_plan(p_table, &reuses, nil))
		testing.expect(t, !reuses)

		// Passing `require_cacheable = true` on a non-cacheable plan fails with `INPUT_INVALID` (`2001`):
		p_fail: duckdb.V2_Prepared_Statement_Handle
		rc := driver_prepare(fx.conn, "SELECT x FROM t WHERE x = $1", true, &p_fail, &fx.err)
		expect_v2_error(t, rc, .INPUT_INVALID, &fx.err)
	}

	// 2. Lifetimes (`test_cpp_api_prepared_statement.cpp` lines 106-137):
	//    (a) A result outlives the prepared statement that created it.
	//    (b) A prepared statement outlives the connection that created it.
	{
		temp_conn: duckdb.V2_Connection_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_connection_create(fx.instance, &temp_conn, &fx.err), &fx.err)

		prepared: duckdb.V2_Prepared_Statement_Handle
		expect_v2_ok(t, driver_prepare(temp_conn, "SELECT x FROM t ORDER BY x", false, &prepared, &fx.err), &fx.err)

		// Destroy `temp_conn` while `prepared` is still alive:
		expect_v2_ok(t, duckdb.duckdb_v2_connection_destroy(&temp_conn))

		// Execute `prepared` after its connection was destroyed, then destroy `prepared` before draining `res`:
		res: duckdb.V2_Result_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_prepared_statement_execute(prepared, nil, nil, 0, &res, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_prepared_statement_destroy(&prepared))

		rows, rc := driver_collect_column(i64, &res)
		expect_v2_ok(t, rc)
		expect_slice_equal(t, rows[:], []i64{1, 2, 3, 4})
	}

	// 3. Error paths (`test_cpp_api_prepared_statement.cpp` lines 139-163):
	//    - Prepare-time catalog error returns `DATABASE_CATALOG` (`6001`)
	//    - Busy connection with a live result refuses both `Prepare` and `Execute` with `RESOURCE_IN_USE` (`3001`)
	{
		bad_prep: duckdb.V2_Prepared_Statement_Handle
		rc := driver_prepare(fx.conn, "SELECT * FROM no_such_table", false, &bad_prep, &fx.err)
		expect_v2_error(t, rc, .DATABASE_CATALOG, &fx.err)

		prepared: duckdb.V2_Prepared_Statement_Handle
		expect_v2_ok(t, driver_prepare(fx.conn, "SELECT 1::BIGINT", false, &prepared, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_prepared_statement_destroy(&prepared)

		live: duckdb.V2_Result_Handle
		expect_v2_ok(t, driver_query(fx.conn, "SELECT i FROM range(100000) t(i)", &live, &fx.err), &fx.err)

		blocked_prep: duckdb.V2_Prepared_Statement_Handle
		expect_v2_error(
			t,
			driver_prepare(fx.conn, "SELECT 1::BIGINT", false, &blocked_prep, &fx.err),
			.RESOURCE_IN_USE,
			&fx.err,
		)

		blocked_res: duckdb.V2_Result_Handle
		expect_v2_error(
			t,
			duckdb.duckdb_v2_prepared_statement_execute(prepared, nil, nil, 0, &blocked_res, &fx.err),
			.RESOURCE_IN_USE,
			&fx.err,
		)

		duckdb.duckdb_v2_result_destroy(&live)
	}
}
