package duckdb

import "core:c"
import "core:fmt"
import "core:strings"

when ODIN_OS == .Linux || ODIN_OS == .Darwin {
	foreign import libduckdb "system:duckdb"
} else when ODIN_OS == .Windows {
	foreign import libduckdb "duckdb.lib"
}

// ============================================================================
// Low-Level C API Types (/usr/include/duckdb.h)
// ============================================================================

duckdb_state :: enum c.int {
	DuckDBSuccess = 0,
	DuckDBError   = 1,
}

duckdb_type :: enum c.int {
	DUCKDB_TYPE_INVALID      = 0,
	DUCKDB_TYPE_BOOLEAN      = 1,
	DUCKDB_TYPE_TINYINT      = 2,
	DUCKDB_TYPE_SMALLINT     = 3,
	DUCKDB_TYPE_INTEGER      = 4,
	DUCKDB_TYPE_BIGINT       = 5,
	DUCKDB_TYPE_UTINYINT     = 6,
	DUCKDB_TYPE_USMALLINT    = 7,
	DUCKDB_TYPE_UINTEGER     = 8,
	DUCKDB_TYPE_UBIGINT      = 9,
	DUCKDB_TYPE_FLOAT        = 10,
	DUCKDB_TYPE_DOUBLE       = 11,
	DUCKDB_TYPE_TIMESTAMP    = 12,
	DUCKDB_TYPE_DATE         = 13,
	DUCKDB_TYPE_TIME         = 14,
	DUCKDB_TYPE_INTERVAL     = 15,
	DUCKDB_TYPE_HUGEINT      = 16,
	DUCKDB_TYPE_VARCHAR      = 17,
	DUCKDB_TYPE_BLOB         = 18,
	DUCKDB_TYPE_DECIMAL      = 19,
	DUCKDB_TYPE_TIMESTAMP_S  = 20,
	DUCKDB_TYPE_TIMESTAMP_MS = 21,
	DUCKDB_TYPE_TIMESTAMP_NS = 22,
	DUCKDB_TYPE_ENUM         = 23,
	DUCKDB_TYPE_LIST         = 24,
	DUCKDB_TYPE_STRUCT       = 25,
	DUCKDB_TYPE_MAP          = 26,
	DUCKDB_TYPE_UUID         = 27,
	DUCKDB_TYPE_UNION        = 28,
	DUCKDB_TYPE_BIT          = 29,
	DUCKDB_TYPE_TIME_TZ      = 30,
	DUCKDB_TYPE_TIMESTAMP_TZ = 31,
	DUCKDB_TYPE_UHUGEINT     = 32,
	DUCKDB_TYPE_ARRAY        = 33,
	DUCKDB_TYPE_ANY          = 34,
	DUCKDB_TYPE_VARINT       = 35,
	DUCKDB_TYPE_SQLNULL      = 36,
}

duckdb_database :: distinct rawptr
duckdb_connection :: distinct rawptr
duckdb_config :: distinct rawptr
duckdb_prepared_statement :: distinct rawptr
duckdb_appender :: distinct rawptr
duckdb_data_chunk :: distinct rawptr
duckdb_vector :: distinct rawptr
duckdb_logical_type :: distinct rawptr

// CRITICAL: Field order MUST match /usr/include/duckdb.h exactly.
duckdb_result :: struct {
	deprecated_column_count:  u64,
	deprecated_row_count:     u64,
	deprecated_rows_changed:  u64,
	deprecated_columns:       rawptr,
	deprecated_error_message: cstring,
	internal_data:            rawptr,
}

// DuckDB inline/pointer string representation in vectorized data chunks (16 bytes)
duckdb_string_t :: V2_Bytes

