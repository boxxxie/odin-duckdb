package duckdb

// ============================================================================
// Layer 3: Schema Introspection & Odin Struct Codegen (`duckdb/codegen.odin`)
// ============================================================================
// Upstream References:
// - `references/c/duckdb-capi-2.0/test/api/capi/v2/test_capi_v2_statement.cpp`
//   (`duckdb_v2_statement_bind` + `duckdb_v2_schema_get_count` + `duckdb_v2_schema_get_field`)
// - `references/odin/odin-postgresql` & `references/zig/zuckdb`
// ============================================================================

import "core:fmt"
import "core:strings"

Column_Schema :: struct {
	name:     string,
	sql_type: string,
	type_id:  V2_Logical_Type_Id,
	nullable: bool,
}

// Maps a `V2_Logical_Type_Handle` + `V2_Logical_Type_Id` to its SQL type name,
// returning a static literal for all 21 primitive types and only allocating via `allocator`
// for parameterized/composite types (`DECIMAL`, `STRUCT`, `LIST`, `MAP`, `ARRAY`, `ENUM`, `UNION`).
logical_type_to_sql_name :: proc(
	ftype: V2_Logical_Type_Handle,
	tid: V2_Logical_Type_Id,
	allocator := context.allocator,
	err: ^V2_Error_Info_Handle = nil,
) -> (sql_type: string, rc: V2_Error) {
	#partial switch tid {
	case .BOOLEAN:
		return "BOOLEAN", .NONE
	case .TINYINT:
		return "TINYINT", .NONE
	case .SMALLINT:
		return "SMALLINT", .NONE
	case .INTEGER:
		return "INTEGER", .NONE
	case .BIGINT:
		return "BIGINT", .NONE
	case .UTINYINT:
		return "UTINYINT", .NONE
	case .USMALLINT:
		return "USMALLINT", .NONE
	case .UINTEGER:
		return "UINTEGER", .NONE
	case .UBIGINT:
		return "UBIGINT", .NONE
	case .FLOAT:
		return "FLOAT", .NONE
	case .DOUBLE:
		return "DOUBLE", .NONE
	case .VARCHAR:
		return "VARCHAR", .NONE
	case .BLOB:
		return "BLOB", .NONE
	case .DATE:
		return "DATE", .NONE
	case .TIME:
		return "TIME", .NONE
	case .TIMESTAMP:
		return "TIMESTAMP", .NONE
	case .TIMESTAMP_TZ:
		return "TIMESTAMPTZ", .NONE
	case .HUGEINT:
		return "HUGEINT", .NONE
	case .UHUGEINT:
		return "UHUGEINT", .NONE
	case .UUID:
		return "UUID", .NONE
	case .INTERVAL:
		return "INTERVAL", .NONE
	case:
		return v2_two_call_string(ftype, duckdb_v2_logical_type_to_text, err, allocator)
	}
}

@(private = "file")
destroy_column_schemas :: proc(cols: ^[dynamic]Column_Schema, allocator := context.allocator) {
	for c in cols^ {
		delete(c.name, allocator)
	}
	delete(cols^)
	cols^ = nil
}

