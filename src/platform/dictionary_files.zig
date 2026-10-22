//! File access for dictionary archives and the per-install SQLite database.
const std = @import("std");
const a = std.heap.smp_allocator;
const HANDLE = ?*anyopaque;
extern "kernel32" fn GetModuleFileNameW(HANDLE, [*]u16, u32) callconv(.winapi) u32;
extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?*anyopaque) callconv(.winapi) HANDLE;
extern "kernel32" fn GetFileSizeEx(HANDLE, *i64) callconv(.winapi) i32;
extern "kernel32" fn ReadFile(HANDLE, [*]u8, u32, *u32, ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(HANDLE) callconv(.winapi) i32;

pub fn siblingPath(name: []const u8) ![:0]u8 {
    var buf: [32768]u16 = undefined;
    const n = GetModuleFileNameW(null, &buf, buf.len);
    if (n == 0 or n >= buf.len) return error.NoExecutablePath;
    var end: usize = n;
    while (end > 0 and buf[end - 1] != '\\') end -= 1;
    const directory = try std.unicode.utf16LeToUtf8Alloc(a, buf[0..end]);
    defer a.free(directory);
    return std.fmt.allocPrintSentinel(a, "{s}{s}", .{ directory, name }, 0);
}

pub fn databasePath() ![:0]u8 {
    return siblingPath("dictionaries.sqlite3");
}

extern "kernel32" fn CreateFileMappingW(HANDLE, ?*anyopaque, u32, u32, u32, ?[*:0]const u16) callconv(.winapi) HANDLE;
extern "kernel32" fn MapViewOfFile(HANDLE, u32, u32, u32, usize) callconv(.winapi) ?[*]const u8;
extern "kernel32" fn UnmapViewOfFile([*]const u8) callconv(.winapi) i32;

pub const MappedArchive = struct {
    bytes: []const u8,
    handle: HANDLE,
    mapping: HANDLE,
    pub fn deinit(self: @This()) void {
        _ = UnmapViewOfFile(self.bytes.ptr);
        _ = CloseHandle(self.mapping);
        _ = CloseHandle(self.handle);
    }
};
// Let Windows page compressed ZIP data as needed instead of allocating a ZIP-sized buffer.
pub fn mapArchive(path: []const u8) !MappedArchive {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
    defer a.free(wide);
    const handle = CreateFileW(wide, 0x80000000, 1, null, 3, 0x80, null);
    if (handle == null or @intFromPtr(handle.?) == std.math.maxInt(usize)) return error.CannotOpenDictionaryZip;
    errdefer _ = CloseHandle(handle);
    var size: i64 = 0;
    if (GetFileSizeEx(handle, &size) == 0 or size <= 0) return error.CannotReadDictionaryZip;
    // The archive reader currently supports ordinary ZIP, not ZIP64.
    if (size > std.math.maxInt(u32)) return error.Zip64NotSupported;
    const mapping = CreateFileMappingW(handle, null, 2, 0, 0, null) orelse return error.CannotMapDictionaryZip;
    errdefer _ = CloseHandle(mapping);
    const bytes = MapViewOfFile(mapping, 4, 0, 0, 0) orelse return error.CannotMapDictionaryZip;
    return .{ .bytes = bytes[0..@intCast(size)], .handle = handle, .mapping = mapping };
}

pub fn readArchive(path: []const u8) ![]u8 {
    return readFile(path, 4 * @as(usize, 1024) * 1024 * 1024 - 1);
}

pub fn readFile(path: []const u8, limit: usize) ![]u8 {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
    defer a.free(wide);
    const handle = CreateFileW(wide, 0x80000000, 1, null, 3, 0x80, null);
    if (handle == null or @intFromPtr(handle.?) == std.math.maxInt(usize)) return error.CannotOpenDictionaryZip;
    defer _ = CloseHandle(handle);
    var size: i64 = 0;
    if (GetFileSizeEx(handle, &size) == 0 or size < 0) return error.CannotReadDictionaryZip;
    if (size > limit) return error.DictionaryTooLarge;
    const bytes = try a.alloc(u8, @intCast(size));
    errdefer a.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        var read: u32 = 0;
        if (ReadFile(handle, bytes.ptr + offset, @intCast(@min(bytes.len - offset, 64 * 1024 * 1024)), &read, null) == 0 or read == 0) return error.CannotReadDictionaryZip;
        offset += read;
    }
    return bytes;
}

/// Sorted, owned paths to regular files in an executable-relative asset folder.
pub fn folderFiles(io: std.Io, name: []const u8, extension: []const u8) !std.ArrayList([]u8) {
    const path = try siblingPath(name);
    defer a.free(path);
    try std.Io.Dir.cwd().createDirPath(io, path);
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var paths: std.ArrayList([]u8) = .empty;
    errdefer freePaths(&paths);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !std.ascii.endsWithIgnoreCase(entry.name, extension)) continue;
        const full = try std.fs.path.join(a, &.{ path, entry.name });
        paths.append(a, full) catch |err| {
            a.free(full);
            return err;
        };
    }
    std.mem.sort([]u8, paths.items, {}, struct {
        fn less(_: void, lhs: []u8, rhs: []u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.less);
    return paths;
}
pub fn freePaths(paths: *std.ArrayList([]u8)) void {
    for (paths.items) |path| a.free(path);
    paths.deinit(a);
}
