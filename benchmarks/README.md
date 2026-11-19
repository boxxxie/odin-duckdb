# odin-duckdb Benchmarks

This directory contains the 48-benchmark statistical performance suite for `odin-duckdb`, measuring throughput (`ops/sec`), bandwidth (`MB/s` / `GB/s`), median/mean latency (`ns/op`), and sample variance (`±σ`, `CV%`, `IQR`, `p95`, `p99`, `min..max`) across the DuckDB 2.0 C API v2 (`duckdb/capi_v2.odin`), Arrow C Data Interface bridge (`duckdb/arrow.odin`), `core:reflect` struct unmarshaling and appenders (`duckdb/reflect.odin`), composable query DSL (`duckdb/dsl.odin`), schema codegen (`duckdb/codegen.odin`), and Quack extension utilities (`duckdb/quack.odin`).

---

## Running the Benchmarks

Always compile benchmarks with `-o:speed` (and `-microarch:native`). The recommended runner is [`hugi`](../ols.json), which compiles and runs `benchmarks/bench_main.odin`, captures exact integer batch nanosecond samples (`HPKT` binary packets), and ingests results into [`benchmarks/history.hugidb`](history.hugidb):

```bash
# Run the full 48-benchmark suite via hugi and ingest into benchmarks/history.hugidb
hugi run benchmarks --runs 5 --warmup 1 \
  --extra-build-flags '-microarch:native -extra-linker-flags:"-L/home/pauli/.local/lib -Wl,-rpath,/home/pauli/.local/lib"'

# Smoke-test a subset in-memory using an overlay branch without modifying benchmarks/history.hugidb
hugi run benchmarks --overlay --runs 1 --warmup 0 --groups scan --filter "2a.|2b." \
  --extra-build-flags '-microarch:native -extra-linker-flags:"-L/home/pauli/.local/lib -Wl,-rpath,/home/pauli/.local/lib"'
```

You can also invoke the benchmark binary directly with `odin run` (when `--packet-out` is omitted, `bench_main.odin` emits JSONL records to `benchmarks/odin.jsonl` and `benchmarks/history.jsonl` as before):

```bash
LD_LIBRARY_PATH=/home/pauli/.local/lib odin run benchmarks -collection:hugi=../hugi/hugi -o:speed -microarch:native \
  -extra-linker-flags:"-L/home/pauli/.local/lib -Wl,-rpath,/home/pauli/.local/lib" -- --runs 5 --warmup 1
```

### Compressed Store, Regression Comparison & `hugi` Workflows

[`benchmarks/history.hugidb`](history.hugidb) stores multi-commit benchmark histories in a compressed transactional `xitdb` database (`CZPK` / `CZCH` cold rollups with exact fixed-point femtosecond `i64` timings):

```bash
# Inspect commit and run history
hugi history --db benchmarks/history.hugidb --runs

# Inspect quantiles, CV%, and footprints for matching benchmarks
hugi inspect --db benchmarks/history.hugidb "append_slice"

# Compare the last two commits (or specify --commits <base>..<cand>) via Welch t-test / Mann-Whitney U
hugi compare --last --db benchmarks/history.hugidb

# Backfill legacy JSONL logs into history.hugidb and compact cold rollups
hugi ingest --db benchmarks/history.hugidb benchmarks/history.jsonl
hugi compact --db benchmarks/history.hugidb --keep-hot 0
```

### DuckDB-on-Parquet Analytics (`query_hugidb.sql`)

Export the full commit series from `benchmarks/history.hugidb` to Apache Parquet (`DECIMAL(18,6)` timings + compressed sample blobs) and analyze latency-tiered bandwidth and commit trends directly with DuckDB SQL ([`benchmarks/query_hugidb.sql`](query_hugidb.sql)):

```bash
hugi export --db benchmarks/history.hugidb --all-commits --out .tmp/history.parquet
duckdb -markdown -light-mode -f benchmarks/query_hugidb.sql
```

### Regenerating README Tables (`update_readme.sh`)

To regenerate the latency-tiered bandwidth tables in both `benchmarks/README.md` and the root `README.md` (optionally targeting a commit prefix):

```bash
./benchmarks/update_readme.sh [commit_sha]
```

When `benchmarks/history.hugidb` and `hugi` are available, `update_readme.sh` streams `hugi export --db benchmarks/history.hugidb --all-commits --format jsonl --out -` into `jq -s` (and falls back automatically to `benchmarks/history.jsonl` / `benchmarks/odin.jsonl` otherwise).