// Introspects any table, view, or query source (`table_or_source`) without executing the query.
// Uses the C API v2 Catalog fast-path (`duckdb_v2_connection_describe_table`) for base tables (~35x faster)
// and falls back to `duckdb_v2_statement_bind` + `V2_Schema_Handle` for views, subqueries, and table functions.
introspect_table_schema :: proc(
	conn: V2_Connection_Handle,
	table_or_source: string,
	allocator := context.allocator,
	err: ^V2_Error_Info_Handle = nil,
) -> (cols: [dynamic]Column_Schema, rc: V2_Error) {
	defer if rc != .NONE {
		destroy_column_schemas(&cols, allocator)
	}

	is_identifier := !strings.contains_any(table_or_source, "() '\"\t\n")
	if is_identifier {
		qname_str := v2_str_from_string(table_or_source)
		qname: V2_Qname_Handle
		if duckdb_v2_qname_parse(&qname_str, &qname, nil) == .NONE {
			defer duckdb_v2_qname_destroy(&qname)
			desc: V2_Table_Description_Handle
			if duckdb_v2_connection_describe_table(conn, qname, &desc, nil) == .NONE {
				defer duckdb_v2_table_description_destroy(&desc)
				col_count: V2_Idx
				rc = duckdb_v2_table_description_get_column_count(desc, &col_count, err)
				if rc != .NONE {
					return cols, rc
				}
				cols = make([dynamic]Column_Schema, 0, int(col_count), allocator)
				for i: V2_Idx = 0; i < col_count; i += 1 {
					col: V2_Column_Description_Handle
					rc = duckdb_v2_table_description_get_column(desc, i, &col, err)
					if rc != .NONE {
						return cols, rc
					}
					defer duckdb_v2_column_description_destroy(&col)

					fname: V2_Identifier
					rc = duckdb_v2_column_description_get_name(col, &fname, err)
					if rc != .NONE {
						return cols, rc
					}

					ftype: V2_Logical_Type_Handle
					rc = duckdb_v2_column_description_get_type(col, &ftype, err)
					if rc != .NONE {
						return cols, rc
					}
					defer duckdb_v2_logical_type_destroy(&ftype)

					tid: V2_Logical_Type_Id
					rc = duckdb_v2_logical_type_get_id(ftype, &tid, err)
					if rc != .NONE {
						return cols, rc
					}

					sql_type_str: string
					sql_type_str, rc = logical_type_to_sql_name(ftype, tid, allocator, err)
					if rc != .NONE {
						return cols, rc
					}

					append(
						&cols,
						Column_Schema{
							name     = strings.clone(v2_str_to_string(fname), allocator),
							sql_type = sql_type_str,
							type_id  = tid,
							nullable = false,
						},
					)
				}
				return cols, .NONE
			}
		}
	}

	source_expr := table_or_source
	if is_identifier {
		source_expr = v2_quote_identifier(table_or_source, true, context.temp_allocator)
	}
	c_sql := fmt.ctprintf("SELECT * FROM %s LIMIT 0", source_expr)
	iter: V2_Statement_Iterator_Handle
	rc = duckdb_v2_parse_sql(conn, c_sql, &iter, err)
	if rc != .NONE {
		return cols, rc
	}
	defer duckdb_v2_statement_iterator_destroy(&iter)

	stmt: V2_Sql_Statement_Handle
	rc = duckdb_v2_statement_iterator_next(iter, &stmt, err)
	if rc != .NONE || stmt == nil {
		return cols, rc
	}
	defer duckdb_v2_sql_statement_destroy(&stmt)

	schema: V2_Schema_Handle
	rc = duckdb_v2_statement_bind(conn, stmt, &schema, nil, err)
	if rc != .NONE {
		return cols, rc
	}
	defer duckdb_v2_schema_destroy(&schema)

	count: V2_Idx
	rc = duckdb_v2_schema_get_count(schema, &count, err)
	if rc != .NONE {
		return cols, rc
	}

	cols = make([dynamic]Column_Schema, 0, int(count), allocator)
	for i: V2_Idx = 0; i < count; i += 1 {
		fname: V2_Identifier
		ftype: V2_Logical_Type_Handle // Borrowed from `schema` (`duckdb_v2.h` line 4720); do NOT destroy.
		rc = duckdb_v2_schema_get_field(schema, i, &fname, &ftype, err)
		if rc != .NONE {
			return cols, rc
		}

		tid: V2_Logical_Type_Id
		rc = duckdb_v2_logical_type_get_id(ftype, &tid, err)
		if rc != .NONE {
			return cols, rc
		}

		sql_type_str: string
		sql_type_str, rc = logical_type_to_sql_name(ftype, tid, allocator, err)
		if rc != .NONE {
			return cols, rc
		}

		append(
			&cols,
			Column_Schema{
				name     = strings.clone(v2_str_to_string(fname), allocator),
				sql_type = sql_type_str,
				type_id  = tid,
				nullable = false,
			},
		)
	}

	return cols, .NONE
}

