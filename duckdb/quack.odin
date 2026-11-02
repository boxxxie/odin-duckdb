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
	rest := s
	if strings.has_prefix(s, "quack://") {
		rest = s[len("quack://"):]
		if len(rest) == 0 {
			return "", false
		}
	} else if strings.has_prefix(s, "quack:") {
		rest = s[len("quack:"):]
		if len(rest) == 0 {
			return "", false
		}
	} else if strings.contains(s, "://") {
		return "", false
	}
	b := strings.builder_make(0, len("http://") + len(rest), allocator)
	strings.write_string(&b, "http://")
	strings.write_string(&b, rest)
	return strings.to_string(b), true
}

// Normalizes backslashes (`\`) to forward slashes (`/`) and escapes single quotes (`'` -> `''`)
// for file/glob/certificate paths embedded inside SQL string literals.
@(private = "package")
write_sql_escaped_slash_path :: #force_inline proc(b: ^strings.Builder, s: string) {
	if strings.index_byte(s, '\\') < 0 {
		write_sql_escaped(b, s)
		return
	}
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if c == '\\' {
			strings.write_byte(b, '/')
		} else if c == '\'' {
			strings.write_string(b, "''")
		} else {
			strings.write_byte(b, c)
		}
	}
}

// Builds `SELECT * FROM quack_serve('<endpoint>'[, token='<token>', cert='<cert>', key='<key>'])`.
quack_serve_sql :: proc(cfg: Quack_Serve_Config, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(0, 96, allocator)
	endpoint := cfg.endpoint if len(cfg.endpoint) > 0 else "quack:localhost:0"
	strings.write_string(&b, "SELECT * FROM quack_serve('")
	write_sql_escaped(&b, endpoint)
	strings.write_byte(&b, '\'')
	if len(cfg.token) > 0 {
		strings.write_string(&b, ", token='")
		write_sql_escaped(&b, cfg.token)
		strings.write_byte(&b, '\'')
	}
	if len(cfg.cert) > 0 {
		strings.write_string(&b, ", cert='")
		write_sql_escaped_slash_path(&b, cfg.cert)
		strings.write_byte(&b, '\'')
	}
	if len(cfg.key) > 0 {
		strings.write_string(&b, ", key='")
		write_sql_escaped_slash_path(&b, cfg.key)
		strings.write_byte(&b, '\'')
	}
	strings.write_byte(&b, ')')
	return strings.to_string(b)
}

// Builds `SELECT * FROM quack_stop()` or `SELECT * FROM quack_stop('<endpoint>')`.
quack_stop_sql :: proc(endpoint := "", allocator := context.temp_allocator) -> string {
	if len(endpoint) == 0 {
		return strings.clone("SELECT * FROM quack_stop()", allocator)
	}
	b := strings.builder_make(0, 32 + len(endpoint), allocator)
	strings.write_string(&b, "SELECT * FROM quack_stop('")
	write_sql_escaped(&b, endpoint)
	strings.write_string(&b, "')")
	return strings.to_string(b)
}

// Builds `CALL quack_identify(name => '...', region => '...', meta => '...')` (`whoami.test` lines 42, 59).
quack_identify_sql :: proc(cfg: Quack_Identity_Config, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(0, 112, allocator)
	strings.write_string(&b, "CALL quack_identify(")
	first := true
	write_arg :: #force_inline proc(b: ^strings.Builder, first: ^bool, k, v: string) {
		if len(v) == 0 {
			return
		}
		if !first^ {
			strings.write_string(b, ", ")
		}
		first^ = false
		strings.write_string(b, k)
		strings.write_string(b, " => '")
		write_sql_escaped(b, v)
		strings.write_byte(b, '\'')
	}
	write_arg(&b, &first, "name", cfg.name)
	write_arg(&b, &first, "provider", cfg.provider)
	write_arg(&b, &first, "hostname", cfg.hostname)
	write_arg(&b, &first, "region", cfg.region)
	write_arg(&b, &first, "meta", cfg.meta_json)
	strings.write_byte(&b, ')')
	return strings.to_string(b)
}

