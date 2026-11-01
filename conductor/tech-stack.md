# Tech Stack

- **Language:** Odin (`dev-2026-09`)
- **Database Engine:**
  - DuckDB 2.0.0 (`Cyanoptera` `d54cbbe3df` at `/home/pauli/.local/bin/duckdb`) with built-in `quack` extension
  - System `libduckdb.so` & `/usr/include/duckdb.h` (`foreign import duckdb_lib "system:duckdb"`)
- **Memory Management:** Explicit Odin `runtime.Allocator` (`context.allocator` for persistent handles/schemas, `context.temp_allocator` for per-query/per-chunk unmarshaling)
- **Reflection & Metaprogramming:** `core:reflect`, struct tags (`duckdb:"..."`), and optional AST/schema codegen CLI
- **Testing:** `odin test tests`
