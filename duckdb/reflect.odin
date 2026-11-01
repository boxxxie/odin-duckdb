package duckdb

// ============================================================================
// Layer 1: `core:reflect` Struct Tag Mapping & Bulk Appender (`duckdb/reflect.odin`)
// ============================================================================
// Upstream & Architectural References:
// - `references/odin/odin-postgresql` & `references/odin/odin_sqlite_example`
// - `references/zig/zuckdb` (typed row unmarshaling & bulk appender)
// - `references/c/duckdb-capi-2.0/test/api/capi/v2/test_capi_v2_appender.cpp`
//   (`V2_Column_Data_Collection_Handle` + `duckdb_v2_statement_add_collection`)
// ============================================================================

import "base:intrinsics"
import "core:fmt"
import "core:reflect"
import "core:strings"

// Maps an Odin `Type_Info` to its corresponding DuckDB 2.0 SQL type name and `V2_Logical_Type_Id`.
odin_type_to_duckdb_sql :: proc(ti: ^reflect.Type_Info) -> (sql_type: string, type_id: V2_Logical_Type_Id, nullable: bool) {
	base := reflect.type_info_base(ti)
	#partial switch v in base.variant {
	case reflect.Type_Info_Boolean:
		return "BOOLEAN", .BOOLEAN, false
	case reflect.Type_Info_Integer:
		switch base.size {
		case 1:
			return ("TINYINT" if v.signed else "UTINYINT"), (.TINYINT if v.signed else .UTINYINT), false
		case 2:
			return ("SMALLINT" if v.signed else "USMALLINT"), (.SMALLINT if v.signed else .USMALLINT), false
		case 4:
			return ("INTEGER" if v.signed else "UINTEGER"), (.INTEGER if v.signed else .UINTEGER), false
		case 8:
			return ("BIGINT" if v.signed else "UBIGINT"), (.BIGINT if v.signed else .UBIGINT), false
		case 16:
			return ("HUGEINT" if v.signed else "UHUGEINT"), (.HUGEINT if v.signed else .UHUGEINT), false
		}
	case reflect.Type_Info_Float:
		if base.size == 4 {
			return "FLOAT", .FLOAT, false
		}
		return "DOUBLE", .DOUBLE, false
	case reflect.Type_Info_String:
		return "VARCHAR", .VARCHAR, false
	case reflect.Type_Info_Union:
		if len(v.variants) == 1 {
			inner_sql, inner_id, _ := odin_type_to_duckdb_sql(v.variants[0])
			return inner_sql, inner_id, true
		}
	}
	return "VARCHAR", .VARCHAR, false
}

// Parses a `duckdb:"col_name,pk,not_null,default=..."` struct tag.
Reflect_Field_Meta :: struct {
	col_name:    string,
	primary_key: bool,
	not_null:    bool,
	default_val: string,
	skip:        bool,
}

parse_duckdb_struct_tag :: proc(
	field_name: string,
	tag: reflect.Struct_Tag,
	allocator := context.temp_allocator,
) -> Reflect_Field_Meta {
	meta := Reflect_Field_Meta{col_name = field_name}
	val, ok := reflect.struct_tag_lookup(tag, "duckdb")
	if !ok || len(val) == 0 {
		return meta
	}
	parts := strings.split(val, ",", allocator)
	for p, idx in parts {
		token := strings.trim_space(p)
		if idx == 0 && len(token) > 0 {
			if token == "-" {
				meta.skip = true
				return meta
			}
			if !strings.contains(token, "=") && token != "pk" && token != "primary_key" && token != "not_null" {
				meta.col_name = token
				continue
			}
		}
		if token == "pk" || token == "primary_key" {
			meta.primary_key = true
		} else if token == "not_null" {
			meta.not_null = true
		} else if strings.has_prefix(token, "default=") {
			meta.default_val = token[len("default="):]
		}
	}
	return meta
}

// Generates a `CREATE TABLE [IF NOT EXISTS] <table_name> (...)` DDL statement from Odin struct `T`
// using `core:reflect` and `duckdb:"..."` struct tags.
create_table_sql :: proc(
	$T: typeid,
	table_name: string,
	if_not_exists := true,
	allocator := context.temp_allocator,
) -> string where intrinsics.type_is_struct(T) {
	b := strings.builder_make(allocator)
	if if_not_exists {
		fmt.sbprintf(&b, "CREATE TABLE IF NOT EXISTS %s (", table_name)
	} else {
		fmt.sbprintf(&b, "CREATE TABLE %s (", table_name)
	}

	fields := reflect.struct_fields_zipped(T)
	emitted := 0
	for f in fields {
		meta := parse_duckdb_struct_tag(f.name, f.tag, allocator)
		if meta.skip {
			continue
		}
		if emitted > 0 {
			strings.write_string(&b, ", ")
		}
		emitted += 1

		sql_type, _, is_maybe := odin_type_to_duckdb_sql(f.type)
		fmt.sbprintf(&b, "%s %s", meta.col_name, sql_type)
		if meta.primary_key {
			strings.write_string(&b, " PRIMARY KEY")
		} else if meta.not_null && !is_maybe {
			strings.write_string(&b, " NOT NULL")
		}
		if len(meta.default_val) > 0 {
			fmt.sbprintf(&b, " DEFAULT %s", meta.default_val)
		}
	}
	strings.write_byte(&b, ')')
	return strings.to_string(b)
}

