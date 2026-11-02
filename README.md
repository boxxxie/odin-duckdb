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

# Run the statistical benchmark suite (writes to benchmarks/odin.jsonl and appends to benchmarks/history.jsonl)
odin run benchmarks -o:speed -microarch:native -- --runs 5 --warmup 1

# Or run via the statistical runner/analyzer (supports --list-commits, --inspect, --compare-commits)
./benchmarks/compare_1v1.py --runs 5 --warmup 1

# Regenerate the latency-tiered statistical tables in benchmarks/README.md and README.md
./benchmarks/update_readme.sh
```

### Baseline Benchmark Results (`-o:speed -microarch:native`)

Each run of `odin run benchmarks -o:speed -microarch:native` writes 48 enriched JSONL records (with Git `commit`, `run_id`, `median_ns`, `mean_ns`, `stddev_ns`, `variance_ns2`, `cv_pct`, `iqr_ns`, `p95_ns`, `p99_ns`, `min_ns`, `max_ns`, `ops_per_sec`, `mb_per_sec`, and raw `samples_ns`) to [`benchmarks/odin.jsonl`](benchmarks/odin.jsonl) and appends to [`benchmarks/history.jsonl`](benchmarks/history.jsonl) for multi-run sample pooling, Welch's $z$-test commit regression analysis ([`./benchmarks/compare_1v1.py`](benchmarks/compare_1v1.py)), automatic latency-tiered table generation ([`./benchmarks/update_readme.sh`](benchmarks/update_readme.sh)), and DuckDB-native querying (`SELECT * FROM 'benchmarks/history.jsonl'`). See [`benchmarks/README.md`](benchmarks/README.md) for full details.

<!-- BEGIN_BENCHMARK_TABLE -->
### 1. Odin Full Suite Results (`-o:speed -microarch:native`, Commit `9ec3509e84e6`, 5 samples across 1 run(s))

#### 1.1 Vectorized Zero-Copy Scans, UDFs & Wire Codecs (`< 50 ns` · `20M–160B ops/s`, 24 tests)

| # | Benchmark | Med (`ns`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops | Bandwidth |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 5 | `1e. Ingest: Custom V2_Copy_Function COPY ... FROM (1M rows)` | **14.7** | 15.4 ± 8.6 | 55.5% | 33.7M | 118M | 6.3 | 26.8 | 29.1 | 8.5 | 29.7 | 1M | 1037.3 MB/s |
| 6 | `1f. Export: Custom V2_Copy_Function COPY ... TO Sink (1M rows)` | **3.1** | 3.2 ± 0.4 | 11.8% | 275M | 362M | 0.6 | 3.6 | 3.6 | 2.8 | 3.6 | 1M | 4954.2 MB/s |
| 8 | `2a. Scan: Zero-Copy V2_Vector_View Flat (1M rows)` | **4.9** | 5.0 ± 0.9 | 18.2% | 156M | 246M | 1.3 | 6.3 | 6.4 | 4.1 | 6.4 | 1M | 4875.6 MB/s |
| 9 | `2b. Scan: Zero-Copy V2_Selection_Vector Filtered (1M source rows)` | **3.4** | 3.5 ± 0.4 | 11.7% | 243M | 336M | 0.4 | 4.1 | 4.1 | 3.0 | 4.1 | 1M | 7074.7 MB/s |
| 10 | `2c. Scan: Arrow C Data Interface Arrow_Array_Stream (1M rows)` | **5.4** | 5.6 ± 0.9 | 15.6% | 135M | 211M | 0.6 | 7.0 | 7.3 | 4.8 | 7.4 | 1M | 4382.7 MB/s |
| 13 | `2f. Scan: Direct ColumnDataCollection Worker Scan (1M rows)` | **0.7** | 0.8 ± 0.1 | 19.1% | 1.0B | 1.6B | 0.2 | 1.0 | 1.0 | 0.6 | 1.0 | 1M | 20.4 GB/s |
| 14 | `2g. Bridge: Arrow_Exporter -> Arrow_Importer Round-Trip (200K)` | **3.2** | 3.8 ± 0.9 | 22.7% | 192M | 326M | 1.1 | 5.1 | 5.2 | 3.1 | 5.2 | 200K | 4709.5 MB/s |
| 15 | `2h. Scan: Multi-Worker ColumnDataCollection 4-Thread Scan (1M)` | **0.4** | 0.4 ± 0.1 | 24.6% | 1.7B | 3.1B | 0.1 | 0.6 | 0.6 | 0.3 | 0.6 | 1M | 41.4 GB/s |
| 16 | `2i. Scan: Cooperative Stepper v2_step_chunk (1M rows)` | **4.9** | 4.9 ± 0.4 | 8.6% | 178M | 227M | 0.5 | 5.5 | 5.6 | 4.4 | 5.6 | 1M | 4895.7 MB/s |
| 17 | `3a. V2_Bytes Write: Inline <= 12 B (v2_vector_assign_string, 200K)` | **4.2** | 4.5 ± 0.4 | 9.8% | 202M | 247M | 0.8 | 4.9 | 5.0 | 4.1 | 5.0 | 200K | 2705.5 MB/s |
| 18 | `3b. V2_Bytes Write: Arena > 12 B (v2_vector_assign_string, 200K)` | **14.0** | 14.0 ± 0.1 | 0.8% | 70.7M | 72.5M | 0.1 | 14.1 | 14.1 | 13.8 | 14.2 | 200K | 2184.5 MB/s |
| 19 | `3c. Vector Cast: duckdb_v2_vector_cast BIGINT -> DOUBLE (200K)` | **0.3** | 0.3 ± 0.0 | 3.9% | 3.1B | 3.4B | 0.0 | 0.3 | 0.3 | 0.3 | 0.3 | 200K | 51.4 GB/s |
| 20 | `3d. Zero-Copy Alias: duckdb_v2_vector_reference (200K rows)` | **0.0** | 0.0 ± 0.0 | 0.0% | 100.0B | 100.0B | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 200K | 1490.1 GB/s |
| 21 | `3e. Vector Flatten: .OTHER (MakeSequence) -> .FLAT (1M rows)` | **0.2** | 0.2 ± 0.0 | 2.1% | 4.2B | 4.3B | 0.0 | 0.2 | 0.2 | 0.2 | 0.2 | 1M | 32.4 GB/s |
| 22 | `3f. Wire Codec: 128-Bit HUGEINT/INTERVAL/BIT/BIGNUM (200K)` | **1.2** | 1.2 ± 0.0 | 0.8% | 826M | 840M | 0.0 | 1.2 | 1.2 | 1.2 | 1.2 | 200K | 37.6 GB/s |
| 24 | `4b. Native STRUCT(...) Child Vector Write+Read (200K structs)` | **0.7** | 0.7 ± 0.1 | 11.2% | 1.3B | 1.8B | 0.1 | 0.8 | 0.8 | 0.6 | 0.8 | 200K | 32.8 GB/s |
| 25 | `4c. Nested LIST(BIGINT) Vector Write+Read (200K lists / 800K items)` | **0.7** | 0.8 ± 0.1 | 7.0% | 1.2B | 1.4B | 0.1 | 0.8 | 0.8 | 0.7 | 0.8 | 200K | 61.2 GB/s |
| 26 | `4d. Fixed ARRAY(DOUBLE, 4) Vector Write+Read (200K arrays / 800K f64)` | **0.5** | 0.5 ± 0.0 | 3.8% | 1.8B | 2.0B | 0.0 | 0.5 | 0.5 | 0.5 | 0.6 | 200K | 57.3 GB/s |
| 31 | `5d. Lexer: Native C API v2 duckdb_v2_tokenize_sql (300K tokens)` | **40.8** | 40.7 ± 0.2 | 0.5% | 24.5M | 24.7M | 0.3 | 40.9 | 40.9 | 40.4 | 40.9 | 300K | — |
| 35 | `6a. UDF: Vectorized Scalar Callback odin_fma (1M rows)` | **1.1** | 1.2 ± 0.2 | 18.2% | 637M | 1.0B | 0.2 | 1.5 | 1.6 | 1.0 | 1.6 | 1M | 20.5 GB/s |
| 36 | `6b. UDF: Streaming Table Function odin_gen_series (1M rows)` | **2.7** | 2.7 ± 0.3 | 9.5% | 326M | 417M | 0.4 | 3.0 | 3.1 | 2.4 | 3.1 | 1M | 5568.9 MB/s |
| 37 | `6c. UDF: Grouped Hash Aggregate odin_agg_sum (1M rows)` | **2.4** | 2.4 ± 0.5 | 22.5% | 319M | 575M | 0.7 | 3.1 | 3.1 | 1.7 | 3.1 | 1M | 3178.9 MB/s |
| 38 | `6d. UDF: Table Function Projection + Filter Pushdown (1M rows)` | **0.5** | 0.5 ± 0.0 | 6.6% | 1.9B | 2.3B | 0.0 | 0.5 | 0.5 | 0.4 | 0.5 | 1M | 31.0 GB/s |
| 39 | `6e. UDF: Custom Type & Vectorized V2_Cast_Function (1M rows)` | **0.8** | 0.8 ± 0.1 | 9.6% | 1.1B | 1.5B | 0.1 | 0.9 | 0.9 | 0.7 | 0.9 | 1M | 19.4 GB/s |

#### 1.2 Sub-Microsecond Reflection Ingest, Unmarshaling & DSL Compilation (`50–999 ns` · `1M–20M ops/s`, 11 tests)

| # | Benchmark | Med (`ns`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops | Bandwidth |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 2 | `1b. Ingest: Legacy V1 Appender API (100K rows)` | **167** | 170 ± 16.7 | 9.9% | 5.3M | 6.5M | 30.1 | 188 | 189 | 154 | 190 | 100K | 210.9 MB/s |
| 3 | `1c. Ingest: V2 ColumnDataCollection append_slice (100K rows)` | **132** | 178 ± 126 | 71.1% | 2.5M | 9.2M | 21.4 | 349 | 392 | 109 | 403 | 100K | 268.3 MB/s |
| 4 | `1d. Ingest: Nullable Maybe(T) append_slice (100K rows, 25% NULL)` | **124** | 150 ± 65.6 | 43.8% | 3.7M | 8.8M | 6.9 | 239 | 261 | 113 | 267 | 100K | 285.1 MB/s |
| 7 | `1g. Ingest: Struct_Appender(T) 1K x 100-Row Micro-Batches (100K)` | **139** | 162 ± 66.3 | 40.9% | 3.6M | 8.5M | 7.2 | 252 | 274 | 117 | 280 | 100K | 254.4 MB/s |
| 11 | `2d. Unmarshal: core:reflect query_as Non-Null Structs (100K rows)` | **64.3** | 64.9 ± 2.6 | 4.0% | 14.6M | 16.2M | 2.2 | 68.0 | 68.4 | 61.7 | 68.5 | 100K | 548.9 MB/s |
| 12 | `2e. Unmarshal: core:reflect query_as Nullable Maybe(T) (100K rows)` | **88.4** | 88.7 ± 4.3 | 4.8% | 10.5M | 11.8M | 5.1 | 94.2 | 95.0 | 84.6 | 95.2 | 100K | 399.3 MB/s |
| 23 | `4a. JSON Tag Round-Trip: append_slice + query_as (10K structs)` | **530** | 556 ± 42.9 | 7.7% | 1.6M | 1.9M | 56.9 | 612 | 618 | 523 | 619 | 10K | 115.1 MB/s |
| 28 | `5a. DSL: query_to_sql Pipeline Compilation (100K queries)` | **225** | 224 ± 1.9 | 0.8% | 4.4M | 4.5M | 3.7 | 226 | 226 | 222 | 226 | 100K | — |
| 30 | `5c. Parser: sqllogic_parse_script (50K directives / 1K scripts)` | **62.2** | 62.1 ± 0.6 | 0.9% | 15.9M | 16.3M | 0.3 | 62.7 | 62.8 | 61.2 | 62.8 | 50K | — |
| 33 | `5f. Quack: SQL Builders + URI Normalize + Template (100K ops)` | **76.8** | 76.8 ± 0.2 | 0.3% | 13.0M | 13.1M | 0.4 | 77.1 | 77.1 | 76.5 | 77.1 | 100K | — |
| 34 | `5g. Reflection DDL: create_table_sql + v2_quote_identifier (100K)` | **200** | 202 ± 5.6 | 2.8% | 4.7M | 5.1M | 5.4 | 209 | 211 | 197 | 211 | 100K | — |

#### 1.3 Multi-Microsecond Point Lookups, Catalog, VFS & Transactions (`≥ 1 µs` · `2K–360K ops/s`, 13 tests)

| # | Benchmark | Med (`µs`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops | Bandwidth |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | `1a. Ingest: V2 Prepared Statement Loop (2K rows)` | **152.9** | 153.5 ± 3.77 | 2.5% | 6.3K | 6.7K | 5.73 | 157.7 | 158.0 | 149.1 | 158.0 | 2K | 0.2 MB/s |
| 27 | `4e. Composite Values: VARIANT/MAP/UNION/DECIMAL (10K ops)` | **3.72** | 3.74 ± 0.06 | 1.7% | 262K | 272K | 0.10 | 3.81 | 3.82 | 3.68 | 3.82 | 10K | — |
| 29 | `5b. Codegen: introspect_table_schema + Odin/CUE (1K tables)` | **4.54** | 4.54 ± 0.01 | 0.2% | 220K | 221K | 0.01 | 4.55 | 4.55 | 4.53 | 4.55 | 1K | — |
| 32 | `5e. Catalog: duckdb_v2_connection_describe_table (5K lookups)` | **2.93** | 2.97 ± 0.09 | 3.1% | 319K | 342K | 0.01 | 3.10 | 3.13 | 2.93 | 3.14 | 5K | — |
| 40 | `6f. UDF: V2_Replacement_Scan Virtual Table Scan (1K queries)` | **272.8** | 277.9 ± 10.7 | 3.9% | 3.4K | 3.7K | 16.5 | 290.8 | 291.5 | 267.6 | 291.7 | 1K | — |
| 41 | `6g. Extensibility: V2_Pragma + V2_Custom_Option + V2_Macro (1K)` | **68.2** | 68.1 ± 1.69 | 2.5% | 14.1K | 15.1K | 1.56 | 70.3 | 70.6 | 66.3 | 70.7 | 1K | — |
| 42 | `7a. Point Lookup: Ad-Hoc v2_query Parse+Bind+Exec (1K queries)` | **218.9** | 217.6 ± 4.14 | 1.9% | 4.5K | 4.7K | 7.64 | 221.6 | 221.8 | 213.2 | 221.8 | 1K | — |
| 43 | `7b. Point Lookup: Pre-Compiled v2_prepared_execute (1K queries)` | **191.0** | 193.3 ± 5.57 | 2.9% | 4.9K | 5.3K | 0.31 | 200.8 | 202.7 | 190.0 | 203.2 | 1K | — |
| 44 | `7c. DSL Pipeline: query_execute_as Build+Bind+Unmarshal (1K)` | **433.7** | 440.0 ± 12.4 | 2.8% | 2.2K | 2.3K | 8.51 | 457.0 | 460.0 | 429.9 | 460.7 | 1K | 0.1 MB/s |
| 45 | `7d. Transactions: v2_with_transaction Commit + Rollback (1K tx)` | **132.0** | 131.8 ± 1.77 | 1.3% | 7.5K | 7.7K | 0.96 | 133.7 | 133.9 | 129.1 | 133.9 | 1K | — |
| 46 | `7e. Prepared DSL: prepared_query_execute_as Cached Plan+Schema (1K)` | **360.2** | 360.5 ± 6.07 | 1.7% | 2.7K | 2.8K | 6.39 | 367.5 | 368.3 | 352.5 | 368.5 | 1K | 0.1 MB/s |
| 47 | `8a. VFS: Positional write_at + read_at (1K x 64 KB = 64 MB)` | **2.77** | 2.77 ± 0.02 | 0.6% | 358K | 364K | 0.02 | 2.79 | 2.79 | 2.75 | 2.79 | 1K | 22.0 GB/s |
| 48 | `8b. Telemetry: V2_Query_Metrics Tree + V2_Log_Sink (10K ops)` | **10.5** | 10.6 ± 0.14 | 1.4% | 93.3K | 96.1K | 0.24 | 10.7 | 10.7 | 10.4 | 10.7 | 10K | — |
<!-- END_BENCHMARK_TABLE -->

---

## License

Released under the [MIT License](LICENSE).