### Selective Execution & Git-Diff Impact Mapping (`--plan` / `--affected` / `--groups` / `--filter`)

When optimizing specific subsystems or procedures, you do not need to re-run all 48 benchmarks. `compare_1v1.py` can inspect `git diff` across `duckdb/*.odin` and `benchmarks/bench_main.odin`, identify modified files and Odin procedures, and map them directly to the affected benchmark groups and name filters:

```bash
# Dry-run: inspect git diff (working tree, staged, or latest commit) and print the affected benchmark plan
./benchmarks/compare_1v1.py --plan

# Inspect a specific commit or range
./benchmarks/compare_1v1.py --plan HEAD~1..HEAD

# Automatically execute ONLY the benchmarks affected by your code changes
./benchmarks/compare_1v1.py --affected

# Or manually pass --groups / --filter to hugi run or compare_1v1.py
hugi run benchmarks --groups dsl_codegen,point_tx --filter "5a.|7c.|7e." \
  --extra-build-flags '-microarch:native -extra-linker-flags:"-L/home/pauli/.local/lib -Wl,-rpath,/home/pauli/.local/lib"'
```

When a selective benchmark run is recorded for a commit, `./benchmarks/update_readme.sh` automatically:
1. Places **Section 1 (Latest Code-Change Impact & Affected Benchmarks)** at the top of the report, showing the inspected diff, changed files/procedures, and latency-tiered progression tables (`1.1`, `1.2`, `1.3`) for the re-run benchmarks against their immediate prior baseline.
2. Marks selectively re-run benchmarks with **↻** in the `#` rank column of **Section 2 (Odin Full Suite Results)** while retaining the latest verified baseline for untouched benchmarks.

`.gitattributes` configures `*.jsonl diff=jsonl`. To get human-readable `git diff` output on legacy `.jsonl` files, configure the `jsonl` textconv driver in your local Git config:

```bash
git config diff.jsonl.textconv "jq -r '\"#\\(.rank) [\\(.commit // \"?\")] \\(.name) | \\(.ns_per_op) ± \\(.stddev_ns // 0) ns/op (CV \\(.cv_pct // 0)%, n=\\(.runs // 1)) | \\(.ops_per_sec) ops/sec\"'"
```

---

## Reference Results (`-o:speed -microarch:native`)

<!-- BEGIN_BENCHMARK_TABLE -->
### 1. Latest Code-Change Impact & Affected Benchmarks (`9ec3509e84e6` → `6a128a2f8c8a`)

> **Benchmark Scope:** `9ec3509e84e6` → `6a128a2f8c8a` (48 / 48 benchmarks compared)

#### 1.1 Vectorized Zero-Copy Scans, UDFs & Wire Codecs (`ns`, 23 tests)

