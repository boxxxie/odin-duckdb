# Track 1 Specification: DuckDB 2.0, Quack Protocol & Odin DSL Resource Compendium

## 1. Objective & Scope
Gather and synthesize all technical resources, reference implementations (C, Rust, Elixir, Odin), protocol specifications (**DuckDB 2.0** & the **Quack IPC/RPC protocol**), and **Odin DSL** design patterns needed to build `boxxxie/odin-duckdb`—a production-grade DuckDB 2.0 library for Odin (`dev-2026-09`).

---

## 2. Local Environment & Binary Inventory
Before writing or linking code, agents working on `boxxxie/odin-duckdb` must account for the two DuckDB installations on this system:

| Artifact | Path | Version | Capabilities & Notes |
|----------|------|---------|----------------------|
| **DuckDB 2.0 CLI Binary** | `/home/pauli/.local/bin/duckdb` | `v2.0.0 (Cyanoptera) d54cbbe3df` | Full DuckDB 2.0 engine with built-in **`quack` protocol extension** (`quack_serve`, `quack_stop`, `TYPE quack` secret & attach, `quack_query`). **CRITICAL:** Always pass `-dark-mode` (or `-light-mode`) in non-interactive shells/subprocesses to avoid a 5-second terminal background probe timeout. |
| **System C Shared Library & Header** | `/usr/lib/libduckdb.so` & `/usr/include/duckdb.h` | `v1.5.6-1` (Arch package) | 10,342-line C API header used by `foreign import duckdb_lib "system:duckdb"`. Supports the full C API (`duckdb_open_ext`, `duckdb_prepare`, `duckdb_appender`, `duckdb_data_chunk`, `duckdb_vector`, replacement scans, scalar/table functions). |
| **QuackDB Cached Shared Library** | `/home/pauli/.cache/quackdb/duckdb/1.5.6/linux-amd64/libduckdb.so` | `v1.5.6` | Cached by Elixir `quackdb` NIF builds. |
| **Rust Reference Implementation (`llim`)** | `/home/pauli/projects/llim/src/stores.rs` | DuckDB 2.0 + Quack | Production Rust implementation of `DuckDbHandle` and `LinearStore` managing a persistent DuckDB 2.0 worker process and `quack_serve` daemon on `quack:127.0.0.1:9494`. |
| **Odin SSG Integration** | `/home/pauli/projects/odin/ssg/ssg/duckdb.odin` & `telemetry.odin` | Odin `dev-2026-09` | Proven C API bindings for schema discovery (`DESCRIBE`), `site_data.duckdb` table ingestion, and `.ssg/telemetry.duckdb` persistence. |

### Bridging `libduckdb.so` and DuckDB 2.0 (`Cyanoptera`)
Because `/usr/lib/libduckdb.so` may come from system packages (`1.5.x`) while `/home/pauli/.local/bin/duckdb` is `v2.0.0 (Cyanoptera)` with the `quack` extension:
1. **Upgrade / Override Path for `libduckdb.so`:** Allow linking against either `system:duckdb` or a DuckDB 2.0 `libduckdb.so` via `-extra-linker-flags:"-L/home/pauli/.local/lib -Wl,-rpath,/home/pauli/.local/lib"`.
2. **Dual-Backend Execution (`Engine_Backend`):** Support both:
   - `.Native_C_API`: Zero-overhead in-process `libduckdb` C API calls.
   - `.Persistent_CLI_Worker`: Persistent background `/home/pauli/.local/bin/duckdb -json -dark-mode` subprocess (identical to `/home/pauli/projects/llim/src/stores.rs`), guaranteeing 100% compatibility with DuckDB 2.0 storage format and the `quack` extension even before system `libduckdb.so` is upgraded.

---

## 3. DuckDB 2.0 & The Quack Protocol (`quack:host:port`)

### 3.1 Why Quack Protocol Matters
Standard DuckDB database files (`.duckdb`) enforce a **single-writer / exclusive file lock** per OS process: if one process opens `db.duckdb` in read-write mode, no other process can open `db.duckdb` concurrently (even for reads).

DuckDB 2.0 solves this with the **Quack protocol** (`quack` extension)—a native, vectorized client-server IPC/RPC protocol over TCP (`quack:<host>:<port>`):
- A single host process opens the `.duckdb` file (or `:memory:`) and starts a background listener via `CALL quack_serve(...)`.
- Any number of concurrent local or remote DuckDB processes, CLI sessions, or Odin services can `ATTACH 'quack:127.0.0.1:9494' AS db (TYPE quack)` and run standard SQL `SELECT`, `INSERT`, `UPDATE`, `DELETE`, or `FROM quack_query(...)` concurrently without lock contention.