// Maps a `V2_Logical_Type_Id` to its idiomatic Odin type name for struct generation.
duckdb_type_id_to_odin_type :: proc(type_id: V2_Logical_Type_Id) -> string {
	#partial switch type_id {
	case .BOOLEAN:
		return "bool"
	case .TINYINT:
		return "i8"
	case .SMALLINT:
		return "i16"
	case .INTEGER:
		return "i32"
	case .BIGINT:
		return "i64"
	case .UTINYINT:
		return "u8"
	case .USMALLINT:
		return "u16"
	case .UINTEGER:
		return "u32"
	case .UBIGINT:
		return "u64"
	case .FLOAT:
		return "f32"
	case .DOUBLE:
		return "f64"
	case .VARCHAR:
		return "string"
	case .BLOB:
		return "[]u8"
	case .DATE:
		return "i32"
	case .TIME, .TIME_NS, .TIMESTAMP, .TIMESTAMP_SEC, .TIMESTAMP_MS, .TIMESTAMP_NS, .TIMESTAMP_TZ, .TIMESTAMP_TZ_NS:
		return "i64"
	case .TIME_TZ:
		return "u64"
	case .HUGEINT, .UUID:
		return "duckdb.V2_Hugeint"
	case .UHUGEINT:
		return "duckdb.V2_Uhugeint"
	case .INTERVAL:
		return "duckdb.V2_Interval"
	}
	return "string"
}

// Maps a `V2_Logical_Type_Id` to its CUE schema type constraint.
duckdb_type_id_to_cue_type :: proc(type_id: V2_Logical_Type_Id) -> string {
	#partial switch type_id {
	case .BOOLEAN:
		return "bool"
	case .TINYINT:
		return "int8"
	case .SMALLINT:
		return "int16"
	case .INTEGER:
		return "int32"
	case .BIGINT:
		return "int64"
	case .UTINYINT:
		return "uint8"
	case .USMALLINT:
		return "uint16"
	case .UINTEGER:
		return "uint32"
	case .UBIGINT:
		return "uint64"
	case .FLOAT:
		return "float32"
	case .DOUBLE, .DECIMAL:
		return "number"
	case .VARCHAR, .DATE, .TIME, .TIME_NS, .TIME_TZ, .TIMESTAMP, .TIMESTAMP_SEC, .TIMESTAMP_MS, .TIMESTAMP_NS, .TIMESTAMP_TZ, .TIMESTAMP_TZ_NS, .UUID, .INTERVAL:
		return "string"
	case .BLOB:
		return "bytes"
	case .HUGEINT, .UHUGEINT:
		return "int"
	}
	return "_"
}

@(private = "file")
is_odin_reserved_word :: proc(ident: string) -> bool {
	switch ident {
	case "asm", "auto_cast", "bit_field", "bit_set", "break", "case", "cast", "context",
	     "continue", "defer", "distinct", "do", "dynamic", "else", "enum", "fallthrough",
	     "for", "foreign", "if", "import", "in", "map", "matrix", "not_in", "or_break",
	     "or_continue", "or_else", "or_return", "package", "proc", "return", "struct",
	     "switch", "transmute", "typeid", "union", "using", "when", "where",
	     "any", "bool", "byte", "cstring", "f16", "f32", "f64", "i8", "i16", "i32", "i64",
	     "i128", "int", "rawptr", "rune", "string", "u8", "u16", "u32", "u64", "u128",
	     "uint", "uintptr":
		return true
	}
	return false
}

@(private = "file")
is_clean_snake_identifier :: #force_inline proc "contextless" (s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	c0 := s[0]
	if !((c0 >= 'a' && c0 <= 'z') || c0 == '_') || s[len(s) - 1] == '_' {
		return false
	}
	for i := 1; i < len(s); i += 1 {
		ch := s[i]
		if !((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '_') {
			return false
		}
	}
	return true
}

