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

## Architecture Overview

- **3-Layer Odin DuckDB 2.0 Stack:** Combines C API v2 bindings (`duckdb/capi_v2.odin`), `core:reflect` struct mapping & bulk `ColumnDataCollection` ingestion (`duckdb/reflect.odin`), composable Friendly SQL & Quack RPC query building (`duckdb/dsl.odin`, `duckdb/quack.odin`), and zero-execution schema codegen (`duckdb/codegen.odin`).
- **4-Layer ATDD Executable Specifications:** Full C API v2, Arrow C Data Interface, Quack protocol, and DSL test coverage under `tests/`.

## Verification

```bash
odin check duckdb -no-entry-point
odin test tests
```
