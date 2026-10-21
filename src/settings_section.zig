const ui = @import("ui");

// Shared layout for clearly separated groups in sidebar settings pages.
key: ui.Key,
title: []const u8,
const Self = @This();

pub fn open(self: Self, frame: *ui.Frame) !ui.layout.Element.Id {
    const panel: ui.component.Rect = .{ .key = self.key, .style = &.{
        .width = .grow(),
        .direction = .column,
        .gap = 10,
        .padding = .all(12),
        .background = .bg,
        .border_width = .all(1),
        .border_color = .toned,
        .radius = .md,
    } };
    const id = try panel.open(frame);
    try frame.e(ui.component.Text{ .key = self.key.indexed(100), .content = self.title, .style = &.{ .font_size = .md }, .selectable = false });
    return id;
}
pub fn close(self: Self, frame: *ui.Frame) !void {
    const panel: ui.component.Rect = .{ .key = self.key };
    try panel.close(frame);
}