@(default_calling_convention = "c")
foreign libduckdb {
	// Database & Connection Lifecycle
	duckdb_open :: proc(path: cstring, out_database: ^duckdb_database) -> duckdb_state ---
	duckdb_open_ext :: proc(path: cstring, out_database: ^duckdb_database, config: duckdb_config, out_error: ^cstring) -> duckdb_state ---
	duckdb_close :: proc(database: ^duckdb_database) ---
	duckdb_connect :: proc(database: duckdb_database, out_connection: ^duckdb_connection) -> duckdb_state ---
	duckdb_disconnect :: proc(connection: ^duckdb_connection) ---
	duckdb_library_version :: proc() -> cstring ---

	// Configuration
	duckdb_create_config :: proc(out_config: ^duckdb_config) -> duckdb_state ---
	duckdb_set_config :: proc(config: duckdb_config, name: cstring, option: cstring) -> duckdb_state ---
	duckdb_destroy_config :: proc(config: ^duckdb_config) ---

	// Query Execution & Result Inspection
	duckdb_query :: proc(connection: duckdb_connection, query: cstring, out_result: ^duckdb_result) -> duckdb_state ---
	duckdb_destroy_result :: proc(result: ^duckdb_result) ---
	duckdb_column_name :: proc(result: ^duckdb_result, col: u64) -> cstring ---
	duckdb_column_type :: proc(result: ^duckdb_result, col: u64) -> duckdb_type ---
	duckdb_column_count :: proc(result: ^duckdb_result) -> u64 ---
	duckdb_row_count :: proc(result: ^duckdb_result) -> u64 ---
	duckdb_rows_changed :: proc(result: ^duckdb_result) -> u64 ---
	duckdb_result_error :: proc(result: ^duckdb_result) -> cstring ---
	duckdb_value_varchar :: proc(result: ^duckdb_result, col: u64, row: u64) -> cstring ---
	duckdb_value_int64 :: proc(result: ^duckdb_result, col: u64, row: u64) -> i64 ---
	duckdb_value_double :: proc(result: ^duckdb_result, col: u64, row: u64) -> f64 ---
	duckdb_value_boolean :: proc(result: ^duckdb_result, col: u64, row: u64) -> bool ---
	duckdb_value_is_null :: proc(result: ^duckdb_result, col: u64, row: u64) -> bool ---
	duckdb_free :: proc(ptr: rawptr) ---

	// Vectorized Data Chunk API
	duckdb_fetch_chunk :: proc(result: duckdb_result) -> duckdb_data_chunk ---
	duckdb_destroy_data_chunk :: proc(chunk: ^duckdb_data_chunk) ---
	duckdb_data_chunk_get_column_count :: proc(chunk: duckdb_data_chunk) -> u64 ---
	duckdb_data_chunk_get_size :: proc(chunk: duckdb_data_chunk) -> u64 ---
	duckdb_data_chunk_get_vector :: proc(chunk: duckdb_data_chunk, col_idx: u64) -> duckdb_vector ---
	duckdb_vector_get_data :: proc(vector: duckdb_vector) -> rawptr ---
	duckdb_vector_get_validity :: proc(vector: duckdb_vector) -> [^]u64 ---

	// Prepared Statements
	duckdb_prepare :: proc(connection: duckdb_connection, query: cstring, out_prepared_statement: ^duckdb_prepared_statement) -> duckdb_state ---
	duckdb_destroy_prepare :: proc(prepared_statement: ^duckdb_prepared_statement) ---
	duckdb_prepare_error :: proc(prepared_statement: duckdb_prepared_statement) -> cstring ---
	duckdb_bind_boolean :: proc(prepared_statement: duckdb_prepared_statement, param_idx: u64, val: bool) -> duckdb_state ---
	duckdb_bind_int64 :: proc(prepared_statement: duckdb_prepared_statement, param_idx: u64, val: i64) -> duckdb_state ---
	duckdb_bind_double :: proc(prepared_statement: duckdb_prepared_statement, param_idx: u64, val: f64) -> duckdb_state ---
	duckdb_bind_varchar :: proc(prepared_statement: duckdb_prepared_statement, param_idx: u64, val: cstring) -> duckdb_state ---
	duckdb_bind_null :: proc(prepared_statement: duckdb_prepared_statement, param_idx: u64) -> duckdb_state ---
	duckdb_execute_prepared :: proc(prepared_statement: duckdb_prepared_statement, out_result: ^duckdb_result) -> duckdb_state ---

	// Appender API (Bulk Ingestion)
	duckdb_appender_create :: proc(connection: duckdb_connection, schema: cstring, table: cstring, out_appender: ^duckdb_appender) -> duckdb_state ---
	duckdb_appender_destroy :: proc(appender: ^duckdb_appender) -> duckdb_state ---
	duckdb_appender_error :: proc(appender: duckdb_appender) -> cstring ---
	duckdb_appender_flush :: proc(appender: duckdb_appender) -> duckdb_state ---
	duckdb_appender_close :: proc(appender: duckdb_appender) -> duckdb_state ---
	duckdb_appender_end_row :: proc(appender: duckdb_appender) -> duckdb_state ---
	duckdb_append_bool :: proc(appender: duckdb_appender, value: bool) -> duckdb_state ---
	duckdb_append_int64 :: proc(appender: duckdb_appender, value: i64) -> duckdb_state ---
	duckdb_append_double :: proc(appender: duckdb_appender, value: f64) -> duckdb_state ---
	duckdb_append_varchar :: proc(appender: duckdb_appender, val: cstring) -> duckdb_state ---
	duckdb_append_null :: proc(appender: duckdb_appender) -> duckdb_state ---
}

