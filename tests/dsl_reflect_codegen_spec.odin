package duckdb_tests

// ============================================================================
// Layer 1: Executable Specifications — 3-Layer Odin Relational DSL,
// `core:reflect` Struct Mapping & Schema Codegen (`tests/dsl_reflect_codegen_spec.odin`)
// ============================================================================
// Architectural References:
// - Layer 1 (`duckdb/reflect.odin`): `core:reflect` struct tags (`duckdb:"..."`),
//   `create_table_sql`, `append_slice` (via C API v2 `ColumnDataCollection`), and `query_as`.
// - Layer 2 (`duckdb/dsl.odin`): Composable `duckdb.Query` relational builder
//   (DuckDB 2.0 Friendly SQL: `EXCLUDE`, `REPLACE`, `GROUP BY ALL`, `QUALIFY`, `ASOF JOIN`,
//   Quack remote tables & RPC, Parquet/CSV/JSON/Iceberg/Delta readers).
// - Layer 3 (`duckdb/codegen.odin`): C API v2 `duckdb_v2_statement_bind` schema introspection
//   (`introspect_table_schema`) & Odin struct code generation (`generate_odin_struct_code`).
// ============================================================================

import "core:strings"
import "core:testing"
import duckdb "../duckdb"

// ----------------------------------------------------------------------------
// 1. Layer 1: `core:reflect` Struct Tag Mapping & Bulk Appender
// ----------------------------------------------------------------------------

Sensor_Reading :: struct {
	id:         i64    `duckdb:"id,pk"`,
	sensor_id:  string `duckdb:"sensor_id,not_null"`,
	reading_mv: i32    `duckdb:"reading_mv,default=0"`,
	calibrated: bool   `duckdb:"calibrated"`,
	scratch:    int    `duckdb:"-"`,
}

Reserved_Keyword_Row :: struct {
	id:     i64    `duckdb:"id,pk"`,
	order:  i32    `duckdb:"order,not_null"`,
	select: string `duckdb:"select"`,
}

Sensor_Meta :: struct {
	firmware: string,
	tags:     []string,
	gain:     f64,
}

Json_Tagged_Sensor :: struct {
	id:   i64         `duckdb:"id,pk"`,
	meta: Sensor_Meta `duckdb:"meta,json"`,
}

