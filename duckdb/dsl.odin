package duckdb

// ============================================================================
// Layer 2: Composable Relational Query Builder (`duckdb/dsl.odin`)
// ============================================================================
// Upstream & Architectural References:
// - `references/zig/zig_prql` (PRQL-style pipeline relational query composition)
// - `references/elixir/quackdb/test/quack_db/source_test.exs` & `analytics_test.exs`
// - `references/duckdb2/duckdb-claude-plugin/skills/duckdb-sql/SKILL.md`
//   (DuckDB 2.0 Friendly SQL: `SELECT * EXCLUDE (...)`, `REPLACE (...)`,
//   `GROUP BY ALL`, `QUALIFY`, `ASOF JOIN`, `SUMMARIZE`, `USING SAMPLE`,
//   `read_parquet`, `read_csv`, `read_json_auto`, `iceberg_scan`, `delta_scan`)
// - `references/duckdb2/duckdb-claude-plugin/skills/quack/SKILL.md`
//   (Quack remote catalog & `alias.query(...)` RPC pushdown)
// ============================================================================

import "base:intrinsics"
import "core:strings"

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

// Generic Small-Buffer Optimization (SBO) container that stores up to `$N` elements inline on
// the stack and spills into `dyn` on the heap only when more than `$N` elements are appended.
Small_Buffer :: struct($N: int, $T: typeid) {
	inline: [N]T,
	len:    int,
	dyn:    [dynamic]T,
}

Small_Query_Strings :: Small_Buffer(3, string)

sb_len :: #force_inline proc(b: Small_Buffer($N, $T)) -> int {
	return len(b.dyn) if len(b.dyn) > 0 else b.len
}

sb_slice :: #force_inline proc(b: ^Small_Buffer($N, $T)) -> []T {
	return b.dyn[:] if len(b.dyn) > 0 else b.inline[:b.len]
}

sb_append :: #force_inline proc(b: ^Small_Buffer($N, $T), items: ..T) {
	if len(b.dyn) == 0 && b.len + len(items) <= N {
		for it, i in items {
			b.inline[b.len + i] = it
		}
		b.len += len(items)
		return
	}
	if len(b.dyn) == 0 {
		reserve(&b.dyn, b.len + len(items) + 4)
		append(&b.dyn, ..b.inline[:b.len])
	}
	append(&b.dyn, ..items)
}

Query :: struct {
	source:       string,
	projections:  Small_Buffer(3, string),
	excludes:     Small_Buffer(3, string),
	replaces:     Small_Buffer(3, string),
	joins:        Small_Buffer(1, Query_Join),
	where_exprs:  Small_Buffer(3, string),
	group_by_all: bool,
	group_by:     [dynamic]string,
	qualify_expr: string,
	order_by:     Small_Buffer(3, string),
	limit_val:    int,
	offset_val:   int,
	summarize:    bool,
	sample_spec:  string,
	params:       Small_Buffer(2, Query_Param),
}

query_from :: proc(table: string, allocator := context.temp_allocator) -> Query {
	q := Query{
		source     = table,
		limit_val  = -1,
		offset_val = -1,
	}
	q.projections.dyn.allocator = allocator
	q.excludes.dyn.allocator    = allocator
	q.replaces.dyn.allocator    = allocator
	q.joins.dyn.allocator       = allocator
	q.where_exprs.dyn.allocator = allocator
	q.group_by.allocator        = allocator
	q.order_by.dyn.allocator    = allocator
	q.params.dyn.allocator      = allocator
	return q
}

query_from_quack :: proc(attach_alias: string, table: string, allocator := context.temp_allocator) -> Query {
	simple_a, _ := is_simple_unquoted_identifier(attach_alias)
	if simple_a && is_simple_qualified_identifier(table) {
		buf := make([]u8, len(attach_alias) + 1 + len(table), allocator)
		intrinsics.mem_copy(&buf[0], raw_data(attach_alias), len(attach_alias))
		buf[len(attach_alias)] = '.'
		intrinsics.mem_copy(&buf[len(attach_alias) + 1], raw_data(table), len(table))
		return query_from(string(buf), allocator)
	}
	b := strings.builder_make(0, len(attach_alias) + len(table) + 6, allocator)
	write_quoted_identifier(&b, attach_alias, false)
	strings.write_byte(&b, '.')
	write_quoted_identifier(&b, table, true)
	return query_from(strings.to_string(b), allocator)
}

query_from_quack_rpc :: proc(attach_alias: string, remote_sql: string, allocator := context.temp_allocator) -> Query {
	b := strings.builder_make(0, len(attach_alias) + len(remote_sql) + 16, allocator)
	write_quoted_identifier(&b, attach_alias, false)
	strings.write_string(&b, ".query('")
	write_sql_escaped(&b, remote_sql)
	strings.write_string(&b, "')")
	return query_from(strings.to_string(b), allocator)
}

