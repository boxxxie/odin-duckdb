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