### 3.2 Complete Quack Protocol SQL Reference

#### A. Server Lifecycle (Host Process)
```sql
INSTALL quack;
LOAD quack;

-- Start non-blocking Quack RPC server on TCP port 9494 with bearer token auth:
CALL quack_serve('quack:127.0.0.1:9494', token => 'my-secret-token');

-- Stop a running Quack server listener:
CALL quack_stop('quack:127.0.0.1:9494');
```
- **Important Process Lifecycle Detail (from `/home/pauli/projects/llim/src/stores.rs`):** `CALL quack_serve(...)` spawns background listener threads inside the DuckDB process and returns immediately. If the host process exits or closes the `duckdb_database` handle, the listener stops. In daemon mode, keep the host handle (or `stdin` pipe of `duckdb -batch -dark-mode`) open for the lifetime of the server.

#### B. Client Authentication & Remote Attachment
```sql
INSTALL quack;
LOAD quack;

-- 1. Register scoped authentication token (ephemeral or PERSISTENT):
CREATE OR REPLACE PERSISTENT SECRET llim_quack (
    TYPE quack,
    SCOPE 'quack:127.0.0.1:9494',
    TOKEN 'my-secret-token'
);

-- 2. Attach remote Quack server as a catalog alias:
ATTACH IF NOT EXISTS 'quack:127.0.0.1:9494' AS remote_db (TYPE quack);

-- 3. Query remote tables transparently as if they were local:
SELECT id, identifier, title FROM remote_db.issues WHERE state_type = 'started';

-- 4. Hybrid Local + Remote Join:
SELECT r.identifier, l.local_note
FROM remote_db.issues r
JOIN local_notes l ON l.issue_id = r.id;

-- 5. Explicit Remote Pass-Through RPC (`quack_query` table function):
FROM quack_query('remote_db', 'SELECT count(*) AS total FROM issues');
```

#### C. Low-Memory & Embedded Daemon Tuning
Referenced from `/home/pauli/projects/llim/src/stores.rs` (`DUCKDB_LOW_MEMORY_SQL`):
```sql
SET memory_limit = '256MB';
SET threads = 2;
SET preserve_insertion_order = false;
```

---

## 4. Reference Implementations Across Languages

### 4.1 C API Reference (`/usr/include/duckdb.h`)
The 10,342-line `/usr/include/duckdb.h` header exposes 6 primary subsystems that `boxxxie/odin-duckdb` should wrap idiomatically:

1. **Database, Config & Connection (`duckdb_open_ext`, `duckdb_connect`):**
   - Use `duckdb_create_config` + `duckdb_set_config` + `duckdb_open_ext(path, &db, cfg, &err)` so open-time errors (such as file lock conflicts or read-only mode `access_mode = READ_ONLY`) return structured diagnostic strings instead of generic `.DuckDBError`.
2. **Modern Vectorized Result Fetching (`duckdb_fetch_chunk` vs deprecated `duckdb_value_*`):**
   - `duckdb_value_varchar` and `duckdb_value_int64` are marked deprecated in `duckdb.h` because they allocate per cell and perform slow row-by-row lookups.
   - **High-performance path:** Iterate `chunk := duckdb_fetch_chunk(res)` until `chunk == nil` (up to `2048` rows per chunk):
     - `row_count := duckdb_data_chunk_get_size(chunk)`
     - `vec := duckdb_data_chunk_get_vector(chunk, col_idx)`
     - `raw_data := duckdb_vector_get_data(vec)` (cast to `[^]i64`, `[^]f64`, `[^]bool`, or `[^]duckdb_string_t`)
     - `validity := duckdb_vector_get_validity(vec)` (bitmask where bit `row_idx % 64` in `validity[row_idx / 64]` is `1` for valid, `0` for `NULL`; if `validity == nil`, all rows in the vector are non-null!).
     - **`duckdb_string_t` (16-byte struct):** If `str.inlined.length <= 12`, string bytes live inline in `str.inlined.inlined[0:length]`; if `> 12`, string bytes live at `str.pointer.ptr[0:length]`. Reading directly from `duckdb_string_t` avoids `malloc`/`duckdb_free` per cell!
3. **Prepared Statements (`duckdb_prepare`, `duckdb_bind_*`, `duckdb_execute_prepared`):**
   - Prevents SQL injection and eliminates SQL parsing overhead in loops.
   - Supports positional `$1, $2` or `?` parameters (`1`-indexed in `duckdb_bind_*`).
   - Supports `duckdb_nparams`, `duckdb_param_type`, and `duckdb_clear_bindings`.
