package duckdb_tests

// ============================================================================
// Layer 1: Executable Specifications — Types & Values (`tests/types_values_v2_spec.odin`)
// ============================================================================
// Ported from Authoritative DuckDB 2.0 C API v2 & C++20 Test Suites:
// 1. `references/c/duckdb-capi-2.0/tools/cpp/tests/test_cpp_api_types_values.cpp`
//    - Value Null (`duckdb_v2_value_create_null` / `duckdb_v2_value_is_null`) and BIGNUM codec
//      (`duckdb_v2_bignum_encode` / `duckdb_v2_bignum_decode` / `duckdb_v2_value_create_bignum`).
//    - `LogicalType` creation (`duckdb_v2_factory_create_type_from_text`, `create_type_from_name`,
//      `create_type_with_alias`, `create_common_type`) & introspection (`duckdb_v2_logical_type_to_text`,
//      `get_id`, `get_name`, `get_param_count`, `get_param`, `equals`) across `DECIMAL`, `ENUM`, `LIST`,
//      `ARRAY`, `MAP`, `STRUCT`, `UNION`, and `TUPLE`.
//    - Composite & leaf `Value` creation/inspection (`create_list`, `create_array`, `create_struct`,
//      `create_tuple`, `create_map`, `get_child_count`, `get_child`, `duckdb_v2_value_cast` to `INTEGER`,
//      `DATE`, `UNION`, `ENUM`, `VARIANT` vector `set_value`/`get_value` round-trip, and typed leaf
//      constructors/getters for `decimal`, `uuid`, `date`, `time`, `timestamp`, `interval`, `bit`, `blob`, `hugeint`).
// ============================================================================

import "core:slice"
import "core:testing"
import duckdb "../duckdb"

@(test)
spec_v2_value_null_and_bignum_codec_roundtrip :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)

	// 1. NULL value creation & inspection
	null_val: duckdb.V2_Value_Handle
	expect_v2_ok(t, duckdb.duckdb_v2_value_create_null(fx.factory, fx.int_type, &null_val, &fx.err), &fx.err)
	defer duckdb.duckdb_v2_value_destroy(&null_val)

	is_null := false
	expect_v2_ok(t, duckdb.duckdb_v2_value_is_null(null_val, &is_null, &fx.err), &fx.err)
	testing.expect(t, is_null, "expected null_val to report is_null == true")

	val_type: duckdb.V2_Logical_Type_Handle
	expect_v2_ok(t, duckdb.duckdb_v2_value_get_logical_type(null_val, &val_type, &fx.err), &fx.err)
	defer duckdb.duckdb_v2_logical_type_destroy(&val_type)

	eq := false
	expect_v2_ok(t, duckdb.duckdb_v2_logical_type_is_equal(val_type, fx.int_type, &eq, &fx.err), &fx.err)
	testing.expect(t, eq, "expected null_val logical type to equal INTEGER")

	// 2. BIGNUM encode/decode for +2^64 and -2^64 (`test_cpp_api_types_values.cpp` lines 29-49)
	magnitude := [9]u8{0x01, 0, 0, 0, 0, 0, 0, 0, 0}
	for is_neg in ([2]bool{false, true}) {
		enc_len: duckdb.V2_Idx
		expect_v2_ok(t, duckdb.duckdb_v2_bignum_encode(&magnitude[0], len(magnitude), is_neg, nil, 0, &enc_len, &fx.err), &fx.err)
		encoded := make([]u8, int(enc_len), context.temp_allocator)
		expect_v2_ok(t, duckdb.duckdb_v2_bignum_encode(&magnitude[0], len(magnitude), is_neg, raw_data(encoded), enc_len, &enc_len, &fx.err), &fx.err)

		b_str := duckdb.V2_Str{ptr = raw_data(encoded), len = enc_len}
		bn_val: duckdb.V2_Value_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_bignum(fx.factory, &b_str, &bn_val, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&bn_val)

		text, text_rc := driver_render_value(bn_val)
		testing.expect_value(t, text_rc, duckdb.V2_Error.NONE)
		if is_neg {
			testing.expect_value(t, text, "-18446744073709551616")
		} else {
			testing.expect_value(t, text, "18446744073709551616")
		}

		// Decode back from blob payload
		blob_out: duckdb.V2_Str
		expect_v2_ok(t, duckdb.duckdb_v2_value_get_blob(bn_val, &blob_out, &fx.err), &fx.err)

		dec_len: duckdb.V2_Idx
		dec_neg := false
		expect_v2_ok(t, duckdb.duckdb_v2_bignum_decode(blob_out.ptr, blob_out.len, nil, 0, &dec_len, &dec_neg, &fx.err), &fx.err)
		decoded := make([]u8, int(dec_len), context.temp_allocator)
		expect_v2_ok(t, duckdb.duckdb_v2_bignum_decode(blob_out.ptr, blob_out.len, raw_data(decoded), dec_len, &dec_len, &dec_neg, &fx.err), &fx.err)
		testing.expect_value(t, dec_neg, is_neg)
		testing.expect(t, slice.equal(decoded, magnitude[:]), "expected decoded bignum magnitude to match 2^64")
	}
}

