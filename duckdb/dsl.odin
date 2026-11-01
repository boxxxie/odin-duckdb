package duckdb

// ============================================================================
// Layer 2: Composable Relational Query Builder (`duckdb/dsl.odin`)
// ============================================================================
// Red-First Stubs (implementation saved in commit `036eef4`, reverted while finalizing ATDD test suite)
// ============================================================================

Join_Kind :: enum {
	INNER,
	LEFT,
	RIGHT,
	FULL,
	CROSS,
	ASOF,
}

Query_Join :: struct {
	kind:      Join_Kind,
	target:    string,
	on_expr:   string,
	using_col: string,
}

Query :: struct {
	source:       string,
	projections:  [dynamic]string,
	excludes:     [dynamic]string,
	replaces:     [dynamic]string,
	joins:        [dynamic]Query_Join,
	where_exprs:  [dynamic]string,
	group_by_all: bool,
	group_by:     [dynamic]string,
	qualify_expr: string,
	order_by:     [dynamic]string,
	limit_val:    int,
	offset_val:   int,
}

query_from :: proc(table: string, allocator := context.temp_allocator) -> Query {
	return Query{source = table}
}

query_from_quack :: proc(attach_alias: string, table: string, allocator := context.temp_allocator) -> Query {
	return Query{}
}

query_from_quack_rpc :: proc(attach_alias: string, remote_sql: string, allocator := context.temp_allocator) -> Query {
	return Query{}
}

query_from_parquet :: proc(path_glob: string, allocator := context.temp_allocator) -> Query {
	return Query{}
}

query_from_csv :: proc(path_glob: string, allocator := context.temp_allocator) -> Query {
	return Query{}
}

query_select :: proc(q: ^Query, cols: ..string) -> ^Query {
	return q
}

query_exclude :: proc(q: ^Query, cols: ..string) -> ^Query {
	return q
}

query_replace :: proc(q: ^Query, exprs: ..string) -> ^Query {
	return q
}

query_where :: proc(q: ^Query, expr: string) -> ^Query {
	return q
}

query_join :: proc(q: ^Query, kind: Join_Kind, target: string, on_expr: string) -> ^Query {
	return q
}

query_asof_join :: proc(q: ^Query, target: string, on_expr: string, using_col := "") -> ^Query {
	return q
}

query_group_by_all :: proc(q: ^Query) -> ^Query {
	return q
}

query_qualify :: proc(q: ^Query, window_predicate: string) -> ^Query {
	return q
}

query_order_by :: proc(q: ^Query, exprs: ..string) -> ^Query {
	return q
}

query_limit :: proc(q: ^Query, limit: int, offset := -1) -> ^Query {
	return q
}

query_to_sql :: proc(q: Query, allocator := context.temp_allocator) -> string {
	return ""
}
