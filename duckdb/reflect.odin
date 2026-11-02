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
import "core:strconv"
import "core:strings"

Struct_Field_Mapping :: struct {
	field_name:       string,
	column_name:      string,
	sql_type:         string,
	type_id:          V2_Logical_Type_Id,
	offset:           uintptr,
	type:             ^reflect.Type_Info,
	is_maybe:         bool,
	maybe_tag_offset: uintptr,
	maybe_tag_size:   int,
	inner_type:       ^reflect.Type_Info,
	is_json:          bool,
	is_pk:            bool,
	not_null:         bool,
	is_unique:        bool,
	default_val:      string,
	ignored:          bool,
}

// Unwraps `Maybe(T)` (`union #maybe {T}`) if present and returns `(inner_type, is_maybe, tag_offset, tag_size)`.
unwrap_maybe_type :: #force_inline proc(ti: ^reflect.Type_Info) -> (^reflect.Type_Info, bool, uintptr, int) {
	#partial switch v in ti.variant {
	case reflect.Type_Info_Union:
		if len(v.variants) == 1 && !v.no_nil {
			tag_size := v.tag_type.size if v.tag_type != nil else 0
			return v.variants[0], true, v.tag_offset, tag_size
		}
		return ti, false, 0, 0
	case reflect.Type_Info_Named:
		if u, is_u := v.base.variant.(reflect.Type_Info_Union); is_u && len(u.variants) == 1 && !u.no_nil {
			tag_size := u.tag_type.size if u.tag_type != nil else 0
			return u.variants[0], true, u.tag_offset, tag_size
		}
		return ti, false, 0, 0
	}
	return ti, false, 0, 0
}

@(private = "file")
maybe_field_is_present :: #force_inline proc(field_ptr: rawptr, f: Struct_Field_Mapping) -> bool {
	if f.maybe_tag_size == 1 {
		return (cast(^u8)(uintptr(field_ptr) + f.maybe_tag_offset))^ != 0
	}
	if f.maybe_tag_size == 0 {
		return (cast(^uintptr)field_ptr)^ != 0
	}
	tag_ptr := rawptr(uintptr(field_ptr) + f.maybe_tag_offset)
	switch f.maybe_tag_size {
	case 2:
		return (cast(^u16)tag_ptr)^ != 0
	case 4:
		return (cast(^u32)tag_ptr)^ != 0
	case 8:
		return (cast(^u64)tag_ptr)^ != 0
	}
	return reflect.get_union_variant(any{field_ptr, f.type.id}) != nil
}

@(private = "file")
maybe_field_mark_present :: #force_inline proc(field_ptr: rawptr, f: Struct_Field_Mapping) {
	if f.maybe_tag_size == 1 {
		(cast(^u8)(uintptr(field_ptr) + f.maybe_tag_offset))^ = 1
		return
	}
	if f.maybe_tag_size == 0 {
		return
	}
	tag_ptr := rawptr(uintptr(field_ptr) + f.maybe_tag_offset)
	switch f.maybe_tag_size {
	case 2:
		(cast(^u16)tag_ptr)^ = 1
	case 4:
		(cast(^u32)tag_ptr)^ = 1
	case 8:
		(cast(^u64)tag_ptr)^ = 1
	}
}

// Maps an unwrapped Odin `reflect.Type_Info` to its canonical DuckDB 2.0 SQL type name and `V2_Logical_Type_Id`.
@(private = "file")
unwrapped_type_to_duckdb_sql :: #force_inline proc(unwrapped: ^reflect.Type_Info) -> (sql_type: string, type_id: V2_Logical_Type_Id, ok: bool) {
	switch unwrapped.id {
	case i64:
		return "BIGINT", .BIGINT, true
	case f64:
		return "DOUBLE", .DOUBLE, true
	case string:
		return "VARCHAR", .VARCHAR, true
	case bool:
		return "BOOLEAN", .BOOLEAN, true
	case i32:
		return "INTEGER", .INTEGER, true
	case f32:
		return "FLOAT", .FLOAT, true
	case u64:
		return "UBIGINT", .UBIGINT, true
	case u32:
		return "UINTEGER", .UINTEGER, true
	case i16:
		return "SMALLINT", .SMALLINT, true
	case u16:
		return "USMALLINT", .USMALLINT, true
	case i8:
		return "TINYINT", .TINYINT, true
	case u8:
		return "UTINYINT", .UTINYINT, true
	case []u8:
		return "BLOB", .BLOB, true
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

// Maps an Odin `reflect.Type_Info` to its canonical DuckDB 2.0 SQL type name and `V2_Logical_Type_Id`.
odin_type_to_duckdb_sql :: proc(ti: ^reflect.Type_Info) -> (sql_type: string, type_id: V2_Logical_Type_Id, ok: bool) {
	unwrapped, _, _, _ := unwrap_maybe_type(ti)
	return unwrapped_type_to_duckdb_sql(unwrapped)
}

// Fast path for extracting the `duckdb:"..."` struct tag without scanning unrelated tags when `duckdb:"` is the prefix.
@(private = "file")
lookup_duckdb_tag :: #force_inline proc(tag: reflect.Struct_Tag) -> (val: string, ok: bool) {
	s := string(tag)
	if len(s) == 0 {
		return "", false
	}
	if strings.has_prefix(s, `duckdb:"`) {
		rem := s[len(`duckdb:"`):]
		end := strings.index_byte(rem, '"')
		if end >= 0 {
			return rem[:end], true
		}
	}
	v, found := reflect.struct_tag_lookup(tag, "duckdb")
	return string(v), found
}

// Parses a single `reflect.Struct_Field` into a `Struct_Field_Mapping` without any heap allocations.
@(private = "file")
parse_single_struct_field :: #force_inline proc(f: reflect.Struct_Field) -> Struct_Field_Mapping {
	m := Struct_Field_Mapping{
		field_name  = f.name,
		column_name = f.name,
		offset      = f.offset,
		type        = f.type,
	}

	if tag_val, has_tag := lookup_duckdb_tag(f.tag); has_tag {
		if tag_val == "-" {
			m.ignored = true
			return m
		}
		rem := tag_val
		idx := 0
		for len(rem) > 0 {
			comma := strings.index_byte(rem, ',')
			p: string
			if comma < 0 {
				p = rem
				rem = ""
			} else {
				p = rem[:comma]
				rem = rem[comma + 1:]
			}
			trimmed := strings.trim_space(p)
			if idx == 0 {
				idx += 1
				if len(trimmed) > 0 {
					m.column_name = trimmed
				}
				continue
			}
			idx += 1
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

	m.inner_type, m.is_maybe, m.maybe_tag_offset, m.maybe_tag_size = unwrap_maybe_type(f.type)

	if m.is_json {
		m.sql_type = "JSON"
		m.type_id = .VARCHAR
	} else {
		sql_t, tid, ok := unwrapped_type_to_duckdb_sql(m.inner_type)
		if !ok {
			m.ignored = true
		} else {
			m.sql_type = sql_t
			m.type_id = tid
		}
	}
	return m
}

// Inspects an Odin `struct` type via `core:reflect` and extracts its `duckdb:"..."` column mappings.
reflect_struct_mappings :: proc($T: typeid, allocator := context.temp_allocator) -> [dynamic]Struct_Field_Mapping
	where intrinsics.type_is_struct(T) {
	fields := reflect.struct_fields_zipped(T)
	mappings := make([dynamic]Struct_Field_Mapping, 0, len(fields), allocator)

	for f in fields {
		append(&mappings, parse_single_struct_field(f))
	}
	return mappings
}

@(private = "file")
lookup_json_tag :: #force_inline proc(tag: reflect.Struct_Tag, fallback: string) -> string {
	s := string(tag)
	if len(s) == 0 {
		return fallback
	}
	if strings.has_prefix(s, `json:"`) {
		rem := s[len(`json:"`):]
		end := strings.index_byte(rem, '"')
		if end >= 0 {
			jval := rem[:end]
			if len(jval) > 0 && jval != "-" {
				if comma := strings.index_byte(jval, ','); comma >= 0 {
					return jval[:comma]
				}
				return jval
			}
			return fallback
		}
	}
	if jtag, has_jtag := reflect.struct_tag_lookup(tag, "json"); has_jtag && len(jtag) > 0 && jtag != "-" {
		jtag_s := string(jtag)
		if comma_idx := strings.index_byte(jtag_s, ','); comma_idx >= 0 {
			return jtag_s[:comma_idx]
		}
		return jtag_s
	}
	return fallback
}