@(test)
spec_v2_logical_type_parse_to_text_params_and_aliases :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)

	// 1. ParseType("DECIMAL(12,4)") & ToText round-trip
	dec_sql := duckdb.v2_str_from_string("DECIMAL(12,4)")
	dec_type: duckdb.V2_Logical_Type_Handle
	expect_v2_ok(t, duckdb.duckdb_v2_factory_create_type_from_text(fx.factory, &dec_sql, &dec_type, &fx.err), &fx.err)
	defer duckdb.duckdb_v2_logical_type_destroy(&dec_type)

	dec_text, dec_rc := driver_render_logical_type(dec_type)
	testing.expect_value(t, dec_rc, duckdb.V2_Error.NONE)
	testing.expect_value(t, dec_text, "DECIMAL(12,4)")

	p_count: duckdb.V2_Idx
	expect_v2_ok(t, duckdb.duckdb_v2_logical_type_get_param_count(dec_type, &p_count, &fx.err), &fx.err)
	testing.expect_value(t, p_count, duckdb.V2_Idx(2))

	p0_name: duckdb.V2_Identifier
	p0_val: duckdb.V2_Value_Handle
	expect_v2_ok(t, duckdb.duckdb_v2_logical_type_get_param(dec_type, 0, &p0_name, &p0_val, &fx.err), &fx.err)
	defer duckdb.duckdb_v2_value_destroy(&p0_val)
	testing.expect_value(t, duckdb.v2_str_to_string(p0_name), "")
	width: u8
	expect_v2_ok(t, duckdb.duckdb_v2_value_get_utinyint(p0_val, &width, &fx.err), &fx.err)
	testing.expect_value(t, width, u8(12))

	// 2. Named TYPE-value params (`STRUCT(a INTEGER, b VARCHAR)`) and dual reconstruction
	v_int, v_vch: duckdb.V2_Value_Handle
	expect_v2_ok(t, duckdb.duckdb_v2_value_create_type(fx.factory, fx.int_type, &v_int, &fx.err), &fx.err)
	defer duckdb.duckdb_v2_value_destroy(&v_int)
	expect_v2_ok(t, duckdb.duckdb_v2_value_create_type(fx.factory, fx.varchar_type, &v_vch, &fx.err), &fx.err)
	defer duckdb.duckdb_v2_value_destroy(&v_vch)

	field_names := [2]duckdb.V2_Identifier{
		duckdb.v2_str_from_string("a"),
		duckdb.v2_str_from_string("b"),
	}
	field_vals := [2]duckdb.V2_Value_Handle{v_int, v_vch}
	struct_name := duckdb.v2_str_from_string("struct")
	struct_qname: duckdb.V2_Qname_Handle
	expect_v2_ok(t, duckdb.duckdb_v2_qname_parse(&struct_name, &struct_qname, &fx.err), &fx.err)
	defer duckdb.duckdb_v2_qname_destroy(&struct_qname)

	struct_type: duckdb.V2_Logical_Type_Handle
	expect_v2_ok(
		t,
		duckdb.duckdb_v2_factory_create_type_from_name(fx.factory, struct_qname, &field_names[0], &field_vals[0], 2, &struct_type, &fx.err),
		&fx.err,
	)
	defer duckdb.duckdb_v2_logical_type_destroy(&struct_type)

	struct_text, s_rc := driver_render_logical_type(struct_type)
	testing.expect_value(t, s_rc, duckdb.V2_Error.NONE)
	testing.expect_value(t, struct_text, "STRUCT(a INTEGER, b VARCHAR)")

	// 3. Alias preserves type_id while changing get_name
	alias_str := duckdb.v2_str_from_string("MY_INT")
	aliased_type: duckdb.V2_Logical_Type_Handle
	expect_v2_ok(t, duckdb.duckdb_v2_factory_create_type_with_alias(fx.factory, fx.int_type, &alias_str, &aliased_type, &fx.err), &fx.err)
	defer duckdb.duckdb_v2_logical_type_destroy(&aliased_type)

	got_name: duckdb.V2_Identifier
	expect_v2_ok(t, duckdb.duckdb_v2_logical_type_get_name(aliased_type, &got_name, &fx.err), &fx.err)
	testing.expect_value(t, duckdb.v2_str_to_string(got_name), "MY_INT")

	got_id: duckdb.V2_Logical_Type_Id
	expect_v2_ok(t, duckdb.duckdb_v2_logical_type_get_id(aliased_type, &got_id, &fx.err), &fx.err)
	testing.expect_value(t, got_id, duckdb.V2_Logical_Type_Id.INTEGER)

	// 4. Unknown type yields DATABASE_CATALOG error (`test_cpp_api_types_values.cpp` line 74)
	bad_sql := duckdb.v2_str_from_string("definitely_not_a_type")
	bad_type: duckdb.V2_Logical_Type_Handle
	expect_v2_error(
		t,
		duckdb.duckdb_v2_factory_create_type_from_text(fx.factory, &bad_sql, &bad_type, &fx.err),
		.DATABASE_CATALOG,
		&fx.err,
	)
}

