package duckdb

// ============================================================================
// DuckDB 2.0 C API v2 (`duckdb_v2_*`) Bindings & Helpers for Odin
// ============================================================================
// Authoritative Upstream References:
// - Header Specification:
//   - `duckdb_v2.h`
//   - `references/c/duckdb-capi-2.0/src/include/duckdb_v2.h`
// - Declarative YAML Specs:
//   - `references/c/duckdb-capi-2.0/api_spec/v2/`
// - Official C++20 Wrapper over C API v2:
//   - `references/c/duckdb-capi-2.0/tools/cpp/duckdb_cpp.hpp`
//   - `references/c/duckdb-capi-2.0/tools/cpp/duckdb_cpp.cpp`
// - C API v2 Test Harness & Helpers:
//   - `references/c/duckdb-capi-2.0/test/api/capi/v2/test_capi_v2.hpp`
//   - `references/c/duckdb-capi-2.0/test/api/capi/v2/test_capi_v2_bytes.cpp`
// - Node Neo C11 Probes:
//   - `references/node/duckdb-node-neo/tools/capi-v2/smoke_v2.c`
// ============================================================================

import "base:intrinsics"
import "core:c"
import "core:reflect"
import "core:strings"

when ODIN_OS == .Linux || ODIN_OS == .Darwin {
	foreign import libduckdb "system:duckdb"
} else when ODIN_OS == .Windows {
	foreign import libduckdb "duckdb.lib"
}

// ----------------------------------------------------------------------------
// Constants & Primitive Types (`duckdb_v2.h` lines 179-400)
// ----------------------------------------------------------------------------

V2_Idx :: u64
V2_Sel :: u32

V2_BYTES_INLINE_LENGTH :: 12

// ----------------------------------------------------------------------------
// Opaque Handles (`duckdb_v2.h` lines 229-364, 10986-10996, 11888-11890)
// ----------------------------------------------------------------------------
// Every `duckdb_v2_*_handle` in C is `typedef struct _duckdb_v2_* { void *internal_ptr; } *duckdb_v2_*_handle`.
// We use `distinct rawptr` in Odin to guarantee strict compile-time type safety across handles.

V2_Environment_Handle            :: distinct rawptr
V2_Instance_Handle               :: distinct rawptr
V2_Connection_Handle             :: distinct rawptr
V2_Config_Handle                 :: distinct rawptr
V2_Option_Handle                 :: distinct rawptr
V2_Error_Info_Handle             :: distinct rawptr
V2_Logical_Type_Handle           :: distinct rawptr
V2_Value_Handle                  :: distinct rawptr
V2_Result_Handle                 :: distinct rawptr
V2_Data_Chunk_Handle             :: distinct rawptr
V2_Vector_Handle                 :: distinct rawptr
V2_Arena_Handle                  :: distinct rawptr
V2_Context_Handle                :: distinct rawptr
V2_Factory_Handle                :: distinct rawptr
V2_Attach_Options_Handle         :: distinct rawptr
V2_Schema_Handle                 :: distinct rawptr
V2_Sql_Statement_Handle          :: distinct rawptr
V2_Statement_Iterator_Handle     :: distinct rawptr
V2_Prepared_Statement_Handle     :: distinct rawptr
V2_Column_Data_Collection_Handle :: distinct rawptr
V2_Column_Data_Collection_Append_State_Handle      :: distinct rawptr
V2_Column_Data_Collection_Shared_Scan_State_Handle :: distinct rawptr
V2_Column_Data_Collection_Worker_Scan_State_Handle :: distinct rawptr
V2_Arrow_Importer_Handle                           :: distinct rawptr
V2_Arrow_Exporter_Handle                           :: distinct rawptr
V2_Arrow_Result_Handle                             :: distinct rawptr

// Functions Common, Signatures & Docs Handles (`duckdb_v2.h` lines 3380-3840)
V2_Function_Bind_Info_Handle     :: distinct rawptr
V2_Function_Docs_Handle          :: distinct rawptr
V2_Function_Signature_Handle     :: distinct rawptr

// Scalar Function Handles (`duckdb_v2.h` lines 10330-10370)
V2_Scalar_Function_Handle                    :: distinct rawptr
V2_Scalar_Function_Resolve_Types_Info_Handle :: distinct rawptr
V2_Scalar_Function_Bind_Info_Handle          :: distinct rawptr
V2_Scalar_Function_Init_Info_Handle          :: distinct rawptr
V2_Scalar_Function_Exec_Info_Handle          :: distinct rawptr

// Table Function Handles (`duckdb_v2.h` lines 12427-12535)
V2_Table_Function_Handle                   :: distinct rawptr
V2_Table_Function_Bind_Info_Handle         :: distinct rawptr
V2_Table_Function_Init_Global_Info_Handle  :: distinct rawptr
V2_Table_Function_Init_Local_Info_Handle   :: distinct rawptr
V2_Table_Function_Exec_Info_Handle         :: distinct rawptr
V2_Table_Function_Progress_Info_Handle     :: distinct rawptr

// Aggregate Function Handles (`duckdb_v2.h` lines 4907-4970)
V2_Aggregate_Function_Handle               :: distinct rawptr
V2_Aggregate_Function_Bind_Info_Handle     :: distinct rawptr
V2_Aggregate_Function_Size_Info_Handle     :: distinct rawptr
V2_Aggregate_Function_Init_Info_Handle     :: distinct rawptr
V2_Aggregate_Function_Update_Info_Handle   :: distinct rawptr
V2_Aggregate_Function_Combine_Info_Handle  :: distinct rawptr
V2_Aggregate_Function_Finalize_Info_Handle :: distinct rawptr
V2_Aggregate_Function_Destroy_Info_Handle  :: distinct rawptr

// Qualified Name, Replacement Scan, Custom Type & Cast Function Handles (`duckdb_v2.h` lines 839-876, 2069-2071, 4220-4222, 9917-9928)
V2_Qname_Handle                   :: distinct rawptr
V2_Replacement_Scan_Handle        :: distinct rawptr
V2_Replacement_Scan_Info_Handle   :: distinct rawptr
V2_Custom_Type_Handle             :: distinct rawptr
V2_Cast_Function_Handle           :: distinct rawptr
V2_Cast_Function_Exec_Info_Handle :: distinct rawptr

// Catalog, Query Metrics, Tokenizer, Pragma, Custom Option & Log Sink Handles (`duckdb_v2.h`)
V2_Table_Description_Handle          :: distinct rawptr
V2_Column_Description_Handle         :: distinct rawptr
V2_Query_Metrics_Handle              :: distinct rawptr
V2_Query_Metrics_Node_Handle         :: distinct rawptr
V2_Token_Iterator_Handle             :: distinct rawptr
V2_Pragma_Function_Handle            :: distinct rawptr
V2_Pragma_Function_Query_Info_Handle :: distinct rawptr
V2_Custom_Option_Handle              :: distinct rawptr
V2_Custom_Option_Update_Info_Handle  :: distinct rawptr
V2_Log_Sink_Handle                   :: distinct rawptr
V2_Log_Sink_Write_Info_Handle        :: distinct rawptr
V2_Log_Sink_Flush_Info_Handle        :: distinct rawptr

// File System, Copy Function, Expression, Filter Pushdown, Multi-File, Macro & Extension Handles (`duckdb_v2.h`)
V2_File_System_Handle                             :: distinct rawptr
V2_File_Open_Options_Handle                       :: distinct rawptr
V2_File_Handle                                    :: distinct rawptr
V2_Copy_Function_Handle                           :: distinct rawptr
V2_Copy_To_Bind_Info_Handle                       :: distinct rawptr
V2_Copy_To_Batch_Size_Info_Handle                 :: distinct rawptr
V2_Copy_To_Init_Info_Handle                       :: distinct rawptr
V2_Copy_To_Batch_Info_Handle                      :: distinct rawptr
V2_Copy_To_Flush_Info_Handle                      :: distinct rawptr
V2_Copy_To_Finalize_Info_Handle                   :: distinct rawptr
V2_Copy_To_Statistics_Info_Handle                 :: distinct rawptr
V2_Copy_From_Bind_Info_Handle                     :: distinct rawptr
V2_Copy_From_Init_Global_Info_Handle              :: distinct rawptr
V2_Copy_From_Init_Local_Info_Handle               :: distinct rawptr
V2_Copy_From_Exec_Info_Handle                     :: distinct rawptr
V2_Copy_From_Progress_Info_Handle                 :: distinct rawptr
V2_Expression_Handle                              :: distinct rawptr
V2_Table_Function_Filter_Pushdown_Info_Handle     :: distinct rawptr
V2_Table_Function_Partition_Data_Info_Handle      :: distinct rawptr
V2_Table_Function_Partitioning_Info_Handle        :: distinct rawptr
V2_Table_Function_Claim_Batch_Info_Handle         :: distinct rawptr
V2_Table_Function_Get_Bind_Info_Info_Handle       :: distinct rawptr
V2_Multi_File_Function_Handle                     :: distinct rawptr
V2_Macro_Function_Handle                          :: distinct rawptr
V2_Extension_Handle                               :: distinct rawptr

// ----------------------------------------------------------------------------
// Arrow C Data Interface & Stream Interface (`duckdb_v2.h` lines 139-176)
// ----------------------------------------------------------------------------

Arrow_Schema :: struct {
	format:       cstring,
	name:         cstring,
	metadata:     [^]u8,
	flags:        i64,
	n_children:   i64,
	children:     [^]^Arrow_Schema,
	dictionary:   ^Arrow_Schema,
	release:      proc "c" (schema: ^Arrow_Schema),
	private_data: rawptr,
}

Arrow_Array :: struct {
	length:       i64,
	null_count:   i64,
	offset:       i64,
	n_buffers:    i64,
	n_children:   i64,
	buffers:      [^]rawptr,
	children:     [^]^Arrow_Array,
	dictionary:   ^Arrow_Array,
	release:      proc "c" (array: ^Arrow_Array),
	private_data: rawptr,
}

Arrow_Array_Stream :: struct {
	get_schema:     proc "c" (stream: ^Arrow_Array_Stream, out: ^Arrow_Schema) -> c.int,
	get_next:       proc "c" (stream: ^Arrow_Array_Stream, out: ^Arrow_Array) -> c.int,
	get_last_error: proc "c" (stream: ^Arrow_Array_Stream) -> cstring,
	release:        proc "c" (stream: ^Arrow_Array_Stream),
	private_data:   rawptr,
}

// ----------------------------------------------------------------------------
// Core Wire & View Structs (`duckdb_v2.h` lines 460-485, 11844-11870)
// ----------------------------------------------------------------------------

// Borrowed, length-delimited UTF-8 string view (`struct duckdb_v2_str`, `duckdb_v2.h` line 460).
// Bytes are NOT guaranteed to be null-terminated. `{nil, 0}` is the canonical empty view.
V2_Str :: struct {
	ptr: [^]u8,
	len: V2_Idx,
}

V2_Identifier :: V2_Str

// 16-byte transparent storage for VARCHAR, BLOB, BIT, and BIGNUM (`struct duckdb_v2_bytes`, `duckdb_v2.h` line 473).
// Cross-validated in `references/c/duckdb-capi-2.0/test/api/capi/v2/test_capi_v2_bytes.cpp` lines 19-46.
V2_Bytes_Pointer :: struct {
	length: u32,
	prefix: [4]u8,
	ptr:    [^]u8,
}

V2_Bytes_Inlined :: struct {
	length:  u32,
	inlined: [12]u8,
}

V2_Bytes :: struct #raw_union {
	pointer: V2_Bytes_Pointer,
	inlined: V2_Bytes_Inlined,
}

#assert(size_of(V2_Bytes) == 16)

V2_Varchar :: V2_Bytes
V2_Blob    :: V2_Bytes
V2_Bit     :: V2_Bytes
V2_Bignum  :: V2_Bytes

// Borrowed view over a vector's data, validity mask, and selection vector (`duckdb_v2.h` line 11844).
V2_Vector_View :: struct {
	data:     rawptr,
	validity: [^]u64,
	sel:      [^]V2_Sel,
	count:    V2_Idx,
}

V2_List_Entry :: struct {
	offset: V2_Idx,
	length: V2_Idx,
}

V2_Hugeint :: struct {
	lower: u64,
	upper: i64,
}

V2_Uhugeint :: struct {
	lower: u64,
	upper: u64,
}

V2_Interval :: struct {
	months: i32,
	days:   i32,
	micros: i64,
}

V2_Text_Sink_Fn :: #type proc "c" (text: ^V2_Str, user_data: rawptr, err: ^V2_Error_Info_Handle)

// Opaque resource handle bundling a pointer with optional destroy/equals callbacks (`struct duckdb_v2_opaque`, `duckdb_v2.h` line 491)
V2_Opaque_Destroy_Fn :: #type proc "c" (data: rawptr)
V2_Opaque_Equals_Fn  :: #type proc "c" (a: rawptr, b: rawptr) -> bool

V2_Opaque :: struct {
	ptr:     rawptr,
	destroy: V2_Opaque_Destroy_Fn,
	equals:  V2_Opaque_Equals_Fn,
}

// Table partition info (`struct duckdb_v2_table_partition_info`, `duckdb_v2.h` line 14375)
V2_Table_Partition_Info :: struct {
	batch_index: V2_Idx,
	row_start:   V2_Idx,
	row_count:   V2_Idx,
}

// Callback Typedefs (`duckdb_v2.h`)
V2_Scalar_Function_Resolve_Types_Callback_Fn :: #type proc "c" (info: V2_Function_Bind_Info_Handle, result: V2_Scalar_Function_Resolve_Types_Info_Handle, ctx: V2_Context_Handle, err: ^V2_Error_Info_Handle)
V2_Scalar_Function_Bind_Callback_Fn          :: #type proc "c" (info: V2_Function_Bind_Info_Handle, result: V2_Scalar_Function_Bind_Info_Handle, ctx: V2_Context_Handle, err: ^V2_Error_Info_Handle)
V2_Scalar_Function_Init_Callback_Fn          :: #type proc "c" (info: V2_Scalar_Function_Init_Info_Handle, ctx: V2_Context_Handle, err: ^V2_Error_Info_Handle)
V2_Scalar_Function_Exec_Callback_Fn          :: #type proc "c" (info: V2_Scalar_Function_Exec_Info_Handle, ctx: V2_Context_Handle, err: ^V2_Error_Info_Handle)

V2_Table_Function_Bind_Callback_Fn           :: #type proc "c" (info: V2_Function_Bind_Info_Handle, result: V2_Table_Function_Bind_Info_Handle, ctx: V2_Context_Handle, err: ^V2_Error_Info_Handle)
V2_Table_Function_Init_Global_Callback_Fn    :: #type proc "c" (info: V2_Table_Function_Init_Global_Info_Handle, ctx: V2_Context_Handle, err: ^V2_Error_Info_Handle)
V2_Table_Function_Init_Local_Callback_Fn     :: #type proc "c" (info: V2_Table_Function_Init_Local_Info_Handle, ctx: V2_Context_Handle, err: ^V2_Error_Info_Handle)
V2_Table_Function_Exec_Callback_Fn           :: #type proc "c" (info: V2_Table_Function_Exec_Info_Handle, ctx: V2_Context_Handle, err: ^V2_Error_Info_Handle)
V2_Table_Function_Progress_Callback_Fn       :: #type proc "c" (info: V2_Table_Function_Progress_Info_Handle, ctx: V2_Context_Handle, err: ^V2_Error_Info_Handle)

V2_Aggregate_Function_Bind_Callback_Fn       :: #type proc "c" (info: V2_Function_Bind_Info_Handle, result: V2_Aggregate_Function_Bind_Info_Handle, ctx: V2_Context_Handle, err: ^V2_Error_Info_Handle)
V2_Aggregate_Function_Size_Callback_Fn       :: #type proc "c" (info: V2_Aggregate_Function_Size_Info_Handle, err: ^V2_Error_Info_Handle)
V2_Aggregate_Function_Init_Callback_Fn       :: #type proc "c" (info: V2_Aggregate_Function_Init_Info_Handle, err: ^V2_Error_Info_Handle)
V2_Aggregate_Function_Update_Callback_Fn     :: #type proc "c" (info: V2_Aggregate_Function_Update_Info_Handle, err: ^V2_Error_Info_Handle)
V2_Aggregate_Function_Combine_Callback_Fn    :: #type proc "c" (info: V2_Aggregate_Function_Combine_Info_Handle, err: ^V2_Error_Info_Handle)
V2_Aggregate_Function_Finalize_Callback_Fn   :: #type proc "c" (info: V2_Aggregate_Function_Finalize_Info_Handle, err: ^V2_Error_Info_Handle)
V2_Aggregate_Function_Destroy_Callback_Fn    :: #type proc "c" (info: V2_Aggregate_Function_Destroy_Info_Handle, err: ^V2_Error_Info_Handle)