@(test)
spec_layer1_reflect_create_table_append_slice_and_query_as :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)

	// 1. `create_table_sql` inspects struct fields & `duckdb:"..."` tags via `core:reflect`:
	ddl := duckdb.create_table_sql(Sensor_Reading, "sensor_readings", true, context.temp_allocator)
	testing.expect_value(
		t,
		ddl,
		"CREATE TABLE IF NOT EXISTS sensor_readings (id BIGINT PRIMARY KEY, sensor_id VARCHAR NOT NULL, reading_mv INTEGER DEFAULT 0, calibrated BOOLEAN)",
	)
	sqllogic_statement_ok(&fx, ddl)

	// 2. `append_slice` bulk-inserts Odin structs via `V2_Column_Data_Collection_Handle`:
	batch := [3]Sensor_Reading{
		{id = 1, sensor_id = "alpha", reading_mv = 120, calibrated = true, scratch = 999},
		{id = 2, sensor_id = "beta", reading_mv = 250, calibrated = false, scratch = 888},
		{id = 3, sensor_id = "alpha", reading_mv = 180, calibrated = true, scratch = 777},
	}
	expect_v2_ok(t, duckdb.append_slice(fx.conn, "sensor_readings", batch[:], &fx.err), &fx.err)

	// 3. `query_as` executes SQL and unmarshals C API v2 vectors directly into `[]Sensor_Reading`:
	rows, rc := duckdb.query_as(
		fx.conn,
		Sensor_Reading,
		"SELECT id, sensor_id, reading_mv, calibrated FROM sensor_readings WHERE calibrated ORDER BY id",
		context.temp_allocator,
		&fx.err,
	)
	expect_v2_ok(t, rc, &fx.err)
	testing.expect_value(t, len(rows), 2)
	if len(rows) == 2 {
		testing.expect_value(t, rows[0].id, i64(1))
		testing.expect_value(t, rows[0].sensor_id, "alpha")
		testing.expect_value(t, rows[0].reading_mv, i32(120))
		testing.expect_value(t, rows[0].calibrated, true)
		testing.expect_value(t, rows[1].id, i64(3))
		testing.expect_value(t, rows[1].reading_mv, i32(180))
	}

	// 4. `query_as` maps columns by name (reordered projection) and rejects runtime type mismatches safely:
	reordered_rows, rc_reordered := duckdb.query_as(
		fx.conn,
		Sensor_Reading,
		"SELECT calibrated, reading_mv, sensor_id, id FROM sensor_readings WHERE id = 2",
		context.temp_allocator,
		&fx.err,
	)
	expect_v2_ok(t, rc_reordered, &fx.err)
	testing.expect_value(t, len(reordered_rows), 1)
	if len(reordered_rows) == 1 {
		testing.expect_value(t, reordered_rows[0].id, i64(2))
		testing.expect_value(t, reordered_rows[0].sensor_id, "beta")
		testing.expect_value(t, reordered_rows[0].reading_mv, i32(250))
		testing.expect_value(t, reordered_rows[0].calibrated, false)
	}

	mismatch_err: duckdb.V2_Error_Info_Handle
	defer duckdb.duckdb_v2_error_info_destroy(&mismatch_err)
	_, rc_mismatch := duckdb.query_as(
		fx.conn,
		Sensor_Reading,
		"SELECT 'not_an_integer' AS id FROM sensor_readings",
		context.temp_allocator,
		&mismatch_err,
	)
	testing.expect_value(t, rc_mismatch, duckdb.V2_Error.INPUT_INVALID)

	// 5. Reserved-word table & column quoting via `v2_quote_identifier`:
	kw_ddl := duckdb.create_table_sql(Reserved_Keyword_Row, "order", true, context.temp_allocator)
	testing.expect_value(
		t,
		kw_ddl,
		`CREATE TABLE IF NOT EXISTS "order" (id BIGINT PRIMARY KEY, "order" INTEGER NOT NULL, "select" VARCHAR)`,
	)
	sqllogic_statement_ok(&fx, kw_ddl)
	kw_batch := [1]Reserved_Keyword_Row{{id = 10, order = 7, select = "quoted_ok"}}
	expect_v2_ok(t, duckdb.append_slice(fx.conn, "order", kw_batch[:], &fx.err), &fx.err)
	kw_rows, rc_kw := duckdb.query_as(
		fx.conn,
		Reserved_Keyword_Row,
		`SELECT "select", "order", id FROM "order"`,
		context.temp_allocator,
		&fx.err,
	)
	expect_v2_ok(t, rc_kw, &fx.err)
	testing.expect_value(t, len(kw_rows), 1)
	if len(kw_rows) == 1 {
		testing.expect_value(t, kw_rows[0].id, i64(10))
		testing.expect_value(t, kw_rows[0].order, i32(7))
		testing.expect_value(t, kw_rows[0].select, "quoted_ok")
	}

	// 6. `query_as` variadic parameter binding, positional fallback, and `.OTHER` (`SEQUENCE`) vector flattening:
	seq_rows, rc_seq := duckdb.query_as(
		fx.conn,
		Sensor_Reading,
		"SELECT i, $1::VARCHAR, $2::INTEGER, true FROM range(1, 3) t(i)",
		context.temp_allocator,
		&fx.err,
		"seq_sensor",
		i32(55),
	)
	expect_v2_ok(t, rc_seq, &fx.err)
	testing.expect_value(t, len(seq_rows), 2)
	if len(seq_rows) == 2 {
		testing.expect_value(t, seq_rows[0].id, i64(1))
		testing.expect_value(t, seq_rows[0].sensor_id, "seq_sensor")
		testing.expect_value(t, seq_rows[0].reading_mv, i32(55))
		testing.expect_value(t, seq_rows[0].calibrated, true)
		testing.expect_value(t, seq_rows[1].id, i64(2))
	}

	// 7. `duckdb:"...,json"` struct tag DDL, `append_slice` marshaling, and `query_as` unmarshaling:
	json_ddl := duckdb.create_table_sql(Json_Tagged_Sensor, "json_sensors", true, context.temp_allocator)
	testing.expect_value(t, json_ddl, "CREATE TABLE IF NOT EXISTS json_sensors (id BIGINT PRIMARY KEY, meta JSON)")
	sqllogic_statement_ok(&fx, json_ddl)

	tags_in := [2]string{"calib", "outdoor"}
	json_batch := [1]Json_Tagged_Sensor{
		{id = 99, meta = Sensor_Meta{firmware = "v2.4.1", tags = tags_in[:], gain = 1.75}},
	}
	expect_v2_ok(t, duckdb.append_slice(fx.conn, "json_sensors", json_batch[:], &fx.err), &fx.err)

	json_rows, rc_json := duckdb.query_as(
		fx.conn,
		Json_Tagged_Sensor,
		"SELECT id, meta FROM json_sensors WHERE id = $1",
		context.temp_allocator,
		&fx.err,
		i64(99),
	)
	expect_v2_ok(t, rc_json, &fx.err)
	testing.expect_value(t, len(json_rows), 1)
	if len(json_rows) == 1 {
		testing.expect_value(t, json_rows[0].id, i64(99))
		testing.expect_value(t, json_rows[0].meta.firmware, "v2.4.1")
		testing.expect_value(t, json_rows[0].meta.gain, f64(1.75))
		expect_slice_equal(t, json_rows[0].meta.tags, tags_in[:])
	}

	// 8. Promoted V2 session & transaction helpers (`duckdb.v2_open`, `duckdb.v2_with_transaction`, `duckdb.v2_close`):
	v2_db, v2_open_rc := duckdb.v2_open("", &fx.err)
	expect_v2_ok(t, v2_open_rc, &fx.err)
	defer _ = duckdb.v2_close(&v2_db)
	expect_v2_ok(t, duckdb.v2_exec_drain(v2_db.conn, "CREATE TABLE v2_tx (x BIGINT)", nil, &fx.err), &fx.err)

	tx_commit_cb :: proc(c: duckdb.V2_Connection_Handle, ud: rawptr, e: ^duckdb.V2_Error_Info_Handle) -> duckdb.V2_Error {
		return duckdb.v2_exec_drain(c, "INSERT INTO v2_tx VALUES ($1)", nil, e, i64(777))
	}
	expect_v2_ok(t, duckdb.v2_with_transaction(v2_db.conn, tx_commit_cb, nil, &fx.err), &fx.err)

	// 9. V1 convenience wrapper (`duckdb.open`, `duckdb.exec`, `duckdb.sql_escape`, `duckdb.close`):
	v1_db, v1_err, v1_ok := duckdb.open("")
	testing.expectf(t, v1_ok, "expected duckdb.open to succeed, got %s", v1_err)
	if v1_ok {
		defer duckdb.close(&v1_db)
		_, exec_ok := duckdb.exec(&v1_db, "CREATE TABLE v1_smoke (id INTEGER); INSERT INTO v1_smoke VALUES (1);")
		testing.expect(t, exec_ok)
	}
	testing.expect_value(t, duckdb.sql_escape("O'Reilly"), "O''Reilly")
}

