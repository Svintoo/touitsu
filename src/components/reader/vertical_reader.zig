//! Native top-to-bottom reader entries with Shift selection in original UTF-8 offsets.
const std = @import("std");
const ui = @import("ui");
const flow = @import("reading_layout.zig");
const Fonts = @import("../fonts/font_settings.zig");
const Selection = @import("shift_selection.zig");
const Popup = @import("selection_popup.zig");
const controls = @import("reader_controls.zig");
const Placed = struct { lo: u32, hi: u32, x: f32, y: f32, w: f32, h: f32 };
const cache_allocator = std.heap.smp_allocator;
const Config = struct { direction: flow.Direction, rows: usize, width: f32, font: usize, size: f32, spacing: f32, scale: f32 };
const Cached = struct { id: usize, points: []Placed, columns: usize, height: f32 };

pub const Cache = struct {
    config: ?Config = null,
    entries: std.ArrayList(Cached) = .empty,

    pub fn deinit(self: *Cache) void {
        self.clear();
        self.entries.deinit(cache_allocator);
    }

    fn clear(self: *Cache) void {
        for (self.entries.items) |entry| cache_allocator.free(entry.points);
        self.entries.clearRetainingCapacity();
    }

    fn prepare(self: *Cache, config: Config) void {
        if (self.config) |previous| {
            if (std.meta.eql(previous, config)) return;
        }
        self.clear();
        self.config = config;
    }

    fn get(self: *const Cache, id: usize) ?Cached {
        for (self.entries.items) |entry| if (entry.id == id) return entry;
        return null;
    }

    fn put(self: *Cache, id: usize, points: []const Placed, columns: usize, height: f32) !void {
        // Bound retained glyph geometry independently of total reader history.
        if (points.len > 32768) return;
        const owned = try cache_allocator.dupe(Placed, points);
        errdefer cache_allocator.free(owned);
        if (self.entries.items.len >= 32) cache_allocator.free(self.entries.orderedRemove(0).points);
        try self.entries.append(cache_allocator, .{ .id = id, .points = owned, .columns = columns, .height = height });
    }
};

