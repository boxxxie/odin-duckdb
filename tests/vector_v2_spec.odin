package duckdb_tests

// ============================================================================
// Layer 1: Executable Specifications (`tests/vector_v2_spec.odin`)
// ============================================================================
// Direct ATDD port of the C++20 & C API v2 Vector test suites from:
// - `references/c/duckdb-capi-2.0/tools/cpp/tests/test_cpp_api_vector.cpp`
//   1. `TEST_CASE("Stable C++API: Vector AssignString", "[cpp_api]")` (lines 36-62)
//   2. `TEST_CASE("Stable C++API: MakeSequence and MakeConstant round-trip", "[cpp_api]")` (lines 304-336)
//   3. `TEST_CASE("Stable C++API: validity mask word-boundary rows", "[cpp_api]")` (lines 426-468)
//   4. `TEST_CASE("Stable C++API: Vector SetNull recurses into nested children", "[cpp_api]")` (lines 527-563)
//   5. `TEST_CASE("Stable C++API: checked and unsafe UTF-8 string construction", "[cpp_api]")` (lines 636-673)
//   6. `TEST_CASE("Stable C++API: Vector Reference aliases the source without copying", "[cpp_api]")` (lines 695-766)
//   7. `TEST_CASE("Stable C++API: vector cast and try cast", "[cpp_api]")` (lines 820-861)
// ============================================================================

import "core:strings"
import "core:testing"
import duckdb "../duckdb"

