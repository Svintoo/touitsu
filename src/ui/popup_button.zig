//! Shared glass outline for dictionary-popup actions, independent of button settings.
const ui = @import("ui");

pub fn style(theme: ui.Theme) ui.Style {
    var tint = theme.elevated;
    tint.value[3] = 0.2;
    return .{
        .width = .fixed(112),
        .height = .fixed(32),
        .padding = .xy(8, 0),
        .font_size = .{ .px = 14 },
        .justify = .center,
        .@"align" = .center,
        .background = .{ .color = tint },
        .foreground = .text,
        .border_color = .toned,
        .border_width = .all(1),
        .radius = .md,
        .backdrop = .frosted,
        .hover = &.{ .background = .muted, .border_color = .accent },
    };
}
