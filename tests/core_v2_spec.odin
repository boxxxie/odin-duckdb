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

import "base:runtime"
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

// ============================================================================
// 6. Error Info Raw Text, JSON Output & Slot Reuse (`test_capi_v2_error_info.cpp`)
// ============================================================================

@(test)
spec_v2_error_info_raw_text_json_and_slot_reuse :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)

	// 1. Null-safe destroy (`test_capi_v2_error_info.cpp` lines 25-44):
	var_null: duckdb.V2_Error_Info_Handle
	testing.expect_value(t, duckdb.duckdb_v2_error_info_destroy(&var_null), duckdb.V2_Error.NONE)
	testing.expect_value(t, duckdb.duckdb_v2_error_info_destroy(nil), duckdb.V2_Error.NONE)

	// 2. Parse error populates both `get_text` (with caret/LINE) and `get_raw_text` (`test_capi_v2_error_info.cpp` lines 163-214):
	err: duckdb.V2_Error_Info_Handle
	defer duckdb.duckdb_v2_error_info_destroy(&err)

	bad_stmt: duckdb.V2_Sql_Statement_Handle
	parse_rc := driver_parse_single_stmt(fx.conn, "SELEC 1", &bad_stmt, &err)
	testing.expect_value(t, parse_rc, duckdb.V2_Error.QUERY_PARSER)

	code: duckdb.V2_Error
	expect_v2_ok(t, duckdb.duckdb_v2_error_info_get_code(err, &code))
	testing.expect_value(t, code, duckdb.V2_Error.QUERY_PARSER)

	text, raw_text: duckdb.V2_Str
	expect_v2_ok(t, duckdb.duckdb_v2_error_info_get_text(err, &text))
	expect_v2_ok(t, duckdb.duckdb_v2_error_info_get_raw_text(err, &raw_text))
	testing.expect(t, strings.contains(duckdb.v2_str_to_string(text), "syntax error"))
	testing.expect(t, len(duckdb.v2_str_to_string(text)) > len(duckdb.v2_str_to_string(raw_text)))

	// Reusing the same `err` slot via `set_text` & `set_code` replaces both text and raw_text (`test_capi_v2_error_info.cpp` lines 253-286):
	msg2 := duckdb.v2_str_from_string("overwritten slot")
	expect_v2_ok(t, duckdb.duckdb_v2_error_info_set_code(err, .INPUT_INVALID))
	expect_v2_ok(t, duckdb.duckdb_v2_error_info_set_text(err, &msg2))
	expect_v2_ok(t, duckdb.duckdb_v2_error_info_get_code(err, &code))
	testing.expect_value(t, code, duckdb.V2_Error.INPUT_INVALID)
	expect_v2_ok(t, duckdb.duckdb_v2_error_info_get_raw_text(err, &raw_text))
	testing.expect_value(t, duckdb.v2_str_to_string(raw_text), "overwritten slot")

	// 3. `SET errors_as_json = true` formats `get_text` as JSON while `get_raw_text` stays plain (`test_capi_v2_error_info.cpp` lines 216-251):
	expect_v2_ok(t, driver_exec_drain(fx.conn, "SET errors_as_json = true", nil, &fx.err), &fx.err)
	json_err: duckdb.V2_Error_Info_Handle
	defer duckdb.duckdb_v2_error_info_destroy(&json_err)
	testing.expect_value(t, driver_parse_single_stmt(fx.conn, "SELEC 1", &bad_stmt, &json_err), duckdb.V2_Error.QUERY_PARSER)
	expect_v2_ok(t, duckdb.duckdb_v2_error_info_get_text(json_err, &text))
	expect_v2_ok(t, duckdb.duckdb_v2_error_info_get_raw_text(json_err, &raw_text))
	testing.expect(t, strings.has_prefix(duckdb.v2_str_to_string(text), "{"))
	testing.expect(t, !strings.has_prefix(duckdb.v2_str_to_string(raw_text), "{"))
}

