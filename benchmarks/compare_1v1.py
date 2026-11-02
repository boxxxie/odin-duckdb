#!/usr/bin/env python3
"""
Sophisticated Benchmark Runner, Multi-Run Aggregator, Commit Regression Analyzer &
Git-Diff Benchmark Impact Mapper for odin-duckdb.

Features:
- Multi-sample variance tracking (Mean, Median/p50, StdDev, Variance, CV%, Min/Max, IQR, p95, p99)
- Pools multiple runs associated with the same (commit, lang, benchmark) from JSONL history
- Commit-vs-Commit regression comparison (--compare-commits <SHA_A> <SHA_B>) with Welch's z-test
- Git-diff-to-benchmark impact mapping (--plan [REF], --plan-json [REF], --affected [REF])
- Selective benchmark execution (--groups <csv>, --filter <patterns>)
- Commit & Run history inspection (--list-commits, --inspect <pattern>)
"""

import argparse
import json
import math
import os
import re
import subprocess
import sys
import time
from collections import defaultdict
from typing import Any, Dict, List, Optional, Set, Tuple

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BENCH_DIR = os.path.join(ROOT_DIR, "benchmarks")
ODIN_JSONL = os.path.join(BENCH_DIR, "odin.jsonl")
HISTORY_JSONL = os.path.join(BENCH_DIR, "history.jsonl")

ALL_GROUPS = [
    "ingest",
    "scan",
    "bytes",
    "nested",
    "dsl_codegen",
    "udf",
    "point_tx",
    "vfs_telemetry",
]