| # | Benchmark | Verdict | Delta | Speedup | Base `9ec3509` (`ns`) | Curr `6a128a2` (`ns`) | Welch $z$ | Base Mean ± σ | Curr Mean ± σ |
| ---: | :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 5 | `1e. Ingest: Custom V2_Copy_Function COPY ... FROM (1M rows)` | `~NOISE` | `+45.3%` | 0.69x | 14.7 | **21.4** | `1.1` | 15.4 ± 8.6 | 20.9 ± 7.6 |
| 6 | `1f. Export: Custom V2_Copy_Function COPY ... TO Sink (1M rows)` | `~NOISE` | `-3.5%` | 1.04x | 3.1 | **3.0** | `0.4` | 3.2 ± 0.4 | 3.3 ± 0.5 |
| 8 | `2a. Scan: Zero-Copy V2_Vector_View Flat (1M rows)` | `~NOISE` | `+28.9%` | 0.78x | 4.9 | **6.3** | `2.4` | 5.0 ± 0.9 | 6.2 ± 0.7 |
| 9 | `2b. Scan: Zero-Copy V2_Selection_Vector Filtered (1M source rows)` | **REGRESSION** | `+31.4%` | 0.76x | 3.4 | **4.4** | `3.7` | 3.5 ± 0.4 | 4.4 ± 0.5 |
| 10 | `2c. Scan: Arrow C Data Interface Arrow_Array_Stream (1M rows)` | **REGRESSION** | `+24.3%` | 0.80x | 5.4 | **6.8** | `3.0` | 5.6 ± 0.9 | 7.1 ± 0.8 |
| 13 | `2f. Scan: Direct ColumnDataCollection Worker Scan (1M rows)` | `~NOISE` | `+39.4%` | 0.72x | 0.7 | **1.0** | `3.5` | 0.8 ± 0.1 | 1.0 ± 0.1 |
| 14 | `2g. Bridge: Arrow_Exporter -> Arrow_Importer Round-Trip (200K)` | **REGRESSION** | `+59.3%` | 0.63x | 3.2 | **5.2** | `4.1` | 3.8 ± 0.9 | 5.2 ± 0.2 |
| 15 | `2h. Scan: Multi-Worker ColumnDataCollection 4-Thread Scan (1M)` | `~NOISE` | `+20.5%` | 0.83x | 0.4 | **0.4** | `1.1` | 0.4 ± 0.1 | 0.5 ± 0.1 |
| 16 | `2i. Scan: Cooperative Stepper v2_step_chunk (1M rows)` | **REGRESSION** | `+19.9%` | 0.83x | 4.9 | **5.8** | `4.2` | 4.9 ± 0.4 | 6.2 ± 0.6 |
| 17 | `3a. V2_Bytes Write: Inline <= 12 B (v2_vector_assign_string, 200K)` | **REGRESSION** | `+63.6%` | 0.61x | 4.2 | **6.9** | `11.2` | 4.5 ± 0.4 | 7.0 ± 0.4 |
| 18 | `3b. V2_Bytes Write: Arena > 12 B (v2_vector_assign_string, 200K)` | **REGRESSION** | `+56.9%` | 0.64x | 14.0 | **21.9** | `118.9` | 14.0 ± 0.1 | 21.9 ± 0.1 |
| 19 | `3c. Vector Cast: duckdb_v2_vector_cast BIGINT -> DOUBLE (200K)` | `~NOISE` | `+65.0%` | 0.61x | 0.3 | **0.5** | `28.4` | 0.3 ± 0.0 | 0.5 ± 0.0 |
| 20 | `3d. Zero-Copy Alias: duckdb_v2_vector_reference (200K rows)` | `~NOISE` | `+0.0%` | 1.00x | 0.0 | **0.0** | `0.5` | 0.0 ± 0.0 | 0.0 ± 0.0 |
| 21 | `3e. Vector Flatten: .OTHER (MakeSequence) -> .FLAT (1M rows)` | `~NOISE` | `+61.6%` | 0.62x | 0.2 | **0.4** | `64.5` | 0.2 ± 0.0 | 0.4 ± 0.0 |
| 22 | `3f. Wire Codec: 128-Bit HUGEINT/INTERVAL/BIT/BIGNUM (200K)` | **REGRESSION** | `+62.2%` | 0.62x | 1.2 | **1.9** | `89.9` | 1.2 ± 0.0 | 1.9 ± 0.0 |
| 24 | `4b. Native STRUCT(...) Child Vector Write+Read (200K structs)` | `~NOISE` | `+26.9%` | 0.79x | 0.7 | **0.9** | `6.4` | 0.7 ± 0.1 | 0.9 ± 0.0 |
| 25 | `4c. Nested LIST(BIGINT) Vector Write+Read (200K lists / 800K items)` | `~NOISE` | `+63.4%` | 0.61x | 0.7 | **1.2** | `18.6` | 0.8 ± 0.1 | 1.2 ± 0.0 |
| 26 | `4d. Fixed ARRAY(DOUBLE, 4) Vector Write+Read (200K arrays / 800K f64)` | `~NOISE` | `+67.1%` | 0.60x | 0.5 | **0.9** | `14.7` | 0.5 ± 0.0 | 0.9 ± 0.1 |
| 35 | `6a. UDF: Vectorized Scalar Callback odin_fma (1M rows)` | `~NOISE` | `+36.5%` | 0.73x | 1.1 | **1.5** | `2.6` | 1.2 ± 0.2 | 1.5 ± 0.2 |
| 36 | `6b. UDF: Streaming Table Function odin_gen_series (1M rows)` | **REGRESSION** | `+51.8%` | 0.66x | 2.7 | **4.2** | `14.0` | 2.7 ± 0.3 | 4.1 ± 0.0 |
| 37 | `6c. UDF: Grouped Hash Aggregate odin_agg_sum (1M rows)` | `~NOISE` | `+17.4%` | 0.85x | 2.4 | **2.8** | `1.5` | 2.4 ± 0.5 | 2.8 ± 0.3 |
| 38 | `6d. UDF: Table Function Projection + Filter Pushdown (1M rows)` | `~NOISE` | `+57.1%` | 0.64x | 0.5 | **0.8** | `19.1` | 0.5 ± 0.0 | 0.7 ± 0.0 |
| 39 | `6e. UDF: Custom Type & Vectorized V2_Cast_Function (1M rows)` | `~NOISE` | `+44.3%` | 0.69x | 0.8 | **1.1** | `11.0` | 0.8 ± 0.1 | 1.1 ± 0.0 |


