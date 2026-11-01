# Development Workflow

1. **Typecheck Package:**
   ```bash
   odin check duckdb -no-entry-point
   ```
2. **Run Tests:**
   ```bash
   odin test tests
   ```
3. **Non-Interactive DuckDB 2.0 CLI Invocations:**
   Always pass `-dark-mode` (or `-light-mode`) when spawning `/home/pauli/.local/bin/duckdb` from Odin `os/process` or non-interactive shells so DuckDB 2.0 does not block for 5 seconds probing terminal background colors.
