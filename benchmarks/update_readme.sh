#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ODIN_JSONL="${SCRIPT_DIR}/odin.jsonl"
HISTORY_JSONL="${SCRIPT_DIR}/history.jsonl"
BENCH_README="${SCRIPT_DIR}/README.md"
ROOT_README="${ROOT_DIR}/README.md"
TARGET_COMMIT="${1:-}"

INPUT_FILES=()
if [[ -f "${HISTORY_JSONL}" ]]; then
    INPUT_FILES+=("${HISTORY_JSONL}")
fi
if [[ -f "${ODIN_JSONL}" ]]; then
    INPUT_FILES+=("${ODIN_JSONL}")
fi

if [[ ${#INPUT_FILES[@]} -eq 0 ]]; then
    echo "Error: Neither ${ODIN_JSONL} nor ${HISTORY_JSONL} found. Run 'odin run benchmarks -o:speed' first." >&2
    exit 1
fi

TABLES=$(jq -rn --arg target_commit "${TARGET_COMMIT}" '
def commify:
  tostring |
  if test("^-?[0-9]+$") then
    (if startswith("-") then "-" else "" end) as $sign |
    (ltrimstr("-") | [splits("") | select(. != "")] | reverse) as $digits |
    $sign + ([range(0; $digits | length) |
      $digits[.] + (if . > 0 and (. % 3 == 0) then "," else "" end)
    ] | reverse | join(""))
  else . end;

def nbsp:
  gsub(" "; "\u00a0");

def fmt_dec1($v):
  (($v * 10 | round) / 10 | tostring) as $s |
  if ($s | test("\\.")) then $s else $s + ".0" end;

def fmt_dec2($v):
  (($v * 100 | round) / 100 | tostring) as $s |
  if ($s | test("\\.")) then
    ($s | split(".")) as $parts |
    $parts[0] + "." + (if ($parts[1] | length) == 1 then $parts[1] + "0" else $parts[1] end)
  else
    $s + ".00"
  end;

def fmt_ns_val($v):
  if $v >= 100 then ($v | round | commify)
  else fmt_dec1($v)
  end;

def fmt_sigma($v):
  if $v >= 100 then ($v | round | commify) else fmt_dec1($v) end;

def fmt_us($ns):
  ($ns / 1000.0) as $us |
  if $us >= 10.0 then fmt_dec1($us)
  else fmt_dec2($us)
  end;

def fmt_ops_count($n):
  if $n >= 1000000 and ($n % 1000000 == 0) then (($n / 1000000 | tostring) + "M")
  elif $n >= 1000 and ($n % 1000 == 0) then (($n / 1000 | tostring) + "K")
  else ($n | commify)
  end;

def fmt_si1($v):
  if $v >= 1e9 then (fmt_dec1($v / 1e9) + "B")
  elif $v >= 1e8 then (($v / 1e6 | round | tostring) + "M")
  elif $v >= 1e6 then (fmt_dec1($v / 1e6) + "M")
  elif $v >= 1e5 then (($v / 1e3 | round | tostring) + "K")
  elif $v >= 1e3 then (fmt_dec1($v / 1e3) + "K")
  else ($v | round | tostring)
  end;

def fmt_si2($v):
  if $v >= 1e9 then (fmt_dec2($v / 1e9) + "B")
  elif $v >= 1e8 then (fmt_dec1($v / 1e6) + "M")
  elif $v >= 1e6 then (fmt_dec2($v / 1e6) + "M")
  elif $v >= 1e5 then (fmt_dec1($v / 1e3) + "K")
  elif $v >= 1e3 then (fmt_dec2($v / 1e3) + "K")
  else ($v | round | tostring)
  end;

def fmt_ops_range($min_ns; $max_ns):
  (1e9 / ([$max_ns, 0.001] | max)) as $lo_ops |
  (1e9 / ([$min_ns, 0.001] | max)) as $hi_ops |
  fmt_si1($lo_ops) as $lo1 |
  fmt_si1($hi_ops) as $hi1 |
  if ($min_ns - $max_ns | fabs) < 1e-6 then
    $lo1
  elif $lo1 != $hi1 then
    "\($lo1)–\($hi1)"
  else
    fmt_si2($lo_ops) as $lo2 |
    fmt_si2($hi_ops) as $hi2 |
    if $lo2 != $hi2 then "\($lo2)–\($hi2)" else $lo1 end
  end;

def fmt_bw($mb_s; $bytes_row):
  if $bytes_row > 0 then
    if $mb_s >= 10240.0 then (fmt_dec1($mb_s / 1024.0) + "\u00a0GB/s")
    else (fmt_dec1($mb_s) + "\u00a0MB/s")
    end
  else
    "—"
  end;

def fmt_speedup($a; $b):
  (($b / ([$a, 0.01] | max)) * 100 | round) as $pct |
  (($pct / 100 | floor | tostring) + "." + (($pct % 100) | tostring | if length == 1 then "0" + . else . end) + "x");

def percentile($sorted; $p):
  ($sorted | length) as $n |
  if $n == 0 then 0
  elif $n == 1 then $sorted[0]
  else
    ($p * ($n - 1)) as $pos |
    ($pos | floor) as $lo |
    ([$lo + 1, $n - 1] | min) as $hi |
    ($pos - $lo) as $frac |
    $sorted[$lo] + $frac * ($sorted[$hi] - $sorted[$lo])
  end;

def welch_z($a; $b):
  ((($a.variance_ns2 / ([$a.runs, 1] | max)) + ($b.variance_ns2 / ([$b.runs, 1] | max))) | sqrt) as $se |
  if $se < 1e-6 then
    (if (($a.mean_ns - $b.mean_ns) | fabs) >= 0.05 then 99.0 else 0.0 end)
  else
    (($a.mean_ns - $b.mean_ns) | fabs) / $se
  end;

def pool_records($recs):
  ($recs | unique_by(.run_id // "run-0")) as $uniq_recs |
  ($uniq_recs[0]) as $first |
  ($first.ops // $first.rows // 1) as $ops |
  ($first.bytes_row // 0) as $bytes_row |
  ([ $uniq_recs[] |
     if (.samples_ns | type) == "array" and (.samples_ns | length) > 0 then .samples_ns[]
     elif .ns_per_item != null then .ns_per_item
     else (.ns_per_op // 0)
     end
  ]) as $samples |
  ($samples | sort) as $sorted |
  ($sorted | length) as $n |
  percentile($sorted; 0.50) as $med |
  percentile($sorted; 0.25) as $q1 |
  percentile($sorted; 0.75) as $q3 |
  ($q3 - $q1) as $iqr |
  percentile($sorted; 0.95) as $p95 |
  percentile($sorted; 0.99) as $p99 |
  (($sorted | add) / ([$n, 1] | max)) as $mean |
  (if $n > 1 then ([ $sorted[] | (. - $mean) * (. - $mean) ] | add) / ($n - 1) else 0 end) as $var |
  ($var | sqrt) as $sd |
  (($sd / ([$mean, 1e-9] | max)) * 100.0) as $cv |
  ($sorted[0] // 0) as $min_ns |
  ($sorted[$n - 1] // 0) as $max_ns |
  (($med * ([$ops, 1] | max)) / 1e6) as $total_ms |
  (($ops * 1e9) / ([($med * ([$ops, 1] | max)), 1.0] | max)) as $ops_sec |
  (($ops_sec * $bytes_row) / (1024.0 * 1024.0)) as $mb_sec |
  {
    rank: $first.rank,
    lang: ($first.lang // "odin"),
    commit: ($first.commit // "unknown"),
    invocations: ($uniq_recs | length),
    name: $first.name,
    ops: $ops,
    runs: $n,
    total_ms: $total_ms,
    ns_per_op: $med,
    median_ns: $med,
    mean_ns: $mean,
    stddev_ns: $sd,
    variance_ns2: $var,
    cv_pct: $cv,
    iqr_ns: $iqr,
    p95_ns: $p95,
    p99_ns: $p99,
    min_ns: $min_ns,
    max_ns: $max_ns,
    ops_per_sec: $ops_sec,
    mb_per_sec: $mb_sec,
    bytes_row: $bytes_row,
    bytes_used: ([ $uniq_recs[] | (.bytes_used // ($ops * $bytes_row)) ] | max)
  };

def distinct_commits($all; $lang):
  reduce ($all[] | select((.lang // "odin") == $lang and (.commit // "unknown") != "unknown") | .commit) as $c (
    [];
    if (index($c) == null) then . + [$c] else . end
  );

def filter_and_pool_commit($all; $lang; $sha):
  ($all | map(select((.lang // "odin") == $lang and ((.commit // "unknown") | startswith($sha))))) as $filtered |
  ($filtered | group_by(.name) | map(pool_records(.)) | sort_by(.rank));

def tier_table_ns($list):
  "| # | Benchmark | Ops | Med\u00a0(`ns`) | Mean\u00a0±\u00a0σ | CV | IQR | `p95` | `p99` | Min | Max | `ops/s` | Bandwidth |",
  "| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  ($list[] |
    "| \(.rank) | `\(.name | gsub("`"; "") | nbsp)` | \(fmt_ops_count(.ops)) | **\(fmt_ns_val(.median_ns))** | \(fmt_ns_val(.mean_ns))\u00a0±\u00a0\(fmt_sigma(.stddev_ns)) | \(fmt_dec1(.cv_pct))% | \(fmt_ns_val(.iqr_ns)) | \(fmt_ns_val(.p95_ns)) | \(fmt_ns_val(.p99_ns)) | \(fmt_ns_val(.min_ns)) | \(fmt_ns_val(.max_ns)) | \(fmt_ops_range(.min_ns; .max_ns)) | \(fmt_bw(.mb_per_sec; .bytes_row)) |"
  );

def tier_table_us($list):
  "| # | Benchmark | Ops | Med\u00a0(`µs`) | Mean\u00a0±\u00a0σ | CV | IQR | `p95` | `p99` | Min | Max | `ops/s` | Bandwidth |",
  "| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  ($list[] |
    "| \(.rank) | `\(.name | gsub("`"; "") | nbsp)` | \(fmt_ops_count(.ops)) | **\(fmt_us(.median_ns))** | \(fmt_us(.mean_ns))\u00a0±\u00a0\(fmt_us(.stddev_ns)) | \(fmt_dec1(.cv_pct))% | \(fmt_us(.iqr_ns)) | \(fmt_us(.p95_ns)) | \(fmt_us(.p99_ns)) | \(fmt_us(.min_ns)) | \(fmt_us(.max_ns)) | \(fmt_ops_range(.min_ns; .max_ns)) | \(fmt_bw(.mb_per_sec; .bytes_row)) |"
  );

def single_lang_section($sec_num; $lang_label; $flags; $sha; $list):
  ($list | map(select(.median_ns < 50.0))) as $fast |
  ($list | map(select(.median_ns >= 50.0 and .median_ns < 1000.0))) as $mid |
  ($list | map(select(.median_ns >= 1000.0))) as $heavy |
  "### \($sec_num). \($lang_label) Results (`\($flags)`, Commit `\($sha)`, \($list[0].runs) samples across \($list[0].invocations) run(s))\n",
  "#### \($sec_num).1 Vectorized Zero-Copy Scans, UDFs & Wire Codecs (`< 50 ns` · `20M–160B ops/s`, \($fast | length) tests)\n",
  tier_table_ns($fast),
  "\n#### \($sec_num).2 Sub-Microsecond Reflection Ingest, Unmarshaling & DSL Compilation (`50–999 ns` · `1M–20M ops/s`, \($mid | length) tests)\n",
  tier_table_ns($mid),
  "\n#### \($sec_num).3 Multi-Microsecond Point Lookups, Catalog, VFS & Transactions (`≥ 1 µs` · `2K–360K ops/s`, \($heavy | length) tests)\n",
  tier_table_us($heavy);

[inputs] as $all |
distinct_commits($all; "odin") as $odin_commits |
(if $target_commit != "" then $target_commit else ($odin_commits | last // "unknown") end) as $odin_target |
filter_and_pool_commit($all; "odin"; $odin_target) as $odin_list |
($odin_list[0].commit // "unknown") as $odin_sha |

single_lang_section("1"; "Odin"; "-o:speed -microarch:native"; $odin_sha; $odin_list),
(if ($odin_commits | length) >= 2 then
  ($odin_commits[-2]) as $prev_sha |
  filter_and_pool_commit($all; "odin"; $prev_sha) as $prev_list |
  (reduce $prev_list[] as $p ({}; .[$p.name] = $p)) as $prev_map |
  "\n### 2. Commit-vs-Commit Progression (`\($prev_sha)` → `\($odin_sha)`, Odin)\n",
  "| # | Benchmark | Baseline\u00a0`\($prev_sha[0:7])`\u00a0(`Med\u00a0±\u00a0σ`) | Current\u00a0`\($odin_sha[0:7])`\u00a0(`Med\u00a0±\u00a0σ`) | Delta\u00a0(%) | Speedup | Welch\u00a0$z$ | Verdict |",
  "| ---: | :--- | ---: | ---: | ---: | ---: | ---: | :--- |",
  ($odin_list[] | select($prev_map[.name] != null) | . as $curr | $prev_map[$curr.name] as $base |
    ([$base.median_ns, 0.01] | max) as $med_a |
    ([$curr.median_ns, 0.01] | max) as $med_b |
    ((($med_b - $med_a) / $med_a) * 100.0) as $delta_pct |
    welch_z($base; $curr) as $wz |
    (($wz >= 1.96) and (($delta_pct | fabs) >= 3.0) and ((($med_b - $med_a) | fabs) >= 0.2)) as $is_sig |
    (if ($is_sig and ($med_b < $med_a)) then "**FASTER**"
     elif ($is_sig and ($med_b > $med_a)) then "**REGRESSION**"
     else "`~NOISE`" end) as $verdict |
    (if $delta_pct >= 0 then "+\(fmt_dec1($delta_pct))%" else "\(fmt_dec1($delta_pct))%" end) as $delta_str |
    "| \($curr.rank) | `\($curr.name | gsub("`"; "") | nbsp)` | \(fmt_ns_val($base.median_ns))\u00a0±\u00a0\(fmt_sigma($base.stddev_ns)) | **\(fmt_ns_val($curr.median_ns))**\u00a0±\u00a0\(fmt_sigma($curr.stddev_ns)) | `\($delta_str)` | \(fmt_speedup($curr.median_ns; $base.median_ns)) | `\(fmt_dec1($wz))` | \($verdict) |"
  )
 else empty end)
' "${INPUT_FILES[@]}")

AWK_SCRIPT='
BEGIN { in_block = 0 }
/<!-- BEGIN_BENCHMARK_TABLE -->/ {
    print
    print tables
    in_block = 1
    next
}
/<!-- END_BENCHMARK_TABLE -->/ {
    in_block = 0
}
!in_block { print }
'

for md_file in "${BENCH_README}" "${ROOT_README}"; do
    if [[ -f "${md_file}" ]] && grep -q "<!-- BEGIN_BENCHMARK_TABLE -->" "${md_file}"; then
        awk -v tables="${TABLES}" "${AWK_SCRIPT}" "${md_file}" > "${md_file}.tmp"
        mv "${md_file}.tmp" "${md_file}"
        echo "Updated ${md_file} with full statistical tables."
    fi
done
