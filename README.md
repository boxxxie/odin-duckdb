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
### 1. Latest Code-Change Impact & Affected Benchmarks (`9ec3509e84e6` → `6a128a2f8c8a`)

> **Benchmark Scope:** `9ec3509e84e6` → `6a128a2f8c8a` (48 / 48 benchmarks compared)

#### 1.1 Vectorized Zero-Copy Scans, UDFs & Wire Codecs (`ns`, 23 tests)

| # | Benchmark | Verdict | Delta | Speedup | Base `9ec3509` (`ns`) | Curr `6a128a2` (`ns`) | Welch $z$ | Base Mean ± σ | Curr Mean ± σ |
| ---: | :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 5 | `1e. Ingest: Custom V2_Copy_Function COPY ... FROM (1M rows)` | `~NOISE` | `+45.3%` | 0.69x | 14.7 | **21.4** | `1.1` | 15.4 ± 8.6 | 20.9 ± 7.6 |
| 6 | `1f. Export: Custom V2_Copy_Function COPY ... TO Sink (1M rows)` | `~NOISE` | `-3.5%` | 1.04x | 3.1 | **3.0** | `0.4` | 3.2 ± 0.4 | 3.3 ± 0.5 |
| 8 | `2a. Scan: Zero-Copy V2_Vector_View Flat (1M rows)` | `~NOISE` | `+28.9%` | 0.78x | 4.9 | **6.3** | `2.4` | 5.0 ± 0.9 | 6.2 ± 0.7 |
| 9 | `2b. Scan: Zero-Copy V2_Selection_Vector Filtered (1M source rows)` | **REGRESSION** | `+31.4%` | 0.76x | 3.4 | **4.4** | `3.7` | 3.5 ± 0.4 | 4.4 ± 0.5 |
| 10 | `2c. Scan: Arrow C Data Interface Arrow_Array_Stream (1M rows)` | **REGRESSION** | `+24.3%` | 0.80x | 5.4 | **6.8** | `3.0` | 5.6 ± 0.9 | 7.1 ± 0.8 |
| 13 | `2f. Scan: Direct ColumnDataCollection Worker Scan (1M rows)` | `~NOISE` | `+39.4%` | 0.72x | 0.7 | **1.0** | `3.5` | 0.8 ± 0.1 | 1.0 ± 0.1 |
| 14 | `2g. Bridge: Arrow_Exporter -> Arrow_Importer Round-Trip (200K)` | **REGRESSION** | `+59.3%` | 0.63x | 3.2 | **5.2** | `4.1` | 3.8 ± 0.9 | 5.2 ± 0.2 |
| 15 | `2h. Scan: Multi-Worker ColumnDataCollection 4-Thread Scan (1M)` | `~NOISE` | `+20.5%` | 0.83x | 0.4 | **0.4** | `1.1` | 0.4 ± 0.1 | 0.5 ± 0.1 |
| 16 | `2i. Scan: Cooperative Stepper v2_step_chunk (1M rows)` | **REGRESSION** | `+19.9%` | 0.83x | 4.9 | **5.8** | `4.2` | 4.9 ± 0.4 | 6.2 ± 0.6 |
| 17 | `3a. V2_Bytes Write: Inline <= 12 B (v2_vector_assign_string, 200K)` | **REGRESSION** | `+63.6%` | 0.61x | 4.2 | **6.9** | `11.2` | 4.5 ± 0.4 | 7.0 ± 0.4 |
| 18 | `3b. V2_Bytes Write: Arena > 12 B (v2_vector_assign_string, 200K)` | **REGRESSION** | `+56.9%` | 0.64x | 14.0 | **21.9** | `118.9` | 14.0 ± 0.1 | 21.9 ± 0.1 |
| 19 | `3c. Vector Cast: duckdb_v2_vector_cast BIGINT -> DOUBLE (200K)` | `~NOISE` | `+65.0%` | 0.61x | 0.3 | **0.5** | `28.4` | 0.3 ± 0.0 | 0.5 ± 0.0 |
| 20 | `3d. Zero-Copy Alias: duckdb_v2_vector_reference (200K rows)` | `~NOISE` | `+0.0%` | 1.00x | 0.0 | **0.0** | `0.5` | 0.0 ± 0.0 | 0.0 ± 0.0 |
| 21 | `3e. Vector Flatten: .OTHER (MakeSequence) -> .FLAT (1M rows)` | `~NOISE` | `+61.6%` | 0.62x | 0.2 | **0.4** | `64.5` | 0.2 ± 0.0 | 0.4 ± 0.0 |
| 22 | `3f. Wire Codec: 128-Bit HUGEINT/INTERVAL/BIT/BIGNUM (200K)` | **REGRESSION** | `+62.2%` | 0.62x | 1.2 | **1.9** | `89.9` | 1.2 ± 0.0 | 1.9 ± 0.0 |
| 24 | `4b. Native STRUCT(...) Child Vector Write+Read (200K structs)` | `~NOISE` | `+26.9%` | 0.79x | 0.7 | **0.9** | `6.4` | 0.7 ± 0.1 | 0.9 ± 0.0 |
| 25 | `4c. Nested LIST(BIGINT) Vector Write+Read (200K lists / 800K items)` | `~NOISE` | `+63.4%` | 0.61x | 0.7 | **1.2** | `18.6` | 0.8 ± 0.1 | 1.2 ± 0.0 |
| 26 | `4d. Fixed ARRAY(DOUBLE, 4) Vector Write+Read (200K arrays / 800K f64)` | `~NOISE` | `+67.1%` | 0.60x | 0.5 | **0.9** | `14.7` | 0.5 ± 0.0 | 0.9 ± 0.1 |
| 35 | `6a. UDF: Vectorized Scalar Callback odin_fma (1M rows)` | `~NOISE` | `+36.5%` | 0.73x | 1.1 | **1.5** | `2.6` | 1.2 ± 0.2 | 1.5 ± 0.2 |
| 36 | `6b. UDF: Streaming Table Function odin_gen_series (1M rows)` | **REGRESSION** | `+51.8%` | 0.66x | 2.7 | **4.2** | `14.0` | 2.7 ± 0.3 | 4.1 ± 0.0 |
| 37 | `6c. UDF: Grouped Hash Aggregate odin_agg_sum (1M rows)` | `~NOISE` | `+17.4%` | 0.85x | 2.4 | **2.8** | `1.5` | 2.4 ± 0.5 | 2.8 ± 0.3 |
| 38 | `6d. UDF: Table Function Projection + Filter Pushdown (1M rows)` | `~NOISE` | `+57.1%` | 0.64x | 0.5 | **0.8** | `19.1` | 0.5 ± 0.0 | 0.7 ± 0.0 |
| 39 | `6e. UDF: Custom Type & Vectorized V2_Cast_Function (1M rows)` | `~NOISE` | `+44.3%` | 0.69x | 0.8 | **1.1** | `11.0` | 0.8 ± 0.1 | 1.1 ± 0.0 |