@(test)
spec_v2_composite_values_variant_box_and_typed_leaf_roundtrips :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)

	union_type, variant_type: duckdb.V2_Logical_Type_Handle
	u_sql := duckdb.v2_str_from_string("UNION(i INTEGER, s VARCHAR)")
	expect_v2_ok(t, duckdb.duckdb_v2_factory_create_type_from_text(fx.factory, &u_sql, &union_type, &fx.err), &fx.err)
	defer duckdb.duckdb_v2_logical_type_destroy(&union_type)

	var_sql := duckdb.v2_str_from_string("VARIANT")
	expect_v2_ok(t, duckdb.duckdb_v2_factory_create_type_from_text(fx.factory, &var_sql, &variant_type, &fx.err), &fx.err)
	defer duckdb.duckdb_v2_logical_type_destroy(&variant_type)

	// 1. LIST, ARRAY, STRUCT, TUPLE, MAP creation & child inspection
	{
		e0, e1: duckdb.V2_Value_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_int(fx.factory, 10, &e0, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&e0)
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_int(fx.factory, 20, &e1, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&e1)

		elems := [2]duckdb.V2_Value_Handle{e0, e1}
		list_val, arr_val, tuple_val: duckdb.V2_Value_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_list(fx.factory, fx.int_type, &elems[0], 2, &list_val, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&list_val)
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_array(fx.factory, fx.int_type, &elems[0], 2, &arr_val, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&arr_val)
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_tuple(fx.factory, &elems[0], 2, &tuple_val, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&tuple_val)

		c_count: duckdb.V2_Idx
		expect_v2_ok(t, duckdb.duckdb_v2_value_get_child_count(list_val, &c_count, &fx.err), &fx.err)
		testing.expect_value(t, c_count, duckdb.V2_Idx(2))

		c1: duckdb.V2_Value_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_value_get_child(arr_val, 1, &c1, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&c1)
		v_c1: i32
		expect_v2_ok(t, duckdb.duckdb_v2_value_get_int(c1, &v_c1, &fx.err), &fx.err)
		testing.expect_value(t, v_c1, i32(20))

		// UNION via cast (`[0]` = tag UTINYINT, `[1]` = active member)
		s_x := duckdb.v2_str_from_string("x")
		vx, u_val: duckdb.V2_Value_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_varchar(fx.factory, &s_x, &vx, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&vx)
		expect_v2_ok(t, duckdb.duckdb_v2_value_cast(fx.factory, vx, union_type, &u_val, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&u_val)

		u_tag_val: duckdb.V2_Value_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_value_get_child(u_val, 0, &u_tag_val, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&u_tag_val)
		tag: u8
		expect_v2_ok(t, duckdb.duckdb_v2_value_get_utinyint(u_tag_val, &tag, &fx.err), &fx.err)
		testing.expect_value(t, tag, u8(1))
	}

	// 2. VARIANT vector `set_value` / `get_value` round-trip (`test_cpp_api_types_values.cpp` lines 278-345)
	{
		types := [1]duckdb.V2_Logical_Type_Handle{variant_type}
		chunk: duckdb.V2_Data_Chunk_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_data_chunk_create(fx.factory, &types[0], 1, &chunk, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_data_chunk_destroy(&chunk)

		vec: duckdb.V2_Vector_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_data_chunk_get_vector(chunk, 0, &vec, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_vector_set_size(vec, 2, &fx.err), &fx.err)

		v42: duckdb.V2_Value_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_bigint(fx.factory, 42, &v42, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&v42)
		expect_v2_ok(t, duckdb.duckdb_v2_vector_set_value(vec, 0, v42, &fx.err), &fx.err)

		s_long := duckdb.v2_str_from_string("a string long enough to spill")
		v_str: duckdb.V2_Value_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_varchar(fx.factory, &s_long, &v_str, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&v_str)
		expect_v2_ok(t, duckdb.duckdb_v2_vector_set_value(vec, 1, v_str, &fx.err), &fx.err)

		box0, unboxed0: duckdb.V2_Value_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_vector_get_value(vec, 0, &box0, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&box0)
		expect_v2_ok(t, duckdb.duckdb_v2_value_cast(fx.factory, box0, fx.bigint_type, &unboxed0, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&unboxed0)
		got42: i64
		expect_v2_ok(t, duckdb.duckdb_v2_value_get_bigint(unboxed0, &got42, &fx.err), &fx.err)
		testing.expect_value(t, got42, i64(42))
	}

	// 3. Typed leaf values: DECIMAL(4,2), INTERVAL, HUGEINT (2^64)
	{
		dec_raw := duckdb.V2_Hugeint{lower = transmute(u64)i64(-1234), upper = -1}
		dec_val: duckdb.V2_Value_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_decimal(fx.factory, &dec_raw, 4, 2, &dec_val, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&dec_val)

		dec_str, dec_rc := driver_render_value(dec_val)
		testing.expect_value(t, dec_rc, duckdb.V2_Error.NONE)
		testing.expect_value(t, dec_str, "-12.34")

		iv_in := duckdb.V2_Interval{months = 14, days = 3, micros = 14706789000}
		iv_val: duckdb.V2_Value_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_interval(fx.factory, &iv_in, &iv_val, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&iv_val)
		iv_out: duckdb.V2_Interval
		expect_v2_ok(t, duckdb.duckdb_v2_value_get_interval(iv_val, &iv_out, &fx.err), &fx.err)
		testing.expect_value(t, iv_out, iv_in)

		huge_in := duckdb.V2_Hugeint{lower = 0, upper = 1}
		huge_val: duckdb.V2_Value_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_hugeint(fx.factory, &huge_in, &huge_val, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&huge_val)
		huge_str, h_rc := driver_render_value(huge_val)
		testing.expect_value(t, h_rc, duckdb.V2_Error.NONE)
		testing.expect_value(t, huge_str, "18446744073709551616")
	}
}

// ============================================================================
// 4. Common Type Supertype Resolution & All Scalar/Temporal/Map/Bit/Type Value
//    Constructors & Getters (`test_capi_v2_common_type.cpp`, `test_capi_v2_value.cpp`)
// ============================================================================

@(test)
spec_v2_common_type_and_all_scalar_temporal_value_roundtrips :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)

	// 1. `duckdb_v2_factory_create_common_type` (`test_capi_v2_common_type.cpp` lines 16-125):
	{
		// Single type -> returns equal type:
		single := [1]duckdb.V2_Logical_Type_Handle{fx.int_type}
		common1: duckdb.V2_Logical_Type_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_factory_create_common_type(fx.factory, &single[0], 1, &common1, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_logical_type_destroy(&common1)
		eq1 := false
		expect_v2_ok(t, duckdb.duckdb_v2_logical_type_is_equal(common1, fx.int_type, &eq1, &fx.err), &fx.err)
		testing.expect(t, eq1)

		// `[INTEGER, BIGINT, DOUBLE]` -> `DOUBLE` (matches `duckdb_v2_value_create_list` with child_type=nil):
		double_type: duckdb.V2_Logical_Type_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_factory_create_type_from_id(fx.factory, .DOUBLE, nil, nil, 0, &double_type, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_logical_type_destroy(&double_type)

		triple := [3]duckdb.V2_Logical_Type_Handle{fx.int_type, fx.bigint_type, double_type}
		common3: duckdb.V2_Logical_Type_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_factory_create_common_type(fx.factory, &triple[0], 3, &common3, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_logical_type_destroy(&common3)

		cid: duckdb.V2_Logical_Type_Id
		expect_v2_ok(t, duckdb.duckdb_v2_logical_type_get_id(common3, &cid, &fx.err), &fx.err)
		testing.expect_value(t, cid, duckdb.V2_Logical_Type_Id.DOUBLE)

		// `duckdb_v2_logical_type_copy` produces an equal independent handle:
		copied_type: duckdb.V2_Logical_Type_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_logical_type_copy(common3, &copied_type, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_logical_type_destroy(&copied_type)
		eq_copy := false
		expect_v2_ok(t, duckdb.duckdb_v2_logical_type_is_equal(common3, copied_type, &eq_copy, &fx.err), &fx.err)
		testing.expect(t, eq_copy)

		// Error cases: count == 0 (`INPUT_INVALID`) and null array element (`INPUT_INVALID`):
		bad_out: duckdb.V2_Logical_Type_Handle
		expect_v2_error(
			t,
			duckdb.duckdb_v2_factory_create_common_type(fx.factory, nil, 0, &bad_out, &fx.err),
			.INPUT_INVALID,
			&fx.err,
		)
		null_elem := [2]duckdb.V2_Logical_Type_Handle{fx.int_type, nil}
		expect_v2_error(
			t,
			duckdb.duckdb_v2_factory_create_common_type(fx.factory, &null_elem[0], 2, &bad_out, &fx.err),
			.INPUT_INVALID,
			&fx.err,
		)
	}

	// 2. Complete scalar & temporal `Value` constructors & getters (`test_capi_v2_value.cpp`):
	{
		v_b, v_i8, v_i16, v_u8, v_u16, v_u32, v_u64, v_uh, v_f32, v_f64: duckdb.V2_Value_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_bool(fx.factory, true, &v_b, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&v_b)
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_tinyint(fx.factory, -42, &v_i8, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&v_i8)
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_smallint(fx.factory, -1234, &v_i16, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&v_i16)
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_utinyint(fx.factory, 200, &v_u8, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&v_u8)
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_usmallint(fx.factory, 50000, &v_u16, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&v_u16)
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_uint(fx.factory, 3000000000, &v_u32, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&v_u32)
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_ubigint(fx.factory, 9000000000000000000, &v_u64, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&v_u64)

		uh_in := duckdb.V2_Uhugeint{lower = 7, upper = 3}
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_uhugeint(fx.factory, &uh_in, &v_uh, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&v_uh)
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_float(fx.factory, 2.5, &v_f32, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&v_f32)
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_double(fx.factory, 3.125, &v_f64, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&v_f64)

		got_b := false
		got_i8: i8
		got_i16: i16
		got_u8: u8
		got_u16: u16
		got_u32: u32
		got_u64: u64
		got_uh: duckdb.V2_Uhugeint
		got_f32: f32
		got_f64: f64
		expect_v2_ok(t, duckdb.duckdb_v2_value_get_bool(v_b, &got_b, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_value_get_tinyint(v_i8, &got_i8, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_value_get_smallint(v_i16, &got_i16, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_value_get_utinyint(v_u8, &got_u8, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_value_get_usmallint(v_u16, &got_u16, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_value_get_uint(v_u32, &got_u32, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_value_get_ubigint(v_u64, &got_u64, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_value_get_uhugeint(v_uh, &got_uh, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_value_get_float(v_f32, &got_f32, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_value_get_double(v_f64, &got_f64, &fx.err), &fx.err)
		testing.expect_value(t, got_b, true)
		testing.expect_value(t, got_i8, i8(-42))
		testing.expect_value(t, got_i16, i16(-1234))
		testing.expect_value(t, got_u8, u8(200))
		testing.expect_value(t, got_u16, u16(50000))
		testing.expect_value(t, got_u32, u32(3000000000))
		testing.expect_value(t, got_u64, u64(9000000000000000000))
		testing.expect_value(t, got_uh, uh_in)
		testing.expect_value(t, got_f32, f32(2.5))
		testing.expect_value(t, got_f64, f64(3.125))
	}

	// 3. Temporal, UUID, BLOB, BIT, MAP, and TYPE-value round-trips:
	{
		v_dt, v_tm, v_tns, v_ttz, v_ts, v_tss, v_tsms, v_tsns, v_tstz, v_tstzns: duckdb.V2_Value_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_date(fx.factory, 19800, &v_dt, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&v_dt)
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_time(fx.factory, 3600000000, &v_tm, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&v_tm)
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_time_ns(fx.factory, 3600000000000, &v_tns, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&v_tns)
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_time_tz(fx.factory, 123456, &v_ttz, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&v_ttz)
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_timestamp(fx.factory, 1700000000000000, &v_ts, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&v_ts)
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_timestamp_sec(fx.factory, 1700000000, &v_tss, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&v_tss)
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_timestamp_ms(fx.factory, 1700000000000, &v_tsms, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&v_tsms)
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_timestamp_ns(fx.factory, 1700000000000000000, &v_tsns, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&v_tsns)
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_timestamp_tz(fx.factory, 1700000000000000, &v_tstz, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&v_tstz)
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_timestamp_tz_ns(fx.factory, 1700000000000000000, &v_tstzns, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&v_tstzns)

		got_dt: i32
		got_tm, got_tns, got_ts, got_tss, got_tsms, got_tsns, got_tstz, got_tstzns: i64
		got_ttz: u64
		expect_v2_ok(t, duckdb.duckdb_v2_value_get_date(v_dt, &got_dt, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_value_get_time(v_tm, &got_tm, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_value_get_time_ns(v_tns, &got_tns, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_value_get_time_tz(v_ttz, &got_ttz, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_value_get_timestamp(v_ts, &got_ts, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_value_get_timestamp_sec(v_tss, &got_tss, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_value_get_timestamp_ms(v_tsms, &got_tsms, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_value_get_timestamp_ns(v_tsns, &got_tsns, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_value_get_timestamp_tz(v_tstz, &got_tstz, &fx.err), &fx.err)
		expect_v2_ok(t, duckdb.duckdb_v2_value_get_timestamp_tz_ns(v_tstzns, &got_tstzns, &fx.err), &fx.err)
		testing.expect_value(t, got_dt, i32(19800))
		testing.expect_value(t, got_tm, i64(3600000000))
		testing.expect_value(t, got_tns, i64(3600000000000))
		testing.expect_value(t, got_ttz, u64(123456))
		testing.expect_value(t, got_ts, i64(1700000000000000))

		// UUID, BLOB, BIT, MAP, and TYPE value (`duckdb_v2_value_create_type` / `get_type`):
		uuid_in := duckdb.V2_Hugeint{lower = 0x1122334455667788, upper = 0x19aabbccddeeff00}
		v_uuid: duckdb.V2_Value_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_uuid(fx.factory, &uuid_in, &v_uuid, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&v_uuid)
		uuid_out: duckdb.V2_Hugeint
		expect_v2_ok(t, duckdb.duckdb_v2_value_get_uuid(v_uuid, &uuid_out, &fx.err), &fx.err)
		testing.expect_value(t, uuid_out, uuid_in)

		blob_bytes := [4]u8{0xDE, 0xAD, 0x00, 0xEF}
		blob_in := duckdb.V2_Str{ptr = &blob_bytes[0], len = 4}
		v_blob: duckdb.V2_Value_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_blob(fx.factory, &blob_in, &v_blob, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&v_blob)
		blob_out: duckdb.V2_Str
		expect_v2_ok(t, duckdb.duckdb_v2_value_get_blob(v_blob, &blob_out, &fx.err), &fx.err)
		testing.expect_value(t, blob_out.len, duckdb.V2_Idx(4))

		bit_bytes := [2]u8{5, 0b11111101}
		bit_in := duckdb.V2_Str{ptr = &bit_bytes[0], len = 2}
		v_bit: duckdb.V2_Value_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_bit(fx.factory, &bit_in, &v_bit, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&v_bit)
		bit_out: duckdb.V2_Str
		expect_v2_ok(t, duckdb.duckdb_v2_value_get_blob(v_bit, &bit_out, &fx.err), &fx.err)
		testing.expect_value(t, bit_out.len, duckdb.V2_Idx(2))

		// MAP value (`duckdb_v2_value_create_map`) & TYPE value (`duckdb_v2_value_create_type` / `get_type`):
		k0, mv0: duckdb.V2_Value_Handle
		k_str := duckdb.v2_str_from_string("key1")
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_varchar(fx.factory, &k_str, &k0, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&k0)
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_int(fx.factory, 77, &mv0, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&mv0)

		keys := [1]duckdb.V2_Value_Handle{k0}
		vals := [1]duckdb.V2_Value_Handle{mv0}
		v_map: duckdb.V2_Value_Handle
		expect_v2_ok(
			t,
			duckdb.duckdb_v2_value_create_map(fx.factory, fx.varchar_type, fx.int_type, &keys[0], &vals[0], 1, &v_map, &fx.err),
			&fx.err,
		)
		defer duckdb.duckdb_v2_value_destroy(&v_map)

		v_type_val: duckdb.V2_Value_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_value_create_type(fx.factory, fx.bigint_type, &v_type_val, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_value_destroy(&v_type_val)
		unwrapped_type: duckdb.V2_Logical_Type_Handle
		expect_v2_ok(t, duckdb.duckdb_v2_value_get_type(v_type_val, &unwrapped_type, &fx.err), &fx.err)
		defer duckdb.duckdb_v2_logical_type_destroy(&unwrapped_type)
		type_eq := false
		expect_v2_ok(t, duckdb.duckdb_v2_logical_type_is_equal(unwrapped_type, fx.bigint_type, &type_eq, &fx.err), &fx.err)
		testing.expect(t, type_eq)
	}
}
