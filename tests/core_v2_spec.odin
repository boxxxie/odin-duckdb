package duckdb_tests

// ============================================================================
// Layer 1: Executable Specifications (`tests/core_v2_spec.odin`)
// ============================================================================
// Every `@(test)` specification below is a direct ATDD port of an authoritative
// upstream DuckDB 2.0 test case from our cloned `references/` repositories:
//
// 1. `spec_v2_environment_instance_lifecycle_and_leak_detection`
//    -> `references/c/duckdb-capi-2.0/tools/cpp/tests/test_cpp_api_core.cpp` lines 37-64
//    -> `references/c/duckdb-capi-2.0/test/api/capi/v2/test_capi_v2_basic.cpp`
// 2. `spec_v2_bytes_layout_inlined_pointer_bit_and_bignum`
//    -> `references/c/duckdb-capi-2.0/test/api/capi/v2/test_capi_v2_bytes.cpp` lines 97-190
// 3. `spec_v2_streaming_step_drain_and_busy_connection_guard`
//    -> `references/c/duckdb-capi-2.0/tools/cpp/tests/test_cpp_api_query.cpp` lines 32-100
//    -> `references/node/duckdb-node-neo/tools/capi-v2/open_result_probe.c`
// 4. `spec_v2_column_data_collection_appender_via_statement_add_collection`
//    -> `references/c/duckdb-capi-2.0/tools/cpp/tests/test_cpp_api_appender.cpp` lines 53-120
//    -> `references/c/duckdb-capi-2.0/tools/cpp/duckdb_cpp.cpp` lines 7246-7320
// 5. `spec_v2_sqllogic_harness_duckdb2_queries_and_errors`
//    -> `references/duckdb2/duckdb-quack/test/sql/whoami.test`
//    -> `references/duckdb2/duckdb-quack/test/sql/serve_canonical.test`
// ============================================================================

import "core:strings"
import "core:testing"
import duckdb "../duckdb"

// Upstream Reference:
// - `references/c/duckdb-capi-2.0/tools/cpp/tests/test_cpp_api_core.cpp` lines 37-64
//   `TEST_CASE("Stable C++API: instances can live in an explicit environment", "[cpp_api]")`
@(test)
spec_v2_environment_instance_lifecycle_and_leak_detection :: proc(t: ^testing.T) {
	ver: duckdb.V2_Str
	rc := duckdb.duckdb_v2_library_version(&ver, nil)
	testing.expect_value(t, rc, duckdb.V2_Error.NONE)
	ver_str := duckdb.v2_str_to_string(ver)
	testing.expectf(t, strings.has_prefix(ver_str, "v2.0.0"), "Expected DuckDB v2.0.0, got %s", ver_str)

	env: duckdb.V2_Environment_Handle
	rc = duckdb.duckdb_v2_environment_create(&env, nil)
	testing.expect_value(t, rc, duckdb.V2_Error.NONE)

	count: duckdb.V2_Idx = 99
	rc = duckdb.duckdb_v2_environment_get_instance_count(env, &count, nil)
	testing.expect_value(t, rc, duckdb.V2_Error.NONE)
	testing.expect_value(t, count, duckdb.V2_Idx(0))

	inst1, inst2: duckdb.V2_Instance_Handle
	testing.expect_value(t, duckdb.duckdb_v2_instance_create(env, &inst1, nil), duckdb.V2_Error.NONE)
	testing.expect_value(t, driver_open_instance(env, "", &inst2, nil), duckdb.V2_Error.NONE)

	// Environment tracks exact live instance count (`test_cpp_api_core.cpp` line 47):
	testing.expect_value(t, duckdb.duckdb_v2_environment_get_instance_count(env, &count, nil), duckdb.V2_Error.NONE)
	testing.expect_value(t, count, duckdb.V2_Idx(2))

	// Destroying an environment while instances are still alive MUST refuse with `RESOURCE_IN_USE` (`3001`):
	testing.expect_value(t, duckdb.duckdb_v2_environment_destroy(&env), duckdb.V2_Error.RESOURCE_IN_USE)

	// Destroy both instances and verify environment count drops back to 0:
	testing.expect_value(t, duckdb.duckdb_v2_instance_destroy(&inst2), duckdb.V2_Error.NONE)
	testing.expect_value(t, duckdb.duckdb_v2_instance_destroy(&inst1), duckdb.V2_Error.NONE)
	testing.expect_value(t, duckdb.duckdb_v2_environment_get_instance_count(env, &count, nil), duckdb.V2_Error.NONE)
	testing.expect_value(t, count, duckdb.V2_Idx(0))

	testing.expect_value(t, duckdb.duckdb_v2_environment_destroy(&env), duckdb.V2_Error.NONE)
	testing.expect_value(t, env, duckdb.V2_Environment_Handle(nil))
}

