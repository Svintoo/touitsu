//! Shift + pointer selection without clicking or activating the reader window.
const std = @import("std");
const ui = @import("ui");
const Point = extern struct { x: i32, y: i32 };
extern "user32" fn GetAsyncKeyState(c_int) callconv(.winapi) i16;
extern "user32" fn GetCursorPos(*Point) callconv(.winapi) i32;
extern "user32" fn ScreenToClient(?*anyopaque, *Point) callconv(.winapi) i32;
extern "user32" fn WindowFromPoint(Point) callconv(.winapi) ?*anyopaque;
extern "user32" fn GetAncestor(?*anyopaque, u32) callconv(.winapi) ?*anyopaque;

pub const Range = struct { lo: u32, hi: u32 };
pub const Entry = struct { id: u64, line_id: usize, text: []const u8 };
pub const Scanner = struct {
    context: *anyopaque,
    lookup: *const fn (*anyopaque, []const u8, usize) anyerror!?usize,
};

whole_line: bool = false,
word_selection: bool = false,
scanner: ?Scanner = null,
shift_down: bool = false,
pointer: ?[2]f32 = null,
active_id: ?u64 = null,
anchor_id: ?u64 = null,
focus_range: Range = .{ .lo = 0, .hi = 0 },
document: []const Entry = &.{},
anchor: Range = .{ .lo = 0, .hi = 0 },
selected: Range = .{ .lo = 0, .hi = 0 },
extending: bool = false,
mouse_dragging: bool = false,
hit_text: bool = false,
const Self = @This();

pub fn sample(self: *Self, hwnd: ?*anyopaque, scale: f32) void {
    self.pointer = null;
    self.hit_text = false;
    const was_down = self.shift_down;
    self.shift_down = GetAsyncKeyState(0x10) < 0;
    if (self.shift_down and !was_down) self.clear();
    if (!self.shift_down and !self.mouse_dragging) self.extending = false;
    var point: Point = undefined;
    if (GetCursorPos(&point) == 0) return;
    // Do not scan through another window covering Touitsu, or while it is minimized.
    const under_pointer = WindowFromPoint(point) orelse return;
    if (GetAncestor(under_pointer, 2) != hwnd) {
        self.extending = false;
        return;
    }
    if (ScreenToClient(hwnd, &point) == 0) return;
    self.pointer = .{ @as(f32, @floatFromInt(point.x)) / scale, @as(f32, @floatFromInt(point.y)) / scale };
}

/// Ordinary mouse selection coexists with the Shift-hover gesture.
pub fn beginPointer(self: *Self, frame: *ui.Frame) void {
    const left = frame.ui().input.mouseButton(.left);
    if (left.pressed) {
        if (self.pointer) |pointer| {
            if (frame.ui().state.get(.floating_window, ui.Key.str("reader.selection.popup").hash())) |popup| {
                if (popup.visible_frame + 1 >= frame.ui().state.frame and
                    pointer[0] >= popup.render_position[0] and pointer[0] < popup.render_position[0] + popup.render_size[0] and
                    pointer[1] >= popup.render_position[1] and pointer[1] < popup.render_position[1] + popup.render_size[1]) return;
            }
            if (frame.ui().state.get(.measured, ui.Key.str("reader.log").hash())) |log| {
                if (log.box.contains(pointer)) {
                    self.clear();
                    self.mouse_dragging = true;
                }
            }
        }
    }
    if (!left.down) self.mouse_dragging = false;
}

pub fn extend(self: *Self, id: u64, hit: Range) void {
    self.hit_text = true;
    if (!self.extending or self.active_id == null or (self.active_id.? != id and self.document.len == 0)) {
        self.anchor_id = id;
        self.anchor = hit;
    }
    self.active_id = id;
    self.focus_range = hit;
    self.selected = .{ .lo = @min(self.anchor.lo, hit.lo), .hi = @max(self.anchor.hi, hit.hi) };
    self.extending = true;
}

/// A frame-borrowed document in reading order, independent of visual column direction.
pub fn rangeFor(self: *const Self, id: u64, len: usize) ?Range {
    const focus = self.active_id orelse return null;
    const anchor_id = self.anchor_id orelse focus;
    if (self.document.len == 0 or anchor_id == focus) {
        if (id != focus) return null;
        return .{ .lo = @intCast(@min(len, self.selected.lo)), .hi = @intCast(@min(len, self.selected.hi)) };
    }
    var anchor_index: ?usize = null;
    var focus_index: ?usize = null;
    var index: ?usize = null;
    for (self.document, 0..) |entry, i| {
        if (entry.id == anchor_id) anchor_index = i;
        if (entry.id == focus) focus_index = i;
        if (entry.id == id) index = i;
    }
    const ai = anchor_index orelse return null;
    const fi = focus_index orelse return null;
    const i = index orelse return null;
    if (i < @min(ai, fi) or i > @max(ai, fi)) return null;
    const lo = if (i == @min(ai, fi)) (if (ai < fi) self.anchor.lo else self.focus_range.lo) else 0;
    const hi = if (i == @max(ai, fi)) (if (ai < fi) self.focus_range.hi else self.anchor.hi) else len;
    return .{ .lo = @intCast(@min(lo, len)), .hi = @intCast(@min(hi, len)) };
}

