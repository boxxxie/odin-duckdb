# `odin-duckdb` — DuckDB 2.0, Quack Protocol & Relational DSL for Odin

[![CI](https://github.com/boxxxie/odin-duckdb/actions/workflows/ci.yml/badge.svg)](https://github.com/boxxxie/odin-duckdb/actions/workflows/ci.yml)
[![Version](https://img.shields.io/badge/version-v0.1.0-blue.svg)](CHANGELOG.md)
[![Odin](https://img.shields.io/badge/Odin-dev--2026--09%2B-3882D2.svg)](https://odin-lang.org)
[![DuckDB](https://img.shields.io/badge/DuckDB-v2.0%20(C%20API%20v2)-FFF000.svg)](https://duckdb.org)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

`odin-duckdb` (`package duckdb`) is a zero-overhead **DuckDB 2.0** (`duckdb_v2_*`) client, **`core:reflect` struct mapper & bulk appender**, **Friendly SQL query builder**, **Quack IPC/RPC toolkit**, and **Odin/CUE schema code generator** for the [Odin programming language](https://odin-lang.org/).

---

## Features

- **Complete DuckDB 2.0 C API v2 Bindings (`duckdb/capi_v2.odin`):**
  - Distinct, type-safe opaque handles (`V2_Environment_Handle`, `V2_Instance_Handle`, `V2_Connection_Handle`, `V2_Result_Handle`, `V2_Data_Chunk_Handle`, `V2_Vector_Handle`, etc.).
  - Zero-copy 16-byte `V2_Bytes` (`VARCHAR`, `BLOB`, `BIT`, `BIGNUM`) and `V2_Vector_View` readers with automatic `.OTHER` (`SEQUENCE`, `FSST`, `SHREDDED`) vector flattening.
  - Full extensibility support: Scalar UDFs, Table Functions (with filter & projection pushdown), Aggregate Functions, Custom Types & Casts, Replacement Scans, Pragma Functions, Copy Functions, Custom Options, Virtual File Systems, Log Sinks, Query Metrics, and SQL Tokenization.
  - Native **Arrow C Data Interface** (`Arrow_Schema`, `Arrow_Array`, `Arrow_Array_Stream`, `Arrow_Exporter`, `Arrow_Importer`).
- **`core:reflect` Struct Mapping & Bulk Ingestion (`duckdb/reflect.odin`):**
  - Automatic `CREATE TABLE` DDL generation from Odin structs (`create_table_sql`).
  - High-throughput vectorized bulk ingestion (`append_slice`) powered by C API v2 `ColumnDataCollection` + `duckdb_v2_statement_add_collection`.
  - Type-checked row unmarshaling (`query_as`) with variadic parameter binding (`$1, $2, ...`), `Maybe(T)` nullable fields, and automatic JSON column serialization (`duckdb:"col,json"`).
- **Composable Friendly SQL Query Builder (`duckdb/dsl.odin`):**
  - Pipeline builder supporting DuckDB 2.0 Friendly SQL: `SELECT * EXCLUDE (...) REPLACE (...)`, `GROUP BY ALL`, `QUALIFY`, `ASOF JOIN`, `SUMMARIZE`, `USING SAMPLE`, and direct readers for Parquet, CSV, JSON, Iceberg, and Delta Lake.
- **First-Class Quack Protocol & SQLLogicTest Toolkit (`duckdb/quack.odin`):**
  - Builders for `quack_serve`, `quack_stop`, `quack_identify`, `CREATE SECRET ... TYPE quack`, `ATTACH ... (TYPE quack)`, and remote `alias.query(...)` pushdown.
  - Built-in parser and template expander for DuckDB `.test` (`SQLLogicTest`) scripts.
- **Zero-Execution Schema Introspection & Codegen (`duckdb/codegen.odin`):**
  - Inspects tables, views, or file scans via `duckdb_v2_statement_bind` without executing queries and emits idiomatic Odin structs (`generate_odin_struct_code`) and CUE schemas (`generate_cue_schema_code`).

---

## Prerequisites & Installation

### 1. System Library (`libduckdb`)

Ensure **DuckDB 2.0+** (`libduckdb.so` on Linux, `libduckdb.dylib` on macOS, or `duckdb.lib` / `duckdb.dll` on Windows) is installed and discoverable on your system library path.

```bash
# Verify libduckdb is available on Linux/macOS
ldconfig -p | grep duckdb
```

### 2. Add to Your Odin Project

Clone `odin-duckdb` into your project or Odin `shared` collection:

```bash
git clone https://github.com/boxxxie/odin-duckdb.git
```

Then import `./duckdb` (or `shared:duckdb`) in your Odin package:

```odin
import "duckdb"
```

---

## Quick Start

### 1. Opening a Session, Transactions & Parameterized Queries

```odin
package main

import "core:fmt"
import "duckdb"

main :: proc() {
	err: duckdb.V2_Error_Info_Handle
	defer duckdb.duckdb_v2_error_info_destroy(&err)

	// Open an in-memory DuckDB 2.0 session (pass a file path for persistent storage)
	db, rc := duckdb.v2_open("", &err)
	assert(rc == .NONE)
	defer _ = duckdb.v2_close(&db)

	// Execute DDL
	rc = duckdb.v2_exec_drain(db.conn, "CREATE TABLE accounts (id BIGINT PRIMARY KEY, balance BIGINT)", nil, &err)
	assert(rc == .NONE)

	// Execute parameterized DML inside an automatic BEGIN / COMMIT / ROLLBACK transaction
	seed_tx :: proc(conn: duckdb.V2_Connection_Handle, _: rawptr, e: ^duckdb.V2_Error_Info_Handle) -> duckdb.V2_Error {
		if rc := duckdb.v2_exec_drain(conn, "INSERT INTO accounts VALUES ($1, $2)", nil, e, i64(1), i64(500)); rc != .NONE {
			return rc
		}
		return duckdb.v2_exec_drain(conn, "INSERT INTO accounts VALUES ($1, $2)", nil, e, i64(2), i64(1250))
	}
	rc = duckdb.v2_with_transaction(db.conn, seed_tx, nil, &err)
	assert(rc == .NONE)

	fmt.println("Accounts seeded successfully!")
}
```

### 2. Struct Tag Reflection, Bulk Appender & `query_as`

Map Odin structs to DuckDB tables using `duckdb:"..."` field tags, bulk-insert slices via `ColumnDataCollection`, and unmarshal results directly into `[dynamic]T`:

```odin
package main

import "core:fmt"
import "duckdb"

Sensor_Meta :: struct {
	firmware: string,
	tags:     []string,
	gain:     f64,
}

Sensor_Reading :: struct {
	id:         i64           `duckdb:"id,pk"`,
	sensor_id:  string        `duckdb:"sensor_id,not_null"`,
	reading_mv: i32           `duckdb:"reading_mv,default=0"`,
	notes:      Maybe(string) `duckdb:"notes"`,
	meta:       Sensor_Meta   `duckdb:"meta,json"`,
	scratch:    int           `duckdb:"-"`, // ignored in DDL, Appender, and query_as
}

main :: proc() {
	db, _ := duckdb.v2_open("")
	defer _ = duckdb.v2_close(&db)

	// 1. Generate and execute CREATE TABLE DDL from struct tags
	ddl := duckdb.create_table_sql(Sensor_Reading, "sensor_readings")
	_ = duckdb.v2_exec_drain(db.conn, ddl)

	// 2. Bulk-append a slice of structs using V2 ColumnDataCollection
	batch := []Sensor_Reading{
		{
			id         = 1,
			sensor_id  = "alpha",
			reading_mv = 120,
			notes      = "nominal",
			meta       = {firmware = "v2.4.1", tags = {"indoor", "calibrated"}, gain = 1.25},
		},
		{
			id         = 2,
			sensor_id  = "beta",
			reading_mv = 260,
			notes      = nil, // stored as SQL NULL
			meta       = {firmware = "v2.4.1", tags = {"outdoor"}, gain = 1.50},
		},
	}
	_ = duckdb.append_slice(db.conn, "sensor_readings", batch)

	// 3. Query back into typed Odin structs with positional parameter binding
	rows, rc := duckdb.query_as(
		db.conn,
		Sensor_Reading,
		"SELECT * FROM sensor_readings WHERE reading_mv >= $1 ORDER BY id",
		context.temp_allocator,
		nil,
		i32(100),
	)
	assert(rc == .NONE)

	for r in rows {
		fmt.printf("id=%d sensor=%s mv=%d firmware=%s\n", r.id, r.sensor_id, r.reading_mv, r.meta.firmware)
	}
}
```

### 3. Composable Friendly SQL Query Builder

Build relational pipelines using DuckDB 2.0 Friendly SQL clauses (`EXCLUDE`, `REPLACE`, `GROUP BY ALL`, `QUALIFY`, `ASOF JOIN`) and execute them with bound parameters:

```odin
q := duckdb.query_from("sensor_readings")
duckdb.query_select(&q, "id", "sensor_id", "reading_mv", "notes", "meta")
duckdb.query_where_bind(&q, "sensor_id = $1 AND reading_mv >= $2", "alpha", i32(100))
duckdb.query_qualify(&q, "row_number() OVER (PARTITION BY sensor_id ORDER BY reading_mv DESC) = 1")
duckdb.query_limit(&q, 10)

rows, rc := duckdb.query_execute_as(db.conn, Sensor_Reading, q, context.temp_allocator)
```

You can also target Parquet, CSV, JSON, Iceberg, Delta Lake, or Quack remote catalogs directly:

```odin
q_parquet := duckdb.query_from_parquet("s3://my-bucket/events/*.parquet")
duckdb.query_exclude(&q_parquet, "raw_payload", "internal_trace")
duckdb.query_replace(&q_parquet, "lower(service_name) AS service_name")
```

### 4. Quack Protocol (IPC / Remote Catalogs & RPC)

Generate SQL statements for serving, authenticating, attaching, and querying DuckDB 2.0 Quack endpoints:

```odin
// Start a Quack server on an ephemeral or fixed port
serve_sql := duckdb.quack_serve_sql({
	endpoint = "quack:localhost:9999",
	token    = "cluster-secret-token",
})

// Register a scoped Quack authentication secret
secret_sql := duckdb.quack_secret_sql({
	name  = "eu_cluster_auth",
	token = "cluster-secret-token",
	scope = "quack:localhost:9999",
})

// Attach a remote Quack instance as a local catalog alias
attach_sql := duckdb.quack_attach_sql({
	endpoint  = "quack:localhost:9999",
	alias     = "remote_eu",
	read_only = true,
})

// Push down raw SQL RPC or query remote tables through the DSL
q_remote := duckdb.query_from_quack("remote_eu", "telemetry_events")
duckdb.query_select(&q_remote, "region", "count(*) AS total")
duckdb.query_group_by_all(&q_remote)
```

### 5. Schema Introspection & Odin / CUE Codegen

Inspect any table, view, or file scan without executing it and generate Odin structs or CUE schemas:

```odin
cols, rc := duckdb.introspect_table_schema(db.conn, "sensor_readings", context.temp_allocator)
assert(rc == .NONE)

odin_code := duckdb.generate_odin_struct_code("models", "Sensor_Reading_Row", cols[:])
cue_code  := duckdb.generate_cue_schema_code("schemas", "Sensor_Reading_Row", cols[:])
```

### 6. Zero-Copy Arrow C Data Interface

Stream query results directly as standard Arrow `Arrow_Schema` / `Arrow_Array` batches or convert a result into an `Arrow_Array_Stream`:

```odin
stmt: duckdb.V2_Sql_Statement_Handle
_ = duckdb.v2_parse_single_stmt(db.conn, "SELECT i FROM range(10000) t(i)", &stmt)
defer duckdb.duckdb_v2_sql_statement_destroy(&stmt)

arrow_res: duckdb.V2_Arrow_Result_Handle
_ = duckdb.duckdb_v2_statement_execute_arrow(db.conn, stmt, nil, nil, 0, 2048, &arrow_res, nil)

stream: duckdb.Arrow_Array_Stream
_ = duckdb.duckdb_v2_arrow_result_to_arrow_c_stream(&arrow_res, &stream, nil)
defer duckdb.arrow_stream_release(&stream)
```

---

## Struct Tag & Type Mapping Reference

### Supported `duckdb:"..."` Struct Tags

| Tag Syntax | Effect in `create_table_sql` / `append_slice` / `query_as` |
| :--- | :--- |
| `duckdb:"col_name"` | Maps the Odin struct field to SQL column `col_name` (automatically quoted if reserved). |
| `duckdb:"col_name,pk"` | Appends `PRIMARY KEY` to the column definition. |
| `duckdb:"col_name,not_null"` | Appends `NOT NULL` to the column definition. |
| `duckdb:"col_name,unique"` | Appends `UNIQUE` to the column definition. |
| `duckdb:"col_name,default=0"` | Appends `DEFAULT 0` to the column definition. |
| `duckdb:"col_name,json"` | Emits `JSON` column type and marshals/unmarshals nested Odin structs/slices via `core:encoding/json`. |
| `duckdb:"-"` | Ignores the field completely during DDL generation, bulk appending, and row unmarshaling. |

### Odin $\leftrightarrow$ DuckDB Type Mapping

| Odin Type | DuckDB SQL Type | C API v2 `V2_Logical_Type_Id` |
| :--- | :--- | :--- |
| `bool` | `BOOLEAN` | `.BOOLEAN` |
| `i8`, `i16`, `i32`, `i64` | `TINYINT`, `SMALLINT`, `INTEGER`, `BIGINT` | `.TINYINT`, `.SMALLINT`, `.INTEGER`, `.BIGINT` |
| `u8`, `u16`, `u32`, `u64` | `UTINYINT`, `USMALLINT`, `UINTEGER`, `UBIGINT` | `.UTINYINT`, `.USMALLINT`, `.UINTEGER`, `.UBIGINT` |
| `f32`, `f64` | `FLOAT`, `DOUBLE` | `.FLOAT`, `.DOUBLE` |
| `string` | `VARCHAR` | `.VARCHAR` |
| `[]u8` | `BLOB` | `.BLOB` |
| `duckdb.V2_Hugeint` | `HUGEINT` / `UUID` | `.HUGEINT` / `.UUID` |
| `duckdb.V2_Uhugeint` | `UHUGEINT` | `.UHUGEINT` |
| `duckdb.V2_Interval` | `INTERVAL` | `.INTERVAL` |
| `Maybe(T)` | Nullable `<SQL Type>` | Unwraps `T` and reads/writes validity mask bits |
| `T` with `duckdb:"...,json"` | `JSON` | `.VARCHAR` wire storage with JSON codec |

---

## Repository Layout

```text
odin-duckdb/
├── duckdb/
│   ├── capi_v2.odin    # DuckDB 2.0 C API v2 bindings, zero-copy views & session helpers
│   ├── duckdb.odin     # Legacy DuckDB v1 C API bindings & compatibility wrapper
│   ├── reflect.odin    # core:reflect struct tag mapper, ColumnDataCollection appender & query_as
│   ├── dsl.odin        # Composable Friendly SQL & Quack relational query builder
│   ├── quack.odin      # Quack server/secret/attach SQL builders & SQLLogicTest parser
│   └── codegen.odin    # Zero-execution table schema introspection & Odin/CUE codegen
├── benchmarks/         # Throughput & latency benchmark suite (bench_main.odin)
└── tests/              # 4-Layer ATDD Executable Specifications
    ├── dsl.odin        # Layer 2: Scoped V2 environment fixture with zero-leak verification
    ├── drivers.odin    # Layer 3: Protocol drivers for C API v2 & Arrow
    ├── sqllogic.odin   # Layer 3: SQLLogicTest directive runner
    └── *_spec.odin     # Layer 1: Executable specifications covering all C API v2 & DSL modules
```

---

## Running Checks, Tests & Benchmarks

```bash
# Type-check the library package without an entry point
odin check duckdb -no-entry-point

# Run the full ATDD executable specification suite
odin test tests

# Run the throughput & latency benchmark suite
odin run benchmarks -o:speed
```

### Baseline Benchmark Results (`-o:speed`)

| Benchmark | Items / Op | Median Time | Min Time | Throughput (ops/s) | Bandwidth (MB/s) | Latency (ns/item) |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1a. Ingest: V2 Prepared Statement Loop (2K rows) | 2000 | 293.173 ms | 287.762 ms | 6.82 K/s | 0.2 MB/s | 146586.4 ns |
| 1b. Ingest: Legacy V1 Appender API (100K rows) | 100000 | 16.308 ms | 15.006 ms | 6.13 M/s | 216.4 MB/s | 163.1 ns |
| 1c. Ingest: V2 ColumnDataCollection `append_slice` (100K rows) | 100000 | 12.056 ms | 10.987 ms | 8.29 M/s | 292.7 MB/s | 120.6 ns |
| 1d. Ingest: Nullable `Maybe(T)` `append_slice` (100K rows, 25% NULL) | 100000 | 11.620 ms | 11.167 ms | 8.61 M/s | 303.7 MB/s | 116.2 ns |
| 1e. Ingest: Custom `V2_Copy_Function` `COPY ... FROM` (1M rows) | 1000000 | 13.355 ms | 7.760 ms | 74.88 M/s | 1142.5 MB/s | 13.4 ns |
| 1f. Export: Custom `V2_Copy_Function` `COPY ... TO` Sink (1M rows) | 1000000 | 2.457 ms | 1.969 ms | 407.00 M/s | 6210.4 MB/s | 2.5 ns |
| 1g. Ingest: `Struct_Appender(T)` 1K x 100-Row Micro-Batches (100K) | 100000 | 16.349 ms | 15.007 ms | 6.12 M/s | 215.8 MB/s | 163.5 ns |
| 2a. Scan: Zero-Copy `V2_Vector_View` Flat (1M rows) | 1000000 | 4.791 ms | 4.174 ms | 208.71 M/s | 4976.1 MB/s | 4.8 ns |
| 2b. Scan: Zero-Copy `V2_Selection_Vector` Filtered (1M source rows) | 1000000 | 3.050 ms | 2.974 ms | 327.90 M/s | 7817.9 MB/s | 3.0 ns |
| 2c. Scan: Arrow C Data Interface `Arrow_Array_Stream` (1M rows) | 1000000 | 5.219 ms | 4.180 ms | 191.62 M/s | 4568.5 MB/s | 5.2 ns |
| 2d. Unmarshal: `core:reflect` `query_as` Non-Null Structs (100K rows) | 100000 | 6.681 ms | 5.761 ms | 14.97 M/s | 528.2 MB/s | 66.8 ns |
| 2e. Unmarshal: `core:reflect` `query_as` Nullable `Maybe(T)` (100K rows) | 100000 | 8.188 ms | 8.114 ms | 12.21 M/s | 430.9 MB/s | 81.9 ns |
| 2f. Scan: Direct `ColumnDataCollection` Worker Scan (1M rows) | 1000000 | 0.785 ms | 0.731 ms | 1274.03 M/s | 19440.1 MB/s | 0.8 ns |
| 2g. Bridge: `Arrow_Exporter` -> `Arrow_Importer` Round-Trip (200K) | 200000 | 0.616 ms | 0.579 ms | 324.56 M/s | 4952.3 MB/s | 3.1 ns |
| 2h. Scan: Multi-Worker `ColumnDataCollection` 4-Thread Scan (1M) | 1000000 | 0.402 ms | 0.339 ms | 2484.56 M/s | 37911.4 MB/s | 0.4 ns |
| 2i. Scan: Cooperative Stepper `v2_step_chunk` (1M rows) | 1000000 | 4.857 ms | 4.100 ms | 205.88 M/s | 4908.6 MB/s | 4.9 ns |
| 3a. `V2_Bytes` Write: Inline <= 12 B (`v2_vector_assign_string`, 200K) | 200000 | 0.943 ms | 0.829 ms | 212.10 M/s | 2427.3 MB/s | 4.7 ns |
| 3b. `V2_Bytes` Write: Arena > 12 B (`v2_vector_assign_string`, 200K) | 200000 | 2.721 ms | 2.618 ms | 73.49 M/s | 2242.7 MB/s | 13.6 ns |
| 3c. Vector Cast: `duckdb_v2_vector_cast` BIGINT -> DOUBLE (200K) | 200000 | 0.056 ms | 0.056 ms | 3556.44 M/s | 54267.0 MB/s | 0.3 ns |
| 3d. Zero-Copy Alias: `duckdb_v2_vector_reference` (200K rows) | 200000 | 0.001 ms | 0.001 ms | 167785.23 M/s | 2560199.5 MB/s | 0.0 ns |
| 3e. Vector Flatten: `.OTHER` (`MakeSequence`) -> `.FLAT` (1M rows) | 1000000 | 0.228 ms | 0.225 ms | 4392.96 M/s | 33515.6 MB/s | 0.2 ns |
| 3f. Wire Codec: 128-Bit `HUGEINT`/`INTERVAL`/`BIT`/`BIGNUM` (200K) | 200000 | 0.226 ms | 0.223 ms | 884.51 M/s | 40489.6 MB/s | 1.1 ns |
| 4a. JSON Tag Round-Trip: `append_slice` + `query_as` (10K structs) | 10000 | 5.743 ms | 5.549 ms | 1.74 M/s | 106.3 MB/s | 574.3 ns |
| 4b. Native `STRUCT(...)` Child Vector Write+Read (200K structs) | 200000 | 0.294 ms | 0.290 ms | 679.71 M/s | 16205.7 MB/s | 1.5 ns |
| 4c. Nested `LIST(BIGINT)` Vector Write+Read (200K lists / 800K items) | 200000 | 0.175 ms | 0.171 ms | 1143.65 M/s | 52352.3 MB/s | 0.9 ns |
| 4d. Fixed `ARRAY(DOUBLE, 4)` Vector Write+Read (200K arrays / 800K f64) | 200000 | 0.133 ms | 0.128 ms | 1504.55 M/s | 45915.3 MB/s | 0.7 ns |
| 4e. Composite Values: `VARIANT`/`MAP`/`UNION`/`DECIMAL` (10K ops) | 10000 | 35.163 ms | 34.629 ms | 284.39 K/s | - | 3516.3 ns |
| 5a. DSL: `query_to_sql` Pipeline Compilation (100K queries) | 100000 | 22.162 ms | 22.156 ms | 4.51 M/s | - | 221.6 ns |
| 5b. Codegen: `introspect_table_schema` + Odin/CUE (1K tables) | 1000 | 4.365 ms | 4.325 ms | 229.09 K/s | - | 4365.2 ns |
| 5c. Parser: `sqllogic_parse_script` (50K directives / 1K scripts) | 50000 | 2.819 ms | 2.787 ms | 17.74 M/s | - | 56.4 ns |
| 5d. Lexer: Native C API v2 `duckdb_v2_tokenize_sql` (300K tokens) | 300000 | 11.639 ms | 11.614 ms | 25.78 M/s | - | 38.8 ns |
| 5e. Catalog: `duckdb_v2_connection_describe_table` (5K lookups) | 5000 | 14.051 ms | 13.994 ms | 355.85 K/s | - | 2810.1 ns |
| 5f. Quack: SQL Builders + URI Normalize + Template (100K ops) | 100000 | 7.231 ms | 7.168 ms | 13.83 M/s | - | 72.3 ns |
| 5g. Reflection DDL: `create_table_sql` + `v2_quote_identifier` (100K) | 100000 | 18.959 ms | 18.854 ms | 5.27 M/s | - | 189.6 ns |
| 6a. UDF: Vectorized Scalar Callback `odin_fma` (1M rows) | 1000000 | 0.992 ms | 0.964 ms | 1007.75 M/s | 23065.6 MB/s | 1.0 ns |
| 6b. UDF: Streaming Table Function `odin_gen_series` (1M rows) | 1000000 | 2.618 ms | 2.395 ms | 382.02 M/s | 5829.1 MB/s | 2.6 ns |
| 6c. UDF: Grouped Hash Aggregate `odin_agg_sum` (1M rows) | 1000000 | 1.780 ms | 1.732 ms | 561.74 M/s | 4285.8 MB/s | 1.8 ns |
| 6d. UDF: Table Function Projection + Filter Pushdown (1M rows) | 1000000 | 0.431 ms | 0.422 ms | 2319.12 M/s | 35387.0 MB/s | 0.4 ns |
| 6e. UDF: Custom Type & Vectorized `V2_Cast_Function` (1M rows) | 1000000 | 0.789 ms | 0.751 ms | 1268.17 M/s | 19350.7 MB/s | 0.8 ns |
| 6f. UDF: `V2_Replacement_Scan` Virtual Table Scan (1K queries) | 1000 | 287.080 ms | 275.041 ms | 3.48 K/s | - | 287080.0 ns |
| 6g. Extensibility: `V2_Pragma` + `V2_Custom_Option` + `V2_Macro` (1K) | 1000 | 68.015 ms | 67.440 ms | 14.70 K/s | - | 68015.1 ns |
| 7a. Point Lookup: Ad-Hoc `v2_query` Parse+Bind+Exec (1K queries) | 1000 | 219.809 ms | 215.840 ms | 4.55 K/s | - | 219809.4 ns |
| 7b. Point Lookup: Pre-Compiled `v2_prepared_execute` (1K queries) | 1000 | 190.238 ms | 184.331 ms | 5.26 K/s | - | 190237.5 ns |
| 7c. DSL Pipeline: `query_execute_as` Build+Bind+Unmarshal (1K) | 1000 | 414.456 ms | 412.117 ms | 2.41 K/s | 0.1 MB/s | 414455.6 ns |
| 7d. Transactions: `v2_with_transaction` Commit + Rollback (1K tx) | 1000 | 125.009 ms | 124.322 ms | 8.00 K/s | - | 125008.9 ns |
| 7e. Prepared DSL: `prepared_query_execute_as` Cached Plan+Schema (1K) | 1000 | 361.787 ms | 339.281 ms | 2.76 K/s | 0.1 MB/s | 361787.1 ns |
| 8a. VFS: Positional `write_at` + `read_at` (1K x 64 KB = 64 MB) | 1000 | 2.797 ms | 2.622 ms | 357.48 K/s | 22342.7 MB/s | 2797.3 ns |
| 8b. Telemetry: `V2_Query_Metrics` Tree + `V2_Log_Sink` (10K ops) | 10000 | 101.159 ms | 100.989 ms | 98.85 K/s | - | 10115.9 ns |

---

## License

Released under the [MIT License](LICENSE).