// Upstream Reference:
// - `references/zig/zuckdb.zig/src/appender.zig` & `src/row.zig`
//   (Typed struct appender & row unmarshalling across all signed/unsigned integers, floats,
//    `Maybe(T)` optional NULL fields, `[]u8` BLOB, and >2048-row multi-chunk bulk flushes)
Rich_Telemetry_Row :: struct {
	id:      i64           `duckdb:"id,pk"`,
	i8_val:  i8            `duckdb:"i8_val"`,
	i16_val: i16           `duckdb:"i16_val"`,
	u8_val:  u8            `duckdb:"u8_val"`,
	u16_val: u16           `duckdb:"u16_val"`,
	u32_val: u32           `duckdb:"u32_val"`,
	u64_val: u64           `duckdb:"u64_val"`,
	f32_val: f32           `duckdb:"f32_val"`,
	f64_val: f64           `duckdb:"f64_val"`,
	opt_num: Maybe(i64)    `duckdb:"opt_num"`,
	opt_tag: Maybe(string) `duckdb:"opt_tag"`,
	payload: []u8          `duckdb:"payload"`,
}

@(test)
spec_layer1_reflect_optional_scalars_blob_and_multi_chunk_appender :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)

	ddl := duckdb.create_table_sql(Rich_Telemetry_Row, "rich_telemetry", true, context.temp_allocator)
	testing.expect_value(
		t,
		ddl,
		"CREATE TABLE IF NOT EXISTS rich_telemetry (id BIGINT PRIMARY KEY, i8_val TINYINT, i16_val SMALLINT, u8_val UTINYINT, u16_val USMALLINT, u32_val UINTEGER, u64_val UBIGINT, f32_val FLOAT, f64_val DOUBLE, opt_num BIGINT, opt_tag VARCHAR, payload BLOB)",
	)
	sqllogic_statement_ok(&fx, ddl)

	b0 := [3]u8{0x01, 0x02, 0x03}
	b1 := [2]u8{0xFE, 0xFF}
	rows_in := [2]Rich_Telemetry_Row{
		{
			id      = 1,
			i8_val  = -8,
			i16_val = -1600,
			u8_val  = 250,
			u16_val = 60000,
			u32_val = 4000000000,
			u64_val = 9000000000000000000,
			f32_val = 1.5,
			f64_val = 2.75,
			opt_num = i64(42),
			opt_tag = "present",
			payload = b0[:],
		},
		{
			id      = 2,
			i8_val  = 7,
			i16_val = 1600,
			u8_val  = 1,
			u16_val = 2,
			u32_val = 3,
			u64_val = 4,
			f32_val = -0.5,
			f64_val = -1.25,
			opt_num = nil,
			opt_tag = nil,
			payload = b1[:],
		},
	}
	expect_v2_ok(t, duckdb.append_slice(fx.conn, "rich_telemetry", rows_in[:], &fx.err), &fx.err)

	rows_out, rc := duckdb.query_as(
		fx.conn,
		Rich_Telemetry_Row,
		"SELECT * FROM rich_telemetry ORDER BY id",
		context.temp_allocator,
		&fx.err,
	)
	expect_v2_ok(t, rc, &fx.err)
	testing.expect_value(t, len(rows_out), 2)
	if len(rows_out) == 2 {
		testing.expect_value(t, rows_out[0].i8_val, i8(-8))
		testing.expect_value(t, rows_out[0].u64_val, u64(9000000000000000000))
		testing.expect_value(t, rows_out[0].opt_num, Maybe(i64)(42))
		testing.expect_value(t, rows_out[0].opt_tag, Maybe(string)("present"))
		testing.expect_value(t, len(rows_out[0].payload), 3)

		testing.expect_value(t, rows_out[1].opt_num, Maybe(i64)(nil))
		testing.expect_value(t, rows_out[1].opt_tag, Maybe(string)(nil))
		testing.expect_value(t, len(rows_out[1].payload), 2)
	}

	// Multi-chunk bulk append (`2500` rows > `2048` standard vector size, ported from `zuckdb.zig/src/appender.zig`):
	sqllogic_statement_ok(&fx, "CREATE TABLE bulk_sensors (id BIGINT PRIMARY KEY, sensor_id VARCHAR NOT NULL, reading_mv INTEGER DEFAULT 0, calibrated BOOLEAN)")
	bulk := make([]Sensor_Reading, 2500, context.temp_allocator)
	for i := 0; i < 2500; i += 1 {
		bulk[i] = Sensor_Reading{
			id         = i64(i + 1),
			sensor_id  = "bulk",
			reading_mv = i32(i * 2),
			calibrated = (i % 2 == 0),
		}
	}
	expect_v2_ok(t, duckdb.append_slice(fx.conn, "bulk_sensors", bulk, &fx.err), &fx.err)
	expect_query_column(&fx, "SELECT count(*)::BIGINT FROM bulk_sensors", []i64{2500})
}

