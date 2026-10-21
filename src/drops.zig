//! Minimal Knots file-drop surface using Frame.droppedPaths().
const ui = @import("ui");

pub fn render(frame: *ui.Frame, pointer: ?[2]f32) !?[]const u8 {
    const key: ui.Key = .str("settings.background.drop");
    const u = frame.ui();
    const measured = try u.state.getOrCreate(.measured, u.allocator, key.hash());
    const hovered = if (pointer) |point| measured.box.contains(point) else false;
    const zone: ui.component.Rect = .{ .key = key, .style = &.{
        .width = .grow(),
        .height = .fixed(120),
        .direction = .column,
        .@"align" = .center,
        .justify = .center,
        .padding = .all(16),
        .background = if (hovered) .muted else .transparent,
        .border_width = .all(1),
        .border_color = if (hovered) .accent else .toned,
        .radius = .md,
    } };
    _ = try zone.open(frame);
    try frame.e(ui.component.Text{ .key = .src(@src()), .content = "Drop an image here\nPNG, JPEG, BMP or GIF", .selectable = false, .style = &.{ .width = .grow(), .wrap = true } });
    try zone.close(frame);
    const paths = frame.droppedPaths();
    return if (hovered and paths.len > 0) paths[0] else null;
}
