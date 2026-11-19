-- ============================================================================
-- DuckDB-on-Parquet Analytics over `hugi` Benchmark History
-- ============================================================================
-- Export history first:
--   hugi export --db benchmarks/history.hugidb --all-commits --out .tmp/history.parquet
-- Run this script:
--   duckdb -markdown -light-mode -f benchmarks/query_hugidb.sql
-- ============================================================================

-- 1. Latency-Tiered Bandwidth & Throughput Summary (Latest Snapshot per Benchmark)
WITH indexed AS (
    SELECT *, ROW_NUMBER() OVER () AS row_ord
    FROM read_parquet('.tmp/history.parquet')
    WHERE lang = 'odin'
),
latest_snapshot AS (
    SELECT *
    FROM indexed
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY full_name
        ORDER BY timestamp_unix DESC, row_ord DESC
    ) = 1
),
tiered AS (
    SELECT
        CASE
            WHEN p50_ns < 50.0 THEN 1
            WHEN p50_ns < 1000.0 THEN 2
            ELSE 3
        END AS tier_id,
        CASE
            WHEN p50_ns < 50.0 THEN '1. Fast (< 50 ns)'
            WHEN p50_ns < 1000.0 THEN '2. Sub-us (50-999 ns)'
            ELSE '3. Multi-us (>= 1 us)'
        END AS latency_tier,
        *
    FROM latest_snapshot
)
SELECT
    latency_tier,
    COUNT(*) AS tests,
    ROUND(MIN(p50_ns)::DOUBLE, 2) AS min_p50_ns,
    ROUND(MEDIAN(p50_ns)::DOUBLE, 2) AS med_p50_ns,
    ROUND(MAX(p50_ns)::DOUBLE, 2) AS max_p50_ns,
    ROUND(MEDIAN(cv_pct), 2) AS med_cv_pct,
    PRINTF('%.2fM', MAX(ops_per_sec) / 1e6) AS peak_ops_s,
    ROUND(AVG(CASE WHEN bytes_per_op > 0 THEN mb_per_sec / 1024.0 END), 2) AS avg_gb_s,
    ROUND(MAX(CASE WHEN bytes_per_op > 0 THEN mb_per_sec / 1024.0 END), 2) AS peak_gb_s
FROM tiered
GROUP BY tier_id, latency_tier
ORDER BY tier_id;

-- 2. Top Bandwidth Benchmarks by Latency Tier (Latest Snapshot)
WITH indexed AS (
    SELECT *, ROW_NUMBER() OVER () AS row_ord
    FROM read_parquet('.tmp/history.parquet')
    WHERE lang = 'odin'
),
latest_snapshot AS (
    SELECT *
    FROM indexed
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY full_name
        ORDER BY timestamp_unix DESC, row_ord DESC
    ) = 1
)
SELECT
    rank,
    CASE
        WHEN p50_ns < 50.0 THEN '< 50 ns'
        WHEN p50_ns < 1000.0 THEN '50-999 ns'
        ELSE '>= 1 us'
    END AS tier,
    name,
    ROUND(p50_ns::DOUBLE, 2) AS p50_ns,
    ROUND(p95_ns::DOUBLE, 2) AS p95_ns,
    ROUND(cv_pct, 1) AS cv_pct,
    CASE
        WHEN mb_per_sec >= 10240.0 THEN PRINTF('%.1f GB/s', mb_per_sec / 1024.0)
        ELSE PRINTF('%.1f MB/s', mb_per_sec)
    END AS bandwidth
FROM latest_snapshot
WHERE bytes_per_op > 0
ORDER BY mb_per_sec DESC
LIMIT 12;

-- 3. Historical Commit Trend & Geometric-Mean Latency Progression
WITH indexed AS (
    SELECT *, ROW_NUMBER() OVER () AS row_ord
    FROM read_parquet('.tmp/history.parquet')
),
commit_agg AS (
    SELECT
        commit,
        lang,
        MIN(row_ord) AS first_ord,
        MIN(timestamp_unix) AS ts_unix,
        COUNT(*) AS benchmarks,
        MAX(run_count) AS runs_per_bench,
        SUM(samples) AS total_samples,
        EXP(AVG(LN(GREATEST(p50_ns::DOUBLE, 0.001)))) AS geomean_p50_ns,
        MEDIAN(cv_pct) AS median_cv_pct,
        MAX(mb_per_sec) / 1024.0 AS peak_gb_s
    FROM indexed
    GROUP BY commit, lang
)
SELECT
    commit,
    lang,
    benchmarks,
    runs_per_bench,
    total_samples,
    ROUND(geomean_p50_ns, 3) AS geomean_p50_ns,
    ROUND(median_cv_pct, 2) AS median_cv_pct,
    ROUND(peak_gb_s, 2) AS peak_gb_s,
    ROUND(
        ((geomean_p50_ns / NULLIF(LAG(geomean_p50_ns) OVER (PARTITION BY lang ORDER BY ts_unix, first_ord), 0.0)) - 1.0) * 100.0,
        2
    ) AS geomean_delta_pct
FROM commit_agg
ORDER BY ts_unix, first_ord;
