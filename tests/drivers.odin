package duckdb_tests

// ============================================================================
// Layer 3: Protocol Drivers (`tests/drivers.odin`)
// ============================================================================
// Architecture Reference:
// - 4-Layer ATDD Architecture (Executable Specifications, DSL, Protocol Drivers, SUT)
// - Upstream C API v2 Driver Equivalents:
//   - `references/c/duckdb-capi-2.0/test/api/capi/v2/test_capi_v2.hpp` lines 51-94, 305-475
//   - `references/c/duckdb-capi-2.0/test/api/capi/v2/test_capi_v2_expression.cpp` lines 51-64 (`TwoCallString`)
//   - `references/c/duckdb-capi-2.0/tools/cpp/duckdb_cpp.cpp`
//   - `references/node/duckdb-node-neo/tools/capi-v2/smoke_v2.c`
// ============================================================================

import duckdb "../duckdb"
import "core:strings"

// Opens an instance under `env`, attaches `path` (`""` for `:memory:`), and makes it default.
// Mirrors `test_capi_v2::OpenInstance` in `references/c/duckdb-capi-2.0/test/api/capi/v2/test_capi_v2.hpp` lines 51-62.
driver_open_instance :: proc(
	env: duckdb.V2_Environment_Handle,
	path: string = "",
	out_instance: ^duckdb.V2_Instance_Handle,
	err: ^duckdb.V2_Error_Info_Handle = nil,
) -> duckdb.V2_Error {
	return duckdb.v2_open_instance(env, path, out_instance, err)
}

// Parses a single SQL statement from `sql` into `out_stmt`.
// Eliminates repeated `clone_to_cstring` -> `duckdb_v2_parse_sql` -> `duckdb_v2_statement_iterator_next` boilerplate.
driver_parse_single_stmt :: proc(
	conn: duckdb.V2_Connection_Handle,
	sql: string,
	out_stmt: ^duckdb.V2_Sql_Statement_Handle,
	err: ^duckdb.V2_Error_Info_Handle = nil,
) -> duckdb.V2_Error {
	return duckdb.v2_parse_single_stmt(conn, sql, out_stmt, err)
}

// Parses and executes a single SQL statement on `conn`, returning the streaming result handle.
// Mirrors `test_capi_v2::Query` in `references/c/duckdb-capi-2.0/test/api/capi/v2/test_capi_v2.hpp` lines 305-337.
driver_query :: proc(
	conn: duckdb.V2_Connection_Handle,
	sql: string,
	out_result: ^duckdb.V2_Result_Handle,
	err: ^duckdb.V2_Error_Info_Handle = nil,
) -> duckdb.V2_Error {
	return duckdb.v2_query(conn, sql, out_result, err)
}

// Executes a side-effecting SQL statement (DDL/DML) to completion via `duckdb_v2_result_drain`
// and reports the changed-row count.
// Mirrors `test_cpp_api_query.cpp` lines 67-84 (`conn.Execute(...).Drain()`).
driver_exec_drain :: proc(
	conn: duckdb.V2_Connection_Handle,
	sql: string,
	out_rows_changed: ^duckdb.V2_Idx = nil,
	err: ^duckdb.V2_Error_Info_Handle = nil,
) -> duckdb.V2_Error {
	return duckdb.v2_exec_drain(conn, sql, out_rows_changed, err)
}

// Steps a streaming `V2_Result_Handle` to its next chunk, blocking on `WAITING` via `duckdb_v2_result_wait`.
// Mirrors `test_capi_v2::StepChunk` in `references/c/duckdb-capi-2.0/test/api/capi/v2/test_capi_v2.hpp` lines 369-406.
driver_step_chunk :: proc(
	result: duckdb.V2_Result_Handle,
	out_chunk: ^duckdb.V2_Data_Chunk_Handle,
	err: ^duckdb.V2_Error_Info_Handle = nil,
) -> (status: duckdb.V2_Result_Step_Status, rc: duckdb.V2_Error) {
	return duckdb.v2_step_chunk(result, out_chunk, err)
}

