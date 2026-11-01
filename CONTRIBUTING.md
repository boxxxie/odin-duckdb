# Contributing to `odin-duckdb`

Thank you for your interest in contributing to `odin-duckdb`! This guide outlines our development workflow, architecture conventions, and verification requirements.

---

## Development Setup

1. **Install Odin:** Use a current Odin compiler build (`dev-2026` or newer).
2. **Install DuckDB 2.0 (`libduckdb`):** Ensure `libduckdb` (with C API v2 symbols `duckdb_v2_*`) is installed on your library path.
3. **Editor Support:** The repository includes an `ols.json` configuration for the [Odin Language Server (`ols`)](https://github.com/DanielGavin/ols) covering both `duckdb/` and `tests/`.

---

## Architectural Principles

### 1. Strict Handle Hygiene & Zero Leaks
Every `V2_*_Handle` created via the C API v2 must be paired with its corresponding `duckdb_v2_*_destroy` call (except borrowed handles explicitly documented by `duckdb_v2.h`, such as the `V2_Logical_Type_Handle` returned by `duckdb_v2_schema_get_field` or `V2_Vector_Handle` borrowed from a `V2_Data_Chunk_Handle`).

In tests, `dsl_with_memory_db` (`tests/dsl.odin`) automatically asserts at scope exit that:
- `duckdb_v2_environment_get_instance_count(env) == 0`
- `duckdb_v2_environment_destroy(&env) == .NONE`

If a test leaves an open `V2_Result_Handle`, `V2_Prepared_Statement_Handle`, or `V2_Instance_Handle` undestroyed, teardown will fail immediately.

### 2. `contextless` Low-Level Helpers
Low-level vector and byte helpers in `duckdb/capi_v2.odin` that may be called from `proc "c"` UDF callbacks (`v2_str_from_string`, `v2_bytes_to_string`, `v2_vector_assign_string`, `v2_vector_assign_bytes`, `v2_vector_get_readable_view`, validity bit helpers) should remain `proc "contextless"` whenever possible.

### 3. 4-Layer ATDD Test Architecture
All tests under `tests/` follow a strict 4-layer separation of concerns:
1. **Layer 1 — Executable Specifications (`tests/*_spec.odin`):** Express *what* behavior is expected in domain terms.
2. **Layer 2 — Domain-Specific Language (`tests/dsl.odin`):** Scoped fixtures (`dsl_with_memory_db`) and high-signal assertions (`expect_v2_ok`, `expect_v2_error`, `expect_query_column`).
3. **Layer 3 — Protocol Drivers (`tests/drivers.odin`, `tests/sqllogic.odin`):** Translates test intent into `duckdb` calls.
4. **Layer 4 — System Under Test (`duckdb/`):** The library package itself.

---

## Pull Request Checklist

Before opening a pull request, verify that:

1. `odin check duckdb -no-entry-point` completes with zero warnings or errors.
2. `odin test tests` passes all executable specifications with zero leaked instances.
3. Any new public procedure or struct tag option includes an executable specification in `tests/` and is documented in `README.md` and `CHANGELOG.md`.