@(private = "file")
assign_json_value_to_any :: proc(jv: json.Value, dst: any, allocator := context.allocator, clone_strings := true) -> bool {
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
			if clone_strings {
				(cast(^string)dst.data)^ = strings.clone(string(s), allocator)
			} else {
				(cast(^string)dst.data)^ = string(s)
			}
			return true
		}
	case reflect.Type_Info_Slice:
		arr, ok := jv.(json.Array)
		if !ok {
			return false
		}
		if len(arr) == 0 {
			raw_slice := cast(^mem.Raw_Slice)dst.data
			raw_slice.data = nil
			raw_slice.len = 0
			return true
		}
		elem_size := v.elem.size
		raw_mem, alloc_err := mem.alloc_bytes(elem_size * len(arr), v.elem.align, allocator)
		if alloc_err != nil {
			return false
		}
		for item_jv, idx in arr {
			elem_ptr := rawptr(uintptr(raw_data(raw_mem)) + uintptr(idx * elem_size))
			if !assign_json_value_to_any(item_jv, any{elem_ptr, v.elem.id}, allocator, clone_strings) {
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
			json_key := sf.name if len(sf.tag) == 0 else lookup_json_tag(sf.tag, sf.name)
			if field_jv, exists := obj[json_key]; exists {
				f_ptr := rawptr(&base_bytes[sf.offset])
				if !assign_json_value_to_any(field_jv, any{f_ptr, sf.type.id}, allocator, clone_strings) {
					return false
				}
			}
		}
		return true
	}
	return false
}

// Fast, zero-AST-allocation single-pass JSON unmarshaler for `duckdb:"...,json"` struct/slice/scalar fields.
@(private = "file")
json_skip_ws :: #force_inline proc "contextless" (s: []u8, pos: int) -> int {
	i := pos
	for i < len(s) {
		c := s[i]
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
			i += 1
		} else {
			break
		}
	}
	return i
}

@(private = "file")
json_parse_simple_string :: #force_inline proc(s: []u8, pos: int, clone_str: bool, allocator: mem.Allocator) -> (val: string, next_pos: int, ok: bool) {
	if pos >= len(s) || s[pos] != '"' {
		return "", pos, false
	}
	i := pos + 1
	for i < len(s) {
		ch := s[i]
		if ch == '\\' {
			return "", pos, false // Escape sequence present: fall back to full `core:encoding/json` parser
		}
		if ch == '"' {
			raw := string(s[pos + 1 : i])
			if clone_str && len(raw) > 0 {
				return strings.clone(raw, allocator), i + 1, true
			}
			return raw, i + 1, true
		}
		i += 1
	}
	return "", pos, false
}

@(private = "file")
json_skip_value :: proc "contextless" (s: []u8, pos: int) -> (next_pos: int, ok: bool) {
	i := json_skip_ws(s, pos)
	if i >= len(s) {
		return i, false
	}
	switch s[i] {
	case '"':
		i += 1
		for i < len(s) {
			if s[i] == '\\' {
				i += 2
				continue
			}
			if s[i] == '"' {
				return i + 1, true
			}
			i += 1
		}
		return i, false
	case '{', '[':
		open_ch := s[i]
		close_ch := u8('}') if open_ch == '{' else u8(']')
		depth := 1
		i += 1
		for i < len(s) && depth > 0 {
			ch := s[i]
			if ch == '"' {
				i += 1
				for i < len(s) {
					if s[i] == '\\' {
						i += 2
						continue
					}
					if s[i] == '"' {
						i += 1
						break
					}
					i += 1
				}
				continue
			}
			if ch == open_ch {
				depth += 1
			} else if ch == close_ch {
				depth -= 1
			}
			i += 1
		}
		return i, depth == 0
	case:
		start := i
		for i < len(s) {
			ch := s[i]
			if ch == ',' || ch == '}' || ch == ']' || ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' {
				break
			}
			i += 1
		}
		return i, i > start
	}
}