// Generic two-call buffer sizing helper for C API v2 string rendering functions.
// Mirrors `ProbeText` / `RenderText` in `test_capi_v2_expression.cpp` lines 51-64 and `test_capi_v2.hpp` lines 160-182.
driver_two_call_string :: proc(
	subject: $H,
	render_fn: proc "c" (H, [^]u8, duckdb.V2_Idx, ^duckdb.V2_Idx, ^duckdb.V2_Error_Info_Handle) -> duckdb.V2_Error,
	allocator := context.temp_allocator,
) -> (text: string, rc: duckdb.V2_Error) {
	return duckdb.v2_two_call_string(subject, render_fn, nil, allocator)
}

// Formats a two-call `duckdb_v2_value_to_string` diagnostic string using `allocator`.
driver_render_value :: proc(
	val: duckdb.V2_Value_Handle,
	allocator := context.temp_allocator,
) -> (text: string, rc: duckdb.V2_Error) {
	is_null := false
	rc = duckdb.duckdb_v2_value_is_null(val, &is_null, nil)
	if rc == .NONE && is_null {
		return "NULL", .NONE
	}
	return driver_two_call_string(val, duckdb.duckdb_v2_value_to_string, allocator)
}

// Formats a two-call `duckdb_v2_logical_type_to_text` string using `allocator`.
driver_render_logical_type :: proc(
	type_handle: duckdb.V2_Logical_Type_Handle,
	allocator := context.temp_allocator,
) -> (text: string, rc: duckdb.V2_Error) {
	return driver_two_call_string(type_handle, duckdb.duckdb_v2_logical_type_to_text, allocator)
}

// Formats a two-call `duckdb_v2_qname_render` string using `allocator`.
driver_render_qname :: proc(
	qname: duckdb.V2_Qname_Handle,
	allocator := context.temp_allocator,
) -> (text: string, rc: duckdb.V2_Error) {
	return driver_two_call_string(qname, duckdb.duckdb_v2_qname_render, allocator)
}

// Formats a two-call `duckdb_v2_identifier_render_quoted` string using `allocator`.
driver_render_identifier_quoted :: proc(
	name: string,
	allocator := context.temp_allocator,
) -> (text: string, rc: duckdb.V2_Error) {
	id := duckdb.v2_str_from_string(name)
	return driver_two_call_string(&id, duckdb.duckdb_v2_identifier_render_quoted, allocator)
}

// Extracts and copies the error message from a `V2_Error_Info_Handle` and destroys the handle.
driver_consume_error_text :: proc(
	err: ^duckdb.V2_Error_Info_Handle,
	allocator := context.temp_allocator,
) -> (code: duckdb.V2_Error, message: string) {
	return duckdb.v2_consume_error_text(err, allocator)
}

// Parses a single SQL statement and prepares it on `conn`.
// Mirrors `Prepare` in `references/c/duckdb-capi-2.0/tools/cpp/tests/test_cpp_api_prepared_statement.cpp` lines 88-92.
driver_prepare :: proc(
	conn: duckdb.V2_Connection_Handle,
	sql: string,
	require_cacheable: bool = false,
	out_prepared: ^duckdb.V2_Prepared_Statement_Handle,
	err: ^duckdb.V2_Error_Info_Handle = nil,
) -> duckdb.V2_Error {
	return duckdb.v2_prepare(conn, sql, require_cacheable, out_prepared, err)
}

