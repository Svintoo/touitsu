//! Reader flow and UTF-8 cells used by the native vertical layout.
const std = @import("std");
pub const Direction = enum { horizontal, vertical_left, vertical_right };
pub const Cell = struct { lo: u32, hi: u32, column: usize, row: usize };
pub const Layout = struct { cells: std.ArrayList(Cell), columns: usize };
pub fn build(a: std.mem.Allocator, text: []const u8, rows: usize) !Layout {
    std.debug.assert(rows > 0);
    var cells: std.ArrayList(Cell) = .empty;
    errdefer cells.deinit(a);
    var column: usize = 0;
    var row: usize = 0;
    var offset: usize = 0;
    while (offset < text.len) {
        const n = try std.unicode.utf8ByteSequenceLength(text[offset]);
        const end = offset + n;
        if (end > text.len) return error.InvalidUtf8;
        const cp = try std.unicode.utf8Decode(text[offset..end]);
        if (cp == '\r') {
            offset = end;
            continue;
        }
        if (cp == '\n') {
            column += 1;
            row = 0;
            offset = end;
            continue;
        }
        if (row == rows) {
            column += 1;
            row = 0;
        }
        try cells.append(a, .{ .lo = @intCast(offset), .hi = @intCast(end), .column = column, .row = row });
        row += 1;
        offset = end;
    }
    return .{ .cells = cells, .columns = column + 1 };
}
pub fn physicalColumn(direction: Direction, columns: usize, column: usize) usize {
    return if (direction == .vertical_right) columns - 1 - column else column;
}
pub fn latest(direction: Direction, maximum: f32) f32 {
    return if (direction == .vertical_right) 0 else maximum;
}
pub fn wheel(direction: Direction, delta: f32) f32 {
    return if (direction == .vertical_right) -delta else delta;
}

/// Advances horizontal character cells while accounting for extra spacing during wrapping.
pub const Pen = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32,
    line_height: f32,
    spacing: f32,
    pub fn newline(self: *Pen) void {
        self.x = 0;
        self.y += self.line_height;
    }
    pub fn place(self: *Pen, advance: f32) [2]f32 {
        if (self.x > 0 and self.x + advance > self.width) self.newline();
        const result: [2]f32 = .{ self.x, self.y };
        self.x += advance + self.spacing;
        return result;
    }
};

test {
    _ = @import("../../tests/components/reader/reading_layout.zig");
}
