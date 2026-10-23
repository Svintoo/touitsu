//! Tests for components/reader/reader_text.zig.
const subject = @import("../../../components/reader/reader_text.zig");

const std = @import("std");
const isWhitespace = subject.isWhitespace;
const isSpecial = subject.isSpecial;

test "whitespace includes Unicode spaces and paragraph separators" {
    for ([_]u21{ ' ', '\t', '\n', 0xa0, 0x2003, 0x2028, 0x202f, 0x3000 }) |cp| try std.testing.expect(isWhitespace(cp));
    try std.testing.expect(!isWhitespace(0x8a9e));
}

test "special count excludes punctuation emoji and controls while retaining letters numbers and marks" {
    for ([_]u21{ '!', 0x3001, 0x3002, 0xff01, 0x1f600, 0x200b }) |cp| try std.testing.expect(isSpecial(cp));
    for ([_]u21{ 0x8a9e, 0x3042, 0x3005, 0xff21, '9', 0xe9, 0x3a9, 0x301 }) |cp| try std.testing.expect(!isSpecial(cp));
}
