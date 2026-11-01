package duckdb_tests

// ============================================================================
// Layer 1: Executable Specifications (`tests/copy_filesystem_v2_spec.odin`)
// ============================================================================
// Direct ATDD port of the C API v2 FileSystem, FileHandle & CopyFunction suites:
// 1. `references/c/duckdb-capi-2.0/tools/cpp/tests/test_cpp_api_file_system.cpp`
//    & `references/c/duckdb-capi-2.0/test/api/capi/v2/test_capi_v2_file_system.cpp`
// 2. `references/c/duckdb-capi-2.0/tools/cpp/tests/test_cpp_api_copy_function.cpp`
//    & `references/c/duckdb-capi-2.0/test/api/capi/v2/test_capi_v2_copy_function.cpp`
// ============================================================================

import "base:runtime"
import "core:os"
import "core:testing"
import duckdb "../duckdb"

// ----------------------------------------------------------------------------
// 1. FileSystem, FileOpenOptions & FileHandle (`test_cpp_api_file_system.cpp`)
// ----------------------------------------------------------------------------

Glob_Collector :: struct {
	count: int,
}

@(private = "file")
fs_glob_cb :: proc "c" (path: ^duckdb.V2_Str, user_data: rawptr, err: ^duckdb.V2_Error_Info_Handle) {
	if user_data != nil && path != nil && path.len > 0 {
		(cast(^Glob_Collector)user_data).count += 1
	}
}

@(private = "file")
fs_expand_sink_cb :: proc "c" (text: ^duckdb.V2_Str, user_data: rawptr, err: ^duckdb.V2_Error_Info_Handle) {
	if user_data != nil && text != nil {
		(cast(^duckdb.V2_Idx)user_data)^ = text.len
	}
}

