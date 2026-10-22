//! One automatic attachment attempt per running instance of a saved game.
const std = @import("std");
const Store = @import("Hookstore.zig").Store;
const Proc = @import("procs.zig").Proc;

attempted: std.AutoHashMap(u32, u64) = .init(std.heap.smp_allocator),
const Self = @This();

pub fn deinit(self: *Self) void {
    self.attempted.deinit();
}

pub fn claim(self: *Self, pid: u32, started_at: u64) !bool {
    if (self.attempted.get(pid)) |previous| {
        if (previous == started_at) return false;
    }
    try self.attempted.put(pid, started_at);
    return true;
}

pub fn hasSavedName(store: *const Store, name: []const u8) bool {
    for (store.entries.items) |entry| {
        if (entry.codes.items.len > 0 and std.ascii.eqlIgnoreCase(std.fs.path.basename(entry.exe), name)) return true;
    }
    return false;
}

pub fn shouldAttach(self: *Self, store: *Store, process: Proc, full_path: []const u8, attached: bool) !bool {
    if (!process.attachable or attached) return false;
    const entry = store.find(full_path) orelse return false;
    if (entry.codes.items.len == 0) return false;
    return self.claim(process.pid, process.started_at);
}

test "hook history preview saved game auto attachment matches paths and attempts each instance once" {
    const a = std.testing.allocator;
    var store: Store = .{ .alloc = a, .path = try a.allocSentinel(u16, 0, 0) };
    defer store.deinit();
    try store.addCode("C:\\Games\\Novel\\game.exe", "HS0@1234");
    try std.testing.expect(hasSavedName(&store, "GAME.EXE"));
    try std.testing.expect(!hasSavedName(&store, "other.exe"));
    try std.testing.expect(store.find("C:\\Other\\game.exe") == null);
    try std.testing.expect(store.find("c:\\games\\novel\\GAME.EXE") != null);
    var tracker: Self = .{};
    defer tracker.deinit();
    const process: Proc = .{ .pid = 99, .name = @constCast("game.exe"), .attachable = true, .is_32bit = false, .started_at = 100 };
    try std.testing.expect(!try tracker.shouldAttach(&store, process, "C:\\Other\\game.exe", false));
    try std.testing.expect(!try tracker.shouldAttach(&store, process, "C:\\Games\\Novel\\game.exe", true));
    try std.testing.expect(try tracker.shouldAttach(&store, process, "C:\\Games\\Novel\\game.exe", false));
    try std.testing.expect(!try tracker.shouldAttach(&store, process, "C:\\Games\\Novel\\game.exe", false));
    try std.testing.expect(try tracker.claim(42, 100));
    // Failed attempts and manual detaches must not cause automatic retry loops.
    try std.testing.expect(!try tracker.claim(42, 100));
    try std.testing.expect(try tracker.claim(43, 100));
    // Windows can reuse a PID; a new creation time is a new game instance.
    try std.testing.expect(try tracker.claim(42, 200));
    try std.testing.expect(!try tracker.claim(42, 200));
}
