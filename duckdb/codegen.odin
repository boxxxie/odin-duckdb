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

// Introspects any table, view, or query source (`table_or_source`) using C API v2's
// `duckdb_v2_statement_bind` + `V2_Schema_Handle` without executing the query.
introspect_table_schema :: proc(
	conn: V2_Connection_Handle,
	table_or_source: string,
	allocator := context.allocator,
	err: ^V2_Error_Info_Handle = nil,
) -> (cols: [dynamic]Column_Schema, rc: V2_Error) {
	cols = make([dynamic]Column_Schema, allocator)

	c_sql := fmt.ctprintf("SELECT * FROM %s LIMIT 0", table_or_source)
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

	for i: V2_Idx = 0; i < count; i += 1 {
		fname: V2_Identifier
		ftype: V2_Logical_Type_Handle
		rc = duckdb_v2_schema_get_field(schema, i, &fname, &ftype, err)
		if rc != .NONE {
			return cols, rc
		}
		defer duckdb_v2_logical_type_destroy(&ftype)

		tid: V2_Logical_Type_Id
		_ = duckdb_v2_logical_type_get_id(ftype, &tid, nil)

		t_len: V2_Idx
		_ = duckdb_v2_logical_type_to_text(ftype, nil, 0, &t_len, nil)
		t_buf := make([]u8, int(t_len), context.temp_allocator)
		if t_len > 0 {
			_ = duckdb_v2_logical_type_to_text(ftype, raw_data(t_buf), t_len, &t_len, nil)
		}

		append(
			&cols,
			Column_Schema{
				name     = strings.clone(v2_str_to_string(fname), allocator),
				sql_type = strings.clone(string(t_buf[:int(t_len)]), allocator),
				type_id  = tid,
				nullable = true,
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
	case .VARCHAR, .BLOB:
		return "string"
	case .HUGEINT, .UUID:
		return "duckdb.V2_Hugeint"
	case .UHUGEINT:
		return "duckdb.V2_Uhugeint"
	case .INTERVAL:
		return "duckdb.V2_Interval"
	}
	return "string"
}

// Generates an idiomatic Odin `struct` definition with `duckdb:"..."` struct tags from `columns`.
generate_odin_struct_code :: proc(
	package_name: string,
	struct_name: string,
	columns: []Column_Schema,
	allocator := context.temp_allocator,
) -> string {
	b := strings.builder_make(allocator)
	if len(package_name) > 0 {
		fmt.sbprintf(&b, "package %s\n\n", package_name)
	}
	fmt.sbprintf(&b, "%s :: struct {{\n", struct_name)
	for col in columns {
		odin_t := duckdb_type_id_to_odin_type(col.type_id)
		fmt.sbprintf(&b, "\t%s: %s `duckdb:\"%s\"`,\n", col.name, odin_t, col.name)
	}
	strings.write_string(&b, "}\n")
	return strings.to_string(b)
}