// ============================================================================
// 7. Instance Options, Attach/Detach, Config Introspection & Factories
// (`test_capi_v2_basic.cpp`, `test_capi_v2_option.cpp`, `test_capi_v2_factory.cpp`)
// ============================================================================

context_config_udf_exec_cb :: proc "c" (
	info: duckdb.V2_Scalar_Function_Exec_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	cfg: duckdb.V2_Config_Handle
	if duckdb.duckdb_v2_context_get_config(ctx, &cfg, err) != .NONE {
		return
	}
	opt_name := duckdb.v2_str_from_string("max_execution_time")
	val: duckdb.V2_Value_Handle
	scope: duckdb.V2_Setting_Scope
	if duckdb.duckdb_v2_config_get_option_value(cfg, &opt_name, &val, &scope, err) != .NONE {
		return
	}
	defer duckdb.duckdb_v2_value_destroy(&val)

	v_i64: i64
	_ = duckdb.duckdb_v2_value_get_bigint(val, &v_i64, nil)

	output: duckdb.V2_Vector_Handle
	raw: rawptr
	_ = duckdb.duckdb_v2_scalar_function_exec_get_result(info, &output, nil)
	_ = duckdb.duckdb_v2_vector_get_data_mutable(output, &raw, nil)
	(cast([^]i64)raw)[0] = v_i64
}

