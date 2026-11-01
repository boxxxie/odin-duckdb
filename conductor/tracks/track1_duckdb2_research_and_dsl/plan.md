# Track 1 Implementation Plan: DuckDB 2.0, C API v2, Quack Protocol & Odin DSL

## Phase 1: Resource Gathering, Reference Clones & Architecture Specification (Completed)
- [x] Inventory local DuckDB 2.0 binary (`/home/pauli/.local/bin/duckdb` v2.0.0 `Cyanoptera` `d54cbbe3df`), install DuckDB 2.0 `libduckdb.so` (exporting all 635 `duckdb_v2_*` symbols) and `duckdb_v2.h` / `duckdb.h` into `~/.local/lib` and `~/.local/include`.
- [x] Clone and `.gitignore` reference repositories across DuckDB 2.0 (`duckdb-quack`, `duckdb-claude-plugin`, `ducklake`), C API v1/v2 (`duckdb-capi-2.0` sparse checkout with `api_spec/v2`, `tools/cpp/`, `tools/shell/`, `test/api/capi/v2/`, `capigen`, `bareduckdb`, `extension-template-c`, `reference-extension-c`), Zig (`zuckdb.zig`, `zig-duckdb`, `zig-duckdb-ext`), Rust (`duckdb-rs` & `duckdb-neo`), Go (`duckdb-go-bindings`, `duckdb-go`), Node (`duckdb-node-neo`), Elixir (`quackdb`, `duckdbex`), and Odin (`lionel626/duckdb-odin`, `TheMartian0x48/duckdb-odin`).
- [x] Document the complete DuckDB 2.0 **Quack protocol** from `duckdb-quack` source (`quack_serve`, `quack_stop`, `quack_server_list`, `quack_active_connections`, `quack_cancel`, `quack_clear_cache`, `quack_identify`, `quack_generate_keys`, `whoami`, `CREATE SECRET ... TYPE quack` with `TOKEN`, `SCOPE`, `EXTRA_HTTP_HEADERS`, `SSL_FINGERPRINT`, `ATTACH ... (TYPE quack)`, `quack_query`) and non-interactive `-dark-mode` CLI flag requirement.
- [x] Design the 3-Layer Odin DuckDB DSL (Layer 1: `core:reflect` struct tag mapping, Layer 2: Composable `duckdb.Query` relational builder with DuckDB 2.0 SQL idioms, Layer 3: Compile-time schema & chunk decoder codegen).
- [x] Establish baseline `duckdb` package (`duckdb/duckdb.odin`) with C API bindings and passing test suite (`tests/duckdb_test.odin`).

## Phase 2: 4-Layer Odin ATDD Test Architecture & Porting Known-Good Upstream Specs (`tests/`)
- [ ] **Layer 3 — Protocol Drivers (`tests/drivers.odin`, `tests/sqllogic.odin`):**
  - Implement C API v2 Driver (`duckdb_v2_environment`, `duckdb_v2_instance`, `duckdb_v2_connection`, `duckdb_v2_result`, `duckdb_v2_vector_view`), C API v1 Driver (`duckdb_database`, `duckdb_connection`, `duckdb_prepared_statement`, `duckdb_appender`), and a **SQLLogicTest `.test` Runner** capable of parsing and executing upstream `references/duckdb2/duckdb-quack/test/sql/*.test` (`statement ok`, `statement error`, `query ... ----`) files directly in Odin.
- [ ] **Layer 2 — Test DSL & Automatic Handle-Leak Invariants (`tests/dsl.odin`):**
  - Implement `Spec_Context` (`given_*`, `upon_*`, `then_*` helpers) that wraps an explicit `duckdb_v2_environment_handle` per test and automatically asserts `duckdb_v2_environment_get_instance_count == 0` and `duckdb_v2_environment_destroy == .NONE` on `defer finish_spec(&ctx)` so any leaked instance, connection, or streaming result fails the spec immediately.
- [ ] **Layer 1 — Executable Specifications Ported from Upstream Oracles (`tests/*_spec.odin`):**
  - Port `test_cpp_api_core.cpp` -> `tests/core_v2_spec.odin` (environment instance counting, config option enumeration & aliases, `Attach` + `SetDefault`, `RenderQuotedIdentifier`, structured `DUCKDB_V2_ERROR` codes).
  - Port `test_capi_v2_bytes.cpp` -> `tests/bytes_v2_spec.odin` (cross-validating 16-byte `duckdb_v2_bytes` inline `<= 12` vs pointer `> 12` strings against v1 `duckdb_string_t`, `BIT` padding/count, and `BIGNUM` sign decoding).
  - Port `test_cpp_api_query.cpp` & `test_cpp_api_prepared_statement.cpp` -> `tests/query_v2_spec.odin` (multi-chunk `Step()` streaming, `Drain()` row counts, busy connection `RESOURCE_IN_USE` refusal, `Interrupt()`, `ParseSQL` multi-statement iteration, positional `$1` and named `$a` prepared parameters).
  - Port `test_cpp_api_appender.cpp` -> `tests/appender_v2_spec.odin` (`ColumnDataCollection` + `statement_add_collection` buffering, flushing, clearing, and scoped buffer isolation).
  - Port `duckdb-quack/test/sql/{serve_canonical,whoami,secret,server_list}.test` -> `tests/quack_spec.odin`.

