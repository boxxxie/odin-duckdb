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

### Odin ↔ DuckDB Type Mapping

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
├── benchmarks/         # 48-benchmark suite, hugi history store & DuckDB-on-Parquet SQL
│   ├── bench_main.odin # Benchmark harness emitting HPKT run packets & JSONL logs
│   ├── history.hugidb  # Compressed xitdb multi-commit benchmark history
│   ├── query_hugidb.sql# DuckDB SQL analytics over exported Parquet history
│   └── update_readme.sh# Latency-tiered Markdown table generator
└── tests/              # 4-Layer ATDD Executable Specifications
    ├── dsl.odin        # Layer 2: Scoped V2 environment fixture with zero-leak verification
    ├── drivers.odin    # Layer 3: Protocol drivers for C API v2 & Arrow
    ├── sqllogic.odin   # Layer 3: SQLLogicTest directive runner
    └── *_spec.odin     # Layer 1: Executable specifications covering all C API v2 & DSL modules
```

---

## Running Checks, Tests & Benchmarks

```bash
# Type-check the library package and benchmark harness
odin check duckdb -no-entry-point
odin check benchmarks -collection:hugi=../hugi/hugi

# Run the full ATDD executable specification suite
odin test tests

# Run the statistical benchmark suite via hugi (stores exact batch samples in benchmarks/history.hugidb)
hugi run benchmarks --runs 5 --warmup 1 \
  --extra-build-flags '-microarch:native -extra-linker-flags:"-L/home/pauli/.local/lib -Wl,-rpath,/home/pauli/.local/lib"'

# Compare the last two commits for speedups or regressions
hugi compare --last --db benchmarks/history.hugidb

# Regenerate the latency-tiered statistical tables in benchmarks/README.md and README.md
./benchmarks/update_readme.sh

