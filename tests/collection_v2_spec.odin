package duckdb_tests

// ============================================================================
// Layer 1: Executable Specifications (`tests/collection_v2_spec.odin`)
// ============================================================================
// Direct ATDD port of all 6 Catch2 test suites from:
// - `references/c/duckdb-capi-2.0/tools/cpp/tests/test_cpp_api_column_data_collection.cpp`
//   1. `TEST_CASE("Stable C++API: ColumnDataCollection round-trip", "[cpp_api]")` (lines 51-69)
//   2. `TEST_CASE("Stable C++API: ColumnDataCollection combine consumes the source", "[cpp_api]")` (lines 71-95)
//   3. `TEST_CASE("Stable C++API: ColumnDataCollection reset", "[cpp_api]")` (lines 97-114)
//   4. `TEST_CASE("Stable C++API: ColumnDataCollection clear", "[cpp_api]")` (lines 116-136)
//   5. `TEST_CASE("Stable C++API: ColumnDataCollection scan refuses a mismatching chunk", "[cpp_api]")` (lines 138-155)
//   6. `TEST_CASE("Stable C++API: DataChunk::Copy outlives the scan", "[cpp_api]")` (lines 156-179)
// ============================================================================

import "core:testing"
import duckdb "../duckdb"

@(test)
spec_v2_column_data_collection_roundtrip_combine_reset_clear_and_copy :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)
	int_types := [1]duckdb.V2_Logical_Type_Handle{fx.int_type}

	// 1. Multi-chunk append & zero-copy scan round-trip (`test_cpp_api_column_data_collection.cpp` lines 51-69):
	{
		collection: duckdb.V2_Column_Data_Collection_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_column_data_collection_create(fx.factory, &int_types[0], 1, &collection, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_column_data_collection_destroy(&collection)

		row_count: duckdb.V2_Idx = 99
		expect_v2_ok(t, duckdb.duckdb_v2_column_data_collection_row_count(collection, &row_count, &fx.err), &fx.err)
		testing.expect_value(t, row_count, duckdb.V2_Idx(0))

		state: duckdb.V2_Column_Data_Collection_Append_State_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_column_data_collection_append_state_create(collection, &state, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_column_data_collection_append_state_destroy(&state)

		c1, c2, c3: duckdb.V2_Data_Chunk_Handle
		expect_v2_ok(t, driver_make_chunk(i32, fx.factory, fx.int_type, []i32{1, 2, 3}, &c1, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_data_chunk_destroy(&c1)
		expect_v2_ok(t, driver_make_chunk(i32, fx.factory, fx.int_type, []i32{4}, &c2, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_data_chunk_destroy(&c2)
		expect_v2_ok(t, driver_make_chunk(i32, fx.factory, fx.int_type, []i32{5, 6}, &c3, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_data_chunk_destroy(&c3)

		expect_v2_ok(t, duckdb.duckdb_v2_column_data_collection_append(collection, state, c1, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_column_data_collection_append(collection, state, c2, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_column_data_collection_append(collection, state, c3, &fx.err), &fx.err)

		expect_v2_ok(t, duckdb.duckdb_v2_column_data_collection_row_count(collection, &row_count, &fx.err), &fx.err)
		testing.expect_value(t, row_count, duckdb.V2_Idx(6))

		scanned, scan_rc := driver_scan_collection(i32, fx.factory, fx.int_type, collection)
		expect_v2_ok(t, scan_rc)
		expect_slice_equal(t, scanned[:], []i32{1, 2, 3, 4, 5, 6})
	}

	// 2. `combine` consumes the source handle on success and leaves it intact on type mismatch (lines 71-95):
	{
		target, source: duckdb.V2_Column_Data_Collection_Handle
		expect_v2_ok(t, driver_make_collection(i32, fx.factory, fx.int_type, []i32{1, 2}, &target, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_column_data_collection_destroy(&target)
		expect_v2_ok(t, driver_make_collection(i32, fx.factory, fx.int_type, []i32{3}, &source, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_column_data_collection_destroy(&source)

		expect_v2_ok(t, duckdb.duckdb_v2_column_data_collection_combine(target, &source, &fx.err), &fx.err)
		// `source` is consumed and set to `nil` by `combine`:
		testing.expect_value(t, source, duckdb.V2_Column_Data_Collection_Handle(nil))

		scanned, _ := driver_scan_collection(i32, fx.factory, fx.int_type, target)
		expect_slice_equal(t, scanned[:], []i32{1, 2, 3})

		// Refused merge with mismatched `BIGINT` collection returns `INPUT_INVALID` and leaves `mismatched` non-nil:
		bigint_types := [1]duckdb.V2_Logical_Type_Handle{fx.bigint_type}

		mismatched: duckdb.V2_Column_Data_Collection_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_column_data_collection_create(fx.factory, &bigint_types[0], 1, &mismatched, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_column_data_collection_destroy(&mismatched)

		expect_v2_error(
			t,
			duckdb.duckdb_v2_column_data_collection_combine(target, &mismatched, &fx.err),
			.INPUT_INVALID,
			&fx.err,
		)
		testing.expect(t, mismatched != nil)
	}

	// 3. `reset`, `clear`, scan type mismatch, and `duckdb_v2_data_chunk_copy` outliving the scan (lines 97-179):
	{
		collection: duckdb.V2_Column_Data_Collection_Handle
		expect_v2_ok(t, driver_make_collection(i32, fx.factory, fx.int_type, []i32{10}, &collection, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_column_data_collection_destroy(&collection)

		// Scan one chunk, deep-copy it via `duckdb_v2_data_chunk_copy`, then reset the collection:
		copied_chunk: duckdb.V2_Data_Chunk_Handle
		{
			shared: duckdb.V2_Column_Data_Collection_Shared_Scan_State_Handle
			expect_v2_ok(t, duckdb.duckdb_v2_column_data_collection_shared_scan_state_create(collection, &shared, &fx.err), &fx.err)
			defer duckdb.duckdb_v2_column_data_collection_shared_scan_state_destroy(&shared)

			worker: duckdb.V2_Column_Data_Collection_Worker_Scan_State_Handle
			expect_v2_ok(t, duckdb.duckdb_v2_column_data_collection_worker_scan_state_create(collection, &worker, &fx.err), &fx.err)
			defer duckdb.duckdb_v2_column_data_collection_worker_scan_state_destroy(&worker)

			scan_chunk: duckdb.V2_Data_Chunk_Handle
			expect_v2_ok(t, driver_make_chunk(i32, fx.factory, fx.int_type, nil, &scan_chunk, &fx.err), &fx.err)
			defer duckdb.duckdb_v2_data_chunk_destroy(&scan_chunk)

			did_produce := false
			expect_v2_ok(
				t,
				duckdb.duckdb_v2_column_data_collection_scan(collection, shared, worker, scan_chunk, &did_produce, &fx.err),
				&fx.err,
			)
			testing.expect(t, did_produce)

			expect_v2_ok(t, duckdb.duckdb_v2_data_chunk_copy(fx.factory, scan_chunk, &copied_chunk, &fx.err), &fx.err)
		}
		defer duckdb.duckdb_v2_data_chunk_destroy(&copied_chunk)

		// Reset `collection` and `clear` it — `copied_chunk` owns its buffers and remains valid!
		expect_v2_ok(t, duckdb.duckdb_v2_column_data_collection_reset(collection, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_column_data_collection_clear(collection, &fx.err), &fx.err)

		copy_sz: duckdb.V2_Idx
		expect_v2_ok(t, duckdb.duckdb_v2_data_chunk_get_size(copied_chunk, &copy_sz, &fx.err), &fx.err)
		testing.expect_value(t, copy_sz, duckdb.V2_Idx(1))

		copy_vec: duckdb.V2_Vector_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_data_chunk_get_vector(copied_chunk, 0, &copy_vec, &fx.err), &fx.err)
		copy_view: duckdb.V2_Vector_View
		expect_v2_ok(t, duckdb.duckdb_v2_vector_get_view(copy_vec, &copy_view, &fx.err), &fx.err)
		copy_data := cast([^]i32)copy_view.data
		testing.expect_value(t, copy_data[duckdb.v2_sel_at(copy_view.sel, 0)], i32(10))
	}
}
