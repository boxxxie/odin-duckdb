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
//   Quack remote tables & RPC, Parquet/CSV readers).
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
	 scratch:   int    `duckdb:"-"`,
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

		q_pq := duckdb.query_from_parquet("s3://bucket/*.parquet")
		testing.expect_value(t, duckdb.query_to_sql(q_pq), "SELECT * FROM read_parquet('s3://bucket/*.parquet')")
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
	duckdb.query_order_by(&q_exec, " region ASC")

	expect_query_column(&fx, duckdb.query_to_sql(q_exec), []i64{40, 90})
}

// ----------------------------------------------------------------------------
// 3. Layer 3: Schema Introspection & Odin Struct Codegen
// ----------------------------------------------------------------------------

@(test)
spec_layer3_schema_introspection_and_odin_struct_codegen :: proc(t: ^testing.T) {
	fx := dsl_with_memory_db(t)

	sqllogic_statement_ok(
		&fx,
		"CREATE TABLE telemetry_events (event_id BIGINT, service VARCHAR, cpu_pct DOUBLE, ok BOOLEAN)",
	)

	cols, rc := duckdb.introspect_table_schema(fx.conn, "telemetry_events", context.temp_allocator, &fx.err)
	expect_v2_ok(t, rc, &fx.err)
	testing.expect_value(t, len(cols), 4)

	if len(cols) == 4 {
		testing.expect_value(t, cols[0].name, "event_id")
		testing.expect_value(t, cols[0].type_id, duckdb.V2_Logical_Type_Id.BIGINT)
		testing.expect_value(t, cols[1].name, "service")
		testing.expect_value(t, cols[1].type_id, duckdb.V2_Logical_Type_Id.VARCHAR)
		testing.expect_value(t, cols[2].name, "cpu_pct")
		testing.expect_value(t, cols[2].type_id, duckdb.V2_Logical_Type_Id.DOUBLE)
		testing.expect_value(t, cols[3].name, "ok")
		testing.expect_value(t, cols[3].type_id, duckdb.V2_Logical_Type_Id.BOOLEAN)
	}

	code := duckdb.generate_odin_struct_code("models", "Telemetry_Event", cols[:], context.temp_allocator)
	expected_code := `package models

Telemetry_Event :: struct {
	event_id: i64 ` + "`duckdb:\"event_id\"`" + `,
	service: string ` + "`duckdb:\"service\"`" + `,
	cpu_pct: f64 ` + "`duckdb:\"cpu_pct\"`" + `,
	ok: bool ` + "`duckdb:\"ok\"`" + `,
}
`
	testing.expect_value(t, strings.trim_space(code), strings.trim_space(expected_code))
}
