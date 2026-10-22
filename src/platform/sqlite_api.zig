//! Small, explicit subset of SQLite's stable C API (see bundled sqlite3.h).
pub const sqlite3 = opaque {};
pub const sqlite3_stmt = opaque {};
pub const SQLITE_OK = 0;
pub const SQLITE_ROW = 100;
pub const SQLITE_DONE = 101;
pub const SQLITE_OPEN_READWRITE = 0x2;
pub const SQLITE_OPEN_CREATE = 0x4;
pub const SQLITE_OPEN_FULLMUTEX = 0x10000;
pub extern fn sqlite3_open_v2([*:0]const u8, *?*sqlite3, c_int, ?[*:0]const u8) c_int;
pub extern fn sqlite3_close(*sqlite3) c_int;
pub extern fn sqlite3_busy_timeout(*sqlite3, c_int) c_int;
pub extern fn sqlite3_exec(*sqlite3, [*:0]const u8, ?*const fn (?*anyopaque, c_int, ?*anyopaque, ?*anyopaque) callconv(.c) c_int, ?*anyopaque, ?*?[*:0]u8) c_int;
pub extern fn sqlite3_prepare_v2(*sqlite3, [*:0]const u8, c_int, *?*sqlite3_stmt, ?*?[*:0]const u8) c_int;
pub extern fn sqlite3_bind_text(*sqlite3_stmt, c_int, [*]const u8, c_int, ?*const fn (?*anyopaque) callconv(.c) void) c_int;
pub extern fn sqlite3_bind_int64(*sqlite3_stmt, c_int, i64) c_int;
pub extern fn sqlite3_step(*sqlite3_stmt) c_int;
pub extern fn sqlite3_reset(*sqlite3_stmt) c_int;
pub extern fn sqlite3_finalize(*sqlite3_stmt) c_int;
pub extern fn sqlite3_column_text(*sqlite3_stmt, c_int) ?[*]const u8;
pub extern fn sqlite3_column_bytes(*sqlite3_stmt, c_int) c_int;
pub extern fn sqlite3_column_int64(*sqlite3_stmt, c_int) i64;
pub extern fn sqlite3_last_insert_rowid(*sqlite3) i64;

pub extern fn sqlite3_bind_blob(*sqlite3_stmt, c_int, [*]const u8, c_int, ?*const fn (?*anyopaque) callconv(.c) void) c_int;
pub extern fn sqlite3_column_blob(*sqlite3_stmt, c_int) ?[*]const u8;