// Generic collector that drains all rows of column `col_idx` from `result` as `[]T` and destroys `result`.
driver_collect_column :: proc(
	$T: typeid,
	result: ^duckdb.V2_Result_Handle,
	col_idx: duckdb.V2_Idx = 0,
	allocator := context.temp_allocator,
) -> (rows: [dynamic]T, rc: duckdb.V2_Error) {
	rows = make([dynamic]T, allocator)
	defer duckdb.duckdb_v2_result_destroy(result)

	for {
		chunk: duckdb.V2_Data_Chunk_Handle
		status: duckdb.V2_Result_Step_Status
		status, rc = driver_step_chunk(result^, &chunk)
		if rc != .NONE || status == .FINISHED || status == .CANCELLED {
			break
		}
		if status == .CHUNK && chunk != nil {
			sz: duckdb.V2_Idx
			_ = duckdb.duckdb_v2_data_chunk_get_size(chunk, &sz, nil)
			vec: duckdb.V2_Vector_Handle
			_ = duckdb.duckdb_v2_data_chunk_get_vector(chunk, col_idx, &vec, nil)
			view: duckdb.V2_Vector_View
			_ = duckdb.v2_vector_get_readable_view(vec, &view, nil)
			data := cast([^]T)view.data
			for i: duckdb.V2_Idx = 0; i < sz; i += 1 {
				append(&rows, data[duckdb.v2_sel_at(view.sel, i)])
			}
			duckdb.duckdb_v2_data_chunk_destroy(&chunk)
		}
	}
	return rows, rc
}

// Builds a single-column `V2_Data_Chunk_Handle` of scalar type `T` populated with `vals`.
driver_make_chunk :: proc(
	$T: typeid,
	factory: duckdb.V2_Factory_Handle,
	col_type: duckdb.V2_Logical_Type_Handle,
	vals: []T,
	out_chunk: ^duckdb.V2_Data_Chunk_Handle,
	err: ^duckdb.V2_Error_Info_Handle = nil,
) -> duckdb.V2_Error {
	types := [1]duckdb.V2_Logical_Type_Handle{col_type}
	rc := duckdb.duckdb_v2_data_chunk_create(factory, &types[0], 1, out_chunk, err)
	if rc != .NONE {
		return rc
	}
	vec: duckdb.V2_Vector_Handle
	rc = duckdb.duckdb_v2_data_chunk_get_vector(out_chunk^, 0, &vec, err)
	if rc != .NONE {
		return rc
	}
	rc = duckdb.duckdb_v2_vector_set_size(vec, duckdb.V2_Idx(len(vals)), err)
	if rc != .NONE {
		return rc
	}
	if len(vals) > 0 {
		raw: rawptr
		rc = duckdb.duckdb_v2_vector_get_data_mutable(vec, &raw, err)
		if rc != .NONE {
			return rc
		}
		data := cast([^]T)raw
		for v, idx in vals {
			data[idx] = v
		}
	}
	return .NONE
}

// Builds and populates a single-column `V2_Column_Data_Collection_Handle` of scalar type `T`.
driver_make_collection :: proc(
	$T: typeid,
	factory: duckdb.V2_Factory_Handle,
	col_type: duckdb.V2_Logical_Type_Handle,
	vals: []T,
	out_collection: ^duckdb.V2_Column_Data_Collection_Handle,
	err: ^duckdb.V2_Error_Info_Handle = nil,
) -> duckdb.V2_Error {
	types := [1]duckdb.V2_Logical_Type_Handle{col_type}
	rc := duckdb.duckdb_v2_column_data_collection_create(factory, &types[0], 1, out_collection, err)
	if rc != .NONE {
		return rc
	}
	if len(vals) == 0 {
		return .NONE
	}

	chunk: duckdb.V2_Data_Chunk_Handle
	rc = driver_make_chunk(T, factory, col_type, vals, &chunk, err)
	if rc != .NONE {
		duckdb.duckdb_v2_column_data_collection_destroy(out_collection)
		return rc
	}
	defer duckdb.duckdb_v2_data_chunk_destroy(&chunk)

	append_state: duckdb.V2_Column_Data_Collection_Append_State_Handle
	rc = duckdb.duckdb_v2_column_data_collection_append_state_create(out_collection^, &append_state, err)
	if rc != .NONE {
		duckdb.duckdb_v2_column_data_collection_destroy(out_collection)
		return rc
	}
	defer duckdb.duckdb_v2_column_data_collection_append_state_destroy(&append_state)

	rc = duckdb.duckdb_v2_column_data_collection_append(out_collection^, append_state, chunk, err)
	if rc != .NONE {
		duckdb.duckdb_v2_column_data_collection_destroy(out_collection)
	}
	return rc
}

