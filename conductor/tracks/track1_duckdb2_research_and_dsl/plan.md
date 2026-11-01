# Track 1 Implementation Plan: DuckDB 2.0, Quack Protocol & Odin DSL

## Phase 1: Resource Gathering & Architecture Specification (Completed)
- [x] Inventory local DuckDB 2.0 binary (`/home/pauli/.local/bin/duckdb` v2.0.0 `Cyanoptera` `d54cbbe3df`) and system C header/library (`/usr/include/duckdb.h` & `/usr/lib/libduckdb.so`).
- [x] Document the DuckDB 2.0 **Quack protocol** (`quack_serve`, `quack_stop`, `CREATE SECRET ... TYPE quack`, `ATTACH ... (TYPE quack)`, `quack_query`) and non-interactive `-dark-mode` CLI flag requirement.
- [x] Analyze reference implementations across C (`/usr/include/duckdb.h`), Rust (`duckdb-rs` & `/home/pauli/projects/llim/src/stores.rs`), Elixir (`duckdbex` & `quackdb`), and existing Odin repositories (`lionel626/duckdb-odin`, `TheMartian0x48/duckdb-odin`, `boxxxie/ssg`).
- [x] Design the 3-Layer Odin DuckDB DSL (Layer 1: `core:reflect` struct tag mapping, Layer 2: Composable `duckdb.Query` relational builder, Layer 3: Compile-time schema & chunk decoder codegen).
- [x] Establish baseline `duckdb` package (`duckdb/duckdb.odin`) with C API bindings (Database, Config, Connection, Prepared Statements, Appender, Vectorized Data Chunks, and Quack SQL helpers) and passing test suite (`tests/duckdb_test.odin`).

## Phase 2: Vectorized Data Chunks & Prepared Statement Engine (`duckdb/chunks.odin`, `duckdb/prepared.odin`)
- [ ] Implement zero-copy `duckdb_string_t` decoder (handling `<= 12` byte inlined strings and `> 12` byte pointer strings) and validity bitmask reader (`duckdb_vector_get_validity`).
- [ ] Implement variadic parameter binder `bind_args(stmt, ..any)` supporting `bool`, `i8..i64`, `u8..u64`, `f32`, `f64`, `string`, `cstring`, `[]byte`, and `nil`.
- [ ] Add unit tests comparing vectorized `duckdb_fetch_chunk` throughput and correctness against `NULL`s, long strings (`> 12` bytes), and numeric types.

## Phase 3: DuckDB 2.0 & Quack Protocol Client/Server Runtime (`duckdb/quack.odin`)
- [ ] Implement `Persistent_Worker` subprocess backend spawning `/home/pauli/.local/bin/duckdb <path> -json -dark-mode` with deterministic marker framing (`__ODIN_DUCKDB_MARKER__`) modeled on `/home/pauli/projects/llim/src/stores.rs`.
- [ ] Implement `quack_serve_daemon` and token file management (`0600` permissions, lock conflict detection when a Quack server is already serving the target database).
- [ ] Implement client helpers (`attach_quack`, `quack_query_json`, `quack_exec`) and integration test spinning up a local `quack:127.0.0.1:<port>` server and querying it from a second client instance.

## Phase 4: Layer 1 (`core:reflect` Struct Tag Mapper) & Layer 2 (`duckdb.Query` DSL) (`duckdb/reflect.odin`, `duckdb/dsl.odin`)
- [ ] Implement `create_table_sql($T, table_name)` and `ensure_table(&db, $T, table_name)` from `duckdb:"col,pk,not_null,json"` struct tags.
- [ ] Implement `query_as(&db, $T, sql, ..args) -> ([]T, string, bool)` and `append_slice(&db, table_name, rows: []$T) -> (string, bool)`.
- [ ] Implement the composable `Query` builder (`from`, `from_quack`, `select`, `where_eq`, `where_raw`, `join`, `order_by`, `limit`, `offset`, `to_sql`, `all`).
- [ ] Implement Layer 3 schema introspection & codegen CLI (`cli/main.odin`) for `.duckdb`, CSV, JSON, and Parquet sources.
