//! Tests for platform/image_decode.zig.
const subject = @import("../../platform/image_decode.zig");

const std = @import("std");
const load = subject.load;
const memory = subject.memory;

test "WIC decodes image pixels and rejects non-image input" {
    const image = try load("src/testdata/background-test.png");
    defer image.deinit();
    try std.testing.expectEqual(@as(u32, 4), image.width);
    try std.testing.expectEqual(@as(u32, 2), image.height);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, image.pixels[0..4]);
    try std.testing.expectError(error.CannotDecodeImage, load("src/testdata/README.md"));
}

test "dictionary raster and SVG assets decode from memory" {
    const png = try memory(@embedFile("../../testdata/background-test.png"), false);
    defer png.deinit();
    try std.testing.expectEqual(@as(u32, 4), png.width);
    const svg = try memory("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 5\"><rect width=\"10\" height=\"5\" fill=\"red\"/></svg>", true);
    defer svg.deinit();
    try std.testing.expectEqual(svg.width, svg.height * 2);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, svg.pixels[0..4]);
    try std.testing.expectError(error.CannotDecodeImage, memory("invalid", true));
}