#### 1.2 Sub-Microsecond Reflection Ingest, Unmarshaling & DSL Compilation (`ns`, 12 tests)

| # | Benchmark | Verdict | Delta | Speedup | Base `9ec3509` (`ns`) | Curr `6a128a2` (`ns`) | Welch $z$ | Base Mean ± σ | Curr Mean ± σ |
| ---: | :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 2 | `1b. Ingest: Legacy V1 Appender API (100K rows)` | **REGRESSION** | `+53.9%` | 0.65x | 167 | **258** | `6.0` | 170 ± 16.7 | 255 ± 27.1 |
| 3 | `1c. Ingest: V2 ColumnDataCollection append_slice (100K rows)` | `~NOISE` | `+51.5%` | 0.66x | 132 | **199** | `0.9` | 178 ± 126 | 263 ± 168 |
| 4 | `1d. Ingest: Nullable Maybe(T) append_slice (100K rows, 25% NULL)` | `~NOISE` | `+58.8%` | 0.63x | 124 | **197** | `1.5` | 150 ± 65.6 | 240 ± 123 |
| 7 | `1g. Ingest: Struct_Appender(T) 1K x 100-Row Micro-Batches (100K)` | `~NOISE` | `+25.4%` | 0.80x | 139 | **174** | `1.2` | 162 ± 66.3 | 233 ± 119 |
| 11 | `2d. Unmarshal: core:reflect query_as Non-Null Structs (100K rows)` | **REGRESSION** | `+55.6%` | 0.64x | 64.3 | **100** | `13.5` | 64.9 ± 2.6 | 101 ± 5.3 |
| 12 | `2e. Unmarshal: core:reflect query_as Nullable Maybe(T) (100K rows)` | **REGRESSION** | `+50.9%` | 0.66x | 88.4 | **133** | `16.2` | 88.7 ± 4.3 | 135 ± 4.8 |
| 23 | `4a. JSON Tag Round-Trip: append_slice + query_as (10K structs)` | **REGRESSION** | `+57.1%` | 0.64x | 530 | **833** | `13.1` | 556 ± 42.9 | 843 ± 23.4 |
| 28 | `5a. DSL: query_to_sql Pipeline Compilation (100K queries)` | **REGRESSION** | `+56.7%` | 0.64x | 225 | **352** | `144.4` | 224 ± 1.9 | 353 ± 0.6 |
| 30 | `5c. Parser: sqllogic_parse_script (50K directives / 1K scripts)` | **REGRESSION** | `+59.5%` | 0.63x | 62.2 | **99.3** | `111.6` | 62.1 ± 0.6 | 99.2 ± 0.5 |
| 31 | `5d. Lexer: Native C API v2 duckdb_v2_tokenize_sql (300K tokens)` | **REGRESSION** | `+57.1%` | 0.64x | 40.8 | **64.1** | `13.4` | 40.7 ± 0.2 | 66.2 ± 4.3 |
| 33 | `5f. Quack: SQL Builders + URI Normalize + Template (100K ops)` | **REGRESSION** | `+63.9%` | 0.61x | 76.8 | **126** | `157.6` | 76.8 ± 0.2 | 126 ± 0.7 |
| 34 | `5g. Reflection DDL: create_table_sql + v2_quote_identifier (100K)` | **REGRESSION** | `+63.4%` | 0.61x | 200 | **327** | `35.9` | 202 ± 5.6 | 330 ± 5.6 |