4. **Appender API (`duckdb_appender_create_ext`, `duckdb_append_*`, `duckdb_append_data_chunk`):**
   - Fastest way to bulk-insert rows into a DuckDB table from Odin structs without formatting massive `INSERT INTO ... VALUES ...` strings.
5. **Replacement Scans (`duckdb_add_replacement_scan`):**
   - Allows registering an Odin callback whenever a SQL query references a table name or file pattern not found in the catalog (e.g., `SELECT * FROM "cue:site.cue"` or `SELECT * FROM "odin_slice:routes"`), dynamically rewriting it to a table function!
6. **Custom Scalar & Table Functions (`duckdb_scalar_function`, `duckdb_table_function`):**
   - Allows exposing native Odin procedures directly inside DuckDB SQL queries.

### 4.2 Rust Reference Implementations (`duckdb-rs` & `llim/src/stores.rs`)
- **`duckdb-rs` (`crates.io/crates/duckdb`):**
  - Modeled after `rusqlite`:
    - `conn.prepare(sql)` -> `Statement`
    - `stmt.query_map(params![a, b], |row| Ok(MyStruct { ... }))`
    - `ToSql` and `FromSql` traits for zero-boilerplate parameter binding and column decoding.
- **`/home/pauli/projects/llim/src/stores.rs` (`DuckDbHandle` & `LinearStore`):**
  - Demonstrates a battle-tested pattern for **DuckDB 2.0 + Quack**:
    1. `DuckDbHandle::open(path)` spawns a persistent `duckdb <path> -json -dark-mode` process with piped `stdin`/`stdout`.
    2. Wraps every query in a marker query (`SELECT '__LLIM_MARKER_<id>__' AS llim_marker;`) so stdout JSON arrays can be framed deterministically over a persistent pipe without restarting the process.
    3. `serve_quack(endpoint, token)` launches a dedicated daemon handle running `INSTALL quack; LOAD quack; CALL quack_serve(...)`, writes `~/.local/share/llim/quack.token` with `0600` permissions, and gracefully falls back if the database file is locked by an already-running Quack server.

