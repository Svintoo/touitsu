//! Tests for components/reader/selection_colors.zig.
const subject = @import("../../../components/reader/selection_colors.zig");

const std = @import("std");
const contrast = subject.contrast;
const palette = subject.palette;

test "selection contrasts with dark, light and midtone text regardless of accent opacity" {
    for ([_][4]f32{ .{ 0.05, 0.05, 0.05, 1 }, .{ 0.95, 0.95, 0.95, 1 }, .{ 0.46, 0.46, 0.46, 1 } }) |text| {
        for ([_][4]f32{ .{ 0.1, 0.2, 0.8, 0.2 }, .{ 0.8, 0.7, 0.2, 0.5 }, text }) |accent| {
            const colors = palette(text, accent);
            try std.testing.expect(contrast(colors.foreground, colors.background) >= 4.5);
            try std.testing.expectEqual(@as(f32, 1), colors.background[3]);
        }
    }
}
