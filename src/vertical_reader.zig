//! Native top-to-bottom reader entries with Shift selection in original UTF-8 offsets.
const std = @import("std");
const ui = @import("ui");
const flow = @import("reading_layout.zig");
const Fonts = @import("font_settings.zig");
const Selection = @import("shift_selection.zig");
const Popup = @import("selection_popup.zig");
const Placed = struct { lo: u32, hi: u32, x: f32, y: f32, w: f32, h: f32 };

pub fn renderEntry(frame: *ui.Frame, id: usize, text: []const u8, fonts: *Fonts, direction: flow.Direction, rows: usize, available_width: f32, selection: *Selection, popup: *Popup) !bool {
    const u = frame.ui();
    const a = frame.arena();
    const horizontal = direction == .horizontal;
    var placed: std.ArrayList(Placed) = .empty;
    defer placed.deinit(a);
    var columns: usize = 1;
    const line_height = try u.lineHeight(fonts.reader_size, fonts.fontName());
    var entry_height: f32 = 0;
    const cell_size = fonts.reader_size * 1.3;
    const step = cell_size + fonts.character_spacing;
    if (horizontal) {
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
    const entry_key = ui.Key.str("reader.vertical.entry").indexed(id);
    const selection_id = ui.Key.str("reader.line").indexed(id).hash();
    const measured_entry = (try u.state.getOrCreate(.measured, u.allocator, entry_key.hash())).*;
    const entry: ui.component.Rect = .{ .key = entry_key, .style = &.{ .width = if (horizontal) .grow() else .fixed(@as(f32, @floatFromInt(columns)) * cell_size), .height = .fixed(entry_height) } };
    _ = try entry.open(frame);
    // Keep a viewport of pre-rendered columns on either side, without building
    // thousands of glyph widgets for history far outside the visible area.
    if (u.state.get(.measured, ui.Key.str("reader.log").hash())) |log| {
        if (!horizontal and measured_entry.width > 0 and (measured_entry.box.x() + measured_entry.width < log.box.x() - log.width or measured_entry.box.x() > log.box.x() + 2 * log.width)) {
            try entry.close(frame);
            return false;
        }
    }
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
        try frame.e(ui.component.Text{ .key = cell_key.indexed(1), .content = if (horizontal) text[cell.lo..cell.hi] else try displayGlyph(a, text[cell.lo..cell.hi]), .selectable = false, .style = &.{ .font = fonts.fontName(), .font_size = .{ .px = fonts.reader_size }, .foreground = if (selected) .{ .color = .{ .value = selection_colors.foreground } } else .text } });
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
        deleted = (try frame.interact(ui.component.Button{
            .key = ui.Key.str("reader.delete").indexed(id),
            .label = "x",
            .style = &.{ .position = .absolute, .offset = delete_offset, .width = .fixed(28), .height = .fixed(28), .padding = .all(0), .background = .transparent, .foreground = .dimmed, .hover = &.{ .background = .muted, .foreground = .text } },
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