// Upstream Reference:
// - `references/c/duckdb-capi-2.0/tools/cpp/tests/test_cpp_api_vector.cpp` lines 36-62, 304-336, 426-468, 636-673
@(test)
spec_v2_vector_assign_string_utf8_sequence_constant_and_validity_boundaries :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)

	// 1. `v2_vector_assign_string` (inlined <= 12B, arena-allocated > 12B, and empty) + UTF-8 validation:
	{
		types := [1]duckdb.V2_Logical_Type_Handle{fx.varchar_type}

		chunk: duckdb.V2_Data_Chunk_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_data_chunk_create(fx.factory, &types[0], 1, &chunk, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_data_chunk_destroy(&chunk)

		vec: duckdb.V2_Vector_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_data_chunk_get_vector(chunk, 0, &vec, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_vector_set_size(vec, 3, &fx.err), &fx.err)

		long_str := "this string is comfortably longer than twelve bytes and lives in the vector arena"
		expect_v2_ok(t, duckdb.v2_vector_assign_string(vec, 0, "hi"))
		expect_v2_ok(t, duckdb.v2_vector_assign_string(vec, 1, long_str))
		expect_v2_ok(t, duckdb.v2_vector_assign_string(vec, 2, ""))

		raw: rawptr
		expect_v2_ok(t, duckdb.duckdb_v2_vector_get_data_mutable(vec, &raw, &fx.err), &fx.err)
		slots := cast([^]duckdb.V2_Bytes)raw
		testing.expect(t, duckdb.v2_bytes_is_inlined(&slots[0]))
		testing.expect(t, !duckdb.v2_bytes_is_inlined(&slots[1]))
		testing.expect_value(t, duckdb.v2_bytes_to_string(&slots[0]), "hi")
		testing.expect_value(t, duckdb.v2_bytes_to_string(&slots[1]), long_str)
		testing.expect_value(t, duckdb.v2_bytes_to_string(&slots[2]), "")

		// Checked UTF-8 validation (`test_cpp_api_vector.cpp` lines 649-663):
		valid_utf8 := duckdb.v2_str_from_string("é🦆")
		expect_v2_ok(t, duckdb.duckdb_v2_validate_utf8(&valid_utf8, &fx.err), &fx.err)

		invalid_bytes := [1]u8{0xFF}
		invalid_utf8 := duckdb.V2_Str{ptr = &invalid_bytes[0], len = 1}
		expect_v2_error(t, duckdb.duckdb_v2_validate_utf8(&invalid_utf8, &fx.err), .INPUT_INVALID, &fx.err)
	}

	// 2. `MakeSequence` (`OTHER` -> `Flatten` -> `FLAT`) and `MakeConstant` (`CONSTANT`) (`test_cpp_api_vector.cpp` lines 304-336):
	{
		types := [2]duckdb.V2_Logical_Type_Handle{fx.bigint_type, fx.bigint_type}

		chunk: duckdb.V2_Data_Chunk_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_data_chunk_create(fx.factory, &types[0], 2, &chunk, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_data_chunk_destroy(&chunk)

		seq_vec, con_vec: duckdb.V2_Vector_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_data_chunk_get_vector(chunk, 0, &seq_vec, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_data_chunk_get_vector(chunk, 1, &con_vec, &fx.err), &fx.err)

		expect_v2_ok(t, duckdb.duckdb_v2_vector_make_sequence(seq_vec, 100, 2, 4, &fx.err), &fx.err)
		vtype: duckdb.V2_Vector_Type
		expect_v2_ok(t, duckdb.duckdb_v2_vector_get_vector_type(seq_vec, &vtype, &fx.err), &fx.err)
		testing.expect_value(t, vtype, duckdb.V2_Vector_Type.OTHER)

		// `GetView` rejects `OTHER` until flattened (`test_cpp_api_vector.cpp` line 515):
		view: duckdb.V2_Vector_View
		expect_v2_error(t, duckdb.duckdb_v2_vector_get_view(seq_vec, &view, &fx.err), .INPUT_INVALID, &fx.err)

		expect_v2_ok(t, duckdb.duckdb_v2_vector_flatten(seq_vec, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_vector_get_vector_type(seq_vec, &vtype, &fx.err), &fx.err)
		testing.expect_value(t, vtype, duckdb.V2_Vector_Type.FLAT)

		expect_v2_ok(t, duckdb.duckdb_v2_vector_get_view(seq_vec, &view, &fx.err), &fx.err)
		testing.expect_value(t, view.count, duckdb.V2_Idx(4))
		seq_data := cast([^]i64)view.data
		for i: duckdb.V2_Idx = 0; i < 4; i += 1 {
			testing.expect_value(t, seq_data[duckdb.v2_sel_at(view.sel, i)], 100 + 2 * i64(i))
		}

		// `MakeConstant` holds one slot referenced by every logical row:
		val_neg5: duckdb.V2_Value_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_bigint(fx.factory, -5, &val_neg5, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&val_neg5)

		expect_v2_ok(t, duckdb.duckdb_v2_vector_make_constant(con_vec, val_neg5, 3, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_vector_get_vector_type(con_vec, &vtype, &fx.err), &fx.err)
		testing.expect_value(t, vtype, duckdb.V2_Vector_Type.CONSTANT)

		cview: duckdb.V2_Vector_View
		expect_v2_ok(t, duckdb.duckdb_v2_vector_get_view(con_vec, &cview, &fx.err), &fx.err)
		testing.expect_value(t, cview.count, duckdb.V2_Idx(3))
		testing.expect_value(t, duckdb.v2_sel_at(cview.sel, 2), duckdb.V2_Idx(0))
		con_data := cast([^]i64)cview.data
		testing.expect_value(t, con_data[duckdb.v2_sel_at(cview.sel, 2)], i64(-5))
	}

	// 3. Validity mask 64-bit word boundaries (`63|64` and `127|128`, `test_cpp_api_vector.cpp` lines 426-468):
	{
		types := [1]duckdb.V2_Logical_Type_Handle{fx.int_type}

		chunk: duckdb.V2_Data_Chunk_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_data_chunk_create(fx.factory, &types[0], 1, &chunk, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_data_chunk_destroy(&chunk)

		vec: duckdb.V2_Vector_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_data_chunk_get_vector(chunk, 0, &vec, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_vector_set_size(vec, 130, &fx.err), &fx.err)

		mask: [^]u64
		expect_v2_ok(t, duckdb.duckdb_v2_vector_flat_get_validity_mutable(vec, &mask, &fx.err), &fx.err)
		boundary_rows := [4]duckdb.V2_Idx{63, 64, 127, 128}
		for r in boundary_rows {
			duckdb.v2_validity_set_invalid(mask, r)
		}

		view: duckdb.V2_Vector_View
		expect_v2_ok(t, duckdb.duckdb_v2_vector_get_view(vec, &view, &fx.err), &fx.err)
		for r in boundary_rows {
			testing.expect(t, !duckdb.v2_row_is_valid(view, r))
		}
		neighbor_rows := [5]duckdb.V2_Idx{0, 62, 65, 126, 129}
		for r in neighbor_rows {
			testing.expect(t, duckdb.v2_row_is_valid(view, r))
		}
	}
}

// Upstream Reference:
// - `references/c/duckdb-capi-2.0/tools/cpp/tests/test_cpp_api_vector.cpp` lines 527-563, 695-766, 820-861
@(test)
spec_v2_vector_nested_struct_nulls_zero_copy_reference_and_cast :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)

	// 1. `SetNull` on a `STRUCT(name VARCHAR, score DOUBLE)` recursively invalidates child vectors (lines 527-563):
	{
		struct_sql := duckdb.v2_str_from_string("STRUCT(name VARCHAR, score DOUBLE)")
		struct_type: duckdb.V2_Logical_Type_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_factory_create_type_from_text(fx.factory, &struct_sql, &struct_type, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_logical_type_destroy(&struct_type)
		types := [1]duckdb.V2_Logical_Type_Handle{struct_type}

		chunk: duckdb.V2_Data_Chunk_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_data_chunk_create(fx.factory, &types[0], 1, &chunk, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_data_chunk_destroy(&chunk)

		vec: duckdb.V2_Vector_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_data_chunk_get_vector(chunk, 0, &vec, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_vector_set_size(vec, 3, &fx.err), &fx.err)

		child_count: duckdb.V2_Idx
		expect_v2_ok(t, duckdb.duckdb_v2_vector_get_child_count(vec, &child_count, &fx.err), &fx.err)
		testing.expect_value(t, child_count, duckdb.V2_Idx(2))

		name_vec, score_vec: duckdb.V2_Vector_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_vector_get_child(vec, 0, &name_vec, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_vector_get_child(vec, 1, &score_vec, &fx.err), &fx.err)

		score_raw: rawptr
		expect_v2_ok(t, duckdb.duckdb_v2_vector_get_data_mutable(score_vec, &score_raw, &fx.err), &fx.err)
		scores := cast([^]f64)score_raw
		for i: duckdb.V2_Idx = 0; i < 3; i += 1 {
			expect_v2_ok(t, duckdb.v2_vector_assign_string(name_vec, i, "n"))
			scores[i] = f64(i)
		}

		expect_v2_ok(t, duckdb.duckdb_v2_vector_set_null(vec, 1, &fx.err), &fx.err)

		parent_view, name_view, score_view: duckdb.V2_Vector_View
		expect_v2_ok(t, duckdb.duckdb_v2_vector_get_view(vec, &parent_view, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_vector_get_view(name_vec, &name_view, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_vector_get_view(score_vec, &score_view, &fx.err), &fx.err)

		testing.expect(t, !duckdb.v2_row_is_valid(parent_view, 1))
		testing.expect(t, !duckdb.v2_row_is_valid(name_view, 1))
		testing.expect(t, !duckdb.v2_row_is_valid(score_view, 1))
		testing.expect(t, duckdb.v2_row_is_valid(parent_view, 0))
		testing.expect(t, duckdb.v2_row_is_valid(name_view, 2))
	}

	// 2. `duckdb_v2_vector_reference` aliases the source buffer without copying + `duckdb_v2_vector_cast` (`NORMAL` vs `TRY`):
	{
		types := [3]duckdb.V2_Logical_Type_Handle{fx.varchar_type, fx.int_type, fx.int_type}
		chunk: duckdb.V2_Data_Chunk_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_data_chunk_create(fx.factory, &types[0], 3, &chunk, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_data_chunk_destroy(&chunk)

		src_str_vec, dst_int_vec, ref_int_vec: duckdb.V2_Vector_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_data_chunk_get_vector(chunk, 0, &src_str_vec, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_data_chunk_get_vector(chunk, 1, &dst_int_vec, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_data_chunk_get_vector(chunk, 2, &ref_int_vec, &fx.err), &fx.err)

		expect_v2_ok(t, duckdb.duckdb_v2_vector_set_size(src_str_vec, 3, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.v2_vector_assign_string(src_str_vec, 0, "10"))
		expect_v2_ok(t, duckdb.v2_vector_assign_string(src_str_vec, 1, "bad_int"))
		expect_v2_ok(t, duckdb.v2_vector_assign_string(src_str_vec, 2, "30"))

		// `NORMAL` cast fails with `TYPE_CONVERSION` (`4001`):
		converted := false
		expect_v2_error(
			t,
			duckdb.duckdb_v2_vector_cast(fx.factory, src_str_vec, dst_int_vec, .NORMAL, &converted, nil, &fx.err),
			.TYPE_CONVERSION,
			&fx.err,
		)

		// `TRY` cast succeeds, sets `converted = false`, marks row 1 invalid, and populates `cast_err`:
		cast_err: duckdb.V2_Error_Info_Handle
		expect_v2_ok(
			t,
			duckdb.duckdb_v2_vector_cast(fx.factory, src_str_vec, dst_int_vec, .TRY, &converted, &cast_err, &fx.err),
			&fx.err,
		)
		testing.expect(t, !converted)
		_, cast_msg := driver_consume_error_text(&cast_err)
		testing.expect(t, strings.contains(cast_msg, "bad_int"))

		// Zero-copy `duckdb_v2_vector_reference` aliases `dst_int_vec`'s buffer directly into `ref_int_vec`:
		expect_v2_ok(t, duckdb.duckdb_v2_vector_reference(ref_int_vec, dst_int_vec, &fx.err), &fx.err)

		dst_view, ref_view: duckdb.V2_Vector_View
		expect_v2_ok(t, duckdb.duckdb_v2_vector_get_view(dst_int_vec, &dst_view, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_vector_get_view(ref_int_vec, &ref_view, &fx.err), &fx.err)
		testing.expect_value(t, ref_view.data, dst_view.data)
		testing.expect(t, duckdb.v2_row_is_valid(ref_view, 0))
		testing.expect(t, !duckdb.v2_row_is_valid(ref_view, 1))
		testing.expect(t, duckdb.v2_row_is_valid(ref_view, 2))
		ref_ints := cast([^]i32)ref_view.data
		testing.expect_value(t, ref_ints[0], i32(10))
		testing.expect_value(t, ref_ints[2], i32(30))
	}
}
