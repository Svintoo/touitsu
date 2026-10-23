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

test {
    _ = @import("../../tests/components/textractor/auto_attach.zig");
}
