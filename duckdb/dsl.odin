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

Small_Query_Strings :: struct {
	inline: [3]string,
	len:    int,
	dyn:    [dynamic]string,
}

Query :: struct {
	source:       string,
	projections:  Small_Query_Strings,
	excludes:     Small_Query_Strings,
	replaces:     Small_Query_Strings,
	joins_in:     [1]Query_Join,
	joins_len:    int,
	joins:        [dynamic]Query_Join,
	where_exprs:  Small_Query_Strings,
	group_by_all: bool,
	group_by:     [dynamic]string,
	qualify_expr: string,
	order_by:     Small_Query_Strings,
	limit_val:    int,
	offset_val:   int,
	summarize:    bool,
	sample_spec:  string,
	params_in:    [2]any,
	params_len:   int,
	params:       [dynamic]any,
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
	q.joins.allocator           = allocator
	q.where_exprs.dyn.allocator = allocator
	q.group_by.allocator        = allocator
	q.order_by.dyn.allocator    = allocator
	q.params.allocator          = allocator
	return q
}

@(private = "file")
sqs_append :: #force_inline proc(s: ^Small_Query_Strings, items: ..string) {
	if len(s.dyn) == 0 && s.len + len(items) <= len(s.inline) {
		for it, i in items {
			s.inline[s.len + i] = it
		}
		s.len += len(items)
		return
	}
	if len(s.dyn) == 0 {
		reserve(&s.dyn, s.len + len(items) + 4)
		append(&s.dyn, ..s.inline[:s.len])
	}
	append(&s.dyn, ..items)
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
	sqs_append(&q.projections, ..cols)
	return q
}

query_exclude :: proc(q: ^Query, cols: ..string) -> ^Query {
	sqs_append(&q.excludes, ..cols)
	return q
}

query_replace :: proc(q: ^Query, exprs: ..string) -> ^Query {
	sqs_append(&q.replaces, ..exprs)
	return q
}

query_where :: proc(q: ^Query, expr: string) -> ^Query {
	sqs_append(&q.where_exprs, expr)
	return q
}

query_bind :: proc(q: ^Query, args: ..any) -> ^Query {
	if len(q.params) == 0 && q.params_len + len(args) <= len(q.params_in) {
		for a, i in args {
			q.params_in[q.params_len + i] = a
		}
		q.params_len += len(args)
		return q
	}
	if len(q.params) == 0 {
		reserve(&q.params, q.params_len + len(args) + 4)
		append(&q.params, ..q.params_in[:q.params_len])
	}
	append(&q.params, ..args)
	return q
}

query_where_bind :: proc(q: ^Query, expr: string, args: ..any) -> ^Query {
	sqs_append(&q.where_exprs, expr)
	query_bind(q, ..args)
	return q
}

@(private = "file")
append_query_join :: #force_inline proc(q: ^Query, j: Query_Join) {
	if len(q.joins) == 0 && q.joins_len < len(q.joins_in) {
		q.joins_in[q.joins_len] = j
		q.joins_len += 1
		return
	}
	if len(q.joins) == 0 {
		reserve(&q.joins, q.joins_len + 2)
		append(&q.joins, ..q.joins_in[:q.joins_len])
	}
	append(&q.joins, j)
}

query_join :: proc(q: ^Query, kind: Join_Kind, target: string, on_expr: string) -> ^Query {
	append_query_join(q, Query_Join{kind = kind, target = target, on_expr = on_expr})
	return q
}

query_asof_join :: proc(q: ^Query, target: string, on_expr: string, using_col := "") -> ^Query {
	append_query_join(q, Query_Join{kind = .ASOF, target = target, on_expr = on_expr, using_col = using_col})
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
	sqs_append(&q.order_by, ..exprs)
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
write_sqs_sep :: #force_inline proc(b: ^strings.Builder, s: Small_Query_Strings, sep: string) {
	if len(s.dyn) > 0 {
		for item, i in s.dyn {
			if i > 0 {
				strings.write_string(b, sep)
			}
			strings.write_string(b, item)
		}
		return
	}
	for i := 0; i < s.len; i += 1 {
		if i > 0 {
			strings.write_string(b, sep)
		}
		strings.write_string(b, s.inline[i])
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
	b := strings.builder_make(0, 192, allocator)
	if q.summarize {
		strings.write_string(&b, "SUMMARIZE ")
	}
	strings.write_string(&b, "SELECT ")

	if q.projections.len == 0 && len(q.projections.dyn) == 0 {
		strings.write_byte(&b, '*')
	} else {
		write_sqs_sep(&b, q.projections, ", ")
	}
	if q.excludes.len > 0 || len(q.excludes.dyn) > 0 {
		strings.write_string(&b, " EXCLUDE (")
		write_sqs_sep(&b, q.excludes, ", ")
		strings.write_byte(&b, ')')
	}
	if q.replaces.len > 0 || len(q.replaces.dyn) > 0 {
		strings.write_string(&b, " REPLACE (")
		write_sqs_sep(&b, q.replaces, ", ")
		strings.write_byte(&b, ')')
	}

	strings.write_string(&b, " FROM ")
	strings.write_string(&b, q.source)

	if len(q.joins) > 0 {
		for j in q.joins {
			write_single_join(&b, j)
		}
	} else {
		for i := 0; i < q.joins_len; i += 1 {
			write_single_join(&b, q.joins_in[i])
		}
	}

	if q.where_exprs.len > 0 || len(q.where_exprs.dyn) > 0 {
		strings.write_string(&b, " WHERE ")
		write_sqs_sep(&b, q.where_exprs, " AND ")
	}

	if q.group_by_all {
		strings.write_string(&b, " GROUP BY ALL")
	} else if len(q.group_by) > 0 {
		strings.write_string(&b, " GROUP BY ")
		for g, i in q.group_by {
			if i > 0 {
				strings.write_string(&b, ", ")
			}
			strings.write_string(&b, g)
		}
	}

	if len(q.qualify_expr) > 0 {
		strings.write_string(&b, " QUALIFY ")
		strings.write_string(&b, q.qualify_expr)
	}

	if q.order_by.len > 0 || len(q.order_by.dyn) > 0 {
		strings.write_string(&b, " ORDER BY ")
		write_sqs_sep(&b, q.order_by, ", ")
	}

	if len(q.sample_spec) > 0 {
		strings.write_string(&b, " USING SAMPLE ")
		strings.write_string(&b, q.sample_spec)
	}

	if q.limit_val >= 0 {
		strings.write_string(&b, " LIMIT ")
		strings.write_int(&b, q.limit_val)
	}
	if q.offset_val >= 0 {
		strings.write_string(&b, " OFFSET ")
		strings.write_int(&b, q.offset_val)
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
	sql := query_to_sql(q, context.temp_allocator)
	if len(q.params) > 0 {
		return query_as(conn, T, sql, allocator, err, ..q.params[:])
	}
	switch q.params_len {
	case 0:
		return query_as(conn, T, sql, allocator, err)
	case 1:
		return query_as(conn, T, sql, allocator, err, q.params_in[0])
	case:
		return query_as(conn, T, sql, allocator, err, q.params_in[0], q.params_in[1])
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
