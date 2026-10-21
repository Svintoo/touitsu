const ui = @import("ui");

// Applied each frame by AppearanceSettings so every project button shares the styler.
pub var current: ui.Style = .{};
// Settings use a consistent outline treatment, independent of reader controls.
pub var settings_outline: bool = false;
key: ui.Key,
label: ?[]const u8 = null,
disabled: bool = false,
appearance: enum { shared, explicit } = .shared,
icon: ?ui.component.Image.Source = null,
style: ?*const ui.Style = null,
parts: ui.component.Button.Parts = .{},
const Self = @This();
pub const Response = ui.component.Button.Response;
fn merged(self: Self) ui.Style {
    if (self.appearance == .explicit) return if (self.style) |style| style.* else .{};
    var result = (self.style orelse &current).*;
    const selected = if (result.background) |background| background == .accent or background == .muted else false;
    if (result.background) |background| {
        if (background == .accent) result.state_layer = 0.18;
    }
    // Keep per-control layout (including compact icons), while sharing appearance.
    result.background = current.background;
    result.foreground = current.foreground;
    result.border_color = current.border_color;
    result.border_width = current.border_width;
    if (result.radius == null) result.radius = current.radius;
    result.backdrop = current.backdrop;
    if (result.padding == null) result.padding = current.padding;
    if (result.font_size == null) result.font_size = current.font_size;
    if (settings_outline) {
        result.background = .transparent;
        result.foreground = if (selected) .accent else .text;
        result.border_color = if (selected) .accent else .toned;
        result.border_width = .all(1);
        result.radius = .md;
        result.backdrop = .none;
        result.state_layer = 0;
        result.hover = &.{ .background = .muted, .border_color = .accent };
        if (self.style == null or self.style.?.padding == null) result.padding = .xy(12, 6);
        if (self.style == null or self.style.?.font_size == null) result.font_size = .sm;
    }
    return result;
}
fn button(self: Self, style: *const ui.Style) ui.component.Button {
    return .{ .key = self.key, .label = if (self.icon == null) self.label else null, .disabled = self.disabled, .style = style, .parts = self.parts };
}
pub fn interact(self: Self, frame: *ui.Frame) !ui.component.Button.Response {
    const response = try self.openResponse(frame);
    try self.close(frame);
    return response;
}
pub fn open(self: Self, frame: *ui.Frame) !ui.layout.Element.Id {
    return (try self.openResponse(frame)).id;
}
pub fn close(self: Self, frame: *ui.Frame) !void {
    return self.button(&current).close(frame);
}
pub fn openResponse(self: Self, frame: *ui.Frame) !ui.component.Button.Response {
    const style = self.merged();
    const response = try self.button(&style).openResponse(frame);
    if (self.icon) |source| {
        try frame.e(ui.component.Image{ .key = self.key.indexed(2), .source = source, .style = &.{ .width = .fixed(18), .height = .fixed(18), .foreground = style.foreground } });
        try frame.ui().setAccessibility(response.id, .{ .role = .button, .name = self.label orelse "", .state = .{ .disabled = self.disabled } });
    }
    return response;
}