## Phase 3: DuckDB 2.0 C API v2 (`duckdb_v2_*`) + Vectorized Data Chunks & Prepared Statements (`duckdb/capi_v2.odin`, `duckdb/chunks.odin`, `duckdb/prepared.odin`)
- [ ] Bind core **DuckDB 2.0 C API v2** (`duckdb/capi_v2.odin` from `duckdb_v2.h` & `api_spec/v2`): `duckdb_v2_str`, `duckdb_v2_bytes` (`DUCKDB_V2_BYTES_INLINE_LENGTH = 12`), `DUCKDB_V2_ERROR`, `duckdb_v2_error_info_handle`, `duckdb_v2_environment_handle`, `duckdb_v2_instance_handle`, `duckdb_v2_connection_handle`, `duckdb_v2_result_handle`, `duckdb_v2_data_chunk_handle`, `duckdb_v2_vector_handle`, `duckdb_v2_vector_view`, `duckdb_v2_column_data_collection_handle`, and `ArrowSchema`/`ArrowArray` C Data Interface structs, with Odin string/slice conversion helpers (`to_v2_str`, `from_v2_str`, `from_v2_bytes`).
- [ ] Implement zero-copy `duckdb_string_t` / `duckdb_v2_bytes` decoder (handling `<= 12` byte inlined strings and `> 12` byte pointer strings) and validity + selection-vector reader (`duckdb_v2_vector_view`).
- [ ] Implement variadic parameter binder `bind_args(stmt, ..any)` and V2 `Appender` (`ColumnDataCollection` + `duckdb_v2_statement_add_collection`) to make all Phase 2 `core_v2_spec`, `bytes_v2_spec`, `query_v2_spec`, and `appender_v2_spec` tests pass green.

## Phase 4: DuckDB 2.0 & Quack Protocol Client/Server Runtime (`duckdb/quack.odin`)
- [ ] Implement full Quack SQL & C API surface modeled on `references/duckdb2/duckdb-quack`:
  - Server lifecycle & introspection: `quack_serve` (with `token`, `secret`, `create_secret_if_not_exists`, `disable_ssl`, `ssl_cert_file`, `ssl_key_file`, `allow_other_hostname`, returning `listen_uri, listen_url, auth_token`), `quack_stop`, `quack_server_list`, `quack_active_connections`, `quack_identify`, `quack_generate_keys`, `quack_clear_cache`, `quack_cancel`, and `whoami()`.
  - Client authentication & attachment: `CREATE OR REPLACE [PERSISTENT] SECRET` (`TYPE quack` with `TOKEN`, `SCOPE`, `EXTRA_HTTP_HEADERS MAP {...}`, `SSL_FINGERPRINT`), `ATTACH IF NOT EXISTS ... (TYPE quack, READ_ONLY)`, and `quack_query(alias_or_uri, sql, use_transaction => ...)`.
- [ ] Implement `Persistent_Worker` subprocess backend spawning `/home/pauli/.local/bin/duckdb <path> -json -dark-mode` with deterministic marker framing (`__ODIN_DUCKDB_MARKER__`) and `quack_serve_daemon` token file management (`0600` permissions, lock conflict detection).
- [ ] Make all Phase 2 `tests/quack_spec.odin` and SQLLogicTest `.test` suites pass green.

## Phase 5: Layer 1 (`core:reflect` Struct Tag Mapper), Layer 2 (`duckdb.Query` DuckDB 2.0 DSL) & Layer 3 Codegen (`duckdb/reflect.odin`, `duckdb/dsl.odin`, `cli/main.odin`)
- [ ] Add ATDD specifications (`tests/dsl_spec.odin`) for struct reflection DDL/unmarshaling and composable `Query` compilation.
- [ ] Implement `create_table_sql($T, table_name)` and `ensure_table(&db, $T, table_name)` from `duckdb:"col,pk,not_null,json,variant"` struct tags.
- [ ] Implement `query_as(&db, $T, sql, ..args) -> ([]T, string, bool)` (vectorized chunk-to-struct unmarshaler) and `append_slice(&db, table_name, rows: []$T) -> (string, bool)`.
- [ ] Implement the composable DuckDB 2.0 `Query` builder (`from`, `from_quack`, `quack_rpc`, `from_parquet`, `from_csv`, `select`, `exclude`, `replace`, `where_eq`, `where_raw`, `qualify`, `join`, `asof_join`, `group_by_all`, `order_by`, `limit`, `offset`, `to_sql`, `all`).
- [ ] Implement Layer 3 schema introspection & codegen CLI (`cli/main.odin`) for `.duckdb`, CSV, JSON, and Parquet sources.