// ============================================================================
// High-Level Odin Wrappers & SQL Escaping Helpers
// ============================================================================

Database :: struct {
	db:   duckdb_database,
	conn: duckdb_connection,
	path: string,
}

open :: proc(path: string = "", low_memory: bool = false) -> (Database, string, bool) {
	d: Database
	d.path = path
	c_path: cstring = nil
	if len(path) > 0 {
		c_path = strings.clone_to_cstring(path, context.temp_allocator)
	}

	if duckdb_open(c_path, &d.db) != .DuckDBSuccess {
		return d, fmt.tprintf("Failed to open DuckDB database: %s", path), false
	}
	if duckdb_connect(d.db, &d.conn) != .DuckDBSuccess {
		duckdb_close(&d.db)
		return d, "Failed to connect to DuckDB database", false
	}

	if low_memory {
		exec(&d, "SET memory_limit = '256MB'; SET threads = 2; SET preserve_insertion_order = false;")
	}
	return d, "", true
}

close :: proc(d: ^Database) {
	if d.conn != nil {
		duckdb_disconnect(&d.conn)
		d.conn = nil
	}
	if d.db != nil {
		duckdb_close(&d.db)
		d.db = nil
	}
}

exec :: proc(d: ^Database, sql: string) -> (string, bool) {
	c_sql := strings.clone_to_cstring(sql, context.temp_allocator)
	res: duckdb_result
	state := duckdb_query(d.conn, c_sql, &res)
	defer duckdb_destroy_result(&res)

	if state != .DuckDBSuccess {
		err_c := duckdb_result_error(&res)
		err_msg := err_c != nil ? string(err_c) : "DuckDB execution error"
		return strings.clone(err_msg, context.temp_allocator), false
	}
	return "", true
}

// Escape single quotes for safe SQL string literal embedding (`'` -> `''`)
sql_escape :: proc(s: string, allocator := context.temp_allocator) -> string {
	if strings.index_byte(s, '\'') < 0 {
		return s
	}
	res, _ := strings.replace_all(s, "'", "''", allocator)
	return res
}

// Writes `s` into `b` with single quotes escaped (`'` -> `''`) without intermediate allocations.
write_sql_escaped :: #force_inline proc(b: ^strings.Builder, s: string) {
	rem := s
	for {
		idx := strings.index_byte(rem, '\'')
		if idx < 0 {
			strings.write_string(b, rem)
			return
		}
		strings.write_string(b, rem[:idx])
		strings.write_string(b, "''")
		rem = rem[idx + 1:]
	}
}
