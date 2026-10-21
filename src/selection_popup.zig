const ui = @import("ui");
const std = @import("std");
const DictionaryUI = @import("dictionary_ui.zig");
const FontSettings = @import("font_settings.zig");
const popup_key: ui.Key = .str("reader.selection.popup");

// Frame-local view of Knots' native text selection. No ownership of reader text.
text: ?[]const u8 = null,
sentence: []const u8 = "",
x: f32 = 0,
y: f32 = 0,
const Self = @This();

/// Call immediately after rendering a selectable Text with this key.
pub fn observe(self: *Self, frame: *ui.Frame, text_key: ui.Key, text: []const u8) !void {
    const u = frame.ui();
    const selection = u.state.get(.text_select, text_key.hash()) orelse return;
    const lo = @min(selection.anchor_byte, selection.cursor_byte);
    const hi = @min(@max(selection.anchor_byte, selection.cursor_byte), text.len);
    if (lo >= hi or selection.box.w() <= 0) return;
    const slot = u.layout_ctx.slotForId(text_key.hash()) orelse return;
    // Match Text's shaping settings, including font, wrapping and display scale.
    const content = u.contents.items[slot];
    const face = try u.font.getFace(content.font);
    const scale = u.content_scale;
    const shaped = try face.shapeWrapped(text, content.font_size * scale, selection.box.w() * scale);
    for (shaped.lines) |line| {
        if (hi <= line.byte_start) break;
        if (lo >= line.byte_end) continue;
        const local_byte = lo -| line.byte_start;
        var x: f32 = line.width / scale;
        for (line.glyphs) |glyph| {
            if (glyph.cluster >= local_byte) {
                x = glyph.x / scale;
                break;
            }
        }
        self.text = text[lo..hi];
        self.sentence = text;
        self.x = selection.box.x() + x;
        self.y = selection.box.y() + line.y / scale;
        return;
    }
}

pub fn render(self: *const Self, frame: *ui.Frame, dictionaries: *DictionaryUI, fonts: *FontSettings, anki: *@import("anki_settings.zig"), appearance: *const @import("popup_appearance.zig")) !void {
    const u = frame.ui();
    const text = self.text orelse {
        u.state.hideFloatingWindow(popup_key.hash());
        return;
    };
    // Hide the popup if the selected line has scrolled out of the reading area.
    if (u.state.get(.measured, ui.Key.str("reader.log").hash())) |log| {
        if (self.y < log.box.y() or self.y >= log.box.y() + log.height) {
            u.state.hideFloatingWindow(popup_key.hash());
            return;
        }
    }
    const width = @min(appearance.width, @as(f32, @floatFromInt(frame.input().logical_extent.width)));
    const viewport_height: f32 = @floatFromInt(frame.input().logical_extent.height);
    const height = @min(appearance.height, viewport_height);
    const x = std.math.clamp(self.x, 0, @max(0, @as(f32, @floatFromInt(frame.input().logical_extent.width)) - width));
    const y = if (self.y >= height + 8) self.y - height - 8 else @min(self.y + 36, @max(0, viewport_height - height));
    const state = try u.state.touchFloatingWindow(popup_key.hash());
    state.position = .{ x, y };
    state.size = .{ width, height };
    state.dragging = false;
    state.resizing = false;
    // Keep the window attached to the highlight rather than easing behind it.
    _ = u.anim(popup_key.hash(), "x", x, .{ .duration_ms = 0 });
    _ = u.anim(popup_key.hash(), "y", y, .{ .duration_ms = 0 });
    var is_open = true;
    const window: ui.component.FloatingWindow = .{
        .key = popup_key,
        .title = "",
        .is_open = &is_open,
        .initial_position = .{ x, y },
        .initial_size = .{ width, height },
        .min_size = .{ 100, 64 },
        .resizable = false,
        .maximizable = false,
        .closable = false,
        .close_on_escape = false,
        .style = &.{
            .backdrop = appearance.material(),
            .background = .{ .color = appearance.backgroundColor(u.theme) },
            .foreground = if (appearance.follow_theme) .text else .{ .color = .{ .value = appearance.foreground } },
            .border_color = if (appearance.follow_theme) .toned else .{ .color = .{ .value = appearance.border } },
            .border_width = .all(appearance.border_width),
            .radius = .{ .fixed = appearance.radius },
        },
        .parts = .{ .title_bar = &.{ .height = .fixed(0), .font_size = .sm }, .content = &.{ .font = fonts.fontName(), .font_size = .{ .px = fonts.popup_size }, .padding = .all(appearance.padding) } },
    };
    const word_changed = if (dictionaries.query) |query| !std.mem.eql(u8, query, text) else true;
    if (word_changed) {
        // FloatingWindow's content viewport uses child key 7.
        if (u.state.get(.scroll, popup_key.indexed(7).hash())) |scroll| scroll.* = .{};
    }
    _ = try window.open(frame);
    try dictionaries.lookup(text);
    const header: ui.component.Rect = .{ .key = .str("reader.popup.header"), .style = &.{ .width = .grow(), .direction = .row, .gap = 8, .@"align" = .center } };
    _ = try header.open(frame);
    try frame.e(ui.component.Text{
        .key = .src(@src()),
        .content = text,
        .selectable = false,
        .style = &.{ .width = .grow(), .wrap = true },
    });
    try header.close(frame);
    try dictionaries.renderResults(frame, text, anki, self.sentence, appearance.entry_spacing);
    try window.close(frame);
}