// Upstream Reference:
// - `references/c/duckdb-capi-2.0/test/api/capi/v2/test_capi_v2_bytes.cpp` lines 97-190
//   - `TEST_CASE("V2 bytes layout: direct reads match V1 equivalents", "[capi_v2][bytes_layout]")`
//   - `TEST_CASE("V2 bytes layout: BIT reads via the transparent split", "[capi_v2][bytes_layout]")`
//   - `TEST_CASE("V2 bytes layout: BIGNUM sign matches bignum_decode", "[capi_v2][bytes_layout]")`
@(test)
spec_v2_bytes_layout_inlined_pointer_bit_and_bignum :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)

	// 1. Inlined ("short", 5 bytes <= 12) vs Pointer (repeat('x', 50), 50 bytes > 12)
	{
		res: duckdb.V2_Result_Handle
		rc := driver_query(fx.conn, "SELECT * FROM (VALUES ('short'), (repeat('x', 50))) t(s)", &res)
		expect_v2_ok(t, rc, nil, "query bytes")
		defer duckdb.duckdb_v2_result_destroy(&res)

		expect_result_column(t, res, 0, "s", .VARCHAR)

		chunk: duckdb.V2_Data_Chunk_Handle
		status, step_rc := driver_step_chunk(res, &chunk)
		expect_v2_ok(t, step_rc)
		testing.expect_value(t, status, duckdb.V2_Result_Step_Status.CHUNK)
		defer duckdb.duckdb_v2_data_chunk_destroy(&chunk)

		vec: duckdb.V2_Vector_Handle
		testing.expect_value(t, duckdb.duckdb_v2_data_chunk_get_vector(chunk, 0, &vec, nil), duckdb.V2_Error.NONE)
		view: duckdb.V2_Vector_View
		testing.expect_value(t, duckdb.duckdb_v2_vector_get_view(vec, &view, nil), duckdb.V2_Error.NONE)

		arr := cast([^]duckdb.V2_Bytes)view.data
		r0 := &arr[duckdb.v2_sel_at(view.sel, 0)]
		r1 := &arr[duckdb.v2_sel_at(view.sel, 1)]

		testing.expect(t, duckdb.v2_bytes_is_inlined(r0))
		testing.expect(t, !duckdb.v2_bytes_is_inlined(r1))
		testing.expect_value(t, duckdb.v2_bytes_length(r0), u32(5))
		testing.expect_value(t, duckdb.v2_bytes_length(r1), u32(50))
		testing.expect_value(t, duckdb.v2_bytes_to_string(r0), "short")
		testing.expect_value(t, r1.pointer.prefix, [4]u8{'x', 'x', 'x', 'x'})
	}

	// 2. Transparent BIT wire split (`'11111111'::BIT` -> padding=0, count=8; `'101'::BIT` -> padding=5, count=3)
	{
		res: duckdb.V2_Result_Handle
		rc := driver_query(fx.conn, "SELECT * FROM (VALUES ('11111111'::BIT), ('101'::BIT)) t(b)", &res)
		expect_v2_ok(t, rc, nil, "query bit")
		defer duckdb.duckdb_v2_result_destroy(&res)

		chunk: duckdb.V2_Data_Chunk_Handle
		status, _ := driver_step_chunk(res, &chunk)
		testing.expect_value(t, status, duckdb.V2_Result_Step_Status.CHUNK)
		defer duckdb.duckdb_v2_data_chunk_destroy(&chunk)

		vec: duckdb.V2_Vector_Handle
		_ = duckdb.duckdb_v2_data_chunk_get_vector(chunk, 0, &vec, nil)
		view: duckdb.V2_Vector_View
		_ = duckdb.duckdb_v2_vector_get_view(vec, &view, nil)

		arr := cast([^]duckdb.V2_Bit)view.data
		r0 := &arr[duckdb.v2_sel_at(view.sel, 0)]
		r1 := &arr[duckdb.v2_sel_at(view.sel, 1)]

		testing.expect_value(t, duckdb.v2_bit_padding(r0), u8(0))
		testing.expect_value(t, duckdb.v2_bit_count(r0), u64(8))
		testing.expect_value(t, duckdb.v2_bit_data(r0)[0], u8(0xFF))

		testing.expect_value(t, duckdb.v2_bit_padding(r1), u8(5))
		testing.expect_value(t, duckdb.v2_bit_count(r1), u64(3))
	}

	// 3. BIGNUM sign vs `duckdb_v2_bignum_decode` (`test_capi_v2_bytes.cpp` lines 162-189)
	{
		res: duckdb.V2_Result_Handle
		rc := driver_query(
			fx.conn,
			"SELECT * FROM (VALUES (340282366920938463463374607431768211455::BIGNUM), (-256::BIGNUM)) t(b)",
			&res,
		)
		expect_v2_ok(t, rc, nil, "query bignum")
		defer duckdb.duckdb_v2_result_destroy(&res)

		chunk: duckdb.V2_Data_Chunk_Handle
		_, _ = driver_step_chunk(res, &chunk)
		defer duckdb.duckdb_v2_data_chunk_destroy(&chunk)

		vec: duckdb.V2_Vector_Handle
		_ = duckdb.duckdb_v2_data_chunk_get_vector(chunk, 0, &vec, nil)
		view: duckdb.V2_Vector_View
		_ = duckdb.duckdb_v2_vector_get_view(vec, &view, nil)

		arr := cast([^]duckdb.V2_Bignum)view.data
		for row: duckdb.V2_Idx = 0; row < 2; row += 1 {
			b := &arr[duckdb.v2_sel_at(view.sel, row)]
			mag_len: duckdb.V2_Idx
			dec_neg := false
			dec_rc := duckdb.duckdb_v2_bignum_decode(
				duckdb.v2_bytes_data(b),
				duckdb.V2_Idx(duckdb.v2_bytes_length(b)),
				nil,
				0,
				&mag_len,
				&dec_neg,
				nil,
			)
			testing.expect_value(t, dec_rc, duckdb.V2_Error.NONE)
			testing.expect_value(t, duckdb.v2_bignum_is_negative(b), dec_neg)
		}
		testing.expect(t, !duckdb.v2_bignum_is_negative(&arr[duckdb.v2_sel_at(view.sel, 0)]))
		testing.expect(t, duckdb.v2_bignum_is_negative(&arr[duckdb.v2_sel_at(view.sel, 1)]))
	}
}