# Export history to Apache Parquet and query latency tiers & commit trends with DuckDB SQL
hugi export --db benchmarks/history.hugidb --all-commits --out .tmp/history.parquet
duckdb -markdown -light-mode -f benchmarks/query_hugidb.sql
```

### Baseline Benchmark Results (`-o:speed -microarch:native`)

`hugi run benchmarks` captures exact integer batch nanosecond samples (`HPKT` packets) and stores pooled multi-commit history in [`benchmarks/history.hugidb`](benchmarks/history.hugidb) alongside legacy JSONL logs ([`benchmarks/odin.jsonl`](benchmarks/odin.jsonl), [`benchmarks/history.jsonl`](benchmarks/history.jsonl)). Use `hugi compare --last` for Welch `t`-test / Mann-Whitney U regression analysis, [`./benchmarks/update_readme.sh`](benchmarks/update_readme.sh) to regenerate the latency-tiered bandwidth tables below, and [`benchmarks/query_hugidb.sql`](benchmarks/query_hugidb.sql) to query exported Parquet histories (`DECIMAL(18,6)` timings) directly in DuckDB. See [`benchmarks/README.md`](benchmarks/README.md) for full details.

<!-- BEGIN_BENCHMARK_TABLE -->
### 1. Latest Code-Change Impact & Affected Benchmarks (`6a128a2f8c8a` → `eed3bbe02f72`)

> **Benchmark Scope:** `6a128a2f8c8a` → `eed3bbe02f72` (48 / 48 benchmarks compared)

#### 1.1 Vectorized Zero-Copy Scans, UDFs & Wire Codecs (`ns`, 24 tests)

| # | Benchmark | Verdict | Delta | Speedup | Base `6a128a2` (`ns`) | Curr `eed3bbe` (`ns`) | Welch $z$ | Base Mean ± σ | Curr Mean ± σ |
| ---: | :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 5 | `1e. Ingest: Custom V2_Copy_Function COPY ... FROM (1M rows)` | **FASTER** | `-61.1%` | 2.57x | 21.4 | **8.3** | `2.7` | 20.9 ± 7.6 | 11.2 ± 3.8 |
| 6 | `1f. Export: Custom V2_Copy_Function COPY ... TO Sink (1M rows)` | `~NOISE` | `+9.0%` | 0.92x | 3.0 | **3.2** | `0.8` | 3.3 ± 0.5 | 3.0 ± 0.5 |
| 8 | `2a. Scan: Zero-Copy V2_Vector_View Flat (1M rows)` | `~NOISE` | `-8.5%` | 1.09x | 6.3 | **5.8** | `0.9` | 6.2 ± 0.7 | 5.8 ± 0.7 |
| 9 | `2b. Scan: Zero-Copy V2_Selection_Vector Filtered (1M source rows)` | **FASTER** | `-13.9%` | 1.16x | 4.4 | **3.8** | `3.0` | 4.4 ± 0.5 | 3.8 ± 0.2 |
| 10 | `2c. Scan: Arrow C Data Interface Arrow_Array_Stream (1M rows)` | `~NOISE` | `-13.8%` | 1.16x | 6.8 | **5.8** | `3.7` | 7.1 ± 0.8 | 5.5 ± 0.6 |
| 13 | `2f. Scan: Direct ColumnDataCollection Worker Scan (1M rows)` | `~NOISE` | `+2.8%` | 0.97x | 1.0 | **1.0** | `0.5` | 1.0 ± 0.1 | 1.1 ± 0.2 |
| 14 | `2g. Bridge: Arrow_Exporter -> Arrow_Importer Round-Trip (200K)` | **FASTER** | `-26.2%` | 1.35x | 5.2 | **3.8** | `10.3` | 5.2 ± 0.2 | 3.8 ± 0.2 |
| 15 | `2h. Scan: Multi-Worker ColumnDataCollection 4-Thread Scan (1M)` | `~NOISE` | `-16.3%` | 1.19x | 0.4 | **0.4** | `0.5` | 0.5 ± 0.1 | 0.4 ± 0.1 |
| 16 | `2i. Scan: Cooperative Stepper v2_step_chunk (1M rows)` | **FASTER** | `-15.7%` | 1.19x | 5.8 | **4.9** | `3.3` | 6.2 ± 0.6 | 5.1 ± 0.6 |
| 17 | `3a. V2_Bytes Write: Inline <= 12 B (v2_vector_assign_string, 200K)` | **FASTER** | `-30.9%` | 1.45x | 6.9 | **4.8** | `12.6` | 7.0 ± 0.4 | 4.7 ± 0.2 |
| 18 | `3b. V2_Bytes Write: Arena > 12 B (v2_vector_assign_string, 200K)` | **FASTER** | `-36.3%` | 1.57x | 21.9 | **14.0** | `11.2` | 21.9 ± 0.1 | 14.6 ± 1.7 |
| 19 | `3c. Vector Cast: duckdb_v2_vector_cast BIGINT -> DOUBLE (200K)` | `~NOISE` | `-37.5%` | 1.60x | 0.5 | **0.3** | `32.9` | 0.5 ± 0.0 | 0.3 ± 0.0 |
| 20 | `3d. Zero-Copy Alias: duckdb_v2_vector_reference (200K rows)` | `~NOISE` | `+0.0%` | 0.99x | 0.0 | **0.0** | `10.0` | 0.0 ± 0.0 | 0.0 ± 0.0 |
| 21 | `3e. Vector Flatten: .OTHER (MakeSequence) -> .FLAT (1M rows)` | `~NOISE` | `-36.1%` | 1.57x | 0.4 | **0.2** | `101.4` | 0.4 ± 0.0 | 0.2 ± 0.0 |
| 22 | `3f. Wire Codec: 128-Bit HUGEINT/INTERVAL/BIT/BIGNUM (200K)` | **FASTER** | `-37.7%` | 1.61x | 1.9 | **1.2** | `81.4` | 1.9 ± 0.0 | 1.2 ± 0.0 |
| 24 | `4b. Native STRUCT(...) Child Vector Write+Read (200K structs)` | `~NOISE` | `-43.7%` | 1.78x | 0.9 | **0.5** | `17.1` | 0.9 ± 0.0 | 0.5 ± 0.0 |
| 25 | `4c. Nested LIST(BIGINT) Vector Write+Read (200K lists / 800K items)` | `~NOISE` | `-38.8%` | 1.63x | 1.2 | **0.7** | `13.6` | 1.2 ± 0.0 | 0.8 ± 0.1 |
| 26 | `4d. Fixed ARRAY(DOUBLE, 4) Vector Write+Read (200K arrays / 800K f64)` | `~NOISE` | `-42.6%` | 1.74x | 0.9 | **0.5** | `15.8` | 0.9 ± 0.1 | 0.5 ± 0.0 |
| 31 | `5d. Lexer: Native C API v2 duckdb_v2_tokenize_sql (300K tokens)` | **FASTER** | `-36.6%` | 1.58x | 64.1 | **40.6** | `13.4` | 66.2 ± 4.3 | 40.6 ± 0.1 |
| 35 | `6a. UDF: Vectorized Scalar Callback odin_fma (1M rows)` | **FASTER** | `-36.0%` | 1.56x | 1.5 | **1.0** | `3.4` | 1.5 ± 0.2 | 1.1 ± 0.3 |
| 36 | `6b. UDF: Streaming Table Function odin_gen_series (1M rows)` | **FASTER** | `-42.6%` | 1.74x | 4.2 | **2.4** | `5.8` | 4.1 ± 0.0 | 2.7 ± 0.6 |
| 37 | `6c. UDF: Grouped Hash Aggregate odin_agg_sum (1M rows)` | `~NOISE` | `-16.5%` | 1.20x | 2.8 | **2.4** | `1.8` | 2.8 ± 0.3 | 2.4 ± 0.4 |
| 38 | `6d. UDF: Table Function Projection + Filter Pushdown (1M rows)` | `~NOISE` | `-41.2%` | 1.70x | 0.8 | **0.4** | `37.2` | 0.7 ± 0.0 | 0.4 ± 0.0 |
| 39 | `6e. UDF: Custom Type & Vectorized V2_Cast_Function (1M rows)` | `~NOISE` | `-38.1%` | 1.62x | 1.1 | **0.7** | `9.5` | 1.1 ± 0.0 | 0.7 ± 0.1 |


#### 1.2 Sub-Microsecond Reflection Ingest, Unmarshaling & DSL Compilation (`ns`, 11 tests)

| # | Benchmark | Verdict | Delta | Speedup | Base `6a128a2` (`ns`) | Curr `eed3bbe` (`ns`) | Welch $z$ | Base Mean ± σ | Curr Mean ± σ |
| ---: | :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 2 | `1b. Ingest: Legacy V1 Appender API (100K rows)` | **FASTER** | `-35.4%` | 1.55x | 258 | **166** | `6.5` | 255 ± 27.1 | 165 ± 17.5 |
| 3 | `1c. Ingest: V2 ColumnDataCollection append_slice (100K rows)` | `~NOISE` | `-37.7%` | 1.60x | 199 | **124** | `1.3` | 263 ± 168 | 154 ± 101 |
| 4 | `1d. Ingest: Nullable Maybe(T) append_slice (100K rows, 25% NULL)` | `~NOISE` | `-40.2%` | 1.67x | 197 | **118** | `1.5` | 240 ± 123 | 146 ± 74.3 |
| 7 | `1g. Ingest: Struct_Appender(T) 1K x 100-Row Micro-Batches (100K)` | `~NOISE` | `-33.6%` | 1.51x | 174 | **116** | `2.0` | 233 ± 119 | 124 ± 20.2 |
| 11 | `2d. Unmarshal: core:reflect query_as Non-Null Structs (100K rows)` | **FASTER** | `-30.1%` | 1.43x | 100 | **69.9** | `12.1` | 101 ± 5.3 | 70.7 ± 1.7 |
| 12 | `2e. Unmarshal: core:reflect query_as Nullable Maybe(T) (100K rows)` | **FASTER** | `-31.4%` | 1.46x | 133 | **91.5** | `15.6` | 135 ± 4.8 | 93.7 ± 4.1 |
| 23 | `4a. JSON Tag Round-Trip: append_slice + query_as (10K structs)` | **FASTER** | `-36.3%` | 1.57x | 833 | **531** | `12.3` | 843 ± 23.4 | 549 ± 56.4 |
| 28 | `5a. DSL: query_to_sql Pipeline Compilation (100K queries)` | **FASTER** | `-35.6%` | 1.55x | 352 | **227** | `143.7` | 353 ± 0.6 | 226 ± 2.2 |
| 30 | `5c. Parser: sqllogic_parse_script (50K directives / 1K scripts)` | **FASTER** | `-43.1%` | 1.76x | 99.3 | **56.5** | `14.9` | 99.2 ± 0.5 | 60.4 ± 6.9 |
| 33 | `5f. Quack: SQL Builders + URI Normalize + Template (100K ops)` | **FASTER** | `-36.3%` | 1.57x | 126 | **80.2** | `69.8` | 126 ± 0.7 | 80.4 ± 1.5 |
| 34 | `5g. Reflection DDL: create_table_sql + v2_quote_identifier (100K)` | **FASTER** | `-37.1%` | 1.59x | 327 | **206** | `44.0` | 330 ± 5.6 | 205 ± 3.4 |


#### 1.3 Multi-Microsecond Point Lookups, Catalog, VFS & Transactions (`µs`, 13 tests)

| # | Benchmark | Verdict | Delta | Speedup | Base `6a128a2` (`µs`) | Curr `eed3bbe` (`µs`) | Welch $z$ | Base Mean ± σ | Curr Mean ± σ |
| ---: | :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | `1a. Ingest: V2 Prepared Statement Loop (2K rows)` | **FASTER** | `-36.4%` | 1.57x | 231.9 | **147.4** | `45.2` | 231.8 ± 2.57 | 148.8 ± 3.79 |
| 27 | `4e. Composite Values: VARIANT/MAP/UNION/DECIMAL (10K ops)` | **FASTER** | `-38.2%` | 1.62x | 5.83 | **3.60** | `52.3` | 5.85 ± 0.09 | 3.61 ± 0.04 |
| 29 | `5b. Codegen: introspect_table_schema + Odin/CUE (1K tables)` | **FASTER** | `-39.5%` | 1.65x | 7.52 | **4.55** | `30.8` | 7.56 ± 0.10 | 4.61 ± 0.22 |
| 32 | `5e. Catalog: duckdb_v2_connection_describe_table (5K lookups)` | **FASTER** | `-37.5%` | 1.60x | 4.77 | **2.98** | `22.1` | 4.81 ± 0.08 | 3.03 ± 0.19 |
| 40 | `6f. UDF: V2_Replacement_Scan Virtual Table Scan (1K queries)` | **FASTER** | `-35.5%` | 1.55x | 416.5 | **268.7** | `35.2` | 419.3 ± 8.24 | 269.1 ± 5.69 |
| 41 | `6g. Extensibility: V2_Pragma + V2_Custom_Option + V2_Macro (1K)` | **FASTER** | `-38.8%` | 1.63x | 111.5 | **68.3** | `40.1` | 112.3 ± 2.41 | 68.2 ± 0.53 |
| 42 | `7a. Point Lookup: Ad-Hoc v2_query Parse+Bind+Exec (1K queries)` | **FASTER** | `-39.5%` | 1.65x | 366.8 | **222.0** | `43.6` | 369.6 ± 7.54 | 221.8 ± 0.91 |
| 43 | `7b. Point Lookup: Pre-Compiled v2_prepared_execute (1K queries)` | **FASTER** | `-42.1%` | 1.73x | 318.6 | **184.6** | `57.9` | 318.9 ± 4.08 | 186.3 ± 3.66 |
| 44 | `7c. DSL Pipeline: query_execute_as Build+Bind+Unmarshal (1K)` | **FASTER** | `-35.5%` | 1.55x | 658.2 | **424.8** | `54.5` | 659.5 ± 6.78 | 426.2 ± 8.01 |
| 45 | `7d. Transactions: v2_with_transaction Commit + Rollback (1K tx)` | **FASTER** | `-41.2%` | 1.70x | 216.5 | **127.3** | `64.5` | 216.8 ± 2.50 | 128.1 ± 2.11 |
| 46 | `7e. Prepared DSL: prepared_query_execute_as Cached Plan+Schema (1K)` | **FASTER** | `-37.2%` | 1.59x | 555.0 | **348.4** | `70.4` | 555.3 ± 3.69 | 349.5 ± 6.38 |
| 47 | `8a. VFS: Positional write_at + read_at (1K x 64 KB = 64 MB)` | **FASTER** | `-41.0%` | 1.69x | 3.79 | **2.24** | `115.2` | 3.80 ± 0.03 | 2.23 ± 0.01 |
| 48 | `8b. Telemetry: V2_Query_Metrics Tree + V2_Log_Sink (10K ops)` | **FASTER** | `-37.4%` | 1.60x | 16.6 | **10.4** | `102.7` | 16.6 ± 0.09 | 10.4 ± 0.12 |


### 2. Odin Full Suite Results (`-o:speed -microarch:native`, Commit `eed3bbe02f72`, 7 samples across 1 run(s))

#### 2.1 Vectorized Zero-Copy Scans, UDFs & Wire Codecs (`< 50 ns` · `20M–160B ops/s`, 24 tests)

| # | Benchmark | Med (`ns`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops | Bandwidth |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 5 | `1e. Ingest: Custom V2_Copy_Function COPY ... FROM (1M rows)` | **8.3** | 11.2 ± 3.8 | 33.7% | 62.9M | 124M | 6.7 | 15.6 | 15.9 | 8.1 | 15.9 | 1M | 1834.0 MB/s |
| 6 | `1f. Export: Custom V2_Copy_Function COPY ... TO Sink (1M rows)` | **3.2** | 3.0 ± 0.5 | 18.1% | 279M | 429M | 0.9 | 3.6 | 3.6 | 2.3 | 3.6 | 1M | 4710.3 MB/s |
| 8 | `2a. Scan: Zero-Copy V2_Vector_View Flat (1M rows)` | **5.8** | 5.8 ± 0.7 | 12.8% | 147M | 214M | 0.8 | 6.7 | 6.8 | 4.7 | 6.8 | 1M | 4134.6 MB/s |
| 9 | `2b. Scan: Zero-Copy V2_Selection_Vector Filtered (1M source rows)` | **3.8** | 3.8 ± 0.2 | 6.2% | 247M | 290M | 0.4 | 4.0 | 4.0 | 3.4 | 4.0 | 1M | 6256.6 MB/s |
| 10 | `2c. Scan: Arrow C Data Interface Arrow_Array_Stream (1M rows)` | **5.8** | 5.5 ± 0.6 | 11.2% | 157M | 208M | 1.0 | 6.3 | 6.4 | 4.8 | 6.4 | 1M | 4091.2 MB/s |
| 13 | `2f. Scan: Direct ColumnDataCollection Worker Scan (1M rows)` | **1.0** | 1.1 ± 0.2 | 16.8% | 691M | 1.1B | 0.1 | 1.4 | 1.4 | 0.9 | 1.4 | 1M | 14.2 GB/s |
| 14 | `2g. Bridge: Arrow_Exporter -> Arrow_Importer Round-Trip (200K)` | **3.8** | 3.8 ± 0.2 | 5.0% | 243M | 275M | 0.3 | 4.1 | 4.1 | 3.6 | 4.1 | 200K | 4004.9 MB/s |
| 15 | `2h. Scan: Multi-Worker ColumnDataCollection 4-Thread Scan (1M)` | **0.4** | 0.4 ± 0.1 | 30.9% | 1.4B | 3.0B | 0.1 | 0.6 | 0.7 | 0.3 | 0.7 | 1M | 41.1 GB/s |
| 16 | `2i. Scan: Cooperative Stepper v2_step_chunk (1M rows)` | **4.9** | 5.1 ± 0.6 | 11.3% | 166M | 222M | 0.8 | 5.9 | 6.0 | 4.5 | 6.0 | 1M | 4845.4 MB/s |
| 17 | `3a. V2_Bytes Write: Inline <= 12 B (v2_vector_assign_string, 200K)` | **4.8** | 4.7 ± 0.2 | 5.0% | 204M | 239M | 0.0 | 4.9 | 4.9 | 4.2 | 4.9 | 200K | 2391.5 MB/s |
| 18 | `3b. V2_Bytes Write: Arena > 12 B (v2_vector_assign_string, 200K)` | **14.0** | 14.6 ± 1.7 | 11.6% | 54.1M | 72.2M | 0.2 | 17.2 | 18.2 | 13.8 | 18.5 | 200K | 2185.2 MB/s |
| 19 | `3c. Vector Cast: duckdb_v2_vector_cast BIGINT -> DOUBLE (200K)` | **0.3** | 0.3 ± 0.0 | 1.9% | 3.2B | 3.4B | 0.0 | 0.3 | 0.3 | 0.3 | 0.3 | 200K | 49.8 GB/s |
| 20 | `3d. Zero-Copy Alias: duckdb_v2_vector_reference (200K rows)` | **0.0** | 0.0 ± 0.0 | 10.0% | 126.3B | 162.3B | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 200K | 2399.5 GB/s |
| 21 | `3e. Vector Flatten: .OTHER (MakeSequence) -> .FLAT (1M rows)` | **0.2** | 0.2 ± 0.0 | 0.8% | 4.2B | 4.3B | 0.0 | 0.2 | 0.2 | 0.2 | 0.2 | 1M | 31.4 GB/s |
| 22 | `3f. Wire Codec: 128-Bit HUGEINT/INTERVAL/BIT/BIGNUM (200K)` | **1.2** | 1.2 ± 0.0 | 1.1% | 811M | 836M | 0.0 | 1.2 | 1.2 | 1.2 | 1.2 | 200K | 37.2 GB/s |
| 24 | `4b. Native STRUCT(...) Child Vector Write+Read (200K structs)` | **0.5** | 0.5 ± 0.0 | 5.4% | 1.8B | 2.1B | 0.0 | 0.5 | 0.5 | 0.5 | 0.5 | 200K | 45.9 GB/s |
| 25 | `4c. Nested LIST(BIGINT) Vector Write+Read (200K lists / 800K items)` | **0.7** | 0.8 ± 0.1 | 10.7% | 1.1B | 1.4B | 0.0 | 0.9 | 0.9 | 0.7 | 0.9 | 200K | 61.2 GB/s |
| 26 | `4d. Fixed ARRAY(DOUBLE, 4) Vector Write+Read (200K arrays / 800K f64)` | **0.5** | 0.5 ± 0.0 | 3.4% | 1.9B | 2.1B | 0.0 | 0.5 | 0.5 | 0.5 | 0.5 | 200K | 59.8 GB/s |
| 31 | `5d. Lexer: Native C API v2 duckdb_v2_tokenize_sql (300K tokens)` | **40.6** | 40.6 ± 0.1 | 0.2% | 24.5M | 24.7M | 0.1 | 40.8 | 40.8 | 40.5 | 40.8 | 300K | — |
| 35 | `6a. UDF: Vectorized Scalar Callback odin_fma (1M rows)` | **1.0** | 1.1 ± 0.3 | 24.3% | 634M | 1.2B | 0.2 | 1.5 | 1.6 | 0.8 | 1.6 | 1M | 23.5 GB/s |
| 36 | `6b. UDF: Streaming Table Function odin_gen_series (1M rows)` | **2.4** | 2.7 ± 0.6 | 23.1% | 249M | 433M | 0.5 | 3.8 | 4.0 | 2.3 | 4.0 | 1M | 6396.1 MB/s |
| 37 | `6c. UDF: Grouped Hash Aggregate odin_agg_sum (1M rows)` | **2.4** | 2.4 ± 0.4 | 17.1% | 342M | 587M | 0.4 | 2.9 | 2.9 | 1.7 | 2.9 | 1M | 3241.8 MB/s |
| 38 | `6d. UDF: Table Function Projection + Filter Pushdown (1M rows)` | **0.4** | 0.4 ± 0.0 | 2.3% | 2.2B | 2.3B | 0.0 | 0.5 | 0.5 | 0.4 | 0.5 | 1M | 33.6 GB/s |
| 39 | `6e. UDF: Custom Type & Vectorized V2_Cast_Function (1M rows)` | **0.7** | 0.7 ± 0.1 | 13.4% | 1.1B | 1.5B | 0.0 | 0.9 | 0.9 | 0.7 | 0.9 | 1M | 21.7 GB/s |

#### 2.2 Sub-Microsecond Reflection Ingest, Unmarshaling & DSL Compilation (`50–999 ns` · `1M–20M ops/s`, 11 tests)

| # | Benchmark | Med (`ns`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops | Bandwidth |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 2 | `1b. Ingest: Legacy V1 Appender API (100K rows)` | **166** | 165 ± 17.5 | 10.6% | 5.3M | 7.0M | 24.2 | 187 | 190 | 142 | 190 | 100K | 212.0 MB/s |
| 3 | `1c. Ingest: V2 ColumnDataCollection append_slice (100K rows)` | **124** | 154 ± 101 | 65.6% | 2.6M | 10.1M | 24.6 | 308 | 367 | 99.1 | 382 | 100K | 284.1 MB/s |
| 4 | `1d. Ingest: Nullable Maybe(T) append_slice (100K rows, 25% NULL)` | **118** | 146 ± 74.3 | 51.0% | 3.2M | 9.6M | 24.0 | 262 | 301 | 105 | 311 | 100K | 300.2 MB/s |
| 7 | `1g. Ingest: Struct_Appender(T) 1K x 100-Row Micro-Batches (100K)` | **116** | 124 ± 20.2 | 16.2% | 6.4M | 9.7M | 28.3 | 152 | 156 | 104 | 157 | 100K | 305.4 MB/s |
| 11 | `2d. Unmarshal: core:reflect query_as Non-Null Structs (100K rows)` | **69.9** | 70.7 ± 1.7 | 2.4% | 13.7M | 14.5M | 2.7 | 72.9 | 73.0 | 69.0 | 73.0 | 100K | 504.7 MB/s |
| 12 | `2e. Unmarshal: core:reflect query_as Nullable Maybe(T) (100K rows)` | **91.5** | 93.7 ± 4.1 | 4.4% | 9.8M | 11.1M | 3.9 | 100 | 101 | 90.4 | 102 | 100K | 385.8 MB/s |
| 23 | `4a. JSON Tag Round-Trip: append_slice + query_as (10K structs)` | **531** | 549 ± 56.4 | 10.3% | 1.5M | 2.0M | 34.7 | 636 | 664 | 510 | 672 | 10K | 115.0 MB/s |
| 28 | `5a. DSL: query_to_sql Pipeline Compilation (100K queries)` | **227** | 226 ± 2.2 | 1.0% | 4.4M | 4.5M | 2.5 | 228 | 228 | 222 | 228 | 100K | — |
| 30 | `5c. Parser: sqllogic_parse_script (50K directives / 1K scripts)` | **56.5** | 60.4 ± 6.9 | 11.3% | 13.7M | 18.1M | 7.9 | 71.0 | 72.5 | 55.2 | 72.9 | 50K | — |
| 33 | `5f. Quack: SQL Builders + URI Normalize + Template (100K ops)` | **80.2** | 80.4 ± 1.5 | 1.9% | 11.9M | 12.6M | 0.9 | 82.7 | 83.5 | 79.2 | 83.7 | 100K | — |
| 34 | `5g. Reflection DDL: create_table_sql + v2_quote_identifier (100K)` | **206** | 205 ± 3.4 | 1.7% | 4.7M | 5.0M | 3.0 | 210 | 212 | 201 | 212 | 100K | — |

#### 2.3 Multi-Microsecond Point Lookups, Catalog, VFS & Transactions (`≥ 1 µs` · `2K–360K ops/s`, 13 tests)

| # | Benchmark | Med (`µs`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops | Bandwidth |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | `1a. Ingest: V2 Prepared Statement Loop (2K rows)` | **147.4** | 148.8 ± 3.79 | 2.5% | 6.4K | 6.9K | 2.42 | 154.9 | 156.2 | 145.6 | 156.6 | 2K | 0.2 MB/s |
| 27 | `4e. Composite Values: VARIANT/MAP/UNION/DECIMAL (10K ops)` | **3.60** | 3.61 ± 0.04 | 1.2% | 273K | 283K | 0.03 | 3.66 | 3.66 | 3.53 | 3.67 | 10K | — |
| 29 | `5b. Codegen: introspect_table_schema + Odin/CUE (1K tables)` | **4.55** | 4.61 ± 0.22 | 4.8% | 201K | 229K | 0.25 | 4.93 | 4.96 | 4.37 | 4.97 | 1K | — |
| 32 | `5e. Catalog: duckdb_v2_connection_describe_table (5K lookups)` | **2.98** | 3.03 ± 0.19 | 6.3% | 291K | 352K | 0.06 | 3.32 | 3.42 | 2.84 | 3.44 | 5K | — |
| 40 | `6f. UDF: V2_Replacement_Scan Virtual Table Scan (1K queries)` | **268.7** | 269.1 ± 5.69 | 2.1% | 3.6K | 3.8K | 4.02 | 277.2 | 279.1 | 261.5 | 279.6 | 1K | — |
| 41 | `6g. Extensibility: V2_Pragma + V2_Custom_Option + V2_Macro (1K)` | **68.3** | 68.2 ± 0.53 | 0.8% | 14.5K | 14.9K | 0.35 | 68.9 | 69.0 | 67.3 | 69.0 | 1K | — |
| 42 | `7a. Point Lookup: Ad-Hoc v2_query Parse+Bind+Exec (1K queries)` | **222.0** | 221.8 ± 0.91 | 0.4% | 4.48K | 4.54K | 1.11 | 222.9 | 223.0 | 220.4 | 223.0 | 1K | — |
| 43 | `7b. Point Lookup: Pre-Compiled v2_prepared_execute (1K queries)` | **184.6** | 186.3 ± 3.66 | 2.0% | 5.2K | 5.4K | 3.53 | 192.0 | 192.5 | 183.7 | 192.7 | 1K | — |
| 44 | `7c. DSL Pipeline: query_execute_as Build+Bind+Unmarshal (1K)` | **424.8** | 426.2 ± 8.01 | 1.9% | 2.3K | 2.4K | 11.7 | 435.8 | 436.6 | 415.8 | 436.8 | 1K | 0.1 MB/s |
| 45 | `7d. Transactions: v2_with_transaction Commit + Rollback (1K tx)` | **127.3** | 128.1 ± 2.11 | 1.6% | 7.6K | 7.9K | 2.99 | 131.1 | 131.5 | 126.2 | 131.6 | 1K | — |
| 46 | `7e. Prepared DSL: prepared_query_execute_as Cached Plan+Schema (1K)` | **348.4** | 349.5 ± 6.38 | 1.8% | 2.8K | 2.9K | 9.23 | 358.0 | 359.1 | 342.1 | 359.3 | 1K | 0.1 MB/s |
| 47 | `8a. VFS: Positional write_at + read_at (1K x 64 KB = 64 MB)` | **2.24** | 2.23 ± 0.01 | 0.6% | 446K | 454K | 0.02 | 2.24 | 2.24 | 2.20 | 2.24 | 1K | 27.3 GB/s |
| 48 | `8b. Telemetry: V2_Query_Metrics Tree + V2_Log_Sink (10K ops)` | **10.4** | 10.4 ± 0.12 | 1.2% | 94.3K | 97.7K | 0.10 | 10.5 | 10.6 | 10.2 | 10.6 | 10K | — |
<!-- END_BENCHMARK_TABLE -->

---

## License

Released under the [MIT License](LICENSE).