// Builds `CREATE SECRET <name> (TYPE quack, TOKEN '<token>'[, SCOPE '<scope>'])` (`secret.test` line 10).
quack_secret_sql :: proc(cfg: Quack_Secret_Config, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(0, 96, allocator)
	strings.write_string(&b, "CREATE SECRET ")
	write_quoted_identifier(&b, cfg.name, false)
	strings.write_string(&b, " (TYPE quack, TOKEN '")
	write_sql_escaped(&b, cfg.token)
	strings.write_byte(&b, '\'')
	if len(cfg.scope) > 0 {
		strings.write_string(&b, ", SCOPE '")
		write_sql_escaped(&b, cfg.scope)
		strings.write_byte(&b, '\'')
	}
	strings.write_byte(&b, ')')
	return strings.to_string(b)
}

// Builds `ATTACH '<endpoint>' AS <alias> (TYPE quack[, READ_ONLY][, PERSISTENT][, TOKEN '...'][, SSL_FINGERPRINT '...'][, EXTRA_HTTP_HEADERS MAP {...}])`.
quack_attach_sql :: proc(cfg: Quack_Attach_Config, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(0, 160, allocator)
	strings.write_string(&b, "ATTACH '")
	write_sql_escaped(&b, cfg.endpoint)
	strings.write_string(&b, "' AS ")
	write_quoted_identifier(&b, cfg.alias, false)
	strings.write_string(&b, " (TYPE quack")
	if cfg.read_only {
		strings.write_string(&b, ", READ_ONLY")
	}
	if cfg.persistent {
		strings.write_string(&b, ", PERSISTENT")
	}
	if len(cfg.token) > 0 {
		strings.write_string(&b, ", TOKEN '")
		write_sql_escaped(&b, cfg.token)
		strings.write_byte(&b, '\'')
	}
	if len(cfg.ssl_fingerprint) > 0 {
		strings.write_string(&b, ", SSL_FINGERPRINT '")
		write_sql_escaped(&b, cfg.ssl_fingerprint)
		strings.write_byte(&b, '\'')
	}
	if len(cfg.extra_headers) > 0 {
		strings.write_string(&b, ", EXTRA_HTTP_HEADERS MAP {")
		for h, i in cfg.extra_headers {
			if i > 0 {
				strings.write_string(&b, ", ")
			}
			strings.write_byte(&b, '\'')
			write_sql_escaped(&b, h.key)
			strings.write_string(&b, "': '")
			write_sql_escaped(&b, h.value)
			strings.write_byte(&b, '\'')
		}
		strings.write_byte(&b, '}')
	}
	strings.write_byte(&b, ')')
	return strings.to_string(b)
}

