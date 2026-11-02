# odin-duckdb Benchmarks

This directory contains the 48-benchmark throughput, bandwidth, and latency suite for `odin-duckdb`, covering the DuckDB 2.0 C API v2 (`duckdb/capi_v2.odin`), Arrow C Data Interface bridge (`duckdb/arrow.odin`), `core:reflect` struct unmarshaling and appenders (`duckdb/reflect.odin`), composable query DSL (`duckdb/dsl.odin`), schema codegen (`duckdb/codegen.odin`), and Quack extension utilities (`duckdb/quack.odin`).

---

## Running the Benchmarks

Always compile benchmarks with `-o:speed`:

```bash
LD_LIBRARY_PATH=/home/pauli/.local/lib odin run benchmarks -o:speed -extra-linker-flags:"-L/home/pauli/.local/lib -Wl,-rpath,/home/pauli/.local/lib"
```

### JSONL Results & Automatic README Updates (`benchmarks/history.jsonl`)

Every benchmark run automatically writes 48 newline-delimited JSON records (one JSON object per benchmark line) to `benchmarks/history.jsonl`:

```json
{"rank":1,"name":"1a. Ingest: V2 Prepared Statement Loop (2K rows)","rows":2000,"iterations":5,"median_ns":306003684,"min_ns":296228052,"max_ns":316587531,"bytes_row":37,"ops_per_sec":6535.87,"mb_per_sec":0.23,"ns_per_item":153001.84}
```

`.gitattributes` configures `*.jsonl diff=jsonl`. To get human-readable `git diff` output on `.jsonl` files, configure the `jsonl` textconv driver in your local Git config:

```bash
git config diff.jsonl.textconv 'jq -r "if .bytes_row > 0 then \"#\(.rank) \(.name) | \(.ns_per_item) ns/item | \(.ops_per_sec) ops/sec | \(.mb_per_sec) MB/s\" else \"#\(.rank) \(.name) | \(.ns_per_item) ns/item | \(.ops_per_sec) ops/sec\" end"'
```

To regenerate the benchmark tables in both `benchmarks/README.md` and the root `README.md` directly from `benchmarks/history.jsonl`, run:

```bash
./benchmarks/update_readme.sh
```

---

## Baseline Results (`-o:speed`)