#### 1.3 Multi-Microsecond Point Lookups, Catalog, VFS & Transactions (`µs`, 13 tests)

| # | Benchmark | Verdict | Delta | Speedup | Base `9ec3509` (`µs`) | Curr `6a128a2` (`µs`) | Welch $z$ | Base Mean ± σ | Curr Mean ± σ |
| ---: | :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | `1a. Ingest: V2 Prepared Statement Loop (2K rows)` | **REGRESSION** | `+51.6%` | 0.66x | 152.9 | **231.9** | `38.4` | 153.5 ± 3.77 | 231.8 ± 2.57 |
| 27 | `4e. Composite Values: VARIANT/MAP/UNION/DECIMAL (10K ops)` | **REGRESSION** | `+56.8%` | 0.64x | 3.72 | **5.83** | `43.5` | 3.74 ± 0.06 | 5.85 ± 0.09 |
| 29 | `5b. Codegen: introspect_table_schema + Odin/CUE (1K tables)` | **REGRESSION** | `+65.7%` | 0.60x | 4.54 | **7.52** | `65.1` | 4.54 ± 0.01 | 7.56 ± 0.10 |
| 32 | `5e. Catalog: duckdb_v2_connection_describe_table (5K lookups)` | **REGRESSION** | `+62.7%` | 0.61x | 2.93 | **4.77** | `33.6` | 2.97 ± 0.09 | 4.81 ± 0.08 |
| 40 | `6f. UDF: V2_Replacement_Scan Virtual Table Scan (1K queries)` | **REGRESSION** | `+52.7%` | 0.65x | 272.8 | **416.5** | `23.4` | 277.9 ± 10.7 | 419.3 ± 8.24 |
| 41 | `6g. Extensibility: V2_Pragma + V2_Custom_Option + V2_Macro (1K)` | **REGRESSION** | `+63.6%` | 0.61x | 68.2 | **111.5** | `33.5` | 68.1 ± 1.69 | 112.3 ± 2.41 |
| 42 | `7a. Point Lookup: Ad-Hoc v2_query Parse+Bind+Exec (1K queries)` | **REGRESSION** | `+67.6%` | 0.60x | 218.9 | **366.8** | `39.5` | 217.6 ± 4.14 | 369.6 ± 7.54 |
| 43 | `7b. Point Lookup: Pre-Compiled v2_prepared_execute (1K queries)` | **REGRESSION** | `+66.8%` | 0.60x | 191.0 | **318.6** | `40.7` | 193.3 ± 5.57 | 318.9 ± 4.08 |
| 44 | `7c. DSL Pipeline: query_execute_as Build+Bind+Unmarshal (1K)` | **REGRESSION** | `+51.8%` | 0.66x | 433.7 | **658.2** | `34.7` | 440.0 ± 12.4 | 659.5 ± 6.78 |
| 45 | `7d. Transactions: v2_with_transaction Commit + Rollback (1K tx)` | **REGRESSION** | `+64.0%` | 0.61x | 132.0 | **216.5** | `62.0` | 131.8 ± 1.77 | 216.8 ± 2.50 |
| 46 | `7e. Prepared DSL: prepared_query_execute_as Cached Plan+Schema (1K)` | **REGRESSION** | `+54.1%` | 0.65x | 360.2 | **555.0** | `61.3` | 360.5 ± 6.07 | 555.3 ± 3.69 |
| 47 | `8a. VFS: Positional write_at + read_at (1K x 64 KB = 64 MB)` | **REGRESSION** | `+36.8%` | 0.73x | 2.77 | **3.79** | `71.2` | 2.77 ± 0.02 | 3.80 ± 0.03 |
| 48 | `8b. Telemetry: V2_Query_Metrics Tree + V2_Log_Sink (10K ops)` | **REGRESSION** | `+57.9%` | 0.63x | 10.5 | **16.6** | `79.6` | 10.6 ± 0.14 | 16.6 ± 0.09 |


