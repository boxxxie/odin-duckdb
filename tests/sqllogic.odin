package duckdb_tests

// ============================================================================
// Layer 3 Protocol Driver: SQLLogicTest (`.test`) Runner (`tests/sqllogic.odin`)
// ============================================================================
// Directly parses and executes upstream DuckDB 2.0 & Quack SQLLogicTest directives
// (`statement ok`, `statement error`, `query <types>`) against our Odin C API v2 driver!
//
// Authoritative Upstream Test References:
// - `references/duckdb2/duckdb-quack/test/sql/whoami.test`
// - `references/duckdb2/duckdb-quack/test/sql/serve_canonical.test`
// - `references/duckdb2/duckdb-quack/test/sql/server_list.test`
// ============================================================================

import "core:strings"
import "core:testing"
import duckdb "../duckdb"

// Executes a single SQLLogicTest `statement ok` directive.
sqllogic_statement_ok :: proc(fx: ^Test_Env, sql: string, loc := #caller_location) {
	err: duckdb.V2_Error_Info_Handle
	rc := driver_exec_drain(fx.conn, sql, nil, &err)
	expect_v2_ok(fx.t, rc, &err, sql, loc = loc)
}

// Executes a single SQLLogicTest `statement error` directive, checking both prepare-time
// and step-time execution errors and optionally matching `expected_substring`.
sqllogic_statement_error :: proc(
	fx: ^Test_Env,
	sql: string,
	expected_substring: string = "",
	loc := #caller_location,
) {
	err: duckdb.V2_Error_Info_Handle
	result: duckdb.V2_Result_Handle
	rc := driver_query(fx.conn, sql, &result, &err)
	defer duckdb.duckdb_v2_result_destroy(&result)

	if rc == .NONE {
		changed: duckdb.V2_Idx
		rc = duckdb.duckdb_v2_result_drain(result, &changed, &err)
	}

	_, msg := driver_consume_error_text(&err)
	testing.expectf(fx.t, rc != .NONE, "Expected SQL statement to fail, but it succeeded: %s", sql, loc = loc)
	if len(expected_substring) > 0 {
		testing.expectf(
			fx.t,
			strings.contains(msg, expected_substring),
			"Expected error message containing %q, got %q",
			expected_substring,
			msg,
			loc = loc,
		)
	}
}

// Executes a SQLLogicTest `query <cols>` directive and compares tab-separated row/column cells
// against `expected_tsv_lines`.
sqllogic_query_rows :: proc(
	fx: ^Test_Env,
	sql: string,
	expected_tsv_lines: []string,
	loc := #caller_location,
) {
	err: duckdb.V2_Error_Info_Handle
	result: duckdb.V2_Result_Handle
	rc := driver_query(fx.conn, sql, &result, &err)
	if !expect_v2_ok(fx.t, rc, &err, sql, loc = loc) {
		return
	}
	defer duckdb.duckdb_v2_result_destroy(&result)

	actual_rows := make([dynamic]string, context.temp_allocator)

	for {
		chunk: duckdb.V2_Data_Chunk_Handle
		status, step_rc := driver_step_chunk(result, &chunk, &err)
		if !expect_v2_ok(fx.t, step_rc, &err, sql, loc = loc) {
			return
		}
		if status == .FINISHED {
			break
		}
		if status != .CHUNK || chunk == nil {
			continue
		}

		row_count: duckdb.V2_Idx
		col_count: duckdb.V2_Idx
		_ = duckdb.duckdb_v2_data_chunk_get_size(chunk, &row_count, nil)
		_ = duckdb.duckdb_v2_data_chunk_get_vector_count(chunk, &col_count, nil)

		for r: duckdb.V2_Idx = 0; r < row_count; r += 1 {
			b := strings.builder_make(context.temp_allocator)
			for c: duckdb.V2_Idx = 0; c < col_count; c += 1 {
				if c > 0 {
					strings.write_byte(&b, '\t')
				}
				vec: duckdb.V2_Vector_Handle
				_ = duckdb.duckdb_v2_data_chunk_get_vector(chunk, c, &vec, nil)
				val: duckdb.V2_Value_Handle
				_ = duckdb.duckdb_v2_vector_get_value(vec, r, &val, nil)
				cell_text, _ := driver_render_value(val, context.temp_allocator)
				duckdb.duckdb_v2_value_destroy(&val)
				strings.write_string(&b, cell_text)
			}
			append(&actual_rows, strings.to_string(b))
		}
		duckdb.duckdb_v2_data_chunk_destroy(&chunk)
	}

	testing.expect_value(fx.t, len(actual_rows), len(expected_tsv_lines), loc = loc)
	count := min(len(actual_rows), len(expected_tsv_lines))
	for i in 0 ..< count {
		testing.expect_value(fx.t, actual_rows[i], expected_tsv_lines[i], loc = loc)
	}
}
