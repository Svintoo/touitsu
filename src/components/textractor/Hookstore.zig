//! hookstore.zig - saved hooks per game, kept in a plain text file next to the exe (hooks.txt).
//!
//! One line per game, same layout as the first fields of Textractor's savedHooks.txt:
//!
//!     <exe path> , <hook code> , <hook code> , |<ctx>:<ctx2>:<hook code>
//!
//! The optional |... part remembers which text thread was selected. You can copy a line from
//! Textractor's savedHooks.txt into hooks.txt and it will be understood. Uses Win32 file calls
//! directly so it doesn't depend on std file/Io APIs.
//! Optional |pairs:<hook code> tokens enable doubled-character post-processing for that hook.

const std = @import("std");

const HANDLE = ?*anyopaque;
extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, sa: ?*anyopaque, disposition: u32, flags: u32, template: ?*anyopaque) callconv(.winapi) HANDLE;
extern "kernel32" fn GetFileSizeEx(h: HANDLE, size: *i64) callconv(.winapi) i32;
extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, n: u32, read: *u32, overlapped: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, n: u32, written: *u32, overlapped: ?*anyopaque) callconv(.winapi) i32;
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

fn readAll(alloc: std.mem.Allocator, path: [*:0]const u16) !?[]u8 {
    const h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
    if (isInvalid(h)) return null; // no file yet
    defer _ = CloseHandle(h);
    var size: i64 = 0;
    if (GetFileSizeEx(h, &size) == 0 or size < 0 or size > 16 * 1024 * 1024) return error.BadFile;
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

fn writeAll(path: [*:0]const u16, data: []const u8) !void {
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
fn defaultPath(alloc: std.mem.Allocator) ![:0]u16 {
    var buf: [1024]u16 = undefined;
    const n = GetModuleFileNameW(null, &buf, buf.len);
    if (n == 0 or n >= buf.len) return error.NoModulePath;
    var end: usize = n;
    while (end > 0 and buf[end - 1] != '\\') end -= 1;
    const name = std.unicode.utf8ToUtf16LeStringLiteral("hooks.txt");
    const out = try alloc.allocSentinel(u16, end + name.len, 0);
    for (buf[0..end], 0..) |c, i| out[i] = c;
    for (name, 0..) |c, i| out[end + i] = c;
    return out;
}

/// The thread that was selected last time: identified by its contexts and hook code.
pub const Sel = struct { ctx: u64, ctx2: u64, code: []u8 };

pub const Entry = struct {
    exe: []u8,
    codes: std.ArrayList([]u8) = .empty,
    sel: ?Sel = null,
    doubled: std.ArrayList([]u8) = .empty,

    fn deinit(self: *Entry, alloc: std.mem.Allocator) void {
        alloc.free(self.exe);
        for (self.codes.items) |c| alloc.free(c);
        self.codes.deinit(alloc);
        for (self.doubled.items) |code| alloc.free(code);
        self.doubled.deinit(alloc);
        if (self.sel) |s| alloc.free(s.code);
    }
};

pub const Store = struct {
    alloc: std.mem.Allocator,
    path: [:0]u16,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(alloc: std.mem.Allocator) !Store {
        var s: Store = .{ .alloc = alloc, .path = try defaultPath(alloc) };
        s.load() catch {}; // a missing or unreadable file just means "no saved hooks"
        return s;
    }

    pub fn deinit(self: *Store) void {
        for (self.entries.items) |*e| e.deinit(self.alloc);
        self.entries.deinit(self.alloc);
        self.alloc.free(self.path);
    }

    pub fn find(self: *Store, exe: []const u8) ?*Entry {
        for (self.entries.items) |*e| {
            if (std.ascii.eqlIgnoreCase(e.exe, exe)) return e;
        }
        return null;
    }

    fn getOrCreate(self: *Store, exe: []const u8) !*Entry {
        if (self.find(exe)) |e| return e;
        const copy = try self.alloc.dupe(u8, exe);
        errdefer self.alloc.free(copy);
        try self.entries.append(self.alloc, .{ .exe = copy });
        return &self.entries.items[self.entries.items.len - 1];
    }

    pub fn addCode(self: *Store, exe: []const u8, code: []const u8) !void {
        const e = try self.getOrCreate(exe);
        for (e.codes.items) |c| {
            if (std.mem.eql(u8, c, code)) return;
        }
        const copy = try self.alloc.dupe(u8, code);
        errdefer self.alloc.free(copy);
        try e.codes.append(self.alloc, copy);
    }

    pub fn reducesPairs(self: *Store, exe: []const u8, code: []const u8) bool {
        const entry = self.find(exe) orelse return false;
        for (entry.doubled.items) |saved| if (std.mem.eql(u8, saved, code)) return true;
        return false;
    }

    pub fn setPairs(self: *Store, exe: []const u8, code: []const u8, enabled: bool) !void {
        const entry = try self.getOrCreate(exe);
        for (entry.doubled.items, 0..) |saved, i| {
            if (!std.mem.eql(u8, saved, code)) continue;
            if (!enabled) self.alloc.free(entry.doubled.orderedRemove(i));
            return;
        }
        if (enabled) {
            const copy = try self.alloc.dupe(u8, code);
            errdefer self.alloc.free(copy);
            try entry.doubled.append(self.alloc, copy);
        }
    }

    pub fn setSel(self: *Store, exe: []const u8, ctx: u64, ctx2: u64, code: []const u8) !void {
        const e = try self.getOrCreate(exe);
        const copy = try self.alloc.dupe(u8, code);
        if (e.sel) |old| self.alloc.free(old.code);
        e.sel = .{ .ctx = ctx, .ctx2 = ctx2, .code = copy };
    }

    pub fn removeCode(self: *Store, exe: []const u8, code: []const u8) void {
        self.setPairs(exe, code, false) catch {};
        const entry = self.find(exe) orelse return;
        if (entry.sel) |sel| {
            if (std.mem.eql(u8, sel.code, code)) {
                self.alloc.free(sel.code);
                entry.sel = null;
            }
        }
        for (entry.codes.items, 0..) |saved, i| {
            if (std.mem.eql(u8, saved, code)) {
                self.alloc.free(saved);
                _ = entry.codes.orderedRemove(i);
                break;
            }
        }
    }

    pub fn forget(self: *Store, exe: []const u8) void {
        for (self.entries.items, 0..) |*e, i| {
            if (std.ascii.eqlIgnoreCase(e.exe, exe)) {
                e.deinit(self.alloc);
                _ = self.entries.orderedRemove(i);
                return;
            }
        }
    }

    fn load(self: *Store) !void {
        const data = (try readAll(self.alloc, self.path.ptr)) orelse return;
        defer self.alloc.free(data);
        var text: []const u8 = data;
        if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text = text[3..]; // UTF-8 BOM
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| self.parseLine(line) catch {};
    }

    pub fn parseLine(self: *Store, raw: []const u8) !void {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) return;
        var it = std.mem.splitSequence(u8, line, " , ");
        const exe = std.mem.trim(u8, it.first(), " \t");
        if (exe.len == 0) return;
        const entry = try self.getOrCreate(exe);
        while (it.next()) |tok_raw| {
            const tok = std.mem.trim(u8, tok_raw, " \t");
            if (tok.len == 0) continue;
            if (std.mem.startsWith(u8, tok, "|pairs:")) {
                try self.setPairs(exe, tok[7..], true);
            } else if (tok[0] == '|') {
                try self.parseSel(entry, tok);
            } else {
                try self.addCode(exe, tok);
            }
        }
    }

    /// "|<ctx>:<ctx2>:<hook code>" - the hook code itself contains ':' so split only twice.
    fn parseSel(self: *Store, entry: *Entry, tok: []const u8) !void {
        const body = tok[1..];
        const a = std.mem.indexOfScalar(u8, body, ':') orelse return;
        const b_rel = std.mem.indexOfScalar(u8, body[a + 1 ..], ':') orelse return;
        const b = a + 1 + b_rel;
        const ctx = std.fmt.parseInt(u64, body[0..a], 10) catch return;
        const ctx2 = std.fmt.parseInt(u64, body[a + 1 .. b], 10) catch return;
        const code = std.mem.trim(u8, body[b + 1 ..], " \t");
        if (code.len == 0) return;
        const copy = try self.alloc.dupe(u8, code);
        if (entry.sel) |old| self.alloc.free(old.code);
        entry.sel = .{ .ctx = ctx, .ctx2 = ctx2, .code = copy };
    }

    pub fn save(self: *Store) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.alloc);
        for (self.entries.items) |e| {
            try buf.appendSlice(self.alloc, e.exe);
            for (e.codes.items) |c| {
                try buf.appendSlice(self.alloc, " , ");
                try buf.appendSlice(self.alloc, c);
            }
            if (e.sel) |s| {
                const t = try std.fmt.allocPrint(self.alloc, " , |{d}:{d}:{s}", .{ s.ctx, s.ctx2, s.code });
                defer self.alloc.free(t);
                try buf.appendSlice(self.alloc, t);
            }
            for (e.doubled.items) |code| {
                try buf.appendSlice(self.alloc, " , |pairs:");
                try buf.appendSlice(self.alloc, code);
            }
            try buf.append(self.alloc, '\n');
        }
        try writeAll(self.path.ptr, buf.items);
    }
};

test {
    _ = @import("../../tests/components/textractor/Hookstore.zig").Tests(.{ .deinitEntry = Entry.deinit });
}
