#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
JSONL_FILE="${SCRIPT_DIR}/history.jsonl"
BENCH_README="${SCRIPT_DIR}/README.md"
ROOT_README="${ROOT_DIR}/README.md"

if [[ ! -f "${JSONL_FILE}" ]]; then
    echo "Error: ${JSONL_FILE} not found. Run 'odin run benchmarks -o:speed' first." >&2
    exit 1
fi

TABLE=$(jq -rn '
def fmt_dec($val; $digits):
  (pow(10; $digits)) as $scale |
  (($val * $scale | round) / $scale | tostring) as $s |
  if ($digits == 0) then $s
  elif ($s | test("\\.")) then
    ($s | split(".")) as $parts |
    $parts[0] + "." + ($parts[1] + ("0" * ($digits - ($parts[1] | length))))
  else
    $s + "." + ("0" * $digits)
  end;

"| # | Benchmark | Items / Op | Median Time | Min Time | Throughput (ops/s) | Bandwidth (MB/s) | Latency (ns/item) |",
"| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: |",
(inputs |
  (.median_ns / 1e6) as $med_ms |
  (.min_ns / 1e6) as $min_ms |
  (if .ops_per_sec >= 1e6 then "\(fmt_dec(.ops_per_sec / 1e6; 2)) M/s" else "\(fmt_dec(.ops_per_sec / 1e3; 2)) K/s" end) as $tp |
  (if .bytes_row > 0 then "\(fmt_dec(.mb_per_sec; 1)) MB/s" else "-" end) as $bw |
  "| \(.rank) | \(.name) | \(.rows) | \(fmt_dec($med_ms; 3)) ms | \(fmt_dec($min_ms; 3)) ms | \($tp) | \($bw) | **\(fmt_dec(.ns_per_item; 1)) ns** |"
)
' "${JSONL_FILE}")

AWK_SCRIPT='
BEGIN { in_block = 0 }
/<!-- BEGIN_BENCHMARK_TABLE -->/ {
    print
    print table
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
        awk -v table="${TABLE}" "${AWK_SCRIPT}" "${md_file}" > "${md_file}.tmp"
        mv "${md_file}.tmp" "${md_file}"
        echo "Updated ${md_file} from ${JSONL_FILE}"
    fi
done
