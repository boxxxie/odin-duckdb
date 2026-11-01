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

import "core:fmt"
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
	summarize:    bool,
	sample_spec:  string,
}

query_from :: proc(table: string, allocator := context.temp_allocator) -> Query {
	return Query{
		source      = table,
		projections = make([dynamic]string, allocator),
		excludes    = make([dynamic]string, allocator),
		replaces    = make([dynamic]string, allocator),
		joins       = make([dynamic]Query_Join, allocator),
		where_exprs = make([dynamic]string, allocator),
		group_by    = make([dynamic]string, allocator),
		order_by    = make([dynamic]string, allocator),
		limit_val   = -1,
		offset_val  = -1,
	}
}

query_from_quack :: proc(attach_alias: string, table: string, allocator := context.temp_allocator) -> Query {
	return query_from(fmt.aprintf("%s.%s", attach_alias, table, allocator = allocator), allocator)
}

query_from_quack_rpc :: proc(attach_alias: string, remote_sql: string, allocator := context.temp_allocator) -> Query {
	escaped, _ := strings.replace_all(remote_sql, "'", "''", allocator)
	return query_from(fmt.aprintf("%s.query('%s')", attach_alias, escaped, allocator = allocator), allocator)
}

query_from_parquet :: proc(path_glob: string, allocator := context.temp_allocator) -> Query {
	return query_from(fmt.aprintf("read_parquet('%s')", path_glob, allocator = allocator), allocator)
}

query_from_csv :: proc(path_glob: string, allocator := context.temp_allocator) -> Query {
	return query_from(fmt.aprintf("read_csv('%s')", path_glob, allocator = allocator), allocator)
}

query_from_json :: proc(path_glob: string, allocator := context.temp_allocator) -> Query {
	return query_from(fmt.aprintf("read_json_auto('%s')", path_glob, allocator = allocator), allocator)
}

query_from_iceberg :: proc(path: string, allocator := context.temp_allocator) -> Query {
	return query_from(fmt.aprintf("iceberg_scan('%s')", path, allocator = allocator), allocator)
}

query_from_delta :: proc(path: string, allocator := context.temp_allocator) -> Query {
	return query_from(fmt.aprintf("delta_scan('%s')", path, allocator = allocator), allocator)
}

query_select :: proc(q: ^Query, cols: ..string) -> ^Query {
	for c in cols {
		append(&q.projections, c)
	}
	return q
}

query_exclude :: proc(q: ^Query, cols: ..string) -> ^Query {
	for c in cols {
		append(&q.excludes, c)
	}
	return q
}

query_replace :: proc(q: ^Query, exprs: ..string) -> ^Query {
	for e in exprs {
		append(&q.replaces, e)
	}
	return q
}

query_where :: proc(q: ^Query, expr: string) -> ^Query {
	append(&q.where_exprs, expr)
	return q
}

query_join :: proc(q: ^Query, kind: Join_Kind, target: string, on_expr: string) -> ^Query {
	append(&q.joins, Query_Join{kind = kind, target = target, on_expr = on_expr})
	return q
}

query_asof_join :: proc(q: ^Query, target: string, on_expr: string, using_col := "") -> ^Query {
	append(&q.joins, Query_Join{kind = .ASOF, target = target, on_expr = on_expr, using_col = using_col})
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
	for e in exprs {
		append(&q.order_by, e)
	}
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

// Compiles a `Query` AST into a DuckDB 2.0 Friendly SQL string.
query_to_sql :: proc(q: Query, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	if q.summarize {
		strings.write_string(&b, "SUMMARIZE ")
	}
	strings.write_string(&b, "SELECT ")

	if len(q.projections) == 0 {
		strings.write_byte(&b, '*')
		if len(q.excludes) > 0 {
			strings.write_string(&b, " EXCLUDE (")
			for c, i in q.excludes {
				if i > 0 {
					strings.write_string(&b, ", ")
				}
				strings.write_string(&b, c)
			}
			strings.write_byte(&b, ')')
		}
		if len(q.replaces) > 0 {
			strings.write_string(&b, " REPLACE (")
			for r, i in q.replaces {
				if i > 0 {
					strings.write_string(&b, ", ")
				}
				strings.write_string(&b, r)
			}
			strings.write_byte(&b, ')')
		}
	} else {
		for c, i in q.projections {
			if i > 0 {
				strings.write_string(&b, ", ")
			}
			strings.write_string(&b, c)
		}
	}

	fmt.sbprintf(&b, " FROM %s", q.source)

	for j in q.joins {
		switch j.kind {
		case .INNER:
			fmt.sbprintf(&b, " INNER JOIN %s ON %s", j.target, j.on_expr)
		case .LEFT:
			fmt.sbprintf(&b, " LEFT JOIN %s ON %s", j.target, j.on_expr)
		case .RIGHT:
			fmt.sbprintf(&b, " RIGHT JOIN %s ON %s", j.target, j.on_expr)
		case .FULL:
			fmt.sbprintf(&b, " FULL JOIN %s ON %s", j.target, j.on_expr)
		case .CROSS:
			fmt.sbprintf(&b, " CROSS JOIN %s", j.target)
		case .ASOF:
			if len(j.using_col) > 0 {
				fmt.sbprintf(&b, " ASOF JOIN %s ON %s USING (%s)", j.target, j.on_expr, j.using_col)
			} else {
				fmt.sbprintf(&b, " ASOF JOIN %s ON %s", j.target, j.on_expr)
			}
		}
	}

	if len(q.where_exprs) > 0 {
		strings.write_string(&b, " WHERE ")
		for w, i in q.where_exprs {
			if i > 0 {
				strings.write_string(&b, " AND ")
			}
			strings.write_string(&b, w)
		}
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
		fmt.sbprintf(&b, " QUALIFY %s", q.qualify_expr)
	}

	if len(q.order_by) > 0 {
		strings.write_string(&b, " ORDER BY ")
		for o, i in q.order_by {
			if i > 0 {
				strings.write_string(&b, ", ")
			}
			strings.write_string(&b, o)
		}
	}

	if len(q.sample_spec) > 0 {
		fmt.sbprintf(&b, " USING SAMPLE %s", q.sample_spec)
	}

	if q.limit_val >= 0 {
		fmt.sbprintf(&b, " LIMIT %d", q.limit_val)
	}
	if q.offset_val >= 0 {
		fmt.sbprintf(&b, " OFFSET %d", q.offset_val)
	}

	return strings.to_string(b)
}