// ----------------------------------------------------------------------------
// 2. Layer 2: Composable `duckdb.Query` Relational Builder & Friendly SQL
// ----------------------------------------------------------------------------

@(test)
spec_layer2_composable_relational_query_builder_and_execution :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)

	// 1. DuckDB 2.0 Friendly SQL (`SELECT * EXCLUDE (...) REPLACE (...)`):
	{
		q := duckdb.query_from("users")
		duckdb.query_exclude(&q, "password_hash", "ssn")
		duckdb.query_replace(&q, "lower(email) AS email")
		duckdb.query_where(&q, "active = true")
		duckdb.query_order_by(&q, "id ASC")
		duckdb.query_limit(&q, 25, 50)

		testing.expect_value(
			t,
			duckdb.query_to_sql(q),
			"SELECT * EXCLUDE (password_hash, ssn) REPLACE (lower(email) AS email) FROM users WHERE active = true ORDER BY id ASC LIMIT 25 OFFSET 50",
		)
	}

	// 2. `GROUP BY ALL`, `QUALIFY`, `ASOF JOIN`, Quack remote table/RPC, and Parquet/CSV sources:
	{
		q_asof := duckdb.query_from("trades t")
		duckdb.query_select(&q_asof, "t.symbol", "t.ts", "q.bid")
		duckdb.query_asof_join(&q_asof, "quotes q", "t.ts >= q.ts", "symbol")
		testing.expect_value(
			t,
			duckdb.query_to_sql(q_asof),
			"SELECT t.symbol, t.ts, q.bid FROM trades t ASOF JOIN quotes q ON t.ts >= q.ts USING (symbol)",
		)

		q_quack := duckdb.query_from_quack("remote_eu", "events")
		duckdb.query_select(&q_quack, "region", "count(*) AS cnt")
		duckdb.query_group_by_all(&q_quack)
		testing.expect_value(
			t,
			duckdb.query_to_sql(q_quack),
			"SELECT region, count(*) AS cnt FROM remote_eu.events GROUP BY ALL",
		)

		q_rpc := duckdb.query_from_quack_rpc("remote_eu", "SELECT 1 AS x WHERE tag = 'ok'")
		testing.expect_value(
			t,
			duckdb.query_to_sql(q_rpc),
			"SELECT * FROM remote_eu.query('SELECT 1 AS x WHERE tag = ''ok''')",
		)

		q_pq := duckdb.query_from_parquet("s3://bucket/o'reilly/*.parquet")
		testing.expect_value(t, duckdb.query_to_sql(q_pq), "SELECT * FROM read_parquet('s3://bucket/o''reilly/*.parquet')")

		q_win_pq := duckdb.query_from_parquet(`C:\data\o'reilly\*.parquet`)
		testing.expect_value(t, duckdb.query_to_sql(q_win_pq), "SELECT * FROM read_parquet('C:/data/o''reilly/*.parquet')")

		// Lakehouse & JSON sources + `SUMMARIZE` & `USING SAMPLE` (`references/elixir/quackdb/test/quack_db/source_test.exs` & `analytics_test.exs`):
		q_json := duckdb.query_from_json("data/*.ndjson")
		testing.expect_value(t, duckdb.query_to_sql(q_json), "SELECT * FROM read_json_auto('data/*.ndjson')")

		q_ice := duckdb.query_from_iceberg("s3://warehouse/db/tbl")
		testing.expect_value(t, duckdb.query_to_sql(q_ice), "SELECT * FROM iceberg_scan('s3://warehouse/db/tbl')")

		q_delta := duckdb.query_from_delta("s3://warehouse/delta_tbl")
		testing.expect_value(t, duckdb.query_to_sql(q_delta), "SELECT * FROM delta_scan('s3://warehouse/delta_tbl')")

		q_sum := duckdb.query_from("events")
		duckdb.query_where(&q_sum, "latency_ms > 0")
		duckdb.query_summarize(&q_sum)
		testing.expect_value(t, duckdb.query_to_sql(q_sum), "SUMMARIZE SELECT * FROM events WHERE latency_ms > 0")

		q_samp := duckdb.query_from("events")
		duckdb.query_sample(&q_samp, "10 PERCENT (bernoulli)")
		testing.expect_value(t, duckdb.query_to_sql(q_samp), "SELECT * FROM events USING SAMPLE 10 PERCENT (bernoulli)")
	}

	// 3. Execute a `duckdb.Query` pipeline (`GROUP BY ALL` + `QUALIFY`) against DuckDB 2.0:
	sqllogic_statement_ok(&fx, "CREATE TABLE events (region VARCHAR, host VARCHAR, latency_ms BIGINT)")
	sqllogic_statement_ok(
		&fx,
		"INSERT INTO events VALUES ('eu', 'h1', 10), ('eu', 'h2', 40), ('us', 'h3', 20), ('us', 'h4', 90)",
	)

	q_exec := duckdb.query_from("events")
	duckdb.query_select(&q_exec, "latency_ms")
	duckdb.query_qualify(&q_exec, "row_number() OVER (PARTITION BY region ORDER BY latency_ms DESC) = 1")
	duckdb.query_order_by(&q_exec, "region ASC")

	expect_query_column(&fx, duckdb.query_to_sql(q_exec), []i64{40, 90})

	// 4. Execute a parameterized `duckdb.Query` pipeline with `query_where_bind` & `query_execute_as`:
	Event_Latency :: struct {
		region:     string `duckdb:"region"`,
		latency_ms: i64    `duckdb:"latency_ms"`,
	}
	q_bound := duckdb.query_from("events")
	duckdb.query_select(&q_bound, "region", "latency_ms")
	duckdb.query_where_bind(&q_bound, "region = $1 AND latency_ms >= $2", "eu", i64(20))
	bound_rows, bound_rc := duckdb.query_execute_as(fx.conn, Event_Latency, q_bound, context.temp_allocator, &fx.err)
	expect_v2_ok(t, bound_rc, &fx.err)
	testing.expect_value(t, len(bound_rows), 1)
	if len(bound_rows) == 1 {
		testing.expect_value(t, bound_rows[0].region, "eu")
		testing.expect_value(t, bound_rows[0].latency_ms, i64(40))
	}

	// 5. Prepare a reusable `Prepared_Query(Event_Latency)` via `query_prepare_as` and execute it multiple times:
	pq: duckdb.Prepared_Query(Event_Latency)
	expect_v2_ok(t, duckdb.query_prepare_as(fx.conn, Event_Latency, q_bound, &pq, false, context.temp_allocator, &fx.err), &fx.err)
	defer duckdb.prepared_query_destroy(&pq)

	pq_rows_eu, pq_rc_eu := duckdb.prepared_query_execute_as(&pq, context.temp_allocator, &fx.err, "eu", i64(20))
	expect_v2_ok(t, pq_rc_eu, &fx.err)
	testing.expect_value(t, len(pq_rows_eu), 1)
	if len(pq_rows_eu) == 1 {
		testing.expect_value(t, pq_rows_eu[0].region, "eu")
		testing.expect_value(t, pq_rows_eu[0].latency_ms, i64(40))
	}

	pq_rows_us, pq_rc_us := duckdb.prepared_query_execute_as(&pq, context.temp_allocator, &fx.err, "us", i64(50))
	expect_v2_ok(t, pq_rc_us, &fx.err)
	testing.expect_value(t, len(pq_rows_us), 1)
	if len(pq_rows_us) == 1 {
		testing.expect_value(t, pq_rows_us[0].region, "us")
		testing.expect_value(t, pq_rows_us[0].latency_ms, i64(90))
	}

	// 6. Stream multiple micro-batches through a reusable `Struct_Appender(Event_Latency)`:
	app: duckdb.Struct_Appender(Event_Latency)
	expect_v2_ok(t, duckdb.struct_appender_create(fx.conn, Event_Latency, "events", &app, context.temp_allocator, &fx.err), &fx.err)
	defer duckdb.struct_appender_destroy(&app)

	mb1 := [2]Event_Latency{{region = "ap", latency_ms = 12}, {region = "ap", latency_ms = 55}}
	mb2 := [1]Event_Latency{{region = "ap", latency_ms = 88}}
	expect_v2_ok(t, duckdb.struct_appender_append(&app, mb1[:], &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.struct_appender_append(&app, mb2[:], &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.struct_appender_flush(&app, &fx.err), &fx.err)

	pq_rows_ap, pq_rc_ap := duckdb.prepared_query_execute_as(&pq, context.temp_allocator, &fx.err, "ap", i64(50))
	expect_v2_ok(t, pq_rc_ap, &fx.err)
	testing.expect_value(t, len(pq_rows_ap), 2)

	// 7. Reuse `Struct_Appender` across multiple `struct_appender_flush` waves with `Maybe(T)`, `BLOB`, and `,json` fields:
	Rich_Micro_Batch_Row :: struct {
		id:      i64             `duckdb:"id,pk"`,
		opt_val: Maybe(i32)      `duckdb:"opt_val"`,
		opt_str: Maybe(string)   `duckdb:"opt_str"`,
		blob:    Maybe([]u8)     `duckdb:"blob"`,
		meta:    Maybe(Sensor_Meta) `duckdb:"meta,json"`,
	}
	rich_ddl := duckdb.create_table_sql(Rich_Micro_Batch_Row, "rich_micro_batches", true, context.temp_allocator)
	sqllogic_statement_ok(&fx, rich_ddl)

	rich_app: duckdb.Struct_Appender(Rich_Micro_Batch_Row)
	expect_v2_ok(t, duckdb.struct_appender_create(fx.conn, Rich_Micro_Batch_Row, "rich_micro_batches", &rich_app, context.temp_allocator, &fx.err), &fx.err)
	defer duckdb.struct_appender_destroy(&rich_app)

	wave1 := [2]Rich_Micro_Batch_Row{
		{id = 1, opt_val = i32(10), opt_str = "alpha", blob = []u8{1, 2, 3}, meta = Sensor_Meta{firmware = "v1", tags = {"a"}, gain = 1.5}},
		{id = 2, opt_val = nil, opt_str = nil, blob = nil, meta = nil},
	}
	expect_v2_ok(t, duckdb.struct_appender_append(&rich_app, wave1[:], &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.struct_appender_flush(&rich_app, &fx.err), &fx.err)
	// Flushing an already-empty appender is a no-op:
	expect_v2_ok(t, duckdb.struct_appender_flush(&rich_app, &fx.err), &fx.err)

	wave2 := [1]Rich_Micro_Batch_Row{
		{id = 3, opt_val = i32(30), opt_str = "gamma_long_inline_exceeding_12_bytes", blob = []u8{9, 8, 7, 6}, meta = Sensor_Meta{firmware = "v2", tags = {"b", "c"}, gain = 2.25}},
	}
	expect_v2_ok(t, duckdb.struct_appender_append(&rich_app, wave2[:], &fx.err), &fx.err)
	expect_v2_ok(t, duckdb.struct_appender_flush(&rich_app, &fx.err), &fx.err)

	rich_out, rich_rc := duckdb.query_as(
		fx.conn,
		Rich_Micro_Batch_Row,
		"SELECT id, opt_val, opt_str, blob, meta FROM rich_micro_batches ORDER BY id",
		context.temp_allocator,
		&fx.err,
	)
	expect_v2_ok(t, rich_rc, &fx.err)
	testing.expect_value(t, len(rich_out), 3)
	if len(rich_out) == 3 {
		testing.expect_value(t, rich_out[0].opt_val, Maybe(i32)(10))
		testing.expect_value(t, rich_out[1].opt_val, Maybe(i32)(nil))
		testing.expect_value(t, rich_out[1].opt_str, Maybe(string)(nil))
		testing.expect(t, rich_out[1].blob == nil)
		testing.expect(t, rich_out[1].meta == nil)
		testing.expect_value(t, rich_out[2].opt_str, Maybe(string)("gamma_long_inline_exceeding_12_bytes"))
		if m3, ok := rich_out[2].meta.?; ok {
			testing.expect_value(t, m3.firmware, "v2")
			testing.expect_value(t, len(m3.tags), 2)
			testing.expect_value(t, m3.gain, 2.25)
		} else {
			testing.expect(t, false, "expected non-nil meta on row 3")
		}
	}
}

// ----------------------------------------------------------------------------
// 3. Layer 3: Schema Introspection & Odin Struct Codegen
// ----------------------------------------------------------------------------

@(test)
spec_layer3_schema_introspection_and_odin_struct_codegen :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)

	sqllogic_statement_ok(
		&fx,
		"CREATE TABLE telemetry_events (event_id BIGINT, service VARCHAR, cpu_pct DOUBLE, ok BOOLEAN, raw_payload BLOB)",
	)

	cols, rc := duckdb.introspect_table_schema(fx.conn, "telemetry_events", context.temp_allocator, &fx.err)
	expect_v2_ok(t, rc, &fx.err)
	testing.expect_value(t, len(cols), 5)

	if len(cols) == 5 {
		testing.expect_value(t, cols[0].name, "event_id")
		testing.expect_value(t, cols[0].type_id, duckdb.V2_Logical_Type_Id.BIGINT)
		testing.expect_value(t, cols[1].name, "service")
		testing.expect_value(t, cols[1].type_id, duckdb.V2_Logical_Type_Id.VARCHAR)
		testing.expect_value(t, cols[2].name, "cpu_pct")
		testing.expect_value(t, cols[2].type_id, duckdb.V2_Logical_Type_Id.DOUBLE)
		testing.expect_value(t, cols[3].name, "ok")
		testing.expect_value(t, cols[3].type_id, duckdb.V2_Logical_Type_Id.BOOLEAN)
		testing.expect_value(t, cols[4].name, "raw_payload")
		testing.expect_value(t, cols[4].type_id, duckdb.V2_Logical_Type_Id.BLOB)
	}

	code := duckdb.generate_odin_struct_code("models", "Telemetry_Event", cols[:], context.temp_allocator)
	expected_code := `package models

Telemetry_Event :: struct {
	event_id: i64 ` + "`duckdb:\"event_id\"`" + `,
	service: string ` + "`duckdb:\"service\"`" + `,
	cpu_pct: f64 ` + "`duckdb:\"cpu_pct\"`" + `,
	ok: bool ` + "`duckdb:\"ok\"`" + `,
	raw_payload: []u8 ` + "`duckdb:\"raw_payload\"`" + `,
}
`
	testing.expect_value(t, strings.trim_space(code), strings.trim_space(expected_code))

	cue_code := duckdb.generate_cue_schema_code("schemas", "Telemetry_Event", cols[:], context.temp_allocator)
	expected_cue := `package schemas

#Telemetry_Event: {
	event_id: int64
	service: string
	cpu_pct: number
	ok: bool
	raw_payload: bytes
}
`
	testing.expect_value(t, strings.trim_space(cue_code), strings.trim_space(expected_cue))

	// Sanitize complex/unsanitized column names (expressions, leading digits, spaces, Odin keywords) and `Maybe(...)` nullable fields:
	dirty_cols := [4]duckdb.Column_Schema{
		{name = "count(*)", sql_type = "BIGINT", type_id = .BIGINT},
		{name = "1st Col-Name", sql_type = "VARCHAR", type_id = .VARCHAR, nullable = true},
		{name = "map", sql_type = "INTEGER", type_id = .INTEGER},
		{name = "***", sql_type = "BOOLEAN", type_id = .BOOLEAN},
	}
	sanitized_code := duckdb.generate_odin_struct_code("", "Dirty_Row", dirty_cols[:], context.temp_allocator)
	expected_sanitized := `Dirty_Row :: struct {
	count: i64 ` + "`duckdb:\"count(*)\"`" + `,
	col_1st_col_name: Maybe(string) ` + "`duckdb:\"1st Col-Name\"`" + `,
	map_: i32 ` + "`duckdb:\"map\"`" + `,
	col_3: bool ` + "`duckdb:\"***\"`" + `,
}`
	testing.expect_value(t, strings.trim_space(sanitized_code), strings.trim_space(expected_sanitized))

	// Reserved-word table introspection (`"order"`):
	sqllogic_statement_ok(&fx, `CREATE TABLE "order" (id BIGINT)`)
	order_cols, rc_order := duckdb.introspect_table_schema(fx.conn, "order", context.temp_allocator, &fx.err)
	expect_v2_ok(t, rc_order, &fx.err)
	testing.expect_value(t, len(order_cols), 1)
}