pub fn collect(self: *const Self, allocator: std.mem.Allocator, full_context: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var entries: usize = 0;
    for (self.document) |entry| {
        const range = self.rangeFor(entry.id, entry.text.len) orelse continue;
        if (range.lo >= range.hi) continue;
        if (entries > 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, if (full_context) entry.text else entry.text[range.lo..range.hi]);
        entries += 1;
    }
    return try out.toOwnedSlice(allocator);
}

pub fn multipleEntries(self: *const Self) bool {
    return self.active_id != null and self.anchor_id != null and self.active_id.? != self.anchor_id.?;
}

/// Resolve the gesture before rendering so all entries highlight the same range this frame.
pub fn hitDocument(self: *Self, frame: *ui.Frame, font: []const u8, size: f32, cells: bool) !void {
    if (!self.shift_down and !self.mouse_dragging) return;
    const pointer = self.pointer orelse return;
    const u = frame.ui();
    const log = u.state.get(.measured, ui.Key.str("reader.log").hash()) orelse return;
    if (!log.box.contains(pointer)) return;
    if (u.state.get(.floating_window, ui.Key.str("reader.selection.popup").hash())) |popup| {
        if (popup.visible_frame + 1 >= u.state.frame and pointer[0] >= popup.render_position[0] and pointer[0] < popup.render_position[0] + popup.render_size[0] and pointer[1] >= popup.render_position[1] and pointer[1] < popup.render_position[1] + popup.render_size[1]) return;
    }
    for (self.document) |entry| {
        if (cells) {
            var iter = (try std.unicode.Utf8View.init(entry.text)).iterator();
            var offset: u32 = 0;
            while (iter.nextCodepointSlice()) |bytes| {
                const hi = offset + @as(u32, @intCast(bytes.len));
                const key = ui.Key.str("reader.vertical.cell").indexed(entry.line_id).indexed(offset);
                if (u.state.get(.measured, key.hash())) |measured| {
                    if (measured.box.contains(pointer)) {
                        if (self.mouse_dragging) self.extend(entry.id, .{ .lo = offset, .hi = hi }) else self.selectHit(entry.id, entry.text, .{ .lo = offset, .hi = hi });
                        return;
                    }
                }
                offset = hi;
            }
        } else {
            const state = u.state.get(.text_select, entry.id) orelse continue;
            if (!state.box.contains(pointer)) continue;
            const face = try u.font.getFace(font);
            const shaped = try face.shapeWrapped(entry.text, size * u.content_scale, state.box.w() * u.content_scale);
            const x = (pointer[0] - state.box.x()) * u.content_scale;
            const y = (pointer[1] - state.box.y()) * u.content_scale;
            for (shaped.lines) |line| {
                if (y < line.y or y >= line.y + shaped.line_height) continue;
                if (hitGlyph(line.glyphs, line.byte_start, line.byte_end, x)) |hit| {
                    if (self.mouse_dragging) self.extend(entry.id, hit) else self.selectHit(entry.id, entry.text, hit);
                    return;
                }
            }
        }
    }
}

/// Pointer selection depends on a scanner interface, not on the database or UI.
pub fn selectHit(self: *Self, id: u64, text: []const u8, hit: Range) void {
    if (self.whole_line) {
        self.extend(id, .{ .lo = 0, .hi = @intCast(text.len) });
        return;
    }
    if (self.word_selection) {
        if (self.scanner) |scanner| {
            const end = (scanner.lookup(scanner.context, text, hit.lo) catch null) orelse hit.hi;
            const range: Range = .{ .lo = hit.lo, .hi = @intCast(@min(text.len, @max(hit.hi, end))) };
            self.hit_text = true;
            self.active_id = id;
            self.anchor_id = id;
            self.anchor = range;
            self.focus_range = range;
            self.selected = range;
            self.extending = true;
            return;
        }
    }
    self.extend(id, hit);
}

fn clear(self: *Self) void {
    self.active_id = null;
    self.anchor_id = null;
    self.extending = false;
    self.anchor = .{ .lo = 0, .hi = 0 };
    self.selected = .{ .lo = 0, .hi = 0 };
}

