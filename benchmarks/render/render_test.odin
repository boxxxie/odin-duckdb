package bench_render

import "core:strings"
import "core:testing"

@(test)
test_render_report_and_bar :: proc(t: ^testing.T) {
	records := [?]Hugi_Record{
		{commit = "eed3bbe", group_name = "ingest", name = "1f", full_name = "1f. Export: Custom V2_Copy_Function COPY ... TO Sink (1M rows)", samples = 7, p50_ns = 3.24, p95_ns = 3.6, cv_pct = 18.1, ops_per_sec = 308_000_000, mb_per_sec = 4710.3, allocs_per_op = 0, alloc_bytes_per_op = 0},
		{commit = "eed3bbe", group_name = "bytes", name = "3d", full_name = "3d. Zero-Copy Alias: duckdb_v2_vector_reference (200K rows)", samples = 7, p50_ns = 0.01, p95_ns = 0.01, cv_pct = 10.0, ops_per_sec = 126_300_000_000, mb_per_sec = 2457131.9, allocs_per_op = 0, alloc_bytes_per_op = 0},
	}

	rep := build_suite_report_view(records[:], "eed3bbe", context.temp_allocator)
	testing.expect_value(t, rep.total_benchmarks, 2)
	testing.expect_value(t, rep.group_count, 2)

	sb := strings.builder_make(0, 1024, context.temp_allocator)
	_, err := suite_report_tmpl.with(strings.to_writer(&sb), rep)
	testing.expect(t, err == nil, "suite_report template renders without error")
	out := strings.to_string(sb)
	testing.expect(t, strings.contains(out, "<!-- BEGIN_BENCHMARK_TABLE -->"), "has benchmark table marker")
	testing.expect(t, strings.contains(out, "2.34 TB/s"), "formats TB/s cleanly")
	free_all(context.temp_allocator)
}
