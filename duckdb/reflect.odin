package duckdb

// ============================================================================
// Layer 1: `core:reflect` Struct Tag Mapping & Bulk Appender (`duckdb/reflect.odin`)
// ============================================================================
// Upstream & Architectural References:
// - `references/zig/zuckdb.zig` (`src/zuckdb.zig`, `src/appender.zig`, `src/row.zig`)
// - `references/c/duckdb-capi-2.0/test/api/capi/v2/test_capi_v2_collection.cpp`
//   (C API v2 `ColumnDataCollection` + `duckdb_v2_statement_add_collection` bulk insert)
//
// Supported struct field tags (`duckdb:"..."`):
// - `duckdb:"col_name"`         -> maps field to SQL column `col_name`
// - `duckdb:"col_name,pk"`      -> adds `PRIMARY KEY`
// - `duckdb:"col_name,not_null"`-> adds `NOT NULL`
// - `duckdb:"col_name,unique"`  -> adds `UNIQUE`
// - `duckdb:"col_name,default=..."` -> adds `DEFAULT ...`
// - `duckdb:"-"`                -> ignores field in DDL, Appender, and Row Unmarshalling
// ============================================================================

import "base:intrinsics"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:strings"

Struct_Field_Mapping :: struct {
	field_name:  string,
	column_name: string,
	sql_type:    string,
	type_id:     V2_Logical_Type_Id,
	offset:      uintptr,
	type:        ^reflect.Type_Info,
	is_maybe:    bool,
	inner_type:  ^reflect.Type_Info,
	is_json:     bool,
	is_pk:       bool,
	not_null:    bool,
	is_unique:   bool,
	default_val: string,
	ignored:     bool,
}

// Unwraps `Maybe(T)` (`union #maybe {T}`) if present and returns `(inner_type, is_maybe)`.
unwrap_maybe_type :: proc(ti: ^reflect.Type_Info) -> (^reflect.Type_Info, bool) {
	base := reflect.type_info_base(ti)
	if u, is_u := base.variant.(reflect.Type_Info_Union); is_u && len(u.variants) == 1 && !u.no_nil {
		return u.variants[0], true
	}
	return ti, false
}

// Maps an Odin `reflect.Type_Info` to its canonical DuckDB 2.0 SQL type name and `V2_Logical_Type_Id`.
odin_type_to_duckdb_sql :: proc(ti: ^reflect.Type_Info) -> (sql_type: string, type_id: V2_Logical_Type_Id, ok: bool) {
	unwrapped, _ := unwrap_maybe_type(ti)
	switch unwrapped.id {
	case V2_Hugeint:
		return "HUGEINT", .HUGEINT, true
	case V2_Uhugeint:
		return "UHUGEINT", .UHUGEINT, true
	case V2_Interval:
		return "INTERVAL", .INTERVAL, true
	}
	base := reflect.type_info_base(unwrapped)
	#partial switch v in base.variant {
	case reflect.Type_Info_Boolean:
		return "BOOLEAN", .BOOLEAN, true
	case reflect.Type_Info_Integer:
		if v.signed {
			switch base.size {
			case 1:
				return "TINYINT", .TINYINT, true
			case 2:
				return "SMALLINT", .SMALLINT, true
			case 4:
				return "INTEGER", .INTEGER, true
			case 8:
				return "BIGINT", .BIGINT, true
			}
		} else {
			switch base.size {
			case 1:
				return "UTINYINT", .UTINYINT, true
			case 2:
				return "USMALLINT", .USMALLINT, true
			case 4:
				return "UINTEGER", .UINTEGER, true
			case 8:
				return "UBIGINT", .UBIGINT, true
			}
		}
	case reflect.Type_Info_Float:
		switch base.size {
		case 4:
			return "FLOAT", .FLOAT, true
		case 8:
			return "DOUBLE", .DOUBLE, true
		}
	case reflect.Type_Info_String:
		return "VARCHAR", .VARCHAR, true
	case reflect.Type_Info_Slice:
		elem_base := reflect.type_info_base(v.elem)
		if int_info, is_int := elem_base.variant.(reflect.Type_Info_Integer); is_int && !int_info.signed && elem_base.size == 1 {
			return "BLOB", .BLOB, true
		}
	}
	return "", .INVALID, false
}