@(test)
spec_v2_file_system_file_handle_and_open_options :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)

	_ = os.make_directory(".tmp")
	path_a := ".tmp/odin_v2_fs_test_a.bin"
	path_b := ".tmp/odin_v2_fs_test_b.bin"
	defer {
		_ = os.remove(path_a)
		_ = os.remove(path_b)
	}

	fs_conn, fs_inst: duckdb.V2_File_System_Handle
	expect_v2_ok(t, duckdb.duckdb_v2_connection_get_file_system(fx.conn, &fs_conn, &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.duckdb_v2_instance_get_file_system(fx.instance, &fs_inst, &fx.err), &fx.err)
	testing.expect(t, fs_conn != nil && fs_inst != nil)

	// Remove any stale test artifacts first:
	pa_str := duckdb.v2_str_from_string(path_a)
	pb_str := duckdb.v2_str_from_string(path_b)
	removed := false
	expect_v2_ok(t, duckdb.duckdb_v2_file_system_path_remove(fs_conn, &pa_str, &removed, &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.duckdb_v2_file_system_path_remove(fs_conn, &pb_str, &removed, &fx.err), &fx.err)

	// 1. Write, Tell, Size, Sync, Close, Destroy (`test_cpp_api_file_system.cpp` lines 31-54):
	{
		opts: duckdb.V2_File_Open_Options_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_file_open_options_create(fs_conn, &opts, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_file_open_options_destroy(&opts)

		// Invalid flag is rejected with `INPUT_INVALID`:
		expect_v2_error(
			t,
			duckdb.duckdb_v2_file_open_options_set_flag(opts, .INVALID, &fx.err),
			.INPUT_INVALID,
			&fx.err,
		)

		expect_v2_ok(t, duckdb.duckdb_v2_file_open_options_set_flag(opts, .WRITE, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_file_open_options_set_flag(opts, .CREATE_NEW, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_file_open_options_set_flag(opts, .PARALLEL_ACCESS, &fx.err), &fx.err)

		file: duckdb.V2_File_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_file_system_open(fs_conn, &pa_str, opts, &file, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_file_destroy(&file)

		payload := "hello world"
		written: duckdb.V2_Idx
		expect_v2_ok(
			t,
			duckdb.duckdb_v2_file_write(file, raw_data(payload), duckdb.V2_Idx(len(payload)), &written, &fx.err),
			&fx.err,
		)
		testing.expect_value(t, written, duckdb.V2_Idx(11))

		pos, sz: duckdb.V2_Idx
		expect_v2_ok(t, duckdb.duckdb_v2_file_tell(file, &pos, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_file_size(file, &sz, &fx.err), &fx.err)
		testing.expect_value(t, pos, duckdb.V2_Idx(11))
		testing.expect_value(t, sz, duckdb.V2_Idx(11))

		// Positional `write_at` overwrites "world" with "DUCKS" without moving `tell`:
		patch := "DUCKS"
		expect_v2_ok(t, duckdb.duckdb_v2_file_write_at(file, raw_data(patch), 5, 6, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_file_sync(file, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_file_close(file, &fx.err), &fx.err)
	}

	// 2. Read, Seek, ReadAt (`test_cpp_api_file_system.cpp` lines 45-54, 134-160):
	{
		ro_opts: duckdb.V2_File_Open_Options_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_file_open_options_create(fs_inst, &ro_opts, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_file_open_options_destroy(&ro_opts)
		expect_v2_ok(t, duckdb.duckdb_v2_file_open_options_set_flag(ro_opts, .READ, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_file_open_options_set_flag(ro_opts, .PARALLEL_ACCESS, &fx.err), &fx.err)

		file: duckdb.V2_File_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_file_system_open(fs_inst, &pa_str, ro_opts, &file, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_file_destroy(&file)

		buf: [16]u8
		n_read: duckdb.V2_Idx
		expect_v2_ok(t, duckdb.duckdb_v2_file_read(file, &buf[0], 16, &n_read, &fx.err), &fx.err)
		testing.expect_value(t, n_read, duckdb.V2_Idx(11))
		testing.expect_value(t, string(buf[:n_read]), "hello DUCKS")

		expect_v2_ok(t, duckdb.duckdb_v2_file_seek(file, 6, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_file_read(file, &buf[0], 5, &n_read, &fx.err), &fx.err)
		testing.expect_value(t, string(buf[:5]), "DUCKS")

		at_buf: [5]u8
		expect_v2_ok(t, duckdb.duckdb_v2_file_read_at(file, &at_buf[0], 5, 0, &fx.err), &fx.err)
		testing.expect_value(t, string(at_buf[:]), "hello")
	}

	// 3. Exists, IsRemote, Expand, Glob, Move, Remove (`test_cpp_api_file_system.cpp` lines 162-292):
	{
		exists := false
		expect_v2_ok(t, duckdb.duckdb_v2_file_system_path_exists(fs_conn, &pa_str, &exists, &fx.err), &fx.err)
		testing.expect(t, exists)

		local_rem, s3_rem := true, false
		s3_str := duckdb.v2_str_from_string("s3://bucket/object.parquet")
		expect_v2_ok(t, duckdb.duckdb_v2_file_system_path_is_remote(fs_conn, &pa_str, &local_rem, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_file_system_path_is_remote(fs_conn, &s3_str, &s3_rem, &fx.err), &fx.err)
		testing.expect(t, !local_rem && s3_rem)

		expanded_len: duckdb.V2_Idx
		expect_v2_ok(
			t,
			duckdb.duckdb_v2_file_system_path_expand(fs_conn, &pa_str, fs_expand_sink_cb, &expanded_len, &fx.err),
			&fx.err,
		)
		testing.expect_value(t, expanded_len, duckdb.V2_Idx(len(path_a)))

		glob_pat := duckdb.v2_str_from_string(".tmp/odin_v2_fs_test_*.bin")
		glob_col := Glob_Collector{}
		expect_v2_ok(
			t,
			duckdb.duckdb_v2_file_system_path_glob(fs_conn, &glob_pat, fs_glob_cb, &glob_col, &fx.err),
			&fx.err,
		)
		testing.expect_value(t, glob_col.count, 1)

		expect_v2_ok(t, duckdb.duckdb_v2_file_system_path_move(fs_conn, &pa_str, &pb_str, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_file_system_path_exists(fs_conn, &pb_str, &exists, &fx.err), &fx.err)
		testing.expect(t, exists)

		expect_v2_ok(t, duckdb.duckdb_v2_file_system_path_remove(fs_conn, &pb_str, &removed, &fx.err), &fx.err)
		testing.expect(t, removed)
	}
}

// ----------------------------------------------------------------------------
// 2. CopyFunction (`COPY ... TO` & `COPY ... FROM`, `test_cpp_api_copy_function.cpp`)
// ----------------------------------------------------------------------------

Copy_Sink_State :: struct {
	bind_cols:      duckdb.V2_Idx,
	init_called:    bool,
	batches_taken:  duckdb.V2_Idx,
	flushed_rows:   duckdb.V2_Idx,
	finalized:      bool,
	from_rows_goal: i64,
	from_cursor:    i64,
}

@(private = "file")
copy_to_bind_cb :: proc "c" (
	info: duckdb.V2_Copy_To_Bind_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	ud: rawptr
	if duckdb.duckdb_v2_copy_to_bind_get_user_data(info, &ud, err) != .NONE || ud == nil {
		return
	}
	st := cast(^Copy_Sink_State)ud
	_ = duckdb.duckdb_v2_copy_to_bind_get_column_count(info, &st.bind_cols, err)
	bd := duckdb.V2_Opaque{ptr = st}
	_ = duckdb.duckdb_v2_copy_to_bind_set_bind_data(info, &bd, err)
}

@(private = "file")
copy_to_batch_size_cb :: proc "c" (
	info: duckdb.V2_Copy_To_Batch_Size_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	_ = duckdb.duckdb_v2_copy_to_batch_size_set_target(info, 1024, err)
}

@(private = "file")
copy_to_init_cb :: proc "c" (
	info: duckdb.V2_Copy_To_Init_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	bd: rawptr
	if duckdb.duckdb_v2_copy_to_init_get_bind_data(info, &bd, err) != .NONE || bd == nil {
		return
	}
	st := cast(^Copy_Sink_State)bd
	st.init_called = true
	id := duckdb.V2_Opaque{ptr = st}
	_ = duckdb.duckdb_v2_copy_to_init_set_init_data(info, &id, err)
}

@(private = "file")
copy_to_batch_cb :: proc "c" (
	info: duckdb.V2_Copy_To_Batch_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	id: rawptr
	if duckdb.duckdb_v2_copy_to_batch_get_init_data(info, &id, err) != .NONE || id == nil {
		return
	}
	st := cast(^Copy_Sink_State)id
	st.batches_taken += 1

	coll: duckdb.V2_Column_Data_Collection_Handle
	if duckdb.duckdb_v2_copy_to_batch_take_input(info, &coll, err) != .NONE {
		return
	}
	rows: duckdb.V2_Idx
	_ = duckdb.duckdb_v2_column_data_collection_row_count(coll, &rows, err)
	duckdb.duckdb_v2_column_data_collection_destroy(&coll)

	// Pass row count in `batch_data.ptr` as `uintptr`:
	batch_op := duckdb.V2_Opaque{ptr = rawptr(uintptr(rows))}
	_ = duckdb.duckdb_v2_copy_to_batch_set_batch_data(info, &batch_op, err)
}

@(private = "file")
copy_to_flush_cb :: proc "c" (
	info: duckdb.V2_Copy_To_Flush_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	id, batch_ptr: rawptr
	if duckdb.duckdb_v2_copy_to_flush_get_init_data(info, &id, err) != .NONE || id == nil {
		return
	}
	_ = duckdb.duckdb_v2_copy_to_flush_get_batch_data(info, &batch_ptr, err)
	st := cast(^Copy_Sink_State)id
	st.flushed_rows += duckdb.V2_Idx(uintptr(batch_ptr))
}

@(private = "file")
copy_to_finalize_cb :: proc "c" (
	info: duckdb.V2_Copy_To_Finalize_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	id: rawptr
	if duckdb.duckdb_v2_copy_to_finalize_get_init_data(info, &id, err) != .NONE || id == nil {
		return
	}
	(cast(^Copy_Sink_State)id).finalized = true
}

@(private = "file")
copy_from_bind_cb :: proc "c" (
	info: duckdb.V2_Copy_From_Bind_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	ud: rawptr
	if duckdb.duckdb_v2_copy_from_bind_get_user_data(info, &ud, err) != .NONE || ud == nil {
		return
	}
	st := cast(^Copy_Sink_State)ud
	st.from_cursor = 0
	_ = duckdb.duckdb_v2_copy_from_bind_set_cardinality(info, duckdb.V2_Idx(st.from_rows_goal), true, err)
	bd := duckdb.V2_Opaque{ptr = st}
	_ = duckdb.duckdb_v2_copy_from_bind_set_bind_data(info, &bd, err)
}

@(private = "file")
copy_from_init_global_cb :: proc "c" (
	info: duckdb.V2_Copy_From_Init_Global_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	bd: rawptr
	_ = duckdb.duckdb_v2_copy_from_init_global_get_bind_data(info, &bd, err)
	gd := duckdb.V2_Opaque{ptr = bd}
	_ = duckdb.duckdb_v2_copy_from_init_global_set_global_state(info, &gd, err)
	_ = duckdb.duckdb_v2_copy_from_init_global_set_max_threads(info, 1, err)
}

@(private = "file")
copy_from_exec_cb :: proc "c" (
	info: duckdb.V2_Copy_From_Exec_Info_Handle,
	ctx: duckdb.V2_Context_Handle,
	err: ^duckdb.V2_Error_Info_Handle,
) {
	gd: rawptr
	if duckdb.duckdb_v2_copy_from_exec_get_global_state(info, &gd, err) != .NONE || gd == nil {
		return
	}
	st := cast(^Copy_Sink_State)gd
	chunk: duckdb.V2_Data_Chunk_Handle
	if duckdb.duckdb_v2_copy_from_exec_get_output_chunk(info, &chunk, err) != .NONE {
		return
	}
	vec: duckdb.V2_Vector_Handle
	if duckdb.duckdb_v2_data_chunk_get_vector(chunk, 0, &vec, err) != .NONE {
		return
	}

	remaining := st.from_rows_goal - st.from_cursor
	if remaining <= 0 {
		_ = duckdb.duckdb_v2_vector_set_size(vec, 0, err)
		return
	}
	raw: rawptr
	if duckdb.duckdb_v2_vector_get_data_mutable(vec, &raw, err) != .NONE {
		return
	}
	out := cast([^]i64)raw
	for i: i64 = 0; i < remaining; i += 1 {
		out[i] = (st.from_cursor + i + 1) * 100
	}
	st.from_cursor += remaining
	_ = duckdb.duckdb_v2_vector_set_size(vec, duckdb.V2_Idx(remaining), err)
}

@(test)
spec_v2_copy_to_and_copy_from_custom_callbacks :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)

	state := Copy_Sink_State{from_rows_goal = 3}
	fn: duckdb.V2_Copy_Function_Handle
	expect_v2_ok(t, duckdb.duckdb_v2_copy_function_create(fx.factory, &fn, &fx.err), &fx.err)
	defer duckdb.duckdb_v2_copy_function_destroy(&fn)

	fn_name := duckdb.v2_str_from_string("odin_copy_fmt")
	ext_name := duckdb.v2_str_from_string("odincopy")
	ud := duckdb.V2_Opaque{ptr = &state}
	expect_v2_ok(t, duckdb.duckdb_v2_copy_function_set_name(fn, &fn_name, &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.duckdb_v2_copy_function_set_file_extension(fn, &ext_name, &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.duckdb_v2_copy_function_set_user_data(fn, &ud, &fx.err), &fx.err)

	expect_v2_ok(t, duckdb.duckdb_v2_copy_to_set_bind_callback(fn, copy_to_bind_cb, &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.duckdb_v2_copy_to_set_batch_size_callback(fn, copy_to_batch_size_cb, &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.duckdb_v2_copy_to_set_init_callback(fn, copy_to_init_cb, &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.duckdb_v2_copy_to_set_batch_callback(fn, copy_to_batch_cb, &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.duckdb_v2_copy_to_set_flush_callback(fn, copy_to_flush_cb, &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.duckdb_v2_copy_to_set_finalize_callback(fn, copy_to_finalize_cb, &fx.err), &fx.err)

	expect_v2_ok(t, duckdb.duckdb_v2_copy_from_set_bind_callback(fn, copy_from_bind_cb, &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.duckdb_v2_copy_from_set_init_global_callback(fn, copy_from_init_global_cb, &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.duckdb_v2_copy_from_set_exec_callback(fn, copy_from_exec_cb, &fx.err), &fx.err)

	expect_v2_ok(t, duckdb.duckdb_v2_connection_register_copy_function(fx.conn, fn, &fx.err), &fx.err)

	// 1. `COPY (SELECT ...) TO` invokes bind -> batch_size -> init -> batch -> flush -> finalize:
	expect_v2_ok(
		t,
		driver_exec_drain(
			fx.conn,
			"COPY (SELECT i FROM range(5) t(i)) TO 'virtual_sink.odincopy' (FORMAT odin_copy_fmt, USE_TMP_FILE FALSE)",
			nil,
			&fx.err,
		),
		&fx.err,
	)
	testing.expect_value(t, state.bind_cols, duckdb.V2_Idx(1))
	testing.expect(t, state.init_called)
	testing.expect(t, state.batches_taken >= 1)
	testing.expect_value(t, state.flushed_rows, duckdb.V2_Idx(5))
	testing.expect(t, state.finalized)

	// 2. `COPY dest FROM` invokes bind -> init_global -> exec and populates `dest`:
	expect_exec_changed_rows(&fx, "CREATE TABLE copy_dest (v BIGINT)", 0)
	expect_v2_ok(
		t,
		driver_exec_drain(fx.conn, "COPY copy_dest FROM 'virtual_src.odincopy' (FORMAT odin_copy_fmt)", nil, &fx.err),
		&fx.err,
	)
	expect_query_column(&fx, "SELECT v FROM copy_dest ORDER BY v", []i64{100, 200, 300})
}