@(private = "file")
unmarshal_json_fast :: proc(s: []u8, pos: int, dst: any, allocator: mem.Allocator) -> (next_pos: int, ok: bool) {
	i := json_skip_ws(s, pos)
	if i >= len(s) {
		return i, false
	}
	if i + 4 <= len(s) && s[i] == 'n' && s[i + 1] == 'u' && s[i + 2] == 'l' && s[i + 3] == 'l' {
		return i + 4, true
	}
	ti := reflect.type_info_base(type_info_of(dst.id))
	#partial switch v in ti.variant {
	case reflect.Type_Info_Boolean:
		if i + 4 <= len(s) && s[i] == 't' && s[i + 1] == 'r' && s[i + 2] == 'u' && s[i + 3] == 'e' {
			(cast(^bool)dst.data)^ = true
			return i + 4, true
		}
		if i + 5 <= len(s) && s[i] == 'f' && s[i + 1] == 'a' && s[i + 2] == 'l' && s[i + 3] == 's' && s[i + 4] == 'e' {
			(cast(^bool)dst.data)^ = false
			return i + 5, true
		}
		return i, false
	case reflect.Type_Info_String:
		str_val, next_i, str_ok := json_parse_simple_string(s, i, true, allocator)
		if !str_ok {
			return i, false
		}
		(cast(^string)dst.data)^ = str_val
		return next_i, true
	case reflect.Type_Info_Integer:
		neg := false
		if s[i] == '-' {
			neg = true
			i += 1
		} else if s[i] == '+' {
			i += 1
		}
		if i >= len(s) || s[i] < '0' || s[i] > '9' {
			return i, false
		}
		acc: u64 = 0
		for i < len(s) {
			ch := s[i]
			if ch >= '0' && ch <= '9' {
				acc = acc * 10 + u64(ch - '0')
				i += 1
			} else {
				break
			}
		}
		val_i64 := -i64(acc) if neg else i64(acc)
		if v.signed {
			switch ti.size {
			case 1: (cast(^i8)dst.data)^  = i8(val_i64)
			case 2: (cast(^i16)dst.data)^ = i16(val_i64)
			case 4: (cast(^i32)dst.data)^ = i32(val_i64)
			case 8: (cast(^i64)dst.data)^ = val_i64
			}
		} else {
			switch ti.size {
			case 1: (cast(^u8)dst.data)^  = u8(acc)
			case 2: (cast(^u16)dst.data)^ = u16(acc)
			case 4: (cast(^u32)dst.data)^ = u32(acc)
			case 8: (cast(^u64)dst.data)^ = acc
			}
		}
		return i, true
	case reflect.Type_Info_Float:
		if i >= len(s) {
			return i, false
		}
		p := i
		neg := false
		if s[p] == '-' {
			neg = true
			p += 1
		} else if s[p] == '+' {
			p += 1
		}
		if p < len(s) && s[p] >= '0' && s[p] <= '9' {
			int_part: u64 = 0
			digits := 0
			for p < len(s) && s[p] >= '0' && s[p] <= '9' {
				int_part = int_part * 10 + u64(s[p] - '0')
				p += 1
				digits += 1
			}
			frac_part: u64 = 0
			frac_scale: f64 = 1.0
			if p < len(s) && s[p] == '.' {
				p += 1
				for p < len(s) && s[p] >= '0' && s[p] <= '9' {
					frac_part = frac_part * 10 + u64(s[p] - '0')
					frac_scale *= 10.0
					p += 1
					digits += 1
				}
			}
			// Fast path for non-scientific floats up to 15 significant digits:
			if digits <= 15 && (p >= len(s) || (s[p] != 'e' && s[p] != 'E')) {
				val_f64 := f64(int_part) + f64(frac_part) / frac_scale
				if neg {
					val_f64 = -val_f64
				}
				if ti.size == 4 {
					(cast(^f32)dst.data)^ = f32(val_f64)
				} else {
					(cast(^f64)dst.data)^ = val_f64
				}
				return p, true
			}
		}
		end_i := i
		for end_i < len(s) {
			ch := s[end_i]
			if (ch >= '0' && ch <= '9') || ch == '.' || ch == '-' || ch == '+' || ch == 'e' || ch == 'E' {
				end_i += 1
			} else {
				break
			}
		}
		if end_i == i {
			return i, false
		}
		val_f64, p_ok := strconv.parse_f64(string(s[i:end_i]))
		if !p_ok {
			return i, false
		}
		if ti.size == 4 {
			(cast(^f32)dst.data)^ = f32(val_f64)
		} else {
			(cast(^f64)dst.data)^ = val_f64
		}
		return end_i, true
	case reflect.Type_Info_Slice:
		if s[i] != '[' {
			return i, false
		}
		i = json_skip_ws(s, i + 1)
		if i < len(s) && s[i] == ']' {
			raw_slice := cast(^mem.Raw_Slice)dst.data
			raw_slice.data = nil
			raw_slice.len = 0
			return i + 1, true
		}
		// Fast single-slab path for `[]string`: counts elements + total string bytes in one scan
		// and allocates a single contiguous block for both `[]string` headers and string bytes.
		if v.elem.id == string {
			count := 0
			total_str_bytes := 0
			scan_i := i
			for scan_i < len(s) {
				if s[scan_i] != '"' {
					return i, false
				}
				str_start := scan_i + 1
				scan_i += 1
				for scan_i < len(s) {
					ch := s[scan_i]
					if ch == '\\' {
						return i, false
					}
					if ch == '"' {
						break
					}
					scan_i += 1
				}
				if scan_i >= len(s) {
					return i, false
				}
				total_str_bytes += scan_i - str_start
				count += 1
				scan_i = json_skip_ws(s, scan_i + 1)
				if scan_i < len(s) && s[scan_i] == ',' {
					scan_i = json_skip_ws(s, scan_i + 1)
				} else if scan_i < len(s) && s[scan_i] == ']' {
					break
				} else {
					return i, false
				}
			}
			headers_bytes := count * size_of(string)
			block, alloc_err := mem.alloc_bytes(headers_bytes + total_str_bytes, align_of(string), allocator)
			if alloc_err != nil {
				return i, false
			}
			str_headers := (cast([^]string)raw_data(block))[:count]
			str_slab := block[headers_bytes:]
			slab_off := 0
			cur_i := i
			for idx := 0; idx < count; idx += 1 {
				str_start := cur_i + 1
				cur_i += 1
				for s[cur_i] != '"' {
					cur_i += 1
				}
				n := cur_i - str_start
				if n > 0 {
					dst_bytes := str_slab[slab_off : slab_off + n]
					mem.copy(raw_data(dst_bytes), &s[str_start], n)
					str_headers[idx] = string(dst_bytes)
					slab_off += n
				} else {
					str_headers[idx] = ""
				}
				cur_i = json_skip_ws(s, cur_i + 1)
				if idx + 1 < count {
					cur_i = json_skip_ws(s, cur_i + 1) // skip ','
				}
			}
			raw_slice := cast(^mem.Raw_Slice)dst.data
			raw_slice.data = raw_data(block)
			raw_slice.len = count
			return scan_i + 1, true
		}
		// Count elements in the JSON array first by scanning top-level commas:
		count := 1
		scan_i := i
		for scan_i < len(s) {
			next_scan, skip_ok := json_skip_value(s, scan_i)
			if !skip_ok {
				return i, false
			}
			scan_i = json_skip_ws(s, next_scan)
			if scan_i < len(s) && s[scan_i] == ',' {
				count += 1
				scan_i = json_skip_ws(s, scan_i + 1)
			} else if scan_i < len(s) && s[scan_i] == ']' {
				break
			} else {
				return i, false
			}
		}
		elem_size := v.elem.size
		raw_mem, alloc_err := mem.alloc_bytes(elem_size * count, v.elem.align, allocator)
		if alloc_err != nil {
			return i, false
		}
		for idx := 0; idx < count; idx += 1 {
			elem_ptr := rawptr(uintptr(raw_data(raw_mem)) + uintptr(idx * elem_size))
			next_i, elem_ok := unmarshal_json_fast(s, i, any{elem_ptr, v.elem.id}, allocator)
			if !elem_ok {
				return i, false
			}
			i = json_skip_ws(s, next_i)
			if idx + 1 < count {
				if i >= len(s) || s[i] != ',' {
					return i, false
				}
				i = json_skip_ws(s, i + 1)
			}
		}
		if i >= len(s) || s[i] != ']' {
			return i, false
		}
		raw_slice := cast(^mem.Raw_Slice)dst.data
		raw_slice.data = raw_data(raw_mem)
		raw_slice.len = count
		return i + 1, true
	case reflect.Type_Info_Struct:
		if s[i] != '{' {
			return i, false
		}
		i = json_skip_ws(s, i + 1)
		if i < len(s) && s[i] == '}' {
			return i + 1, true
		}
		fields := reflect.struct_fields_zipped(dst.id)
		stack_keys: [16]string = ---
		has_stack_keys := len(fields) <= len(stack_keys)
		if has_stack_keys {
			for sf, f_idx in fields {
				stack_keys[f_idx] = sf.name if len(sf.tag) == 0 else lookup_json_tag(sf.tag, sf.name)
			}
		}
		base_bytes := cast([^]u8)dst.data
		field_cursor := 0
		for i < len(s) {
			key_str, after_key, key_ok := json_parse_simple_string(s, i, false, allocator)
			if !key_ok {
				return i, false
			}
			i = json_skip_ws(s, after_key)
			if i >= len(s) || s[i] != ':' {
				return i, false
			}
			i = json_skip_ws(s, i + 1)
			matched := false
			// O(1) positional fast-path when JSON keys are emitted in struct field order:
			if field_cursor < len(fields) {
				sf := fields[field_cursor]
				json_key := stack_keys[field_cursor] if has_stack_keys else (sf.name if len(sf.tag) == 0 else lookup_json_tag(sf.tag, sf.name))
				if json_key == key_str {
					f_ptr := rawptr(&base_bytes[sf.offset])
					next_i, val_ok := unmarshal_json_fast(s, i, any{f_ptr, sf.type.id}, allocator)
					if !val_ok {
						return i, false
					}
					i = next_i
					matched = true
					field_cursor += 1
				}
			}
			if !matched {
				for sf, f_idx in fields {
					json_key := stack_keys[f_idx] if has_stack_keys else (sf.name if len(sf.tag) == 0 else lookup_json_tag(sf.tag, sf.name))
					if json_key == key_str {
						f_ptr := rawptr(&base_bytes[sf.offset])
						next_i, val_ok := unmarshal_json_fast(s, i, any{f_ptr, sf.type.id}, allocator)
						if !val_ok {
							return i, false
						}
						i = next_i
						matched = true
						field_cursor = f_idx + 1
						break
					}
				}
			}
			if !matched {
				next_i, skip_ok := json_skip_value(s, i)
				if !skip_ok {
					return i, false
				}
				i = next_i
			}
			i = json_skip_ws(s, i)
			if i < len(s) && s[i] == ',' {
				i = json_skip_ws(s, i + 1)
				continue
			}
			if i < len(s) && s[i] == '}' {
				return i + 1, true
			}
			return i, false
		}
	}
	return i, false
}

@(private = "file")
write_json_escaped_string :: #force_inline proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	start := 0
	for i := 0; i < len(s); i += 1 {
		ch := s[i]
		if ch == '"' || ch == '\\' || ch < 0x20 {
			if i > start {
				strings.write_string(b, s[start:i])
			}
			switch ch {
			case '"':  strings.write_string(b, `\"`)
			case '\\': strings.write_string(b, `\\`)
			case '\b': strings.write_string(b, `\b`)
			case '\f': strings.write_string(b, `\f`)
			case '\n': strings.write_string(b, `\n`)
			case '\r': strings.write_string(b, `\r`)
			case '\t': strings.write_string(b, `\t`)
			case:
				hex := "0123456789abcdef"
				esc := [6]u8{'\\', 'u', '0', '0', hex[ch >> 4], hex[ch & 0x0f]}
				strings.write_bytes(b, esc[:])
			}
			start = i + 1
		}
	}
	if start < len(s) {
		strings.write_string(b, s[start:])
	}
	strings.write_byte(b, '"')
}

