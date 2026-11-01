package duckdb

// ============================================================================
// DuckDB 2.0 Quack Protocol & SQLLogicTest `.test` Parser (`duckdb/quack.odin`)
// ============================================================================
// Upstream References:
// - `references/duckdb2/duckdb-quack/test/sql/whoami.test`
// - `references/duckdb2/duckdb-quack/test/sql/secret.test`
// - `references/duckdb2/duckdb-quack/test/template/quack_setup.test_template`
// - `references/elixir/quackdb/test/quack_db/uri_test.exs`
// - `references/duckdb2/duckdb-claude-plugin/skills/quack/SKILL.md`
// ============================================================================

import "core:fmt"
import "core:strings"

// ----------------------------------------------------------------------------
// 1. Quack Server, Identity, Secret, Attach & URI Normalization Builders
// ----------------------------------------------------------------------------

Quack_Serve_Config :: struct {
	endpoint: string, // e.g. "quack:localhost:0" or "http://127.0.0.1:9999"
	token:    string, // optional auth token
	cert:     string, // optional TLS certificate path
	key:      string, // optional TLS private key path
}

Quack_Identity_Config :: struct {
	name:      string,
	provider:  string,
	hostname:  string,
	region:    string,
	meta_json: string,
}

Quack_Secret_Config :: struct {
	name:  string,
	token: string,
	scope: string,
}

Quack_Header :: struct {
	key:   string,
	value: string,
}

Quack_Attach_Config :: struct {
	endpoint:        string, // e.g. "quack:localhost:9999" or "https://host:9999"
	alias:           string, // catalog alias, e.g. "remote"
	token:           string, // optional inline token
	read_only:       bool,
	persistent:      bool,
	ssl_fingerprint: string, // optional "sha256:..."
	extra_headers:   []Quack_Header,
}

// Normalizes a Quack endpoint URI (`127.0.0.1:4321`, `quack:localhost:9999`, `quack://10.0.0.1:8815`,
// `http://...`, `https://...`) into a canonical `http://` or `https://` endpoint URI.
quack_normalize_uri :: proc(endpoint: string, allocator := context.temp_allocator) -> (string, bool) {
	s := strings.trim_space(endpoint)
	if len(s) == 0 {
		return "", false
	}
	if strings.has_prefix(s, "http://") {
		rest := s[len("http://"):]
		if len(rest) == 0 {
			return "", false
		}
		return strings.clone(s, allocator), true
	}
	if strings.has_prefix(s, "https://") {
		rest := s[len("https://"):]
		if len(rest) == 0 {
			return "", false
		}
		return strings.clone(s, allocator), true
	}
	if strings.has_prefix(s, "quack://") {
		rest := s[len("quack://"):]
		if len(rest) == 0 {
			return "", false
		}
		return fmt.aprintf("http://%s", rest, allocator = allocator), true
	}
	if strings.has_prefix(s, "quack:") {
		rest := s[len("quack:"):]
		if len(rest) == 0 {
			return "", false
		}
		return fmt.aprintf("http://%s", rest, allocator = allocator), true
	}
	if strings.contains(s, "://") {
		return "", false
	}
	return fmt.aprintf("http://%s", s, allocator = allocator), true
}

// Builds `SELECT * FROM quack_serve('<endpoint>'[, token='<token>', cert='<cert>', key='<key>'])`.
quack_serve_sql :: proc(cfg: Quack_Serve_Config, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	endpoint := cfg.endpoint if len(cfg.endpoint) > 0 else "quack:localhost:0"
	fmt.sbprintf(&b, "SELECT * FROM quack_serve('%s'", sql_escape(endpoint, allocator))
	if len(cfg.token) > 0 {
		fmt.sbprintf(&b, ", token='%s'", sql_escape(cfg.token, allocator))
	}
	if len(cfg.cert) > 0 {
		fmt.sbprintf(&b, ", cert='%s'", sql_escape(cfg.cert, allocator))
	}
	if len(cfg.key) > 0 {
		fmt.sbprintf(&b, ", key='%s'", sql_escape(cfg.key, allocator))
	}
	strings.write_byte(&b, ')')
	return strings.to_string(b)
}

// Builds `SELECT * FROM quack_stop()` or `SELECT * FROM quack_stop('<endpoint>')`.
quack_stop_sql :: proc(endpoint := "", allocator := context.temp_allocator) -> string {
	if len(endpoint) == 0 {
		return fmt.aprintf("SELECT * FROM quack_stop()", allocator = allocator)
	}
	return fmt.aprintf("SELECT * FROM quack_stop('%s')", sql_escape(endpoint, allocator), allocator = allocator)
}

