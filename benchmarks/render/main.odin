package bench_render

import "core:encoding/json"
import "core:fmt"
import "core:math"
import vmem "core:mem/virtual"
import "core:os"
import "core:strings"

DEFAULT_HUGI_BIN :: "/home/pauli/.local/bin/hugi"
DEFAULT_DB_PATH :: "benchmarks/history.hugidb"
RENDERS_DIR :: "benchmarks/renders"
README_PATH :: "benchmarks/README.md"

PALETTE :: [7]string{
	"#58a6ff",
	"#3fb950",
	"#f78166",
	"#d2a8ff",
	"#ffa657",
	"#79c0ff",
	"#ff7b72",
}

Group_Meta :: struct {
	key:   string,
	title: string,
	desc:  string,
}

GROUP_META :: [8]Group_Meta{
	{"ingest", "`ingest` — Prepared Loops, Appenders, `append_slice` & Custom `COPY`", "Comparing V1 Appenders, V2 `ColumnDataCollection`, `Struct_Appender(T)`, and custom `V2_Copy_Function` pipelines."},
	{"scan", "`scan` — Zero-Copy Vector Views, Selection Vectors & Arrow Streams", "Zero-copy column views, filtered selection vectors, `core:reflect` unmarshaling, multi-worker scans, and Arrow bridges."},
	{"bytes", "`bytes` — `V2_Bytes`, Casts, Vector Flatten & 128-Bit Codecs", "Inline/arena `V2_Bytes` writes, vector casts, `.OTHER` flattening, zero-copy `vector_reference`, and 128-bit wire codecs."},
	{"nested", "`nested` — `STRUCT`, `LIST`, `ARRAY`, JSON Tags & Composite Values", "Native nested child vectors (`STRUCT`, `LIST`, `ARRAY`), JSON struct round-trips, and composite value handling."},
	{"dsl_codegen", "`dsl_codegen` — Friendly SQL DSL, Codegen, Parser & Native Lexer", "`query_to_sql`, `introspect_table_schema` Odin/CUE codegen, SQLLogic parser, `v2_tokenize_sql`, and Quack helpers."},
	{"udf", "`udf` — Vectorized Scalar, Table & Aggregate Odin UDFs", "Vectorized scalar callbacks, streaming table functions with projection/filter pushdown, aggregates, casts, and replacement scans."},
	{"point_tx", "`point_tx` — Point Queries, Prepared Plans & Transactions", "Ad-hoc vs prepared `v2_query` execution, DSL round-trips, and explicit `v2_with_transaction` commits/rollbacks."},
	{"vfs_telemetry", "`vfs_telemetry` — Positional VFS I/O & Query Telemetry", "Positional `write_at` + `read_at` VFS throughput and `V2_Query_Metrics` tree collection."},
}

Hugi_Record :: struct {
	commit:             string,
	group_name:         string,
	name:               string,
	full_name:          string,
	samples:            int,
	p50_ns:             f64,
	p95_ns:             f64,
	cv_pct:             f64,
	ops_per_sec:        f64,
	mb_per_sec:         f64,
	allocs_per_op:      f64,
	alloc_bytes_per_op: f64,
}

Svg_Tick_View :: struct {
	pos:      string,
	text_pos: string,
	label:    string,
}

Bar_View :: struct {
	label:    string,
	text_y:   string,
	rect_y:   string,
	width:    string,
	val_x:    string,
	val_y:    string,
	val_text: string,
	color:    string,
}

Bar_Chart_View :: struct {
	title:       string,
	subtitle:    string,
	width:       int,
	height:      int,
	pad_l:       int,
	pad_t:       int,
	pw:          int,
	ph:          int,
	plot_bottom: int,
	label_x:     int,
	x_label_y:   int,
	x_ticks:     []Svg_Tick_View,
	bars:        []Bar_View,
}

Report_Row_View :: struct {
	name:   string,
	median: string,
	p95:    string,
	ops:    string,
	cv:     string,
	allocs: string,
}