V2_Replacement_Scan_Callback_Fn              :: #type proc "c" (info: V2_Replacement_Scan_Info_Handle, ctx: V2_Context_Handle, err: ^V2_Error_Info_Handle)
V2_Cast_Function_Exec_Callback_Fn            :: #type proc "c" (info: V2_Cast_Function_Exec_Info_Handle, ctx: V2_Context_Handle, err: ^V2_Error_Info_Handle)
V2_Pragma_Function_Query_Callback_Fn         :: #type proc "c" (info: V2_Function_Bind_Info_Handle, result: V2_Pragma_Function_Query_Info_Handle, ctx: V2_Context_Handle, err: ^V2_Error_Info_Handle)
V2_Pragma_Function_Exec_Callback_Fn          :: #type proc "c" (info: V2_Function_Bind_Info_Handle, ctx: V2_Context_Handle, err: ^V2_Error_Info_Handle)
V2_Custom_Option_Update_Callback_Fn          :: #type proc "c" (info: V2_Custom_Option_Update_Info_Handle, ctx: V2_Context_Handle, err: ^V2_Error_Info_Handle)
V2_Log_Sink_Write_Callback_Fn                :: #type proc "c" (info: V2_Log_Sink_Write_Info_Handle, user_data: rawptr, timestamp: i64, level: V2_Log_Level, scope: V2_Log_Scope, type: ^V2_Str, message: ^V2_Str, err: ^V2_Error_Info_Handle)
V2_Log_Sink_Flush_Callback_Fn                :: #type proc "c" (info: V2_Log_Sink_Flush_Info_Handle, user_data: rawptr, err: ^V2_Error_Info_Handle)

V2_File_System_Path_Glob_Callback_Fn         :: #type proc "c" (path: ^V2_Str, user_data: rawptr, err: ^V2_Error_Info_Handle)
V2_Copy_To_Bind_Callback_Fn                  :: #type proc "c" (info: V2_Copy_To_Bind_Info_Handle, ctx: V2_Context_Handle, err: ^V2_Error_Info_Handle)
V2_Copy_To_Batch_Size_Callback_Fn            :: #type proc "c" (info: V2_Copy_To_Batch_Size_Info_Handle, ctx: V2_Context_Handle, err: ^V2_Error_Info_Handle)
V2_Copy_To_Init_Callback_Fn                  :: #type proc "c" (info: V2_Copy_To_Init_Info_Handle, ctx: V2_Context_Handle, err: ^V2_Error_Info_Handle)
V2_Copy_To_Batch_Callback_Fn                 :: #type proc "c" (info: V2_Copy_To_Batch_Info_Handle, ctx: V2_Context_Handle, err: ^V2_Error_Info_Handle)
V2_Copy_To_Flush_Callback_Fn                 :: #type proc "c" (info: V2_Copy_To_Flush_Info_Handle, ctx: V2_Context_Handle, err: ^V2_Error_Info_Handle)
V2_Copy_To_Finalize_Callback_Fn              :: #type proc "c" (info: V2_Copy_To_Finalize_Info_Handle, ctx: V2_Context_Handle, err: ^V2_Error_Info_Handle)
V2_Copy_To_Statistics_Callback_Fn            :: #type proc "c" (info: V2_Copy_To_Statistics_Info_Handle, ctx: V2_Context_Handle, err: ^V2_Error_Info_Handle)
V2_Copy_From_Bind_Callback_Fn                :: #type proc "c" (info: V2_Copy_From_Bind_Info_Handle, ctx: V2_Context_Handle, err: ^V2_Error_Info_Handle)
V2_Copy_From_Init_Global_Callback_Fn         :: #type proc "c" (info: V2_Copy_From_Init_Global_Info_Handle, ctx: V2_Context_Handle, err: ^V2_Error_Info_Handle)
V2_Copy_From_Init_Local_Callback_Fn          :: #type proc "c" (info: V2_Copy_From_Init_Local_Info_Handle, ctx: V2_Context_Handle, err: ^V2_Error_Info_Handle)
V2_Copy_From_Exec_Callback_Fn                :: #type proc "c" (info: V2_Copy_From_Exec_Info_Handle, ctx: V2_Context_Handle, err: ^V2_Error_Info_Handle)
V2_Copy_From_Progress_Callback_Fn            :: #type proc "c" (info: V2_Copy_From_Progress_Info_Handle, ctx: V2_Context_Handle, err: ^V2_Error_Info_Handle)
V2_Table_Function_Filter_Pushdown_Callback_Fn :: #type proc "c" (info: V2_Table_Function_Filter_Pushdown_Info_Handle, ctx: V2_Context_Handle, err: ^V2_Error_Info_Handle)
V2_Table_Function_Partition_Data_Callback_Fn  :: #type proc "c" (info: V2_Table_Function_Partition_Data_Info_Handle, ctx: V2_Context_Handle, err: ^V2_Error_Info_Handle)
V2_Table_Function_Partitioning_Callback_Fn    :: #type proc "c" (info: V2_Table_Function_Partitioning_Info_Handle, ctx: V2_Context_Handle, err: ^V2_Error_Info_Handle)
V2_Table_Function_Claim_Batch_Callback_Fn     :: #type proc "c" (info: V2_Table_Function_Claim_Batch_Info_Handle, ctx: V2_Context_Handle, err: ^V2_Error_Info_Handle)
V2_Table_Function_Get_Bind_Info_Callback_Fn   :: #type proc "c" (info: V2_Table_Function_Get_Bind_Info_Info_Handle, ctx: V2_Context_Handle, err: ^V2_Error_Info_Handle)
V2_Extension_Get_Api_Fn                      :: #type proc "c" (extension: V2_Extension_Handle, version: cstring) -> rawptr

V2_Extension_Input :: struct {
	get_api:   V2_Extension_Get_Api_Fn,
	extension: V2_Extension_Handle,
	ctx:       V2_Context_Handle,
	err:       ^V2_Error_Info_Handle,
}

// ----------------------------------------------------------------------------
// Enums (`duckdb_v2.h` lines 504-658, 8955-9036, 10939-10976, 11263-11276, 12051-12076)
// ----------------------------------------------------------------------------

V2_Error :: enum c.int {
	NONE                         = 0,
	API                          = 1,
	IO_FILE_NOT_FOUND            = 1001,
	IO_READ_FAILURE              = 1002,
	IO_EOF                       = 1003,
	IO_GENERAL                   = 1004,
	IO_NETWORK                   = 1005,
	IO_HTTP                      = 1006,
	INPUT_INVALID                = 2001,
	INPUT_PARAMETER_INVALID      = 2002,
	INPUT_OUT_OF_RANGE           = 2003,
	INPUT_OBJECT_SIZE            = 2004,
	INPUT_METADATA_DEFERRED      = 2005,
	RESOURCE_IN_USE              = 3001,
	RESOURCE_OUT_OF_MEMORY       = 3002,
	RESOURCE_CONNECTION          = 3003,
	RESOURCE_DEPENDENCY          = 3004,
	RESOURCE_MISSING_EXTENSION   = 3005,
	RESOURCE_AUTOLOAD            = 3006,
	TYPE_CONVERSION              = 4001,
	TYPE_UNKNOWN                 = 4002,
	TYPE_INVALID                 = 4003,
	TYPE_MISMATCH                = 4004,
	TYPE_DECIMAL                 = 4005,
	TYPE_DIVIDE_BY_ZERO          = 4006,
	QUERY_PARSER                 = 5001,
	QUERY_SYNTAX                 = 5002,
	QUERY_BINDER                 = 5003,
	QUERY_PLANNER                = 5004,
	QUERY_OPTIMIZER              = 5005,
	QUERY_EXPRESSION             = 5006,
	QUERY_EXECUTOR               = 5007,
	QUERY_SCHEDULER              = 5008,
	QUERY_NOT_IMPLEMENTED        = 5009,
	QUERY_PARAMETER_NOT_RESOLVED = 5010,
	QUERY_PARAMETER_NOT_ALLOWED  = 5011,
	DATABASE_CATALOG             = 6001,
	DATABASE_TRANSACTION         = 6002,
	DATABASE_CONSTRAINT          = 6003,
	DATABASE_INDEX               = 6004,
	DATABASE_SEQUENCE            = 6005,
	DATABASE_STATISTICS          = 6006,
	DATABASE_SERIALIZATION       = 6007,
	CONFIGURATION_SETTINGS       = 7001,
	CONFIGURATION_INVALID        = 7002,
	CONFIGURATION_PERMISSION     = 7003,
	RUNTIME_INTERNAL             = 8001,
	RUNTIME_FATAL                = 8002,
	RUNTIME_INTERRUPT            = 8003,
	RUNTIME_NULL_POINTER         = 8004,
}

V2_Logical_Type_Id :: enum c.int {
	INVALID         = 0,
	SQLNULL         = 1,
	UNKNOWN         = 2,
	ANY             = 3,
	TYPE            = 6,
	BOOLEAN         = 10,
	TINYINT         = 11,
	SMALLINT        = 12,
	INTEGER         = 13,
	BIGINT          = 14,
	DATE            = 15,
	TIME            = 16,
	TIMESTAMP_SEC   = 17,
	TIMESTAMP_MS    = 18,
	TIMESTAMP       = 19,
	TIMESTAMP_NS    = 20,
	DECIMAL         = 21,
	FLOAT           = 22,
	DOUBLE          = 23,
	VARCHAR         = 25,
	BLOB            = 26,
	INTERVAL        = 27,
	UTINYINT        = 28,
	USMALLINT       = 29,
	UINTEGER        = 30,
	UBIGINT         = 31,
	TIMESTAMP_TZ    = 32,
	TIMESTAMP_TZ_NS = 33,
	TIME_TZ         = 34,
	TIME_NS         = 35,
	BIT             = 36,
	BIGNUM          = 39,
	UHUGEINT        = 49,
	HUGEINT         = 50,
	UUID            = 54,
	GEOMETRY        = 60,
	STRUCT          = 100,
	LIST            = 101,
	MAP             = 102,
	ENUM            = 104,
	UNION           = 107,
	ARRAY           = 108,
	VARIANT         = 109,
	TUPLE           = 110,
}

V2_Statement_Type :: enum c.int {
	INVALID           = 0,
	SELECT            = 1,
	INSERT            = 2,
	UPDATE            = 3,
	CREATE            = 4,
	DELETE            = 5,
	PREPARE           = 6,
	EXECUTE           = 7,
	ALTER             = 8,
	TRANSACTION       = 9,
	COPY              = 10,
	ANALYZE           = 11,
	VARIABLE_SET      = 12,
	CREATE_FUNC       = 13,
	EXPLAIN           = 14,
	DROP              = 15,
	EXPORT            = 16,
	PRAGMA            = 17,
	VACUUM            = 18,
	CALL              = 19,
	SET               = 20,
	LOAD              = 21,
	RELATION          = 22,
	EXTENSION         = 23,
	LOGICAL_PLAN      = 24,
	ATTACH            = 25,
	DETACH            = 26,
	MULTI             = 27,
	COPY_DATABASE     = 28,
	UPDATE_EXTENSIONS = 29,
	MERGE_INTO        = 30,
	CONNECT           = 31,
	DISCONNECT        = 32,
	EXTERNAL_RESOURCE = 33,
	PASSTHROUGH       = 34,
}

V2_Vector_Type :: enum c.int {
	OTHER      = 0, // Covers FSST / SEQUENCE / SHREDDED — call `duckdb_v2_vector_flatten` first
	FLAT       = 1,
	CONSTANT   = 2,
	DICTIONARY = 3,
}

V2_Result_Type :: enum c.int {
	QUERY_RESULT = 0,
	CHANGED_ROWS = 1,
	NOTHING      = 2,
}

V2_Result_Step_Status :: enum c.int {
	WAITING   = 0,
	CHUNK     = 1,
	FINISHED  = 2,
	CANCELLED = 3,
}

V2_Cast_Mode :: enum c.int {
	NORMAL = 0,
	TRY    = 1,
}

V2_Setting_Scope :: enum c.int {
	DEFAULT = 0,
	GLOBAL  = 1,
	SESSION = 2,
}

V2_Function_Parameter_Kind :: enum c.int {
	POSITIONAL_ONLY     = 0,
	STANDARD            = 1,
	POSITIONAL_VARIADIC = 2,
	NAMED_ONLY          = 3,
	NAMED_VARIADIC      = 4,
}

V2_Function_Property_Key :: enum c.int {
	STABILITY              = 65536,  // 0x010000
	NULL_HANDLING          = 65792,  // 0x010100
	FALLIBILITY            = 66048,  // 0x010200
	COLLATION_HANDLING     = 66304,  // 0x010300
	AGG_ORDER_DEPENDENT    = 196608, // 0x030000
	AGG_DISTINCT_DEPENDENT = 196864, // 0x030100
}

V2_Function_Property_Value :: enum c.int {
	STABILITY_CONSISTENT               = 65536,
	STABILITY_VOLATILE                 = 65537,
	STABILITY_CONSISTENT_WITHIN_QUERY  = 65538,
	NULL_HANDLING_DEFAULT              = 65792,
	NULL_HANDLING_SPECIAL              = 65793,
	FALLIBILITY_INFALLIBLE             = 66048,
	FALLIBILITY_FALLIBLE               = 66049,
	COLLATION_HANDLING_PROPAGATE       = 66304,
	COLLATION_HANDLING_PUSH_COMBINABLE = 66305,
	COLLATION_HANDLING_IGNORE          = 66306,
	AGG_ORDER_DEPENDENT_YES            = 196608,
	AGG_ORDER_DEPENDENT_NO             = 196609,
	AGG_DISTINCT_DEPENDENT_YES         = 196864,
	AGG_DISTINCT_DEPENDENT_NO          = 196865,
}

V2_Order_Preservation :: enum c.int {
	NO_ORDER          = 0,
	INSERTION_ORDER   = 1,
	PREFER_INSERTION  = 2,
}

V2_Log_Level :: enum c.int {
	TRACE   = 10,
	DEBUG   = 20,
	INFO    = 30,
	WARNING = 40,
	ERROR   = 50,
	FATAL   = 60,
}

V2_Log_Scope :: enum c.int {
	DATABASE   = 10,
	CONNECTION = 20,
	THREAD     = 30,
}

V2_Token_Type :: enum c.int {
	INVALID        = 0,
	KEYWORD        = 1,
	IDENTIFIER     = 2,
	STRING_LITERAL = 3,
	NUMBER_LITERAL = 4,
	OPERATOR       = 5,
	COMMENT        = 6,
	TERMINATOR     = 7,
	END_OF_INPUT   = 8,
}

V2_File_Flag :: enum c.int {
	INVALID             = 0,
	READ                = 1,
	WRITE               = 2,
	CREATE              = 3,
	CREATE_NEW          = 4,
	APPEND              = 5,
	EXCLUSIVE_CREATE    = 6,
	PARALLEL_ACCESS     = 7,
	EXTERNAL_FILE_CACHE = 8,
}

V2_Expression_Type :: enum c.int {
	INVALID                    = 0,
	OPERATOR_CAST              = 12,
	OPERATOR_NOT               = 13,
	OPERATOR_IS_NULL           = 14,
	OPERATOR_IS_NOT_NULL       = 15,
	COMPARE_EQUAL              = 25,
	COMPARE_NOTEQUAL           = 26,
	COMPARE_LESSTHAN           = 27,
	COMPARE_GREATERTHAN        = 28,
	COMPARE_LESSTHANOREQUALTO  = 29,
	COMPARE_GREATERTHANOREQUALTO = 30,
	COMPARE_IN                 = 35,
	COMPARE_NOT_IN             = 36,
	COMPARE_DISTINCT_FROM      = 37,
	COMPARE_BETWEEN            = 38,
	COMPARE_NOT_DISTINCT_FROM  = 40,
	CONJUNCTION_AND            = 50,
	CONJUNCTION_OR             = 51,
	VALUE_CONSTANT             = 75,
	VALUE_PARAMETER            = 76,
	BOUND_FUNCTION             = 141,
	CASE_EXPR                  = 150,
	OPERATOR_COALESCE          = 152,
	BOUND_COLUMN_REF           = 228,
}

V2_Macro_Function_Type :: enum c.int {
	SCALAR = 0,
	TABLE  = 1,
}