// Builds `CALL quack_identify(name => '...', region => '...', meta => '...')` (`whoami.test` lines 42, 59).
quack_identify_sql :: proc(cfg: Quack_Identity_Config, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "CALL quack_identify(")
	first := true
	write_arg :: proc(b: ^strings.Builder, first: ^bool, k, v: string, allocator := context.temp_allocator) {
		if len(v) == 0 {
			return
		}
		if !first^ {
			strings.write_string(b, ", ")
		}
		first^ = false
		fmt.sbprintf(b, "%s => '%s'", k, sql_escape(v, allocator))
	}
	write_arg(&b, &first, "name", cfg.name, allocator)
	write_arg(&b, &first, "provider", cfg.provider, allocator)
	write_arg(&b, &first, "hostname", cfg.hostname, allocator)
	write_arg(&b, &first, "region", cfg.region, allocator)
	write_arg(&b, &first, "meta", cfg.meta_json, allocator)
	strings.write_byte(&b, ')')
	return strings.to_string(b)
}

// Builds `CREATE SECRET <name> (TYPE quack, TOKEN '<token>'[, SCOPE '<scope>'])` (`secret.test` line 10).
quack_secret_sql :: proc(cfg: Quack_Secret_Config, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(
		&b,
		"CREATE SECRET %s (TYPE quack, TOKEN '%s'",
		v2_quote_identifier(cfg.name, false, allocator),
		sql_escape(cfg.token, allocator),
	)
	if len(cfg.scope) > 0 {
		fmt.sbprintf(&b, ", SCOPE '%s'", sql_escape(cfg.scope, allocator))
	}
	strings.write_byte(&b, ')')
	return strings.to_string(b)
}

// Builds `ATTACH '<endpoint>' AS <alias> (TYPE quack[, READ_ONLY][, PERSISTENT][, TOKEN '...'][, SSL_FINGERPRINT '...'][, EXTRA_HTTP_HEADERS MAP {...}])`.
quack_attach_sql :: proc(cfg: Quack_Attach_Config, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(
		&b,
		"ATTACH '%s' AS %s (TYPE quack",
		sql_escape(cfg.endpoint, allocator),
		v2_quote_identifier(cfg.alias, false, allocator),
	)
	if cfg.read_only {
		strings.write_string(&b, ", READ_ONLY")
	}
	if cfg.persistent {
		strings.write_string(&b, ", PERSISTENT")
	}
	if len(cfg.token) > 0 {
		fmt.sbprintf(&b, ", TOKEN '%s'", sql_escape(cfg.token, allocator))
	}
	if len(cfg.ssl_fingerprint) > 0 {
		fmt.sbprintf(&b, ", SSL_FINGERPRINT '%s'", sql_escape(cfg.ssl_fingerprint, allocator))
	}
	if len(cfg.extra_headers) > 0 {
		strings.write_string(&b, ", EXTRA_HTTP_HEADERS MAP {")
		for h, i in cfg.extra_headers {
			if i > 0 {
				strings.write_string(&b, ", ")
			}
			fmt.sbprintf(&b, "'%s': '%s'", sql_escape(h.key, allocator), sql_escape(h.value, allocator))
		}
		strings.write_byte(&b, '}')
	}
	strings.write_byte(&b, ')')
	return strings.to_string(b)
}

// Builds `FROM <alias>.query('<escaped_remote_sql>')` (`secret.test` line 16).
quack_query_sql :: proc(alias: string, remote_sql: string, allocator := context.temp_allocator) -> string {
	return fmt.aprintf(
		"FROM %s.query('%s')",
		v2_quote_identifier(alias, false, allocator),
		sql_escape(remote_sql, allocator),
		allocator = allocator,
	)
}

// ----------------------------------------------------------------------------
// 2. SQLLogicTest `.test` Script Parser & Template Expander
//    (`references/duckdb2/duckdb-quack/test/sql/*.test`)
// ----------------------------------------------------------------------------

Sqllogic_Directive_Kind :: enum {
	REQUIRE,
	INCLUDE,
	STATEMENT_OK,
	STATEMENT_ERROR,
	QUERY,
}

Sqllogic_Directive :: struct {
	kind:          Sqllogic_Directive_Kind,
	arg:           string, // extension name for `require`, path for `include`, or column type signature (`II`, `TI`, etc.) for `query`
	sort_mode:     string, // `nosort`, `rowsort`, or `valuesort` for `query`
	connection_id: string, // optional connection label (e.g. `quack_db:quack_server_con`)
	sql:           string, // SQL statement(s) to execute
	expected:      string, // expected TSV output rows (for `query`) or expected error substring (for `statement error`)
}

// Expands `{var}` placeholders in a SQLLogicTest script or SQL snippet.
sqllogic_expand_template :: proc(
	sql: string,
	vars: map[string]string,
	allocator := context.temp_allocator,
) -> string {
	res := strings.clone(sql, allocator)
	for k, v in vars {
		placeholder := strings.concatenate({"{", k, "}"}, allocator)
		res, _ = strings.replace_all(res, placeholder, v, allocator)
	}
	return res
}

@(private = "file")
is_sqllogic_directive_start :: proc(trimmed: string) -> bool {
	return strings.has_prefix(trimmed, "statement ") ||
	       strings.has_prefix(trimmed, "query ") ||
	       strings.has_prefix(trimmed, "require ") ||
	       strings.has_prefix(trimmed, "include ") ||
	       strings.has_prefix(trimmed, "loop ") ||
	       strings.has_prefix(trimmed, "concurrentloop ") ||
	       trimmed == "endloop" ||
	       trimmed == "restart" ||
	       trimmed == "halt" ||
	       strings.has_prefix(trimmed, "mode ") ||
	       strings.has_prefix(trimmed, "pragma ")
}