Report_Group_View :: struct {
	title:    string,
	desc:     string,
	has_desc: bool,
	count:    int,
	rows:     []Report_Row_View,
}

Suite_Report_View :: struct {
	commit:            string,
	total_benchmarks:  int,
	total_samples_str: string,
	group_count:       int,
	groups:            []Report_Group_View,
}

Bar_Spec :: struct {
	full_name: string,
	label:     string,
	color:     string,
}

bar_chart_tmpl := compiled("templates/bar_chart.runa.twig", Bar_Chart_View)
suite_report_tmpl := compiled("templates/suite_report.runa.twig", Suite_Report_View)

@(require_results)
fmt_commas_u64 :: proc(val: u64, allocator := context.allocator) -> string {
	buf: [32]byte
	pos := len(buf)
	v := val
	digits := 0
	if v == 0 {
		pos -= 1
		buf[pos] = '0'
	} else {
		for v > 0 {
			if digits > 0 && digits % 3 == 0 {
				pos -= 1
				buf[pos] = ','
			}
			pos -= 1
			buf[pos] = byte('0' + (v % 10))
			v /= 10
			digits += 1
		}
	}
	return strings.clone(string(buf[pos:]), allocator)
}

@(require_results)
fmt_ns :: proc(ns: f64, allocator := context.allocator) -> string {
	if ns < 1.0 {
		return fmt.aprintf("%.2f ps", ns * 1000.0, allocator = allocator)
	}
	if ns < 1_000.0 {
		return fmt.aprintf("%.2f ns", ns, allocator = allocator)
	}
	if ns < 1_000_000.0 {
		return fmt.aprintf("%.2f us", ns / 1_000.0, allocator = allocator)
	}
	if ns < 1_000_000_000.0 {
		return fmt.aprintf("%.2f ms", ns / 1_000_000.0, allocator = allocator)
	}
	return fmt.aprintf("%.3f s", ns / 1_000_000_000.0, allocator = allocator)
}

@(require_results)
fmt_axis_ns :: proc(ns: f64, allocator := context.allocator) -> string {
	if ns <= 0 {
		return strings.clone("0", allocator)
	}
	raw := fmt_ns(ns, context.temp_allocator)
	if s, ok := strings.replace_all(raw, ".000 ", " ", context.temp_allocator); ok {
		raw = s
	}
	if s, ok := strings.replace_all(raw, ".00 ", " ", context.temp_allocator); ok {
		raw = s
	}
	return strings.clone(raw, allocator)
}

@(require_results)
fmt_bytes :: proc(b: f64, allocator := context.allocator) -> string {
	if b < 1024.0 {
		return fmt.aprintf("%.0f B", b, allocator = allocator)
	}
	if b < 1024.0 * 1024.0 {
		return fmt.aprintf("%.2f KiB", b / 1024.0, allocator = allocator)
	}
	return fmt.aprintf("%.2f MiB", b / (1024.0 * 1024.0), allocator = allocator)
}

@(require_results)
fmt_tp_or_ops :: proc(rec: Hugi_Record, allocator := context.allocator) -> string {
	if rec.mb_per_sec >= 1024.0 * 1024.0 {
		return fmt.aprintf("%.2f TB/s", rec.mb_per_sec / (1024.0 * 1024.0), allocator = allocator)
	}
	if rec.mb_per_sec >= 1024.0 {
		return fmt.aprintf("%.2f GB/s", rec.mb_per_sec / 1024.0, allocator = allocator)
	}
	if rec.mb_per_sec > 0 {
		return fmt.aprintf("%.1f MB/s", rec.mb_per_sec, allocator = allocator)
	}
	if rec.ops_per_sec >= 1_000_000_000.0 {
		return fmt.aprintf("%.2fB/s", rec.ops_per_sec / 1_000_000_000.0, allocator = allocator)
	}
	if rec.ops_per_sec >= 1_000_000.0 {
		return fmt.aprintf("%.2fM/s", rec.ops_per_sec / 1_000_000.0, allocator = allocator)
	}
	if rec.ops_per_sec >= 1_000.0 {
		return fmt.aprintf("%.1fK/s", rec.ops_per_sec / 1_000.0, allocator = allocator)
	}
	return fmt.aprintf("%.0f/s", rec.ops_per_sec, allocator = allocator)
}