// Upstream Reference:
// - `references/c/duckdb-capi-2.0/tools/cpp/tests/test_cpp_api_query.cpp` lines 32-100
//   - `TEST_CASE("Stable C++API: step loop drains a multi-chunk result", "[cpp_api]")`
//   - `TEST_CASE("Stable C++API: Drain applies side effects and reports rows changed", "[cpp_api]")`
//   - `TEST_CASE("Stable C++API: a busy connection refuses new work with RESOURCE_IN_USE", "[cpp_api]")`
@(test)
spec_v2_streaming_step_drain_and_busy_connection_guard :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)

	// 1. Multi-chunk step loop (`range(100000)`) + sticky FINISHED status:
	{
		res: duckdb.V2_Result_Handle
		expect_v2_ok(t, driver_query(fx.conn, "SELECT i FROM range(100000) t(i)", &res))
		defer duckdb.duckdb_v2_result_destroy(&res)

		total_rows: duckdb.V2_Idx = 0
		chunk_count: duckdb.V2_Idx = 0
		for {
			chunk: duckdb.V2_Data_Chunk_Handle
			status, rc := driver_step_chunk(res, &chunk)
			expect_v2_ok(t, rc)
			if status == .CHUNK {
				sz: duckdb.V2_Idx
				_ = duckdb.duckdb_v2_data_chunk_get_size(chunk, &sz, nil)
				total_rows += sz
				chunk_count += 1
				duckdb.duckdb_v2_data_chunk_destroy(&chunk)
				continue
			}
			testing.expect_value(t, status, duckdb.V2_Result_Step_Status.FINISHED)
			break
		}
		testing.expect_value(t, total_rows, duckdb.V2_Idx(100000))
		testing.expect(t, chunk_count > 1)

		// FINISHED is sticky:
		extra_chunk: duckdb.V2_Data_Chunk_Handle
		sticky_status, sticky_rc := driver_step_chunk(res, &extra_chunk)
		expect_v2_ok(t, sticky_rc)
		testing.expect_value(t, sticky_status, duckdb.V2_Result_Step_Status.FINISHED)
		testing.expect_value(t, extra_chunk, duckdb.V2_Data_Chunk_Handle(nil))
	}

	// 2. `Drain()` applies side effects and reports affected rows (`test_cpp_api_query.cpp` lines 67-84):
	expect_exec_changed_rows(&fx, "CREATE TABLE t (i INTEGER)", 0)
	expect_exec_changed_rows(&fx, "INSERT INTO t VALUES (1), (2), (3)", 3)
	expect_exec_changed_rows(&fx, "DELETE FROM t WHERE i = 1", 1)

	// 3. A busy connection with an undrained result refuses new queries with `RESOURCE_IN_USE` (`3001`):
	{
		live: duckdb.V2_Result_Handle
		expect_v2_ok(t, driver_query(fx.conn, "SELECT i FROM range(100000) t(i)", &live))
		defer duckdb.duckdb_v2_result_destroy(&live)

		second: duckdb.V2_Result_Handle
		err: duckdb.V2_Error_Info_Handle
		rc := driver_query(fx.conn, "SELECT 1", &second, &err)
		expect_v2_error(t, rc, .RESOURCE_IN_USE, &err)

		// Draining `live` frees the connection immediately:
		changed: duckdb.V2_Idx
		expect_v2_ok(t, duckdb.duckdb_v2_result_drain(live, &changed, nil))

		expect_v2_ok(t, driver_query(fx.conn, "SELECT 1", &second))
		duckdb.duckdb_v2_result_destroy(&second)
	}
}