### 2. Odin Full Suite Results (`-o:speed -microarch:native`, Commit `6a128a2f8c8a`, 5 samples across 1 run(s))

#### 2.1 Vectorized Zero-Copy Scans, UDFs & Wire Codecs (`< 50 ns` · `20M–160B ops/s`, 23 tests)

| # | Benchmark | Med (`ns`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops | Bandwidth |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 5 | `1e. Ingest: Custom V2_Copy_Function COPY ... FROM (1M rows)` | **21.4** | 20.9 ± 7.6 | 36.1% | 30.9M | 83.7M | 5.1 | 30.3 | 31.9 | 11.9 | 32.3 | 1M | 714.0 MB/s |
| 6 | `1f. Export: Custom V2_Copy_Function COPY ... TO Sink (1M rows)` | **3.0** | 3.3 ± 0.5 | 16.3% | 249M | 353M | 0.8 | 3.9 | 4.0 | 2.8 | 4.0 | 1M | 5134.9 MB/s |
| 8 | `2a. Scan: Zero-Copy V2_Vector_View Flat (1M rows)` | **6.3** | 6.2 ± 0.7 | 12.1% | 142M | 191M | 1.1 | 7.0 | 7.0 | 5.2 | 7.0 | 1M | 3782.8 MB/s |
| 9 | `2b. Scan: Zero-Copy V2_Selection_Vector Filtered (1M source rows)` | **4.4** | 4.4 ± 0.5 | 10.4% | 198M | 252M | 0.7 | 5.0 | 5.0 | 4.0 | 5.1 | 1M | 5385.8 MB/s |
| 10 | `2c. Scan: Arrow C Data Interface Arrow_Array_Stream (1M rows)` | **6.8** | 7.1 ± 0.8 | 11.2% | 119M | 155M | 0.7 | 8.2 | 8.3 | 6.5 | 8.4 | 1M | 3525.3 MB/s |
| 13 | `2f. Scan: Direct ColumnDataCollection Worker Scan (1M rows)` | **1.0** | 1.0 ± 0.1 | 12.1% | 801M | 1.1B | 0.1 | 1.2 | 1.2 | 0.9 | 1.2 | 1M | 14.6 GB/s |
| 14 | `2g. Bridge: Arrow_Exporter -> Arrow_Importer Round-Trip (200K)` | **5.2** | 5.2 ± 0.2 | 4.8% | 181M | 201M | 0.4 | 5.5 | 5.5 | 5.0 | 5.5 | 200K | 2957.3 MB/s |
| 15 | `2h. Scan: Multi-Worker ColumnDataCollection 4-Thread Scan (1M)` | **0.4** | 0.5 ± 0.1 | 15.3% | 1.7B | 2.4B | 0.0 | 0.6 | 0.6 | 0.4 | 0.6 | 1M | 34.4 GB/s |
| 16 | `2i. Scan: Cooperative Stepper v2_step_chunk (1M rows)` | **5.8** | 6.2 ± 0.6 | 9.6% | 141M | 174M | 0.7 | 7.0 | 7.1 | 5.7 | 7.1 | 1M | 4082.4 MB/s |
| 17 | `3a. V2_Bytes Write: Inline <= 12 B (v2_vector_assign_string, 200K)` | **6.9** | 7.0 ± 0.4 | 5.1% | 130M | 147M | 0.1 | 7.5 | 7.6 | 6.8 | 7.7 | 200K | 1653.6 MB/s |
| 18 | `3b. V2_Bytes Write: Arena > 12 B (v2_vector_assign_string, 200K)` | **21.9** | 21.9 ± 0.1 | 0.5% | 45.5M | 46.0M | 0.1 | 22.0 | 22.0 | 21.7 | 22.0 | 200K | 1392.6 MB/s |
| 19 | `3c. Vector Cast: duckdb_v2_vector_cast BIGINT -> DOUBLE (200K)` | **0.5** | 0.5 ± 0.0 | 2.4% | 2.0B | 2.1B | 0.0 | 0.5 | 0.5 | 0.5 | 0.5 | 200K | 31.1 GB/s |
| 20 | `3d. Zero-Copy Alias: duckdb_v2_vector_reference (200K rows)` | **0.0** | 0.0 ± 0.0 | 5.4% | 93.7B | 106.8B | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 200K | 1509.7 GB/s |
| 21 | `3e. Vector Flatten: .OTHER (MakeSequence) -> .FLAT (1M rows)` | **0.4** | 0.4 ± 0.0 | 0.7% | 2.67B | 2.72B | 0.0 | 0.4 | 0.4 | 0.4 | 0.4 | 1M | 20.0 GB/s |
| 22 | `3f. Wire Codec: 128-Bit HUGEINT/INTERVAL/BIT/BIGNUM (200K)` | **1.9** | 1.9 ± 0.0 | 0.8% | 512M | 524M | 0.0 | 1.9 | 2.0 | 1.9 | 2.0 | 200K | 23.2 GB/s |
| 24 | `4b. Native STRUCT(...) Child Vector Write+Read (200K structs)` | **0.9** | 0.9 ± 0.0 | 5.2% | 1.0B | 1.2B | 0.1 | 1.0 | 1.0 | 0.9 | 1.0 | 200K | 25.8 GB/s |
| 25 | `4c. Nested LIST(BIGINT) Vector Write+Read (200K lists / 800K items)` | **1.2** | 1.2 ± 0.0 | 2.7% | 792M | 842M | 0.0 | 1.3 | 1.3 | 1.2 | 1.3 | 200K | 37.5 GB/s |
| 26 | `4d. Fixed ARRAY(DOUBLE, 4) Vector Write+Read (200K arrays / 800K f64)` | **0.9** | 0.9 ± 0.1 | 5.8% | 1.0B | 1.2B | 0.0 | 0.9 | 0.9 | 0.8 | 1.0 | 200K | 34.3 GB/s |
| 35 | `6a. UDF: Vectorized Scalar Callback odin_fma (1M rows)` | **1.5** | 1.5 ± 0.2 | 10.5% | 601M | 794M | 0.2 | 1.6 | 1.7 | 1.3 | 1.7 | 1M | 15.0 GB/s |
| 36 | `6b. UDF: Streaming Table Function odin_gen_series (1M rows)` | **4.2** | 4.1 ± 0.0 | 1.2% | 239M | 246M | 0.1 | 4.2 | 4.2 | 4.1 | 4.2 | 1M | 3669.6 MB/s |
| 37 | `6c. UDF: Grouped Hash Aggregate odin_agg_sum (1M rows)` | **2.8** | 2.8 ± 0.3 | 12.1% | 307M | 430M | 0.2 | 3.2 | 3.2 | 2.3 | 3.3 | 1M | 2708.3 MB/s |
| 38 | `6d. UDF: Table Function Projection + Filter Pushdown (1M rows)` | **0.8** | 0.7 ± 0.0 | 2.1% | 1.3B | 1.4B | 0.0 | 0.8 | 0.8 | 0.7 | 0.8 | 1M | 19.8 GB/s |
| 39 | `6e. UDF: Custom Type & Vectorized V2_Cast_Function (1M rows)` | **1.1** | 1.1 ± 0.0 | 3.4% | 864M | 940M | 0.1 | 1.2 | 1.2 | 1.1 | 1.2 | 1M | 13.4 GB/s |