// Sanitizes a raw SQL column name into a valid snake_case Odin struct field identifier.
sanitize_odin_identifier :: proc(raw_name: string, idx := 0, allocator := context.temp_allocator) -> string {
	if is_clean_snake_identifier(raw_name) && !is_odin_reserved_word(raw_name) {
		return raw_name
	}
	b := strings.builder_make(0, len(raw_name) + 8, allocator)
	prev_underscore := false
	for i := 0; i < len(raw_name); i += 1 {
		ch := raw_name[i]
		is_upper := ch >= 'A' && ch <= 'Z'
		is_lower := ch >= 'a' && ch <= 'z'
		is_digit := ch >= '0' && ch <= '9'
		if is_upper {
			strings.write_byte(&b, ch + ('a' - 'A'))
			prev_underscore = false
		} else if is_lower || is_digit {
			strings.write_byte(&b, ch)
			prev_underscore = false
		} else if !prev_underscore && strings.builder_len(b) > 0 {
			strings.write_byte(&b, '_')
			prev_underscore = true
		}
	}
	s := strings.trim(strings.to_string(b), "_")
	if len(s) == 0 {
		return fmt.aprintf("col_%d", idx, allocator = allocator)
	}
	if s[0] >= '0' && s[0] <= '9' {
		s = fmt.aprintf("col_%s", s, allocator = allocator)
	}
	if is_odin_reserved_word(s) {
		s = fmt.aprintf("%s_", s, allocator = allocator)
	}
	return s
}

// Generates an idiomatic Odin `struct` definition with `duckdb:"..."` struct tags from `columns`.
generate_odin_struct_code :: proc(
	package_name: string,
	struct_name: string,
	columns: []Column_Schema,
	allocator := context.temp_allocator,
) -> string {
	b := strings.builder_make(0, len(columns) * 48 + 64, allocator)
	if len(package_name) > 0 {
		strings.write_string(&b, "package ")
		strings.write_string(&b, package_name)
		strings.write_string(&b, "\n\n")
	}
	strings.write_string(&b, struct_name)
	strings.write_string(&b, " :: struct {\n")
	for col, idx in columns {
		field_ident := sanitize_odin_identifier(col.name, idx, allocator)
		odin_t := duckdb_type_id_to_odin_type(col.type_id)
		strings.write_byte(&b, '\t')
		strings.write_string(&b, field_ident)
		strings.write_string(&b, ": ")
		if col.nullable {
			strings.write_string(&b, "Maybe(")
			strings.write_string(&b, odin_t)
			strings.write_byte(&b, ')')
		} else {
			strings.write_string(&b, odin_t)
		}
		strings.write_string(&b, " `duckdb:\"")
		if strings.index_byte(col.name, '\\') < 0 && strings.index_byte(col.name, '"') < 0 {
			strings.write_string(&b, col.name)
		} else {
			escaped_tag, _ := strings.replace_all(col.name, `\`, `\\`, allocator)
			escaped_tag, _ = strings.replace_all(escaped_tag, `"`, `\"`, allocator)
			strings.write_string(&b, escaped_tag)
		}
		strings.write_string(&b, "\"`,\n")
	}
	strings.write_string(&b, "}\n")
	return strings.to_string(b)
}

// Generates a CUE schema definition (`#Definition: { ... }`) from `columns`.
generate_cue_schema_code :: proc(
	package_name: string,
	definition_name: string,
	columns: []Column_Schema,
	allocator := context.temp_allocator,
) -> string {
	b := strings.builder_make(0, len(columns) * 32 + 64, allocator)
	if len(package_name) > 0 {
		strings.write_string(&b, "package ")
		strings.write_string(&b, package_name)
		strings.write_string(&b, "\n\n")
	}
	def_ident := strings.trim_prefix(definition_name, "#")
	strings.write_byte(&b, '#')
	strings.write_string(&b, def_ident)
	strings.write_string(&b, ": {\n")
	for col, idx in columns {
		field_ident := sanitize_odin_identifier(col.name, idx, allocator)
		cue_t := duckdb_type_id_to_cue_type(col.type_id)
		strings.write_byte(&b, '\t')
		strings.write_string(&b, field_ident)
		if col.nullable {
			strings.write_string(&b, "?: ")
			strings.write_string(&b, cue_t)
			strings.write_string(&b, " | null\n")
		} else {
			strings.write_string(&b, ": ")
			strings.write_string(&b, cue_t)
			strings.write_byte(&b, '\n')
		}
	}
	strings.write_string(&b, "}\n")
	return strings.to_string(b)
}