@(private = "file")
marshal_json_fast :: proc(b: ^strings.Builder, val: any) -> bool {
	if val == nil || val.data == nil {
		strings.write_string(b, "null")
		return true
	}
	ti := reflect.type_info_base(type_info_of(val.id))
	#partial switch v in ti.variant {
	case reflect.Type_Info_Boolean:
		if (cast(^bool)val.data)^ {
			strings.write_string(b, "true")
		} else {
			strings.write_string(b, "false")
		}
		return true
	case reflect.Type_Info_String:
		if v.is_cstring {
			write_json_escaped_string(b, string((cast(^cstring)val.data)^))
		} else {
			write_json_escaped_string(b, (cast(^string)val.data)^)
		}
		return true
	case reflect.Type_Info_Integer:
		if v.signed {
			s_val: i64
			switch ti.size {
			case 1: s_val = i64((cast(^i8)val.data)^)
			case 2: s_val = i64((cast(^i16)val.data)^)
			case 4: s_val = i64((cast(^i32)val.data)^)
			case 8: s_val = (cast(^i64)val.data)^
			case:   return false
			}
			strings.write_i64(b, s_val)
		} else {
			u_val: u64
			switch ti.size {
			case 1: u_val = u64((cast(^u8)val.data)^)
			case 2: u_val = u64((cast(^u16)val.data)^)
			case 4: u_val = u64((cast(^u32)val.data)^)
			case 8: u_val = (cast(^u64)val.data)^
			case:   return false
			}
			strings.write_u64(b, u_val)
		}
		return true
	case reflect.Type_Info_Float:
		f_val: f64
		if ti.size == 4 {
			f_val = f64((cast(^f32)val.data)^)
		} else {
			f_val = (cast(^f64)val.data)^
		}
		strings.write_f64(b, f_val, 'g')
		return true
	case reflect.Type_Info_Slice:
		raw_slice := (cast(^mem.Raw_Slice)val.data)^
		strings.write_byte(b, '[')
		elem_size := v.elem.size
		elem_id := v.elem.id
		base_ptr := uintptr(raw_slice.data)
		for idx := 0; idx < raw_slice.len; idx += 1 {
			if idx > 0 {
				strings.write_byte(b, ',')
			}
			elem_ptr := rawptr(base_ptr + uintptr(idx * elem_size))
			if !marshal_json_fast(b, any{elem_ptr, elem_id}) {
				return false
			}
		}
		strings.write_byte(b, ']')
		return true
	case reflect.Type_Info_Array:
		strings.write_byte(b, '[')
		elem_size := v.elem_size
		elem_id := v.elem.id
		base_ptr := uintptr(val.data)
		for idx := 0; idx < v.count; idx += 1 {
			if idx > 0 {
				strings.write_byte(b, ',')
			}
			elem_ptr := rawptr(base_ptr + uintptr(idx * elem_size))
			if !marshal_json_fast(b, any{elem_ptr, elem_id}) {
				return false
			}
		}
		strings.write_byte(b, ']')
		return true
	case reflect.Type_Info_Struct:
		strings.write_byte(b, '{')
		fields := reflect.struct_fields_zipped(val.id)
		base_bytes := cast([^]u8)val.data
		first := true
		for sf in fields {
			if len(sf.tag) > 0 {
				if jtag, has_jtag := reflect.struct_tag_lookup(sf.tag, "json"); has_jtag && jtag == "-" {
					continue
				}
			}
			if !first {
				strings.write_byte(b, ',')
			}
			first = false
			json_key := sf.name if len(sf.tag) == 0 else lookup_json_tag(sf.tag, sf.name)
			strings.write_byte(b, '"')
			strings.write_string(b, json_key)
			strings.write_string(b, `":`)
			f_ptr := rawptr(&base_bytes[sf.offset])
			if !marshal_json_fast(b, any{f_ptr, sf.type.id}) {
				return false
			}
		}
		strings.write_byte(b, '}')
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
	fields := reflect.struct_fields_zipped(T)
	b := strings.builder_make(0, 128 + len(fields) * 32, allocator)

	if if_not_exists {
		strings.write_string(&b, "CREATE TABLE IF NOT EXISTS ")
	} else {
		strings.write_string(&b, "CREATE TABLE ")
	}
	write_quoted_identifier(&b, table_name, true)
	strings.write_string(&b, " (")

	col_idx := 0
	for f in fields {
		m := parse_single_struct_field(f)
		if m.ignored {
			continue
		}
		if col_idx > 0 {
			strings.write_string(&b, ", ")
		}
		col_idx += 1

		write_quoted_identifier(&b, m.column_name, false)
		strings.write_byte(&b, ' ')
		strings.write_string(&b, m.sql_type)
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
			strings.write_string(&b, " DEFAULT ")
			strings.write_string(&b, m.default_val)
		}
	}
	strings.write_byte(&b, ')')
	return strings.to_string(b)
}

// Collects non-ignored `Struct_Field_Mapping` entries for `$T` into `stack_buf` when `active_count <= 16`,
// or allocates an exact-sized slice on `allocator` (guaranteeing `len == cap` for safe `delete(slice, allocator)`).
@(private = "file")
collect_active_struct_fields :: proc(
	$T: typeid,
	stack_buf: ^[16]Struct_Field_Mapping,
	allocator: mem.Allocator,
) -> (active: []Struct_Field_Mapping, dyn_allocated: []Struct_Field_Mapping) where intrinsics.type_is_struct(T) {
	raw_fields := reflect.struct_fields_zipped(T)
	if len(raw_fields) <= len(stack_buf^) {
		n := 0
		for rf in raw_fields {
			m := parse_single_struct_field(rf)
			if !m.ignored {
				stack_buf^[n] = m
				n += 1
			}
		}
		return stack_buf[:n], nil
	}

	active_count := 0
	for rf in raw_fields {
		m := parse_single_struct_field(rf)
		if !m.ignored {
			active_count += 1
		}
	}
	if active_count == 0 {
		return nil, nil
	}
	if active_count <= len(stack_buf^) {
		n := 0
		for rf in raw_fields {
			m := parse_single_struct_field(rf)
			if !m.ignored {
				stack_buf^[n] = m
				n += 1
			}
		}
		return stack_buf[:n], nil
	}

	dyn_slice := make([]Struct_Field_Mapping, active_count, allocator)
	n := 0
	for rf in raw_fields {
		m := parse_single_struct_field(rf)
		if !m.ignored {
			dyn_slice[n] = m
			n += 1
		}
	}
	return dyn_slice, dyn_slice
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
	app: Struct_Appender(T)
	if rc := struct_appender_create(conn, T, table_name, &app, context.temp_allocator, err); rc != .NONE {
		return rc
	}
	defer struct_appender_destroy(&app)

	if rc := struct_appender_append(&app, rows, err); rc != .NONE {
		return rc
	}
	return struct_appender_flush_internal(&app, false, err)
}

// ============================================================================
// Reusable `Struct_Appender(T)` & `Prepared_Query(T)` Session Handles
// ============================================================================

// Persistent session handle that amortizes struct reflection, `V2_Column_Data_Collection_Handle`
// allocation, `V2_Data_Chunk_Handle` creation, and `INSERT INTO <table>` SQL building across
// repeated micro-batch appends (`struct_appender_append` + `struct_appender_flush`).
Struct_Appender :: struct($T: typeid) where intrinsics.type_is_struct(T) {
	conn:           V2_Connection_Handle,
	factory:        V2_Factory_Handle,
	collection:     V2_Column_Data_Collection_Handle,
	append_state:   V2_Column_Data_Collection_Append_State_Handle,
	chunk:          V2_Data_Chunk_Handle,
	chunk_cap:      V2_Idx,
	col_count:      int,
	has_any_json:   bool,
	chunk_dirty:    bool,
	fields_in:      [16]Struct_Field_Mapping,
	col_types_in:   [16]V2_Logical_Type_Handle,
	col_names_in:   [16]V2_Identifier,
	col_vecs_in:    [16]V2_Vector_Handle,
	fields_dyn:     []Struct_Field_Mapping,
	col_types_dyn:  []V2_Logical_Type_Handle,
	col_names_dyn:  []V2_Identifier,
	col_vecs_dyn:   []V2_Vector_Handle,
	insert_sql_buf: [dynamic]u8,
	allocator:      mem.Allocator,
}

@(private = "file")
struct_appender_fields :: #force_inline proc(app: ^Struct_Appender($T)) -> []Struct_Field_Mapping {
	if app.col_count <= len(app.fields_in) {
		return app.fields_in[:app.col_count]
	}
	return app.fields_dyn
}

@(private = "file")
struct_appender_col_names :: #force_inline proc(app: ^Struct_Appender($T)) -> []V2_Identifier {
	if app.col_count <= len(app.col_names_in) {
		return app.col_names_in[:app.col_count]
	}
	return app.col_names_dyn
}

@(private = "file")
struct_appender_col_vecs :: #force_inline proc(app: ^Struct_Appender($T)) -> []V2_Vector_Handle {
	if app.col_count <= len(app.col_vecs_in) {
		return app.col_vecs_in[:app.col_count]
	}
	return app.col_vecs_dyn
}