### 4.3 Elixir Reference Implementations (`duckdbex` & `quackdb`)
- **`quackdb` (`/home/pauli/.cache/quackdb`):**
  - Uses precompiled `libduckdb.so` with dirty NIF schedulers for long-running analytical queries and maps DuckDB vectorized chunks directly into Elixir maps/structs.
  - Inspiration for Odin: **Pipeline-oriented query composition** (similar to Elixir's `Ecto.Query`) where query fragments are value types (`Query` struct) that can be composed and inspected before execution.

### 4.4 Audit of Existing Odin DuckDB Libraries
| Repository | Approach | Limitations | How `boxxxie/odin-duckdb` Improves |
|------------|----------|-------------|-------------------------------|
| `lionel626/duckdb-odin` | Hand-written raw C bindings for `DUCKDB_API_0_3_2` (archived July 2024) | Missing DuckDB 1.x/2.0 APIs, no Odin wrappers, no allocator integration, no Quack support. | Targets modern DuckDB 1.5+/2.0, full vectorized chunk + prepared + appender APIs, Quack protocol, Odin allocators. |
| `TheMartian0x48/duckdb-odin` | Raw `odin-c-bindgen` dump of `duckdb.h` | Hardcodes 20+ static `.a` archive paths, exposes raw `[^]c.char` pointers everywhere, zero idiomatic Odin helpers. | Clean `foreign import` linking, safe Odin slice/string views over `duckdb_string_t`, reflection & DSL layers. |
| `boxxxie/ssg` (`ssg/duckdb.odin`) | Pragmatic C bindings + `DESCRIBE` introspection + `sources_gen.cue` / `schema_gen.odin` codegen | Scoped to SSG workspace ingestion and telemetry (`duckdb_value_varchar` cell fetching). | Extracted and generalized into `boxxxie/odin-duckdb` with vectorized chunks, prepared statements, Quack client/server, and query DSL. |

---

## 5. Odin DuckDB DSL & Ergonomic API Design

Odin lacks Rust's procedural macros or Elixir's AST macros, but provides three powerful mechanisms that combine into a clean, idiomatic **3-Layer DuckDB DSL**:

```
┌─────────────────────────────────────────────────────────────────────────┐
│ Layer 3: Compile-Time Schema & Query Codegen (`duckdb/cli`)             │
│   .duckdb / .sql / .csv / .parquet  ──►  schema_gen.odin + CUE schemas  │
├─────────────────────────────────────────────────────────────────────────┤
│ Layer 2: Composable Relational Query Builder DSL (`duckdb.Query`)       │
│   from("issues") -> select(...) -> where_eq("state", v) -> order_by(..) │
├─────────────────────────────────────────────────────────────────────────┤
│ Layer 1: Runtime Struct Reflection & Tag DSL (`core:reflect`)           │
│   query_as(&db, Issue, sql, ..args)  |  append_struct(&app, issue)      │
├─────────────────────────────────────────────────────────────────────────┤
│ Layer 0: Vectorized C API + Quack Protocol Engine (`duckdb.Database`)   │
│   libduckdb C API (Chunks/Prepared/Appender) + DuckDB 2.0 Quack Worker  │
└─────────────────────────────────────────────────────────────────────────┘
```

### 5.1 Layer 1: Runtime Struct Tag Reflection (`core:reflect`)
Using `reflect.struct_field_types`, `reflect.struct_field_names`, and `reflect.struct_field_tags`, any Odin struct can be annotated with `duckdb:"..."` tags:

```odin
Telemetry_Route :: struct {
    run_id:     string `duckdb:"run_id,pk,not_null"`,
    route:      string `duckdb:"route,pk,not_null"`,
    layout:     string `duckdb:"layout"`,
    html_bytes: i64    `duckdb:"html_bytes"`,
    sha256:     string `duckdb:"sha256"`,
    skipped:    bool   `duckdb:"-",`, // ignored by DuckDB mapper
}
```

**Capabilities enabled by Layer 1 Reflection:**
1. **Automatic DDL Generation (`create_table_sql($T, table_name)`):**
   - Inspects fields and `duckdb:"..."` tags of `$T` to generate `CREATE TABLE IF NOT EXISTS "telemetry_routes" ("run_id" VARCHAR NOT NULL, ..., PRIMARY KEY ("run_id", "route"));`.
2. **Vectorized Typed Unmarshaling (`query_as(&db, $T, sql, ..args)` -> `[]T`):**
   - Binds `args: ..any` (`i64`, `int`, `f64`, `bool`, `string`, `[]byte`) to a `duckdb_prepared_statement` via `switch v in arg`.
   - Matches result column names to struct fields once per query (building a `col_idx -> field_offset/type` lookup table).
   - Iterates `duckdb_fetch_chunk`, reading `duckdb_vector_get_data` and `duckdb_string_t` directly into `[]T` allocated on `context.temp_allocator`.
3. **Struct Appender (`append_struct(&appender, row: $T)` / `append_slice(&db, table, rows: []$T)`):**
   - Iterates struct fields in table column order and calls `duckdb_append_int64`, `duckdb_append_varchar`, etc., ending the row automatically.

### 5.2 Layer 2: Composable Relational Query Builder DSL (`duckdb.Query`)
Inspired by Elixir's `Ecto.Query` and PRQL, `Query` is an immutable-style value builder allocated on `context.temp_allocator` that collects projections, joins, predicates, and bound parameters (`[dynamic]any`):

```odin
q := duckdb.from("telemetry_routes")
duckdb.select(&q, "route", "layout", "html_bytes", "sha256")
duckdb.where_eq(&q, "run_id", latest_run_id)
duckdb.where_gt(&q, "html_bytes", 4096)
duckdb.order_by(&q, "html_bytes", .Desc)
duckdb.limit(&q, 25)

// Compiles to:
// SQL:  SELECT "route", "layout", "html_bytes", "sha256"
//       FROM "telemetry_routes"
//       WHERE "run_id" = $1 AND "html_bytes" > $2
//       ORDER BY "html_bytes" DESC LIMIT 25
// Args: [latest_run_id, 4096]
routes, err, ok := duckdb.all(&db, Telemetry_Route, &q)
```

**Quack-Aware Query Builder Extensions:**
- `duckdb.from_quack(alias, table)` -> `FROM "remote_db"."issues"`
- `duckdb.quack_rpc(alias, raw_sql)` -> `FROM quack_query('remote_db', '...')`
- `duckdb.from_parquet(glob_path)` -> `FROM read_parquet('...')`
- `duckdb.from_csv(glob_path)` -> `FROM read_csv_auto('...')`

### 5.3 Layer 3: Compile-Time Schema & Query Codegen (`duckdb/cli`)
For zero-reflection hot paths and external data dumps (CSV/JSON/Parquet/DuckDB tables):
- `odin run cli -- codegen <db_or_dir> --package=models --out=models/schema_gen.odin`
- Uses `DESCRIBE SELECT * FROM ...` to emit strongly-typed Odin structs, static `CREATE TABLE` constants, and specialized vectorized chunk decoders.