// Appends a slice `rows: []T` of Odin structs into `table_name` using C API v2's zero-copy
// `V2_Column_Data_Collection_Handle` + `duckdb_v2_statement_add_collection` bulk appender pattern.
append_slice :: proc(
	conn: V2_Connection_Handle,
	table_name: string,
	rows: []$T,
	err: ^V2_Error_Info_Handle = nil,
) -> V2_Error where intrinsics.type_is_struct(T) {
	if len(rows) == 0 {
		return .NONE
	}

	factory: V2_Factory_Handle
	rc := duckdb_v2_connection_get_factory(conn, &factory, err)
	if rc != .NONE {
		return rc
	}

	fields := reflect.struct_fields_zipped(T)
	col_types := make([dynamic]V2_Logical_Type_Handle, context.temp_allocator)
	col_names := make([dynamic]V2_Identifier, context.temp_allocator)
	active_fields := make([dynamic]reflect.Struct_Field, context.temp_allocator)
	defer {
		for &lt in col_types {
			duckdb_v2_logical_type_destroy(&lt)
		}
	}

	for f in fields {
		meta := parse_duckdb_struct_tag(f.name, f.tag, context.temp_allocator)
		if meta.skip {
			continue
		}
		_, tid, _ := odin_type_to_duckdb_sql(f.type)
		lt: V2_Logical_Type_Handle
		rc = duckdb_v2_factory_create_type_from_id(factory, tid, nil, nil, 0, &lt, err)
		if rc != .NONE {
			return rc
		}
		append(&col_types, lt)
		append(&col_names, v2_str_from_string(meta.col_name))
		append(&active_fields, f)
	}

	ncols := V2_Idx(len(active_fields))
	nrows := V2_Idx(len(rows))

	chunk: V2_Data_Chunk_Handle
	rc = duckdb_v2_data_chunk_create(factory, raw_data(col_types), ncols, &chunk, err)
	if rc != .NONE {
		return rc
	}
	defer duckdb_v2_data_chunk_destroy(&chunk)

	for f, c_idx in active_fields {
		vec: V2_Vector_Handle
		rc = duckdb_v2_data_chunk_get_vector(chunk, V2_Idx(c_idx), &vec, err)
		if rc != .NONE {
			return rc
		}
		rc = duckdb_v2_vector_set_size(vec, nrows, err)
		if rc != .NONE {
			return rc
		}

		_, tid, _ := odin_type_to_duckdb_sql(f.type)
		raw: rawptr
		if tid != .VARCHAR {
			rc = duckdb_v2_vector_get_data_mutable(vec, &raw, err)
			if rc != .NONE {
				return rc
			}
		}

		for r_idx in 0 ..< len(rows) {
			row_base := uintptr(&rows[r_idx])
			field_ptr := rawptr(row_base + f.offset)
			#partial switch tid {
			case .BOOLEAN:
				(cast([^]bool)raw)[r_idx] = (cast(^bool)field_ptr)^
			case .INTEGER:
				(cast([^]i32)raw)[r_idx] = (cast(^i32)field_ptr)^
			case .BIGINT:
				(cast([^]i64)raw)[r_idx] = (cast(^i64)field_ptr)^
			case .DOUBLE:
				(cast([^]f64)raw)[r_idx] = (cast(^f64)field_ptr)^
			case .VARCHAR:
				str_val := (cast(^string)field_ptr)^
				rc = v2_vector_assign_string(vec, V2_Idx(r_idx), str_val, err)
				if rc != .NONE {
					return rc
				}
			}
		}
	}

	collection: V2_Column_Data_Collection_Handle
	rc = duckdb_v2_column_data_collection_create(factory, raw_data(col_types), ncols, &collection, err)
	if rc != .NONE {
		return rc
	}
	defer duckdb_v2_column_data_collection_destroy(&collection)

	append_state: V2_Column_Data_Collection_Append_State_Handle
	rc = duckdb_v2_column_data_collection_append_state_create(collection, &append_state, err)
	if rc != .NONE {
		return rc
	}
	defer duckdb_v2_column_data_collection_append_state_destroy(&append_state)

	rc = duckdb_v2_column_data_collection_append(collection, append_state, chunk, err)
	if rc != .NONE {
		return rc
	}

	insert_sql := fmt.ctprintf("INSERT INTO %s SELECT * FROM __odin_append_src", table_name)
	iter: V2_Statement_Iterator_Handle
	rc = duckdb_v2_parse_sql(conn, insert_sql, &iter, err)
	if rc != .NONE {
		return rc
	}
	defer duckdb_v2_statement_iterator_destroy(&iter)

	stmt: V2_Sql_Statement_Handle
	rc = duckdb_v2_statement_iterator_next(iter, &stmt, err)
	if rc != .NONE || stmt == nil {
		return rc
	}
	defer duckdb_v2_sql_statement_destroy(&stmt)

	src_id := v2_str_from_string("__odin_append_src")
	rc = duckdb_v2_statement_add_collection(stmt, &src_id, collection, raw_data(col_names), ncols, err)
	if rc != .NONE {
		return rc
	}

	res: V2_Result_Handle
	rc = duckdb_v2_statement_execute(conn, stmt, nil, nil, 0, &res, err)
	if rc != .NONE {
		return rc
	}
	defer duckdb_v2_result_destroy(&res)

	rows_changed: V2_Idx
	return duckdb_v2_result_drain(res, &rows_changed, err)
}