// Creates a reusable `Struct_Appender(T)` bound to `table_name` on `conn`.
struct_appender_create :: proc(
	conn: V2_Connection_Handle,
	$T: typeid,
	table_name: string,
	out_app: ^Struct_Appender(T),
	allocator := context.allocator,
	err: ^V2_Error_Info_Handle = nil,
) -> V2_Error where intrinsics.type_is_struct(T) {
	out_app^ = Struct_Appender(T){
		conn      = conn,
		allocator = allocator,
	}

	active, dyn_fields := collect_active_struct_fields(T, &out_app.fields_in, allocator)
	out_app.col_count = len(active)
	out_app.fields_dyn = dyn_fields
	if out_app.col_count == 0 {
		return .INPUT_INVALID
	}
	if out_app.col_count > len(out_app.fields_in) {
		out_app.col_types_dyn = make([]V2_Logical_Type_Handle, out_app.col_count, allocator)
		out_app.col_names_dyn = make([]V2_Identifier, out_app.col_count, allocator)
		out_app.col_vecs_dyn  = make([]V2_Vector_Handle, out_app.col_count, allocator)
	}

	if rc := duckdb_v2_connection_get_factory(conn, &out_app.factory, err); rc != .NONE {
		struct_appender_destroy(out_app)
		return rc
	}

	col_names := struct_appender_col_names(out_app)
	col_vecs := struct_appender_col_vecs(out_app)
	col_types := out_app.col_types_in[:out_app.col_count] if out_app.col_count <= len(out_app.col_types_in) else out_app.col_types_dyn

	for f, idx in active {
		if rc := duckdb_v2_factory_create_type_from_id(out_app.factory, f.type_id, nil, nil, 0, &col_types[idx], err); rc != .NONE {
			struct_appender_destroy(out_app)
			return rc
		}
		col_names[idx] = V2_Identifier(v2_str_from_string(f.column_name))
		if f.is_json {
			out_app.has_any_json = true
		}
	}

	if rc := duckdb_v2_column_data_collection_create(
		out_app.factory,
		raw_data(col_types),
		V2_Idx(out_app.col_count),
		&out_app.collection,
		err,
	); rc != .NONE {
		struct_appender_destroy(out_app)
		return rc
	}

	if rc := duckdb_v2_column_data_collection_append_state_create(out_app.collection, &out_app.append_state, err); rc != .NONE {
		struct_appender_destroy(out_app)
		return rc
	}

	if rc := duckdb_v2_data_chunk_create(out_app.factory, raw_data(col_types), V2_Idx(out_app.col_count), &out_app.chunk, err); rc != .NONE {
		struct_appender_destroy(out_app)
		return rc
	}

	for col_idx := 0; col_idx < out_app.col_count; col_idx += 1 {
		if rc := duckdb_v2_data_chunk_get_vector(out_app.chunk, V2_Idx(col_idx), &col_vecs[col_idx], err); rc != .NONE {
			struct_appender_destroy(out_app)
			return rc
		}
	}

	if rc := duckdb_v2_data_chunk_get_capacity(out_app.chunk, &out_app.chunk_cap, err); rc != .NONE {
		struct_appender_destroy(out_app)
		return rc
	}
	if out_app.chunk_cap == 0 {
		out_app.chunk_cap = 2048
	}

	sql_b := strings.builder_make(0, 64 + out_app.col_count * 16, allocator)
	strings.write_string(&sql_b, "INSERT INTO ")
	write_quoted_identifier(&sql_b, table_name, true)
	strings.write_string(&sql_b, " (")
	for f, idx in active {
		if idx > 0 {
			strings.write_string(&sql_b, ", ")
		}
		write_quoted_identifier(&sql_b, f.column_name, false)
	}
	strings.write_string(&sql_b, ") SELECT * FROM __odin_append_src")
	strings.write_byte(&sql_b, 0)
	out_app.insert_sql_buf = sql_b.buf
	return .NONE
}

// Destroys all C API v2 handles and dynamic allocations owned by `app`.
struct_appender_destroy :: proc(app: ^Struct_Appender($T)) where intrinsics.type_is_struct(T) {
	if app == nil {
		return
	}
	if app.chunk != nil {
		duckdb_v2_data_chunk_destroy(&app.chunk)
	}
	if app.append_state != nil {
		duckdb_v2_column_data_collection_append_state_destroy(&app.append_state)
	}
	if app.collection != nil {
		duckdb_v2_column_data_collection_destroy(&app.collection)
	}
	col_types := app.col_types_in[:app.col_count] if app.col_count <= len(app.col_types_in) else app.col_types_dyn
	for &ct in col_types {
		if ct != nil {
			duckdb_v2_logical_type_destroy(&ct)
		}
	}
	if len(app.fields_dyn) > 0 {
		delete(app.fields_dyn, app.allocator)
		delete(app.col_types_dyn, app.allocator)
		delete(app.col_names_dyn, app.allocator)
		delete(app.col_vecs_dyn, app.allocator)
	}
	if app.insert_sql_buf != nil {
		delete(app.insert_sql_buf)
	}
	app^ = {}
}

// Appends a batch of `rows: []T` into `app`'s in-memory `V2_Column_Data_Collection_Handle`
// without parsing SQL or re-reflecting struct tags. Call `struct_appender_flush` to commit the
// buffered collection to the target table.
struct_appender_append :: proc(
	app: ^Struct_Appender($T),
	rows: []T,
	err: ^V2_Error_Info_Handle = nil,
) -> V2_Error where intrinsics.type_is_struct(T) {
	if len(rows) == 0 {
		return .NONE
	}
	clear_first := app.chunk_dirty
	app.chunk_dirty = true
	return append_rows_to_collection(
		app.collection,
		app.append_state,
		app.chunk,
		app.chunk_cap,
		struct_appender_fields(app),
		struct_appender_col_vecs(app),
		app.has_any_json,
		clear_first,
		rows,
		err,
	)
}

@(private = "file")
append_scalar_col :: #force_inline proc(
	$Col_Type: typeid,
	raw: rawptr,
	rows: []$Row,
	batch_start, batch_len: int,
	f: Struct_Field_Mapping,
	vec: V2_Vector_Handle,
	err: ^V2_Error_Info_Handle,
) -> V2_Error {
	dst := cast([^]Col_Type)raw
	if !f.is_maybe {
		for r_idx := 0; r_idx < batch_len; r_idx += 1 {
			row_ptr := cast([^]u8)&rows[batch_start + r_idx]
			dst[r_idx] = (cast(^Col_Type)&row_ptr[f.offset])^
		}
		return .NONE
	}
	validity_mask: [^]u64
	for r_idx := 0; r_idx < batch_len; r_idx += 1 {
		row_ptr := cast([^]u8)&rows[batch_start + r_idx]
		field_ptr := cast(rawptr)&row_ptr[f.offset]
		if !maybe_field_is_present(field_ptr, f) {
			if validity_mask == nil {
				if rc := duckdb_v2_vector_flat_get_validity_mutable(vec, &validity_mask, err); rc != .NONE {
					return rc
				}
			}
			v2_validity_set_invalid(validity_mask, V2_Idx(r_idx))
			continue
		}
		dst[r_idx] = (cast(^Col_Type)field_ptr)^
	}
	return .NONE
}

@(private = "file")
append_bytes_col :: #force_inline proc(
	$Col_Type: typeid,
	raw: rawptr,
	rows: []$Row,
	batch_start, batch_len: int,
	f: Struct_Field_Mapping,
	vec: V2_Vector_Handle,
	err: ^V2_Error_Info_Handle,
) -> V2_Error {
	arena: V2_Arena_Handle
	dst := cast([^]V2_Bytes)raw
	if !f.is_maybe {
		for r_idx := 0; r_idx < batch_len; r_idx += 1 {
			row_ptr := cast([^]u8)&rows[batch_start + r_idx]
			val := (cast(^Col_Type)&row_ptr[f.offset])^
			raw_bytes := transmute([]u8)val when Col_Type == string else val
			if len(raw_bytes) > V2_BYTES_INLINE_LENGTH && arena == nil {
				if rc := duckdb_v2_vector_get_arena(vec, &arena, err); rc != .NONE {
					return rc
				}
			}
			if rc := v2_bytes_encode_in_arena(arena, raw_bytes, &dst[r_idx], err); rc != .NONE {
				return rc
			}
		}
		return .NONE
	}
	validity_mask: [^]u64
	for r_idx := 0; r_idx < batch_len; r_idx += 1 {
		row_ptr := cast([^]u8)&rows[batch_start + r_idx]
		field_ptr := cast(rawptr)&row_ptr[f.offset]
		if !maybe_field_is_present(field_ptr, f) {
			if validity_mask == nil {
				if rc := duckdb_v2_vector_flat_get_validity_mutable(vec, &validity_mask, err); rc != .NONE {
					return rc
				}
			}
			v2_validity_set_invalid(validity_mask, V2_Idx(r_idx))
			continue
		}
		val := (cast(^Col_Type)field_ptr)^
		raw_bytes := transmute([]u8)val when Col_Type == string else val
		if len(raw_bytes) > V2_BYTES_INLINE_LENGTH && arena == nil {
			if rc := duckdb_v2_vector_get_arena(vec, &arena, err); rc != .NONE {
				return rc
			}
		}
		if rc := v2_bytes_encode_in_arena(arena, raw_bytes, &dst[r_idx], err); rc != .NONE {
			return rc
		}
	}
	return .NONE
}