#### 2.2 Sub-Microsecond Reflection Ingest, Unmarshaling & DSL Compilation (`50–999 ns` · `1M–20M ops/s`, 12 tests)

| # | Benchmark | Med (`ns`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops | Bandwidth |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 2 | `1b. Ingest: Legacy V1 Appender API (100K rows)` | **258** | 255 ± 27.1 | 10.6% | 3.4M | 4.4M | 32.2 | 288 | 293 | 228 | 295 | 100K | 137.0 MB/s |
| 3 | `1c. Ingest: V2 ColumnDataCollection append_slice (100K rows)` | **199** | 263 ± 168 | 64.0% | 1.8M | 5.9M | 21.1 | 491 | 549 | 170 | 563 | 100K | 177.1 MB/s |
| 4 | `1d. Ingest: Nullable Maybe(T) append_slice (100K rows, 25% NULL)` | **197** | 240 ± 123 | 51.1% | 2.2M | 5.8M | 29.9 | 407 | 448 | 172 | 459 | 100K | 179.6 MB/s |
| 7 | `1g. Ingest: Struct_Appender(T) 1K x 100-Row Micro-Batches (100K)` | **174** | 233 ± 119 | 51.0% | 2.3M | 5.9M | 33.7 | 396 | 434 | 168 | 444 | 100K | 202.9 MB/s |
| 11 | `2d. Unmarshal: core:reflect query_as Non-Null Structs (100K rows)` | **100** | 101 ± 5.3 | 5.3% | 9.1M | 10.5M | 2.9 | 108 | 109 | 95.6 | 109 | 100K | 352.8 MB/s |
| 12 | `2e. Unmarshal: core:reflect query_as Nullable Maybe(T) (100K rows)` | **133** | 135 ± 4.8 | 3.6% | 7.1M | 7.7M | 7.8 | 141 | 141 | 131 | 141 | 100K | 264.5 MB/s |
| 23 | `4a. JSON Tag Round-Trip: append_slice + query_as (10K structs)` | **833** | 843 ± 23.4 | 2.8% | 1.1M | 1.2M | 7.9 | 875 | 882 | 827 | 884 | 10K | 73.3 MB/s |
| 28 | `5a. DSL: query_to_sql Pipeline Compilation (100K queries)` | **352** | 353 ± 0.6 | 0.2% | 2.83M | 2.84M | 1.0 | 353 | 353 | 352 | 353 | 100K | — |
| 30 | `5c. Parser: sqllogic_parse_script (50K directives / 1K scripts)` | **99.3** | 99.2 ± 0.5 | 0.5% | 10.0M | 10.2M | 0.1 | 99.5 | 99.6 | 98.4 | 99.6 | 50K | — |
| 31 | `5d. Lexer: Native C API v2 duckdb_v2_tokenize_sql (300K tokens)` | **64.1** | 66.2 ± 4.3 | 6.4% | 13.6M | 15.7M | 1.5 | 72.0 | 73.3 | 63.7 | 73.7 | 300K | — |
| 33 | `5f. Quack: SQL Builders + URI Normalize + Template (100K ops)` | **126** | 126 ± 0.7 | 0.5% | 7.9M | 8.0M | 1.0 | 127 | 127 | 125 | 127 | 100K | — |
| 34 | `5g. Reflection DDL: create_table_sql + v2_quote_identifier (100K)` | **327** | 330 ± 5.6 | 1.7% | 2.9M | 3.1M | 1.4 | 337 | 339 | 326 | 340 | 100K | — |