// Inspects an Odin `struct` type via `core:reflect` and extracts its `duckdb:"..."` column mappings.
reflect_struct_mappings :: proc($T: typeid, allocator := context.temp_allocator) -> [dynamic]Struct_Field_Mapping
	where intrinsics.type_is_struct(T) {
	mappings := make([dynamic]Struct_Field_Mapping, allocator)
	fields := reflect.struct_fields_zipped(T)

	for f in fields {
		m := Struct_Field_Mapping{
			field_name  = f.name,
			column_name = f.name,
			offset      = f.offset,
			type        = f.type,
		}
		m.inner_type, m.is_maybe = unwrap_maybe_type(f.type)

		if tag_val, has_tag := reflect.struct_tag_lookup(f.tag, "duckdb"); has_tag {
			if tag_val == "-" {
				m.ignored = true
				append(&mappings, m)
				continue
			}
			parts := strings.split(string(tag_val), ",", allocator)
			for p, idx in parts {
				trimmed := strings.trim_space(p)
				if idx == 0 && len(trimmed) > 0 {
					m.column_name = trimmed
					continue
				}
				if trimmed == "pk" || trimmed == "primary_key" {
					m.is_pk = true
				} else if trimmed == "not_null" {
					m.not_null = true
				} else if trimmed == "unique" {
					m.is_unique = true
				} else if trimmed == "json" {
					m.is_json = true
				} else if strings.has_prefix(trimmed, "default=") {
					m.default_val = trimmed[len("default="):]
				}
			}
		}

		if m.is_json {
			m.sql_type = "JSON"
			m.type_id = .VARCHAR
		} else {
			sql_t, tid, ok := odin_type_to_duckdb_sql(f.type)
			if !ok {
				m.ignored = true
			} else {
				m.sql_type = sql_t
				m.type_id = tid
			}
		}
		append(&mappings, m)
	}
	return mappings
}

@(private = "file")
assign_json_value_to_any :: proc(jv: json.Value, dst: any, allocator := context.allocator) -> bool {
	if dst == nil || dst.data == nil {
		return false
	}
	if _, is_null := jv.(json.Null); is_null {
		return true
	}
	ti := reflect.type_info_base(type_info_of(dst.id))
	#partial switch v in ti.variant {
	case reflect.Type_Info_Boolean:
		if b, ok := jv.(json.Boolean); ok {
			(cast(^bool)dst.data)^ = bool(b)
			return true
		}
	case reflect.Type_Info_Integer:
		val_i64: i64
		if i, ok := jv.(json.Integer); ok {
			val_i64 = i64(i)
		} else if f, ok_f := jv.(json.Float); ok_f {
			val_i64 = i64(f)
		} else {
			return false
		}
		if v.signed {
			switch ti.size {
			case 1:
				(cast(^i8)dst.data)^ = i8(val_i64)
			case 2:
				(cast(^i16)dst.data)^ = i16(val_i64)
			case 4:
				(cast(^i32)dst.data)^ = i32(val_i64)
			case 8:
				(cast(^i64)dst.data)^ = val_i64
			}
		} else {
			switch ti.size {
			case 1:
				(cast(^u8)dst.data)^ = u8(val_i64)
			case 2:
				(cast(^u16)dst.data)^ = u16(val_i64)
			case 4:
				(cast(^u32)dst.data)^ = u32(val_i64)
			case 8:
				(cast(^u64)dst.data)^ = u64(val_i64)
			}
		}
		return true
	case reflect.Type_Info_Float:
		val_f64: f64
		if f, ok := jv.(json.Float); ok {
			val_f64 = f64(f)
		} else if i, ok_i := jv.(json.Integer); ok_i {
			val_f64 = f64(i)
		} else {
			return false
		}
		if ti.size == 4 {
			(cast(^f32)dst.data)^ = f32(val_f64)
		} else {
			(cast(^f64)dst.data)^ = val_f64
		}
		return true
	case reflect.Type_Info_String:
		if s, ok := jv.(json.String); ok {
			(cast(^string)dst.data)^ = strings.clone(string(s), allocator)
			return true
		}
	case reflect.Type_Info_Slice:
		arr, ok := jv.(json.Array)
		if !ok {
			return false
		}
		elem_size := v.elem.size
		raw_mem, alloc_err := mem.alloc_bytes(elem_size * len(arr), v.elem.align, allocator)
		if alloc_err != nil {
			return false
		}
		for item_jv, idx in arr {
			elem_ptr := rawptr(uintptr(raw_data(raw_mem)) + uintptr(idx * elem_size))
			if !assign_json_value_to_any(item_jv, any{elem_ptr, v.elem.id}, allocator) {
				return false
			}
		}
		raw_slice := cast(^mem.Raw_Slice)dst.data
		raw_slice.data = raw_data(raw_mem)
		raw_slice.len = len(arr)
		return true
	case reflect.Type_Info_Struct:
		obj, ok := jv.(json.Object)
		if !ok {
			return false
		}
		fields := reflect.struct_fields_zipped(dst.id)
		base_bytes := cast([^]u8)dst.data
		for sf in fields {
			json_key := sf.name
			if jtag, has_jtag := reflect.struct_tag_lookup(sf.tag, "json"); has_jtag && len(jtag) > 0 && jtag != "-" {
				json_key = strings.split(string(jtag), ",", context.temp_allocator)[0]
			}
			if field_jv, exists := obj[json_key]; exists {
				f_ptr := rawptr(&base_bytes[sf.offset])
				if !assign_json_value_to_any(field_jv, any{f_ptr, sf.type.id}, allocator) {
					return false
				}
			}
		}
		return true
	}
	return false
}

