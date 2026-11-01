package duckdb_tests

import "core:strings"
import "core:testing"
import "../duckdb"

@(test)
test_duckdb_open_and_prepared_appender :: proc(t: ^testing.T) {
	db, err, ok := duckdb.open("", low_memory = true)
	testing.expectf(t, ok, "Expected in-memory DuckDB open to succeed, got: %s", err)
	defer duckdb.close(&db)

	_, create_ok := duckdb.exec(&db, "CREATE TABLE items (id BIGINT, name VARCHAR, score DOUBLE);")
	testing.expect(t, create_ok, "Expected CREATE TABLE to succeed")

	// Test Appender API
	app: duckdb.duckdb_appender
	app_state := duckdb.duckdb_appender_create(db.conn, nil, "items", &app)
	testing.expect(t, app_state == .DuckDBSuccess, "Expected appender create to succeed")
	defer duckdb.duckdb_appender_destroy(&app)

	duckdb.duckdb_append_int64(app, 1)
	duckdb.duckdb_append_varchar(app, "quack_item")
	duckdb.duckdb_append_double(app, 99.5)
	duckdb.duckdb_appender_end_row(app)
	duckdb.duckdb_appender_flush(app)

	// Test Prepared Statement API
	stmt: duckdb.duckdb_prepared_statement
	prep_state := duckdb.duckdb_prepare(db.conn, "SELECT name, score FROM items WHERE id = $1", &stmt)
	testing.expect(t, prep_state == .DuckDBSuccess, "Expected prepare to succeed")
	defer duckdb.duckdb_destroy_prepare(&stmt)

	duckdb.duckdb_bind_int64(stmt, 1, 1)
	res: duckdb.duckdb_result
	exec_state := duckdb.duckdb_execute_prepared(stmt, &res)
	testing.expect(t, exec_state == .DuckDBSuccess, "Expected prepared execution to succeed")
	defer duckdb.duckdb_destroy_result(&res)

	testing.expect_value(t, duckdb.duckdb_row_count(&res), 1)

	val_c := duckdb.duckdb_value_varchar(&res, 0, 0)
	testing.expect(t, val_c != nil, "Expected non-null varchar")
	if val_c != nil {
		testing.expect_value(t, string(val_c), "quack_item")
		duckdb.duckdb_free(rawptr(val_c))
	}

	// Test Quack SQL builders
	serve_sql := duckdb.quack_serve_sql("quack:127.0.0.1:9494", "secret-tok", context.temp_allocator)
	testing.expect(t, strings.contains(serve_sql, "CALL quack_serve('quack:127.0.0.1:9494', token => 'secret-tok');"))

	attach_sql := duckdb.quack_attach_sql({
		endpoint    = "quack:127.0.0.1:9494",
		token       = "secret-tok",
		secret_name = "llim_quack",
		alias_name  = "llim_remote",
	}, context.temp_allocator)
	testing.expect(t, strings.contains(attach_sql, "TYPE quack"))
	testing.expect(t, strings.contains(attach_sql, "ATTACH IF NOT EXISTS 'quack:127.0.0.1:9494' AS llim_remote (TYPE quack);"))
}