// Drains a single-column `V2_Column_Data_Collection_Handle` of scalar type `T` through one shared + worker scan state.
driver_scan_collection :: proc(
	$T: typeid,
	factory: duckdb.V2_Factory_Handle,
	col_type: duckdb.V2_Logical_Type_Handle,
	collection: duckdb.V2_Column_Data_Collection_Handle,
	allocator := context.temp_allocator,
) -> (out: [dynamic]T, rc: duckdb.V2_Error) {
	out = make([dynamic]T, allocator)

	shared: duckdb.V2_Column_Data_Collection_Shared_Scan_State_Handle
	rc = duckdb.duckdb_v2_column_data_collection_shared_scan_state_create(collection, &shared, nil)
	if rc != .NONE {
		return out, rc
	}
	defer duckdb.duckdb_v2_column_data_collection_shared_scan_state_destroy(&shared)

	worker: duckdb.V2_Column_Data_Collection_Worker_Scan_State_Handle
	rc = duckdb.duckdb_v2_column_data_collection_worker_scan_state_create(collection, &worker, nil)
	if rc != .NONE {
		return out, rc
	}
	defer duckdb.duckdb_v2_column_data_collection_worker_scan_state_destroy(&worker)

	chunk: duckdb.V2_Data_Chunk_Handle
	rc = driver_make_chunk(T, factory, col_type, nil, &chunk)
	if rc != .NONE {
		return out, rc
	}
	defer duckdb.duckdb_v2_data_chunk_destroy(&chunk)

	for {
		did_produce := false
		rc = duckdb.duckdb_v2_column_data_collection_scan(collection, shared, worker, chunk, &did_produce, nil)
		if rc != .NONE || !did_produce {
			break
		}
		sz: duckdb.V2_Idx
		_ = duckdb.duckdb_v2_data_chunk_get_size(chunk, &sz, nil)
		vec: duckdb.V2_Vector_Handle
		_ = duckdb.duckdb_v2_data_chunk_get_vector(chunk, 0, &vec, nil)
		view: duckdb.V2_Vector_View
		_ = duckdb.v2_vector_get_readable_view(vec, &view, nil)
		data := cast([^]T)view.data
		for i: duckdb.V2_Idx = 0; i < sz; i += 1 {
			append(&out, data[duckdb.v2_sel_at(view.sel, i)])
		}
	}
	return out, rc
}

// Parses a single SQL statement and executes it as an Arrow streaming result (`duckdb_v2_statement_execute_arrow`).
// Mirrors `QueryArrow` in `references/c/duckdb-capi-2.0/test/api/capi/v2/test_capi_v2_arrow.cpp`.
driver_query_arrow :: proc(
	conn: duckdb.V2_Connection_Handle,
	sql: string,
	batch_size: duckdb.V2_Idx = 0,
	out_result: ^duckdb.V2_Arrow_Result_Handle,
	err: ^duckdb.V2_Error_Info_Handle = nil,
) -> duckdb.V2_Error {
	if out_result != nil {
		out_result^ = nil
	}
	stmt: duckdb.V2_Sql_Statement_Handle
	rc := driver_parse_single_stmt(conn, sql, &stmt, err)
	if rc != .NONE || stmt == nil {
		return rc
	}
	defer duckdb.duckdb_v2_sql_statement_destroy(&stmt)

	return duckdb.duckdb_v2_statement_execute_arrow(conn, stmt, nil, nil, 0, batch_size, out_result, err)
}

// Sets a callback error code + message on `err`.
// Mirrors `test_capi_v2::SetError` in `references/c/duckdb-capi-2.0/test/api/capi/v2/test_capi_v2.hpp` lines 153-158.
driver_set_callback_error :: proc "contextless" (
	err: ^duckdb.V2_Error_Info_Handle,
	code: duckdb.V2_Error,
	msg: string,
) {
	if err == nil || err^ == nil {
		return
	}
	_ = duckdb.duckdb_v2_error_info_set_code(err^, code)
	s := duckdb.v2_str_from_string(msg)
	_ = duckdb.duckdb_v2_error_info_set_text(err^, &s)
}