#### 1.2 Sub-Microsecond Reflection Ingest, Unmarshaling & DSL Compilation (`ns`, 12 tests)

| # | Benchmark | Verdict | Delta | Speedup | Base `9ec3509` (`ns`) | Curr `6a128a2` (`ns`) | Welch $z$ | Base Mean ± σ | Curr Mean ± σ |
| ---: | :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 2 | `1b. Ingest: Legacy V1 Appender API (100K rows)` | **REGRESSION** | `+53.9%` | 0.65x | 167 | **258** | `6.0` | 170 ± 16.7 | 255 ± 27.1 |
| 3 | `1c. Ingest: V2 ColumnDataCollection append_slice (100K rows)` | `~NOISE` | `+51.5%` | 0.66x | 132 | **199** | `0.9` | 178 ± 126 | 263 ± 168 |
| 4 | `1d. Ingest: Nullable Maybe(T) append_slice (100K rows, 25% NULL)` | `~NOISE` | `+58.8%` | 0.63x | 124 | **197** | `1.5` | 150 ± 65.6 | 240 ± 123 |
| 7 | `1g. Ingest: Struct_Appender(T) 1K x 100-Row Micro-Batches (100K)` | `~NOISE` | `+25.4%` | 0.80x | 139 | **174** | `1.2` | 162 ± 66.3 | 233 ± 119 |
| 11 | `2d. Unmarshal: core:reflect query_as Non-Null Structs (100K rows)` | **REGRESSION** | `+55.6%` | 0.64x | 64.3 | **100** | `13.5` | 64.9 ± 2.6 | 101 ± 5.3 |
| 12 | `2e. Unmarshal: core:reflect query_as Nullable Maybe(T) (100K rows)` | **REGRESSION** | `+50.9%` | 0.66x | 88.4 | **133** | `16.2` | 88.7 ± 4.3 | 135 ± 4.8 |
| 23 | `4a. JSON Tag Round-Trip: append_slice + query_as (10K structs)` | **REGRESSION** | `+57.1%` | 0.64x | 530 | **833** | `13.1` | 556 ± 42.9 | 843 ± 23.4 |
| 28 | `5a. DSL: query_to_sql Pipeline Compilation (100K queries)` | **REGRESSION** | `+56.7%` | 0.64x | 225 | **352** | `144.4` | 224 ± 1.9 | 353 ± 0.6 |
| 30 | `5c. Parser: sqllogic_parse_script (50K directives / 1K scripts)` | **REGRESSION** | `+59.5%` | 0.63x | 62.2 | **99.3** | `111.6` | 62.1 ± 0.6 | 99.2 ± 0.5 |
| 31 | `5d. Lexer: Native C API v2 duckdb_v2_tokenize_sql (300K tokens)` | **REGRESSION** | `+57.1%` | 0.64x | 40.8 | **64.1** | `13.4` | 40.7 ± 0.2 | 66.2 ± 4.3 |
| 33 | `5f. Quack: SQL Builders + URI Normalize + Template (100K ops)` | **REGRESSION** | `+63.9%` | 0.61x | 76.8 | **126** | `157.6` | 76.8 ± 0.2 | 126 ± 0.7 |
| 34 | `5g. Reflection DDL: create_table_sql + v2_quote_identifier (100K)` | **REGRESSION** | `+63.4%` | 0.61x | 200 | **327** | `35.9` | 202 ± 5.6 | 330 ± 5.6 |


#### 1.3 Multi-Microsecond Point Lookups, Catalog, VFS & Transactions (`µs`, 13 tests)

