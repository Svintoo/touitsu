//! Opaque selection colors with readable text over images and glass surfaces.
const std = @import("std");
pub const Palette = struct { foreground: [4]f32, background: [4]f32 };

fn luminance(color: [4]f32) f32 {
    var result: f32 = 0;
    for ([_]f32{ 0.2126, 0.7152, 0.0722 }, 0..) |weight, i| {
        const c = color[i];
        result += weight * (if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4));
    }
    return result;
}

pub fn contrast(a: [4]f32, b: [4]f32) f32 {
    const first = luminance(a);
    const second = luminance(b);
    return (@max(first, second) + 0.05) / (@min(first, second) + 0.05);
}

pub fn palette(text: [4]f32, accent: [4]f32) Palette {
    var foreground = text;
    foreground[3] = 1;
    const target: f32 = if (luminance(foreground) > 0.179) 0 else 1;
    var background = accent;
    background[3] = 1;
    // Preserve as much of the theme accent as possible while ensuring contrast.
    for (0..21) |step| {
        const mix = @as(f32, @floatFromInt(step)) / 20;
        for (0..3) |i| background[i] = accent[i] * (1 - mix) + target * mix;
        if (contrast(foreground, background) >= 4.5) break;
    }
    return .{ .foreground = foreground, .background = background };
}

test "selection contrasts with dark, light and midtone text regardless of accent opacity" {
    for ([_][4]f32{ .{ 0.05, 0.05, 0.05, 1 }, .{ 0.95, 0.95, 0.95, 1 }, .{ 0.46, 0.46, 0.46, 1 } }) |text| {
        for ([_][4]f32{ .{ 0.1, 0.2, 0.8, 0.2 }, .{ 0.8, 0.7, 0.2, 0.5 }, text }) |accent| {
            const colors = palette(text, accent);
            try std.testing.expect(contrast(colors.foreground, colors.background) >= 4.5);
            try std.testing.expectEqual(@as(f32, 1), colors.background[3]);
        }
    }
}
