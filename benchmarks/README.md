# odin-duckdb Benchmarks

This directory contains the 48-benchmark statistical performance suite for `odin-duckdb`, measuring throughput ($\text{ops/sec}$), bandwidth ($\text{MB/s}$ / $\text{GB/s}$), median/mean latency ($\text{ns/op}$), and sample variance ($\pm\sigma$, $\text{CV}\%$, $\text{IQR}$, $\text{p95}$, $\text{p99}$, $\text{min..max}$) across the DuckDB 2.0 C API v2 (`duckdb/capi_v2.odin`), Arrow C Data Interface bridge (`duckdb/arrow.odin`), `core:reflect` struct unmarshaling and appenders (`duckdb/reflect.odin`), composable query DSL (`duckdb/dsl.odin`), schema codegen (`duckdb/codegen.odin`), and Quack extension utilities (`duckdb/quack.odin`).

---

## Running the Benchmarks

Always compile benchmarks with `-o:speed` (and `-microarch:native`). By default, each benchmark executes **1 warmup pass** followed by **5–7 measured trials** (`--warmup 1`) and automatically tags results with the current Git commit SHA:

```bash
LD_LIBRARY_PATH=/home/pauli/.local/lib odin run benchmarks -o:speed -microarch:native -extra-linker-flags:"-L/home/pauli/.local/lib -Wl,-rpath,/home/pauli/.local/lib"
```

You can customize the number of measured trials, warmup passes, commit SHA, run ID, or append multiple runs for the same commit:

```bash
# Run 10 measured trials after 2 warmup passes
LD_LIBRARY_PATH=/home/pauli/.local/lib odin run benchmarks -o:speed -microarch:native -extra-linker-flags:"-L/home/pauli/.local/lib -Wl,-rpath,/home/pauli/.local/lib" -- --runs 10 --warmup 2

# Append an additional run session to odin.jsonl & history.jsonl for the current commit
LD_LIBRARY_PATH=/home/pauli/.local/lib odin run benchmarks -o:speed -microarch:native -extra-linker-flags:"-L/home/pauli/.local/lib -Wl,-rpath,/home/pauli/.local/lib" -- --runs 5 --append
```

Or use the statistical runner & analyzer script directly:

```bash
./benchmarks/compare_1v1.py --runs 5 --warmup 1
```

### Multi-Run Pooling, Commit History & Regression Analysis (`history.jsonl`)

Every benchmark run writes enriched JSONL records (one JSON object per benchmark line) to:
- `benchmarks/odin.jsonl` (latest Odin snapshot, or accumulated runs with `--append`)
- `benchmarks/history.jsonl` (append-only multi-commit, multi-run history log)

Each JSONL line captures the Git commit SHA, run session ID, summary statistics, quantiles, and the raw `samples_ns` array:
```json
{"rank":1,"lang":"odin","commit":"9ec3509e84e6","run_id":"run-1793604825","name":"1a. Ingest: V2 Prepared Statement Loop (2K rows)","ops":2000,"rows":2000,"runs":5,"iterations":5,"warmup":1,"total_ms":305.839,"ns_per_op":152919.60,"ns_per_item":152919.60,"mean_ns":153461.98,"median_ns":152919.60,"stddev_ns":3765.62,"variance_ns2":14180000.00,"cv_pct":2.45,"min_ns":149080.42,"max_ns":158014.01,"iqr_ns":5733.30,"p95_ns":157714.07,"p99_ns":157954.02,"ops_per_sec":6539.38,"mb_per_sec":0.23,"bytes_row":37,"bytes_used":74000,"samples_ns":[158014.01,150481.20,152919.60,149080.42,156814.50]}
```

When multiple runs are recorded for the same `(commit, lang, name)`, `compare_1v1.py` and `update_readme.sh` automatically **pool all `samples_ns` arrays** across those runs and recompute unified variance metrics:

```bash
# List all commits, run sessions, and pooled sample counts in history.jsonl
./benchmarks/compare_1v1.py --list-commits

# Inspect individual runs, quantiles (IQR, p95, p99), and raw sample arrays for matching tests
./benchmarks/compare_1v1.py --inspect "append_slice"

# Compare two Git commits for statistically significant speedups or regressions (Welch's t/z test)
./benchmarks/compare_1v1.py --compare-commits <baseline_sha> <candidate_sha>
```

