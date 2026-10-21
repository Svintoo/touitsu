const std = @import("std");
const a = std.heap.smp_allocator;
extern fn touitsu_image_load([*:0]const u16, *?[*]u8, *u32, *u32) c_int;
extern fn touitsu_image_memory([*]const u8, u32, c_int, *?[*]u8, *u32, *u32) c_int;
extern fn touitsu_image_free([*]u8) void;

pixels: []u8,
width: u32,
height: u32,
const Self = @This();
pub fn load(path: []const u8) !Self {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
    defer a.free(wide);
    var pixels: ?[*]u8 = null;
    var width: u32 = 0;
    var height: u32 = 0;
    if (touitsu_image_load(wide, &pixels, &width, &height) != 0) return error.CannotDecodeImage;
    return .{ .pixels = pixels.?[0 .. @as(usize, width) * height * 4], .width = width, .height = height };
}
// Decodes dictionary assets directly from SQLite without temporary files.
pub fn memory(bytes: []const u8, svg: bool) !Self {
    if (bytes.len == 0 or bytes.len > 64 * 1024 * 1024) return error.CannotDecodeImage;
    var pixels: ?[*]u8 = null;
    var width: u32 = 0;
    var height: u32 = 0;
    if (touitsu_image_memory(bytes.ptr, @intCast(bytes.len), @intFromBool(svg), &pixels, &width, &height) != 0) return error.CannotDecodeImage;
    return .{ .pixels = pixels.?[0 .. @as(usize, width) * height * 4], .width = width, .height = height };
}
pub fn deinit(self: Self) void {
    touitsu_image_free(self.pixels.ptr);
}

test "WIC decodes image pixels and rejects non-image input" {
    const image = try load("src/testdata/background-test.png");
    defer image.deinit();
    try std.testing.expectEqual(@as(u32, 4), image.width);
    try std.testing.expectEqual(@as(u32, 2), image.height);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, image.pixels[0..4]);
    try std.testing.expectError(error.CannotDecodeImage, load("src/testdata/README.md"));
}

test "dictionary raster and SVG assets decode from memory" {
    const png = try memory(@embedFile("testdata/background-test.png"), false);
    defer png.deinit();
    try std.testing.expectEqual(@as(u32, 4), png.width);
    const svg = try memory("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 5\"><rect width=\"10\" height=\"5\" fill=\"red\"/></svg>", true);
    defer svg.deinit();
    try std.testing.expectEqual(svg.width, svg.height * 2);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, svg.pixels[0..4]);
    try std.testing.expectError(error.CannotDecodeImage, memory("invalid", true));
}