/// Finish hit testing every reader entry before deciding that Shift missed the text.
pub fn finishFrame(self: *Self, frame: *ui.Frame) bool {
    if (!self.shift_down or self.hit_text or self.mouse_dragging) return false;
    if (self.active_id) |id| {
        if (frame.ui().state.get(.text_select, id)) |state| {
            state.anchor_byte = 0;
            state.cursor_byte = 0;
        }
        frame.ui().state.selection_text = "";
        frame.requestRedraw();
    }
    self.clear();
    return true;
}

/// Render using Knots' own highlight and copy implementation, replacing only its trigger.
pub fn renderText(self: *Self, frame: *ui.Frame, text: ui.component.Text) !void {
    const u = frame.ui();
    const colors = @import("selection_colors.zig").palette(u.theme.text.value, u.theme.primary.value);
    var selection_style = text.parts.selection.*;
    selection_style.background = .{ .color = .{ .value = colors.background } };
    selection_style.opacity = 1;
    var rendered = text;
    rendered.parts.selection = &selection_style;
    const id = text.key.hash();
    _ = try rendered.open(frame);
    const state = try u.state.getOrCreate(.text_select, u.allocator, id);
    if (self.shift_down and self.document.len == 0) {
        if (self.pointer) |pointer| {
            if (u.state.get(.measured, ui.Key.str("reader.log").hash())) |log| {
                if (pointer[0] >= log.box.x() and pointer[0] < log.box.x() + log.width and pointer[1] >= log.box.y() and pointer[1] < log.box.y() + log.height) {
                    if (state.box.w() > 0 and state.box.h() > 0 and pointer[0] >= state.box.x() and pointer[0] < state.box.x() + state.box.w() and pointer[1] >= state.box.y() and pointer[1] < state.box.y() + state.box.h()) {
                        // Respect overlay hit testing: hovering the dictionary must not select text behind it.
                        const popup = u.state.get(.floating_window, ui.Key.str("reader.selection.popup").hash());
                        const over_popup = if (popup) |p| p.visible_frame + 1 >= u.state.frame and pointer[0] >= p.render_position[0] and pointer[0] < p.render_position[0] + p.render_size[0] and pointer[1] >= p.render_position[1] and pointer[1] < p.render_position[1] + p.render_size[1] else false;
                        if (!over_popup) {
                            const content = u.contents.items[u.currentSlot()];
                            const face = try u.font.getFace(content.font);
                            const shaped = try face.shapeWrapped(text.content, content.font_size * u.content_scale, state.box.w() * u.content_scale);
                            const local_x = (pointer[0] - state.box.x()) * u.content_scale;
                            const local_y = (pointer[1] - state.box.y()) * u.content_scale;
                            for (shaped.lines) |line| {
                                if (local_y < line.y or local_y >= line.y + shaped.line_height) continue;
                                if (hitGlyph(line.glyphs, line.byte_start, line.byte_end, local_x)) |hit| self.selectHit(id, text.content, hit);
                                break;
                            }
                        }
                    }
                }
            }
        }
    }
    if (self.document.len > 0) {
        const range = self.rangeFor(id, text.content.len) orelse Range{ .lo = 0, .hi = 0 };
        state.anchor_byte = range.lo;
        state.cursor_byte = range.hi;
    } else if (self.active_id != null and self.active_id.? == id) {
        state.anchor_byte = self.selected.lo;
        state.cursor_byte = self.selected.hi;
    } else if (self.shift_down) {
        state.anchor_byte = 0;
        state.cursor_byte = 0;
    }
    if (!self.shift_down and self.document.len == 0) {
        try rendered.close(frame);
        return;
    }
    state.dragging = false;
    // Only this Text ignores mouse-button selection during Shift-hover. Other controls keep ordinary input.
    const left = @constCast(u.input.mouseButton(.left));
    const saved = left.*;
    left.* = .{};
    defer left.* = saved;
    try rendered.close(frame);
}

fn hitGlyph(glyphs: anytype, start: u32, end: u32, x: f32) ?Range {
    for (glyphs, 0..) |glyph, i| {
        if (x < glyph.x or x >= glyph.x + glyph.advance) continue;
        var hi = end;
        for (glyphs[i + 1 ..]) |next| {
            if (next.cluster > glyph.cluster) {
                hi = start + next.cluster;
                break;
            }
        }
        const lo = start + glyph.cluster;
        if (lo >= hi) return null;
        return .{ .lo = lo, .hi = hi };
    }
    return null;
}

