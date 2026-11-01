# Product Definition: `duckdb` for Odin

## Vision
Build a first-class, idiomatic, zero-overhead **DuckDB 2.0** library, **Quack protocol** client/server toolkit, and **relational query & schema DSL** for **Odin** (`dev-2026-09`).

## Core Capabilities
1. **Complete DuckDB C API + Vectorized Execution:**
   - Memory-safe, allocator-aware Odin wrappers around `libduckdb` (`/usr/include/duckdb.h`), covering Database/Config/Connection lifecycle, Prepared Statements (`$1, $2` parameter binding), Appender bulk ingestion, Vectorized Data Chunks (`duckdb_data_chunk`, `duckdb_vector`, `duckdb_string_t`), Replacement Scans, and Custom Scalar/Table Functions.
2. **DuckDB 2.0 & Quack Protocol (`quack_serve` / `ATTACH ... TYPE quack`):**
   - Full support for DuckDB 2.0 (`Cyanoptera`) features, specifically the **Quack IPC/RPC protocol** allowing multiple local or remote processes to query and mutate a shared DuckDB instance concurrently without single-writer file lock conflicts.
   - Dual execution backends: native `libduckdb` C API and persistent DuckDB 2.0 worker processes (`duckdb -json -dark-mode`) for environments where system `libduckdb.so` trails the standalone DuckDB 2.0 binary.
3. **Ergonomic Odin DSL (Reflection + Query Builder + Codegen):**
   - **Struct Tag Reflection (`core:reflect`):** Map Odin structs directly to DuckDB tables, `Appender` rows, and vectorized result chunks via `duckdb:"..."` struct tags.
   - **Composable Relational Query DSL:** Type-checked query construction in Odin (`from`, `select`, `where`, `join`, `group_by`, `order_by`, `limit`) that compiles to parameterized SQL.
   - **Schema Introspection & Codegen:** Emit static Odin structs and CUE schemas from DuckDB databases, CSVs, JSONL, and Parquet files.