// Builds `FROM <alias>.query('<escaped_remote_sql>')` (`secret.test` line 16).
quack_query_sql :: proc(alias: string, remote_sql: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(0, len(alias) + len(remote_sql) + 18, allocator)
	strings.write_string(&b, "FROM ")
	write_quoted_identifier(&b, alias, false)
	strings.write_string(&b, ".query('")
	write_sql_escaped(&b, remote_sql)
	strings.write_string(&b, "')")
	return strings.to_string(b)
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

// Expands `{var}` placeholders in a SQLLogicTest script or SQL snippet in a single pass.
sqllogic_expand_template :: proc(
	sql: string,
	vars: map[string]string,
	allocator := context.temp_allocator,
) -> string {
	first_open := strings.index_byte(sql, '{')
	if first_open < 0 || len(vars) == 0 {
		return strings.clone(sql, allocator)
	}
	b := strings.builder_make(0, len(sql) + 32, allocator)
	strings.write_string(&b, sql[:first_open])
	rem := sql[first_open:]
	for len(rem) > 0 {
		open_idx := strings.index_byte(rem, '{')
		if open_idx < 0 {
			strings.write_string(&b, rem)
			break
		}
		if open_idx > 0 {
			strings.write_string(&b, rem[:open_idx])
			rem = rem[open_idx:]
		}
		close_idx := strings.index_byte(rem, '}')
		if close_idx < 0 {
			strings.write_string(&b, rem)
			break
		}
		key := rem[1:close_idx]
		if val, found := vars[key]; found {
			strings.write_string(&b, val)
		} else {
			strings.write_string(&b, rem[:close_idx + 1])
		}
		rem = rem[close_idx + 1:]
	}
	return strings.to_string(b)
}

@(private = "file")
is_sqllogic_directive_start :: #force_inline proc(trimmed: string) -> bool {
	if len(trimmed) == 0 {
		return false
	}
	switch trimmed[0] {
	case 's':
		return strings.has_prefix(trimmed, "statement ")
	case 'q':
		return strings.has_prefix(trimmed, "query ")
	case 'r':
		return strings.has_prefix(trimmed, "require ") || trimmed == "restart"
	case 'i':
		return strings.has_prefix(trimmed, "include ")
	case 'l':
		return strings.has_prefix(trimmed, "loop ")
	case 'c':
		return strings.has_prefix(trimmed, "concurrentloop ")
	case 'e':
		return trimmed == "endloop"
	case 'h':
		return trimmed == "halt"
	case 'm':
		return strings.has_prefix(trimmed, "mode ")
	case 'p':
		return strings.has_prefix(trimmed, "pragma ")
	}
	return false
}

@(private = "file")
next_token_ws :: #force_inline proc(rest: ^string) -> (tok: string, ok: bool) {
	s := strings.trim_left_space(rest^)
	if len(s) == 0 {
		rest^ = ""
		return "", false
	}
	idx := 0
	for idx < len(s) {
		ch := s[idx]
		if ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n' {
			break
		}
		idx += 1
	}
	tok = s[:idx]
	rest^ = s[idx:]
	return tok, true
}

@(private = "file")
next_line_slice :: #force_inline proc(rest: ^string) -> (line: string, ok: bool) {
	s := rest^
	if len(s) == 0 {
		return "", false
	}
	nl := strings.index_byte(s, '\n')
	if nl < 0 {
		rest^ = ""
		if len(s) > 0 && s[len(s) - 1] == '\r' {
			return s[:len(s) - 1], true
		}
		return s, true
	}
	line = s[:nl]
	if len(line) > 0 && line[len(line) - 1] == '\r' {
		line = line[:len(line) - 1]
	}
	rest^ = s[nl + 1:]
	return line, true
}

@(private = "file")
parse_sqllogic_block_body :: #force_inline proc(
	rest: ^string,
	$trim_expected: bool,
	$stop_on_blank_sql_without_sep: bool,
	allocator := context.temp_allocator,
) -> (sql_str: string, exp_str: string) {
	sql_b: strings.Builder
	exp_b: strings.Builder
	sql_single := ""
	sql_lines := 0
	exp_single := ""
	exp_lines := 0
	in_expected := false

	for len(rest^) > 0 {
		saved_rest := rest^
		raw_l, lok := next_line_slice(rest)
		if !lok {
			break
		}
		trimmed_l := strings.trim_space(raw_l)
		if trimmed_l == "----" {
			in_expected = true
			continue
		}
		if in_expected {
			if len(trimmed_l) == 0 {
				break
			}
			if is_sqllogic_directive_start(trimmed_l) {
				rest^ = saved_rest
				break
			}
			exp_line := trimmed_l if trim_expected else raw_l
			if exp_lines == 0 {
				exp_single = exp_line
			} else {
				if exp_lines == 1 {
					exp_b = strings.builder_make(0, len(exp_single) + len(exp_line) + 32, allocator)
					strings.write_string(&exp_b, exp_single)
				}
				strings.write_byte(&exp_b, '\n')
				strings.write_string(&exp_b, exp_line)
			}
			exp_lines += 1
		} else {
			if is_sqllogic_directive_start(trimmed_l) || (len(trimmed_l) > 0 && trimmed_l[0] == '#') {
				rest^ = saved_rest
				break
			}
			if stop_on_blank_sql_without_sep && len(trimmed_l) == 0 {
				// Check if a `----` separator appears before the next directive
				probe := rest^
				has_sep := false
				for len(probe) > 0 {
					pl, pok := next_line_slice(&probe)
					if !pok {
						break
					}
					pt := strings.trim_space(pl)
					if pt == "----" {
						has_sep = true
						break
					}
					if is_sqllogic_directive_start(pt) || (len(pt) > 0 && pt[0] == '#') {
						break
					}
				}
				if !has_sep {
					break
				}
			}
			if sql_lines == 0 {
				sql_single = raw_l
			} else {
				if sql_lines == 1 {
					sql_b = strings.builder_make(0, len(sql_single) + len(raw_l) + 64, allocator)
					strings.write_string(&sql_b, sql_single)
				}
				strings.write_byte(&sql_b, '\n')
				strings.write_string(&sql_b, raw_l)
			}
			sql_lines += 1
		}
	}

	sql_str = sql_single if sql_lines <= 1 else strings.to_string(sql_b)
	exp_str = exp_single if exp_lines <= 1 else strings.to_string(exp_b)
	return sql_str, exp_str
}