@(private = "file")
append_rows_to_collection :: proc(
	collection: V2_Column_Data_Collection_Handle,
	append_state: V2_Column_Data_Collection_Append_State_Handle,
	chunk: V2_Data_Chunk_Handle,
	chunk_cap: V2_Idx,
	active_fields: []Struct_Field_Mapping,
	col_vecs: []V2_Vector_Handle,
	has_any_json: bool,
	clear_first_chunk: bool,
	rows: []$T,
	err: ^V2_Error_Info_Handle = nil,
) -> V2_Error where intrinsics.type_is_struct(T) {
	json_b: strings.Builder
	if has_any_json {
		json_b = strings.builder_make(0, 256, context.temp_allocator)
	}

	batch_start := 0
	for batch_start < len(rows) {
		batch_len := len(rows) - batch_start
		if V2_Idx(batch_len) > chunk_cap {
			batch_len = int(chunk_cap)
		}
		if clear_first_chunk || batch_start > 0 {
			if rc := duckdb_v2_data_chunk_clear(chunk, err); rc != .NONE {
				return rc
			}
		}

		for f, col_idx in active_fields {
			vec := col_vecs[col_idx]

			raw: rawptr
			if rc := duckdb_v2_vector_get_data_mutable(vec, &raw, err); rc != .NONE {
				return rc
			}
			if rc := duckdb_v2_vector_set_size(vec, V2_Idx(batch_len), err); rc != .NONE {
				return rc
			}

			if f.is_json {
				arena: V2_Arena_Handle
				if rc := duckdb_v2_vector_get_arena(vec, &arena, err); rc != .NONE {
					return rc
				}
				bytes_dst := cast([^]V2_Bytes)raw
				json_opt: json.Marshal_Options
				validity_mask: [^]u64
				for r_idx := 0; r_idx < batch_len; r_idx += 1 {
					row_ptr := cast([^]u8)&rows[batch_start + r_idx]
					field_ptr := cast(rawptr)&row_ptr[f.offset]
					if f.is_maybe && !maybe_field_is_present(field_ptr, f) {
						if validity_mask == nil {
							if rc := duckdb_v2_vector_flat_get_validity_mutable(vec, &validity_mask, err); rc != .NONE {
								return rc
							}
						}
						v2_validity_set_invalid(validity_mask, V2_Idx(r_idx))
						continue
					}
					strings.builder_reset(&json_b)
					if !marshal_json_fast(&json_b, any{field_ptr, f.inner_type.id}) {
						strings.builder_reset(&json_b)
						if m_err := json.marshal_to_builder(&json_b, any{field_ptr, f.inner_type.id}, &json_opt); m_err != nil {
							return .TYPE_CONVERSION
						}
					}
					if rc := v2_bytes_encode_in_arena(arena, json_b.buf[:], &bytes_dst[r_idx], err); rc != .NONE {
						return rc
					}
				}
				continue
			}

			rc_col: V2_Error
			#partial switch f.type_id {
			case .BOOLEAN:   rc_col = append_scalar_col(bool, raw, rows, batch_start, batch_len, f, vec, err)
			case .TINYINT:   rc_col = append_scalar_col(i8, raw, rows, batch_start, batch_len, f, vec, err)
			case .SMALLINT:  rc_col = append_scalar_col(i16, raw, rows, batch_start, batch_len, f, vec, err)
			case .INTEGER:   rc_col = append_scalar_col(i32, raw, rows, batch_start, batch_len, f, vec, err)
			case .BIGINT:    rc_col = append_scalar_col(i64, raw, rows, batch_start, batch_len, f, vec, err)
			case .UTINYINT:  rc_col = append_scalar_col(u8, raw, rows, batch_start, batch_len, f, vec, err)
			case .USMALLINT: rc_col = append_scalar_col(u16, raw, rows, batch_start, batch_len, f, vec, err)
			case .UINTEGER:  rc_col = append_scalar_col(u32, raw, rows, batch_start, batch_len, f, vec, err)
			case .UBIGINT:   rc_col = append_scalar_col(u64, raw, rows, batch_start, batch_len, f, vec, err)
			case .FLOAT:     rc_col = append_scalar_col(f32, raw, rows, batch_start, batch_len, f, vec, err)
			case .DOUBLE:    rc_col = append_scalar_col(f64, raw, rows, batch_start, batch_len, f, vec, err)
			case .HUGEINT:   rc_col = append_scalar_col(V2_Hugeint, raw, rows, batch_start, batch_len, f, vec, err)
			case .UHUGEINT:  rc_col = append_scalar_col(V2_Uhugeint, raw, rows, batch_start, batch_len, f, vec, err)
			case .INTERVAL:  rc_col = append_scalar_col(V2_Interval, raw, rows, batch_start, batch_len, f, vec, err)
			case .VARCHAR:   rc_col = append_bytes_col(string, raw, rows, batch_start, batch_len, f, vec, err)
			case .BLOB:      rc_col = append_bytes_col([]u8, raw, rows, batch_start, batch_len, f, vec, err)
			}
			if rc_col != .NONE {
				return rc_col
			}
		}

		if rc := duckdb_v2_column_data_collection_append(collection, append_state, chunk, err); rc != .NONE {
			return rc
		}
		batch_start += batch_len
	}
	return .NONE
}

@(private = "file")
struct_appender_flush_internal :: proc(
	app: ^Struct_Appender($T),
	reset_after_flush: bool,
	err: ^V2_Error_Info_Handle = nil,
) -> V2_Error where intrinsics.type_is_struct(T) {
	row_cnt: V2_Idx
	if rc := duckdb_v2_column_data_collection_row_count(app.collection, &row_cnt, err); rc != .NONE {
		return rc
	}
	if row_cnt == 0 {
		return .NONE
	}

	c_sql := cstring(raw_data(app.insert_sql_buf))
	iter: V2_Statement_Iterator_Handle
	if rc := duckdb_v2_parse_sql(app.conn, c_sql, &iter, err); rc != .NONE {
		return rc
	}
	defer duckdb_v2_statement_iterator_destroy(&iter)

	stmt: V2_Sql_Statement_Handle
	if rc := duckdb_v2_statement_iterator_next(iter, &stmt, err); rc != .NONE {
		return rc
	}
	defer duckdb_v2_sql_statement_destroy(&stmt)

	col_names := struct_appender_col_names(app)
	src_ident := V2_Identifier(v2_str_from_string("__odin_append_src"))
	if rc := duckdb_v2_statement_add_collection(
		stmt,
		&src_ident,
		app.collection,
		raw_data(col_names),
		V2_Idx(app.col_count),
		err,
	); rc != .NONE {
		return rc
	}

	res: V2_Result_Handle
	if rc := duckdb_v2_statement_execute(app.conn, stmt, nil, nil, 0, &res, err); rc != .NONE {
		return rc
	}
	defer duckdb_v2_result_destroy(&res)

	rows_changed: V2_Idx
	if rc := duckdb_v2_result_drain(res, &rows_changed, err); rc != .NONE {
		return rc
	}

	if !reset_after_flush {
		return .NONE
	}

	if app.append_state != nil {
		duckdb_v2_column_data_collection_append_state_destroy(&app.append_state)
	}
	if rc := duckdb_v2_column_data_collection_clear(app.collection, err); rc != .NONE {
		return rc
	}
	return duckdb_v2_column_data_collection_append_state_create(app.collection, &app.append_state, err)
}

// Flushes all rows currently buffered in `app.collection` into the target table via a single
// `duckdb_v2_statement_add_collection` + `duckdb_v2_statement_execute` call, then clears `app.collection`
// and recreates `app.append_state` so `app` can immediately accept the next wave of batches.
struct_appender_flush :: proc(
	app: ^Struct_Appender($T),
	err: ^V2_Error_Info_Handle = nil,
) -> V2_Error where intrinsics.type_is_struct(T) {
	return struct_appender_flush_internal(app, true, err)
}

