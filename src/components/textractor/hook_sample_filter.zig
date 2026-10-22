const std = @import("std");

pub const Options = struct {
    controls: bool = true,
    invalid: bool = true,
    private_use: bool = false,
    japanese_only: bool = false,
    unsupported: bool = true,
};

pub fn clean(allocator: std.mem.Allocator, text: []const u8, options: Options) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 0;
        const cp = if (len > 0 and len <= text.len - i) std.unicode.utf8Decode(text[i..][0..len]) catch null else null;
        if (cp) |value| {
            const control = (value < 0x20 and value != '\n' and value != '\r' and value != '\t') or (value >= 0x7f and value <= 0x9f);
            const invalid = value == 0xfffd or (value >= 0xfdd0 and value <= 0xfdef) or (value & 0xffff >= 0xfffe);
            const private = (value >= 0xe000 and value <= 0xf8ff) or (value >= 0xf0000 and value <= 0xffffd) or (value >= 0x100000 and value <= 0x10fffd);
            if (!(options.controls and control) and !(options.invalid and invalid) and !(options.private_use and private))
                try result.appendSlice(allocator, text[i..][0..len]);
            i += len;
        } else {
            if (!options.invalid) try result.appendSlice(allocator, "\xef\xbf\xbd");
            i += 1;
        }
    }
    return try result.toOwnedSlice(allocator);
}

pub fn hasJapanese(text: []const u8) bool {
    var iter = (std.unicode.Utf8View.init(text) catch return false).iterator();
    while (iter.nextCodepoint()) |cp| {
        if ((cp >= 0x3040 and cp <= 0x30ff) or (cp >= 0x3400 and cp <= 0x9fff) or
            (cp >= 0xff66 and cp <= 0xff9f) or (cp >= 0x20000 and cp <= 0x323af)) return true;
    }
    return false;
}

/// Halve adjacent equal pairs, preserving legitimate repeated letters in doubled text.
pub fn reducePairs(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var iter = (try std.unicode.Utf8View.init(text)).iterator();
    var previous: ?[]const u8 = null;
    while (iter.nextCodepointSlice()) |bytes| {
        if (previous) |prev| {
            if (std.mem.eql(u8, prev, bytes)) {
                previous = null;
                continue;
            }
        }
        try result.appendSlice(allocator, bytes);
        previous = bytes;
    }
    return try result.toOwnedSlice(allocator);
}

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
