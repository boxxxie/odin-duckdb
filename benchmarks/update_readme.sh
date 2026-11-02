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

PLAN_JSON="$("${SCRIPT_DIR}/compare_1v1.py" --plan-json 2>/dev/null || echo '{}')"

TABLES=$(jq -rn --arg target_commit "${TARGET_COMMIT}" --argjson plan "${PLAN_JSON}" '
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

def fmt_ops_bounds($min_ns; $max_ns):
  (1e9 / ([$max_ns, 0.001] | max)) as $lo_ops |
  (1e9 / ([$min_ns, 0.001] | max)) as $hi_ops |
  fmt_si1($lo_ops) as $lo1 |
  fmt_si1($hi_ops) as $hi1 |
  if ($min_ns - $max_ns | fabs) < 1e-6 then
    [$lo1, $hi1]
  elif $lo1 != $hi1 then
    [$lo1, $hi1]
  else
    fmt_si2($lo_ops) as $lo2 |
    fmt_si2($hi_ops) as $hi2 |
    if $lo2 != $hi2 then [$lo2, $hi2] else [$lo1, $hi1] end
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

def welch_se($a; $b):
  ((($a.variance_ns2 / ([$a.runs, 1] | max)) + ($b.variance_ns2 / ([$b.runs, 1] | max))) | sqrt);

def welch_z($a; $b):
  welch_se($a; $b) as $se |
  if $se < 1e-6 then
    (if (($a.mean_ns - $b.mean_ns) | fabs) >= 0.05 then 99.0 else 0.0 end)
  else
    (($a.mean_ns - $b.mean_ns) | fabs) / $se
  end;

def welch_med_z($a; $b):
  welch_se($a; $b) as $se |
  if $se < 1e-6 then
    (if (($a.median_ns - $b.median_ns) | fabs) >= 0.05 then 99.0 else 0.0 end)
  else
    (($a.median_ns - $b.median_ns) | fabs) / $se
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

# Builds a complete 48-benchmark snapshot up to $target_sha (or latest if empty),
# taking each test from its most recent commit <= $target_sha so selective runs
# preserve untouched benchmarks while highlighting newly updated ones.
def latest_snapshot_for_lang($all; $lang; $target_sha):
  distinct_commits($all; $lang) as $commits |
  (if $target_sha != "" then
    ($commits | map(select(startswith($target_sha))) | last // $target_sha)
   else
    ($commits | last // "unknown")
   end) as $resolved_sha |
  (($commits | index($resolved_sha)) // (($commits | length) - 1)) as $max_idx |
  ($commits[0:($max_idx + 1)]) as $allowed_commits |
  ($all | map(select((.lang // "odin") == $lang and ((.commit // "unknown") as $rc | ($allowed_commits | index($rc)) != null)))) as $filtered |
  ($filtered | group_by(.name) | map(
    (. | last.commit) as $latest_c |
    (. | map(select(.commit == $latest_c))) | pool_records(.)
  ) | sort_by(.rank));

# For every benchmark updated in $target_sha, finds its immediate prior pooled record from commits < $target_sha
def baseline_before_commit($all; $lang; $target_sha):
  distinct_commits($all; $lang) as $commits |
  (($commits | index($target_sha)) // (($commits | length) - 1)) as $idx |
  (if $idx > 0 then $commits[0:$idx] else [] end) as $prior_commits |
  ($all | map(select((.lang // "odin") == $lang and ((.commit // "unknown") as $rc | ($prior_commits | index($rc)) != null)))) as $filtered |
  ($filtered | group_by(.name) | map(
    (. | last.commit) as $latest_c |
    (. | map(select(.commit == $latest_c))) | pool_records(.)
  ) | sort_by(.rank));

def rank_cell($r; $target_sha; $has_selective):
  if $has_selective and ($r.commit == $target_sha) then
    "**\($r.rank)**\u00a0↻"
  else
    "\($r.rank)"
  end;

def tier_table_ns($list; $target_sha; $has_selective):
  "| # | Benchmark | Med\u00a0(`ns`) | Mean\u00a0±\u00a0σ | CV | Min\u00a0`ops/s` | Max\u00a0`ops/s` | IQR | `p95` | `p99` | Min | Max | Ops | Bandwidth |",
  "| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  ($list[] | . as $r | fmt_ops_bounds(.min_ns; .max_ns) as $ops_b |
    "| \(rank_cell($r; $target_sha; $has_selective)) | `\(.name | gsub("`"; "") | nbsp)` | **\(fmt_ns_val(.median_ns))** | \(fmt_ns_val(.mean_ns))\u00a0±\u00a0\(fmt_sigma(.stddev_ns)) | \(fmt_dec1(.cv_pct))% | \($ops_b[0]) | \($ops_b[1]) | \(fmt_ns_val(.iqr_ns)) | \(fmt_ns_val(.p95_ns)) | \(fmt_ns_val(.p99_ns)) | \(fmt_ns_val(.min_ns)) | \(fmt_ns_val(.max_ns)) | \(fmt_ops_count(.ops)) | \(fmt_bw(.mb_per_sec; .bytes_row)) |"
  );

def tier_table_us($list; $target_sha; $has_selective):
  "| # | Benchmark | Med\u00a0(`µs`) | Mean\u00a0±\u00a0σ | CV | Min\u00a0`ops/s` | Max\u00a0`ops/s` | IQR | `p95` | `p99` | Min | Max | Ops | Bandwidth |",
  "| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  ($list[] | . as $r | fmt_ops_bounds(.min_ns; .max_ns) as $ops_b |
    "| \(rank_cell($r; $target_sha; $has_selective)) | `\(.name | gsub("`"; "") | nbsp)` | **\(fmt_us(.median_ns))** | \(fmt_us(.mean_ns))\u00a0±\u00a0\(fmt_us(.stddev_ns)) | \(fmt_dec1(.cv_pct))% | \($ops_b[0]) | \($ops_b[1]) | \(fmt_us(.iqr_ns)) | \(fmt_us(.p95_ns)) | \(fmt_us(.p99_ns)) | \(fmt_us(.min_ns)) | \(fmt_us(.max_ns)) | \(fmt_ops_count(.ops)) | \(fmt_bw(.mb_per_sec; .bytes_row)) |"
  );

def single_lang_section($sec_num; $lang_label; $flags; $sha; $list):
  ($list | map(select(.commit == $sha)) | length) as $updated_cnt |
  ($list | length) as $total_cnt |
  (($updated_cnt > 0) and ($updated_cnt < $total_cnt)) as $has_selective |
  ($list | map(select(.commit == $sha))[0] // $list[0]) as $sample_rec |
  ($list | map(select(.median_ns < 50.0))) as $fast |
  ($list | map(select(.median_ns >= 50.0 and .median_ns < 1000.0))) as $mid |
  ($list | map(select(.median_ns >= 1000.0))) as $heavy |
  "### \($sec_num). \($lang_label) Results (`\($flags)`, Commit `\($sha)`, \($sample_rec.runs) samples across \($sample_rec.invocations) run(s))\n",
  (if $has_selective then
    "> **Selective update (`\($sha[0:7])`):** Re-ran **\($updated_cnt) / \($total_cnt)** affected benchmarks (marked with **↻** in `#`); remaining \($total_cnt - $updated_cnt) benchmarks retain their latest verified baseline.\n"
   else empty end),
  "#### \($sec_num).1 Vectorized Zero-Copy Scans, UDFs & Wire Codecs (`< 50 ns` · `20M–160B ops/s`, \($fast | length) tests)\n",
  tier_table_ns($fast; $sha; $has_selective),
  "\n#### \($sec_num).2 Sub-Microsecond Reflection Ingest, Unmarshaling & DSL Compilation (`50–999 ns` · `1M–20M ops/s`, \($mid | length) tests)\n",
  tier_table_ns($mid; $sha; $has_selective),
  "\n#### \($sec_num).3 Multi-Microsecond Point Lookups, Catalog, VFS & Transactions (`≥ 1 µs` · `2K–360K ops/s`, \($heavy | length) tests)\n",
  tier_table_us($heavy; $sha; $has_selective);

def progression_table($rows; $prev_sha; $curr_sha; $unit):
  "| # | Benchmark | Verdict | Delta | Speedup | Base\u00a0`\($prev_sha[0:7])`\u00a0(`\($unit)`) | Curr\u00a0`\($curr_sha[0:7])`\u00a0(`\($unit)`) | Welch\u00a0$z$ | Base\u00a0Mean\u00a0±\u00a0σ | Curr\u00a0Mean\u00a0±\u00a0σ |",
  "| ---: | :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  ($rows[] |
    .curr as $curr | .base as $base |
    ([$base.median_ns, 0.01] | max) as $med_a |
    ([$curr.median_ns, 0.01] | max) as $med_b |
    ((($med_b - $med_a) / $med_a) * 100.0) as $delta_pct |
    welch_z($base; $curr) as $wz |
    welch_med_z($base; $curr) as $med_z |
    (if ([$med_a, $med_b] | max) < 50.0 then 0.5 else 5.0 end) as $abs_thresh |
    (($wz >= 2.58) and ($med_z >= 2.58) and (($delta_pct | fabs) >= 10.0) and ((($med_b - $med_a) | fabs) >= $abs_thresh)) as $is_sig |
    (if ($is_sig and ($med_b < $med_a)) then "**FASTER**"
     elif ($is_sig and ($med_b > $med_a)) then "**REGRESSION**"
     else "`~NOISE`" end) as $verdict |
    (if $delta_pct >= 0 then "+\(fmt_dec1($delta_pct))%" else "\(fmt_dec1($delta_pct))%" end) as $delta_str |
    (if $unit == "µs" then fmt_us($base.median_ns) else fmt_ns_val($base.median_ns) end) as $b_med |
    (if $unit == "µs" then fmt_us($curr.median_ns) else fmt_ns_val($curr.median_ns) end) as $c_med |
    (if $unit == "µs" then "\(fmt_us($base.mean_ns))\u00a0±\u00a0\(fmt_us($base.stddev_ns))" else "\(fmt_ns_val($base.mean_ns))\u00a0±\u00a0\(fmt_sigma($base.stddev_ns))" end) as $b_msd |
    (if $unit == "µs" then "\(fmt_us($curr.mean_ns))\u00a0±\u00a0\(fmt_us($curr.stddev_ns))" else "\(fmt_ns_val($curr.mean_ns))\u00a0±\u00a0\(fmt_sigma($curr.stddev_ns))" end) as $c_msd |
    "| \($curr.rank) | `\($curr.name | gsub("`"; "") | nbsp)` | \($verdict) | `\($delta_str)` | \(fmt_speedup($curr.median_ns; $base.median_ns)) | \($b_med) | **\($c_med)** | `\(fmt_dec1($wz))` | \($b_msd) | \($c_msd) |"
  );

[inputs] as $all |
distinct_commits($all; "odin") as $odin_commits |
(if $target_commit != "" then
  ($odin_commits | map(select(startswith($target_commit))) | last // $target_commit)
 else
  ($odin_commits | last // "unknown")
 end) as $odin_sha |
latest_snapshot_for_lang($all; "odin"; $odin_sha) as $odin_list |

(if ($odin_commits | length) >= 2 then
  baseline_before_commit($all; "odin"; $odin_sha) as $prev_list |
  (reduce $prev_list[] as $p ({}; .[$p.name] = $p)) as $prev_map |
  ([ $odin_list[] | select(.commit == $odin_sha and $prev_map[.name] != null) | {curr: ., base: $prev_map[.name]} ]) as $prog_rows |
  (if ($prog_rows | length) > 0 then ($prog_rows[0].base.commit) else ($odin_commits[-2]) end) as $prev_sha |
  ($prog_rows | map(select(.curr.median_ns < 50.0))) as $prog_fast |
  ($prog_rows | map(select(.curr.median_ns >= 50.0 and .curr.median_ns < 1000.0))) as $prog_mid |
  ($prog_rows | map(select(.curr.median_ns >= 1000.0))) as $prog_heavy |
  "### 1. Latest Code-Change Impact & Affected Benchmarks (`\($prev_sha)` → `\($odin_sha)`)\n",
  (if ($plan.changed_files // [] | length) > 0 then
    ([ $plan.reasons[]? | "`\(.file)` (`\(.procs)`)" ] | join(", ")) as $files_summary |
    (($plan.groups // []) | join(",")) as $grp_str |
    (($plan.filters // []) | join("|")) as $flt_str |
    (if ($plan.is_full_suite // false) then
      "`FULL SUITE` (\($prog_rows | length) / \($odin_list | length) benchmarks re-run)"
     else
      "`--groups \($grp_str)`" +
      (if ($flt_str | length) > 0 then " `--filter \"\($flt_str)\"`" else "" end) +
      " (\($prog_rows | length) / \($odin_list | length) benchmarks re-run)"
     end) as $scope_summary |
    "> **Inspected Diff:** `\($plan.diff_desc // "HEAD~1..HEAD")`  \n" +
    "> **Changed Code:** \($files_summary)  \n" +
    "> **Mapped Benchmark Scope:** \($scope_summary)\n"
   else
    "> **Benchmark Scope:** `\($prev_sha)` → `\($odin_sha)` (\($prog_rows | length) / \($odin_list | length) benchmarks compared)\n"
   end),
  (if ($prog_fast | length) > 0 then
    "#### 1.1 Vectorized Zero-Copy Scans, UDFs & Wire Codecs (`ns`, \($prog_fast | length) tests)\n",
    progression_table($prog_fast; $prev_sha; $odin_sha; "ns"),
    "\n"
   else empty end),
  (if ($prog_mid | length) > 0 then
    "#### 1.2 Sub-Microsecond Reflection Ingest, Unmarshaling & DSL Compilation (`ns`, \($prog_mid | length) tests)\n",
    progression_table($prog_mid; $prev_sha; $odin_sha; "ns"),
    "\n"
   else empty end),
  (if ($prog_heavy | length) > 0 then
    "#### 1.3 Multi-Microsecond Point Lookups, Catalog, VFS & Transactions (`µs`, \($prog_heavy | length) tests)\n",
    progression_table($prog_heavy; $prev_sha; $odin_sha; "µs"),
    "\n"
   else empty end)
 else empty end),
single_lang_section((if ($odin_commits | length) >= 2 then "2" else "1" end); "Odin Full Suite"; "-o:speed -microarch:native"; $odin_sha; $odin_list)
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
