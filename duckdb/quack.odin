package duckdb

// ============================================================================
// DuckDB 2.0 Quack Protocol & SQLLogicTest `.test` Parser (`duckdb/quack.odin`)
// ============================================================================
// Red-First Stubs (implementation saved in commit `036eef4`, reverted while finalizing ATDD test suite)
// ============================================================================

Quack_Serve_Config :: struct {
	endpoint: string,
	token:    string,
	cert:     string,
	key:      string,
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
	endpoint:        string,
	alias:           string,
	token:           string,
	read_only:       bool,
	persistent:      bool,
	ssl_fingerprint: string,
	extra_headers:   []Quack_Header,
}

quack_serve_sql :: proc(cfg: Quack_Serve_Config, allocator := context.temp_allocator) -> string {
	return ""
}

quack_stop_sql :: proc(endpoint := "", allocator := context.temp_allocator) -> string {
	return ""
}

quack_identify_sql :: proc(cfg: Quack_Identity_Config, allocator := context.temp_allocator) -> string {
	return ""
}

quack_secret_sql :: proc(cfg: Quack_Secret_Config, allocator := context.temp_allocator) -> string {
	return ""
}

quack_attach_sql :: proc(cfg: Quack_Attach_Config, allocator := context.temp_allocator) -> string {
	return ""
}

quack_query_sql :: proc(alias: string, remote_sql: string, allocator := context.temp_allocator) -> string {
	return ""
}

quack_normalize_uri :: proc(
	uri: string,
	allocator := context.temp_allocator,
) -> (normalized: string, ok: bool) {
	return "", false
}

Sqllogic_Directive_Kind :: enum {
	REQUIRE,
	INCLUDE,
	STATEMENT_OK,
	STATEMENT_ERROR,
	QUERY,
}

Sqllogic_Directive :: struct {
	kind:          Sqllogic_Directive_Kind,
	arg:           string,
	sort_mode:     string,
	connection_id: string,
	sql:           string,
	expected:      string,
}

sqllogic_parse_script :: proc(
	content: string,
	allocator := context.temp_allocator,
) -> [dynamic]Sqllogic_Directive {
	return make([dynamic]Sqllogic_Directive, allocator)
}

sqllogic_expand_template :: proc(
	content: string,
	vars: map[string]string,
	allocator := context.temp_allocator,
) -> string {
	return ""
}