`.gitattributes` configures `*.jsonl diff=jsonl`. To get human-readable `git diff` output on `.jsonl` files, configure the `jsonl` textconv driver in your local Git config:

```bash
git config diff.jsonl.textconv "jq -r '\"#\\(.rank) [\\(.commit // \"?\")] \\(.name) | \\(.ns_per_op) ± \\(.stddev_ns // 0) ns/op (CV \\(.cv_pct // 0)%, n=\\(.runs // 1)) | \\(.ops_per_sec) ops/sec\"'"
```

To regenerate the reference tables in both `benchmarks/README.md` and the root `README.md` from `benchmarks/history.jsonl` and `benchmarks/odin.jsonl` (optionally filtering by commit prefix):

```bash
./benchmarks/update_readme.sh [commit_sha]
```

---

## Reference Results (`-o:speed -microarch:native`)

<!-- BEGIN_BENCHMARK_TABLE -->
### 1. Odin Results (`-o:speed -microarch:native`, Commit `9ec3509e84e6`, 5 samples across 1 run(s))

#### 1.1 Vectorized Zero-Copy Scans, UDFs & Wire Codecs (`< 50 ns` · `20M–160B ops/s`, 24 tests)

| # | Benchmark | Ops | Med (`ns`) | Mean ± σ | CV | IQR | `p95` | `p99` | Min | Max | `ops/s` | Bandwidth |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 5 | `1e. Ingest: Custom V2_Copy_Function COPY ... FROM (1M rows)` | 1M | **14.7** | 15.4 ± 8.6 | 55.5% | 6.3 | 26.8 | 29.1 | 8.5 | 29.7 | 33.7M–118M | 1037.3 MB/s |
| 6 | `1f. Export: Custom V2_Copy_Function COPY ... TO Sink (1M rows)` | 1M | **3.1** | 3.2 ± 0.4 | 11.8% | 0.6 | 3.6 | 3.6 | 2.8 | 3.6 | 275M–362M | 4954.2 MB/s |
| 8 | `2a. Scan: Zero-Copy V2_Vector_View Flat (1M rows)` | 1M | **4.9** | 5.0 ± 0.9 | 18.2% | 1.3 | 6.3 | 6.4 | 4.1 | 6.4 | 156M–246M | 4875.6 MB/s |
| 9 | `2b. Scan: Zero-Copy V2_Selection_Vector Filtered (1M source rows)` | 1M | **3.4** | 3.5 ± 0.4 | 11.7% | 0.4 | 4.1 | 4.1 | 3.0 | 4.1 | 243M–336M | 7074.7 MB/s |
| 10 | `2c. Scan: Arrow C Data Interface Arrow_Array_Stream (1M rows)` | 1M | **5.4** | 5.6 ± 0.9 | 15.6% | 0.6 | 7.0 | 7.3 | 4.8 | 7.4 | 135M–211M | 4382.7 MB/s |
| 13 | `2f. Scan: Direct ColumnDataCollection Worker Scan (1M rows)` | 1M | **0.7** | 0.8 ± 0.1 | 19.1% | 0.2 | 1.0 | 1.0 | 0.6 | 1.0 | 1.0B–1.6B | 20.4 GB/s |
| 14 | `2g. Bridge: Arrow_Exporter -> Arrow_Importer Round-Trip (200K)` | 200K | **3.2** | 3.8 ± 0.9 | 22.7% | 1.1 | 5.1 | 5.2 | 3.1 | 5.2 | 192M–326M | 4709.5 MB/s |
| 15 | `2h. Scan: Multi-Worker ColumnDataCollection 4-Thread Scan (1M)` | 1M | **0.4** | 0.4 ± 0.1 | 24.6% | 0.1 | 0.6 | 0.6 | 0.3 | 0.6 | 1.7B–3.1B | 41.4 GB/s |
| 16 | `2i. Scan: Cooperative Stepper v2_step_chunk (1M rows)` | 1M | **4.9** | 4.9 ± 0.4 | 8.6% | 0.5 | 5.5 | 5.6 | 4.4 | 5.6 | 178M–227M | 4895.7 MB/s |
| 17 | `3a. V2_Bytes Write: Inline <= 12 B (v2_vector_assign_string, 200K)` | 200K | **4.2** | 4.5 ± 0.4 | 9.8% | 0.8 | 4.9 | 5.0 | 4.1 | 5.0 | 202M–247M | 2705.5 MB/s |
| 18 | `3b. V2_Bytes Write: Arena > 12 B (v2_vector_assign_string, 200K)` | 200K | **14.0** | 14.0 ± 0.1 | 0.8% | 0.1 | 14.1 | 14.1 | 13.8 | 14.2 | 70.7M–72.5M | 2184.5 MB/s |
| 19 | `3c. Vector Cast: duckdb_v2_vector_cast BIGINT -> DOUBLE (200K)` | 200K | **0.3** | 0.3 ± 0.0 | 3.9% | 0.0 | 0.3 | 0.3 | 0.3 | 0.3 | 3.1B–3.4B | 51.4 GB/s |
| 20 | `3d. Zero-Copy Alias: duckdb_v2_vector_reference (200K rows)` | 200K | **0.0** | 0.0 ± 0.0 | 0.0% | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 100.0B | 1490.1 GB/s |
| 21 | `3e. Vector Flatten: .OTHER (MakeSequence) -> .FLAT (1M rows)` | 1M | **0.2** | 0.2 ± 0.0 | 2.1% | 0.0 | 0.2 | 0.2 | 0.2 | 0.2 | 4.2B–4.3B | 32.4 GB/s |
| 22 | `3f. Wire Codec: 128-Bit HUGEINT/INTERVAL/BIT/BIGNUM (200K)` | 200K | **1.2** | 1.2 ± 0.0 | 0.8% | 0.0 | 1.2 | 1.2 | 1.2 | 1.2 | 826M–840M | 37.6 GB/s |
| 24 | `4b. Native STRUCT(...) Child Vector Write+Read (200K structs)` | 200K | **0.7** | 0.7 ± 0.1 | 11.2% | 0.1 | 0.8 | 0.8 | 0.6 | 0.8 | 1.3B–1.8B | 32.8 GB/s |
| 25 | `4c. Nested LIST(BIGINT) Vector Write+Read (200K lists / 800K items)` | 200K | **0.7** | 0.8 ± 0.1 | 7.0% | 0.1 | 0.8 | 0.8 | 0.7 | 0.8 | 1.2B–1.4B | 61.2 GB/s |
| 26 | `4d. Fixed ARRAY(DOUBLE, 4) Vector Write+Read (200K arrays / 800K f64)` | 200K | **0.5** | 0.5 ± 0.0 | 3.8% | 0.0 | 0.5 | 0.5 | 0.5 | 0.6 | 1.8B–2.0B | 57.3 GB/s |
| 31 | `5d. Lexer: Native C API v2 duckdb_v2_tokenize_sql (300K tokens)` | 300K | **40.8** | 40.7 ± 0.2 | 0.5% | 0.3 | 40.9 | 40.9 | 40.4 | 40.9 | 24.5M–24.7M | — |
| 35 | `6a. UDF: Vectorized Scalar Callback odin_fma (1M rows)` | 1M | **1.1** | 1.2 ± 0.2 | 18.2% | 0.2 | 1.5 | 1.6 | 1.0 | 1.6 | 637M–1.0B | 20.5 GB/s |
| 36 | `6b. UDF: Streaming Table Function odin_gen_series (1M rows)` | 1M | **2.7** | 2.7 ± 0.3 | 9.5% | 0.4 | 3.0 | 3.1 | 2.4 | 3.1 | 326M–417M | 5568.9 MB/s |
| 37 | `6c. UDF: Grouped Hash Aggregate odin_agg_sum (1M rows)` | 1M | **2.4** | 2.4 ± 0.5 | 22.5% | 0.7 | 3.1 | 3.1 | 1.7 | 3.1 | 319M–575M | 3178.9 MB/s |
| 38 | `6d. UDF: Table Function Projection + Filter Pushdown (1M rows)` | 1M | **0.5** | 0.5 ± 0.0 | 6.6% | 0.0 | 0.5 | 0.5 | 0.4 | 0.5 | 1.9B–2.3B | 31.0 GB/s |
| 39 | `6e. UDF: Custom Type & Vectorized V2_Cast_Function (1M rows)` | 1M | **0.8** | 0.8 ± 0.1 | 9.6% | 0.1 | 0.9 | 0.9 | 0.7 | 0.9 | 1.1B–1.5B | 19.4 GB/s |