@(require_results)
exec_hugi :: proc(args: []string, allocator := context.allocator) -> (stdout: []byte, ok: bool) {
	hugi_bin := DEFAULT_HUGI_BIN if os.exists(DEFAULT_HUGI_BIN) else "hugi"
	cmd := make([dynamic]string, 0, len(args) + 1, context.temp_allocator)
	append(&cmd, hugi_bin)
	for a in args {
		append(&cmd, a)
	}
	state, out, stderr, exec_err := os.process_exec(os.Process_Desc{command = cmd[:]}, allocator)
	if exec_err != nil && hugi_bin != "hugi" {
		delete(out, allocator)
		delete(stderr, allocator)
		cmd[0] = "hugi"
		state, out, stderr, exec_err = os.process_exec(os.Process_Desc{command = cmd[:]}, allocator)
	}
	defer delete(stderr, allocator)
	if exec_err != nil || !state.success {
		delete(out, allocator)
		return nil, false
	}
	return out, true
}

@(require_results)
latest_commit_from_hugi :: proc(db_path: string, allocator := context.allocator) -> (string, bool) {
	out, ok := exec_hugi({"history", "--db", db_path, "--limit", "1"}, context.temp_allocator)
	if !ok {
		return "", false
	}
	for line in strings.split_lines(string(out), context.temp_allocator) {
		t := strings.trim_space(line)
		if len(t) == 0 || strings.has_prefix(t, "Commit") || strings.has_prefix(t, "-") {
			continue
		}
		if idx := strings.index_byte(t, '|'); idx > 0 {
			return strings.clone(strings.trim_space(t[:idx]), allocator), true
		}
	}
	return "", false
}

