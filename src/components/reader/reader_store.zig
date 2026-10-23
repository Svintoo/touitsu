const std = @import("std");
const HANDLE = ?*anyopaque;
extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, sa: ?*anyopaque, disposition: u32, flags: u32, template: ?*anyopaque) callconv(.winapi) HANDLE;
extern "kernel32" fn GetFileSizeEx(h: HANDLE, size: *i64) callconv(.winapi) i32;
extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, n: u32, read: *u32, overlapped: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, n: u32, written: *u32, overlapped: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn MoveFileExW(from: [*:0]const u16, to: [*:0]const u16, flags: u32) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) i32;
extern "kernel32" fn GetModuleFileNameW(module: HANDLE, buf: [*]u16, size: u32) callconv(.winapi) u32;

const GENERIC_READ: u32 = 0x80000000;
const GENERIC_WRITE: u32 = 0x40000000;
const FILE_SHARE_READ: u32 = 1;
const CREATE_ALWAYS: u32 = 2;
const OPEN_EXISTING: u32 = 3;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;

fn isInvalid(h: HANDLE) bool {
    return h == null or @intFromPtr(h.?) == std.math.maxInt(usize);
}

pub fn readAll(alloc: std.mem.Allocator, path: [*:0]const u16) !?[]u8 {
    return readAllLimited(alloc, path, 16 * 1024 * 1024);
}

pub fn readAllLimited(alloc: std.mem.Allocator, path: [*:0]const u16, max_bytes: i64) !?[]u8 {
    const h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
    if (isInvalid(h)) return null; // no file yet
    defer _ = CloseHandle(h);
    var size: i64 = 0;
    if (GetFileSizeEx(h, &size) == 0 or size < 0 or size > max_bytes) return error.BadFile;
    const buf = try alloc.alloc(u8, @intCast(size));
    errdefer alloc.free(buf);
    var done: usize = 0;
    while (done < buf.len) {
        var n: u32 = 0;
        if (ReadFile(h, buf.ptr + done, @intCast(buf.len - done), &n, null) == 0 or n == 0) break;
        done += n;
    }
    if (done != buf.len) return error.ShortRead;
    return buf;
}

fn writeRaw(path: [*:0]const u16, data: []const u8) !void {
    const h = CreateFileW(path, GENERIC_WRITE, 0, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    if (isInvalid(h)) return error.CantWriteFile;
    defer _ = CloseHandle(h);
    var done: usize = 0;
    while (done < data.len) {
        var n: u32 = 0;
        if (WriteFile(h, data.ptr + done, @intCast(data.len - done), &n, null) == 0 or n == 0) return error.CantWriteFile;
        done += n;
    }
}

/// <directory of the running exe>\hooks.txt
pub fn defaultPath(alloc: std.mem.Allocator) ![:0]u16 {
    var buf: [1024]u16 = undefined;
    const n = GetModuleFileNameW(null, &buf, buf.len);
    if (n == 0 or n >= buf.len) return error.NoModulePath;
    var end: usize = n;
    while (end > 0 and buf[end - 1] != '\\') end -= 1;
    const name = std.unicode.utf8ToUtf16LeStringLiteral("reader-history.json");
    const out = try alloc.allocSentinel(u16, end + name.len, 0);
    for (buf[0..end], 0..) |c, i| out[i] = c;
    for (name, 0..) |c, i| out[end + i] = c;
    return out;
}

/// Replace the history only after a complete temporary file has been written.
pub fn writeAll(path: [*:0]const u16, data: []const u8) !void {
    const original = std.mem.span(path);
    const suffix = std.unicode.utf8ToUtf16LeStringLiteral(".tmp");
    const temp = try std.heap.smp_allocator.allocSentinel(u16, original.len + suffix.len, 0);
    defer std.heap.smp_allocator.free(temp);
    @memcpy(temp[0..original.len], original);
    @memcpy(temp[original.len..], suffix);
    try writeRaw(temp, data);
    if (MoveFileExW(temp, path, 1 | 8) == 0) return error.CantReplaceHistory;
}

test {
    _ = @import("../../tests/components/reader/reader_store.zig");
}
