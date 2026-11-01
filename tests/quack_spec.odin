package duckdb_tests

// ============================================================================
// Layer 1: Executable Specifications — Quack Protocol & SQLLogicTest Parser
// (`tests/quack_spec.odin`)
// ============================================================================
// Upstream References:
// - `references/duckdb2/duckdb-quack/test/sql/whoami.test`
// - `references/duckdb2/duckdb-quack/test/sql/secret.test`
// - `references/duckdb2/duckdb-quack/test/template/quack_setup.test_template`
// - `references/duckdb2/duckdb-claude-plugin/skills/quack/SKILL.md`
// ============================================================================

import "core:os"
import "core:strings"
import "core:testing"
import duckdb "../duckdb"

// ----------------------------------------------------------------------------
// 1. Quack Server, Identity, Secret, Attach & RPC SQL Builders
// ----------------------------------------------------------------------------

@(test)
spec_quack_serve_identify_secret_attach_and_rpc_sql_builders :: proc(t: ^testing.T) {
	// 1. `quack_serve_sql` & `quack_stop_sql` (`quack_setup.test_template` line 13):
	serve_sql := duckdb.quack_serve_sql({
		endpoint = "quack:localhost:0",
		token    = "asdf",
	})
	testing.expect_value(t, serve_sql, "SELECT * FROM quack_serve('quack:localhost:0', token='asdf')")

	tls_serve_sql := duckdb.quack_serve_sql({
		endpoint = "https://127.0.0.1:9999",
		token    = "sec",
		cert     = "/tmp/server.crt",
		key      = "/tmp/server.key",
	})
	testing.expect_value(
		t,
		tls_serve_sql,
		"SELECT * FROM quack_serve('https://127.0.0.1:9999', token='sec', cert='/tmp/server.crt', key='/tmp/server.key')",
	)
	testing.expect_value(t, duckdb.quack_stop_sql(), "SELECT * FROM quack_stop()")
	testing.expect_value(t, duckdb.quack_stop_sql("quack:localhost:9999"), "SELECT * FROM quack_stop('quack:localhost:9999')")

	// 2. `quack_identify_sql` (`whoami.test` lines 42, 59):
	id_sql := duckdb.quack_identify_sql({
		name      = "test-node",
		region    = "eu-west-1",
		meta_json = `{"role": "worker", "platform": "override"}`,
	})
	testing.expect_value(
		t,
		id_sql,
		`CALL quack_identify(name => 'test-node', region => 'eu-west-1', meta => '{"role": "worker", "platform": "override"}')`,
	)

	// 3. `quack_secret_sql` (`secret.test` line 10):
	sec_sql := duckdb.quack_secret_sql({
		name  = "quack_ok",
		token = "asdf",
		scope = "quack:localhost:9999",
	})
	testing.expect_value(
		t,
		sec_sql,
		"CREATE SECRET quack_ok (TYPE quack, TOKEN 'asdf', SCOPE 'quack:localhost:9999')",
	)

	// 4. `quack_attach_sql` (`READ_ONLY`, `PERSISTENT`, `TOKEN`, `SSL_FINGERPRINT`, `EXTRA_HTTP_HEADERS`):
	headers := [2]duckdb.Quack_Header{
		{key = "Authorization", value = "Bearer tok_123"},
		{key = "X-Trace-Id", value = "req-42"},
	}
	attach_sql := duckdb.quack_attach_sql({
		endpoint        = "https://127.0.0.1:9999",
		alias           = "remote_cluster",
		token           = "asdf",
		read_only       = true,
		persistent      = true,
		ssl_fingerprint = "sha256:deadbeef",
		extra_headers   = headers[:],
	})
	testing.expect_value(
		t,
		attach_sql,
		"ATTACH 'https://127.0.0.1:9999' AS remote_cluster (TYPE quack, READ_ONLY, PERSISTENT, TOKEN 'asdf', SSL_FINGERPRINT 'sha256:deadbeef', EXTRA_HTTP_HEADERS MAP {'Authorization': 'Bearer tok_123', 'X-Trace-Id': 'req-42'})",
	)

	// 5. `quack_query_sql` (`secret.test` line 16) with single-quote escaping:
	rpc_sql := duckdb.quack_query_sql("r_ok", "SELECT name FROM nodes WHERE region = 'eu-west-1'")
	testing.expect_value(t, rpc_sql, "FROM r_ok.query('SELECT name FROM nodes WHERE region = ''eu-west-1''')")
}