@(require_results)
render_bar_svg :: proc(
	title: string,
	subtitle: string,
	specs: []Bar_Spec,
	records: []Hugi_Record,
	out_path: string,
	allocator := context.allocator,
) -> bool {
	width, pad_l, pad_r, pad_t, pad_b, row_h := 960, 270, 230, 68, 42, 34
	matched := make([dynamic]struct{ spec: Bar_Spec, rec: Hugi_Record }, 0, len(specs), allocator)
	min_v, max_v := max(f64), 0.0
	for sp in specs {
		found := false
		var_rec: Hugi_Record
		for rec in records {
			if rec.full_name == sp.full_name || strings.has_prefix(rec.full_name, sp.full_name) {
				var_rec = rec
				found = true
				break
			}
		}
		if found && var_rec.p50_ns > 0 {
			append(&matched, struct{ spec: Bar_Spec, rec: Hugi_Record }{sp, var_rec})
			min_v = min(min_v, var_rec.p50_ns)
			max_v = max(max_v, var_rec.p50_ns)
		}
	}
	if len(matched) == 0 || max_v <= 0 {
		return false
	}

	ph := len(matched) * row_h + 12
	height := pad_t + ph + pad_b
	pw := width - pad_l - pad_r
	lo := int(math.floor(math.log10(min_v)))
	hi := int(math.ceil(math.log10(max_v)))
	if lo == hi { hi += 1 }

	x_ticks := make([]Svg_Tick_View, hi - lo + 1, allocator)
	for e := lo; e <= hi; e += 1 {
		t := f64(e - lo) / f64(hi - lo)
		x_ticks[e - lo] = Svg_Tick_View{
			pos   = fmt.aprintf("%.1f", f64(pad_l) + t * f64(pw), allocator = allocator),
			label = fmt_axis_ns(math.pow10(f64(e)), allocator),
		}
	}

	bars := make([]Bar_View, len(matched), allocator)
	for item, idx in matched {
		ry := pad_t + 10 + idx * row_h
		t := (math.log10(item.rec.p50_ns) - f64(lo)) / f64(hi - lo)
		w_bar := max(4.0, t * f64(pw))
		dur := fmt_ns(item.rec.p50_ns, context.temp_allocator)
		tp := fmt_tp_or_ops(item.rec, context.temp_allocator)
		bars[idx] = Bar_View{
			label    = item.spec.label,
			text_y   = fmt.aprintf("%.1f", f64(ry) + 16.0, allocator = allocator),
			rect_y   = fmt.aprintf("%.1f", f64(ry) + 3.0, allocator = allocator),
			width    = fmt.aprintf("%.1f", w_bar, allocator = allocator),
			val_x    = fmt.aprintf("%.1f", f64(pad_l) + w_bar + 8.0, allocator = allocator),
			val_y    = fmt.aprintf("%.1f", f64(ry) + 17.0, allocator = allocator),
			val_text = fmt.aprintf("%s (%s)", dur, tp, allocator = allocator),
			color    = item.spec.color,
		}
	}

	view := Bar_Chart_View{
		title       = title,
		subtitle    = subtitle,
		width       = width,
		height      = height,
		pad_l       = pad_l,
		pad_t       = pad_t,
		pw          = pw,
		ph          = ph,
		plot_bottom = pad_t + ph,
		label_x     = pad_l - 10,
		x_label_y   = pad_t + ph + 18,
		x_ticks     = x_ticks,
		bars        = bars,
	}
	sb := strings.builder_make(0, bar_chart_tmpl.approx_bytes, context.temp_allocator)
	if _, err := bar_chart_tmpl.with(strings.to_writer(&sb), view); err != nil {
		return false
	}
	return os.write_entire_file(out_path, transmute([]byte)strings.to_string(sb)) == nil
}

@(require_results)
strip_group_prefix :: proc(full_name: string, gkey: string) -> string {
	s := full_name
	p1 := fmt.tprintf("%s::", gkey)
	if strings.has_prefix(s, p1) {
		s = s[len(p1):]
	}
	p2 := fmt.tprintf("%s/", gkey)
	if strings.has_prefix(s, p2) {
		s = s[len(p2):]
	}
	if clean, ok := strings.replace_all(s, "`", "", context.temp_allocator); ok {
		s = clean
	}
	return s
}

@(require_results)
build_suite_report_view :: proc(records: []Hugi_Record, commit: string, allocator := context.allocator) -> Suite_Report_View {
	grouped := make(map[string][dynamic]Hugi_Record, context.temp_allocator)
	extra := make([dynamic]string, context.temp_allocator)
	total_samples := u64(0)
	for rec in records {
		total_samples += u64(max(rec.samples, 0))
		g := rec.group_name if len(rec.group_name) > 0 else "default"
		if g not_in grouped {
			grouped[g] = make([dynamic]Hugi_Record, context.temp_allocator)
			known := false
			for gm in GROUP_META { if gm.key == g { known = true; break } }
			if !known { append(&extra, g) }
		}
		append(&grouped[g], rec)
	}
	ordered := make([dynamic]string, 0, len(grouped), context.temp_allocator)
	for gm in GROUP_META { if gm.key in grouped { append(&ordered, gm.key) } }
	for eg in extra { append(&ordered, eg) }

	groups := make([]Report_Group_View, len(ordered), allocator)
	for gkey, gi in ordered {
		recs := grouped[gkey][:]
		title, desc := gkey, ""
		for gm in GROUP_META { if gm.key == gkey { title, desc = gm.title, gm.desc; break } }
		rows := make([]Report_Row_View, len(recs), allocator)
		for rec, ri in recs {
			short := strip_group_prefix(rec.full_name, gkey)
			alloc_str: string
			if rec.allocs_per_op > 0 || rec.alloc_bytes_per_op > 0 {
				alloc_str = fmt.aprintf("%.1f (%s)", rec.allocs_per_op, fmt_bytes(rec.alloc_bytes_per_op, context.temp_allocator), allocator = allocator)
			} else {
				alloc_str = strings.clone("**0**", allocator)
			}
			rows[ri] = Report_Row_View{
				name   = strings.clone(short, allocator),
				median = fmt_ns(rec.p50_ns, allocator),
				p95    = fmt_ns(rec.p95_ns, allocator),
				ops    = fmt_tp_or_ops(rec, allocator),
				cv     = fmt.aprintf("%.1f%%", rec.cv_pct, allocator = allocator),
				allocs = alloc_str,
			}
		}
		groups[gi] = Report_Group_View{
			title    = strings.clone(title, allocator),
			desc     = strings.clone(desc, allocator),
			has_desc = len(desc) > 0,
			count    = len(recs),
			rows     = rows,
		}
	}
	return Suite_Report_View{
		commit            = strings.clone(commit, allocator),
		total_benchmarks  = len(records),
		total_samples_str = fmt_commas_u64(total_samples, allocator),
		group_count       = len(groups),
		groups            = groups,
	}
}