@(private = "file")
make_fn_call_source :: #force_inline proc(fn_prefix: string, path: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(0, len(fn_prefix) + len(path) + 4, allocator)
	strings.write_string(&b, fn_prefix)
	write_sql_escaped_slash_path(&b, path)
	strings.write_string(&b, "')")
	return strings.to_string(b)
}

query_from_parquet :: proc(path_glob: string, allocator := context.temp_allocator) -> Query {
	return query_from(make_fn_call_source("read_parquet('", path_glob, allocator), allocator)
}

query_from_csv :: proc(path_glob: string, allocator := context.temp_allocator) -> Query {
	return query_from(make_fn_call_source("read_csv('", path_glob, allocator), allocator)
}

query_from_json :: proc(path_glob: string, allocator := context.temp_allocator) -> Query {
	return query_from(make_fn_call_source("read_json_auto('", path_glob, allocator), allocator)
}

query_from_iceberg :: proc(path: string, allocator := context.temp_allocator) -> Query {
	return query_from(make_fn_call_source("iceberg_scan('", path, allocator), allocator)
}

query_from_delta :: proc(path: string, allocator := context.temp_allocator) -> Query {
	return query_from(make_fn_call_source("delta_scan('", path, allocator), allocator)
}

query_select :: proc(q: ^Query, cols: ..string) -> ^Query {
	sb_append(&q.projections, ..cols)
	return q
}

query_exclude :: proc(q: ^Query, cols: ..string) -> ^Query {
	sb_append(&q.excludes, ..cols)
	return q
}

query_replace :: proc(q: ^Query, exprs: ..string) -> ^Query {
	sb_append(&q.replaces, ..exprs)
	return q
}

query_where :: proc(q: ^Query, expr: string) -> ^Query {
	sb_append(&q.where_exprs, expr)
	return q
}

// Binds positional query parameters into `q.params` by value (`Query_Param`) so bound parameters
// never retain dangling stack pointers if `q` is returned from a helper procedure.
query_bind :: proc(q: ^Query, args: ..any) -> ^Query {
	for a in args {
		qp, _ := v2_box_query_param(a)
		sb_append(&q.params, qp)
	}
	return q
}

query_where_bind :: proc(q: ^Query, expr: string, args: ..any) -> ^Query {
	sb_append(&q.where_exprs, expr)
	query_bind(q, ..args)
	return q
}

query_join :: proc(q: ^Query, kind: Join_Kind, target: string, on_expr: string) -> ^Query {
	sb_append(&q.joins, Query_Join{kind = kind, target = target, on_expr = on_expr})
	return q
}

query_asof_join :: proc(q: ^Query, target: string, on_expr: string, using_col := "") -> ^Query {
	sb_append(&q.joins, Query_Join{kind = .ASOF, target = target, on_expr = on_expr, using_col = using_col})
	return q
}

query_group_by_all :: proc(q: ^Query) -> ^Query {
	q.group_by_all = true
	return q
}

query_qualify :: proc(q: ^Query, window_predicate: string) -> ^Query {
	q.qualify_expr = window_predicate
	return q
}

query_order_by :: proc(q: ^Query, exprs: ..string) -> ^Query {
	sb_append(&q.order_by, ..exprs)
	return q
}

query_limit :: proc(q: ^Query, limit: int, offset := -1) -> ^Query {
	q.limit_val = limit
	q.offset_val = offset
	return q
}

query_summarize :: proc(q: ^Query) -> ^Query {
	q.summarize = true
	return q
}

query_sample :: proc(q: ^Query, sample_spec: string) -> ^Query {
	q.sample_spec = sample_spec
	return q
}

@(private = "file")
write_sb_strings_sep :: #force_inline proc(b: ^strings.Builder, s: ^Small_Buffer($N, string), sep: string) {
	for item, i in sb_slice(s) {
		if i > 0 {
			strings.write_string(b, sep)
		}
		strings.write_string(b, item)
	}
}

@(private = "file")
write_single_join :: #force_inline proc(b: ^strings.Builder, j: Query_Join) {
	switch j.kind {
	case .INNER:
		strings.write_string(b, " INNER JOIN ")
		strings.write_string(b, j.target)
		strings.write_string(b, " ON ")
		strings.write_string(b, j.on_expr)
	case .LEFT:
		strings.write_string(b, " LEFT JOIN ")
		strings.write_string(b, j.target)
		strings.write_string(b, " ON ")
		strings.write_string(b, j.on_expr)
	case .RIGHT:
		strings.write_string(b, " RIGHT JOIN ")
		strings.write_string(b, j.target)
		strings.write_string(b, " ON ")
		strings.write_string(b, j.on_expr)
	case .FULL:
		strings.write_string(b, " FULL JOIN ")
		strings.write_string(b, j.target)
		strings.write_string(b, " ON ")
		strings.write_string(b, j.on_expr)
	case .CROSS:
		strings.write_string(b, " CROSS JOIN ")
		strings.write_string(b, j.target)
	case .ASOF:
		strings.write_string(b, " ASOF JOIN ")
		strings.write_string(b, j.target)
		strings.write_string(b, " ON ")
		strings.write_string(b, j.on_expr)
		if len(j.using_col) > 0 {
			strings.write_string(b, " USING (")
			strings.write_string(b, j.using_col)
			strings.write_byte(b, ')')
		}
	}
}

