package duckdb

// ============================================================================
// Layer 1: `core:reflect` Struct Tag Mapping & Bulk Appender (`duckdb/reflect.odin`)
// ============================================================================
// Red-First Stubs (implementation saved in commit `036eef4`, reverted while finalizing ATDD test suite)
// ============================================================================

import "base:intrinsics"

create_table_sql :: proc(
	$T: typeid,
	table_name: string,
	if_not_exists := true,
	allocator := context.temp_allocator,
) -> string where intrinsics.type_is_struct(T) {
	return ""
}

append_slice :: proc(
	conn: V2_Connection_Handle,
	table_name: string,
	rows: []$T,
	err: ^V2_Error_Info_Handle = nil,
) -> V2_Error where intrinsics.type_is_struct(T) {
	return .QUERY_NOT_IMPLEMENTED
}

query_as :: proc(
	conn: V2_Connection_Handle,
	$T: typeid,
	sql: string,
	allocator := context.allocator,
	err: ^V2_Error_Info_Handle = nil,
) -> (out: [dynamic]T, rc: V2_Error) where intrinsics.type_is_struct(T) {
	return make([dynamic]T, allocator), .QUERY_NOT_IMPLEMENTED
}
