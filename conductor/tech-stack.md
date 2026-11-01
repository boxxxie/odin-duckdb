# Tech Stack

- **Language:** Odin (`dev-2026-09`)
- **Database Engine:**
  - DuckDB 2.0.0 (`Cyanoptera` `d54cbbe3df` at `/home/pauli/.local/bin/duckdb`) with built-in `quack` extension
  - DuckDB 2.0 `libduckdb.so` (`/home/pauli/.local/lib/libduckdb.so`) & C API v1/v2 headers (`/home/pauli/.local/include/duckdb.h`, `/home/pauli/.local/include/duckdb_v2.h`, `/home/pauli/.local/include/duckdb_extension_v2.h`)
  - System `libduckdb.so` & `/usr/include/duckdb.h` (`foreign import duckdb_lib "system:duckdb"`)
- **Memory Management:** Explicit Odin `runtime.Allocator` (`context.allocator` for persistent handles/schemas, `context.temp_allocator` for per-query/per-chunk unmarshaling, zero-copy `duckdb_v2_str` / `duckdb_v2_bytes` views)
- **Reflection & Metaprogramming:** `core:reflect`, struct tags (`duckdb:"..."`), and optional AST/schema codegen CLI
- **Testing:** `odin test tests -extra-linker-flags:"-L/home/pauli/.local/lib -Wl,-rpath,/home/pauli/.local/lib"` (links against DuckDB 2.0 `libduckdb.so` with `duckdb_v2_*` and `quack` support)
