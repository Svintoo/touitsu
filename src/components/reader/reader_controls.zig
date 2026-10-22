//! Opaque, contrasting reader actions, including over custom backgrounds.
const ui = @import("ui");
const colors = @import("selection_colors.zig");

pub fn action(frame: *ui.Frame) ui.Style {
    const palette = colors.palette(frame.ui().theme.text.value, frame.ui().theme.primary.value);
    return .{
        .background = .{ .color = .{ .value = palette.background } },
        .foreground = .{ .color = .{ .value = palette.foreground } },
        .border_color = .{ .color = .{ .value = palette.foreground } },
        .border_width = .all(1),
        .radius = .sm,
        .padding = .xy(10, 6),
        .state_layer = 0.15,
    };
}

pub fn delete(frame: *ui.Frame, offset: [2]f32) ui.Style {
    var style = action(frame);
    style.position = .absolute;
    style.offset = offset;
    style.width = .fixed(28);
    style.height = .fixed(28);
    style.padding = .all(0);
    return style;
}
