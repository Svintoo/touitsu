//! Tests for components/textractor/hook_sample_filter.zig.
const subject = @import("../../../components/textractor/hook_sample_filter.zig");

const std = @import("std");
const clean = subject.clean;
const hasJapanese = subject.hasJapanese;
const reducePairs = subject.reducePairs;

test "paired capture repetition preserves doubled letters and UTF-8" {
    const result = try reducePairs(std.testing.allocator, "aappppllee\xe3\x81\x82\xe3\x81\x82!");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("apple\xe3\x81\x82!", result);
}

test "clean malformed samples without losing Japanese or whitespace" {
    const result = try clean(std.testing.allocator, "\x00\x01Hello\xff\xef\xbf\xbd\xee\x80\x80\n\xe3\x81\x82", .{ .private_use = true });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Hello\n\xe3\x81\x82", result);
    try std.testing.expect(hasJapanese(result));
    try std.testing.expect(!hasJapanese("Hello"));
}

test "filters can be disabled" {
    const result = try clean(std.testing.allocator, "\x00\xee\x80\x80\xff", .{ .controls = false, .invalid = false });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\x00\xee\x80\x80\xef\xbf\xbd", result);
}