@(test)
spec_v2_instance_startup_attach_options_multi_db_and_factory :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)

	// 1. Instance factory creates built-in types & values, and `duckdb_v2_instance_create_with_options`
	//    starts an instance with startup option arrays (`test_capi_v2_factory.cpp` & `test_capi_v2_basic.cpp`):
	{
		opt_names := [1]duckdb.V2_Str{duckdb.v2_str_from_string("threads")}
		opt_vals := [1]duckdb.V2_Str{duckdb.v2_str_from_string("2")}
		inst: duckdb.V2_Instance_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_instance_create_with_options(fx.env, &opt_names[0], &opt_vals[0], 1, &inst, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_instance_destroy(&inst)

		inst_factory: duckdb.V2_Factory_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_instance_get_factory(inst, &inst_factory, &fx.err), &fx.err)

		v_threads: duckdb.V2_Value_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_bigint(inst_factory, 2, &v_threads, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&v_threads)

		inst_cfg: duckdb.V2_Config_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_instance_get_config(inst, &inst_cfg, &fx.err), &fx.err)
		threads_name := duckdb.v2_str_from_string("threads")
		expect_v2_ok(t, duckdb.duckdb_v2_config_set_option_value(inst_cfg, &threads_name, v_threads, .GLOBAL, &fx.err), &fx.err)

		// 2. `duckdb_v2_attach_options_create`/`set`/`destroy`, multi-database `attach`, `set_default`, and `detach`:
		aopts: duckdb.V2_Attach_Options_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_attach_options_create(inst, &aopts, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_attach_options_destroy(&aopts)

		mem_str := duckdb.v2_str_from_string(":memory:")
		main_alias := duckdb.v2_str_from_string("main_db")
		aux_alias := duckdb.v2_str_from_string("aux")
		expect_v2_ok(t, duckdb.duckdb_v2_instance_attach(inst, &main_alias, &mem_str, aopts, true, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_instance_attach(inst, &aux_alias, &mem_str, nil, false, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_instance_set_default(inst, &aux_alias, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_instance_set_default(inst, &main_alias, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_instance_detach(inst, &aux_alias, &fx.err), &fx.err)
	}

	// 3. Config option enumeration, aliases, scopes (`SESSION` vs `GLOBAL` vs `DEFAULT`), `set_option_text`,
	//    `duckdb_v2_context_get_config` in UDF, and instance vs connection factory catalog visibility:
	inst_cfg, conn_cfg: duckdb.V2_Config_Handle
	expect_v2_ok(t, duckdb.duckdb_v2_instance_get_config(fx.instance, &inst_cfg, &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.duckdb_v2_connection_get_config(fx.conn, &conn_cfg, &fx.err), &fx.err)

	opt_count: duckdb.V2_Idx
	expect_v2_ok(t, duckdb.duckdb_v2_config_get_option_count(inst_cfg, &opt_count, &fx.err), &fx.err)
	testing.expect(t, opt_count > 50, "expected > 50 built-in options")

	opt0: duckdb.V2_Option_Handle
	expect_v2_ok(t, duckdb.duckdb_v2_config_get_option_by_index(inst_cfg, 0, &opt0, &fx.err), &fx.err)
	defer duckdb.duckdb_v2_option_destroy(&opt0)
	opt0_name: duckdb.V2_Identifier
	expect_v2_ok(t, duckdb.duckdb_v2_option_get_name(opt0, &opt0_name, &fx.err), &fx.err)
	testing.expect(t, len(duckdb.v2_str_to_string(opt0_name)) > 0)

	// Look up `worker_threads` alias -> resolves to `threads` (`test_capi_v2_option.cpp` lines 162-182):
	alias_lookup := duckdb.v2_str_from_string("worker_threads")
	threads_opt: duckdb.V2_Option_Handle
	expect_v2_ok(t, duckdb.duckdb_v2_config_get_option_by_name(inst_cfg, &alias_lookup, &threads_opt, &fx.err), &fx.err)
	defer duckdb.duckdb_v2_option_destroy(&threads_opt)
	canon_name: duckdb.V2_Identifier
	expect_v2_ok(t, duckdb.duckdb_v2_option_get_name(threads_opt, &canon_name, &fx.err), &fx.err)
	testing.expect_value(t, duckdb.v2_str_to_string(canon_name), "threads")

	desc: duckdb.V2_Str
	expect_v2_ok(t, duckdb.duckdb_v2_option_get_description(threads_opt, &desc, &fx.err), &fx.err)
	testing.expect(t, len(duckdb.v2_str_to_string(desc)) > 0)

	def_scope: duckdb.V2_Setting_Scope
	expect_v2_ok(t, duckdb.duckdb_v2_option_get_default_scope(threads_opt, &def_scope, &fx.err), &fx.err)
	testing.expect_value(t, def_scope, duckdb.V2_Setting_Scope.GLOBAL)

	alias_cnt: duckdb.V2_Idx
	expect_v2_ok(t, duckdb.duckdb_v2_option_get_alias_count(threads_opt, &alias_cnt, &fx.err), &fx.err)
	testing.expect(t, alias_cnt >= 1)
	first_alias: duckdb.V2_Identifier
	expect_v2_ok(t, duckdb.duckdb_v2_option_get_alias(threads_opt, 0, &first_alias, &fx.err), &fx.err)
	testing.expect_value(t, duckdb.v2_str_to_string(first_alias), "worker_threads")

	// `set_option_text` on `max_execution_time` and reading via `duckdb_v2_context_get_config` in scalar UDF (`test_capi_v2_option.cpp` lines 47-94, 605-609):
	met_name := duckdb.v2_str_from_string("max_execution_time")
	met_val_str := duckdb.v2_str_from_string("1234")
	expect_v2_ok(t, duckdb.duckdb_v2_config_set_option_text(conn_cfg, &met_name, &met_val_str, .SESSION, &fx.err), &fx.err)

	fn: duckdb.V2_Scalar_Function_Handle
	expect_v2_ok(t, duckdb.duckdb_v2_scalar_function_create(fx.factory, &fn, &fx.err), &fx.err)
	defer duckdb.duckdb_v2_scalar_function_destroy(&fn)
	sig: duckdb.V2_Function_Signature_Handle
	expect_v2_ok(t, duckdb.duckdb_v2_scalar_function_get_signature(fn, &sig, &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.duckdb_v2_function_signature_set_return_type(sig, fx.bigint_type, &fx.err), &fx.err)
	fn_name := duckdb.v2_str_from_string("read_met_cfg")
	expect_v2_ok(t, duckdb.duckdb_v2_scalar_function_set_name(fn, &fn_name, &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.duckdb_v2_scalar_function_set_exec_callback(fn, context_config_udf_exec_cb, &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.duckdb_v2_connection_register_scalar_function(fx.conn, fn, &fx.err), &fx.err)

	expect_query_column(&fx, "SELECT read_met_cfg()", []i64{1234})
	expect_v2_ok(t, driver_exec_drain(fx.conn, "RESET max_execution_time", nil, &fx.err), &fx.err)

	// Instance factory refuses catalog-dependent user types while connection factory resolves them (`test_capi_v2_factory.cpp` lines 88-119):
	sqllogic_statement_ok(&fx, "CREATE TYPE mood_enum AS ENUM ('happy', 'sad')")
	mood_str := duckdb.v2_str_from_string("mood_enum")
	inst_factory: duckdb.V2_Factory_Handle
	expect_v2_ok(t, duckdb.duckdb_v2_instance_get_factory(fx.instance, &inst_factory, &fx.err), &fx.err)

	cat_type: duckdb.V2_Logical_Type_Handle
	expect_v2_error(
		t,
		duckdb.duckdb_v2_factory_create_type_from_text(inst_factory, &mood_str, &cat_type, &fx.err),
		.INPUT_INVALID,
		&fx.err,
	)
	expect_v2_ok(t, duckdb.duckdb_v2_factory_create_type_from_text(fx.factory, &mood_str, &cat_type, &fx.err), &fx.err)
	defer duckdb.duckdb_v2_logical_type_destroy(&cat_type)
}

// ============================================================================
// 8. Result Box Renderer, Fetch Chunk, Query Progress & Transactions
// (`test_capi_v2_result.cpp` & `test_capi_v2_query.cpp`)
// ============================================================================

Box_Render_Accum :: struct {
	builder: strings.Builder,
	calls:   int,
}

box_sink_accum_cb :: proc "c" (text: ^duckdb.V2_Str, user_data: rawptr, err: ^duckdb.V2_Error_Info_Handle) {
	context = runtime.default_context()
	if user_data == nil || text == nil {
		return
	}
	acc := cast(^Box_Render_Accum)user_data
	acc.calls += 1
	if text.ptr != nil && text.len > 0 {
		s := string((cast([^]u8)text.ptr)[:text.len])
		for i := 0; i < len(s); i += 1 {
			append(&acc.builder.buf, s[i])
		}
	}
}

box_sink_fail_cb :: proc "c" (text: ^duckdb.V2_Str, user_data: rawptr, err: ^duckdb.V2_Error_Info_Handle) {
	driver_set_callback_error(err, .IO_GENERAL, "sink failure")
}

@(test)
spec_v2_result_render_box_fetch_chunk_progress_and_transactions :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)

	// 1. `duckdb_v2_sql_statement_get_text`, `duckdb_v2_result_get_result_type`, `duckdb_v2_result_get_statement_type`,
	//    and `duckdb_v2_result_fetch_chunk` (`test_capi_v2_result.cpp` lines 1530-1695):
	{
		stmt: duckdb.V2_Sql_Statement_Handle
		expect_v2_ok(t, driver_parse_single_stmt(fx.conn, "SELECT 10::BIGINT AS a, 20::BIGINT AS b", &stmt, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_sql_statement_destroy(&stmt)

		stmt_sql: duckdb.V2_Str
		expect_v2_ok(t, duckdb.duckdb_v2_sql_statement_get_text(stmt, &stmt_sql, &fx.err), &fx.err)
		testing.expect_value(t, duckdb.v2_str_to_string(stmt_sql), "SELECT 10::BIGINT AS a, 20::BIGINT AS b")

		res: duckdb.V2_Result_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_statement_execute(fx.conn, stmt, nil, nil, 0, &res, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_result_destroy(&res)

		res_type: duckdb.V2_Result_Type
		expect_v2_ok(t, duckdb.duckdb_v2_result_get_result_type(res, &res_type, &fx.err), &fx.err)
		testing.expect_value(t, res_type, duckdb.V2_Result_Type.QUERY_RESULT)

		st_type: duckdb.V2_Statement_Type
		expect_v2_ok(t, duckdb.duckdb_v2_result_get_statement_type(res, &st_type, &fx.err), &fx.err)
		testing.expect_value(t, st_type, duckdb.V2_Statement_Type.SELECT)

		chunk1, chunk2: duckdb.V2_Data_Chunk_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_result_fetch_chunk(res, &chunk1, &fx.err), &fx.err)
		testing.expect(t, chunk1 != nil)
		defer duckdb.duckdb_v2_data_chunk_destroy(&chunk1)

		expect_v2_ok(t, duckdb.duckdb_v2_result_fetch_chunk(res, &chunk2, &fx.err), &fx.err)
		testing.expect_value(t, chunk2, duckdb.V2_Data_Chunk_Handle(nil))
	}

	// 2. `duckdb_v2_result_render_box` adopt-by-transfer, custom `null_value` (`<nil>`), `limit` approximate footer (`? rows`),
	//    pre-adoption argument validation leaving `res` intact, and sink `false` returning `RUNTIME_IO` (`test_capi_v2_result.cpp` lines 1922-2155):
	{
		res: duckdb.V2_Result_Handle
		expect_v2_ok(t, driver_query(fx.conn, "SELECT 1 AS a, NULL::VARCHAR AS b", &res, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_result_destroy(&res)

		// Pre-adoption validation: null sink returns `INPUT_INVALID` and leaves `res != nil`
		empty_str := duckdb.V2_Str{}
		expect_v2_error(
			t,
			duckdb.duckdb_v2_result_render_box(&res, 0, 0, 0, &empty_str, 0, 0, nil, nil, &fx.err),
			.INPUT_INVALID,
			&fx.err,
		)
		testing.expect(t, res != nil, "expected pre-adoption validation failure to leave result handle intact")

		acc := Box_Render_Accum{
			builder = strings.builder_make(context.temp_allocator),
		}
		nil_str := duckdb.v2_str_from_string("<nil>")
		expect_v2_ok(
			t,
			duckdb.duckdb_v2_result_render_box(&res, 10, 80, 0, &nil_str, 0, 0, box_sink_accum_cb, &acc, &fx.err),
			&fx.err,
		)
		testing.expect_value(t, res, duckdb.V2_Result_Handle(nil))
		rendered := strings.to_string(acc.builder)
		testing.expect(t, strings.contains(rendered, "<nil>"), "expected rendered box to contain custom <nil> string")

		// Failing sink callback returns `IO_GENERAL` and still consumes `res2`:
		res2: duckdb.V2_Result_Handle
		expect_v2_ok(t, driver_query(fx.conn, "SELECT 1", &res2, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_result_destroy(&res2)
		expect_v2_error(
			t,
			duckdb.duckdb_v2_result_render_box(&res2, 0, 0, 0, &empty_str, 0, 0, box_sink_fail_cb, nil, &fx.err),
			.IO_GENERAL,
			&fx.err,
		)
		testing.expect_value(t, res2, duckdb.V2_Result_Handle(nil))
	}

	// 3. `duckdb_v2_connection_progress_get` and `BEGIN` / `INSERT` / `ROLLBACK` / `COMMIT` preservation (`test_capi_v2_query.cpp` lines 53-154):
	{
		pct: f64
		rows_p, total_r: u64
		expect_v2_ok(t, duckdb.duckdb_v2_connection_progress_get(fx.conn, &pct, &rows_p, &total_r, &fx.err), &fx.err)

		sqllogic_statement_ok(&fx, "CREATE TABLE tx_items (v INTEGER)")
		sqllogic_statement_ok(&fx, "BEGIN TRANSACTION")
		sqllogic_statement_ok(&fx, "INSERT INTO tx_items VALUES (10), (20)")
		sqllogic_statement_ok(&fx, "ROLLBACK")
		expect_query_column(&fx, "SELECT count(*)::BIGINT FROM tx_items", []i64{0})

		sqllogic_statement_ok(&fx, "BEGIN TRANSACTION")
		sqllogic_statement_ok(&fx, "INSERT INTO tx_items VALUES (42)")
		sqllogic_statement_ok(&fx, "COMMIT")
		expect_query_column(&fx, "SELECT v FROM tx_items", []i32{42})
	}
}
