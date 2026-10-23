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

test {
    _ = @import("../tests/platform/image_decode.zig");
}
