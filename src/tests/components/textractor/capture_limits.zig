//! Tests for components/textractor/capture_limits.zig.
const subject = @import("../../../components/textractor/capture_limits.zig");

const std = @import("std");
const sample_code_units = subject.sample_code_units;
const message_bytes = subject.message_bytes;
const events_per_second = subject.events_per_second;
const bytes_per_second = subject.bytes_per_second;
const prefix = subject.prefix;
const FloodGuard = subject.FloodGuard;

test "hook history preview flood limits allow startup bursts and stop runaway output" {
    var guard: FloodGuard = .{};
    try std.testing.expect(!guard.accept(0, message_bytes + 1));
    guard = .{};
    for (0..events_per_second) |_| try std.testing.expect(guard.accept(0, 5));
    try std.testing.expect(!guard.accept(0, 5));
    try std.testing.expect(!guard.accept(2000, 5));
    guard = .{};
    for (0..bytes_per_second / message_bytes) |_| try std.testing.expect(guard.accept(0, message_bytes));
    try std.testing.expect(!guard.accept(0, 1));
    guard = .{};
    // Capture limits count UTF-16 units; Japanese UTF-8 may need three bytes each.
    try std.testing.expect(guard.accept(0, sample_code_units * 3));
    guard = .{};
    // Textractor commonly emits dozens of diagnostics immediately on attachment.
    for (0..100) |_| try std.testing.expect(guard.accept(0, 512));
    try std.testing.expect(!guard.blocked);
    try std.testing.expect(guard.accept(1000, 512));
    guard = .{};
    for (0..100) |i| try std.testing.expect(guard.accept(@intCast(i * 1000), 100));
}

test "character budget respects UTF-8 boundaries" {
    try std.testing.expectEqualStrings("a\xe3\x81\x82", prefix("a\xe3\x81\x82b", 2));
}