// Upstream Reference:
// - `references/c/duckdb-capi-2.0/tools/cpp/tests/test_cpp_api_appender.cpp` lines 53-80
//   `TEST_CASE("Stable C++API: appender buffers and flushes into a table", "[cpp_api]")`
// - `references/c/duckdb-capi-2.0/tools/cpp/duckdb_cpp.cpp` lines 7246-7320
@(test)
spec_v2_column_data_collection_appender_via_statement_add_collection :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)

	expect_exec_changed_rows(&fx, "CREATE TABLE t (v BIGINT)", 0)

	// Create and populate `BIGINT` `ColumnDataCollection` buffer with `[10, 20, 30]` via Layer 3 driver:
	collection: duckdb.V2_Column_Data_Collection_Handle
	expect_v2_ok(t, driver_make_collection(i64, fx.factory, fx.bigint_type, []i64{10, 20, 30}, &collection, &fx.err), &fx.err)
	defer duckdb.duckdb_v2_column_data_collection_destroy(&collection)

	buffered_rows: duckdb.V2_Idx
	expect_v2_ok(t, duckdb.duckdb_v2_column_data_collection_row_count(collection, &buffered_rows, &fx.err), &fx.err)
	testing.expect_value(t, buffered_rows, duckdb.V2_Idx(3))

	// Parse `INSERT INTO t SELECT * FROM __odin_appender_buf`, bind `collection` via `duckdb_v2_statement_add_collection`, and flush:
	stmt: duckdb.V2_Sql_Statement_Handle
	expect_v2_ok(t, driver_parse_single_stmt(fx.conn, "INSERT INTO t SELECT * FROM __odin_appender_buf", &stmt, &fx.err), &fx.err)
	defer duckdb.duckdb_v2_sql_statement_destroy(&stmt)

	cte_name := duckdb.v2_str_from_string("__odin_appender_buf")
	expect_v2_ok(t, duckdb.duckdb_v2_statement_add_collection(stmt, &cte_name, collection, nil, 0, &fx.err), &fx.err)

	res: duckdb.V2_Result_Handle
	expect_v2_ok(t, duckdb.duckdb_v2_statement_execute(fx.conn, stmt, nil, nil, 0, &res, &fx.err), &fx.err)
	flushed_rows: duckdb.V2_Idx
	expect_v2_ok(t, duckdb.duckdb_v2_result_drain(res, &flushed_rows, &fx.err), &fx.err)
	duckdb.duckdb_v2_result_destroy(&res)
	testing.expect_value(t, flushed_rows, duckdb.V2_Idx(3))

	// Verify via Layer 3 SQLLogicTest runner:
	sqllogic_query_rows(&fx, "SELECT v FROM t ORDER BY v", []string{"10", "20", "30"})
}