#### 1.2 Sub-Microsecond Reflection Ingest, Unmarshaling & DSL Compilation (`50–999 ns` · `1M–20M ops/s`, 11 tests)

| # | Benchmark | Ops | Med (`ns`) | Mean ± σ | CV | IQR | `p95` | `p99` | Min | Max | `ops/s` | Bandwidth |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 2 | `1b. Ingest: Legacy V1 Appender API (100K rows)` | 100K | **167** | 170 ± 16.7 | 9.9% | 30.1 | 188 | 189 | 154 | 190 | 5.3M–6.5M | 210.9 MB/s |
| 3 | `1c. Ingest: V2 ColumnDataCollection append_slice (100K rows)` | 100K | **132** | 178 ± 126 | 71.1% | 21.4 | 349 | 392 | 109 | 403 | 2.5M–9.2M | 268.3 MB/s |
| 4 | `1d. Ingest: Nullable Maybe(T) append_slice (100K rows, 25% NULL)` | 100K | **124** | 150 ± 65.6 | 43.8% | 6.9 | 239 | 261 | 113 | 267 | 3.7M–8.8M | 285.1 MB/s |
| 7 | `1g. Ingest: Struct_Appender(T) 1K x 100-Row Micro-Batches (100K)` | 100K | **139** | 162 ± 66.3 | 40.9% | 7.2 | 252 | 274 | 117 | 280 | 3.6M–8.5M | 254.4 MB/s |
| 11 | `2d. Unmarshal: core:reflect query_as Non-Null Structs (100K rows)` | 100K | **64.3** | 64.9 ± 2.6 | 4.0% | 2.2 | 68.0 | 68.4 | 61.7 | 68.5 | 14.6M–16.2M | 548.9 MB/s |
| 12 | `2e. Unmarshal: core:reflect query_as Nullable Maybe(T) (100K rows)` | 100K | **88.4** | 88.7 ± 4.3 | 4.8% | 5.1 | 94.2 | 95.0 | 84.6 | 95.2 | 10.5M–11.8M | 399.3 MB/s |
| 23 | `4a. JSON Tag Round-Trip: append_slice + query_as (10K structs)` | 10K | **530** | 556 ± 42.9 | 7.7% | 56.9 | 612 | 618 | 523 | 619 | 1.6M–1.9M | 115.1 MB/s |
| 28 | `5a. DSL: query_to_sql Pipeline Compilation (100K queries)` | 100K | **225** | 224 ± 1.9 | 0.8% | 3.7 | 226 | 226 | 222 | 226 | 4.4M–4.5M | — |
| 30 | `5c. Parser: sqllogic_parse_script (50K directives / 1K scripts)` | 50K | **62.2** | 62.1 ± 0.6 | 0.9% | 0.3 | 62.7 | 62.8 | 61.2 | 62.8 | 15.9M–16.3M | — |
| 33 | `5f. Quack: SQL Builders + URI Normalize + Template (100K ops)` | 100K | **76.8** | 76.8 ± 0.2 | 0.3% | 0.4 | 77.1 | 77.1 | 76.5 | 77.1 | 13.0M–13.1M | — |
| 34 | `5g. Reflection DDL: create_table_sql + v2_quote_identifier (100K)` | 100K | **200** | 202 ± 5.6 | 2.8% | 5.4 | 209 | 211 | 197 | 211 | 4.7M–5.1M | — |

