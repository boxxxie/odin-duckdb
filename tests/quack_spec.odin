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
		if len(directives) >= 2 {
			testing.expect_value(t, directives[0].kind, duckdb.Sqllogic_Directive_Kind.REQUIRE)
			testing.expect_value(t, directives[0].arg, "quack")
			testing.expect_value(t, directives[1].kind, duckdb.Sqllogic_Directive_Kind.REQUIRE)
			testing.expect_value(t, directives[1].arg, "json")
		}

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
		if len(directives) >= 1 {
			testing.expect_value(t, directives[0].kind, duckdb.Sqllogic_Directive_Kind.INCLUDE)
			testing.expect_value(t, directives[0].arg, "test/template/quack_setup.test_template")
		}

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

// ----------------------------------------------------------------------------
// 3. Full 91-File Upstream `duckdb-quack` Suite, Template Expansion & URI Normalization
//    (`references/duckdb2/duckdb-quack/test/*`, `references/elixir/quackdb/test/quack_db/uri_test.exs`)
// ----------------------------------------------------------------------------

@(test)
spec_quack_all_91_upstream_sqllogic_test_files_and_uri_normalization :: proc(t: ^testing.T) {
	// 1. Parse all 91 upstream `.test`, `.test_slow`, and `.test_template` files in `references/duckdb2/duckdb-quack/test/`:
	dirs := [3]string{
		"references/duckdb2/duckdb-quack/test/sql",
		"references/duckdb2/duckdb-quack/test/remote_pushdown",
		"references/duckdb2/duckdb-quack/test/template",
	}

	total_files := 0
	total_directives := 0
	for dir_path in dirs {
		dh, open_err := os.open(dir_path)
		testing.expect_value(t, open_err, os.ERROR_NONE)
		if open_err != os.ERROR_NONE {
			continue
		}
		defer os.close(dh)

		fis, read_err := os.read_dir(dh, -1, context.temp_allocator)
		testing.expect_value(t, read_err, os.ERROR_NONE)
		for fi in fis {
			if !strings.has_suffix(fi.name, ".test") &&
			   !strings.has_suffix(fi.name, ".test_slow") &&
			   !strings.has_suffix(fi.name, ".test_template") {
				continue
			}
			total_files += 1
			raw, ferr := os.read_entire_file_from_path(fi.fullpath, context.temp_allocator)
			testing.expect_value(t, ferr, os.ERROR_NONE)
			directives := duckdb.sqllogic_parse_script(string(raw), context.temp_allocator)
			testing.expectf(t, len(directives) > 0, "expected >0 directives in %s", fi.name)
			total_directives += len(directives)
		}
	}
	testing.expect_value(t, total_files, 91)
	testing.expect(t, total_directives > 1000, "expected >1000 directives across all 91 upstream Quack test files")

	// 2. Template variable expansion (`{server}`, `{quack_port}`) from `test/sql/secret.test`:
	vars := make(map[string]string, context.temp_allocator)
	vars["server"] = "'quack:localhost:9999'"
	vars["quack_port"] = "9999"

	expanded := duckdb.sqllogic_expand_template(
		"create secret quack_ok (type quack, token 'asdf', scope 'quack:localhost:{quack_port}'); attach {server} as r_ok (type quack);",
		vars,
		context.temp_allocator,
	)
	testing.expect_value(
		t,
		expanded,
		"create secret quack_ok (type quack, token 'asdf', scope 'quack:localhost:9999'); attach 'quack:localhost:9999' as r_ok (type quack);",
	)

	// 3. Quack endpoint URI normalization (`references/elixir/quackdb/test/quack_db/uri_test.exs`):
	u1, ok1 := duckdb.quack_normalize_uri("127.0.0.1:4321")
	testing.expect(t, ok1)
	testing.expect_value(t, u1, "http://127.0.0.1:4321")

	u2, ok2 := duckdb.quack_normalize_uri("quack:localhost:9999")
	testing.expect(t, ok2)
	testing.expect_value(t, u2, "http://localhost:9999")

	u3, ok3 := duckdb.quack_normalize_uri("quack://10.0.0.1:8815")
	testing.expect(t, ok3)
	testing.expect_value(t, u3, "http://10.0.0.1:8815")

	u4, ok4 := duckdb.quack_normalize_uri("https://10.0.0.1:8815")
	testing.expect(t, ok4)
	testing.expect_value(t, u4, "https://10.0.0.1:8815")

	_, ok_bad1 := duckdb.quack_normalize_uri("ftp://example.com")
	testing.expect(t, !ok_bad1)

	_, ok_bad2 := duckdb.quack_normalize_uri("")
	testing.expect(t, !ok_bad2)
}