| # | Benchmark | Verdict | Delta | Speedup | Base `9ec3509` (`µs`) | Curr `6a128a2` (`µs`) | Welch $z$ | Base Mean ± σ | Curr Mean ± σ |
| ---: | :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | `1a. Ingest: V2 Prepared Statement Loop (2K rows)` | **REGRESSION** | `+51.6%` | 0.66x | 152.9 | **231.9** | `38.4` | 153.5 ± 3.77 | 231.8 ± 2.57 |
| 27 | `4e. Composite Values: VARIANT/MAP/UNION/DECIMAL (10K ops)` | **REGRESSION** | `+56.8%` | 0.64x | 3.72 | **5.83** | `43.5` | 3.74 ± 0.06 | 5.85 ± 0.09 |
| 29 | `5b. Codegen: introspect_table_schema + Odin/CUE (1K tables)` | **REGRESSION** | `+65.7%` | 0.60x | 4.54 | **7.52** | `65.1` | 4.54 ± 0.01 | 7.56 ± 0.10 |
| 32 | `5e. Catalog: duckdb_v2_connection_describe_table (5K lookups)` | **REGRESSION** | `+62.7%` | 0.61x | 2.93 | **4.77** | `33.6` | 2.97 ± 0.09 | 4.81 ± 0.08 |
| 40 | `6f. UDF: V2_Replacement_Scan Virtual Table Scan (1K queries)` | **REGRESSION** | `+52.7%` | 0.65x | 272.8 | **416.5** | `23.4` | 277.9 ± 10.7 | 419.3 ± 8.24 |
| 41 | `6g. Extensibility: V2_Pragma + V2_Custom_Option + V2_Macro (1K)` | **REGRESSION** | `+63.6%` | 0.61x | 68.2 | **111.5** | `33.5` | 68.1 ± 1.69 | 112.3 ± 2.41 |
| 42 | `7a. Point Lookup: Ad-Hoc v2_query Parse+Bind+Exec (1K queries)` | **REGRESSION** | `+67.6%` | 0.60x | 218.9 | **366.8** | `39.5` | 217.6 ± 4.14 | 369.6 ± 7.54 |
| 43 | `7b. Point Lookup: Pre-Compiled v2_prepared_execute (1K queries)` | **REGRESSION** | `+66.8%` | 0.60x | 191.0 | **318.6** | `40.7` | 193.3 ± 5.57 | 318.9 ± 4.08 |
| 44 | `7c. DSL Pipeline: query_execute_as Build+Bind+Unmarshal (1K)` | **REGRESSION** | `+51.8%` | 0.66x | 433.7 | **658.2** | `34.7` | 440.0 ± 12.4 | 659.5 ± 6.78 |
| 45 | `7d. Transactions: v2_with_transaction Commit + Rollback (1K tx)` | **REGRESSION** | `+64.0%` | 0.61x | 132.0 | **216.5** | `62.0` | 131.8 ± 1.77 | 216.8 ± 2.50 |
| 46 | `7e. Prepared DSL: prepared_query_execute_as Cached Plan+Schema (1K)` | **REGRESSION** | `+54.1%` | 0.65x | 360.2 | **555.0** | `61.3` | 360.5 ± 6.07 | 555.3 ± 3.69 |
| 47 | `8a. VFS: Positional write_at + read_at (1K x 64 KB = 64 MB)` | **REGRESSION** | `+36.8%` | 0.73x | 2.77 | **3.79** | `71.2` | 2.77 ± 0.02 | 3.80 ± 0.03 |
| 48 | `8b. Telemetry: V2_Query_Metrics Tree + V2_Log_Sink (10K ops)` | **REGRESSION** | `+57.9%` | 0.63x | 10.5 | **16.6** | `79.6` | 10.6 ± 0.14 | 16.6 ± 0.09 |


### 2. Odin Full Suite Results (`-o:speed -microarch:native`, Commit `6a128a2f8c8a`, 5 samples across 1 run(s))

#### 2.1 Vectorized Zero-Copy Scans, UDFs & Wire Codecs (`< 50 ns` · `20M–160B ops/s`, 23 tests)

