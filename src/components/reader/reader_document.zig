//! Cached paragraph geometry for one continuously scrollable history document.
const std = @import("std");
const ui = @import("ui");
const Fonts = @import("../fonts/font_settings.zig");
const Selection = @import("shift_selection.zig");
const flow = @import("reading_layout.zig");
const a = std.heap.smp_allocator;

pub const Box = struct { offset: f32, extent: f32 };
pub const Range = struct { first: usize, end: usize };
pub const overscan: f32 = 0.2;
const Config = struct {
    width: f32,
    rows: usize,
    font: usize,
    size: f32,
    scale: f32,
    spacing: f32,
    gap: f32,
    direction: flow.Direction,
};

boxes: std.ArrayList(Box) = .empty,
entries: std.ArrayList(Selection.Entry) = .empty,
indices: std.AutoHashMap(u64, usize) = .init(a),
extents: std.AutoHashMap(usize, f32) = .init(a),
config: ?Config = null,
revision: u64 = std.math.maxInt(u64),
total: f32 = 0,
const Self = @This();

pub fn deinit(self: *Self) void {
    self.boxes.deinit(a);
    self.entries.deinit(a);
    self.indices.deinit();
    self.extents.deinit();
}

pub fn forget(self: *Self, id: usize) void {
    _ = self.extents.remove(id);
}

pub fn update(self: *Self, frame: *ui.Frame, fonts: *Fonts, direction: flow.Direction, width: f32, rows: usize, revision: u64, lines: anytype) !bool {
    const config: Config = .{ .width = width, .rows = rows, .font = fonts.selected, .size = fonts.reader_size, .scale = frame.ui().content_scale, .spacing = fonts.character_spacing, .gap = fonts.line_spacing, .direction = direction };
    const same_geometry = if (self.config) |old| std.meta.eql(old, config) else false;
    if (same_geometry and self.revision == revision) return false;
    if (!same_geometry) self.extents.clearRetainingCapacity();
    self.boxes.clearRetainingCapacity();
    self.entries.clearRetainingCapacity();
    self.indices.clearRetainingCapacity();
    self.total = 0;
    for (lines, 0..) |line, i| {
        const text = if (std.unicode.utf8ValidateSlice(line.text)) line.text else "\u{FFFD}";
        const extent = self.extents.get(line.id) orelse blk: {
            const measured = try measure(frame, fonts, config, text);
            try self.extents.put(line.id, measured);
            break :blk measured;
        };
        if (i > 0) self.total += fonts.line_spacing;
        try self.boxes.append(a, .{ .offset = self.total, .extent = extent });
        const id = ui.Key.str("reader.line").indexed(line.id).hash();
        try self.entries.append(a, .{ .id = id, .line_id = line.id, .text = text });
        try self.indices.put(id, i);
        self.total += extent;
    }
    self.config = config;
    self.revision = revision;
    return true;
}

pub const Anchor = struct { id: u64, screen: f32 };

pub fn anchor(self: *const Self, scroll: f32, reverse: bool) ?Anchor {
    if (self.boxes.items.len == 0) return null;
    const range = self.visible(scroll, 0, reverse);
    const i = @min(range.first, self.boxes.items.len - 1);
    return .{ .id = self.entries.items[i].id, .screen = self.position(i, reverse) - scroll };
}

pub fn position(self: *const Self, i: usize, reverse: bool) f32 {
    const box = self.boxes.items[i];
    return if (reverse) @max(self.config.?.width, self.total) - box.offset - box.extent else box.offset;
}

// Include a small overscan margin. The full document extent is
// independent of this range, so the scrollbar can reach every retained entry.
pub fn visible(self: *const Self, scroll: f32, viewport: f32, reverse: bool) Range {
    const cursor = if (reverse) self.total - scroll - viewport else scroll;
    const lo = cursor - overscan * viewport;
    const hi = cursor + (1 + overscan) * viewport;
    var first: usize = 0;
    var end = self.boxes.items.len;
    while (first < end) {
        const mid = first + (end - first) / 2;
        const box = self.boxes.items[mid];
        if (box.offset + box.extent < lo) first = mid + 1 else end = mid;
    }
    var last = first;
    end = self.boxes.items.len;
    while (last < end) {
        const mid = last + (end - last) / 2;
        if (self.boxes.items[mid].offset <= hi) last = mid + 1 else end = mid;
    }
    return .{ .first = first, .end = last };
}

fn measure(frame: *ui.Frame, fonts: *Fonts, config: Config, text: []const u8) !f32 {
    if (config.direction != .horizontal) {
        var layout = try flow.build(frame.arena(), text, config.rows);
        defer layout.cells.deinit(frame.arena());
        return @as(f32, @floatFromInt(layout.columns)) * fonts.reader_size * 1.3;
    }
    const u = frame.ui();
    const face = try u.font.getFace(fonts.fontName());
    if (fonts.character_spacing == 0) {
        const shaped = try face.shapeWrapped(text, fonts.reader_size * u.content_scale, @max(1, config.width - 44) * u.content_scale);
        return @max(28, shaped.height / u.content_scale + 6);
    }
    var pen: flow.Pen = .{ .width = @max(1, config.width - 8), .line_height = try u.lineHeight(fonts.reader_size, fonts.fontName()), .spacing = fonts.character_spacing };
    var it = (try std.unicode.Utf8View.init(text)).iterator();
    while (it.nextCodepointSlice()) |glyph| {
        if (glyph[0] == '\r') continue;
        if (glyph[0] == '\n') {
            pen.newline();
            continue;
        }
        const shaped = try face.shape(glyph, fonts.reader_size * u.content_scale);
        _ = pen.place(@max(1, shaped.width / u.content_scale));
    }
    return @max(28, pen.y + pen.line_height + 6);
}