// Executes `sql` on `conn` via C API v2 and unmarshals each result row into `[]T` using `core:reflect`.
query_as :: proc(
	conn: V2_Connection_Handle,
	$T: typeid,
	sql: string,
	allocator := context.allocator,
	err: ^V2_Error_Info_Handle = nil,
) -> (out: [dynamic]T, rc: V2_Error) where intrinsics.type_is_struct(T) {
	out = make([dynamic]T, allocator)

	c_sql := strings.clone_to_cstring(sql, context.temp_allocator)
	iter: V2_Statement_Iterator_Handle
	rc = duckdb_v2_parse_sql(conn, c_sql, &iter, err)
	if rc != .NONE {
		return out, rc
	}
	defer duckdb_v2_statement_iterator_destroy(&iter)

	stmt: V2_Sql_Statement_Handle
	rc = duckdb_v2_statement_iterator_next(iter, &stmt, err)
	if rc != .NONE || stmt == nil {
		return out, rc
	}
	defer duckdb_v2_sql_statement_destroy(&stmt)

	res: V2_Result_Handle
	rc = duckdb_v2_statement_execute(conn, stmt, nil, nil, 0, &res, err)
	if rc != .NONE {
		return out, rc
	}
	defer duckdb_v2_result_destroy(&res)

	fields := reflect.struct_fields_zipped(T)
	active_fields := make([dynamic]reflect.Struct_Field, context.temp_allocator)
	for f in fields {
		meta := parse_duckdb_struct_tag(f.name, f.tag, context.temp_allocator)
		if !meta.skip {
			append(&active_fields, f)
		}
	}

	for {
		chunk: V2_Data_Chunk_Handle
		status: V2_Result_Step_Status
		rc = duckdb_v2_result_step(res, &chunk, &status, err)
		if rc != .NONE {
			return out, rc
		}
		if status == .FINISHED || status == .CANCELLED {
			break
		}
		if status == .WAITING {
			rc = duckdb_v2_result_wait(res, err)
			if rc != .NONE {
				return out, rc
			}
			continue
		}
		if chunk != nil {
			defer duckdb_v2_data_chunk_destroy(&chunk)
			row_count: V2_Idx
			_ = duckdb_v2_data_chunk_get_size(chunk, &row_count, nil)
			vec_count: V2_Idx
			_ = duckdb_v2_data_chunk_get_vector_count(chunk, &vec_count, nil)

			ncols := min(int(vec_count), len(active_fields))
			views := make([]V2_Vector_View, ncols, context.temp_allocator)
			tids := make([]V2_Logical_Type_Id, ncols, context.temp_allocator)

			for c in 0 ..< ncols {
				vec: V2_Vector_Handle
				_ = duckdb_v2_data_chunk_get_vector(chunk, V2_Idx(c), &vec, nil)
				vtype: V2_Vector_Type
				_ = duckdb_v2_vector_get_vector_type(vec, &vtype, nil)
				if vtype == .OTHER {
					_ = duckdb_v2_vector_flatten(vec, nil)
				}
				_ = duckdb_v2_vector_get_view(vec, &views[c], nil)
				_, tids[c], _ = odin_type_to_duckdb_sql(active_fields[c].type)
			}

			for r: V2_Idx = 0; r < row_count; r += 1 {
				item: T
				item_base := uintptr(&item)
				for c in 0 ..< ncols {
					view := views[c]
					if !v2_row_is_valid(view, r) {
						continue
					}
					phys := v2_sel_at(view.sel, r)
					f := active_fields[c]
					field_ptr := rawptr(item_base + f.offset)
					#partial switch tids[c] {
					case .BOOLEAN:
						(cast(^bool)field_ptr)^ = (cast([^]bool)view.data)[phys]
					case .INTEGER:
						(cast(^i32)field_ptr)^ = (cast([^]i32)view.data)[phys]
					case .BIGINT:
						(cast(^i64)field_ptr)^ = (cast([^]i64)view.data)[phys]
					case .DOUBLE:
						(cast(^f64)field_ptr)^ = (cast([^]f64)view.data)[phys]
					case .VARCHAR:
						slots := cast([^]V2_Bytes)view.data
						(cast(^string)field_ptr)^ = strings.clone(v2_bytes_to_string(&slots[phys]), allocator)
					}
				}
				append(&out, item)
			}
		}
	}

	return out, .NONE
}