| # | Benchmark | Med (`ns`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops | Bandwidth |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 5 | `1e. Ingest: Custom V2_Copy_Function COPY ... FROM (1M rows)` | **21.4** | 20.9 ± 7.6 | 36.1% | 30.9M | 83.7M | 5.1 | 30.3 | 31.9 | 11.9 | 32.3 | 1M | 714.0 MB/s |
| 6 | `1f. Export: Custom V2_Copy_Function COPY ... TO Sink (1M rows)` | **3.0** | 3.3 ± 0.5 | 16.3% | 249M | 353M | 0.8 | 3.9 | 4.0 | 2.8 | 4.0 | 1M | 5134.9 MB/s |
| 8 | `2a. Scan: Zero-Copy V2_Vector_View Flat (1M rows)` | **6.3** | 6.2 ± 0.7 | 12.1% | 142M | 191M | 1.1 | 7.0 | 7.0 | 5.2 | 7.0 | 1M | 3782.8 MB/s |
| 9 | `2b. Scan: Zero-Copy V2_Selection_Vector Filtered (1M source rows)` | **4.4** | 4.4 ± 0.5 | 10.4% | 198M | 252M | 0.7 | 5.0 | 5.0 | 4.0 | 5.1 | 1M | 5385.8 MB/s |
| 10 | `2c. Scan: Arrow C Data Interface Arrow_Array_Stream (1M rows)` | **6.8** | 7.1 ± 0.8 | 11.2% | 119M | 155M | 0.7 | 8.2 | 8.3 | 6.5 | 8.4 | 1M | 3525.3 MB/s |
| 13 | `2f. Scan: Direct ColumnDataCollection Worker Scan (1M rows)` | **1.0** | 1.0 ± 0.1 | 12.1% | 801M | 1.1B | 0.1 | 1.2 | 1.2 | 0.9 | 1.2 | 1M | 14.6 GB/s |
| 14 | `2g. Bridge: Arrow_Exporter -> Arrow_Importer Round-Trip (200K)` | **5.2** | 5.2 ± 0.2 | 4.8% | 181M | 201M | 0.4 | 5.5 | 5.5 | 5.0 | 5.5 | 200K | 2957.3 MB/s |
| 15 | `2h. Scan: Multi-Worker ColumnDataCollection 4-Thread Scan (1M)` | **0.4** | 0.5 ± 0.1 | 15.3% | 1.7B | 2.4B | 0.0 | 0.6 | 0.6 | 0.4 | 0.6 | 1M | 34.4 GB/s |
| 16 | `2i. Scan: Cooperative Stepper v2_step_chunk (1M rows)` | **5.8** | 6.2 ± 0.6 | 9.6% | 141M | 174M | 0.7 | 7.0 | 7.1 | 5.7 | 7.1 | 1M | 4082.4 MB/s |
| 17 | `3a. V2_Bytes Write: Inline <= 12 B (v2_vector_assign_string, 200K)` | **6.9** | 7.0 ± 0.4 | 5.1% | 130M | 147M | 0.1 | 7.5 | 7.6 | 6.8 | 7.7 | 200K | 1653.6 MB/s |
| 18 | `3b. V2_Bytes Write: Arena > 12 B (v2_vector_assign_string, 200K)` | **21.9** | 21.9 ± 0.1 | 0.5% | 45.5M | 46.0M | 0.1 | 22.0 | 22.0 | 21.7 | 22.0 | 200K | 1392.6 MB/s |
| 19 | `3c. Vector Cast: duckdb_v2_vector_cast BIGINT -> DOUBLE (200K)` | **0.5** | 0.5 ± 0.0 | 2.4% | 2.0B | 2.1B | 0.0 | 0.5 | 0.5 | 0.5 | 0.5 | 200K | 31.1 GB/s |
| 20 | `3d. Zero-Copy Alias: duckdb_v2_vector_reference (200K rows)` | **0.0** | 0.0 ± 0.0 | 5.4% | 93.7B | 106.8B | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 200K | 1509.7 GB/s |
| 21 | `3e. Vector Flatten: .OTHER (MakeSequence) -> .FLAT (1M rows)` | **0.4** | 0.4 ± 0.0 | 0.7% | 2.67B | 2.72B | 0.0 | 0.4 | 0.4 | 0.4 | 0.4 | 1M | 20.0 GB/s |
| 22 | `3f. Wire Codec: 128-Bit HUGEINT/INTERVAL/BIT/BIGNUM (200K)` | **1.9** | 1.9 ± 0.0 | 0.8% | 512M | 524M | 0.0 | 1.9 | 2.0 | 1.9 | 2.0 | 200K | 23.2 GB/s |
| 24 | `4b. Native STRUCT(...) Child Vector Write+Read (200K structs)` | **0.9** | 0.9 ± 0.0 | 5.2% | 1.0B | 1.2B | 0.1 | 1.0 | 1.0 | 0.9 | 1.0 | 200K | 25.8 GB/s |
| 25 | `4c. Nested LIST(BIGINT) Vector Write+Read (200K lists / 800K items)` | **1.2** | 1.2 ± 0.0 | 2.7% | 792M | 842M | 0.0 | 1.3 | 1.3 | 1.2 | 1.3 | 200K | 37.5 GB/s |
| 26 | `4d. Fixed ARRAY(DOUBLE, 4) Vector Write+Read (200K arrays / 800K f64)` | **0.9** | 0.9 ± 0.1 | 5.8% | 1.0B | 1.2B | 0.0 | 0.9 | 0.9 | 0.8 | 1.0 | 200K | 34.3 GB/s |
| 35 | `6a. UDF: Vectorized Scalar Callback odin_fma (1M rows)` | **1.5** | 1.5 ± 0.2 | 10.5% | 601M | 794M | 0.2 | 1.6 | 1.7 | 1.3 | 1.7 | 1M | 15.0 GB/s |
| 36 | `6b. UDF: Streaming Table Function odin_gen_series (1M rows)` | **4.2** | 4.1 ± 0.0 | 1.2% | 239M | 246M | 0.1 | 4.2 | 4.2 | 4.1 | 4.2 | 1M | 3669.6 MB/s |
| 37 | `6c. UDF: Grouped Hash Aggregate odin_agg_sum (1M rows)` | **2.8** | 2.8 ± 0.3 | 12.1% | 307M | 430M | 0.2 | 3.2 | 3.2 | 2.3 | 3.3 | 1M | 2708.3 MB/s |
| 38 | `6d. UDF: Table Function Projection + Filter Pushdown (1M rows)` | **0.8** | 0.7 ± 0.0 | 2.1% | 1.3B | 1.4B | 0.0 | 0.8 | 0.8 | 0.7 | 0.8 | 1M | 19.8 GB/s |
| 39 | `6e. UDF: Custom Type & Vectorized V2_Cast_Function (1M rows)` | **1.1** | 1.1 ± 0.0 | 3.4% | 864M | 940M | 0.1 | 1.2 | 1.2 | 1.1 | 1.2 | 1M | 13.4 GB/s |