// Compiles a `Query` AST into a DuckDB 2.0 Friendly SQL string.
query_to_sql :: proc(q: Query, allocator := context.temp_allocator) -> string {
	q_mut := q
	b := strings.builder_make(0, 192, allocator)
	if q_mut.summarize {
		strings.write_string(&b, "SUMMARIZE ")
	}
	strings.write_string(&b, "SELECT ")

	if sb_len(q_mut.projections) == 0 {
		strings.write_byte(&b, '*')
	} else {
		write_sb_strings_sep(&b, &q_mut.projections, ", ")
	}
	if sb_len(q_mut.excludes) > 0 {
		strings.write_string(&b, " EXCLUDE (")
		write_sb_strings_sep(&b, &q_mut.excludes, ", ")
		strings.write_byte(&b, ')')
	}
	if sb_len(q_mut.replaces) > 0 {
		strings.write_string(&b, " REPLACE (")
		write_sb_strings_sep(&b, &q_mut.replaces, ", ")
		strings.write_byte(&b, ')')
	}

	strings.write_string(&b, " FROM ")
	strings.write_string(&b, q_mut.source)

	for j in sb_slice(&q_mut.joins) {
		write_single_join(&b, j)
	}

	if sb_len(q_mut.where_exprs) > 0 {
		strings.write_string(&b, " WHERE ")
		write_sb_strings_sep(&b, &q_mut.where_exprs, " AND ")
	}

	if q_mut.group_by_all {
		strings.write_string(&b, " GROUP BY ALL")
	} else if len(q_mut.group_by) > 0 {
		strings.write_string(&b, " GROUP BY ")
		for g, i in q_mut.group_by {
			if i > 0 {
				strings.write_string(&b, ", ")
			}
			strings.write_string(&b, g)
		}
	}

	if len(q_mut.qualify_expr) > 0 {
		strings.write_string(&b, " QUALIFY ")
		strings.write_string(&b, q_mut.qualify_expr)
	}

	if sb_len(q_mut.order_by) > 0 {
		strings.write_string(&b, " ORDER BY ")
		write_sb_strings_sep(&b, &q_mut.order_by, ", ")
	}

	if len(q_mut.sample_spec) > 0 {
		strings.write_string(&b, " USING SAMPLE ")
		strings.write_string(&b, q_mut.sample_spec)
	}

	if q_mut.limit_val >= 0 {
		strings.write_string(&b, " LIMIT ")
		strings.write_int(&b, q_mut.limit_val)
	}
	if q_mut.offset_val >= 0 {
		strings.write_string(&b, " OFFSET ")
		strings.write_int(&b, q_mut.offset_val)
	}

	return strings.to_string(b)
}

// Compiles `q` to SQL and executes it with its bound `q.params` via `query_as`.
query_execute_as :: proc(
	conn: V2_Connection_Handle,
	$T: typeid,
	q: Query,
	allocator := context.allocator,
	err: ^V2_Error_Info_Handle = nil,
) -> (out: [dynamic]T, rc: V2_Error) where intrinsics.type_is_struct(T) {
	q_mut := q
	sql := query_to_sql(q_mut, context.temp_allocator)
	params := sb_slice(&q_mut.params)
	switch len(params) {
	case 0:
		return query_as(conn, T, sql, allocator, err)
	case 1:
		return query_as(conn, T, sql, allocator, err, params[0])
	case 2:
		return query_as(conn, T, sql, allocator, err, params[0], params[1])
	case:
		stack_anys: [16]any
		anys: []any
		if len(params) <= len(stack_anys) {
			anys = stack_anys[:len(params)]
		} else {
			anys = make([]any, len(params), context.temp_allocator)
		}
		for &p, idx in params {
			anys[idx] = p
		}
		return query_as(conn, T, sql, allocator, err, ..anys)
	}
}

// Compiles `q` to SQL, binds & validates its result schema against `$T`, and prepares a reusable
// `Prepared_Query(T)` handle for high-frequency parameterized execution via `prepared_query_execute_as`.
query_prepare_as :: proc(
	conn: V2_Connection_Handle,
	$T: typeid,
	q: Query,
	out_pq: ^Prepared_Query(T),
	require_cacheable: bool = false,
	allocator := context.allocator,
	err: ^V2_Error_Info_Handle = nil,
) -> V2_Error where intrinsics.type_is_struct(T) {
	sql := query_to_sql(q, context.temp_allocator)
	return prepared_query_create(conn, T, sql, out_pq, require_cacheable, allocator, err)
}