// Parses a DuckDB SQLLogicTest `.test` script into structured `Sqllogic_Directive` items.
sqllogic_parse_script :: proc(
	content: string,
	allocator := context.temp_allocator,
) -> [dynamic]Sqllogic_Directive {
	directives := make([dynamic]Sqllogic_Directive, 0, 32, allocator)
	rest := content

	for len(rest) > 0 {
		raw_header, ok := next_line_slice(&rest)
		if !ok {
			break
		}
		line := strings.trim_space(raw_header)
		if len(line) == 0 || line[0] == '#' || strings.has_prefix(line, "test-env ") || strings.has_prefix(line, "set ") {
			continue
		}

		if strings.has_prefix(line, "require ") {
			ext := strings.trim_space(line[len("require "):])
			append(&directives, Sqllogic_Directive{kind = .REQUIRE, arg = ext})
			continue
		}

		if strings.has_prefix(line, "include ") {
			inc := strings.trim_space(line[len("include "):])
			if strings.index_byte(inc, '\\') >= 0 {
				inc, _ = strings.replace_all(inc, "\\", "/", allocator)
			}
			append(&directives, Sqllogic_Directive{kind = .INCLUDE, arg = inc})
			continue
		}

		if strings.has_prefix(line, "statement ") {
			hdr_rest := line[len("statement "):]
			tok1, _ := next_token_ws(&hdr_rest)
			tok2, _ := next_token_ws(&hdr_rest)
			is_error := tok1 == "error"
			conn_id := tok2

			sql_str, exp_str := parse_sqllogic_block_body(&rest, true, true, allocator)
			append(
				&directives,
				Sqllogic_Directive{
					kind          = .STATEMENT_ERROR if is_error else .STATEMENT_OK,
					connection_id = conn_id,
					sql           = sql_str,
					expected      = exp_str,
				},
			)
			continue
		}

		if strings.has_prefix(line, "query ") {
			hdr_rest := line[len("query "):]
			col_sig, has_sig := next_token_ws(&hdr_rest)
			if !has_sig {
				col_sig = "I"
			}
			sort_mode := "nosort"
			conn_id := ""
			for {
				p, pok := next_token_ws(&hdr_rest)
				if !pok {
					break
				}
				if p == "nosort" || p == "rowsort" || p == "valuesort" {
					sort_mode = p
				} else {
					conn_id = p
				}
			}

			sql_str, exp_str := parse_sqllogic_block_body(&rest, false, false, allocator)
			append(
				&directives,
				Sqllogic_Directive{
					kind          = .QUERY,
					arg           = col_sig,
					sort_mode     = sort_mode,
					connection_id = conn_id,
					sql           = sql_str,
					expected      = exp_str,
				},
			)
			continue
		}
	}

	return directives
}