// Shared schema-to-struct column binder used by both `prepared_query_create` and `query_as`.
@(private = "file")
bind_schema_to_struct_fields :: proc(
	schema: V2_Schema_Handle,
	active_fields: []Struct_Field_Mapping,
	col_to_field: []int,
	field_claimed: []bool,
	caller_label: string,
	err: ^V2_Error_Info_Handle,
) -> V2_Error {
	for i := 0; i < len(col_to_field); i += 1 {
		col_to_field[i] = -1
	}
	schema_cols := V2_Idx(len(col_to_field))
	for col_idx: V2_Idx = 0; col_idx < schema_cols; col_idx += 1 {
		col_name_ident: V2_Identifier
		col_type_handle: V2_Logical_Type_Handle // Borrowed from `schema` (`duckdb_v2.h` line 4720); do NOT destroy.
		if rc := duckdb_v2_schema_get_field(schema, col_idx, &col_name_ident, &col_type_handle, err); rc != .NONE {
			return rc
		}
		col_type_id: V2_Logical_Type_Id
		if rc := duckdb_v2_logical_type_get_id(col_type_handle, &col_type_id, err); rc != .NONE {
			return rc
		}

		col_name := v2_str_to_string(col_name_ident)
		matched_field_idx := -1
		// O(1) positional fast-path when result column `col_idx` matches `active_fields[col_idx]` directly:
		if int(col_idx) < len(active_fields) && !field_claimed[int(col_idx)] {
			pf := active_fields[int(col_idx)]
			if pf.column_name == col_name || pf.field_name == col_name {
				matched_field_idx = int(col_idx)
			}
		}
		if matched_field_idx < 0 {
			for f, f_idx in active_fields {
				if f.column_name == col_name || f.field_name == col_name ||
				   strings.equal_fold(f.column_name, col_name) || strings.equal_fold(f.field_name, col_name) {
					matched_field_idx = f_idx
					break
				}
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
							"%s column '%s' type mismatch: expected %v, got %v",
							caller_label,
							col_name,
							f.type_id,
							col_type_id,
						),
					)
					_ = duckdb_v2_error_info_set_code(err^, .INPUT_INVALID)
					_ = duckdb_v2_error_info_set_text(err^, &msg)
				}
				return .INPUT_INVALID
			}
			col_to_field[int(col_idx)] = matched_field_idx
			field_claimed[matched_field_idx] = true
		}
	}
	return .NONE
}

// Pre-compiled, schema-verified typed query handle (`Prepared_Query(T)`).
// Compiles SQL into a `V2_Prepared_Statement_Handle` AND binds the result `V2_Schema_Handle`
// once at prepare time (`prepared_query_create` / `query_prepare_as`), caching the `col_to_field`
// mapping so `prepared_query_execute_as` skips SQL parsing, binding, reflection, and schema
// inspection on every execution.
Prepared_Query :: struct($T: typeid) where intrinsics.type_is_struct(T) {
	conn:             V2_Connection_Handle,
	factory:          V2_Factory_Handle,
	prepared:         V2_Prepared_Statement_Handle,
	schema_col_count: int,
	active_len:       int,
	fields_in:        [16]Struct_Field_Mapping,
	col_to_field_in:  [16]int,
	fields_dyn:       []Struct_Field_Mapping,
	col_to_field_dyn: []int,
	allocator:        mem.Allocator,
}

@(private = "file")
prepared_query_fields :: #force_inline proc(pq: ^Prepared_Query($T)) -> []Struct_Field_Mapping {
	if pq.active_len <= len(pq.fields_in) {
		return pq.fields_in[:pq.active_len]
	}
	return pq.fields_dyn
}

@(private = "file")
prepared_query_col_map :: #force_inline proc(pq: ^Prepared_Query($T)) -> []int {
	if pq.schema_col_count <= len(pq.col_to_field_in) {
		return pq.col_to_field_in[:pq.schema_col_count]
	}
	return pq.col_to_field_dyn
}

// Parses, binds, validates column types against `$T`, and prepares `sql` into `out_pq`.
prepared_query_create :: proc(
	conn: V2_Connection_Handle,
	$T: typeid,
	sql: string,
	out_pq: ^Prepared_Query(T),
	require_cacheable: bool = false,
	allocator := context.allocator,
	err: ^V2_Error_Info_Handle = nil,
) -> V2_Error where intrinsics.type_is_struct(T) {
	out_pq^ = Prepared_Query(T){
		conn      = conn,
		allocator = allocator,
	}

	if rc := duckdb_v2_connection_get_factory(conn, &out_pq.factory, err); rc != .NONE {
		return rc
	}

	active_fields, dyn_fields := collect_active_struct_fields(T, &out_pq.fields_in, allocator)
	out_pq.active_len = len(active_fields)
	out_pq.fields_dyn = dyn_fields

	stmt: V2_Sql_Statement_Handle
	if rc := v2_parse_single_stmt(conn, sql, &stmt, err); rc != .NONE || stmt == nil {
		prepared_query_destroy(out_pq)
		return rc
	}
	defer duckdb_v2_sql_statement_destroy(&stmt)

	schema: V2_Schema_Handle
	if rc := duckdb_v2_statement_bind(conn, stmt, &schema, nil, err); rc != .NONE {
		prepared_query_destroy(out_pq)
		return rc
	}
	defer duckdb_v2_schema_destroy(&schema)

	schema_cols: V2_Idx
	if rc := duckdb_v2_schema_get_count(schema, &schema_cols, err); rc != .NONE {
		prepared_query_destroy(out_pq)
		return rc
	}
	out_pq.schema_col_count = int(schema_cols)
	if out_pq.schema_col_count > len(out_pq.col_to_field_in) {
		out_pq.col_to_field_dyn = make([]int, out_pq.schema_col_count, allocator)
	}
	col_to_field := prepared_query_col_map(out_pq)

	stack_claimed: [16]bool
	field_claimed: []bool
	if out_pq.active_len <= len(stack_claimed) {
		field_claimed = stack_claimed[:out_pq.active_len]
	} else {
		field_claimed = make([]bool, out_pq.active_len, context.temp_allocator)
	}

	if rc := bind_schema_to_struct_fields(schema, active_fields, col_to_field, field_claimed, "prepared_query_create", err); rc != .NONE {
		prepared_query_destroy(out_pq)
		return rc
	}

	if rc := duckdb_v2_prepared_statement_create(conn, stmt, require_cacheable, &out_pq.prepared, err); rc != .NONE {
		prepared_query_destroy(out_pq)
		return rc
	}
	return .NONE
}

// Destroys the underlying `V2_Prepared_Statement_Handle` and any dynamic slices owned by `pq`.
prepared_query_destroy :: proc(pq: ^Prepared_Query($T)) where intrinsics.type_is_struct(T) {
	if pq == nil {
		return
	}
	if pq.prepared != nil {
		duckdb_v2_prepared_statement_destroy(&pq.prepared)
	}
	if len(pq.fields_dyn) > 0 {
		delete(pq.fields_dyn, pq.allocator)
	}
	if len(pq.col_to_field_dyn) > 0 {
		delete(pq.col_to_field_dyn, pq.allocator)
	}
	pq^ = {}
}

// Executes a pre-compiled `Prepared_Query(T)` with optional positional `args` (`..any`)
// and unmarshals the result chunks directly using the pre-bound `col_to_field` mapping.
prepared_query_execute_as :: proc(
	pq: ^Prepared_Query($T),
	allocator := context.allocator,
	err: ^V2_Error_Info_Handle = nil,
	args: ..any,
) -> (out: [dynamic]T, rc: V2_Error) where intrinsics.type_is_struct(T) {
	out = make([dynamic]T, allocator)
	res: V2_Result_Handle
	rc = v2_prepared_execute_with_factory(pq.factory, pq.prepared, &res, err, ..args)
	if rc != .NONE {
		return out, rc
	}
	defer duckdb_v2_result_destroy(&res)

	active_fields := prepared_query_fields(pq)
	col_to_field := prepared_query_col_map(pq)
	stack_views: [16]V2_Vector_View = ---
	views: []V2_Vector_View
	if pq.schema_col_count <= len(stack_views) {
		views = stack_views[:pq.schema_col_count]
	} else {
		views = make([]V2_Vector_View, pq.schema_col_count, context.temp_allocator)
	}
	return unmarshal_result_chunks_with_mapping(&out, res, active_fields, col_to_field, views, allocator, err)
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
	stack_active: [16]Struct_Field_Mapping = ---
	active_fields, _ := collect_active_struct_fields(T, &stack_active, context.temp_allocator)

	res: V2_Result_Handle
	rc = v2_query(conn, sql, &res, err, ..args)
	if rc != .NONE {
		return out, rc
	}
	defer duckdb_v2_result_destroy(&res)

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

	stack_col_to_field: [16]int = ---
	stack_field_claimed: [16]bool
	stack_views: [16]V2_Vector_View = ---
	col_to_field: []int
	field_claimed: []bool
	views: []V2_Vector_View
	if int(schema_col_count) <= len(stack_col_to_field) && len(active_fields) <= len(stack_field_claimed) {
		col_to_field  = stack_col_to_field[:int(schema_col_count)]
		field_claimed = stack_field_claimed[:len(active_fields)]
		views         = stack_views[:int(schema_col_count)]
	} else {
		col_to_field  = make([]int, int(schema_col_count), context.temp_allocator)
		field_claimed = make([]bool, len(active_fields), context.temp_allocator)
		views         = make([]V2_Vector_View, int(schema_col_count), context.temp_allocator)
	}

	rc = bind_schema_to_struct_fields(schema, active_fields, col_to_field, field_claimed, "query_as", err)
	if rc != .NONE {
		return out, rc
	}

	return unmarshal_result_chunks_with_mapping(&out, res, active_fields, col_to_field, views, allocator, err)
}

