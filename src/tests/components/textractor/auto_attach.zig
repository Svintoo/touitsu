//! Tests for components/textractor/auto_attach.zig.
const subject = @import("../../../components/textractor/auto_attach.zig");

const std = @import("std");
const Store = @import("../../../components/textractor/Hookstore.zig").Store;
const Proc = @import("../../../components/textractor/procs.zig").Proc;
const Self = subject;
const hasSavedName = subject.hasSavedName;

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