#### 2.2 Sub-Microsecond Reflection Ingest, Unmarshaling & DSL Compilation (`50–999 ns` · `1M–20M ops/s`, 12 tests)

| # | Benchmark | Med (`ns`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops | Bandwidth |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 2 | `1b. Ingest: Legacy V1 Appender API (100K rows)` | **258** | 255 ± 27.1 | 10.6% | 3.4M | 4.4M | 32.2 | 288 | 293 | 228 | 295 | 100K | 137.0 MB/s |
| 3 | `1c. Ingest: V2 ColumnDataCollection append_slice (100K rows)` | **199** | 263 ± 168 | 64.0% | 1.8M | 5.9M | 21.1 | 491 | 549 | 170 | 563 | 100K | 177.1 MB/s |
| 4 | `1d. Ingest: Nullable Maybe(T) append_slice (100K rows, 25% NULL)` | **197** | 240 ± 123 | 51.1% | 2.2M | 5.8M | 29.9 | 407 | 448 | 172 | 459 | 100K | 179.6 MB/s |
| 7 | `1g. Ingest: Struct_Appender(T) 1K x 100-Row Micro-Batches (100K)` | **174** | 233 ± 119 | 51.0% | 2.3M | 5.9M | 33.7 | 396 | 434 | 168 | 444 | 100K | 202.9 MB/s |
| 11 | `2d. Unmarshal: core:reflect query_as Non-Null Structs (100K rows)` | **100** | 101 ± 5.3 | 5.3% | 9.1M | 10.5M | 2.9 | 108 | 109 | 95.6 | 109 | 100K | 352.8 MB/s |
| 12 | `2e. Unmarshal: core:reflect query_as Nullable Maybe(T) (100K rows)` | **133** | 135 ± 4.8 | 3.6% | 7.1M | 7.7M | 7.8 | 141 | 141 | 131 | 141 | 100K | 264.5 MB/s |
| 23 | `4a. JSON Tag Round-Trip: append_slice + query_as (10K structs)` | **833** | 843 ± 23.4 | 2.8% | 1.1M | 1.2M | 7.9 | 875 | 882 | 827 | 884 | 10K | 73.3 MB/s |
| 28 | `5a. DSL: query_to_sql Pipeline Compilation (100K queries)` | **352** | 353 ± 0.6 | 0.2% | 2.83M | 2.84M | 1.0 | 353 | 353 | 352 | 353 | 100K | — |
| 30 | `5c. Parser: sqllogic_parse_script (50K directives / 1K scripts)` | **99.3** | 99.2 ± 0.5 | 0.5% | 10.0M | 10.2M | 0.1 | 99.5 | 99.6 | 98.4 | 99.6 | 50K | — |
| 31 | `5d. Lexer: Native C API v2 duckdb_v2_tokenize_sql (300K tokens)` | **64.1** | 66.2 ± 4.3 | 6.4% | 13.6M | 15.7M | 1.5 | 72.0 | 73.3 | 63.7 | 73.7 | 300K | — |
| 33 | `5f. Quack: SQL Builders + URI Normalize + Template (100K ops)` | **126** | 126 ± 0.7 | 0.5% | 7.9M | 8.0M | 1.0 | 127 | 127 | 125 | 127 | 100K | — |
| 34 | `5g. Reflection DDL: create_table_sql + v2_quote_identifier (100K)` | **327** | 330 ± 5.6 | 1.7% | 2.9M | 3.1M | 1.4 | 337 | 339 | 326 | 340 | 100K | — |

