# Product Definition: `duckdb` for Odin

## Vision
Build a first-class, idiomatic, zero-overhead **DuckDB 2.0** library, **Quack protocol** client/server toolkit, and **relational query & schema DSL** for **Odin** (`dev-2026-09`).

## Core Capabilities
1. **Complete DuckDB 2.0 C API v1 (`duckdb_*`) + C API v2 (`duckdb_v2_*`) + Vectorized Execution:**
   - Memory-safe, allocator-aware Odin wrappers around `libduckdb` (`~/.local/lib/libduckdb.so` v2.0.0 & `/usr/lib/libduckdb.so`), covering both **C API v1 (`duckdb.h`)** and **DuckDB 2.0's new C API v2 (`duckdb_v2.h`)**:
     - C API v2 Environment (`duckdb_v2_environment_handle`), Instance (`duckdb_v2_instance_handle`), Connection (`duckdb_v2_connection_handle`), length-delimited string views (`duckdb_v2_str { ptr, len }`), transparent 16-byte bytes storage (`duckdb_v2_bytes`), structured error handles (`duckdb_v2_error_info_handle`, `DUCKDB_V2_ERROR`), and Arrow C Data Interface (`ArrowSchema`, `ArrowArray`, `ArrowArrayStream`).
     - Prepared Statements (`$1, $2` parameter binding), Appender bulk ingestion, Vectorized Data Chunks (`duckdb_data_chunk`, `duckdb_vector`, `duckdb_string_t` / `duckdb_v2_bytes`), Replacement Scans, and Custom Scalar/Table Functions.
2. **DuckDB 2.0 (`Cyanoptera`) Dialect & Complete Quack Protocol (`duckdb-quack`):**
   - Full support for DuckDB 2.0 SQL dialect (`lambda x: ...`, `FROM`-first queries, `SELECT * EXCLUDE/REPLACE`, `VARIANT`, `INSTALL AND LOAD`, `STORAGE_VERSION 'v1.5.0'` compatibility) and the **Quack IPC/RPC protocol** (`quack_serve`, `quack_stop`, `quack_server_list`, `quack_active_connections`, `quack_cancel`, `quack_clear_cache`, `quack_identify`, `quack_generate_keys`, `whoami()`, `TYPE quack` secrets with `TOKEN`, `SCOPE`, `EXTRA_HTTP_HEADERS`, and `SSL_FINGERPRINT`, `ATTACH ... TYPE quack`, `quack_query`).
   - Dual execution backends: native `libduckdb.so` C API (v1 + v2) and persistent DuckDB 2.0 worker processes (`duckdb -json -dark-mode`) for environments where system `libduckdb.so` trails the standalone DuckDB 2.0 binary.
3. **Ergonomic Odin DSL (Reflection + Query Builder + Capigen/Schema Codegen):**
   - **Struct Tag Reflection (`core:reflect`):** Map Odin structs directly to DuckDB tables, `Appender` rows, and vectorized result chunks via `duckdb:"..."` struct tags.
   - **Composable Relational Query DSL:** Type-checked query construction in Odin (`from`, `from_quack`, `quack_rpc`, `select`, `exclude`, `replace`, `where`, `qualify`, `join`, `asof_join`, `group_by_all`, `order_by`, `limit`) that compiles to parameterized DuckDB 2.0 SQL.
   - **Schema Introspection & `api_spec/v2` Codegen:** Emit static Odin structs and CUE schemas from DuckDB databases, CSVs, JSONL, and Parquet files, plus optional C API binding verification against `references/c/duckdb-capi-2.0/api_spec/v2`.