#### 1.3 Multi-Microsecond Point Lookups, Catalog, VFS & Transactions (`≥ 1 µs` · `2K–360K ops/s`, 13 tests)

| # | Benchmark | Ops | Med (`µs`) | Mean ± σ | CV | IQR | `p95` | `p99` | Min | Max | `ops/s` | Bandwidth |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | `1a. Ingest: V2 Prepared Statement Loop (2K rows)` | 2K | **152.9** | 153.5 ± 3.77 | 2.5% | 5.73 | 157.7 | 158.0 | 149.1 | 158.0 | 6.3K–6.7K | 0.2 MB/s |
| 27 | `4e. Composite Values: VARIANT/MAP/UNION/DECIMAL (10K ops)` | 10K | **3.72** | 3.74 ± 0.06 | 1.7% | 0.10 | 3.81 | 3.82 | 3.68 | 3.82 | 262K–272K | — |
| 29 | `5b. Codegen: introspect_table_schema + Odin/CUE (1K tables)` | 1K | **4.54** | 4.54 ± 0.01 | 0.2% | 0.01 | 4.55 | 4.55 | 4.53 | 4.55 | 220K–221K | — |
| 32 | `5e. Catalog: duckdb_v2_connection_describe_table (5K lookups)` | 5K | **2.93** | 2.97 ± 0.09 | 3.1% | 0.01 | 3.10 | 3.13 | 2.93 | 3.14 | 319K–342K | — |
| 40 | `6f. UDF: V2_Replacement_Scan Virtual Table Scan (1K queries)` | 1K | **272.8** | 277.9 ± 10.7 | 3.9% | 16.5 | 290.8 | 291.5 | 267.6 | 291.7 | 3.4K–3.7K | — |
| 41 | `6g. Extensibility: V2_Pragma + V2_Custom_Option + V2_Macro (1K)` | 1K | **68.2** | 68.1 ± 1.69 | 2.5% | 1.56 | 70.3 | 70.6 | 66.3 | 70.7 | 14.1K–15.1K | — |
| 42 | `7a. Point Lookup: Ad-Hoc v2_query Parse+Bind+Exec (1K queries)` | 1K | **218.9** | 217.6 ± 4.14 | 1.9% | 7.64 | 221.6 | 221.8 | 213.2 | 221.8 | 4.5K–4.7K | — |
| 43 | `7b. Point Lookup: Pre-Compiled v2_prepared_execute (1K queries)` | 1K | **191.0** | 193.3 ± 5.57 | 2.9% | 0.31 | 200.8 | 202.7 | 190.0 | 203.2 | 4.9K–5.3K | — |
| 44 | `7c. DSL Pipeline: query_execute_as Build+Bind+Unmarshal (1K)` | 1K | **433.7** | 440.0 ± 12.4 | 2.8% | 8.51 | 457.0 | 460.0 | 429.9 | 460.7 | 2.2K–2.3K | 0.1 MB/s |
| 45 | `7d. Transactions: v2_with_transaction Commit + Rollback (1K tx)` | 1K | **132.0** | 131.8 ± 1.77 | 1.3% | 0.96 | 133.7 | 133.9 | 129.1 | 133.9 | 7.5K–7.7K | — |
| 46 | `7e. Prepared DSL: prepared_query_execute_as Cached Plan+Schema (1K)` | 1K | **360.2** | 360.5 ± 6.07 | 1.7% | 6.39 | 367.5 | 368.3 | 352.5 | 368.5 | 2.7K–2.8K | 0.1 MB/s |
| 47 | `8a. VFS: Positional write_at + read_at (1K x 64 KB = 64 MB)` | 1K | **2.77** | 2.77 ± 0.02 | 0.6% | 0.02 | 2.79 | 2.79 | 2.75 | 2.79 | 358K–364K | 22.0 GB/s |
| 48 | `8b. Telemetry: V2_Query_Metrics Tree + V2_Log_Sink (10K ops)` | 10K | **10.5** | 10.6 ± 0.14 | 1.4% | 0.24 | 10.7 | 10.7 | 10.4 | 10.7 | 93.3K–96.1K | — |
<!-- END_BENCHMARK_TABLE -->