// Generates a `CREATE TABLE [IF NOT EXISTS] <table_name> (...)` DDL statement from an Odin struct `$T`.
// Identifiers are rendered through `v2_quote_identifier` (`duckdb_v2_identifier_render_quoted`) so bare
// identifiers pass through while SQL reserved words or spaces are double-quoted.
create_table_sql :: proc(
	$T: typeid,
	table_name: string,
	if_not_exists := true,
	allocator := context.temp_allocator,
) -> string where intrinsics.type_is_struct(T) {
	mappings := reflect_struct_mappings(T, allocator)
	b := strings.builder_make(allocator)
	quoted_table := v2_quote_identifier(table_name, true, allocator)

	if if_not_exists {
		fmt.sbprintf(&b, "CREATE TABLE IF NOT EXISTS %s (", quoted_table)
	} else {
		fmt.sbprintf(&b, "CREATE TABLE %s (", quoted_table)
	}

	col_idx := 0
	for m in mappings {
		if m.ignored {
			continue
		}
		if col_idx > 0 {
			strings.write_string(&b, ", ")
		}
		col_idx += 1

		fmt.sbprintf(&b, "%s %s", v2_quote_identifier(m.column_name, false, allocator), m.sql_type)
		if m.is_pk {
			strings.write_string(&b, " PRIMARY KEY")
		}
		if m.not_null {
			strings.write_string(&b, " NOT NULL")
		}
		if m.is_unique {
			strings.write_string(&b, " UNIQUE")
		}
		if len(m.default_val) > 0 {
			fmt.sbprintf(&b, " DEFAULT %s", m.default_val)
		}
	}
	strings.write_byte(&b, ')')
	return strings.to_string(b)
}

