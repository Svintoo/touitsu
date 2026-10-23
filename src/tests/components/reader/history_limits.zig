//! Tests for components/reader/history_limits.zig.
const subject = @import("../../../components/reader/history_limits.zig");

const std = @import("std");
const units = subject.units;

test "hook history preview word estimate handles Japanese and spaced text" {
    try std.testing.expectEqual(@as(usize, 4), units("one two"));
    try std.testing.expectEqual(@as(usize, 4), units("日本語文"));
    try std.testing.expectEqual(@as(usize, 6), units("日本語文 word"));
    try std.testing.expectEqual(@as(usize, 0), units(" \n\t"));
}