def current_git_commit() -> str:
    try:
        out = subprocess.check_output(
            ["git", "rev-parse", "--short=12", "HEAD"],
            cwd=ROOT_DIR,
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        return out if out else "unknown"
    except Exception:
        return "unknown"


def resolve_diff_target(ref: Optional[str]) -> Tuple[List[str], str]:
    """
    Determines the git diff command and human description.
    - If `ref` is explicitly given (e.g. 'HEAD~1', 'main', 'a1b2c3d..e4f5g6h'), diffs against that ref.
    - Otherwise, if the working tree or index has uncommitted changes in `duckdb/` or `benchmarks/`,
      diffs `HEAD` (working tree + staged).
    - Otherwise, diffs `HEAD~1..HEAD` (the most recent commit).
    """
    if ref and ref != "auto":
        return ["git", "diff", "--unified=0", ref], f"git diff {ref}"

    try:
        status_out = subprocess.check_output(
            ["git", "status", "--porcelain", "--", "duckdb/", "benchmarks/"],
            cwd=ROOT_DIR,
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        if status_out:
            return ["git", "diff", "--unified=0", "HEAD", "--", "duckdb/", "benchmarks/"], "working tree + staged vs HEAD"
    except Exception:
        pass

    return ["git", "diff", "--unified=0", "HEAD~1..HEAD", "--", "duckdb/", "benchmarks/"], "latest commit (HEAD~1..HEAD)"


def map_changes_to_benchmarks(ref: Optional[str] = None) -> Dict[str, Any]:
    """
    Inspects git diff across `duckdb/*.odin` and `benchmarks/bench_main.odin`, extracts modified files
    and Odin procedure definitions, and maps them to affected benchmark groups and name filters.
    """
    diff_cmd, diff_desc = resolve_diff_target(ref)
    try:
        diff_text = subprocess.check_output(
            diff_cmd,
            cwd=ROOT_DIR,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except Exception:
        diff_text = ""

    changed_files: List[str] = []
    changed_procs_by_file: Dict[str, Set[str]] = defaultdict(set)
    current_file: Optional[str] = None

    proc_decl_re = re.compile(r"^\s*([A-Za-z0-9_]+)\s*::\s*proc\b")
    hunk_proc_re = re.compile(r"@@.*@@\s*([A-Za-z0-9_]+)\s*::\s*proc\b")

    for line in diff_text.splitlines():
        if line.startswith("+++ b/"):
            current_file = line[6:].strip()
            if current_file not in changed_files:
                changed_files.append(current_file)
        elif line.startswith("@@ ") and current_file:
            m = hunk_proc_re.search(line)
            if m:
                changed_procs_by_file[current_file].add(m.group(1))
        elif (line.startswith("+") or line.startswith("-")) and not line.startswith("+++") and not line.startswith("---"):
            if current_file:
                body = line[1:]
                m = proc_decl_re.match(body)
                if m:
                    changed_procs_by_file[current_file].add(m.group(1))

    groups: Set[str] = set()
    filters: List[str] = []
    reasons: List[Dict[str, str]] = []
    full_suite_reason: Optional[str] = None

    def add_filter(pat: str) -> None:
        if pat not in filters:
            filters.append(pat)

    for fpath in changed_files:
        procs = sorted(changed_procs_by_file.get(fpath, set()))
        procs_lower = " ".join(procs).lower()

        if fpath == "duckdb/dsl.odin":
            groups.update(["dsl_codegen", "point_tx"])
            add_filter("5a.")
            add_filter("7c.")
            add_filter("7e.")
            reasons.append({
                "file": fpath,
                "procs": ", ".join(procs) or "(module-level)",
                "impact": "Query Builder DSL compilation (`query_to_sql`) & DSL execution (`5a`, `7c`, `7e`)",
            })

        elif fpath == "duckdb/codegen.odin":
            groups.add("dsl_codegen")
            add_filter("5b.")
            reasons.append({
                "file": fpath,
                "procs": ", ".join(procs) or "(module-level)",
                "impact": "Zero-execution schema introspection & Odin/CUE codegen (`5b`)",
            })

        elif fpath == "duckdb/quack.odin":
            groups.add("dsl_codegen")
            if procs and all("sqllogic" in p.lower() for p in procs):
                add_filter("5c.")
                impact_desc = "SQLLogicTest script parser (`5c`)"
            elif procs and not any("sqllogic" in p.lower() for p in procs):
                add_filter("5f.")
                impact_desc = "Quack SQL builders, URI normalization & template expansion (`5f`)"
            else:
                add_filter("5c.")
                add_filter("5f.")
                impact_desc = "SQLLogicTest parser (`5c`) & Quack SQL builders/URI/template (`5f`)"
            reasons.append({
                "file": fpath,
                "procs": ", ".join(procs) or "(module-level)",
                "impact": impact_desc,
            })

        elif fpath == "duckdb/arrow.odin":
            groups.add("scan")
            add_filter("2c.")
            add_filter("2g.")
            reasons.append({
                "file": fpath,
                "procs": ", ".join(procs) or "(module-level)",
                "impact": "Arrow C Data Interface (`Arrow_Array_Stream` `2c`, `Arrow_Exporter`/`Arrow_Importer` `2g`)",
            })

        elif fpath == "duckdb/reflect.odin":
            matched_specific = False
            if any(k in procs_lower for k in ["create_table_sql", "quote_identifier", "odin_type_to_duckdb"]):
                groups.add("dsl_codegen")
                add_filter("5g.")
                matched_specific = True
            if any(k in procs_lower for k in ["struct_appender", "append_slice", "append_chunk", "write_struct"]):
                groups.update(["ingest", "nested"])
                for pat in ["1c.", "1d.", "1g.", "4a."]:
                    add_filter(pat)
                matched_specific = True
            if any(k in procs_lower for k in ["query_as", "unmarshal", "read_struct", "query_execute_as"]):
                groups.update(["scan", "nested", "point_tx"])
                for pat in ["2d.", "2e.", "4a.", "7c."]:
                    add_filter(pat)
                matched_specific = True
            if any(k in procs_lower for k in ["prepared_query", "query_prepare_as"]):
                groups.add("point_tx")
                add_filter("7e.")
                matched_specific = True

            if not matched_specific:
                groups.update(["ingest", "scan", "nested", "dsl_codegen", "point_tx"])
                for pat in ["1c.", "1d.", "1g.", "2d.", "2e.", "4a.", "5g.", "7c.", "7e."]:
                    add_filter(pat)

            reasons.append({
                "file": fpath,
                "procs": ", ".join(procs) or "(module-level)",
                "impact": "Reflection marshaling (`append_slice`, `Struct_Appender`, `query_as`, `create_table_sql`, `Prepared_Query`)",
            })

        elif fpath == "duckdb/duckdb.odin":
            groups.add("ingest")
            add_filter("1b.")
            reasons.append({
                "file": fpath,
                "procs": ", ".join(procs) or "(module-level)",
                "impact": "Legacy V1 C API & Appender (`1b`)",
            })

        elif fpath == "duckdb/capi_v2.odin":
            matched_v2 = False
            if procs:
                if any("transaction" in p.lower() for p in procs):
                    groups.add("point_tx")
                    add_filter("7d.")
                    matched_v2 = True
                if any("step_chunk" in p.lower() for p in procs):
                    groups.add("scan")
                    add_filter("2i.")
                    matched_v2 = True
                if any("vector_assign_string" in p.lower() or "v2_bytes" in p.lower() for p in procs):
                    groups.update(["ingest", "scan", "bytes"])
                    for pat in ["1c.", "1d.", "1g.", "2a.", "2d.", "2e.", "3a.", "3b."]:
                        add_filter(pat)
                    matched_v2 = True
                if any("hugeint" in p.lower() or "uhugeint" in p.lower() or "bignum" in p.lower() or "bit" in p.lower() for p in procs):
                    groups.add("bytes")
                    add_filter("3f.")
                    matched_v2 = True

            if not matched_v2:
                groups.update(ALL_GROUPS)
                full_suite_reason = f"Core C API v2 bindings (`{fpath}`) modified across general symbols; full suite recommended"

            reasons.append({
                "file": fpath,
                "procs": ", ".join(procs) or "(module-level)",
                "impact": "DuckDB 2.0 C API v2 bindings & zero-copy vector/chunk helpers",
            })

        elif fpath == "benchmarks/bench_main.odin":
            matched_bench = False
            for p in procs:
                pl = p.lower()
                if "ingest" in pl or "copy_" in pl or "struct_appender" in pl:
                    groups.add("ingest")
                    matched_bench = True
                if "scan" in pl or "arrow" in pl or "query_as" in pl:
                    groups.add("scan")
                    matched_bench = True
                if "v2_bytes" in pl or "vector_" in pl or "128bit" in pl:
                    groups.add("bytes")
                    matched_bench = True
                if "json_tag" in pl or "struct_vector" in pl or "list_vector" in pl or "array_vector" in pl or "composite" in pl:
                    groups.add("nested")
                    matched_bench = True
                if "dsl_query_to_sql" in pl or "schema_introspect" in pl or "sqllogic" in pl or "tokenize_sql" in pl or "describe_table" in pl or "quack" in pl or "ddl_create_table" in pl:
                    groups.add("dsl_codegen")
                    matched_bench = True
                if "udf" in pl or "replacement_scan" in pl or "pragma" in pl or "pushdown" in pl or "cast_ns" in pl:
                    groups.add("udf")
                    matched_bench = True
                if "point_lookup" in pl or "query_execute_as" in pl or "with_transaction" in pl or "prepared_query_execute_as" in pl:
                    groups.add("point_tx")
                    matched_bench = True
                if "vfs" in pl or "query_metrics" in pl or "log_sink" in pl:
                    groups.add("vfs_telemetry")
                    matched_bench = True
            if not matched_bench:
                groups.update(ALL_GROUPS)
                full_suite_reason = "Benchmark harness infrastructure modified in `benchmarks/bench_main.odin`"
            reasons.append({
                "file": fpath,
                "procs": ", ".join(procs) or "(harness)",
                "impact": "Benchmark suite definitions (`benchmarks/bench_main.odin`)",
            })

    ordered_groups = [g for g in ALL_GROUPS if g in groups]
    is_full_suite = (len(ordered_groups) == len(ALL_GROUPS)) or (full_suite_reason is not None)
    if is_full_suite:
        ordered_groups = list(ALL_GROUPS)
        filters = []

    known_records = load_jsonl_file(ODIN_JSONL) or load_all_history()
    seen_names: List[str] = []
    for r in known_records:
        nm = r.get("name", "")
        if nm and nm not in seen_names:
            seen_names.append(nm)

    matched_tests: List[str] = []
    if is_full_suite:
        matched_tests = list(seen_names)
    elif filters:
        for nm in seen_names:
            low = nm.lower()
            if any(f.lower() in low for f in filters):
                matched_tests.append(nm)
    elif ordered_groups:
        prefix_map = {
            "ingest": "1",
            "scan": "2",
            "bytes": "3",
            "nested": "4",
            "dsl_codegen": "5",
            "udf": "6",
            "point_tx": "7",
            "vfs_telemetry": "8",
        }
        allowed_prefixes = tuple(prefix_map[g] for g in ordered_groups if g in prefix_map)
        for nm in seen_names:
            if nm.startswith(allowed_prefixes):
                matched_tests.append(nm)

    return {
        "diff_desc": diff_desc,
        "changed_files": changed_files,
        "reasons": reasons,
        "groups": ordered_groups,
        "filters": filters,
        "is_full_suite": is_full_suite,
        "full_suite_reason": full_suite_reason,
        "matched_tests": matched_tests,
        "total_known_tests": len(seen_names),
    }


def print_benchmark_plan(plan: Dict[str, Any]) -> None:
    print()
    print("=" * 116)
    print("  odin-duckdb Code-Change-to-Benchmark Impact Plan")
    print(f"  Inspected Diff : {plan['diff_desc']}")
    print("=" * 116)

    if not plan["changed_files"]:
        print("  No changes detected in `duckdb/` or `benchmarks/`.")
        print("=" * 116)
        return

    print("  Modified Files & Procedures:")
    for r in plan["reasons"]:
        print(f"    - {r['file']:<28} | Procs: {r['procs']}")
        print(f"      -> Impact: {r['impact']}")

    print("  " + "-" * 112)
    if plan["is_full_suite"]:
        reason_str = f" ({plan['full_suite_reason']})" if plan["full_suite_reason"] else ""
        print(f"  Selected Scope : FULL SUITE ({len(plan['matched_tests'])}/{plan['total_known_tests']} benchmarks){reason_str}")
        print("  Command        : ./benchmarks/compare_1v1.py")
    elif not plan["groups"] and not plan["filters"]:
        print("  Selected Scope : NONE (only non-benchmark files modified)")
    else:
        grp_csv = ",".join(plan["groups"])
        flt_str = "|".join(plan["filters"])
        print(f"  Selected Groups: {grp_csv}")
        if flt_str:
            print(f"  Name Filter    : {flt_str}")
        print(f"  Matched Tests  : {len(plan['matched_tests'])} / {plan['total_known_tests']} benchmarks")
        for idx, nm in enumerate(plan["matched_tests"], 1):
            print(f"    {idx:>2}. {nm}")
        cmd_parts = ["./benchmarks/compare_1v1.py", f"--groups {grp_csv}"]
        if flt_str:
            cmd_parts.append(f'--filter "{flt_str}"')
        print("  " + "-" * 112)
        print(f"  Direct Command : {' '.join(cmd_parts)}")
        print("  Auto Command   : ./benchmarks/compare_1v1.py --affected")
    print("=" * 116)


def calc_percentile(sorted_vals: List[float], p: float) -> float:
    n = len(sorted_vals)
    if n == 0:
        return 0.0
    if n == 1:
        return sorted_vals[0]
    pos = p * (n - 1)
    lo = int(math.floor(pos))
    hi = min(lo + 1, n - 1)
    frac = pos - lo
    return sorted_vals[lo] + frac * (sorted_vals[hi] - sorted_vals[lo])


def compute_pooled_stats(records: List[Dict[str, Any]]) -> Dict[str, Any]:
    """
    Pools all raw `samples_ns` across multiple run records associated with the same
    (commit, lang, benchmark_name) and computes unified variance statistics.
    """
    first = records[0]
    samples: List[float] = []
    run_ids: List[str] = []

    for r in records:
        rid = str(r.get("run_id", "run-0"))
        if rid not in run_ids:
            run_ids.append(rid)
        if "samples_ns" in r and isinstance(r["samples_ns"], list) and len(r["samples_ns"]) > 0:
            samples.extend(float(x) for x in r["samples_ns"])
        elif "ns_per_item" in r:
            samples.append(float(r["ns_per_item"]))
        elif "ns_per_op" in r:
            samples.append(float(r["ns_per_op"]))

    if not samples:
        samples = [0.0]

    sorted_s = sorted(samples)
    n = len(sorted_s)
    min_ns = sorted_s[0]
    max_ns = sorted_s[-1]
    median_ns = calc_percentile(sorted_s, 0.50)
    q1_ns = calc_percentile(sorted_s, 0.25)
    q3_ns = calc_percentile(sorted_s, 0.75)
    iqr_ns = q3_ns - q1_ns
    p95_ns = calc_percentile(sorted_s, 0.95)
    p99_ns = calc_percentile(sorted_s, 0.99)

    mean_ns = sum(sorted_s) / n
    if n > 1:
        variance_ns2 = sum((x - mean_ns) ** 2 for x in sorted_s) / (n - 1)
    else:
        variance_ns2 = 0.0
    stddev_ns = math.sqrt(variance_ns2)
    cv_pct = (stddev_ns / max(mean_ns, 1e-9)) * 100.0

    ops = int(first.get("ops", first.get("rows", 1)))
    bytes_row = int(first.get("bytes_row", 0))
    bytes_used = max(int(r.get("bytes_used", ops * bytes_row)) for r in records)
    total_ms = (median_ns * max(ops, 1)) / 1e6
    ops_per_sec = (ops * 1e9) / max(median_ns * max(ops, 1), 1.0)
    mb_per_sec = (ops_per_sec * bytes_row) / (1024.0 * 1024.0)

    return {
        "rank": int(first.get("rank", 0)),
        "lang": first.get("lang", "odin"),
        "commit": first.get("commit", "unknown"),
        "run_ids": run_ids,
        "num_invocations": len(records),
        "name": first["name"],
        "ops": ops,
        "runs": n,
        "total_ms": total_ms,
        "ns_per_op": median_ns,
        "median_ns": median_ns,
        "mean_ns": mean_ns,
        "stddev_ns": stddev_ns,
        "variance_ns2": variance_ns2,
        "cv_pct": cv_pct,
        "min_ns": min_ns,
        "max_ns": max_ns,
        "iqr_ns": iqr_ns,
        "p95_ns": p95_ns,
        "p99_ns": p99_ns,
        "ops_per_sec": ops_per_sec,
        "mb_per_sec": mb_per_sec,
        "bytes_row": bytes_row,
        "bytes_used": bytes_used,
        "samples_ns": samples,
    }


def load_jsonl_file(path: str) -> List[Dict[str, Any]]:
    if not os.path.isfile(path):
        return []
    out = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return out


def match_commit(record_commit: str, target_commit: Optional[str]) -> bool:
    if not target_commit:
        return True
    rc = record_commit.strip()
    tc = target_commit.strip()
    return rc.startswith(tc) or tc.startswith(rc)


def pool_by_lang_and_test(
    records: List[Dict[str, Any]],
    lang: str = "odin",
    commit: Optional[str] = None,
) -> List[Dict[str, Any]]:
    filtered = [
        r for r in records
        if r.get("lang", "odin") == lang and match_commit(str(r.get("commit", "unknown")), commit)
    ]
    if not filtered and commit:
        return []

    grouped: Dict[str, List[Dict[str, Any]]] = defaultdict(list)
    order: List[str] = []
    for r in filtered:
        name = r["name"]
        if name not in grouped:
            order.append(name)
        grouped[name].append(r)

    if not commit:
        for name in order:
            recs = grouped[name]
            latest_c = recs[-1].get("commit", "unknown")
            grouped[name] = [r for r in recs if r.get("commit", "unknown") == latest_c]

    pooled = [compute_pooled_stats(grouped[name]) for name in order]
    pooled.sort(key=lambda x: x["rank"])
    return pooled


def welch_se(a: Dict[str, Any], b: Dict[str, Any]) -> float:
    var_a = a["variance_ns2"]
    var_b = b["variance_ns2"]
    n_a = max(a["runs"], 1)
    n_b = max(b["runs"], 1)
    return math.sqrt((var_a / n_a) + (var_b / n_b))


def welch_z_score(a: Dict[str, Any], b: Dict[str, Any]) -> float:
    se = welch_se(a, b)
    if se < 1e-6:
        return 99.0 if abs(a["mean_ns"] - b["mean_ns"]) >= 0.05 else 0.0
    return abs(a["mean_ns"] - b["mean_ns"]) / se


def run_cmd(cmd: List[str], label: str) -> None:
    print(f"==> Running {label}: {' '.join(cmd)}", file=sys.stderr)
    env = os.environ.copy()
    local_lib = os.path.expanduser("~/.local/lib")
    env["LD_LIBRARY_PATH"] = f"{local_lib}:{env.get('LD_LIBRARY_PATH', '')}".rstrip(":")
    proc = subprocess.run(cmd, cwd=ROOT_DIR, env=env)
    if proc.returncode != 0:
        sys.exit(proc.returncode)


def print_pooled_summary(odin_rows: List[Dict[str, Any]]) -> None:
    if not odin_rows:
        print("ERROR: No benchmark records found.", file=sys.stderr)
        sys.exit(1)

    o_commit = odin_rows[-1]["commit"]
    o_samples = odin_rows[0]["runs"]
    o_inv = odin_rows[0]["num_invocations"]

    print()
    print("=" * 158)
    print(
        f"  odin-duckdb Pooled Statistical Benchmark Report (-o:speed -microarch:native)\n"
        f"  Commit: {o_commit} ({o_samples} samples/test across {o_inv} run(s))"
    )
    print("=" * 158)
    header = (
        f"  {'Benchmark':<56} | {'Ops':>8} | {'Med (ms)':>9} | {'Med ± σ (ns)':>19} | "
        f"{'CV%':>6} | {'IQR ns':>8} | {'p95 ns':>9} | {'Throughput':>11} | {'Bandwidth':>11}"
    )
    print(header)
    print("  " + "-" * 154)

    for r in odin_rows:
        name = r["name"][:56]
        med_sd = f"{r['median_ns']:.1f} ± {r['stddev_ns']:.1f}"
        cv_str = f"{r['cv_pct']:.1f}%"
        tp_str = (
            f"{r['ops_per_sec'] / 1e6:.2f} M/s"
            if r["ops_per_sec"] >= 1e6
            else f"{r['ops_per_sec'] / 1e3:.2f} K/s"
        )
        bw_str = f"{r['mb_per_sec']:.1f} MB/s" if r["bytes_row"] > 0 else "—"
        print(
            f"  {name:<56} | {r['ops']:>8} | {r['total_ms']:>9.3f} | {med_sd:>19} | "
            f"{cv_str:>6} | {r['iqr_ns']:>8.1f} | {r['p95_ns']:>9.1f} | {tp_str:>11} | {bw_str:>11}"
        )
    print("=" * 158)


def compare_commits(records: List[Dict[str, Any]], sha_a: str, sha_b: str, lang: str = "odin") -> None:
    rows_a = pool_by_lang_and_test(records, lang, sha_a)
    rows_b = pool_by_lang_and_test(records, lang, sha_b)

    if not rows_a:
        print(f"ERROR: No benchmark records found for commit '{sha_a}'.", file=sys.stderr)
        sys.exit(1)
    if not rows_b:
        print(f"ERROR: No benchmark records found for commit '{sha_b}'.", file=sys.stderr)
        sys.exit(1)

    map_b = {r["name"]: r for r in rows_b}
    paired = [(a, map_b[a["name"]]) for a in rows_a if a["name"] in map_b]

    full_a = rows_a[0]["commit"]
    full_b = rows_b[0]["commit"]

    print()
    print("=" * 162)
    print(
        f"  Commit-vs-Commit Benchmark Regression Report [{lang.upper()}]\n"
        f"  Baseline (A): {full_a} ({rows_a[0]['runs']} samples across {rows_a[0]['num_invocations']} run(s))  vs  "
        f"Candidate (B): {full_b} ({rows_b[0]['runs']} samples across {rows_b[0]['num_invocations']} run(s))"
    )
    print("=" * 162)
    print(
        f"  {'Benchmark':<54} | {'Baseline A (Med ± σ)':>22} | {'Candidate B (Med ± σ)':>22} | "
        f"{'Delta %':>9} | {'Speedup':>9} | {'Welch z':>7} | {'Verdict':<14}"
    )
    print("  " + "-" * 158)

    faster = 0
    slower = 0
    unchanged = 0

    for a, b in paired:
        med_a = max(a["median_ns"], 0.01)
        med_b = max(b["median_ns"], 0.01)
        delta_pct = ((med_b - med_a) / med_a) * 100.0
        speedup = med_a / med_b
        z = welch_z_score(a, b)
        se = welch_se(a, b)
        med_z = (abs(med_b - med_a) / se) if se >= 1e-6 else (99.0 if abs(med_b - med_a) >= 0.05 else 0.0)

        # Require 99% confidence (z >= 2.58 on both mean and median) AND >= 10% relative shift
        # AND >= 5.0 ns absolute shift (or >= 0.5 ns for sub-50ns tests) to filter out CPU clock drift.
        abs_thresh = 0.5 if max(med_a, med_b) < 50.0 else 5.0
        is_sig = (
            (z >= 2.58)
            and (med_z >= 2.58)
            and (abs(delta_pct) >= 10.0)
            and (abs(med_b - med_a) >= abs_thresh)
        )
        if is_sig and med_b < med_a:
            verdict = "FASTER"
            faster += 1
        elif is_sig and med_b > med_a:
            verdict = "REGRESSION"
            slower += 1
        else:
            verdict = "~NOISE"
            unchanged += 1

        cell_a = f"{a['median_ns']:>8.1f} ± {a['stddev_ns']:>5.1f} ns"
        cell_b = f"{b['median_ns']:>8.1f} ± {b['stddev_ns']:>5.1f} ns"
        print(
            f"  {a['name'][:54]:<54} | {cell_a:>22} | {cell_b:>22} | "
            f"{delta_pct:>+8.1f}% | {speedup:>8.2f}x | {z:>7.2f} | {verdict:<14}"
        )

    print("=" * 162)
    print(
        f"  Summary ({len(paired)} benchmarks): {faster} FASTER, {slower} REGRESSION, {unchanged} ~NOISE (within variance)"
    )
    print("=" * 162)


def list_commits(records: List[Dict[str, Any]]) -> None:
    if not records:
        print("No benchmark history records found.")
        return

    summary: Dict[Tuple[str, str], Dict[str, Any]] = {}
    for r in records:
        key = (str(r.get("commit", "unknown")), str(r.get("lang", "odin")))
        if key not in summary:
            summary[key] = {"run_ids": set(), "tests": set(), "total_samples": defaultdict(int)}
        rid = str(r.get("run_id", "run-0"))
        summary[key]["run_ids"].add(rid)
        name = r.get("name", "")
        summary[key]["tests"].add(name)
        s_cnt = len(r.get("samples_ns", [])) if isinstance(r.get("samples_ns"), list) else int(r.get("runs", r.get("iterations", 1)))
        summary[key]["total_samples"][name] += max(s_cnt, 1)

    print()
    print("=" * 96)
    print(f"  {'Commit SHA':<16} | {'Lang':<6} | {'Run Sessions':>12} | {'Benchmarks':>10} | {'Pooled Samples/Test':>20} | {'Run IDs'}")
    print("  " + "-" * 92)
    for (commit, lang), info in summary.items():
        samples_counts = list(info["total_samples"].values())
        min_s = min(samples_counts) if samples_counts else 0
        max_s = max(samples_counts) if samples_counts else 0
        samp_str = f"{min_s}" if min_s == max_s else f"{min_s}..{max_s}"
        rids = ", ".join(sorted(info["run_ids"])[:4])
        if len(info["run_ids"]) > 4:
            rids += f" (+{len(info['run_ids']) - 4} more)"
        print(
            f"  {commit:<16} | {lang:<6} | {len(info['run_ids']):>12} | {len(info['tests']):>10} | {samp_str:>20} | {rids}"
        )
    print("=" * 96)


def inspect_test(records: List[Dict[str, Any]], pattern: str, commit: Optional[str]) -> None:
    pat = pattern.lower()
    matched = [
        r for r in records
        if pat in r.get("name", "").lower() and match_commit(str(r.get("commit", "unknown")), commit)
    ]
    if not matched:
        print(f"No benchmark records matching '{pattern}'" + (f" at commit '{commit}'" if commit else ""))
        return

    grouped: Dict[Tuple[str, str, str], List[Dict[str, Any]]] = defaultdict(list)
    for r in matched:
        key = (str(r.get("commit", "unknown")), str(r.get("lang", "odin")), r["name"])
        grouped[key].append(r)

    print()
    for (c_sha, lang, name), recs in grouped.items():
        pooled = compute_pooled_stats(recs)
        print("=" * 110)
        print(f"  Benchmark : {name}")
        print(f"  Commit    : {c_sha} | Lang: {lang} | Invocations: {pooled['num_invocations']} | Total Pooled Samples: {pooled['runs']}")
        print(
            f"  Stats (ns): Median={pooled['median_ns']:.2f} | Mean={pooled['mean_ns']:.2f} ± {pooled['stddev_ns']:.2f} "
            f"(CV={pooled['cv_pct']:.2f}%, Var={pooled['variance_ns2']:.2f})"
        )
        print(
            f"  Quantiles : Min={pooled['min_ns']:.2f} | IQR={pooled['iqr_ns']:.2f} | "
            f"p95={pooled['p95_ns']:.2f} | p99={pooled['p99_ns']:.2f} | Max={pooled['max_ns']:.2f}"
        )
        print(f"  Samples   : {[round(x, 2) for x in pooled['samples_ns']]}")
        for idx, r in enumerate(recs, 1):
            r_samples = r.get("samples_ns", [r.get("ns_per_op", r.get("ns_per_item", 0))])
            print(f"    Run #{idx} ({r.get('run_id', 'run-0')}): median={r.get('ns_per_op', r.get('ns_per_item'))} ns/op, samples={r_samples}")
    print("=" * 110)


def load_all_history() -> List[Dict[str, Any]]:
    records = load_jsonl_file(HISTORY_JSONL)
    if not records:
        records = load_jsonl_file(ODIN_JSONL)
    return records


def main() -> None:
    parser = argparse.ArgumentParser(description="odin-duckdb Multi-Run Statistical Benchmark Runner & Analyzer")
    parser.add_argument("--runs", type=int, default=5, help="In-process measured trials per test (default: 5)")
    parser.add_argument("--warmup", type=int, default=1, help="In-process warmup passes before trials (default: 1)")
    parser.add_argument("--commit", type=str, default=None, help="Git commit SHA to tag or query")
    parser.add_argument("--run-id", type=str, default=None, help="Run session identifier")
    parser.add_argument("--append", action="store_true", help="Append to odin.jsonl to accumulate multiple runs")
    parser.add_argument("--no-history", action="store_true", help="Do not append to benchmarks/history.jsonl")
    parser.add_argument("--from-jsonl", action="store_true", help="Analyze existing JSONL files without re-running binaries")
    parser.add_argument(
        "--groups",
        type=str,
        default=None,
        help="Comma-separated benchmark groups to run (ingest,scan,bytes,nested,dsl_codegen,udf,point_tx,vfs_telemetry)",
    )
    parser.add_argument(
        "--filter",
        type=str,
        default=None,
        help="Pipe- or comma-separated substring patterns matching benchmark names",
    )
    parser.add_argument(
        "--affected",
        nargs="?",
        const="auto",
        default=None,
        metavar="GIT_REF",
        help="Automatically detect modified files/procedures in git diff and run only affected benchmarks",
    )
    parser.add_argument(
        "--plan",
        nargs="?",
        const="auto",
        default=None,
        metavar="GIT_REF",
        help="Dry-run: show which files, procedures, and benchmarks are affected by git diff without executing",
    )
    parser.add_argument(
        "--plan-json",
        nargs="?",
        const="auto",
        default=None,
        metavar="GIT_REF",
        help="Emit the git-diff benchmark impact plan as JSON",
    )
    parser.add_argument(
        "--compare-commits",
        nargs=2,
        metavar=("SHA_A", "SHA_B"),
        help="Compare benchmark distributions between two git commit SHAs",
    )
    parser.add_argument("--list-commits", action="store_true", help="List all commits and run sessions in history")
    parser.add_argument("--inspect", type=str, default=None, help="Inspect all runs and sample distributions for matching tests")

    args = parser.parse_args()

    if args.plan_json is not None:
        plan = map_changes_to_benchmarks(args.plan_json)
        print(json.dumps(plan))
        return

    if args.plan is not None:
        plan = map_changes_to_benchmarks(args.plan)
        print_benchmark_plan(plan)
        return

    if args.list_commits:
        list_commits(load_all_history())
        return

    if args.inspect:
        inspect_test(load_all_history(), args.inspect, args.commit)
        return

    if args.compare_commits:
        sha_a, sha_b = args.compare_commits
        compare_commits(load_all_history(), sha_a, sha_b, "odin")
        return

    selected_groups = args.groups
    selected_filter = args.filter

    if args.affected is not None:
        plan = map_changes_to_benchmarks(args.affected)
        print_benchmark_plan(plan)
        if not plan["changed_files"] or (not plan["groups"] and not plan["filters"] and not plan["is_full_suite"]):
            print("No benchmark-relevant code changes detected; skipping benchmark execution.")
            return
        if not plan["is_full_suite"]:
            if plan["groups"] and not selected_groups:
                selected_groups = ",".join(plan["groups"])
            if plan["filters"] and not selected_filter:
                selected_filter = "|".join(plan["filters"])

    if not args.from_jsonl:
        commit_sha = args.commit or current_git_commit()
        run_id = args.run_id or f"run-{int(time.time())}"
        local_lib = os.path.expanduser("~/.local/lib")

        common_flags = [
            "--runs", str(args.runs),
            "--warmup", str(args.warmup),
            "--commit", commit_sha,
            "--run-id", run_id,
        ]
        if args.append:
            common_flags.append("--append")
        if args.no_history:
            common_flags.append("--no-history")
        if selected_groups:
            common_flags.extend(["--groups", selected_groups])
        if selected_filter:
            common_flags.extend(["--filter", selected_filter])

        run_cmd(
            [
                "odin", "run", "benchmarks", "-o:speed", "-microarch:native",
                f"-extra-linker-flags:-L{local_lib} -Wl,-rpath,{local_lib}",
                "--",
            ] + common_flags,
            "odin-duckdb (-o:speed -microarch:native)",
        )

    odin_raw = load_all_history() if args.commit else (load_jsonl_file(ODIN_JSONL) or load_all_history())
    odin_rows = pool_by_lang_and_test(odin_raw, "odin", args.commit)
    print_pooled_summary(odin_rows)


if __name__ == "__main__":
    main()