// Bulk-appends a slice of Odin structs `[]T` into `table_name` using DuckDB 2.0's C API v2
// `V2_Column_Data_Collection_Handle` + `duckdb_v2_statement_add_collection`.
append_slice :: proc(
	conn: V2_Connection_Handle,
	table_name: string,
	rows: []$T,
	err: ^V2_Error_Info_Handle = nil,
) -> V2_Error where intrinsics.type_is_struct(T) {
	if len(rows) == 0 {
		return .NONE
	}

	mappings := reflect_struct_mappings(T, context.temp_allocator)
	active_fields := make([dynamic]Struct_Field_Mapping, context.temp_allocator)
	for m in mappings {
		if !m.ignored {
			append(&active_fields, m)
		}
	}
	col_count := len(active_fields)
	if col_count == 0 {
		return .INPUT_INVALID
	}

	factory: V2_Factory_Handle
	if rc := duckdb_v2_connection_get_factory(conn, &factory, err); rc != .NONE {
		return rc
	}

	col_types := make([]V2_Logical_Type_Handle, col_count, context.temp_allocator)
	col_names := make([]V2_Identifier, col_count, context.temp_allocator)
	defer {
		for &ct in col_types {
			if ct != nil {
				duckdb_v2_logical_type_destroy(&ct)
			}
		}
	}

	for f, idx in active_fields {
		if rc := duckdb_v2_factory_create_type_from_id(factory, f.type_id, nil, nil, 0, &col_types[idx], err); rc != .NONE {
			return rc
		}
		col_names[idx] = V2_Identifier(v2_str_from_string(f.column_name))
	}

	collection: V2_Column_Data_Collection_Handle
	if rc := duckdb_v2_column_data_collection_create(
		factory,
		raw_data(col_types),
		V2_Idx(col_count),
		&collection,
		err,
	); rc != .NONE {
		return rc
	}
	defer duckdb_v2_column_data_collection_destroy(&collection)

	append_state: V2_Column_Data_Collection_Append_State_Handle
	if rc := duckdb_v2_column_data_collection_append_state_create(collection, &append_state, err); rc != .NONE {
		return rc
	}
	defer duckdb_v2_column_data_collection_append_state_destroy(&append_state)

	chunk: V2_Data_Chunk_Handle
	if rc := duckdb_v2_data_chunk_create(factory, raw_data(col_types), V2_Idx(col_count), &chunk, err); rc != .NONE {
		return rc
	}
	defer duckdb_v2_data_chunk_destroy(&chunk)

	chunk_cap: V2_Idx
	if rc := duckdb_v2_data_chunk_get_capacity(chunk, &chunk_cap, err); rc != .NONE {
		return rc
	}
	if chunk_cap == 0 {
		chunk_cap = 2048
	}

	batch_start := 0
	for batch_start < len(rows) {
		batch_len := len(rows) - batch_start
		if V2_Idx(batch_len) > chunk_cap {
			batch_len = int(chunk_cap)
		}
		if batch_start > 0 {
			if rc := duckdb_v2_data_chunk_clear(chunk, err); rc != .NONE {
				return rc
			}
		}

		for f, col_idx in active_fields {
			vec: V2_Vector_Handle
			if rc := duckdb_v2_data_chunk_get_vector(chunk, V2_Idx(col_idx), &vec, err); rc != .NONE {
				return rc
			}

			raw: rawptr
			if rc := duckdb_v2_vector_get_data_mutable(vec, &raw, err); rc != .NONE {
				return rc
			}

			if rc := duckdb_v2_vector_set_size(vec, V2_Idx(batch_len), err); rc != .NONE {
				return rc
			}

			for r_idx := 0; r_idx < batch_len; r_idx += 1 {
				row_ptr := cast([^]u8)&rows[batch_start + r_idx]
				field_ptr := cast(rawptr)&row_ptr[f.offset]
				val_ptr := field_ptr

				if f.is_maybe {
					sub_any := reflect.get_union_variant(any{field_ptr, f.type.id})
					if sub_any == nil {
						if rc := duckdb_v2_vector_set_null(vec, V2_Idx(r_idx), err); rc != .NONE {
							return rc
						}
						continue
					}
					val_ptr = sub_any.data
				}

				if f.is_json {
					json_bytes, m_err := json.marshal(any{val_ptr, f.inner_type.id}, allocator = context.temp_allocator)
					if m_err != nil {
						return .TYPE_CONVERSION
					}
					if rc := v2_vector_assign_bytes(vec, V2_Idx(r_idx), json_bytes, err); rc != .NONE {
						return rc
					}
					continue
				}

				#partial switch f.type_id {
				case .BOOLEAN:
					(cast([^]bool)raw)[r_idx] = (cast(^bool)val_ptr)^
				case .TINYINT:
					(cast([^]i8)raw)[r_idx] = (cast(^i8)val_ptr)^
				case .SMALLINT:
					(cast([^]i16)raw)[r_idx] = (cast(^i16)val_ptr)^
				case .INTEGER:
					(cast([^]i32)raw)[r_idx] = (cast(^i32)val_ptr)^
				case .BIGINT:
					(cast([^]i64)raw)[r_idx] = (cast(^i64)val_ptr)^
				case .UTINYINT:
					(cast([^]u8)raw)[r_idx] = (cast(^u8)val_ptr)^
				case .USMALLINT:
					(cast([^]u16)raw)[r_idx] = (cast(^u16)val_ptr)^
				case .UINTEGER:
					(cast([^]u32)raw)[r_idx] = (cast(^u32)val_ptr)^
				case .UBIGINT:
					(cast([^]u64)raw)[r_idx] = (cast(^u64)val_ptr)^
				case .FLOAT:
					(cast([^]f32)raw)[r_idx] = (cast(^f32)val_ptr)^
				case .DOUBLE:
					(cast([^]f64)raw)[r_idx] = (cast(^f64)val_ptr)^
				case .HUGEINT:
					(cast([^]V2_Hugeint)raw)[r_idx] = (cast(^V2_Hugeint)val_ptr)^
				case .UHUGEINT:
					(cast([^]V2_Uhugeint)raw)[r_idx] = (cast(^V2_Uhugeint)val_ptr)^
				case .INTERVAL:
					(cast([^]V2_Interval)raw)[r_idx] = (cast(^V2_Interval)val_ptr)^
				case .VARCHAR:
					s := (cast(^string)val_ptr)^
					if rc := v2_vector_assign_string(vec, V2_Idx(r_idx), s, err); rc != .NONE {
						return rc
					}
				case .BLOB:
					b := (cast(^[]u8)val_ptr)^
					if rc := v2_vector_assign_bytes(vec, V2_Idx(r_idx), b, err); rc != .NONE {
						return rc
					}
				}
			}
		}

		if rc := duckdb_v2_column_data_collection_append(collection, append_state, chunk, err); rc != .NONE {
			return rc
		}
		batch_start += batch_len
	}

	// Build `INSERT INTO <table> (<cols...>) SELECT * FROM __odin_append_src` with quoted identifiers:
	sql_b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sql_b, "INSERT INTO %s (", v2_quote_identifier(table_name, true, context.temp_allocator))
	for f, idx in active_fields {
		if idx > 0 {
			strings.write_string(&sql_b, ", ")
		}
		strings.write_string(&sql_b, v2_quote_identifier(f.column_name, false, context.temp_allocator))
	}
	strings.write_string(&sql_b, ") SELECT * FROM __odin_append_src")
	c_sql := strings.clone_to_cstring(strings.to_string(sql_b), context.temp_allocator)

	iter: V2_Statement_Iterator_Handle
	if rc := duckdb_v2_parse_sql(conn, c_sql, &iter, err); rc != .NONE {
		return rc
	}
	defer duckdb_v2_statement_iterator_destroy(&iter)

	stmt: V2_Sql_Statement_Handle
	if rc := duckdb_v2_statement_iterator_next(iter, &stmt, err); rc != .NONE {
		return rc
	}
	defer duckdb_v2_sql_statement_destroy(&stmt)

	src_ident := V2_Identifier(v2_str_from_string("__odin_append_src"))
	if rc := duckdb_v2_statement_add_collection(
		stmt,
		&src_ident,
		collection,
		raw_data(col_names),
		V2_Idx(col_count),
		err,
	); rc != .NONE {
		return rc
	}

	res: V2_Result_Handle
	if rc := duckdb_v2_statement_execute(conn, stmt, nil, nil, 0, &res, err); rc != .NONE {
		return rc
	}
	defer duckdb_v2_result_destroy(&res)

	rows_changed: V2_Idx
	return duckdb_v2_result_drain(res, &rows_changed, err)
}

