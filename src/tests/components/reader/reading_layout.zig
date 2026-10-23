//! Tests for components/reader/reading_layout.zig.
const subject = @import("../../../components/reader/reading_layout.zig");

const std = @import("std");
const build = subject.build;
const physicalColumn = subject.physicalColumn;
const latest = subject.latest;
const wheel = subject.wheel;
const Pen = subject.Pen;

test "vertical cells preserve Japanese byte ranges, wrap and reverse columns" {
    const a = std.testing.allocator;
    var layout = try build(a, "日本語\n猫", 2);
    defer layout.cells.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), layout.columns);
    try std.testing.expectEqual(@as(u32, 3), layout.cells.items[1].lo);
    try std.testing.expectEqual(@as(usize, 1), layout.cells.items[2].column);
    try std.testing.expectEqual(@as(usize, 2), layout.cells.items[3].column);
    try std.testing.expectEqual(@as(usize, 2), physicalColumn(.vertical_right, 3, 0));
    try std.testing.expectEqual(@as(usize, 0), physicalColumn(.vertical_left, 3, 0));
}

test "latest edge and wheel movement follow reading direction" {
    try std.testing.expectEqual(@as(f32, 500), latest(.horizontal, 500));
    try std.testing.expectEqual(@as(f32, 500), latest(.vertical_left, 500));
    try std.testing.expectEqual(@as(f32, 0), latest(.vertical_right, 500));
    try std.testing.expectEqual(@as(f32, -40), wheel(.vertical_right, 40));
    try std.testing.expectEqual(@as(f32, 40), wheel(.vertical_left, 40));
}

test "character spacing participates in horizontal wrapping" {
    var pen: Pen = .{ .width = 25, .line_height = 20, .spacing = 3 };
    try std.testing.expectEqual([2]f32{ 0, 0 }, pen.place(10));
    try std.testing.expectEqual([2]f32{ 13, 0 }, pen.place(10));
    try std.testing.expectEqual([2]f32{ 0, 20 }, pen.place(10));
    pen.newline();
    try std.testing.expectEqual([2]f32{ 0, 40 }, pen.place(10));
}