test "multiline range copies UTF-8 in reading order and retains complete card context" {
    const entries = [_]Entry{
        .{ .id = 30, .line_id = 1, .text = "最初の行" },
        .{ .id = 10, .line_id = 2, .text = "真ん中" },
        .{ .id = 20, .line_id = 3, .text = "最後の行" },
    };
    var selection: Self = .{ .document = &entries };
    selection.extend(30, .{ .lo = 6, .hi = 9 });
    selection.extend(20, .{ .lo = 0, .hi = 3 });
    try std.testing.expectEqual(Range{ .lo = 6, .hi = 12 }, selection.rangeFor(30, 12).?);
    try std.testing.expectEqual(Range{ .lo = 0, .hi = 9 }, selection.rangeFor(10, 9).?);
    try std.testing.expectEqual(Range{ .lo = 0, .hi = 3 }, selection.rangeFor(20, 12).?);
    const selected = try selection.collect(std.testing.allocator, false);
    defer std.testing.allocator.free(selected);
    try std.testing.expectEqualStrings("の行\n真ん中\n最", selected);
    const context = try selection.collect(std.testing.allocator, true);
    defer std.testing.allocator.free(context);
    try std.testing.expectEqualStrings("最初の行\n真ん中\n最後の行", context);
    selection.clear();
    selection.extend(20, .{ .lo = 0, .hi = 3 });
    selection.extend(30, .{ .lo = 6, .hi = 9 });
    const reverse = try selection.collect(std.testing.allocator, false);
    defer std.testing.allocator.free(reverse);
    try std.testing.expectEqualStrings(selected, reverse);
}

test "Shift gesture extends forward and backward and restarts after release" {
    var selection: Self = .{};
    selection.extend(1, .{ .lo = 3, .hi = 6 });
    try std.testing.expectEqual(Range{ .lo = 3, .hi = 6 }, selection.selected);
    selection.extend(1, .{ .lo = 9, .hi = 12 });
    try std.testing.expectEqual(Range{ .lo = 3, .hi = 12 }, selection.selected);
    selection.extend(1, .{ .lo = 0, .hi = 3 });
    try std.testing.expectEqual(Range{ .lo = 0, .hi = 6 }, selection.selected);
    selection.extending = false;
    selection.extend(1, .{ .lo = 6, .hi = 9 });
    try std.testing.expectEqual(Range{ .lo = 6, .hi = 9 }, selection.selected);
    selection.extend(2, .{ .lo = 0, .hi = 3 });
    try std.testing.expectEqual(Range{ .lo = 0, .hi = 3 }, selection.selected);
}

test "word expansion uses source bytes and whole-line selection takes precedence" {
    const Fake = struct {
        calls: usize = 0,
        fn lookup(pointer: *anyopaque, _: []const u8, start: usize) anyerror!?usize {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            self.calls += 1;
            return if (start == 0) 6 else null;
        }
    };
    var fake: Fake = .{};
    var selection: Self = .{ .word_selection = true, .scanner = .{ .context = &fake, .lookup = Fake.lookup } };
    selection.selectHit(7, "文字です", .{ .lo = 0, .hi = 3 });
    try std.testing.expectEqual(Range{ .lo = 0, .hi = 6 }, selection.selected);
    selection.selectHit(7, "文字です", .{ .lo = 6, .hi = 9 });
    try std.testing.expectEqual(Range{ .lo = 6, .hi = 9 }, selection.selected);
    selection.whole_line = true;
    selection.selectHit(7, "文字です", .{ .lo = 0, .hi = 3 });
    try std.testing.expectEqual(Range{ .lo = 0, .hi = 12 }, selection.selected);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    selection.whole_line = false;
    selection.word_selection = false;
    selection.extending = false;
    selection.selectHit(7, "文字です", .{ .lo = 0, .hi = 3 });
    selection.selectHit(7, "文字です", .{ .lo = 3, .hi = 6 });
    try std.testing.expectEqual(Range{ .lo = 0, .hi = 6 }, selection.selected);
}

test "glyph hit testing preserves UTF-8 clusters on wrapped lines and rejects trailing space" {
    const Glyph = struct { x: f32, advance: f32, cluster: u32 };
    const glyphs = [_]Glyph{ .{ .x = 0, .advance = 20, .cluster = 0 }, .{ .x = 20, .advance = 20, .cluster = 3 } };
    try std.testing.expectEqual(Range{ .lo = 6, .hi = 9 }, hitGlyph(&glyphs, 6, 12, 10).?);
    try std.testing.expectEqual(Range{ .lo = 9, .hi = 12 }, hitGlyph(&glyphs, 6, 12, 25).?);
    try std.testing.expect(hitGlyph(&glyphs, 6, 12, 41) == null);
    try std.testing.expect(hitGlyph(&glyphs, 6, 12, -1) == null);
}