// Executes `sql` via C API v2, matches result columns by name against struct `duckdb:"..."` tags
// (with positional fallback when unaliased), verifies runtime `V2_Logical_Type_Id` compatibility
// before dereferencing vector buffers, and unmarshals the returned rows into `[dynamic]T`.
// Supports variadic positional query parameters (`args: ..any`).
query_as :: proc(
	conn: V2_Connection_Handle,
	$T: typeid,
	sql: string,
	allocator := context.allocator,
	err: ^V2_Error_Info_Handle = nil,
	args: ..any,
) -> (out: [dynamic]T, rc: V2_Error) where intrinsics.type_is_struct(T) {
	out = make([dynamic]T, allocator)
	mappings := reflect_struct_mappings(T, context.temp_allocator)
	active_fields := make([dynamic]Struct_Field_Mapping, context.temp_allocator)
	for m in mappings {
		if !m.ignored {
			append(&active_fields, m)
		}
	}

	res: V2_Result_Handle
	rc = v2_query(conn, sql, &res, err, ..args)
	if rc != .NONE {
		return out, rc
	}
	defer duckdb_v2_result_destroy(&res)

	// Inspect the result schema to map result column index -> `active_fields` index by column name
	// and validate runtime `V2_Logical_Type_Id` before casting `view.data`.
	schema: V2_Schema_Handle
	rc = duckdb_v2_result_get_schema(res, &schema, err)
	if rc != .NONE {
		return out, rc
	}
	defer duckdb_v2_schema_destroy(&schema)

	schema_col_count: V2_Idx
	rc = duckdb_v2_schema_get_count(schema, &schema_col_count, err)
	if rc != .NONE {
		return out, rc
	}

	col_to_field := make([]int, int(schema_col_count), context.temp_allocator)
	for i := 0; i < int(schema_col_count); i += 1 {
		col_to_field[i] = -1
	}
	field_claimed := make([]bool, len(active_fields), context.temp_allocator)

	for col_idx: V2_Idx = 0; col_idx < schema_col_count; col_idx += 1 {
		col_name_ident: V2_Identifier
		col_type_handle: V2_Logical_Type_Handle // Borrowed from `schema` (`duckdb_v2.h` line 4720); do NOT destroy.
		rc = duckdb_v2_schema_get_field(schema, col_idx, &col_name_ident, &col_type_handle, err)
		if rc != .NONE {
			return out, rc
		}

		col_type_id: V2_Logical_Type_Id
		rc = duckdb_v2_logical_type_get_id(col_type_handle, &col_type_id, err)
		if rc != .NONE {
			return out, rc
		}

		col_name := v2_str_to_string(col_name_ident)
		matched_field_idx := -1
		for f, f_idx in active_fields {
			if strings.equal_fold(f.column_name, col_name) || strings.equal_fold(f.field_name, col_name) {
				matched_field_idx = f_idx
				break
			}
		}

		// Positional fallback when result column is unaliased (no name match) and the positional struct field is unclaimed:
		if matched_field_idx < 0 && int(col_idx) < len(active_fields) && !field_claimed[int(col_idx)] {
			matched_field_idx = int(col_idx)
		}

		if matched_field_idx >= 0 {
			f := active_fields[matched_field_idx]
			if col_type_id != f.type_id {
				if err != nil && err^ != nil {
					msg := v2_str_from_string(
						fmt.tprintf(
							"query_as column '%s' type mismatch: expected %v, got %v",
							col_name,
							f.type_id,
							col_type_id,
						),
					)
					_ = duckdb_v2_error_info_set_code(err^, .INPUT_INVALID)
					_ = duckdb_v2_error_info_set_text(err^, &msg)
				}
				return out, .INPUT_INVALID
			}
			col_to_field[int(col_idx)] = matched_field_idx
			field_claimed[matched_field_idx] = true
		}
	}

	for {
		chunk: V2_Data_Chunk_Handle
		rc = duckdb_v2_result_fetch_chunk(res, &chunk, err)
		if rc != .NONE {
			return out, rc
		}
		if chunk == nil {
			break
		}
		defer duckdb_v2_data_chunk_destroy(&chunk)

		row_count: V2_Idx
		rc = duckdb_v2_data_chunk_get_size(chunk, &row_count, err)
		if rc != .NONE {
			return out, rc
		}

		vec_count: V2_Idx
		rc = duckdb_v2_data_chunk_get_vector_count(chunk, &vec_count, err)
		if rc != .NONE {
			return out, rc
		}

		col_limit := int(schema_col_count)
		if int(vec_count) < col_limit {
			col_limit = int(vec_count)
		}

		views := make([]V2_Vector_View, col_limit, context.temp_allocator)
		for col_idx := 0; col_idx < col_limit; col_idx += 1 {
			if col_to_field[col_idx] < 0 {
				continue
			}
			vec: V2_Vector_Handle
			rc = duckdb_v2_data_chunk_get_vector(chunk, V2_Idx(col_idx), &vec, err)
			if rc != .NONE {
				return out, rc
			}
			rc = v2_vector_get_readable_view(vec, &views[col_idx], err)
			if rc != .NONE {
				return out, rc
			}
		}

		for r: V2_Idx = 0; r < row_count; r += 1 {
			item: T
			item_bytes := cast([^]u8)&item

			for col_idx := 0; col_idx < col_limit; col_idx += 1 {
				field_idx := col_to_field[col_idx]
				if field_idx < 0 {
					continue
				}
				f := active_fields[field_idx]
				view := views[col_idx]
				if !v2_row_is_valid(view, r) {
					continue
				}
				phys := v2_sel_at(view.sel, r)
				field_ptr := cast(rawptr)&item_bytes[f.offset]

				if f.is_json {
					b_ptr := &((cast([^]V2_Bytes)view.data)[phys])
					raw_json := v2_bytes_data(b_ptr)[:int(v2_bytes_length(b_ptr))]
					jv, p_err := json.parse(raw_json, allocator = context.temp_allocator)
					if p_err != .None {
						return out, .TYPE_CONVERSION
					}
					if !assign_json_value_to_any(jv, any{field_ptr, f.inner_type.id}, allocator) {
						return out, .TYPE_CONVERSION
					}
					if f.is_maybe {
						reflect.set_union_variant_typeid(any{field_ptr, f.type.id}, f.inner_type.id)
					}
					continue
				}

				#partial switch f.type_id {
				case .BOOLEAN:
					(cast(^bool)field_ptr)^ = (cast([^]bool)view.data)[phys]
				case .TINYINT:
					(cast(^i8)field_ptr)^ = (cast([^]i8)view.data)[phys]
				case .SMALLINT:
					(cast(^i16)field_ptr)^ = (cast([^]i16)view.data)[phys]
				case .INTEGER:
					(cast(^i32)field_ptr)^ = (cast([^]i32)view.data)[phys]
				case .BIGINT:
					(cast(^i64)field_ptr)^ = (cast([^]i64)view.data)[phys]
				case .UTINYINT:
					(cast(^u8)field_ptr)^ = (cast([^]u8)view.data)[phys]
				case .USMALLINT:
					(cast(^u16)field_ptr)^ = (cast([^]u16)view.data)[phys]
				case .UINTEGER:
					(cast(^u32)field_ptr)^ = (cast([^]u32)view.data)[phys]
				case .UBIGINT:
					(cast(^u64)field_ptr)^ = (cast([^]u64)view.data)[phys]
				case .FLOAT:
					(cast(^f32)field_ptr)^ = (cast([^]f32)view.data)[phys]
				case .DOUBLE:
					(cast(^f64)field_ptr)^ = (cast([^]f64)view.data)[phys]
				case .HUGEINT:
					(cast(^V2_Hugeint)field_ptr)^ = (cast([^]V2_Hugeint)view.data)[phys]
				case .UHUGEINT:
					(cast(^V2_Uhugeint)field_ptr)^ = (cast([^]V2_Uhugeint)view.data)[phys]
				case .INTERVAL:
					(cast(^V2_Interval)field_ptr)^ = (cast([^]V2_Interval)view.data)[phys]
				case .VARCHAR:
					b_ptr := &((cast([^]V2_Bytes)view.data)[phys])
					(cast(^string)field_ptr)^ = strings.clone(v2_bytes_to_string(b_ptr), allocator)
				case .BLOB:
					b_ptr := &((cast([^]V2_Bytes)view.data)[phys])
					n := int(v2_bytes_length(b_ptr))
					if n > 0 {
						buf := make([]u8, n, allocator)
						mem.copy(raw_data(buf), v2_bytes_data(b_ptr), n)
						(cast(^[]u8)field_ptr)^ = buf
					}
				}

				if f.is_maybe {
					reflect.set_union_variant_typeid(any{field_ptr, f.type.id}, f.inner_type.id)
				}
			}
			append(&out, item)
		}
	}

	return out, .NONE
}
