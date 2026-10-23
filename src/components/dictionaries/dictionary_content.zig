//! Text/image runs retained from Yomitan structured glossary content.
const std = @import("std");
pub const Image = struct {
    path: []const u8,
    width: ?f32 = null,
    height: ?f32 = null,
    em: bool = false,
    monochrome: bool = false,
    alt: []const u8 = "Dictionary image",
};
pub const Part = union(enum) { text: []const u8, image: Image };
pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    parts: []const Part,
    pub fn init(allocator: std.mem.Allocator, json: []const u8) !Document {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const value = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{ .allocate = .alloc_always });
        var parts: std.ArrayList(Part) = .empty;
        var text: std.ArrayList(u8) = .empty;
        try visit(a, &parts, &text, value, 0);
        try flush(a, &parts, &text);
        return .{ .arena = arena, .parts = try parts.toOwnedSlice(a) };
    }
    pub fn deinit(self: Document) void {
        self.arena.deinit();
    }
};
fn string(value: std.json.Value, name: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(name) orelse return null;
    return if (field == .string) field.string else null;
}
fn number(value: std.json.Value, name: []const u8) ?f32 {
    const field = value.object.get(name) orelse return null;
    const n: f32 = switch (field) {
        .integer => @floatFromInt(field.integer),
        .float => @floatCast(field.float),
        else => return null,
    };
    return if (std.math.isFinite(n) and n > 0) n else null;
}
fn flush(a: std.mem.Allocator, parts: *std.ArrayList(Part), text: *std.ArrayList(u8)) !void {
    if (text.items.len == 0) return;
    try parts.append(a, .{ .text = try text.toOwnedSlice(a) });
}
fn visit(a: std.mem.Allocator, parts: *std.ArrayList(Part), text: *std.ArrayList(u8), value: std.json.Value, depth: usize) anyerror!void {
    if (depth > 64) return error.DictionaryContentTooDeep;
    switch (value) {
        .string => try text.appendSlice(a, value.string),
        .array => for (value.array.items, 0..) |child, i| {
            if (depth == 0 and i > 0) try text.append(a, '\n');
            try visit(a, parts, text, child, depth + 1);
        },
        .object => {
            const tag = string(value, "tag") orelse "";
            const kind = string(value, "type") orelse "";
            if (std.mem.eql(u8, tag, "img") or std.mem.eql(u8, kind, "image")) {
                const path = string(value, "path") orelse return;
                try flush(a, parts, text);
                try parts.append(a, .{ .image = .{
                    .path = path,
                    .width = number(value, "width"),
                    .height = number(value, "height"),
                    .em = std.mem.eql(u8, string(value, "sizeUnits") orelse "", "em"),
                    .monochrome = std.mem.eql(u8, string(value, "appearance") orelse "", "monochrome"),
                    .alt = string(value, "alt") orelse string(value, "title") orelse string(value, "description") orelse "Dictionary image",
                } });
                return;
            }
            if (std.mem.eql(u8, tag, "br")) {
                try text.append(a, '\n');
                return;
            }
            if (value.object.get("content")) |content| {
                try visit(a, parts, text, content, depth + 1);
            } else if (string(value, "text")) |content| {
                try text.appendSlice(a, content);
            } else if (string(value, "description")) |content| {
                try text.appendSlice(a, content);
            }
            if (std.mem.eql(u8, tag, "div") or std.mem.eql(u8, tag, "li") or std.mem.eql(u8, tag, "tr")) try text.append(a, '\n');
        },
        else => {},
    }
}

test {
    _ = @import("../../tests/components/dictionaries/dictionary_content.zig");
}