pub fn renderEntry(frame: *ui.Frame, id: usize, text: []const u8, fonts: *Fonts, direction: flow.Direction, rows: usize, available_width: f32, selection: *Selection, popup: *Popup, visible: [2]f32, cache: *Cache) !bool {
    const u = frame.ui();
    const a = frame.arena();
    const horizontal = direction == .horizontal;
    cache.prepare(.{ .direction = direction, .rows = rows, .width = available_width, .font = fonts.selected, .size = fonts.reader_size, .spacing = fonts.character_spacing, .scale = u.content_scale });
    const cached = cache.get(id);
    var placed: std.ArrayList(Placed) = .empty;
    defer if (cached == null) placed.deinit(a);
    var columns: usize = 1;
    const line_height = try u.lineHeight(fonts.reader_size, fonts.fontName());
    var entry_height: f32 = 0;
    const cell_size = fonts.reader_size * 1.3;
    const step = cell_size + fonts.character_spacing;
    if (cached) |value| {
        placed.items = value.points;
        columns = value.columns;
        entry_height = value.height;
    } else if (horizontal) {
        const face = try u.font.getFace(fonts.fontName());
        var pen: flow.Pen = .{ .width = available_width, .line_height = line_height, .spacing = fonts.character_spacing };
        var offset: usize = 0;
        while (offset < text.len) {
            const n = try std.unicode.utf8ByteSequenceLength(text[offset]);
            const end = offset + n;
            const glyph = text[offset..end];
            if (glyph[0] == '\r') {
                offset = end;
                continue;
            }
            if (glyph[0] == '\n') {
                pen.newline();
                offset = end;
                continue;
            }
            const shaped = try face.shape(glyph, fonts.reader_size * u.content_scale);
            const advance = @max(1, shaped.width / u.content_scale);
            const position = pen.place(advance);
            try placed.append(a, .{ .lo = @intCast(offset), .hi = @intCast(end), .x = 4 + position[0], .y = 3 + position[1], .w = advance, .h = line_height });
            offset = end;
        }
        entry_height = @max(28, pen.y + line_height + 6);
    } else {
        var layout = try flow.build(a, text, rows);
        defer layout.cells.deinit(a);
        columns = layout.columns;
        for (layout.cells.items) |cell| {
            const col = flow.physicalColumn(direction, columns, cell.column);
            try placed.append(a, .{ .lo = cell.lo, .hi = cell.hi, .x = @as(f32, @floatFromInt(col)) * cell_size, .y = @as(f32, @floatFromInt(cell.row)) * step, .w = cell_size, .h = cell_size });
        }
        entry_height = @as(f32, @floatFromInt(rows)) * step + 36;
    }
    if (cached == null and text.len >= 512) try cache.put(id, placed.items, columns, entry_height);
    const entry_key = ui.Key.str("reader.vertical.entry").indexed(id);
    const selection_id = ui.Key.str("reader.line").indexed(id).hash();
    const measured_entry = (try u.state.getOrCreate(.measured, u.allocator, entry_key.hash())).*;
    const entry: ui.component.Rect = .{ .key = entry_key, .style = &.{ .width = if (horizontal) .grow() else .fixed(@as(f32, @floatFromInt(columns)) * cell_size), .height = .fixed(entry_height) } };
    const entry_id = try entry.open(frame);
    // Expose the paragraph once, rather than one semantic node per glyph.
    try u.setAccessibility(entry_id, .{ .role = .text_run, .state = .{ .value_text = text } });
    var hovered = false;
    var can_scan = false;
    if (selection.pointer) |pointer| {
        if (u.state.get(.measured, ui.Key.str("reader.log").hash())) |log| {
            can_scan = log.box.contains(pointer) and !overPopup(frame, pointer);
            hovered = can_scan and measured_entry.box.contains(pointer);
        }
    }
    // Resolve the complete word before drawing any cells, including cells before
    // the hovered glyph in right-to-left or wrapped layouts.
    if (selection.document.len == 0 and (selection.shift_down or selection.mouse_dragging) and can_scan) {
        if (selection.pointer) |pointer| {
            for (placed.items) |cell| {
                const cell_key = ui.Key.str("reader.vertical.cell").indexed(id).indexed(cell.lo);
                if (u.state.get(.measured, cell_key.hash())) |measured| {
                    if (measured.box.contains(pointer)) {
                        if (selection.shift_down) selection.selectHit(selection_id, text, .{ .lo = cell.lo, .hi = cell.hi }) else selection.extend(selection_id, .{ .lo = cell.lo, .hi = cell.hi });
                        break;
                    }
                }
            }
        }
    }
    const selection_colors = @import("selection_colors.zig").palette(u.theme.text.value, u.theme.primary.value);
    for (placed.items) |cell| {
        const position = if (horizontal) cell.y else cell.x;
        const size = if (horizontal) cell.h else cell.w;
        if (position + size < visible[0] or position > visible[1]) continue;
        const cell_key = ui.Key.str("reader.vertical.cell").indexed(id).indexed(cell.lo);
        const measured = (try u.state.getOrCreate(.measured, u.allocator, cell_key.hash())).*;
        const range = selection.rangeFor(selection_id, text.len);
        const selected = if (range) |r| cell.lo < r.hi and cell.hi > r.lo else false;
        const rect: ui.component.Rect = .{ .key = cell_key, .style = &.{
            .position = .absolute,
            .offset = .{ cell.x, cell.y },
            .width = .fixed(cell.w),
            .height = .fixed(cell.h),
            .justify = if (horizontal) .start else .center,
            .@"align" = .center,
            .background = if (selected) .{ .color = .{ .value = selection_colors.background } } else .transparent,
        } };
        _ = try rect.open(frame);
        // Visual glyphs share the paragraph's semantic text run.
        const glyph_style: ui.Style = .{ .font = fonts.fontName(), .font_size = .{ .px = fonts.reader_size }, .foreground = if (selected) .{ .color = .{ .value = selection_colors.foreground } } else .text };
        const glyph_key = cell_key.indexed(1);
        const resolved = u.resolveStyle(glyph_key.hash(), .{ .base = &.{}, .user = &glyph_style }, .{}, null);
        const decoration = try u.textDecorationStyled(if (horizontal) text[cell.lo..cell.hi] else try displayGlyph(a, text[cell.lo..cell.hi]), &resolved);
        _ = try u.openWith(glyph_key, resolved.element(.{}), decoration, .{ .content = resolved.content });
        u.close();
        try rect.close(frame);
        if (selected and popup.text == null and measured.box.w() > 0) {
            const lo = range.?.lo;
            const hi = range.?.hi;
            if (lo < hi) {
                popup.text = text[lo..hi];
                popup.sentence = text;
                popup.x = measured.box.x();
                popup.y = measured.box.y();
                u.state.selection_text = text[lo..hi];
            }
        }
    }
    var deleted = false;
    if (hovered and placed.items.len > 0) {
        const last = placed.items[placed.items.len - 1];
        const delete_offset: [2]f32 = if (horizontal) .{ last.x + last.w + 8, last.y + @max(0, (last.h - 28) / 2) } else .{ last.x + @max(0, (cell_size - 28) / 2), last.y + cell_size + 4 };
        const delete_style = controls.delete(frame, delete_offset);
        deleted = (try frame.interact(ui.component.Button{
            .key = ui.Key.str("reader.delete").indexed(id),
            .label = "x",
            .style = &delete_style,
        })).clicked;
    }
    try entry.close(frame);
    return deleted;
}
fn overPopup(frame: *ui.Frame, point: [2]f32) bool {
    const u = frame.ui();
    const p = u.state.get(.floating_window, ui.Key.str("reader.selection.popup").hash()) orelse return false;
    return p.visible_frame + 1 >= u.state.frame and point[0] >= p.render_position[0] and point[0] < p.render_position[0] + p.render_size[0] and point[1] >= p.render_position[1] and point[1] < p.render_position[1] + p.render_size[1];
}
fn displayGlyph(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    const cp = try std.unicode.utf8Decode(text);
    // Common Japanese vertical punctuation. Keep the source offsets unchanged for lookup.
    const vertical: u21 = switch (cp) {
        0x3001 => 0xfe11,
        0x3002 => 0xfe12,
        0x300c => 0xfe41,
        0x300d => 0xfe42,
        0x300e => 0xfe43,
        0x300f => 0xfe44,
        0xff08 => 0xfe35,
        0xff09 => 0xfe36,
        0x30fc => 0xfe31,
        else => return text,
    };
    var bytes: [4]u8 = undefined;
    const n = try std.unicode.utf8Encode(vertical, &bytes);
    return a.dupe(u8, bytes[0..n]);
}