<!-- BEGIN_BENCHMARK_TABLE -->
| # | Benchmark | Items / Op | Median Time | Min Time | Throughput (ops/s) | Bandwidth (MB/s) | Latency (ns/item) |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1a. Ingest: V2 Prepared Statement Loop (2K rows) | 2000 | 306.004 ms | 296.228 ms | 6.54 K/s | 0.2 MB/s | **153001.8 ns** |
| 2 | 1b. Ingest: Legacy V1 Appender API (100K rows) | 100000 | 16.600 ms | 14.571 ms | 6.02 M/s | 212.6 MB/s | **166.0 ns** |
| 3 | 1c. Ingest: V2 ColumnDataCollection `append_slice` (100K rows) | 100000 | 12.511 ms | 11.118 ms | 7.99 M/s | 282.0 MB/s | **125.1 ns** |
| 4 | 1d. Ingest: Nullable `Maybe(T)` `append_slice` (100K rows, 25% NULL) | 100000 | 12.788 ms | 11.213 ms | 7.82 M/s | 275.9 MB/s | **127.9 ns** |
| 5 | 1e. Ingest: Custom `V2_Copy_Function` `COPY ... FROM` (1M rows) | 1000000 | 14.251 ms | 13.485 ms | 70.17 M/s | 1070.7 MB/s | **14.3 ns** |
| 6 | 1f. Export: Custom `V2_Copy_Function` `COPY ... TO` Sink (1M rows) | 1000000 | 2.467 ms | 2.247 ms | 405.27 M/s | 6183.9 MB/s | **2.5 ns** |
| 7 | 1g. Ingest: `Struct_Appender(T)` 1K x 100-Row Micro-Batches (100K) | 100000 | 13.258 ms | 12.941 ms | 7.54 M/s | 266.2 MB/s | **132.6 ns** |
| 8 | 2a. Scan: Zero-Copy `V2_Vector_View` Flat (1M rows) | 1000000 | 5.444 ms | 4.986 ms | 183.67 M/s | 4379.1 MB/s | **5.4 ns** |
| 9 | 2b. Scan: Zero-Copy `V2_Selection_Vector` Filtered (1M source rows) | 1000000 | 3.996 ms | 3.362 ms | 250.25 M/s | 5966.3 MB/s | **4.0 ns** |
| 10 | 2c. Scan: Arrow C Data Interface `Arrow_Array_Stream` (1M rows) | 1000000 | 5.782 ms | 4.647 ms | 172.96 M/s | 4123.7 MB/s | **5.8 ns** |
| 11 | 2d. Unmarshal: `core:reflect` `query_as` Non-Null Structs (100K rows) | 100000 | 7.280 ms | 6.124 ms | 13.74 M/s | 484.7 MB/s | **72.8 ns** |
| 12 | 2e. Unmarshal: `core:reflect` `query_as` Nullable `Maybe(T)` (100K rows) | 100000 | 8.876 ms | 8.138 ms | 11.27 M/s | 397.5 MB/s | **88.8 ns** |
| 13 | 2f. Scan: Direct `ColumnDataCollection` Worker Scan (1M rows) | 1000000 | 0.886 ms | 0.721 ms | 1129.13 M/s | 17229.1 MB/s | **0.9 ns** |
| 14 | 2g. Bridge: `Arrow_Exporter` -> `Arrow_Importer` Round-Trip (200K) | 200000 | 0.639 ms | 0.612 ms | 313.06 M/s | 4776.9 MB/s | **3.2 ns** |
| 15 | 2h. Scan: Multi-Worker `ColumnDataCollection` 4-Thread Scan (1M) | 1000000 | 0.385 ms | 0.341 ms | 2600.77 M/s | 39684.7 MB/s | **0.4 ns** |
| 16 | 2i. Scan: Cooperative Stepper `v2_step_chunk` (1M rows) | 1000000 | 5.381 ms | 4.833 ms | 185.84 M/s | 4430.8 MB/s | **5.4 ns** |
| 17 | 3a. `V2_Bytes` Write: Inline <= 12 B (`v2_vector_assign_string`, 200K) | 200000 | 0.813 ms | 0.810 ms | 245.89 M/s | 2814.0 MB/s | **4.1 ns** |
| 18 | 3b. `V2_Bytes` Write: Arena > 12 B (`v2_vector_assign_string`, 200K) | 200000 | 2.935 ms | 2.905 ms | 68.13 M/s | 2079.3 MB/s | **14.7 ns** |
| 19 | 3c. Vector Cast: `duckdb_v2_vector_cast` BIGINT -> DOUBLE (200K) | 200000 | 0.061 ms | 0.060 ms | 3290.88 M/s | 50214.9 MB/s | **0.3 ns** |
| 20 | 3d. Zero-Copy Alias: `duckdb_v2_vector_reference` (200K rows) | 200000 | 0.001 ms | 0.001 ms | 159616.92 M/s | 2435560.9 MB/s | **0.0 ns** |
| 21 | 3e. Vector Flatten: `.OTHER` (`MakeSequence`) -> `.FLAT` (1M rows) | 1000000 | 0.241 ms | 0.237 ms | 4142.45 M/s | 31604.4 MB/s | **0.2 ns** |
| 22 | 3f. Wire Codec: 128-Bit `HUGEINT`/`INTERVAL`/`BIT`/`BIGNUM` (200K) | 200000 | 0.240 ms | 0.236 ms | 833.23 M/s | 38142.1 MB/s | **1.2 ns** |
| 23 | 4a. JSON Tag Round-Trip: `append_slice` + `query_as` (10K structs) | 10000 | 5.938 ms | 5.577 ms | 1.68 M/s | 102.8 MB/s | **593.8 ns** |
| 24 | 4b. Native `STRUCT(...)` Child Vector Write+Read (200K structs) | 200000 | 0.304 ms | 0.302 ms | 657.55 M/s | 15677.2 MB/s | **1.5 ns** |
| 25 | 4c. Nested `LIST(BIGINT)` Vector Write+Read (200K lists / 800K items) | 200000 | 0.180 ms | 0.176 ms | 1110.08 M/s | 50815.2 MB/s | **0.9 ns** |
| 26 | 4d. Fixed `ARRAY(DOUBLE, 4)` Vector Write+Read (200K arrays / 800K f64) | 200000 | 0.139 ms | 0.136 ms | 1436.56 M/s | 43840.5 MB/s | **0.7 ns** |
| 27 | 4e. Composite Values: `VARIANT`/`MAP`/`UNION`/`DECIMAL` (10K ops) | 10000 | 37.214 ms | 37.007 ms | 268.72 K/s | - | **3721.4 ns** |
| 28 | 5a. DSL: `query_to_sql` Pipeline Compilation (100K queries) | 100000 | 23.798 ms | 23.524 ms | 4.20 M/s | - | **238.0 ns** |
| 29 | 5b. Codegen: `introspect_table_schema` + Odin/CUE (1K tables) | 1000 | 4.506 ms | 4.502 ms | 221.90 K/s | - | **4506.5 ns** |
| 30 | 5c. Parser: `sqllogic_parse_script` (50K directives / 1K scripts) | 50000 | 2.878 ms | 2.874 ms | 17.37 M/s | - | **57.6 ns** |
| 31 | 5d. Lexer: Native C API v2 `duckdb_v2_tokenize_sql` (300K tokens) | 300000 | 12.125 ms | 12.074 ms | 24.74 M/s | - | **40.4 ns** |
| 32 | 5e. Catalog: `duckdb_v2_connection_describe_table` (5K lookups) | 5000 | 14.691 ms | 14.621 ms | 340.35 K/s | - | **2938.2 ns** |
| 33 | 5f. Quack: SQL Builders + URI Normalize + Template (100K ops) | 100000 | 7.788 ms | 7.703 ms | 12.84 M/s | - | **77.9 ns** |
| 34 | 5g. Reflection DDL: `create_table_sql` + `v2_quote_identifier` (100K) | 100000 | 19.941 ms | 19.779 ms | 5.01 M/s | - | **199.4 ns** |
| 35 | 6a. UDF: Vectorized Scalar Callback `odin_fma` (1M rows) | 1000000 | 1.113 ms | 0.962 ms | 898.64 M/s | 20568.2 MB/s | **1.1 ns** |
| 36 | 6b. UDF: Streaming Table Function `odin_gen_series` (1M rows) | 1000000 | 3.228 ms | 2.696 ms | 309.82 M/s | 4727.5 MB/s | **3.2 ns** |
| 37 | 6c. UDF: Grouped Hash Aggregate `odin_agg_sum` (1M rows) | 1000000 | 2.086 ms | 1.994 ms | 479.43 M/s | 3657.8 MB/s | **2.1 ns** |
| 38 | 6d. UDF: Table Function Projection + Filter Pushdown (1M rows) | 1000000 | 0.493 ms | 0.417 ms | 2027.80 M/s | 30941.8 MB/s | **0.5 ns** |
| 39 | 6e. UDF: Custom Type & Vectorized `V2_Cast_Function` (1M rows) | 1000000 | 0.998 ms | 0.980 ms | 1002.13 M/s | 15291.3 MB/s | **1.0 ns** |
| 40 | 6f. UDF: `V2_Replacement_Scan` Virtual Table Scan (1K queries) | 1000 | 278.255 ms | 271.748 ms | 3.59 K/s | - | **278255.2 ns** |
| 41 | 6g. Extensibility: `V2_Pragma` + `V2_Custom_Option` + `V2_Macro` (1K) | 1000 | 67.527 ms | 65.077 ms | 14.81 K/s | - | **67526.8 ns** |
| 42 | 7a. Point Lookup: Ad-Hoc `v2_query` Parse+Bind+Exec (1K queries) | 1000 | 212.599 ms | 211.011 ms | 4.70 K/s | - | **212598.9 ns** |
| 43 | 7b. Point Lookup: Pre-Compiled `v2_prepared_execute` (1K queries) | 1000 | 184.253 ms | 183.953 ms | 5.43 K/s | - | **184252.9 ns** |
| 44 | 7c. DSL Pipeline: `query_execute_as` Build+Bind+Unmarshal (1K) | 1000 | 454.593 ms | 449.407 ms | 2.20 K/s | 0.1 MB/s | **454592.8 ns** |
| 45 | 7d. Transactions: `v2_with_transaction` Commit + Rollback (1K tx) | 1000 | 135.028 ms | 129.914 ms | 7.41 K/s | - | **135028.1 ns** |
| 46 | 7e. Prepared DSL: `prepared_query_execute_as` Cached Plan+Schema (1K) | 1000 | 392.483 ms | 376.357 ms | 2.55 K/s | 0.1 MB/s | **392483.1 ns** |
| 47 | 8a. VFS: Positional `write_at` + `read_at` (1K x 64 KB = 64 MB) | 1000 | 2.756 ms | 2.739 ms | 362.88 K/s | 22679.9 MB/s | **2755.8 ns** |
| 48 | 8b. Telemetry: `V2_Query_Metrics` Tree + `V2_Log_Sink` (10K ops) | 10000 | 112.263 ms | 108.261 ms | 89.08 K/s | - | **11226.3 ns** |
<!-- END_BENCHMARK_TABLE -->