// ----------------------------------------------------------------------------
// 2. SQLLogicTest `.test` Script Parser & Runner on Upstream Quack Test Files
// ----------------------------------------------------------------------------

@(test)
spec_sqllogic_parser_and_upstream_quack_test_files :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)

	// 1. Parse upstream `references/duckdb2/duckdb-quack/test/sql/whoami.test`:
	{
		raw, err := os.read_entire_file_from_path("references/duckdb2/duckdb-quack/test/sql/whoami.test", context.temp_allocator)
		testing.expect_value(t, err, os.ERROR_NONE)
		directives := duckdb.sqllogic_parse_script(string(raw), context.temp_allocator)

		// Verify `require quack`, `require json`, `require httpfs`, `statement ok`, and `query I` / `query II`:
		testing.expect(t, len(directives) >= 15)
		testing.expect_value(t, directives[0].kind, duckdb.Sqllogic_Directive_Kind.REQUIRE)
		testing.expect_value(t, directives[0].arg, "quack")
		testing.expect_value(t, directives[1].kind, duckdb.Sqllogic_Directive_Kind.REQUIRE)
		testing.expect_value(t, directives[1].arg, "json")

		found_identify := false
		found_two_col_query := false
		for d in directives {
			if d.kind == .STATEMENT_OK && strings.contains(d.sql, "CALL quack_identify(name => 'test-node'") {
				found_identify = true
			}
			if d.kind == .QUERY && d.arg == "II" && strings.contains(d.sql, "SELECT name, region FROM whoami()") {
				found_two_col_query = true
				testing.expect_value(t, d.expected, "test-node\teu-west-1")
			}
		}
		testing.expect(t, found_identify)
		testing.expect(t, found_two_col_query)
	}

	// 2. Parse upstream `references/duckdb2/duckdb-quack/test/sql/secret.test`:
	{
		raw, err := os.read_entire_file_from_path("references/duckdb2/duckdb-quack/test/sql/secret.test", context.temp_allocator)
		testing.expect_value(t, err, os.ERROR_NONE)
		directives := duckdb.sqllogic_parse_script(string(raw), context.temp_allocator)

		testing.expect(t, len(directives) >= 9)
		testing.expect_value(t, directives[0].kind, duckdb.Sqllogic_Directive_Kind.INCLUDE)
		testing.expect_value(t, directives[0].arg, "test/template/quack_setup.test_template")

		found_auth_err := false
		for d in directives {
			if d.kind == .STATEMENT_ERROR && strings.contains(d.sql, "attach {server} as r_bad") {
				found_auth_err = true
				testing.expect_value(t, d.expected, "Authentication failed")
			}
		}
		testing.expect(t, found_auth_err)
	}

	// 3. Execute a self-contained SQLLogicTest script against `fx.conn`:
	script := `
# End-to-end SQLLogicTest script executed against DuckDB 2.0 C API v2
statement ok
CREATE TABLE cluster_nodes (name VARCHAR, region VARCHAR, active BOOLEAN);

statement ok
INSERT INTO cluster_nodes VALUES ('node-a', 'eu-west-1', true), ('node-b', 'us-east-1', false);

query TT
SELECT name, region FROM cluster_nodes WHERE active ORDER BY name;
----
node-a	eu-west-1

statement error
SELECT * FROM missing_quack_table;
----
missing_quack_table
`
	parsed := duckdb.sqllogic_parse_script(script, context.temp_allocator)
	testing.expect_value(t, len(parsed), 4)
	for d in parsed {
		#partial switch d.kind {
		case .STATEMENT_OK:
			sqllogic_statement_ok(&fx, d.sql)
		case .STATEMENT_ERROR:
			sqllogic_statement_error(&fx, d.sql, d.expected)
		case .QUERY:
			exp_rows := strings.split_lines(d.expected, context.temp_allocator)
			sqllogic_query_rows(&fx, d.sql, exp_rows)
		}
	}
}
