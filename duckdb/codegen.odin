package duckdb

// ============================================================================
// Layer 3: Schema Introspection & Odin Struct Codegen (`duckdb/codegen.odin`)
// ============================================================================
// Red-First Stubs (implementation saved in commit `036eef4`, reverted while finalizing ATDD test suite)
// ============================================================================

Column_Schema :: struct {
	name:     string,
	sql_type: string,
	type_id:  V2_Logical_Type_Id,
	nullable: bool,
}

introspect_table_schema :: proc(
	conn: V2_Connection_Handle,
	table_or_source: string,
	allocator := context.allocator,
	err: ^V2_Error_Info_Handle = nil,
) -> (cols: [dynamic]Column_Schema, rc: V2_Error) {
	return make([dynamic]Column_Schema, allocator), .QUERY_NOT_IMPLEMENTED
}

duckdb_type_id_to_odin_type :: proc(type_id: V2_Logical_Type_Id) -> string {
	return ""
}

generate_odin_struct_code :: proc(
	package_name: string,
	struct_name: string,
	columns: []Column_Schema,
	allocator := context.temp_allocator,
) -> string {
	return ""
}