#### 2.3 Multi-Microsecond Point Lookups, Catalog, VFS & Transactions (`≥ 1 µs` · `2K–360K ops/s`, 13 tests)

| # | Benchmark | Med (`µs`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops | Bandwidth |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | `1a. Ingest: V2 Prepared Statement Loop (2K rows)` | **231.9** | 231.8 ± 2.57 | 1.1% | 4.3K | 4.4K | 3.75 | 234.8 | 235.0 | 228.9 | 235.1 | 2K | 0.2 MB/s |
| 27 | `4e. Composite Values: VARIANT/MAP/UNION/DECIMAL (10K ops)` | **5.83** | 5.85 ± 0.09 | 1.5% | 167K | 173K | 0.05 | 5.97 | 6.00 | 5.79 | 6.00 | 10K | — |
| 29 | `5b. Codegen: introspect_table_schema + Odin/CUE (1K tables)` | **7.52** | 7.56 ± 0.10 | 1.4% | 129K | 134K | 0.09 | 7.70 | 7.72 | 7.46 | 7.73 | 1K | — |
| 32 | `5e. Catalog: duckdb_v2_connection_describe_table (5K lookups)` | **4.77** | 4.81 ± 0.08 | 1.7% | 202K | 210K | 0.03 | 4.93 | 4.95 | 4.76 | 4.96 | 5K | — |
| 40 | `6f. UDF: V2_Replacement_Scan Virtual Table Scan (1K queries)` | **416.5** | 419.3 ± 8.24 | 2.0% | 2.3K | 2.4K | 6.21 | 429.7 | 431.1 | 409.5 | 431.5 | 1K | — |
| 41 | `6g. Extensibility: V2_Pragma + V2_Custom_Option + V2_Macro (1K)` | **111.5** | 112.3 ± 2.41 | 2.1% | 8.6K | 9.1K | 1.21 | 115.6 | 116.3 | 110.3 | 116.4 | 1K | — |
| 42 | `7a. Point Lookup: Ad-Hoc v2_query Parse+Bind+Exec (1K queries)` | **366.8** | 369.6 ± 7.54 | 2.0% | 2.6K | 2.8K | 2.30 | 379.8 | 381.9 | 362.9 | 382.5 | 1K | — |
| 43 | `7b. Point Lookup: Pre-Compiled v2_prepared_execute (1K queries)` | **318.6** | 318.9 ± 4.08 | 1.3% | 3.1K | 3.2K | 3.27 | 324.3 | 325.3 | 315.5 | 325.6 | 1K | — |
| 44 | `7c. DSL Pipeline: query_execute_as Build+Bind+Unmarshal (1K)` | **658.2** | 659.5 ± 6.78 | 1.0% | 1.50K | 1.53K | 11.4 | 667.2 | 667.6 | 652.5 | 667.7 | 1K | 0.1 MB/s |
| 45 | `7d. Transactions: v2_with_transaction Commit + Rollback (1K tx)` | **216.5** | 216.8 ± 2.50 | 1.2% | 4.5K | 4.7K | 3.00 | 219.9 | 220.3 | 214.2 | 220.5 | 1K | — |
| 46 | `7e. Prepared DSL: prepared_query_execute_as Cached Plan+Schema (1K)` | **555.0** | 555.3 ± 3.69 | 0.7% | 1.78K | 1.82K | 1.44 | 560.0 | 560.9 | 551.0 | 561.1 | 1K | 0.1 MB/s |
| 47 | `8a. VFS: Positional write_at + read_at (1K x 64 KB = 64 MB)` | **3.79** | 3.80 ± 0.03 | 0.7% | 260K | 265K | 0.03 | 3.84 | 3.84 | 3.77 | 3.84 | 1K | 16.1 GB/s |
| 48 | `8b. Telemetry: V2_Query_Metrics Tree + V2_Log_Sink (10K ops)` | **16.6** | 16.6 ± 0.09 | 0.5% | 60.0K | 60.8K | 0.05 | 16.7 | 16.7 | 16.4 | 16.7 | 10K | — |
<!-- END_BENCHMARK_TABLE -->