@(require_results)
render_all :: proc(db_path: string, commit_arg: string, allocator := context.allocator) -> bool {
	if !os.exists(db_path) {
		return false
	}
	arena: vmem.Arena
	if vmem.arena_init_growing(&arena) != nil { return false }
	defer vmem.arena_destroy(&arena)
	arena_alloc := vmem.arena_allocator(&arena)

	commit := commit_arg
	if len(commit) == 0 {
		c, ok := latest_commit_from_hugi(db_path, arena_alloc)
		if !ok { return false }
		commit = c
	}
	raw, ok := exec_hugi({"export", "--db", db_path, "--commit", commit, "--format", "json", "--out", "-"}, arena_alloc)
	if !ok { return false }
	records: []Hugi_Record
	if json.unmarshal(raw, &records, allocator = arena_alloc) != nil || len(records) == 0 {
		return false
	}
	if !os.exists(RENDERS_DIR) && os.make_directory(RENDERS_DIR) != nil {
		return false
	}

	sub := fmt.tprintf("Commit %s · -o:speed -microarch:native", commit)

	s1 := [?]Bar_Spec{
		{"2h.", "2h Multi-Worker 4T Scan (1M)", PALETTE[1]},
		{"2f.", "2f Direct Worker Scan (1M)", PALETTE[1]},
		{"1f.", "1f COPY ... TO Sink (1M)", PALETTE[1]},
		{"2b.", "2b Selection Vector Scan (1M)", PALETTE[5]},
		{"2g.", "2g Arrow Export/Import (200K)", PALETTE[5]},
		{"2i.", "2i Cooperative v2_step_chunk", PALETTE[5]},
		{"2a.", "2a Zero-Copy Vector View (1M)", PALETTE[0]},
		{"2c.", "2c Arrow_Array_Stream (1M)", PALETTE[0]},
		{"1e.", "1e COPY ... FROM (1M)", PALETTE[0]},
		{"2d.", "2d reflect query_as Non-Null", PALETTE[3]},
		{"1g.", "1g Struct_Appender(T) (100K)", PALETTE[4]},
		{"1c.", "1c append_slice (100K rows)", PALETTE[4]},
		{"1b.", "1b Legacy V1 Appender (100K)", PALETTE[2]},
	}
	if !render_bar_svg("Vectorized Ingest vs Zero-Copy Scan & Arrow Bridge", sub, s1[:], records, fmt.tprintf("%s/ingest_and_scan_latency.svg", RENDERS_DIR), arena_alloc) {
		return false
	}

	s2 := [?]Bar_Spec{
		{"3d.", "3d Zero-Copy vector_reference", PALETTE[1]},
		{"3e.", "3e Flatten .OTHER -> .FLAT", PALETTE[1]},
		{"3c.", "3c duckdb_v2_vector_cast", PALETTE[1]},
		{"6d.", "6d UDF Pushdown Projection", PALETTE[5]},
		{"4d.", "4d Fixed ARRAY(DOUBLE, 4)", PALETTE[5]},
		{"4b.", "4b Native STRUCT(...) Child", PALETTE[5]},
		{"6e.", "6e UDF V2_Cast_Function (1M)", PALETTE[0]},
		{"4c.", "4c Nested LIST(BIGINT)", PALETTE[0]},
		{"6a.", "6a UDF Scalar odin_fma (1M)", PALETTE[0]},
		{"3f.", "3f 128-Bit Wire Codecs", PALETTE[3]},
		{"6c.", "6c UDF Aggregate odin_agg_sum", PALETTE[3]},
		{"6b.", "6b UDF odin_gen_series (1M)", PALETTE[3]},
		{"3a.", "3a V2_Bytes Inline <=12B", PALETTE[4]},
		{"3b.", "3b V2_Bytes Arena >12B", PALETTE[2]},
	}
	if !render_bar_svg("Native Vectors, Wire Codecs & Vectorized Odin UDFs", sub, s2[:], records, fmt.tprintf("%s/vector_bytes_and_udf.svg", RENDERS_DIR), arena_alloc) {
		return false
	}

	s3 := [?]Bar_Spec{
		{"5d.", "5d Native v2_tokenize_sql", PALETTE[1]},
		{"5c.", "5c sqllogic_parse_script", PALETTE[1]},
		{"5f.", "5f Quack SQL Builders", PALETTE[5]},
		{"5g.", "5g Reflection create_table_sql", PALETTE[0]},
		{"5a.", "5a DSL query_to_sql", PALETTE[0]},
		{"8a.", "8a VFS write_at + read_at", PALETTE[5]},
		{"5e.", "5e Catalog describe_table", PALETTE[3]},
		{"5b.", "5b Schema Codegen (Odin/CUE)", PALETTE[3]},
		{"8b.", "8b Telemetry Metrics + Sink", PALETTE[4]},
		{"7d.", "7d v2_with_transaction", PALETTE[4]},
		{"1a.", "1a V2 Prepared Statement Loop", PALETTE[2]},
		{"7b.", "7b v2_prepared_execute", PALETTE[2]},
		{"7a.", "7a Ad-Hoc v2_query", PALETTE[6]},
		{"7c.", "7c DSL query_execute_as", PALETTE[6]},
	}
	if !render_bar_svg("Query DSL Compilation, SQL Parser/Lexer, VFS & Transactions", sub, s3[:], records, fmt.tprintf("%s/dsl_and_point_tx.svg", RENDERS_DIR), arena_alloc) {
		return false
	}

	rep := build_suite_report_view(records, commit, arena_alloc)
	sb := strings.builder_make(0, suite_report_tmpl.approx_bytes, allocator)
	defer strings.builder_destroy(&sb)
	if _, err := suite_report_tmpl.with(strings.to_writer(&sb), rep); err != nil { return false }
	if os.write_entire_file(README_PATH, transmute([]byte)strings.to_string(sb)) != nil { return false }

	fmt.printfln("bench_render: rendered 3 SVGs and %d rows (%s) -> %s", rep.total_benchmarks, rep.commit, README_PATH)
	free_all(context.temp_allocator)
	return true
}

main :: proc() {
	commit := ""
	args := os.args[1:] if len(os.args) > 1 else nil
	for i := 0; i < len(args); i += 1 {
		if args[i] == "--commit" && i + 1 < len(args) {
			commit = args[i + 1]
			i += 1
		}
	}
	if !render_all(DEFAULT_DB_PATH, commit, context.allocator) {
		os.exit(1)
	}
}