V2_Table_Partition_Kind :: enum c.int {
	NOT_PARTITIONED         = 0,
	SINGLE_VALUE_PARTITIONS = 1,
	OVERLAPPING_PARTITIONS  = 2,
	DISJOINT_PARTITIONS     = 3,
}

// ----------------------------------------------------------------------------
// Foreign C API v2 Declarations (`duckdb_v2.h`)
// ----------------------------------------------------------------------------

@(default_calling_convention = "c")
foreign libduckdb {
	// Environment (`duckdb_v2.h` lines 2416-2454)
	duckdb_v2_environment_create             :: proc(out_env: ^V2_Environment_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_environment_destroy            :: proc(env: ^V2_Environment_Handle) -> V2_Error ---
	duckdb_v2_environment_get_instance_count :: proc(env: V2_Environment_Handle, out_count: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---

	// Error Info (`duckdb_v2.h` lines 2489-2580)
	duckdb_v2_error_info_get_code     :: proc(info: V2_Error_Info_Handle, out_code: ^V2_Error) -> V2_Error ---
	duckdb_v2_error_info_get_text     :: proc(info: V2_Error_Info_Handle, out_text: ^V2_Str) -> V2_Error ---
	duckdb_v2_error_info_get_raw_text :: proc(info: V2_Error_Info_Handle, out_raw_text: ^V2_Str) -> V2_Error ---
	duckdb_v2_error_info_set_code     :: proc(info: V2_Error_Info_Handle, code: V2_Error) -> V2_Error ---
	duckdb_v2_error_info_set_text     :: proc(info: V2_Error_Info_Handle, text: ^V2_Str) -> V2_Error ---
	duckdb_v2_error_info_destroy      :: proc(info: ^V2_Error_Info_Handle) -> V2_Error ---

	// Instance & Connection (`duckdb_v2.h` lines 1980-2046, 2674-2698, 3864-4083)
	duckdb_v2_library_version              :: proc(out_version: ^V2_Str, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_instance_create              :: proc(env: V2_Environment_Handle, out_instance: ^V2_Instance_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_instance_create_with_options :: proc(env: V2_Environment_Handle, option_names: [^]V2_Str, option_values: [^]V2_Str, option_count: V2_Idx, out_instance: ^V2_Instance_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_instance_destroy             :: proc(instance: ^V2_Instance_Handle) -> V2_Error ---
	duckdb_v2_instance_attach              :: proc(instance: V2_Instance_Handle, name: ^V2_Identifier, path: ^V2_Str, options: V2_Attach_Options_Handle, make_default: bool, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_instance_detach              :: proc(instance: V2_Instance_Handle, name: ^V2_Identifier, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_instance_set_default         :: proc(instance: V2_Instance_Handle, name: ^V2_Identifier, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_instance_get_factory         :: proc(instance: V2_Instance_Handle, out_factory: ^V2_Factory_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_attach_options_create        :: proc(instance: V2_Instance_Handle, out_options: ^V2_Attach_Options_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_attach_options_set           :: proc(options: V2_Attach_Options_Handle, key: ^V2_Identifier, setting: ^V2_Str, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_attach_options_destroy       :: proc(options: ^V2_Attach_Options_Handle) -> V2_Error ---
	duckdb_v2_connection_create            :: proc(instance: V2_Instance_Handle, out_conn: ^V2_Connection_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_connection_destroy           :: proc(conn: ^V2_Connection_Handle) -> V2_Error ---
	duckdb_v2_connection_interrupt         :: proc(conn: V2_Connection_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_connection_progress_get      :: proc(conn: V2_Connection_Handle, out_percentage: ^f64, out_rows_processed: ^u64, out_total_rows_to_process: ^u64, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_connection_get_factory       :: proc(conn: V2_Connection_Handle, out_factory: ^V2_Factory_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_context_get_factory          :: proc(ctx: V2_Context_Handle, out_factory: ^V2_Factory_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---

	// Configuration & Options (`duckdb_v2.h` lines 1580-1944)
	duckdb_v2_instance_get_config           :: proc(instance: V2_Instance_Handle, out_config: ^V2_Config_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_connection_get_config         :: proc(conn: V2_Connection_Handle, out_config: ^V2_Config_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_context_get_config            :: proc(ctx: V2_Context_Handle, out_config: ^V2_Config_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_config_get_option_count       :: proc(config: V2_Config_Handle, out_count: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_config_get_option_by_index    :: proc(config: V2_Config_Handle, index: V2_Idx, out_option: ^V2_Option_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_config_get_option_by_name     :: proc(config: V2_Config_Handle, name: ^V2_Identifier, out_option: ^V2_Option_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_option_get_name               :: proc(option: V2_Option_Handle, out_name: ^V2_Identifier, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_option_get_description        :: proc(option: V2_Option_Handle, out_description: ^V2_Str, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_option_get_default_value      :: proc(option: V2_Option_Handle, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_option_get_default_scope      :: proc(option: V2_Option_Handle, out_scope: ^V2_Setting_Scope, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_option_supports_scope         :: proc(option: V2_Option_Handle, scope: V2_Setting_Scope, out_supported: ^bool, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_option_get_alias_count        :: proc(option: V2_Option_Handle, out_count: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_option_get_alias              :: proc(option: V2_Option_Handle, index: V2_Idx, out_alias: ^V2_Identifier, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_option_destroy                :: proc(option: ^V2_Option_Handle) -> V2_Error ---
	duckdb_v2_config_get_option_value       :: proc(config: V2_Config_Handle, name: ^V2_Identifier, out_value: ^V2_Value_Handle, out_scope: ^V2_Setting_Scope, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_config_set_option_value       :: proc(config: V2_Config_Handle, name: ^V2_Identifier, value: V2_Value_Handle, scope: V2_Setting_Scope, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_config_set_option_text        :: proc(config: V2_Config_Handle, name: ^V2_Identifier, setting: ^V2_Str, scope: V2_Setting_Scope, err: ^V2_Error_Info_Handle) -> V2_Error ---

	// Schema & Logical Type (`duckdb_v2.h` lines 4703-4744, 9084-9452)
	duckdb_v2_schema_get_count              :: proc(schema: V2_Schema_Handle, out_count: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_schema_get_field              :: proc(schema: V2_Schema_Handle, index: V2_Idx, out_name: ^V2_Identifier, out_type: ^V2_Logical_Type_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_schema_destroy                :: proc(schema: ^V2_Schema_Handle) -> V2_Error ---
	duckdb_v2_factory_create_type_from_id   :: proc(factory: V2_Factory_Handle, type_id: V2_Logical_Type_Id, param_names: [^]V2_Identifier, param_values: [^]V2_Value_Handle, param_count: V2_Idx, out_type: ^V2_Logical_Type_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_factory_create_type_from_name :: proc(factory: V2_Factory_Handle, type_name: V2_Qname_Handle, param_names: [^]V2_Identifier, param_values: [^]V2_Value_Handle, param_count: V2_Idx, out_type: ^V2_Logical_Type_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_factory_create_type_from_text :: proc(factory: V2_Factory_Handle, text: ^V2_Str, out_type: ^V2_Logical_Type_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_factory_create_type_with_alias :: proc(factory: V2_Factory_Handle, type: V2_Logical_Type_Handle, alias: ^V2_Identifier, out_type: ^V2_Logical_Type_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_factory_create_common_type    :: proc(factory: V2_Factory_Handle, types: [^]V2_Logical_Type_Handle, type_count: V2_Idx, out_type: ^V2_Logical_Type_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_logical_type_copy             :: proc(type: V2_Logical_Type_Handle, out_type: ^V2_Logical_Type_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_logical_type_destroy          :: proc(type: ^V2_Logical_Type_Handle) -> V2_Error ---
	duckdb_v2_logical_type_is_equal         :: proc(left: V2_Logical_Type_Handle, right: V2_Logical_Type_Handle, result: ^bool, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_logical_type_get_id           :: proc(type: V2_Logical_Type_Handle, out_id: ^V2_Logical_Type_Id, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_logical_type_get_name         :: proc(type: V2_Logical_Type_Handle, out_name: ^V2_Identifier, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_logical_type_get_param_count  :: proc(type: V2_Logical_Type_Handle, out_count: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_logical_type_get_param        :: proc(type: V2_Logical_Type_Handle, index: V2_Idx, out_name: ^V2_Identifier, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_logical_type_to_text          :: proc(type: V2_Logical_Type_Handle, out_text: [^]u8, out_capacity: V2_Idx, out_length: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---

	// SQL Statement Parsing, Binding,Prepared & Execution (`duckdb_v2.h` lines 11022-11248, 11935-12036, 12140-12386)
	duckdb_v2_parse_sql                        :: proc(conn: V2_Connection_Handle, sql: cstring, out_iterator: ^V2_Statement_Iterator_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_statement_iterator_next          :: proc(iterator: V2_Statement_Iterator_Handle, out_statement: ^V2_Sql_Statement_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_statement_iterator_destroy       :: proc(iterator: ^V2_Statement_Iterator_Handle) -> V2_Error ---
	duckdb_v2_statement_bind                   :: proc(conn: V2_Connection_Handle, statement: V2_Sql_Statement_Handle, out_schema: ^V2_Schema_Handle, out_parameters: ^V2_Schema_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_statement_add_collection         :: proc(statement: V2_Sql_Statement_Handle, name: ^V2_Identifier, collection: V2_Column_Data_Collection_Handle, column_names: [^]V2_Identifier, column_count: V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_sql_statement_get_type           :: proc(statement: V2_Sql_Statement_Handle, out_type: ^V2_Statement_Type, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_sql_statement_get_text           :: proc(statement: V2_Sql_Statement_Handle, out_text: ^V2_Str, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_sql_statement_get_parameter_count :: proc(statement: V2_Sql_Statement_Handle, out_count: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_sql_statement_get_parameter_name :: proc(statement: V2_Sql_Statement_Handle, index: V2_Idx, out_name: ^V2_Identifier, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_sql_statement_destroy            :: proc(statement: ^V2_Sql_Statement_Handle) -> V2_Error ---

	duckdb_v2_prepared_statement_create        :: proc(conn: V2_Connection_Handle, statement: V2_Sql_Statement_Handle, require_cacheable: bool, out_prepared: ^V2_Prepared_Statement_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_prepared_statement_execute       :: proc(prepared: V2_Prepared_Statement_Handle, parameter_names: [^]V2_Identifier, parameter_values: [^]V2_Value_Handle, parameter_count: V2_Idx, out_result: ^V2_Result_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_prepared_statement_reuses_plan   :: proc(prepared: V2_Prepared_Statement_Handle, out_reuses: ^bool, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_prepared_statement_destroy       :: proc(prepared: ^V2_Prepared_Statement_Handle) -> V2_Error ---

	duckdb_v2_statement_execute                :: proc(conn: V2_Connection_Handle, statement: V2_Sql_Statement_Handle, parameter_names: [^]V2_Identifier, parameter_values: [^]V2_Value_Handle, parameter_count: V2_Idx, out_result: ^V2_Result_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_result_destroy                   :: proc(result: ^V2_Result_Handle) -> V2_Error ---
	duckdb_v2_result_step                      :: proc(result: V2_Result_Handle, out_chunk: ^V2_Data_Chunk_Handle, out_status: ^V2_Result_Step_Status, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_result_fetch_chunk               :: proc(result: V2_Result_Handle, out_chunk: ^V2_Data_Chunk_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_result_wait                      :: proc(result: V2_Result_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_result_render_box                :: proc(result: ^V2_Result_Handle, max_rows: V2_Idx, max_width: V2_Idx, max_col_width: V2_Idx, null_value: ^V2_Str, render_mode: V2_Idx, limit: V2_Idx, sink: V2_Text_Sink_Fn, user_data: rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_result_drain                     :: proc(result: V2_Result_Handle, out_rows_changed: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_result_get_result_type           :: proc(result: V2_Result_Handle, out_type: ^V2_Result_Type, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_result_get_statement_type        :: proc(result: V2_Result_Handle, out_type: ^V2_Statement_Type, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_result_get_schema                :: proc(result: V2_Result_Handle, out_schema: ^V2_Schema_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---

	// DataChunk, Vector & Arena (`duckdb_v2.h` lines 823-825, 2248-2384, 11313-11840)
	duckdb_v2_arena_allocate                   :: proc(arena: V2_Arena_Handle, byte_len: V2_Idx, out_ptr: ^[^]u8, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_data_chunk_create                :: proc(factory: V2_Factory_Handle, types: [^]V2_Logical_Type_Handle, column_count: V2_Idx, out_chunk: ^V2_Data_Chunk_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_data_chunk_copy                  :: proc(factory: V2_Factory_Handle, chunk: V2_Data_Chunk_Handle, out_chunk: ^V2_Data_Chunk_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_data_chunk_destroy               :: proc(chunk: ^V2_Data_Chunk_Handle) -> V2_Error ---
	duckdb_v2_data_chunk_clear                 :: proc(chunk: V2_Data_Chunk_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_data_chunk_get_size              :: proc(chunk: V2_Data_Chunk_Handle, out_size: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_data_chunk_get_capacity          :: proc(chunk: V2_Data_Chunk_Handle, out_capacity: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_data_chunk_get_vector_count      :: proc(chunk: V2_Data_Chunk_Handle, out_count: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_data_chunk_get_vector            :: proc(chunk: V2_Data_Chunk_Handle, index: V2_Idx, out_vector: ^V2_Vector_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---

	duckdb_v2_vector_get_vector_type           :: proc(vector: V2_Vector_Handle, out_type: ^V2_Vector_Type, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_vector_get_logical_type          :: proc(vector: V2_Vector_Handle, out_type: ^V2_Logical_Type_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_vector_get_view                  :: proc(vector: V2_Vector_Handle, out_view: ^V2_Vector_View, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_vector_get_size                  :: proc(vector: V2_Vector_Handle, out_size: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_vector_set_size                  :: proc(vector: V2_Vector_Handle, size: V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_vector_get_value                 :: proc(vector: V2_Vector_Handle, row: V2_Idx, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_vector_set_value                 :: proc(vector: V2_Vector_Handle, row: V2_Idx, value: V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_vector_get_data_mutable          :: proc(vector: V2_Vector_Handle, out_data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_vector_flatten                   :: proc(vector: V2_Vector_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_vector_cast                      :: proc(factory: V2_Factory_Handle, source: V2_Vector_Handle, target: V2_Vector_Handle, mode: V2_Cast_Mode, out_converted: ^bool, cast_err: ^V2_Error_Info_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_vector_reference                 :: proc(vector: V2_Vector_Handle, source: V2_Vector_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_vector_make_constant             :: proc(vector: V2_Vector_Handle, value: V2_Value_Handle, count: V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_vector_make_sequence             :: proc(vector: V2_Vector_Handle, start: i64, increment: i64, count: V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_vector_set_null                  :: proc(vector: V2_Vector_Handle, row: V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_vector_flat_get_validity_mutable :: proc(vector: V2_Vector_Handle, out_validity: ^[^]u64, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_vector_constant_set_valid        :: proc(vector: V2_Vector_Handle, validity: bool, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_vector_get_arena                 :: proc(vector: V2_Vector_Handle, out_arena: ^V2_Arena_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_vector_get_child_count           :: proc(vector: V2_Vector_Handle, out_count: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_vector_get_child                 :: proc(vector: V2_Vector_Handle, index: V2_Idx, out_child: ^V2_Vector_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_bignum_decode                    :: proc(in_data: [^]u8, in_length: V2_Idx, out_data: [^]u8, out_capacity: V2_Idx, out_length: ^V2_Idx, out_is_negative: ^bool, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_bignum_encode                    :: proc(in_data: [^]u8, in_length: V2_Idx, is_negative: bool, out_data: [^]u8, out_capacity: V2_Idx, out_length: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_validate_utf8                    :: proc(text: ^V2_Str, err: ^V2_Error_Info_Handle) -> V2_Error ---

	// ColumnDataCollection — V2 Bulk Appender Primitive (`duckdb_v2.h` lines 1267-1536)
	duckdb_v2_column_data_collection_create                    :: proc(factory: V2_Factory_Handle, types_array: [^]V2_Logical_Type_Handle, types_count: V2_Idx, out_collection: ^V2_Column_Data_Collection_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_column_data_collection_reset                     :: proc(collection: V2_Column_Data_Collection_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_column_data_collection_clear                     :: proc(collection: V2_Column_Data_Collection_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_column_data_collection_destroy                   :: proc(collection: ^V2_Column_Data_Collection_Handle) -> V2_Error ---
	duckdb_v2_column_data_collection_combine                   :: proc(target: V2_Column_Data_Collection_Handle, source: ^V2_Column_Data_Collection_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_column_data_collection_row_count                 :: proc(collection: V2_Column_Data_Collection_Handle, out_row_count: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_column_data_collection_append_state_create       :: proc(collection: V2_Column_Data_Collection_Handle, out_state: ^V2_Column_Data_Collection_Append_State_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_column_data_collection_append_state_destroy      :: proc(state: ^V2_Column_Data_Collection_Append_State_Handle) -> V2_Error ---
	duckdb_v2_column_data_collection_append                    :: proc(collection: V2_Column_Data_Collection_Handle, state: V2_Column_Data_Collection_Append_State_Handle, chunk: V2_Data_Chunk_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_column_data_collection_shared_scan_state_create  :: proc(collection: V2_Column_Data_Collection_Handle, out_state: ^V2_Column_Data_Collection_Shared_Scan_State_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_column_data_collection_shared_scan_state_destroy :: proc(state: ^V2_Column_Data_Collection_Shared_Scan_State_Handle) -> V2_Error ---
	duckdb_v2_column_data_collection_worker_scan_state_create  :: proc(collection: V2_Column_Data_Collection_Handle, out_state: ^V2_Column_Data_Collection_Worker_Scan_State_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_column_data_collection_worker_scan_state_destroy :: proc(state: ^V2_Column_Data_Collection_Worker_Scan_State_Handle) -> V2_Error ---
	duckdb_v2_column_data_collection_scan                      :: proc(collection: V2_Column_Data_Collection_Handle, shared_state: V2_Column_Data_Collection_Shared_Scan_State_Handle, worker_state: V2_Column_Data_Collection_Worker_Scan_State_Handle, out_chunk: V2_Data_Chunk_Handle, did_produce_chunk: ^bool, err: ^V2_Error_Info_Handle) -> V2_Error ---

	// Value (`duckdb_v2.h` lines 14409-15954)
	duckdb_v2_value_destroy                  :: proc(value: ^V2_Value_Handle) -> V2_Error ---
	duckdb_v2_value_is_null                  :: proc(value: V2_Value_Handle, out_is_null: ^bool, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_get_logical_type         :: proc(value: V2_Value_Handle, out_type: ^V2_Logical_Type_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_get_bool                 :: proc(value: V2_Value_Handle, out: ^bool, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_get_utinyint             :: proc(value: V2_Value_Handle, out: ^u8, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_get_usmallint            :: proc(value: V2_Value_Handle, out: ^u16, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_get_uint                 :: proc(value: V2_Value_Handle, out: ^u32, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_get_ubigint              :: proc(value: V2_Value_Handle, out: ^u64, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_get_uhugeint             :: proc(value: V2_Value_Handle, out: ^V2_Uhugeint, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_get_tinyint              :: proc(value: V2_Value_Handle, out: ^i8, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_get_smallint             :: proc(value: V2_Value_Handle, out: ^i16, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_get_int                  :: proc(value: V2_Value_Handle, out: ^i32, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_get_bigint               :: proc(value: V2_Value_Handle, out: ^i64, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_get_hugeint              :: proc(value: V2_Value_Handle, out: ^V2_Hugeint, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_get_varchar              :: proc(value: V2_Value_Handle, out: ^V2_Str, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_get_blob                 :: proc(value: V2_Value_Handle, out: ^V2_Str, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_get_float                :: proc(value: V2_Value_Handle, out: ^f32, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_get_double               :: proc(value: V2_Value_Handle, out: ^f64, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_get_date                 :: proc(value: V2_Value_Handle, out: ^i32, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_get_time                 :: proc(value: V2_Value_Handle, out: ^i64, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_get_time_ns              :: proc(value: V2_Value_Handle, out: ^i64, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_get_time_tz              :: proc(value: V2_Value_Handle, out: ^u64, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_get_timestamp            :: proc(value: V2_Value_Handle, out: ^i64, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_get_timestamp_sec        :: proc(value: V2_Value_Handle, out: ^i64, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_get_timestamp_ms         :: proc(value: V2_Value_Handle, out: ^i64, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_get_timestamp_ns         :: proc(value: V2_Value_Handle, out: ^i64, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_get_timestamp_tz         :: proc(value: V2_Value_Handle, out: ^i64, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_get_timestamp_tz_ns      :: proc(value: V2_Value_Handle, out: ^i64, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_get_interval             :: proc(value: V2_Value_Handle, out: ^V2_Interval, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_get_uuid                 :: proc(value: V2_Value_Handle, out: ^V2_Hugeint, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_get_decimal              :: proc(value: V2_Value_Handle, out: ^V2_Hugeint, out_width: ^u8, out_scale: ^u8, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_get_type                 :: proc(value: V2_Value_Handle, out_type: ^V2_Logical_Type_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_null              :: proc(factory: V2_Factory_Handle, type: V2_Logical_Type_Handle, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_bool              :: proc(factory: V2_Factory_Handle, in_value: bool, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_utinyint          :: proc(factory: V2_Factory_Handle, in_value: u8, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_usmallint         :: proc(factory: V2_Factory_Handle, in_value: u16, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_uint              :: proc(factory: V2_Factory_Handle, in_value: u32, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_ubigint           :: proc(factory: V2_Factory_Handle, in_value: u64, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_uhugeint          :: proc(factory: V2_Factory_Handle, in_value: ^V2_Uhugeint, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_tinyint           :: proc(factory: V2_Factory_Handle, in_value: i8, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_smallint          :: proc(factory: V2_Factory_Handle, in_value: i16, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_int               :: proc(factory: V2_Factory_Handle, in_value: i32, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_bigint            :: proc(factory: V2_Factory_Handle, in_value: i64, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_hugeint           :: proc(factory: V2_Factory_Handle, in_value: ^V2_Hugeint, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_varchar           :: proc(factory: V2_Factory_Handle, in_value: ^V2_Str, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_blob              :: proc(factory: V2_Factory_Handle, in_value: ^V2_Str, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_float             :: proc(factory: V2_Factory_Handle, in_value: f32, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_double            :: proc(factory: V2_Factory_Handle, in_value: f64, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_type              :: proc(factory: V2_Factory_Handle, in_type: V2_Logical_Type_Handle, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_date              :: proc(factory: V2_Factory_Handle, in_value: i32, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_time              :: proc(factory: V2_Factory_Handle, in_value: i64, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_time_ns           :: proc(factory: V2_Factory_Handle, in_value: i64, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_time_tz           :: proc(factory: V2_Factory_Handle, in_value: u64, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_timestamp         :: proc(factory: V2_Factory_Handle, in_value: i64, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_timestamp_sec     :: proc(factory: V2_Factory_Handle, in_value: i64, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_timestamp_ms      :: proc(factory: V2_Factory_Handle, in_value: i64, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_timestamp_ns      :: proc(factory: V2_Factory_Handle, in_value: i64, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_timestamp_tz      :: proc(factory: V2_Factory_Handle, in_value: i64, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_timestamp_tz_ns   :: proc(factory: V2_Factory_Handle, in_value: i64, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_interval          :: proc(factory: V2_Factory_Handle, in_value: ^V2_Interval, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_decimal           :: proc(factory: V2_Factory_Handle, in_value: ^V2_Hugeint, width: u8, scale: u8, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_uuid              :: proc(factory: V2_Factory_Handle, in_value: ^V2_Hugeint, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_bit               :: proc(factory: V2_Factory_Handle, in_value: ^V2_Str, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_bignum            :: proc(factory: V2_Factory_Handle, in_value: ^V2_Str, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_list              :: proc(factory: V2_Factory_Handle, child_type: V2_Logical_Type_Handle, children: [^]V2_Value_Handle, child_count: V2_Idx, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_array             :: proc(factory: V2_Factory_Handle, child_type: V2_Logical_Type_Handle, children: [^]V2_Value_Handle, child_count: V2_Idx, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_struct            :: proc(factory: V2_Factory_Handle, names: [^]V2_Identifier, children: [^]V2_Value_Handle, field_count: V2_Idx, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_tuple             :: proc(factory: V2_Factory_Handle, children: [^]V2_Value_Handle, field_count: V2_Idx, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_create_map               :: proc(factory: V2_Factory_Handle, key_type: V2_Logical_Type_Handle, value_type: V2_Logical_Type_Handle, keys: [^]V2_Value_Handle, values: [^]V2_Value_Handle, entry_count: V2_Idx, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_get_child_count          :: proc(value: V2_Value_Handle, out_count: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_get_child                :: proc(value: V2_Value_Handle, index: V2_Idx, out_child: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_cast                     :: proc(factory: V2_Factory_Handle, value: V2_Value_Handle, target_type: V2_Logical_Type_Handle, out_value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_value_to_string                :: proc(value: V2_Value_Handle, out_string: [^]u8, out_capacity: V2_Idx, out_length: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---

	// Arrow C Data Interface & Streaming Result (`duckdb_v2.h` lines 16323-16526)
	duckdb_v2_statement_execute_arrow          :: proc(conn: V2_Connection_Handle, statement: V2_Sql_Statement_Handle, parameter_names: [^]V2_Identifier, parameter_values: [^]V2_Value_Handle, parameter_count: V2_Idx, batch_size: V2_Idx, out_result: ^V2_Arrow_Result_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_prepared_statement_execute_arrow :: proc(prepared: V2_Prepared_Statement_Handle, parameter_names: [^]V2_Identifier, parameter_values: [^]V2_Value_Handle, parameter_count: V2_Idx, batch_size: V2_Idx, out_result: ^V2_Arrow_Result_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_arrow_result_destroy             :: proc(result: ^V2_Arrow_Result_Handle) -> V2_Error ---
	duckdb_v2_arrow_result_step                :: proc(result: V2_Arrow_Result_Handle, out_array: ^Arrow_Array, out_status: ^V2_Result_Step_Status, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_arrow_result_fetch_array         :: proc(result: V2_Arrow_Result_Handle, out_array: ^Arrow_Array, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_arrow_result_wait                :: proc(result: V2_Arrow_Result_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_arrow_result_drain               :: proc(result: V2_Arrow_Result_Handle, out_rows_changed: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_arrow_result_get_result_type     :: proc(result: V2_Arrow_Result_Handle, out_type: ^V2_Result_Type, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_arrow_result_get_statement_type  :: proc(result: V2_Arrow_Result_Handle, out_type: ^V2_Statement_Type, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_arrow_result_get_schema          :: proc(result: V2_Arrow_Result_Handle, out_schema: ^Arrow_Schema, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_arrow_result_to_arrow_c_stream   :: proc(result: ^V2_Arrow_Result_Handle, out_stream: ^Arrow_Array_Stream, err: ^V2_Error_Info_Handle) -> V2_Error ---

	// Qualified Name (`qname`, `duckdb_v2.h` lines 4248-4406)
	duckdb_v2_qname_parse          :: proc(text: ^V2_Str, name: ^V2_Qname_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_qname_create         :: proc(parts: [^]V2_Identifier, part_count: V2_Idx, name: ^V2_Qname_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_qname_get_part_count :: proc(name: V2_Qname_Handle, count: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_qname_get_part       :: proc(name: V2_Qname_Handle, index: V2_Idx, part: ^V2_Identifier, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_qname_render         :: proc(name: V2_Qname_Handle, out_text: [^]u8, out_capacity: V2_Idx, out_length: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_qname_equals         :: proc(left: V2_Qname_Handle, right: V2_Qname_Handle, result: ^bool, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_qname_hash           :: proc(name: V2_Qname_Handle, hash: ^u64, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_qname_destroy        :: proc(name: ^V2_Qname_Handle) -> V2_Error ---

	// Function Bind Info, Docs & Signature (`duckdb_v2.h` lines 3419-3816)
	duckdb_v2_function_bind_get_user_data         :: proc(info: V2_Function_Bind_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_function_bind_set_bind_data         :: proc(info: V2_Function_Bind_Info_Handle, data: ^V2_Opaque, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_function_bind_get_arg_count         :: proc(info: V2_Function_Bind_Info_Handle, positional_fixed: ^V2_Idx, positional_variadic: ^V2_Idx, named_fixed: ^V2_Idx, named_variadic: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_function_bind_get_arg_type          :: proc(info: V2_Function_Bind_Info_Handle, index: V2_Idx, type: ^V2_Logical_Type_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_function_bind_get_arg_value         :: proc(info: V2_Function_Bind_Info_Handle, index: V2_Idx, value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_function_bind_get_arg_name          :: proc(info: V2_Function_Bind_Info_Handle, index: V2_Idx, name: ^V2_Identifier, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_function_bind_get_arg_index         :: proc(info: V2_Function_Bind_Info_Handle, name: ^V2_Identifier, index: ^V2_Idx, found: ^bool, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_function_docs_set_description       :: proc(docs: V2_Function_Docs_Handle, description: ^V2_Str, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_function_docs_add_example           :: proc(docs: V2_Function_Docs_Handle, title: ^V2_Str, example: ^V2_Str, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_function_docs_add_category          :: proc(docs: V2_Function_Docs_Handle, category: ^V2_Str, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_function_signature_add_parameter    :: proc(sig: V2_Function_Signature_Handle, name: ^V2_Identifier, type: V2_Logical_Type_Handle, value: V2_Value_Handle, kind: V2_Function_Parameter_Kind, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_function_signature_set_return_type  :: proc(sig: V2_Function_Signature_Handle, type: V2_Logical_Type_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_identifier_render_quoted            :: proc(name: ^V2_Identifier, out_text: [^]u8, out_capacity: V2_Idx, out_length: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---

	// Scalar Function (`duckdb_v2.h` lines 10414-10925)
	duckdb_v2_scalar_function_create                       :: proc(factory: V2_Factory_Handle, fn: ^V2_Scalar_Function_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_scalar_function_set_name                     :: proc(fn: V2_Scalar_Function_Handle, name: ^V2_Identifier, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_scalar_function_get_docs                     :: proc(fn: V2_Scalar_Function_Handle, docs: ^V2_Function_Docs_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_scalar_function_get_signature                :: proc(fn: V2_Scalar_Function_Handle, sig: ^V2_Function_Signature_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_scalar_function_set_user_data                :: proc(fn: V2_Scalar_Function_Handle, data: ^V2_Opaque, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_scalar_function_set_property                 :: proc(fn: V2_Scalar_Function_Handle, key: V2_Function_Property_Key, value: V2_Function_Property_Value, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_scalar_function_set_resolve_types_callback   :: proc(fn: V2_Scalar_Function_Handle, callback: V2_Scalar_Function_Resolve_Types_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_scalar_function_set_bind_callback            :: proc(fn: V2_Scalar_Function_Handle, callback: V2_Scalar_Function_Bind_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_scalar_function_set_init_callback            :: proc(fn: V2_Scalar_Function_Handle, callback: V2_Scalar_Function_Init_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_scalar_function_set_exec_callback            :: proc(fn: V2_Scalar_Function_Handle, callback: V2_Scalar_Function_Exec_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_scalar_function_resolve_types_set_return_type :: proc(info: V2_Scalar_Function_Resolve_Types_Info_Handle, return_type: V2_Logical_Type_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_scalar_function_bind_set_bind_data           :: proc(info: V2_Scalar_Function_Bind_Info_Handle, data: ^V2_Opaque, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_scalar_function_init_get_user_data           :: proc(info: V2_Scalar_Function_Init_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_scalar_function_init_get_bind_data           :: proc(info: V2_Scalar_Function_Init_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_scalar_function_init_set_init_data           :: proc(info: V2_Scalar_Function_Init_Info_Handle, data: ^V2_Opaque, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_scalar_function_exec_get_user_data           :: proc(info: V2_Scalar_Function_Exec_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_scalar_function_exec_get_bind_data           :: proc(info: V2_Scalar_Function_Exec_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_scalar_function_exec_get_init_data           :: proc(info: V2_Scalar_Function_Exec_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_scalar_function_exec_get_row_count           :: proc(info: V2_Scalar_Function_Exec_Info_Handle, count: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_scalar_function_exec_get_arg_count           :: proc(info: V2_Scalar_Function_Exec_Info_Handle, positional_fixed: ^V2_Idx, positional_variadic: ^V2_Idx, named_fixed: ^V2_Idx, named_variadic: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_scalar_function_exec_get_arg                 :: proc(info: V2_Scalar_Function_Exec_Info_Handle, index: V2_Idx, vector: ^V2_Vector_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_scalar_function_exec_get_result              :: proc(info: V2_Scalar_Function_Exec_Info_Handle, vector: ^V2_Vector_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_connection_register_scalar_function          :: proc(conn: V2_Connection_Handle, fn: V2_Scalar_Function_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_scalar_function_destroy                      :: proc(fn: ^V2_Scalar_Function_Handle) -> V2_Error ---

	// Table Function (`duckdb_v2.h` lines 12604-13360)
	duckdb_v2_table_function_create                            :: proc(factory: V2_Factory_Handle, fn: ^V2_Table_Function_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_set_name                          :: proc(fn: V2_Table_Function_Handle, name: ^V2_Identifier, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_get_docs                          :: proc(fn: V2_Table_Function_Handle, docs: ^V2_Function_Docs_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_get_signature                     :: proc(fn: V2_Table_Function_Handle, sig: ^V2_Function_Signature_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_set_user_data                     :: proc(fn: V2_Table_Function_Handle, data: ^V2_Opaque, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_set_bind_callback                 :: proc(fn: V2_Table_Function_Handle, callback: V2_Table_Function_Bind_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_set_init_global_callback          :: proc(fn: V2_Table_Function_Handle, callback: V2_Table_Function_Init_Global_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_set_init_local_callback           :: proc(fn: V2_Table_Function_Handle, callback: V2_Table_Function_Init_Local_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_set_exec_callback                 :: proc(fn: V2_Table_Function_Handle, callback: V2_Table_Function_Exec_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_set_progress_callback             :: proc(fn: V2_Table_Function_Handle, callback: V2_Table_Function_Progress_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_set_partition_data_callback       :: proc(fn: V2_Table_Function_Handle, callback: V2_Table_Function_Partition_Data_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_set_partitioning_callback         :: proc(fn: V2_Table_Function_Handle, callback: V2_Table_Function_Partitioning_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_set_claim_batch_callback          :: proc(fn: V2_Table_Function_Handle, callback: V2_Table_Function_Claim_Batch_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_set_get_bind_info_callback        :: proc(fn: V2_Table_Function_Handle, callback: V2_Table_Function_Get_Bind_Info_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_set_projection_pushdown           :: proc(fn: V2_Table_Function_Handle, enable: bool, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_bind_add_result_column            :: proc(info: V2_Table_Function_Bind_Info_Handle, name: ^V2_Identifier, type: V2_Logical_Type_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_bind_set_cardinality              :: proc(info: V2_Table_Function_Bind_Info_Handle, cardinality: V2_Idx, is_exact: bool, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_bind_set_order_preservation       :: proc(info: V2_Table_Function_Bind_Info_Handle, order: V2_Order_Preservation, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_init_global_get_user_data         :: proc(info: V2_Table_Function_Init_Global_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_init_global_get_bind_data         :: proc(info: V2_Table_Function_Init_Global_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_init_global_set_global_state      :: proc(info: V2_Table_Function_Init_Global_Info_Handle, data: ^V2_Opaque, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_init_global_set_max_threads       :: proc(info: V2_Table_Function_Init_Global_Info_Handle, max_threads: V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_init_global_get_column_count      :: proc(info: V2_Table_Function_Init_Global_Info_Handle, count: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_init_global_get_column_index      :: proc(info: V2_Table_Function_Init_Global_Info_Handle, index: V2_Idx, column_index: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_init_local_get_user_data          :: proc(info: V2_Table_Function_Init_Local_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_init_local_get_bind_data          :: proc(info: V2_Table_Function_Init_Local_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_init_local_get_global_state       :: proc(info: V2_Table_Function_Init_Local_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_init_local_set_local_state        :: proc(info: V2_Table_Function_Init_Local_Info_Handle, data: ^V2_Opaque, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_init_local_get_column_count       :: proc(info: V2_Table_Function_Init_Local_Info_Handle, count: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_init_local_get_column_index       :: proc(info: V2_Table_Function_Init_Local_Info_Handle, index: V2_Idx, column_index: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_exec_get_user_data                :: proc(info: V2_Table_Function_Exec_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_exec_get_bind_data                :: proc(info: V2_Table_Function_Exec_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_exec_get_global_state             :: proc(info: V2_Table_Function_Exec_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_exec_get_local_state              :: proc(info: V2_Table_Function_Exec_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_exec_get_output_chunk             :: proc(info: V2_Table_Function_Exec_Info_Handle, chunk: ^V2_Data_Chunk_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_exec_get_column_count             :: proc(info: V2_Table_Function_Exec_Info_Handle, count: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_exec_get_column_index             :: proc(info: V2_Table_Function_Exec_Info_Handle, index: V2_Idx, column_index: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_progress_get_user_data            :: proc(info: V2_Table_Function_Progress_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_progress_get_bind_data            :: proc(info: V2_Table_Function_Progress_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_progress_get_global_state         :: proc(info: V2_Table_Function_Progress_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_progress_set_progress             :: proc(info: V2_Table_Function_Progress_Info_Handle, progress: f64, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_partition_data_get_user_data      :: proc(info: V2_Table_Function_Partition_Data_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_partition_data_get_bind_data      :: proc(info: V2_Table_Function_Partition_Data_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_partition_data_get_global_state   :: proc(info: V2_Table_Function_Partition_Data_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_partition_data_get_local_state    :: proc(info: V2_Table_Function_Partition_Data_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_partition_data_requires_batch_index       :: proc(info: V2_Table_Function_Partition_Data_Info_Handle, required: ^bool, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_partition_data_requires_partition_columns :: proc(info: V2_Table_Function_Partition_Data_Info_Handle, required: ^bool, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_partition_data_get_partition_column_count :: proc(info: V2_Table_Function_Partition_Data_Info_Handle, count: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_partition_data_get_partition_column_index :: proc(info: V2_Table_Function_Partition_Data_Info_Handle, index: V2_Idx, column_index: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_partition_data_set_batch_index    :: proc(info: V2_Table_Function_Partition_Data_Info_Handle, batch_index: V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_partition_data_set_partition_value :: proc(info: V2_Table_Function_Partition_Data_Info_Handle, index: V2_Idx, value: V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_partitioning_get_user_data        :: proc(info: V2_Table_Function_Partitioning_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_partitioning_get_bind_data        :: proc(info: V2_Table_Function_Partitioning_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_partitioning_get_partition_column_count :: proc(info: V2_Table_Function_Partitioning_Info_Handle, count: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_partitioning_get_partition_column_index :: proc(info: V2_Table_Function_Partitioning_Info_Handle, index: V2_Idx, column_index: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_partitioning_set_partition_info   :: proc(info: V2_Table_Function_Partitioning_Info_Handle, partition_info: V2_Table_Partition_Kind, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_claim_batch_get_user_data         :: proc(info: V2_Table_Function_Claim_Batch_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_claim_batch_get_bind_data         :: proc(info: V2_Table_Function_Claim_Batch_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_claim_batch_get_global_state      :: proc(info: V2_Table_Function_Claim_Batch_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_claim_batch_get_local_state       :: proc(info: V2_Table_Function_Claim_Batch_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_claim_batch_set_claimed           :: proc(info: V2_Table_Function_Claim_Batch_Info_Handle, claimed: bool, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_get_bind_info_get_user_data       :: proc(info: V2_Table_Function_Get_Bind_Info_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_get_bind_info_get_bind_data       :: proc(info: V2_Table_Function_Get_Bind_Info_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_get_bind_info_set_column_identifier :: proc(info: V2_Table_Function_Get_Bind_Info_Info_Handle, column_index: V2_Idx, child_path: [^]V2_Idx, child_path_length: V2_Idx, identifier: V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_get_bind_info_set_option          :: proc(info: V2_Table_Function_Get_Bind_Info_Info_Handle, key: ^V2_Str, value: V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_connection_register_table_function               :: proc(conn: V2_Connection_Handle, fn: V2_Table_Function_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_destroy                           :: proc(fn: ^V2_Table_Function_Handle) -> V2_Error ---

	// Aggregate Function (`duckdb_v2.h` lines 5023-5884)
	duckdb_v2_aggregate_function_create                     :: proc(factory: V2_Factory_Handle, fn: ^V2_Aggregate_Function_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_set_name                   :: proc(fn: V2_Aggregate_Function_Handle, name: ^V2_Identifier, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_get_docs                   :: proc(fn: V2_Aggregate_Function_Handle, docs: ^V2_Function_Docs_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_get_signature              :: proc(fn: V2_Aggregate_Function_Handle, sig: ^V2_Function_Signature_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_set_user_data              :: proc(fn: V2_Aggregate_Function_Handle, data: ^V2_Opaque, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_set_property               :: proc(fn: V2_Aggregate_Function_Handle, key: V2_Function_Property_Key, value: V2_Function_Property_Value, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_set_bind_callback          :: proc(fn: V2_Aggregate_Function_Handle, callback: V2_Aggregate_Function_Bind_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_set_size_callback          :: proc(fn: V2_Aggregate_Function_Handle, callback: V2_Aggregate_Function_Size_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_set_init_callback          :: proc(fn: V2_Aggregate_Function_Handle, callback: V2_Aggregate_Function_Init_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_set_update_callback        :: proc(fn: V2_Aggregate_Function_Handle, callback: V2_Aggregate_Function_Update_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_set_combine_callback       :: proc(fn: V2_Aggregate_Function_Handle, callback: V2_Aggregate_Function_Combine_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_set_finalize_callback      :: proc(fn: V2_Aggregate_Function_Handle, callback: V2_Aggregate_Function_Finalize_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_set_destroy_callback       :: proc(fn: V2_Aggregate_Function_Handle, callback: V2_Aggregate_Function_Destroy_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_bind_set_return_type       :: proc(info: V2_Aggregate_Function_Bind_Info_Handle, return_type: V2_Logical_Type_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_size_get_user_data         :: proc(info: V2_Aggregate_Function_Size_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_size_get_bind_data         :: proc(info: V2_Aggregate_Function_Size_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_size_set_state_size        :: proc(info: V2_Aggregate_Function_Size_Info_Handle, size: V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_init_get_user_data         :: proc(info: V2_Aggregate_Function_Init_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_init_get_bind_data         :: proc(info: V2_Aggregate_Function_Init_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_init_get_state_count       :: proc(info: V2_Aggregate_Function_Init_Info_Handle, count: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_init_get_states            :: proc(info: V2_Aggregate_Function_Init_Info_Handle, states: ^[^]rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_update_get_user_data       :: proc(info: V2_Aggregate_Function_Update_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_update_get_bind_data       :: proc(info: V2_Aggregate_Function_Update_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_update_get_row_count       :: proc(info: V2_Aggregate_Function_Update_Info_Handle, count: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_update_get_arg_count       :: proc(info: V2_Aggregate_Function_Update_Info_Handle, positional_fixed: ^V2_Idx, positional_variadic: ^V2_Idx, named_fixed: ^V2_Idx, named_variadic: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_update_get_arg             :: proc(info: V2_Aggregate_Function_Update_Info_Handle, index: V2_Idx, vector: ^V2_Vector_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_update_get_states          :: proc(info: V2_Aggregate_Function_Update_Info_Handle, states: ^[^]rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_combine_get_user_data      :: proc(info: V2_Aggregate_Function_Combine_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_combine_get_bind_data      :: proc(info: V2_Aggregate_Function_Combine_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_combine_get_state_count    :: proc(info: V2_Aggregate_Function_Combine_Info_Handle, count: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_combine_get_sources        :: proc(info: V2_Aggregate_Function_Combine_Info_Handle, states: ^[^]rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_combine_get_targets        :: proc(info: V2_Aggregate_Function_Combine_Info_Handle, states: ^[^]rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_finalize_get_user_data     :: proc(info: V2_Aggregate_Function_Finalize_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_finalize_get_bind_data     :: proc(info: V2_Aggregate_Function_Finalize_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_finalize_get_state_count   :: proc(info: V2_Aggregate_Function_Finalize_Info_Handle, count: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_finalize_get_states        :: proc(info: V2_Aggregate_Function_Finalize_Info_Handle, states: ^[^]rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_finalize_get_result        :: proc(info: V2_Aggregate_Function_Finalize_Info_Handle, vector: ^V2_Vector_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_finalize_get_result_offset :: proc(info: V2_Aggregate_Function_Finalize_Info_Handle, offset: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_destroy_get_user_data      :: proc(info: V2_Aggregate_Function_Destroy_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_destroy_get_bind_data      :: proc(info: V2_Aggregate_Function_Destroy_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_destroy_get_state_count    :: proc(info: V2_Aggregate_Function_Destroy_Info_Handle, count: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_destroy_get_states         :: proc(info: V2_Aggregate_Function_Destroy_Info_Handle, states: ^[^]rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_connection_register_aggregate_function        :: proc(conn: V2_Connection_Handle, fn: V2_Aggregate_Function_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_aggregate_function_destroy                    :: proc(fn: ^V2_Aggregate_Function_Handle) -> V2_Error ---

	// Replacement Scan (`duckdb_v2.h` lines 9961-10309)
	duckdb_v2_replacement_scan_create               :: proc(factory: V2_Factory_Handle, scan: ^V2_Replacement_Scan_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_replacement_scan_set_callback         :: proc(scan: V2_Replacement_Scan_Handle, callback: V2_Replacement_Scan_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_replacement_scan_set_user_data        :: proc(scan: V2_Replacement_Scan_Handle, data: ^V2_Opaque, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_replacement_scan_get_user_data        :: proc(info: V2_Replacement_Scan_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_replacement_scan_get_name             :: proc(info: V2_Replacement_Scan_Info_Handle, name: ^V2_Qname_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_replacement_scan_set_function_name    :: proc(info: V2_Replacement_Scan_Info_Handle, name: V2_Qname_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_replacement_scan_add_argument         :: proc(info: V2_Replacement_Scan_Info_Handle, value: V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_replacement_scan_add_named_argument   :: proc(info: V2_Replacement_Scan_Info_Handle, name: ^V2_Identifier, value: V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_replacement_scan_set_collection       :: proc(info: V2_Replacement_Scan_Info_Handle, collection: V2_Column_Data_Collection_Handle, column_names: [^]V2_Identifier, column_count: V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_replacement_scan_set_subquery         :: proc(info: V2_Replacement_Scan_Info_Handle, sql: ^V2_Str, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_replacement_scan_set_alias            :: proc(info: V2_Replacement_Scan_Info_Handle, alias: ^V2_Identifier, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_connection_register_replacement_scan  :: proc(conn: V2_Connection_Handle, scan: V2_Replacement_Scan_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_instance_register_replacement_scan    :: proc(instance: V2_Instance_Handle, scan: V2_Replacement_Scan_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_replacement_scan_destroy              :: proc(scan: ^V2_Replacement_Scan_Handle) -> V2_Error ---

	// Custom Type & Cast Function (`duckdb_v2.h` lines 908-1186, 2099-2209)
	duckdb_v2_custom_type_create                    :: proc(factory: V2_Factory_Handle, type: ^V2_Custom_Type_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_custom_type_set_name                  :: proc(type: V2_Custom_Type_Handle, name: ^V2_Identifier, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_custom_type_set_base_type             :: proc(type: V2_Custom_Type_Handle, base_type: V2_Logical_Type_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_connection_register_custom_type       :: proc(conn: V2_Connection_Handle, type: V2_Custom_Type_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_custom_type_destroy                   :: proc(type: ^V2_Custom_Type_Handle) -> V2_Error ---
	duckdb_v2_cast_function_create                  :: proc(factory: V2_Factory_Handle, fn: ^V2_Cast_Function_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_cast_function_set_source_type         :: proc(fn: V2_Cast_Function_Handle, source_type: V2_Logical_Type_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_cast_function_set_target_type         :: proc(fn: V2_Cast_Function_Handle, target_type: V2_Logical_Type_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_cast_function_set_implicit_cast_cost  :: proc(fn: V2_Cast_Function_Handle, cost: i64, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_cast_function_set_user_data           :: proc(fn: V2_Cast_Function_Handle, data: ^V2_Opaque, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_cast_function_set_exec_callback       :: proc(fn: V2_Cast_Function_Handle, callback: V2_Cast_Function_Exec_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_cast_function_exec_get_user_data      :: proc(info: V2_Cast_Function_Exec_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_cast_function_exec_get_row_count      :: proc(info: V2_Cast_Function_Exec_Info_Handle, count: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_cast_function_exec_get_input          :: proc(info: V2_Cast_Function_Exec_Info_Handle, vector: ^V2_Vector_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_cast_function_exec_get_output         :: proc(info: V2_Cast_Function_Exec_Info_Handle, vector: ^V2_Vector_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_cast_function_exec_get_mode           :: proc(info: V2_Cast_Function_Exec_Info_Handle, mode: ^V2_Cast_Mode, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_connection_register_cast_function     :: proc(conn: V2_Connection_Handle, fn: V2_Cast_Function_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_cast_function_destroy                 :: proc(fn: ^V2_Cast_Function_Handle) -> V2_Error ---

	// Catalog (`TableDescription` & `ColumnDescription`, `duckdb_v2.h` lines 5946-6147)
	duckdb_v2_connection_describe_table          :: proc(conn: V2_Connection_Handle, name: V2_Qname_Handle, desc: ^V2_Table_Description_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_description_get_qname        :: proc(desc: V2_Table_Description_Handle, name: ^V2_Qname_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_description_is_readonly      :: proc(desc: V2_Table_Description_Handle, readonly: ^bool, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_description_get_column_count :: proc(desc: V2_Table_Description_Handle, count: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_description_get_column       :: proc(desc: V2_Table_Description_Handle, index: V2_Idx, column: ^V2_Column_Description_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_description_destroy          :: proc(desc: ^V2_Table_Description_Handle) -> V2_Error ---
	duckdb_v2_column_description_get_name        :: proc(column: V2_Column_Description_Handle, name: ^V2_Identifier, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_column_description_get_type        :: proc(column: V2_Column_Description_Handle, type: ^V2_Logical_Type_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_column_description_has_default     :: proc(column: V2_Column_Description_Handle, has_default: ^bool, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_column_description_has_generated   :: proc(column: V2_Column_Description_Handle, has_generated: ^bool, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_column_description_destroy         :: proc(column: ^V2_Column_Description_Handle) -> V2_Error ---

	// Query Metrics (`duckdb_v2.h` lines 4464-4663)
	duckdb_v2_connection_get_query_metrics       :: proc(conn: V2_Connection_Handle, metrics: ^V2_Query_Metrics_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_connection_enable_profiling        :: proc(conn: V2_Connection_Handle, enabled: bool, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_query_metrics_get_root             :: proc(metrics: V2_Query_Metrics_Handle, node: ^V2_Query_Metrics_Node_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_query_metrics_node_get_name        :: proc(node: V2_Query_Metrics_Node_Handle, name: ^V2_Str, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_query_metrics_node_get_child_count :: proc(node: V2_Query_Metrics_Node_Handle, count: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_query_metrics_node_get_child       :: proc(node: V2_Query_Metrics_Node_Handle, index: V2_Idx, child: ^V2_Query_Metrics_Node_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_query_metrics_node_get_metric_count :: proc(node: V2_Query_Metrics_Node_Handle, count: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_query_metrics_node_get_metric_name :: proc(node: V2_Query_Metrics_Node_Handle, index: V2_Idx, name: ^V2_Str, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_query_metrics_node_get_metric_value :: proc(node: V2_Query_Metrics_Node_Handle, index: V2_Idx, value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_query_metrics_node_get_metric      :: proc(node: V2_Query_Metrics_Node_Handle, name: ^V2_Str, value: ^V2_Value_Handle, present: ^bool, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_query_metrics_destroy              :: proc(metrics: ^V2_Query_Metrics_Handle) -> V2_Error ---

	// Tokenizer (`duckdb_v2.h` lines 4823-4885)
	duckdb_v2_tokenize_sql                     :: proc(conn: V2_Connection_Handle, sql: ^V2_Str, out_iterator: ^V2_Token_Iterator_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_token_iterator_next              :: proc(iterator: V2_Token_Iterator_Handle, out_type: ^V2_Token_Type, out_start: ^V2_Idx, out_length: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_token_iterator_ends_unterminated :: proc(iterator: V2_Token_Iterator_Handle, out_ends_unterminated: ^bool, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_token_iterator_destroy           :: proc(iterator: ^V2_Token_Iterator_Handle) -> V2_Error ---

	// Pragma Function (`duckdb_v2.h` lines 9676-9897)
	duckdb_v2_pragma_function_create             :: proc(factory: V2_Factory_Handle, fn: ^V2_Pragma_Function_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_pragma_function_set_name           :: proc(fn: V2_Pragma_Function_Handle, name: ^V2_Identifier, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_pragma_function_get_docs           :: proc(fn: V2_Pragma_Function_Handle, docs: ^V2_Function_Docs_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_pragma_function_get_signature      :: proc(fn: V2_Pragma_Function_Handle, sig: ^V2_Function_Signature_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_pragma_function_set_user_data      :: proc(fn: V2_Pragma_Function_Handle, data: ^V2_Opaque, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_pragma_function_set_query_callback :: proc(fn: V2_Pragma_Function_Handle, callback: V2_Pragma_Function_Query_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_pragma_function_set_exec_callback  :: proc(fn: V2_Pragma_Function_Handle, callback: V2_Pragma_Function_Exec_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_pragma_function_query_set_query    :: proc(info: V2_Pragma_Function_Query_Info_Handle, query: ^V2_Str, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_connection_register_pragma_function :: proc(conn: V2_Connection_Handle, fn: V2_Pragma_Function_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_pragma_function_destroy            :: proc(fn: ^V2_Pragma_Function_Handle) -> V2_Error ---

	// Custom Option (`duckdb_v2.h` lines 7979-8309)
	duckdb_v2_custom_option_create               :: proc(factory: V2_Factory_Handle, option: ^V2_Custom_Option_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_custom_option_set_name             :: proc(option: V2_Custom_Option_Handle, name: ^V2_Identifier, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_custom_option_set_type             :: proc(option: V2_Custom_Option_Handle, type: V2_Logical_Type_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_custom_option_set_default_value    :: proc(option: V2_Custom_Option_Handle, value: V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_custom_option_set_description      :: proc(option: V2_Custom_Option_Handle, description: ^V2_Str, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_custom_option_set_default_scope    :: proc(option: V2_Custom_Option_Handle, scope: V2_Setting_Scope, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_custom_option_set_supports_scope   :: proc(option: V2_Custom_Option_Handle, scope: V2_Setting_Scope, supported: bool, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_custom_option_set_user_data        :: proc(option: V2_Custom_Option_Handle, data: ^V2_Opaque, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_custom_option_set_update_callback  :: proc(option: V2_Custom_Option_Handle, callback: V2_Custom_Option_Update_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_custom_option_update_get_user_data :: proc(info: V2_Custom_Option_Update_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_custom_option_update_get_value     :: proc(info: V2_Custom_Option_Update_Info_Handle, value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_custom_option_update_set_value     :: proc(info: V2_Custom_Option_Update_Info_Handle, value: V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_custom_option_update_get_scope     :: proc(info: V2_Custom_Option_Update_Info_Handle, scope: ^V2_Setting_Scope, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_custom_option_update_is_reset      :: proc(info: V2_Custom_Option_Update_Info_Handle, is_reset: ^bool, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_connection_register_custom_option  :: proc(conn: V2_Connection_Handle, option: V2_Custom_Option_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_custom_option_destroy              :: proc(option: ^V2_Custom_Option_Handle) -> V2_Error ---

	// Logging & Log Sink (`duckdb_v2.h` lines 4172-4199, 8706-8938)
	duckdb_v2_instance_log                          :: proc(instance: V2_Instance_Handle, level: V2_Log_Level, log_type: ^V2_Str, message: ^V2_Str, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_connection_log                        :: proc(conn: V2_Connection_Handle, level: V2_Log_Level, log_type: ^V2_Str, message: ^V2_Str, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_context_log                           :: proc(ctx: V2_Context_Handle, level: V2_Log_Level, log_type: ^V2_Str, message: ^V2_Str, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_log_sink_create                       :: proc(factory: V2_Factory_Handle, sink: ^V2_Log_Sink_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_log_sink_set_name                     :: proc(sink: V2_Log_Sink_Handle, name: ^V2_Identifier, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_log_sink_set_user_data                :: proc(sink: V2_Log_Sink_Handle, data: ^V2_Opaque, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_log_sink_set_write_callback           :: proc(sink: V2_Log_Sink_Handle, callback: V2_Log_Sink_Write_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_log_sink_set_flush_callback           :: proc(sink: V2_Log_Sink_Handle, callback: V2_Log_Sink_Flush_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_log_sink_write_info_get_connection_id :: proc(info: V2_Log_Sink_Write_Info_Handle, id: ^V2_Idx, present: ^bool, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_log_sink_write_info_get_transaction_id :: proc(info: V2_Log_Sink_Write_Info_Handle, id: ^V2_Idx, present: ^bool, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_log_sink_write_info_get_query_id      :: proc(info: V2_Log_Sink_Write_Info_Handle, id: ^V2_Idx, present: ^bool, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_log_sink_write_info_get_thread_id     :: proc(info: V2_Log_Sink_Write_Info_Handle, id: ^V2_Idx, present: ^bool, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_instance_register_log_sink            :: proc(instance: V2_Instance_Handle, sink: V2_Log_Sink_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_log_sink_destroy                      :: proc(sink: ^V2_Log_Sink_Handle) -> V2_Error ---

	// File System, File Open Options & File Handle (`duckdb_v2.h` lines 2841-3370)
	duckdb_v2_context_get_file_system       :: proc(ctx: V2_Context_Handle, file_system: ^V2_File_System_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_instance_get_file_system      :: proc(instance: V2_Instance_Handle, file_system: ^V2_File_System_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_connection_get_file_system    :: proc(conn: V2_Connection_Handle, file_system: ^V2_File_System_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_file_open_options_create      :: proc(file_system: V2_File_System_Handle, options: ^V2_File_Open_Options_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_file_open_options_set_flag    :: proc(options: V2_File_Open_Options_Handle, flag: V2_File_Flag, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_file_open_options_set_value   :: proc(options: V2_File_Open_Options_Handle, name: ^V2_Str, value: V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_file_open_options_destroy     :: proc(options: ^V2_File_Open_Options_Handle) -> V2_Error ---
	duckdb_v2_file_system_open              :: proc(file_system: V2_File_System_Handle, file_path: ^V2_Str, options: V2_File_Open_Options_Handle, file: ^V2_File_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_file_system_path_exists       :: proc(file_system: V2_File_System_Handle, path: ^V2_Str, out_exists: ^bool, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_file_system_path_is_remote    :: proc(file_system: V2_File_System_Handle, path: ^V2_Str, out_is_remote: ^bool, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_file_system_path_expand       :: proc(file_system: V2_File_System_Handle, path: ^V2_Str, sink: V2_Text_Sink_Fn, user_data: rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_file_system_path_glob         :: proc(file_system: V2_File_System_Handle, pattern: ^V2_Str, callback: V2_File_System_Path_Glob_Callback_Fn, user_data: rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_file_system_path_move         :: proc(file_system: V2_File_System_Handle, source: ^V2_Str, target: ^V2_Str, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_file_system_path_remove       :: proc(file_system: V2_File_System_Handle, path: ^V2_Str, out_removed: ^bool, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_file_read                     :: proc(file: V2_File_Handle, buffer: rawptr, buffer_size: V2_Idx, bytes_read: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_file_write                    :: proc(file: V2_File_Handle, buffer: rawptr, buffer_size: V2_Idx, bytes_written: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_file_read_at                  :: proc(file: V2_File_Handle, buffer: rawptr, buffer_size: V2_Idx, location: V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_file_write_at                 :: proc(file: V2_File_Handle, buffer: rawptr, buffer_size: V2_Idx, location: V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_file_tell                     :: proc(file: V2_File_Handle, position: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_file_size                     :: proc(file: V2_File_Handle, size: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_file_seek                     :: proc(file: V2_File_Handle, position: V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_file_sync                     :: proc(file: V2_File_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_file_close                    :: proc(file: V2_File_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_file_destroy                  :: proc(file: ^V2_File_Handle) -> V2_Error ---

	// Copy Function (`duckdb_v2.h` lines 6352-7918)
	duckdb_v2_copy_function_create                 :: proc(factory: V2_Factory_Handle, fn: ^V2_Copy_Function_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_function_set_name               :: proc(fn: V2_Copy_Function_Handle, name: ^V2_Identifier, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_function_set_file_extension     :: proc(fn: V2_Copy_Function_Handle, extension: ^V2_Str, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_function_set_user_data          :: proc(fn: V2_Copy_Function_Handle, data: ^V2_Opaque, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_set_bind_callback            :: proc(fn: V2_Copy_Function_Handle, callback: V2_Copy_To_Bind_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_set_batch_size_callback      :: proc(fn: V2_Copy_Function_Handle, callback: V2_Copy_To_Batch_Size_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_set_init_callback            :: proc(fn: V2_Copy_Function_Handle, callback: V2_Copy_To_Init_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_set_batch_callback           :: proc(fn: V2_Copy_Function_Handle, callback: V2_Copy_To_Batch_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_set_flush_callback           :: proc(fn: V2_Copy_Function_Handle, callback: V2_Copy_To_Flush_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_set_finalize_callback        :: proc(fn: V2_Copy_Function_Handle, callback: V2_Copy_To_Finalize_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_set_statistics_callback      :: proc(fn: V2_Copy_Function_Handle, callback: V2_Copy_To_Statistics_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_bind_get_user_data           :: proc(info: V2_Copy_To_Bind_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_bind_set_bind_data           :: proc(info: V2_Copy_To_Bind_Info_Handle, data: ^V2_Opaque, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_bind_get_file_path           :: proc(info: V2_Copy_To_Bind_Info_Handle, path: ^V2_Str, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_bind_get_column_count        :: proc(info: V2_Copy_To_Bind_Info_Handle, count: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_bind_get_column_type         :: proc(info: V2_Copy_To_Bind_Info_Handle, index: V2_Idx, type: ^V2_Logical_Type_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_bind_get_column_name         :: proc(info: V2_Copy_To_Bind_Info_Handle, index: V2_Idx, name: ^V2_Identifier, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_bind_get_option_count        :: proc(info: V2_Copy_To_Bind_Info_Handle, count: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_bind_get_option_name         :: proc(info: V2_Copy_To_Bind_Info_Handle, index: V2_Idx, name: ^V2_Identifier, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_bind_get_option_value        :: proc(info: V2_Copy_To_Bind_Info_Handle, index: V2_Idx, value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_batch_size_get_user_data     :: proc(info: V2_Copy_To_Batch_Size_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_batch_size_get_bind_data     :: proc(info: V2_Copy_To_Batch_Size_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_batch_size_set_target        :: proc(info: V2_Copy_To_Batch_Size_Info_Handle, rows: V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_init_get_user_data           :: proc(info: V2_Copy_To_Init_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_init_get_bind_data           :: proc(info: V2_Copy_To_Init_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_init_get_file_path           :: proc(info: V2_Copy_To_Init_Info_Handle, path: ^V2_Str, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_init_set_init_data           :: proc(info: V2_Copy_To_Init_Info_Handle, data: ^V2_Opaque, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_batch_get_user_data          :: proc(info: V2_Copy_To_Batch_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_batch_get_bind_data          :: proc(info: V2_Copy_To_Batch_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_batch_get_init_data          :: proc(info: V2_Copy_To_Batch_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_batch_take_input             :: proc(info: V2_Copy_To_Batch_Info_Handle, collection: ^V2_Column_Data_Collection_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_batch_set_batch_data         :: proc(info: V2_Copy_To_Batch_Info_Handle, data: ^V2_Opaque, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_flush_get_user_data          :: proc(info: V2_Copy_To_Flush_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_flush_get_bind_data          :: proc(info: V2_Copy_To_Flush_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_flush_get_init_data          :: proc(info: V2_Copy_To_Flush_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_flush_get_batch_data         :: proc(info: V2_Copy_To_Flush_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_finalize_get_user_data       :: proc(info: V2_Copy_To_Finalize_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_finalize_get_bind_data       :: proc(info: V2_Copy_To_Finalize_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_finalize_get_init_data       :: proc(info: V2_Copy_To_Finalize_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_statistics_get_user_data     :: proc(info: V2_Copy_To_Statistics_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_statistics_get_bind_data     :: proc(info: V2_Copy_To_Statistics_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_statistics_get_init_data     :: proc(info: V2_Copy_To_Statistics_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_statistics_set_row_count     :: proc(info: V2_Copy_To_Statistics_Info_Handle, row_count: V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_to_statistics_set_file_size     :: proc(info: V2_Copy_To_Statistics_Info_Handle, file_size_bytes: V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_from_set_bind_callback          :: proc(fn: V2_Copy_Function_Handle, callback: V2_Copy_From_Bind_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_from_set_init_global_callback   :: proc(fn: V2_Copy_Function_Handle, callback: V2_Copy_From_Init_Global_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_from_set_init_local_callback    :: proc(fn: V2_Copy_Function_Handle, callback: V2_Copy_From_Init_Local_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_from_set_exec_callback          :: proc(fn: V2_Copy_Function_Handle, callback: V2_Copy_From_Exec_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_from_set_progress_callback      :: proc(fn: V2_Copy_Function_Handle, callback: V2_Copy_From_Progress_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_from_bind_get_user_data         :: proc(info: V2_Copy_From_Bind_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_from_bind_set_bind_data         :: proc(info: V2_Copy_From_Bind_Info_Handle, data: ^V2_Opaque, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_from_bind_get_file_path         :: proc(info: V2_Copy_From_Bind_Info_Handle, path: ^V2_Str, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_from_bind_get_column_count      :: proc(info: V2_Copy_From_Bind_Info_Handle, count: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_from_bind_get_column_type       :: proc(info: V2_Copy_From_Bind_Info_Handle, index: V2_Idx, type: ^V2_Logical_Type_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_from_bind_get_column_name       :: proc(info: V2_Copy_From_Bind_Info_Handle, index: V2_Idx, name: ^V2_Identifier, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_from_bind_get_option_count      :: proc(info: V2_Copy_From_Bind_Info_Handle, count: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_from_bind_get_option_name       :: proc(info: V2_Copy_From_Bind_Info_Handle, index: V2_Idx, name: ^V2_Identifier, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_from_bind_get_option_value      :: proc(info: V2_Copy_From_Bind_Info_Handle, index: V2_Idx, value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_from_bind_set_cardinality       :: proc(info: V2_Copy_From_Bind_Info_Handle, cardinality: V2_Idx, is_exact: bool, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_from_init_global_get_user_data  :: proc(info: V2_Copy_From_Init_Global_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_from_init_global_get_bind_data  :: proc(info: V2_Copy_From_Init_Global_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_from_init_global_set_global_state :: proc(info: V2_Copy_From_Init_Global_Info_Handle, data: ^V2_Opaque, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_from_init_global_set_max_threads :: proc(info: V2_Copy_From_Init_Global_Info_Handle, max_threads: V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_from_init_local_get_user_data   :: proc(info: V2_Copy_From_Init_Local_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_from_init_local_get_bind_data   :: proc(info: V2_Copy_From_Init_Local_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_from_init_local_get_global_state :: proc(info: V2_Copy_From_Init_Local_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_from_init_local_set_local_state :: proc(info: V2_Copy_From_Init_Local_Info_Handle, data: ^V2_Opaque, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_from_exec_get_user_data         :: proc(info: V2_Copy_From_Exec_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_from_exec_get_bind_data         :: proc(info: V2_Copy_From_Exec_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_from_exec_get_global_state      :: proc(info: V2_Copy_From_Exec_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_from_exec_get_local_state       :: proc(info: V2_Copy_From_Exec_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_from_exec_get_output_chunk      :: proc(info: V2_Copy_From_Exec_Info_Handle, chunk: ^V2_Data_Chunk_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_from_progress_get_user_data     :: proc(info: V2_Copy_From_Progress_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_from_progress_get_bind_data     :: proc(info: V2_Copy_From_Progress_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_from_progress_get_global_state  :: proc(info: V2_Copy_From_Progress_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_from_progress_set_progress      :: proc(info: V2_Copy_From_Progress_Info_Handle, progress: f64, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_connection_register_copy_function    :: proc(conn: V2_Connection_Handle, fn: V2_Copy_Function_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_copy_function_destroy                :: proc(fn: ^V2_Copy_Function_Handle) -> V2_Error ---

	// Expression & Table Filter Pushdown / Multi-File (`duckdb_v2.h` lines 8444-8619, 12852-14376)
	duckdb_v2_expression_get_type                  :: proc(expression: V2_Expression_Handle, type: ^V2_Expression_Type, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_expression_get_return_type           :: proc(expression: V2_Expression_Handle, type: ^V2_Logical_Type_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_expression_get_child_count           :: proc(expression: V2_Expression_Handle, count: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_expression_get_child                 :: proc(expression: V2_Expression_Handle, index: V2_Idx, child: ^V2_Expression_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_expression_constant_get_value        :: proc(expression: V2_Expression_Handle, value: ^V2_Value_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_expression_column_ref_get_index      :: proc(expression: V2_Expression_Handle, index: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_expression_function_get_name         :: proc(expression: V2_Expression_Handle, name: ^V2_Identifier, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_expression_function_get_qname        :: proc(expression: V2_Expression_Handle, name: ^V2_Qname_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_expression_cast_get_mode             :: proc(expression: V2_Expression_Handle, mode: ^V2_Cast_Mode, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_set_filter_pushdown_callback :: proc(fn: V2_Table_Function_Handle, callback: V2_Table_Function_Filter_Pushdown_Callback_Fn, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_filter_pushdown_get_user_data :: proc(info: V2_Table_Function_Filter_Pushdown_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_filter_pushdown_get_bind_data :: proc(info: V2_Table_Function_Filter_Pushdown_Info_Handle, data: ^rawptr, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_filter_pushdown_get_filter_count :: proc(info: V2_Table_Function_Filter_Pushdown_Info_Handle, count: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_filter_pushdown_get_filter :: proc(info: V2_Table_Function_Filter_Pushdown_Info_Handle, index: V2_Idx, filter: ^V2_Expression_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_filter_pushdown_accept :: proc(info: V2_Table_Function_Filter_Pushdown_Info_Handle, index: V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_filter_pushdown_get_column_count :: proc(info: V2_Table_Function_Filter_Pushdown_Info_Handle, count: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_table_function_filter_pushdown_get_column_index :: proc(info: V2_Table_Function_Filter_Pushdown_Info_Handle, index: V2_Idx, column_index: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_multi_file_function_create           :: proc(factory: V2_Factory_Handle, fn: ^V2_Multi_File_Function_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_multi_file_function_set_name         :: proc(fn: V2_Multi_File_Function_Handle, name: ^V2_Str, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_multi_file_function_set_single_file_function :: proc(fn: V2_Multi_File_Function_Handle, name: ^V2_Str, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_multi_file_function_set_reader_type  :: proc(fn: V2_Multi_File_Function_Handle, reader_type: ^V2_Str, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_multi_file_function_set_file_extension :: proc(fn: V2_Multi_File_Function_Handle, extension: ^V2_Str, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_connection_register_multi_file_function :: proc(conn: V2_Connection_Handle, fn: V2_Multi_File_Function_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_multi_file_function_destroy          :: proc(fn: ^V2_Multi_File_Function_Handle) -> V2_Error ---

	// Macro Function & Extension Registration (`duckdb_v2.h` lines 9471-9605)
	duckdb_v2_macro_function_create                :: proc(factory: V2_Factory_Handle, type: V2_Macro_Function_Type, fn: ^V2_Macro_Function_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_macro_function_set_name              :: proc(fn: V2_Macro_Function_Handle, name: ^V2_Identifier, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_macro_function_set_body              :: proc(fn: V2_Macro_Function_Handle, body: ^V2_Str, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_macro_function_get_signature         :: proc(fn: V2_Macro_Function_Handle, sig: ^V2_Function_Signature_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_macro_function_get_docs              :: proc(fn: V2_Macro_Function_Handle, docs: ^V2_Function_Docs_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_macro_function_destroy               :: proc(fn: ^V2_Macro_Function_Handle) -> V2_Error ---
	duckdb_v2_extension_register_scalar_function   :: proc(extension: V2_Extension_Handle, fn: V2_Scalar_Function_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_extension_register_aggregate_function :: proc(extension: V2_Extension_Handle, fn: V2_Aggregate_Function_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_extension_register_table_function    :: proc(extension: V2_Extension_Handle, fn: V2_Table_Function_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_extension_register_copy_function     :: proc(extension: V2_Extension_Handle, fn: V2_Copy_Function_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_extension_register_pragma_function   :: proc(extension: V2_Extension_Handle, fn: V2_Pragma_Function_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_extension_register_macro_function    :: proc(extension: V2_Extension_Handle, fn: V2_Macro_Function_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_extension_register_custom_type       :: proc(extension: V2_Extension_Handle, type: V2_Custom_Type_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_extension_register_cast_function     :: proc(extension: V2_Extension_Handle, fn: V2_Cast_Function_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_extension_register_replacement_scan  :: proc(extension: V2_Extension_Handle, scan: V2_Replacement_Scan_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_extension_register_custom_option     :: proc(extension: V2_Extension_Handle, option: V2_Custom_Option_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_extension_register_log_sink          :: proc(extension: V2_Extension_Handle, sink: V2_Log_Sink_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_extension_register_multi_file_function :: proc(extension: V2_Extension_Handle, fn: V2_Multi_File_Function_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---

	// Arrow Exporter & Importer (`duckdb_v2.h` lines 16043-16300)
	duckdb_v2_arrow_importer_create     :: proc(ctx: V2_Context_Handle, schema: ^Arrow_Schema, batch_size: V2_Idx, out_importer: ^V2_Arrow_Importer_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_arrow_importer_get_schema :: proc(importer: V2_Arrow_Importer_Handle, out_schema: ^V2_Schema_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_arrow_importer_append     :: proc(importer: V2_Arrow_Importer_Handle, array: ^Arrow_Array, consume: bool, flush: bool, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_arrow_importer_next_chunk :: proc(importer: V2_Arrow_Importer_Handle, out_chunk: ^V2_Data_Chunk_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_arrow_importer_destroy    :: proc(importer: ^V2_Arrow_Importer_Handle) -> V2_Error ---
	duckdb_v2_arrow_exporter_create     :: proc(ctx: V2_Context_Handle, types: ^V2_Logical_Type_Handle, names: ^V2_Str, count: V2_Idx, batch_size: V2_Idx, out_exporter: ^V2_Arrow_Exporter_Handle, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_arrow_exporter_get_schema :: proc(exporter: V2_Arrow_Exporter_Handle, out_schema: ^Arrow_Schema, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_arrow_exporter_append     :: proc(exporter: V2_Arrow_Exporter_Handle, chunk: ^V2_Data_Chunk_Handle, consume: bool, flush: bool, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_arrow_exporter_next_array :: proc(exporter: V2_Arrow_Exporter_Handle, out_array: ^Arrow_Array, err: ^V2_Error_Info_Handle) -> V2_Error ---
	duckdb_v2_arrow_exporter_destroy    :: proc(exporter: ^V2_Arrow_Exporter_Handle) -> V2_Error ---
}

// ----------------------------------------------------------------------------
// Zero-Copy String, Bytes, BIT & Vector View Helpers
// ----------------------------------------------------------------------------
// Ported directly from:
// - `references/c/duckdb-capi-2.0/test/api/capi/v2/test_capi_v2.hpp` lines 127-151, 505-536
// - `references/c/duckdb-capi-2.0/test/api/capi/v2/test_capi_v2_bytes.cpp` lines 19-46

v2_str_from_string :: #force_inline proc "contextless" (s: string) -> V2_Str {
	if len(s) == 0 {
		return V2_Str{ptr = nil, len = 0}
	}
	return V2_Str{ptr = raw_data(s), len = V2_Idx(len(s))}
}

v2_str_to_string :: #force_inline proc "contextless" (s: V2_Str) -> string {
	if s.ptr == nil || s.len == 0 {
		return ""
	}
	return string(s.ptr[:s.len])
}

v2_bytes_is_inlined :: #force_inline proc "contextless" (b: ^V2_Bytes) -> bool {
	return b.inlined.length <= V2_BYTES_INLINE_LENGTH
}

v2_bytes_length :: #force_inline proc "contextless" (b: ^V2_Bytes) -> u32 {
	return b.inlined.length
}

v2_bytes_data :: #force_inline proc "contextless" (b: ^V2_Bytes) -> [^]u8 {
	if v2_bytes_is_inlined(b) {
		return &b.inlined.inlined[0]
	}
	return b.pointer.ptr
}

v2_bytes_to_string :: #force_inline proc "contextless" (b: ^V2_Bytes) -> string {
	n := int(v2_bytes_length(b))
	if n == 0 {
		return ""
	}
	return string(v2_bytes_data(b)[:n])
}

// BIT wire format (`test_capi_v2_bytes.cpp` lines 31-41):
// byte 0 is the padding-bit count; bytes 1.. are the payload.
v2_bit_padding :: #force_inline proc "contextless" (b: ^V2_Bytes) -> u8 {
	if v2_bytes_length(b) == 0 {
		return 0
	}
	return v2_bytes_data(b)[0]
}

v2_bit_count :: #force_inline proc "contextless" (b: ^V2_Bytes) -> u64 {
	length := v2_bytes_length(b)
	if length == 0 {
		return 0
	}
	return u64(length - 1) * 8 - u64(v2_bytes_data(b)[0])
}

v2_bit_data :: #force_inline proc "contextless" (b: ^V2_Bytes) -> [^]u8 {
	if v2_bytes_length(b) <= 1 {
		return nil
	}
	return v2_bytes_data(b)[1:]
}

// BIGNUM sign encoding (`test_capi_v2_bytes.cpp` lines 43-46):
// MSB of data[0] clear = negative, set = positive.
v2_bignum_is_negative :: #force_inline proc "contextless" (b: ^V2_Bytes) -> bool {
	if v2_bytes_length(b) == 0 {
		return false
	}
	return (v2_bytes_data(b)[0] & 0x80) == 0
}

// Vector view selection & validity helpers (`test_capi_v2.hpp` lines 505-516):
v2_sel_at :: #force_inline proc "contextless" (sel: [^]V2_Sel, i: V2_Idx) -> V2_Idx {
	if sel == nil {
		return i
	}
	return V2_Idx(sel[i])
}

v2_row_is_valid :: #force_inline proc "contextless" (view: V2_Vector_View, logical_row: V2_Idx) -> bool {
	phys := v2_sel_at(view.sel, logical_row)
	if view.validity == nil {
		return true
	}
	return (view.validity[phys / 64] & (u64(1) << (phys % 64))) != 0
}

// Physical validity mask bit helpers (`test_cpp_api_vector.cpp` lines 426-498):
v2_validity_row_is_valid :: #force_inline proc "contextless" (validity: [^]u64, phys_row: V2_Idx) -> bool {
	if validity == nil {
		return true
	}
	return (validity[phys_row / 64] & (u64(1) << (phys_row % 64))) != 0
}

v2_validity_set_valid :: #force_inline proc "contextless" (validity: [^]u64, phys_row: V2_Idx) {
	validity[phys_row / 64] |= (u64(1) << (phys_row % 64))
}

v2_validity_set_invalid :: #force_inline proc "contextless" (validity: [^]u64, phys_row: V2_Idx) {
	validity[phys_row / 64] &= ~(u64(1) << (phys_row % 64))
}

// Release helpers for Arrow C Data Interface structs (`duckdb_v2.h` lines 139-176):
arrow_schema_release :: proc "contextless" (schema: ^Arrow_Schema) {
	if schema != nil && schema.release != nil {
		schema.release(schema)
	}
}

arrow_array_release :: proc "contextless" (array: ^Arrow_Array) {
	if array != nil && array.release != nil {
		array.release(array)
	}
}

arrow_stream_release :: proc "contextless" (stream: ^Arrow_Array_Stream) {
	if stream != nil && stream.release != nil {
		stream.release(stream)
	}
}

// Assembles a `V2_Bytes` in a vector's arena (`test_capi_v2.hpp` lines 216-250, 518-536):
v2_vector_assign_string :: proc "contextless" (vec: V2_Vector_Handle, index: V2_Idx, s: string, err: ^V2_Error_Info_Handle = nil) -> V2_Error {
	return v2_vector_assign_bytes(vec, index, transmute([]u8)s, err)
}

v2_vector_assign_bytes :: proc "contextless" (vec: V2_Vector_Handle, index: V2_Idx, data: []u8, err: ^V2_Error_Info_Handle = nil) -> V2_Error {
	arena: V2_Arena_Handle
	rc := duckdb_v2_vector_get_arena(vec, &arena, err)
	if rc != .NONE {
		return rc
	}

	storage: V2_Bytes
	if len(data) <= V2_BYTES_INLINE_LENGTH {
		storage.inlined.length = u32(len(data))
		if len(data) > 0 {
			intrinsics.mem_copy(&storage.inlined.inlined[0], raw_data(data), len(data))
		}
	} else {
		bytes_ptr: [^]u8
		rc = duckdb_v2_arena_allocate(arena, V2_Idx(len(data)), &bytes_ptr, err)
		if rc != .NONE {
			return rc
		}
		intrinsics.mem_copy(bytes_ptr, raw_data(data), len(data))
		storage.pointer.length = u32(len(data))
		storage.pointer.ptr = bytes_ptr
		intrinsics.mem_copy(&storage.pointer.prefix[0], bytes_ptr, 4)
	}

	raw: rawptr
	rc = duckdb_v2_vector_get_data_mutable(vec, &raw, err)
	if rc != .NONE {
		return rc
	}
	arr := cast([^]V2_Bytes)raw
	arr[index] = storage
	return .NONE
}

// Obtains a readable `V2_Vector_View` for `vec`, automatically flattening `.OTHER`
// encodings (`SEQUENCE`, `FSST`, `SHREDDED`) first so `duckdb_v2_vector_get_view` succeeds.
v2_vector_get_readable_view :: proc "contextless" (
	vec: V2_Vector_Handle,
	out_view: ^V2_Vector_View,
	err: ^V2_Error_Info_Handle = nil,
) -> V2_Error {
	vtype: V2_Vector_Type
	if rc := duckdb_v2_vector_get_vector_type(vec, &vtype, err); rc != .NONE {
		return rc
	}
	if vtype == .OTHER {
		if rc := duckdb_v2_vector_flatten(vec, err); rc != .NONE {
			return rc
		}
	}
	return duckdb_v2_vector_get_view(vec, out_view, err)
}

// Two-call buffer sizing protocol (`duckdb_v2.h` `FillCallerText` convention:
// call 1 with `nil, 0` reports required length excluding NUL; call 2 requires `length + 1` capacity).
v2_two_call_string :: proc(
	handle: $H,
	to_text_fn: proc "c" (h: H, out_text: [^]u8, out_cap: V2_Idx, out_len: ^V2_Idx, err: ^V2_Error_Info_Handle) -> V2_Error,
	err: ^V2_Error_Info_Handle = nil,
	allocator := context.temp_allocator,
) -> (string, V2_Error) {
	length: V2_Idx
	rc := to_text_fn(handle, nil, 0, &length, err)
	if rc != .NONE {
		return "", rc
	}
	buf := make([]u8, int(length) + 1, allocator)
	rc = to_text_fn(handle, raw_data(buf), length + 1, &length, err)
	if rc != .NONE {
		return "", rc
	}
	return string(buf[:int(length)]), .NONE
}

// Renders a SQL identifier using DuckDB 2.0's `duckdb_v2_identifier_render_quoted` rules:
// bare valid identifiers pass through unchanged (`sensor_readings` -> `sensor_readings`),
// while SQL reserved words, spaces, leading digits, and embedded quotes are double-quoted
// (`select` -> `"select"`, `my col` -> `"my col"`, `a"b` -> `"a""b"`).
// Supports dot-separated qualified table names (e.g. `schema.table`) when `allow_qualified` is true.
v2_quote_identifier :: proc(
	name: string,
	allow_qualified := false,
	allocator := context.temp_allocator,
) -> string {
	if len(name) == 0 {
		return `""`
	}
	if allow_qualified {
		qname: V2_Qname_Handle
		view := v2_str_from_string(name)
		if duckdb_v2_qname_parse(&view, &qname, nil) == .NONE && qname != nil {
			defer duckdb_v2_qname_destroy(&qname)
			if rendered, rc := v2_two_call_string(qname, duckdb_v2_qname_render, nil, allocator); rc == .NONE {
				return rendered
			}
		}
	}
	ident := V2_Identifier(v2_str_from_string(name))
	length: V2_Idx
	if duckdb_v2_identifier_render_quoted(&ident, nil, 0, &length, nil) != .NONE {
		return name
	}
	buf := make([]u8, int(length) + 1, allocator)
	if duckdb_v2_identifier_render_quoted(&ident, raw_data(buf), length + 1, &length, nil) != .NONE {
		return name
	}
	return string(buf[:int(length)])
}

// ----------------------------------------------------------------------------
// High-Level C API v2 Session, Parameter Boxing, Execution & Transaction API
// ----------------------------------------------------------------------------

V2_Database :: struct {
	env:      V2_Environment_Handle,
	instance: V2_Instance_Handle,
	conn:     V2_Connection_Handle,
	factory:  V2_Factory_Handle,
	path:     string,
}

// Opens a DuckDB 2.0 instance under `env`, attaches `path` (`""` for `:memory:`), and sets it as default.
v2_open_instance :: proc(
	env: V2_Environment_Handle,
	path: string = "",
	out_instance: ^V2_Instance_Handle,
	err: ^V2_Error_Info_Handle = nil,
) -> V2_Error {
	rc := duckdb_v2_instance_create(env, out_instance, err)
	if rc != .NONE {
		return rc
	}
	path_str := v2_str_from_string(path)
	rc = duckdb_v2_instance_attach(out_instance^, nil, &path_str, nil, true, err)
	if rc != .NONE {
		duckdb_v2_instance_destroy(out_instance)
	}
	return rc
}

// Opens a self-contained `V2_Database` session (Environment, Instance, Connection, and Factory).
v2_open :: proc(path: string = "", err: ^V2_Error_Info_Handle = nil) -> (db: V2_Database, rc: V2_Error) {
	db.path = path
	rc = duckdb_v2_environment_create(&db.env, err)
	if rc != .NONE {
		return db, rc
	}
	rc = v2_open_instance(db.env, path, &db.instance, err)
	if rc != .NONE {
		_ = duckdb_v2_environment_destroy(&db.env)
		return db, rc
	}
	rc = duckdb_v2_connection_create(db.instance, &db.conn, err)
	if rc != .NONE {
		_ = duckdb_v2_instance_destroy(&db.instance)
		_ = duckdb_v2_environment_destroy(&db.env)
		return db, rc
	}
	rc = duckdb_v2_connection_get_factory(db.conn, &db.factory, err)
	if rc != .NONE {
		_ = v2_close(&db)
	}
	return db, rc
}

// Closes a `V2_Database` session in reverse lifecycle order (`conn` -> `instance` -> `env`).
v2_close :: proc(db: ^V2_Database) -> V2_Error {
	db.factory = nil
	if db.conn != nil {
		if rc := duckdb_v2_connection_destroy(&db.conn); rc != .NONE {
			return rc
		}
	}
	if db.instance != nil {
		if rc := duckdb_v2_instance_destroy(&db.instance); rc != .NONE {
			return rc
		}
	}
	if db.env != nil {
		if rc := duckdb_v2_environment_destroy(&db.env); rc != .NONE {
			return rc
		}
	}
	return .NONE
}

// Extracts and clones the error code and text from `err`, then destroys the error handle.
v2_consume_error_text :: proc(
	err: ^V2_Error_Info_Handle,
	allocator := context.temp_allocator,
) -> (code: V2_Error, message: string) {
	if err == nil || err^ == nil {
		return .NONE, ""
	}
	_ = duckdb_v2_error_info_get_code(err^, &code)
	raw_str: V2_Str
	_ = duckdb_v2_error_info_get_text(err^, &raw_str)
	message = strings.clone(v2_str_to_string(raw_str), allocator)
	_ = duckdb_v2_error_info_destroy(err)
	return code, message
}

// Boxes an arbitrary Odin scalar, `string`, `[]u8`, `V2_Hugeint`, `V2_Uhugeint`, `V2_Interval`,
// `Maybe(T)`, or `nil` into a `V2_Value_Handle` for parameterized query execution.
v2_create_value_from_any :: proc(
	factory: V2_Factory_Handle,
	arg: any,
	out_val: ^V2_Value_Handle,
	err: ^V2_Error_Info_Handle = nil,
) -> V2_Error {
	if out_val != nil {
		out_val^ = nil
	}
	if arg == nil || arg.data == nil {
		sql_null_type: V2_Logical_Type_Handle
		if rc := duckdb_v2_factory_create_type_from_id(factory, .SQLNULL, nil, nil, 0, &sql_null_type, err); rc != .NONE {
			return rc
		}
		defer duckdb_v2_logical_type_destroy(&sql_null_type)
		return duckdb_v2_value_create_null(factory, sql_null_type, out_val, err)
	}

	ti := reflect.type_info_base(type_info_of(arg.id))
	if u, is_u := ti.variant.(reflect.Type_Info_Union); is_u && len(u.variants) == 1 && !u.no_nil {
		sub := reflect.get_union_variant(arg)
		if sub == nil {
			_, tid, ok := odin_type_to_duckdb_sql(u.variants[0])
			if !ok {
				tid = .SQLNULL
			}
			null_t: V2_Logical_Type_Handle
			if rc := duckdb_v2_factory_create_type_from_id(factory, tid, nil, nil, 0, &null_t, err); rc != .NONE {
				return rc
			}
			defer duckdb_v2_logical_type_destroy(&null_t)
			return duckdb_v2_value_create_null(factory, null_t, out_val, err)
		}
		return v2_create_value_from_any(factory, sub, out_val, err)
	}

	switch v in arg {
	case V2_Value_Handle:
		out_val^ = v
		return .NONE
	case V2_Hugeint:
		tmp := v
		return duckdb_v2_value_create_hugeint(factory, &tmp, out_val, err)
	case V2_Uhugeint:
		tmp := v
		return duckdb_v2_value_create_uhugeint(factory, &tmp, out_val, err)
	case V2_Interval:
		tmp := v
		return duckdb_v2_value_create_interval(factory, &tmp, out_val, err)
	case []u8:
		s := V2_Str{ptr = raw_data(v), len = V2_Idx(len(v))}
		return duckdb_v2_value_create_blob(factory, &s, out_val, err)
	}

	#partial switch v in ti.variant {
	case reflect.Type_Info_Boolean:
		return duckdb_v2_value_create_bool(factory, (cast(^bool)arg.data)^, out_val, err)
	case reflect.Type_Info_Integer:
		if v.signed {
			switch ti.size {
			case 1:
				return duckdb_v2_value_create_tinyint(factory, (cast(^i8)arg.data)^, out_val, err)
			case 2:
				return duckdb_v2_value_create_smallint(factory, (cast(^i16)arg.data)^, out_val, err)
			case 4:
				return duckdb_v2_value_create_int(factory, (cast(^i32)arg.data)^, out_val, err)
			case 8:
				return duckdb_v2_value_create_bigint(factory, (cast(^i64)arg.data)^, out_val, err)
			}
		} else {
			switch ti.size {
			case 1:
				return duckdb_v2_value_create_utinyint(factory, (cast(^u8)arg.data)^, out_val, err)
			case 2:
				return duckdb_v2_value_create_usmallint(factory, (cast(^u16)arg.data)^, out_val, err)
			case 4:
				return duckdb_v2_value_create_uint(factory, (cast(^u32)arg.data)^, out_val, err)
			case 8:
				return duckdb_v2_value_create_ubigint(factory, (cast(^u64)arg.data)^, out_val, err)
			}
		}
	case reflect.Type_Info_Float:
		switch ti.size {
		case 4:
			return duckdb_v2_value_create_float(factory, (cast(^f32)arg.data)^, out_val, err)
		case 8:
			return duckdb_v2_value_create_double(factory, (cast(^f64)arg.data)^, out_val, err)
		}
	case reflect.Type_Info_String:
		if v.is_cstring {
			cs := (cast(^cstring)arg.data)^
			s := v2_str_from_string(string(cs))
			return duckdb_v2_value_create_varchar(factory, &s, out_val, err)
		}
		s := v2_str_from_string((cast(^string)arg.data)^)
		return duckdb_v2_value_create_varchar(factory, &s, out_val, err)
	}

	return .INPUT_INVALID
}

// Parses a single SQL statement from `sql` into `out_stmt`.
v2_parse_single_stmt :: proc(
	conn: V2_Connection_Handle,
	sql: string,
	out_stmt: ^V2_Sql_Statement_Handle,
	err: ^V2_Error_Info_Handle = nil,
) -> V2_Error {
	if out_stmt != nil {
		out_stmt^ = nil
	}
	sql_cstr := strings.clone_to_cstring(sql, context.temp_allocator)
	iter: V2_Statement_Iterator_Handle
	rc := duckdb_v2_parse_sql(conn, sql_cstr, &iter, err)
	if rc != .NONE {
		return rc
	}
	defer duckdb_v2_statement_iterator_destroy(&iter)
	return duckdb_v2_statement_iterator_next(iter, out_stmt, err)
}

// Parses and executes a single SQL statement with optional positional `args` (`..any`).
v2_query :: proc(
	conn: V2_Connection_Handle,
	sql: string,
	out_result: ^V2_Result_Handle,
	err: ^V2_Error_Info_Handle = nil,
	args: ..any,
) -> V2_Error {
	if out_result != nil {
		out_result^ = nil
	}
	stmt: V2_Sql_Statement_Handle
	rc := v2_parse_single_stmt(conn, sql, &stmt, err)
	if rc != .NONE || stmt == nil {
		return rc
	}
	defer duckdb_v2_sql_statement_destroy(&stmt)

	if len(args) == 0 {
		return duckdb_v2_statement_execute(conn, stmt, nil, nil, 0, out_result, err)
	}

	factory: V2_Factory_Handle
	if rc = duckdb_v2_connection_get_factory(conn, &factory, err); rc != .NONE {
		return rc
	}

	vals := make([]V2_Value_Handle, len(args), context.temp_allocator)
	defer {
		for &v in vals {
			if v != nil {
				duckdb_v2_value_destroy(&v)
			}
		}
	}

	for a, idx in args {
		if rc = v2_create_value_from_any(factory, a, &vals[idx], err); rc != .NONE {
			return rc
		}
	}

	return duckdb_v2_statement_execute(conn, stmt, nil, raw_data(vals), V2_Idx(len(vals)), out_result, err)
}

// Executes a DDL/DML statement to completion via `duckdb_v2_result_drain` with optional positional `args`.
v2_exec_drain :: proc(
	conn: V2_Connection_Handle,
	sql: string,
	out_rows_changed: ^V2_Idx = nil,
	err: ^V2_Error_Info_Handle = nil,
	args: ..any,
) -> V2_Error {
	result: V2_Result_Handle
	rc := v2_query(conn, sql, &result, err, ..args)
	if rc != .NONE {
		return rc
	}
	defer duckdb_v2_result_destroy(&result)

	changed: V2_Idx
	rc = duckdb_v2_result_drain(result, &changed, err)
	if out_rows_changed != nil {
		out_rows_changed^ = changed
	}
	return rc
}

// Steps a streaming `V2_Result_Handle` to its next chunk, waiting on `WAITING` via `duckdb_v2_result_wait`.
v2_step_chunk :: proc(
	result: V2_Result_Handle,
	out_chunk: ^V2_Data_Chunk_Handle,
	err: ^V2_Error_Info_Handle = nil,
) -> (status: V2_Result_Step_Status, rc: V2_Error) {
	for {
		out_chunk^ = nil
		rc = duckdb_v2_result_step(result, out_chunk, &status, err)
		if rc != .NONE {
			return status, rc
		}
		switch status {
		case .CHUNK, .FINISHED, .CANCELLED:
			return status, .NONE
		case .WAITING:
			rc = duckdb_v2_result_wait(result, err)
			if rc != .NONE {
				return status, rc
			}
		}
	}
}

// Parses and prepares a single SQL statement on `conn`.
v2_prepare :: proc(
	conn: V2_Connection_Handle,
	sql: string,
	require_cacheable: bool = false,
	out_prepared: ^V2_Prepared_Statement_Handle,
	err: ^V2_Error_Info_Handle = nil,
) -> V2_Error {
	if out_prepared != nil {
		out_prepared^ = nil
	}
	stmt: V2_Sql_Statement_Handle
	rc := v2_parse_single_stmt(conn, sql, &stmt, err)
	if rc != .NONE || stmt == nil {
		return rc
	}
	defer duckdb_v2_sql_statement_destroy(&stmt)
	return duckdb_v2_prepared_statement_create(conn, stmt, require_cacheable, out_prepared, err)
}

// Executes `body` inside a `BEGIN TRANSACTION ... COMMIT` block, automatically issuing `ROLLBACK` on error.
v2_with_transaction :: proc(
	conn: V2_Connection_Handle,
	body: proc(conn: V2_Connection_Handle, user_data: rawptr, err: ^V2_Error_Info_Handle) -> V2_Error,
	user_data: rawptr = nil,
	err: ^V2_Error_Info_Handle = nil,
) -> V2_Error {
	if rc := v2_exec_drain(conn, "BEGIN TRANSACTION", nil, err); rc != .NONE {
		return rc
	}
	if rc := body(conn, user_data, err); rc != .NONE {
		_ = v2_exec_drain(conn, "ROLLBACK", nil, nil)
		return rc
	}
	return v2_exec_drain(conn, "COMMIT", nil, err)
}