// Upstream Reference:
// - `references/c/duckdb-capi-2.0/test/api/capi/v2/test_capi_v2_identifier.cpp` lines 31-95
// - `references/c/duckdb-capi-2.0/test/api/capi/v2/test_capi_v2_statement.cpp` lines 1-180
@(test)
spec_v2_identifier_quoting_statement_bind_and_multi_statement :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)

	// 1. `duckdb_v2_identifier_render_quoted` quotes keywords, spaces, digits, and embedded quotes (`test_capi_v2_identifier.cpp`):
	{
		q_plain, rc1 := driver_render_identifier_quoted("col")
		expect_v2_ok(t, rc1)
		testing.expect_value(t, q_plain, "col")

		q_mixed, rc2 := driver_render_identifier_quoted("MyCol")
		expect_v2_ok(t, rc2)
		testing.expect_value(t, q_mixed, "MyCol")

		q_kw, rc3 := driver_render_identifier_quoted("select")
		expect_v2_ok(t, rc3)
		testing.expect_value(t, q_kw, "\"select\"")

		q_space, rc4 := driver_render_identifier_quoted("my col")
		expect_v2_ok(t, rc4)
		testing.expect_value(t, q_space, "\"my col\"")

		q_digit, rc5 := driver_render_identifier_quoted("1abc")
		expect_v2_ok(t, rc5)
		testing.expect_value(t, q_digit, "\"1abc\"")

		q_quote, rc6 := driver_render_identifier_quoted("a\"b")
		expect_v2_ok(t, rc6)
		testing.expect_value(t, q_quote, "\"a\"\"b\"")

		// Buffer sizing error contract (`INPUT_OBJECT_SIZE`) and invalid UTF-8 (`INPUT_INVALID`):
		small_buf: [4]u8
		req_len: duckdb.V2_Idx
		id_space := duckdb.v2_str_from_string("my col")
		expect_v2_error(
			t,
			duckdb.duckdb_v2_identifier_render_quoted(&id_space, &small_buf[0], len(small_buf), &req_len, &fx.err),
			.INPUT_OBJECT_SIZE,
			&fx.err,
		)
		testing.expect_value(t, req_len, duckdb.V2_Idx(8))

		bad_utf8 := [1]u8{0x80}
		id_bad := duckdb.V2_Str{ptr = &bad_utf8[0], len = 1}
		expect_v2_error(
			t,
			duckdb.duckdb_v2_identifier_render_quoted(&id_bad, nil, 0, &req_len, &fx.err),
			.INPUT_INVALID,
			&fx.err,
		)
	}

	// 2. `duckdb_v2_statement_bind` inspects result schema & parameter schema before execution (`test_capi_v2_statement.cpp`):
	{
		stmt: duckdb.V2_Sql_Statement_Handle
		expect_v2_ok(t, driver_parse_single_stmt(fx.conn, "SELECT $a::BIGINT + $b::BIGINT AS total, 'ok' AS tag", &stmt, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_sql_statement_destroy(&stmt)

		stmt_type: duckdb.V2_Statement_Type
		expect_v2_ok(t, duckdb.duckdb_v2_sql_statement_get_type(stmt, &stmt_type, &fx.err), &fx.err)
		testing.expect_value(t, stmt_type, duckdb.V2_Statement_Type.SELECT)

		schema, params_schema: duckdb.V2_Schema_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_statement_bind(fx.conn, stmt, &schema, &params_schema, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_schema_destroy(&schema)
		defer duckdb.duckdb_v2_schema_destroy(&params_schema)

		field_count: duckdb.V2_Idx
		expect_v2_ok(t, duckdb.duckdb_v2_schema_get_count(schema, &field_count, &fx.err), &fx.err)
		testing.expect_value(t, field_count, duckdb.V2_Idx(2))

		param_count: duckdb.V2_Idx
		expect_v2_ok(t, duckdb.duckdb_v2_sql_statement_get_parameter_count(stmt, &param_count, &fx.err), &fx.err)
		testing.expect_value(t, param_count, duckdb.V2_Idx(2))

		p_name: duckdb.V2_Identifier
		expect_v2_ok(t, duckdb.duckdb_v2_sql_statement_get_parameter_name(stmt, 0, &p_name, &fx.err), &fx.err)
		testing.expect_value(t, duckdb.v2_str_to_string(p_name), "a")
	}

	// 3. Multi-statement SQL iteration (`SELECT 10; SELECT 20;`) and `duckdb_v2_connection_interrupt`:
	{
		iter: duckdb.V2_Statement_Iterator_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_parse_sql(fx.conn, "SELECT 10::BIGINT; SELECT 20::BIGINT;", &iter, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_statement_iterator_destroy(&iter)

		collected := make([dynamic]i64, context.temp_allocator)
		for {
			stmt: duckdb.V2_Sql_Statement_Handle
			expect_v2_ok(t, duckdb.duckdb_v2_statement_iterator_next(iter, &stmt, &fx.err), &fx.err)
			if stmt == nil {
				break
			}
			res: duckdb.V2_Result_Handle
			expect_v2_ok(t, duckdb.duckdb_v2_statement_execute(fx.conn, stmt, nil, nil, 0, &res, &fx.err), &fx.err)
			duckdb.duckdb_v2_sql_statement_destroy(&stmt)
			rows, rc := driver_collect_column(i64, &res)
			expect_v2_ok(t, rc)
			for v in rows {
				append(&collected, v)
			}
		}
		expect_slice_equal(t, collected[:], []i64{10, 20})

		// Interrupting an idle connection is a safe no-op:
		expect_v2_ok(t, duckdb.duckdb_v2_connection_interrupt(fx.conn, &fx.err), &fx.err)
	}
}

// Upstream Reference:
// - `references/duckdb2/duckdb-quack/test/sql/whoami.test`
// - `references/duckdb2/duckdb-claude-plugin/skills/duckdb-sql/SKILL.md` (DuckDB 2.0 friendly SQL)
@(test)
spec_v2_sqllogic_harness_duckdb2_queries_and_errors :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)

	sqllogic_statement_ok(&fx, "CREATE TABLE metrics (node VARCHAR, region VARCHAR, latency_ms INTEGER)")
	sqllogic_statement_ok(
		&fx,
		"INSERT INTO metrics VALUES ('test-node-1', 'eu-west-1', 12), ('test-node-2', 'us-east-1', 28)",
	)

	// DuckDB 2.0 `FROM`-first friendly SQL query:
	sqllogic_query_rows(
		&fx,
		"FROM metrics SELECT node, region, latency_ms ORDER BY node",
		[]string{
			"test-node-1\teu-west-1\t12",
			"test-node-2\tus-east-1\t28",
		},
	)

	// Verify `statement error` captures catalog/binder failure cleanly:
	sqllogic_statement_error(&fx, "SELECT * FROM non_existent_table_xyz", "non_existent_table_xyz")
}