#### 2.3 Multi-Microsecond Point Lookups, Catalog, VFS & Transactions (`≥ 1 µs` · `2K–360K ops/s`, 13 tests)

| # | Benchmark | Med (`µs`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops | Bandwidth |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | `1a. Ingest: V2 Prepared Statement Loop (2K rows)` | **231.9** | 231.8 ± 2.57 | 1.1% | 4.3K | 4.4K | 3.75 | 234.8 | 235.0 | 228.9 | 235.1 | 2K | 0.2 MB/s |
| 27 | `4e. Composite Values: VARIANT/MAP/UNION/DECIMAL (10K ops)` | **5.83** | 5.85 ± 0.09 | 1.5% | 167K | 173K | 0.05 | 5.97 | 6.00 | 5.79 | 6.00 | 10K | — |
| 29 | `5b. Codegen: introspect_table_schema + Odin/CUE (1K tables)` | **7.52** | 7.56 ± 0.10 | 1.4% | 129K | 134K | 0.09 | 7.70 | 7.72 | 7.46 | 7.73 | 1K | — |
| 32 | `5e. Catalog: duckdb_v2_connection_describe_table (5K lookups)` | **4.77** | 4.81 ± 0.08 | 1.7% | 202K | 210K | 0.03 | 4.93 | 4.95 | 4.76 | 4.96 | 5K | — |
| 40 | `6f. UDF: V2_Replacement_Scan Virtual Table Scan (1K queries)` | **416.5** | 419.3 ± 8.24 | 2.0% | 2.3K | 2.4K | 6.21 | 429.7 | 431.1 | 409.5 | 431.5 | 1K | — |
| 41 | `6g. Extensibility: V2_Pragma + V2_Custom_Option + V2_Macro (1K)` | **111.5** | 112.3 ± 2.41 | 2.1% | 8.6K | 9.1K | 1.21 | 115.6 | 116.3 | 110.3 | 116.4 | 1K | — |
| 42 | `7a. Point Lookup: Ad-Hoc v2_query Parse+Bind+Exec (1K queries)` | **366.8** | 369.6 ± 7.54 | 2.0% | 2.6K | 2.8K | 2.30 | 379.8 | 381.9 | 362.9 | 382.5 | 1K | — |
| 43 | `7b. Point Lookup: Pre-Compiled v2_prepared_execute (1K queries)` | **318.6** | 318.9 ± 4.08 | 1.3% | 3.1K | 3.2K | 3.27 | 324.3 | 325.3 | 315.5 | 325.6 | 1K | — |
| 44 | `7c. DSL Pipeline: query_execute_as Build+Bind+Unmarshal (1K)` | **658.2** | 659.5 ± 6.78 | 1.0% | 1.50K | 1.53K | 11.4 | 667.2 | 667.6 | 652.5 | 667.7 | 1K | 0.1 MB/s |
| 45 | `7d. Transactions: v2_with_transaction Commit + Rollback (1K tx)` | **216.5** | 216.8 ± 2.50 | 1.2% | 4.5K | 4.7K | 3.00 | 219.9 | 220.3 | 214.2 | 220.5 | 1K | — |
| 46 | `7e. Prepared DSL: prepared_query_execute_as Cached Plan+Schema (1K)` | **555.0** | 555.3 ± 3.69 | 0.7% | 1.78K | 1.82K | 1.44 | 560.0 | 560.9 | 551.0 | 561.1 | 1K | 0.1 MB/s |
| 47 | `8a. VFS: Positional write_at + read_at (1K x 64 KB = 64 MB)` | **3.79** | 3.80 ± 0.03 | 0.7% | 260K | 265K | 0.03 | 3.84 | 3.84 | 3.77 | 3.84 | 1K | 16.1 GB/s |
| 48 | `8b. Telemetry: V2_Query_Metrics Tree + V2_Log_Sink (10K ops)` | **16.6** | 16.6 ± 0.09 | 0.5% | 60.0K | 60.8K | 0.05 | 16.7 | 16.7 | 16.4 | 16.7 | 10K | — |
<!-- END_BENCHMARK_TABLE -->

---

## License

Released under the [MIT License](LICENSE).
