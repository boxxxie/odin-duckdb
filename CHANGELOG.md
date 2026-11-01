# Changelog

All notable changes to `odin-duckdb` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-11-01

### Added

- **DuckDB 2.0 C API v2 Bindings (`duckdb/capi_v2.odin`):**
  - Complete foreign bindings for `duckdb_v2.h` across environments, instances, connections, configurations, schemas, logical types, values, statements, prepared statements, streaming results, data chunks, vectors, arenas, and column data collections.
  - Full extensibility bindings for scalar functions, table functions (with filter and projection pushdown), aggregate functions, custom types, cast functions, replacement scans, pragma functions, copy functions, macro functions, multi-file functions, custom options, file systems, log sinks, query metrics, and the SQL tokenizer.
  - Native Arrow C Data Interface structs (`Arrow_Schema`, `Arrow_Array`, `Arrow_Array_Stream`) and `duckdb_v2_arrow_*` streaming result, importer, and exporter bindings.
  - Zero-copy `V2_Str`, `V2_Bytes` (inline $\le 12$ bytes and arena pointer $> 12$ bytes), `V2_Bit`, `V2_Bignum`, and `V2_Vector_View` helpers (`v2_vector_get_readable_view` with automatic `.OTHER` vector flattening).
  - High-level V2 session and execution helpers: `V2_Database`, `v2_open`, `v2_close`, `v2_open_instance`, `v2_parse_single_stmt`, `v2_query`, `v2_exec_drain`, `v2_step_chunk`, `v2_prepare`, `v2_consume_error_text`, `v2_create_value_from_any`, and `v2_with_transaction`.
- **Legacy C API v1 Bindings (`duckdb/duckdb.odin`):**
  - Cross-platform (`Linux`, `Darwin`, `Windows`) bindings for `duckdb.h` (`duckdb_open`, `duckdb_query`, prepared statements, appender, data chunks) and convenience wrappers (`open`, `close`, `exec`, `sql_escape`).
- **`core:reflect` Struct Mapping & Bulk Appender (`duckdb/reflect.odin`):**
  - `reflect_struct_mappings` and `create_table_sql` supporting `pk`, `not_null`, `unique`, `default=...`, `json`, and `-` struct tags with automatic `duckdb_v2_identifier_render_quoted` identifier escaping.
  - `append_slice` bulk struct ingestion using C API v2 `ColumnDataCollection` and `duckdb_v2_statement_add_collection`.
  - `query_as` typed row unmarshaling with variadic positional parameter binding (`args: ..any`), case-insensitive column-name matching with positional fallback, `Maybe(T)` nullable field support, and recursive `core:encoding/json` serialization/deserialization for `,json` fields.
- **Composable Friendly SQL Query Builder (`duckdb/dsl.odin`):**
  - Relational pipeline builder (`query_from`, `query_select`, `query_exclude`, `query_replace`, `query_where`, `query_where_bind`, `query_bind`, `query_join`, `query_asof_join`, `query_group_by_all`, `query_qualify`, `query_order_by`, `query_limit`, `query_summarize`, `query_sample`, `query_to_sql`, `query_execute_as`).
  - Source helpers for Parquet (`query_from_parquet`), CSV (`query_from_csv`), JSON (`query_from_json`), Iceberg (`query_from_iceberg`), Delta Lake (`query_from_delta`), and Quack remote tables/RPC (`query_from_quack`, `query_from_quack_rpc`).
- **Quack Protocol & SQLLogicTest Parser (`duckdb/quack.odin`):**
  - Endpoint URI normalization (`quack_normalize_uri`) and SQL builders (`quack_serve_sql`, `quack_stop_sql`, `quack_identify_sql`, `quack_secret_sql`, `quack_attach_sql`, `quack_query_sql`).
  - `sqllogic_parse_script` and `sqllogic_expand_template` supporting `require`, `include`, `statement ok`, `statement error`, and `query` directives (including multi-paragraph SQL queries and 4-token query headers).
- **Schema Introspection & Codegen (`duckdb/codegen.odin`):**
  - Zero-execution table/source introspection (`introspect_table_schema`) via `duckdb_v2_statement_bind`.
  - Odin struct generator (`generate_odin_struct_code`) and CUE schema generator (`generate_cue_schema_code`).
- **ATDD Executable Specification Suite (`tests/`):**
  - 4-layer test architecture with automatic live-instance leak detection (`duckdb_v2_environment_get_instance_count == 0` on teardown).