// Parses a DuckDB SQLLogicTest `.test` script into structured `Sqllogic_Directive` items.
sqllogic_parse_script :: proc(
	content: string,
	allocator := context.temp_allocator,
) -> [dynamic]Sqllogic_Directive {
	directives := make([dynamic]Sqllogic_Directive, allocator)
	lines := strings.split_lines(content, allocator)

	i := 0
	for i < len(lines) {
		line := strings.trim_space(lines[i])
		if len(line) == 0 || strings.has_prefix(line, "#") || strings.has_prefix(line, "test-env ") || strings.has_prefix(line, "set ") {
			i += 1
			continue
		}

		if strings.has_prefix(line, "require ") {
			ext := strings.trim_space(line[len("require "):])
			append(&directives, Sqllogic_Directive{kind = .REQUIRE, arg = ext})
			i += 1
			continue
		}

		if strings.has_prefix(line, "include ") {
			inc := strings.trim_space(line[len("include "):])
			append(&directives, Sqllogic_Directive{kind = .INCLUDE, arg = inc})
			i += 1
			continue
		}

		if strings.has_prefix(line, "statement ") {
			parts := strings.fields(line, allocator)
			is_error := len(parts) >= 2 && parts[1] == "error"
			conn_id := parts[2] if len(parts) >= 3 else ""
			i += 1

			has_separator := false
			for j := i; j < len(lines); j += 1 {
				tj := strings.trim_space(lines[j])
				if tj == "----" {
					has_separator = true
					break
				}
				if is_sqllogic_directive_start(tj) {
					break
				}
			}

			sql_b := strings.builder_make(allocator)
			in_expected := false
			exp_b := strings.builder_make(allocator)

			for i < len(lines) {
				raw_l := lines[i]
				trimmed_l := strings.trim_space(raw_l)
				if (in_expected || !has_separator) && len(trimmed_l) == 0 {
					i += 1
					break
				}
				if trimmed_l == "----" {
					in_expected = true
					i += 1
					continue
				}
				if in_expected {
					if strings.builder_len(exp_b) > 0 {
						strings.write_byte(&exp_b, '\n')
					}
					strings.write_string(&exp_b, trimmed_l)
				} else {
					if strings.builder_len(sql_b) > 0 {
						strings.write_byte(&sql_b, '\n')
					}
					strings.write_string(&sql_b, raw_l)
				}
				i += 1
			}

			append(
				&directives,
				Sqllogic_Directive{
					kind          = .STATEMENT_ERROR if is_error else .STATEMENT_OK,
					connection_id = conn_id,
					sql           = strings.to_string(sql_b),
					expected      = strings.to_string(exp_b),
				},
			)
			continue
		}

		if strings.has_prefix(line, "query ") {
			parts := strings.fields(line, allocator)
			col_sig := parts[1] if len(parts) >= 2 else "I"
			sort_mode := "nosort"
			conn_id := ""
			for p in parts[2:] {
				if p == "nosort" || p == "rowsort" || p == "valuesort" {
					sort_mode = p
				} else {
					conn_id = p
				}
			}
			i += 1

			// Look ahead to check whether this `query` block has a `----` separator before the next directive.
			// If it does, blank lines before `----` are part of a multi-line SQL query rather than block terminators.
			has_separator := false
			for j := i; j < len(lines); j += 1 {
				tj := strings.trim_space(lines[j])
				if tj == "----" {
					has_separator = true
					break
				}
				if is_sqllogic_directive_start(tj) {
					break
				}
			}

			sql_b := strings.builder_make(allocator)
			exp_b := strings.builder_make(allocator)
			in_expected := false

			for i < len(lines) {
				raw_l := lines[i]
				trimmed_l := strings.trim_space(raw_l)
				if in_expected && len(trimmed_l) == 0 {
					i += 1
					break
				}
				if trimmed_l == "----" {
					in_expected = true
					i += 1
					continue
				}
				if !in_expected && !has_separator && len(trimmed_l) == 0 {
					i += 1
					break
				}
				if in_expected {
					if strings.builder_len(exp_b) > 0 {
						strings.write_byte(&exp_b, '\n')
					}
					strings.write_string(&exp_b, raw_l)
				} else {
					if strings.builder_len(sql_b) > 0 {
						strings.write_byte(&sql_b, '\n')
					}
					strings.write_string(&sql_b, raw_l)
				}
				i += 1
			}

			append(
				&directives,
				Sqllogic_Directive{
					kind          = .QUERY,
					arg           = col_sig,
					sort_mode     = sort_mode,
					connection_id = conn_id,
					sql           = strings.to_string(sql_b),
					expected      = strings.to_string(exp_b),
				},
			)
			continue
		}

		i += 1
	}

	return directives
}
