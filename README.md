# `odin-duckdb` — DuckDB 2.0, Quack Protocol & Relational DSL for Odin

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Odin](https://img.shields.io/badge/Odin-dev--2026-3882D2.svg)](https://odin-lang.org/)
[![DuckDB](https://img.shields.io/badge/DuckDB-v2.0%20(C%20API%20v2)-FFF000.svg)](https://duckdb.org/)

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
git clone https://github.com/your-org/odin-duckdb.git
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
└── tests/              # 4-Layer ATDD Executable Specifications
    ├── dsl.odin        # Layer 2: Scoped V2 environment fixture with zero-leak verification
    ├── drivers.odin    # Layer 3: Protocol drivers for C API v2 & Arrow
    ├── sqllogic.odin   # Layer 3: SQLLogicTest directive runner
    └── *_spec.odin     # Layer 1: Executable specifications covering all C API v2 & DSL modules
```

---

## Running Checks & Tests

```bash
# Type-check the library package without an entry point
odin check duckdb -no-entry-point

# Run the full ATDD executable specification suite
odin test tests
```

---

## License

Released under the [MIT License](LICENSE).
