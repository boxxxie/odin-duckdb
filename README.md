# `odin-duckdb` (`duckdb`) — DuckDB 2.0, Quack Protocol & Query DSL for Odin

An ergonomic, zero-overhead **DuckDB 2.0** library, **Quack protocol** client/server toolkit, and **relational query & schema DSL** for **Odin** (`dev-2026-09`).

## Goals & Scope

1. **Full C API & Vectorized Execution (`duckdb.h`):**
   - Complete bindings for Database/Connection configuration, Prepared Statements (`duckdb_prepare`, `duckdb_bind_*`), Appender bulk ingestion (`duckdb_appender_*`), and zero-copy Vectorized Data Chunks (`duckdb_fetch_chunk`, `duckdb_vector_get_data`, `duckdb_string_t`).
2. **First-Class DuckDB 2.0 & Quack Protocol Support:**
   - Native support for DuckDB 2.0 (`Cyanoptera`) features including the **Quack IPC/RPC protocol** (`CALL quack_serve(...)`, `CALL quack_stop(...)`, `CREATE SECRET ... TYPE quack`, `ATTACH 'quack:...' AS ... (TYPE quack)`, and `FROM quack_query(...)`).
   - Support for both direct `libduckdb` C API execution and persistent background DuckDB 2.0 worker processes (`duckdb -json -dark-mode`) to bypass single-writer file locks via `quack_serve`.
3. **Odin Schema Reflection & Relational Query DSL:**
   - **Struct Tag Reflection (`core:reflect`):** Automatic DDL (`CREATE TABLE`), `Appender` struct insertion, and typed row/chunk unmarshaling (`query_as(conn, $T, sql, ..args)`) via `duckdb:"col_name,pk,json"` tags.
   - **Composable Query Builder DSL:** Type-safe relational pipeline construction (`from`, `select`, `where`, `join`, `order_by`, `limit`) with automatic `$1, $2` parameter binding.
   - **Compile-Time Schema Codegen:** Inspecting `.duckdb`, CSV, JSON, and Parquet sources to emit static Odin structs and CUE schemas (`sources_gen.cue`, `schema_gen.odin`).

## Conductor Tracks

- **[Track 1: DuckDB 2.0, Quack Protocol & Odin DSL Research & Architecture](conductor/tracks/track1_duckdb2_research_and_dsl/spec.md)**
  - Comprehensive resource compendium and architectural design referencing the C API (`/usr/include/duckdb.h`), Rust (`duckdb-rs` & `llim` Quack server store), Elixir (`duckdbex` & `quackdb`), and existing Odin bindings.

## Verification

```bash
odin check duckdb -no-entry-point
odin test tests
```