@(private = "file")
unmarshal_scalar_col :: #force_inline proc(
	$Col_Type: typeid,
	view: V2_Vector_View,
	out: []$Row,
	base_row, n_rows: int,
	f: Struct_Field_Mapping,
) {
	src := cast([^]Col_Type)view.data
	if !f.is_maybe && view.validity == nil && view.sel == nil {
		for r := 0; r < n_rows; r += 1 {
			item_bytes := cast([^]u8)&out[base_row + r]
			(cast(^Col_Type)&item_bytes[f.offset])^ = src[r]
		}
		return
	}
	sel := view.sel
	val_mask := view.validity
	for r := 0; r < n_rows; r += 1 {
		phys := V2_Idx(r) if sel == nil else V2_Idx(sel[r])
		if val_mask != nil && (val_mask[phys >> 6] & (u64(1) << (phys & 63))) == 0 {
			continue
		}
		item_bytes := cast([^]u8)&out[base_row + r]
		field_ptr := cast(rawptr)&item_bytes[f.offset]
		(cast(^Col_Type)field_ptr)^ = src[phys]
		if f.is_maybe {
			maybe_field_mark_present(field_ptr, f)
		}
	}
}

@(private = "file")
unmarshal_bytes_col :: #force_inline proc(
	$Col_Type: typeid,
	view: V2_Vector_View,
	out: []$Row,
	base_row, n_rows: int,
	f: Struct_Field_Mapping,
	allocator: mem.Allocator,
) {
	src := cast([^]V2_Bytes)view.data
	if !f.is_maybe && view.validity == nil && view.sel == nil {
		total_bytes := 0
		for r := 0; r < n_rows; r += 1 {
			total_bytes += int(v2_bytes_length(&src[r]))
		}
		if total_bytes > 0 {
			slab := make([]u8, total_bytes, allocator)
			offset := 0
			for r := 0; r < n_rows; r += 1 {
				item_bytes := cast([^]u8)&out[base_row + r]
				b_ptr := &src[r]
				n := int(v2_bytes_length(b_ptr))
				if n > 0 {
					dst_slice := slab[offset : offset + n]
					mem.copy(raw_data(dst_slice), v2_bytes_data(b_ptr), n)
					(cast(^Col_Type)&item_bytes[f.offset])^ = string(dst_slice) when Col_Type == string else dst_slice
					offset += n
				}
			}
		}
		return
	}
	sel := view.sel
	val_mask := view.validity
	total_bytes := 0
	for r := 0; r < n_rows; r += 1 {
		phys := V2_Idx(r) if sel == nil else V2_Idx(sel[r])
		if val_mask == nil || (val_mask[phys >> 6] & (u64(1) << (phys & 63))) != 0 {
			total_bytes += int(v2_bytes_length(&src[phys]))
		}
	}
	nullable_slab: []u8
	if total_bytes > 0 {
		nullable_slab = make([]u8, total_bytes, allocator)
	} else if f.is_maybe && f.maybe_tag_size == 0 {
		nullable_slab = make([]u8, 1, allocator)
	}
	empty_non_nil := string(nullable_slab[:0]) when Col_Type == string else nullable_slab[:0]
	offset := 0
	for r := 0; r < n_rows; r += 1 {
		phys := V2_Idx(r) if sel == nil else V2_Idx(sel[r])
		if val_mask != nil && (val_mask[phys >> 6] & (u64(1) << (phys & 63))) == 0 {
			continue
		}
		item_bytes := cast([^]u8)&out[base_row + r]
		field_ptr := cast(rawptr)&item_bytes[f.offset]
		b_ptr := &src[phys]
		n := int(v2_bytes_length(b_ptr))
		if n > 0 {
			dst_slice := nullable_slab[offset : offset + n]
			mem.copy(raw_data(dst_slice), v2_bytes_data(b_ptr), n)
			(cast(^Col_Type)field_ptr)^ = string(dst_slice) when Col_Type == string else dst_slice
			offset += n
		} else {
			(cast(^Col_Type)field_ptr)^ = empty_non_nil
		}
		if f.is_maybe {
			maybe_field_mark_present(field_ptr, f)
		}
	}
}

@(private = "file")
unmarshal_result_chunks_with_mapping :: proc(
	out_ptr: ^[dynamic]$T,
	res: V2_Result_Handle,
	active_fields: []Struct_Field_Mapping,
	col_to_field: []int,
	views: []V2_Vector_View,
	allocator: mem.Allocator,
	err: ^V2_Error_Info_Handle = nil,
) -> (out: [dynamic]T, rc: V2_Error) where intrinsics.type_is_struct(T) {
	out = out_ptr^
	defer out_ptr^ = out
	col_limit := len(col_to_field)

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

		base_row := len(out)
		n_rows := int(row_count)
		if base_row + n_rows > cap(out) {
			new_cap := max(cap(out) * 2, base_row + n_rows, 2048 if n_rows >= 2048 else 0)
			reserve(&out, new_cap)
		}
		#no_bounds_check {
			(^mem.Raw_Dynamic_Array)(&out).len = base_row + n_rows
			mem.zero_slice(out[base_row : base_row + n_rows])
		}

		// Column-major unmarshaling: switch on column type once per chunk instead of per row.
		for col_idx := 0; col_idx < col_limit; col_idx += 1 {
			field_idx := col_to_field[col_idx]
			if field_idx < 0 {
				continue
			}
			f := active_fields[field_idx]
			view := views[col_idx]

			if f.is_json {
				for r: V2_Idx = 0; r < row_count; r += 1 {
					if !v2_row_is_valid(view, r) {
						continue
					}
					phys := v2_sel_at(view.sel, r)
					item_bytes := cast([^]u8)&out[base_row + int(r)]
					field_ptr := cast(rawptr)&item_bytes[f.offset]
					b_ptr := &((cast([^]V2_Bytes)view.data)[phys])
					raw_json := v2_bytes_data(b_ptr)[:int(v2_bytes_length(b_ptr))]
					_, parsed_ok := unmarshal_json_fast(raw_json, 0, any{field_ptr, f.inner_type.id}, allocator)
					if !parsed_ok {
						jv, p_err := json.parse(raw_json, allocator = context.temp_allocator, parse_integers = true)
						parsed_ok = (p_err == .None) && assign_json_value_to_any(jv, any{field_ptr, f.inner_type.id}, allocator, true)
					}
					if !parsed_ok {
						return out, .TYPE_CONVERSION
					}
					if f.is_maybe {
						maybe_field_mark_present(field_ptr, f)
					}
				}
				continue
			}

			#partial switch f.type_id {
			case .BOOLEAN:   unmarshal_scalar_col(bool, view, out[:], base_row, n_rows, f)
			case .TINYINT:   unmarshal_scalar_col(i8, view, out[:], base_row, n_rows, f)
			case .SMALLINT:  unmarshal_scalar_col(i16, view, out[:], base_row, n_rows, f)
			case .INTEGER:   unmarshal_scalar_col(i32, view, out[:], base_row, n_rows, f)
			case .BIGINT:    unmarshal_scalar_col(i64, view, out[:], base_row, n_rows, f)
			case .UTINYINT:  unmarshal_scalar_col(u8, view, out[:], base_row, n_rows, f)
			case .USMALLINT: unmarshal_scalar_col(u16, view, out[:], base_row, n_rows, f)
			case .UINTEGER:  unmarshal_scalar_col(u32, view, out[:], base_row, n_rows, f)
			case .UBIGINT:   unmarshal_scalar_col(u64, view, out[:], base_row, n_rows, f)
			case .FLOAT:     unmarshal_scalar_col(f32, view, out[:], base_row, n_rows, f)
			case .DOUBLE:    unmarshal_scalar_col(f64, view, out[:], base_row, n_rows, f)
			case .HUGEINT:   unmarshal_scalar_col(V2_Hugeint, view, out[:], base_row, n_rows, f)
			case .UHUGEINT:  unmarshal_scalar_col(V2_Uhugeint, view, out[:], base_row, n_rows, f)
			case .INTERVAL:  unmarshal_scalar_col(V2_Interval, view, out[:], base_row, n_rows, f)
			case .VARCHAR:   unmarshal_bytes_col(string, view, out[:], base_row, n_rows, f, allocator)
			case .BLOB:      unmarshal_bytes_col([]u8, view, out[:], base_row, n_rows, f, allocator)
			}
		}
	}

	return out, .NONE
}
