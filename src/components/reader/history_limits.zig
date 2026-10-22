//! Approximate word budget without dictionary-dependent tokenization.
const std = @import("std");

// Half-word units: two Japanese characters or one Latin word count as a word.
pub const max_units = 500_000 * 2;
pub const max_bytes = 8 * 1024 * 1024;
pub const max_lines = 100_000;

pub fn units(text: []const u8) usize {
    const view = std.unicode.Utf8View.init(text) catch return text.len * 2;
    var it = view.iterator();
    var total: usize = 0;
    var in_word = false;
    while (it.nextCodepoint()) |cp| {
        if ((cp >= 0x3000 and cp <= 0x30ff) or
            (cp >= 0x3400 and cp <= 0x9fff) or
            (cp >= 0xf900 and cp <= 0xfaff) or
            (cp >= 0xff00 and cp <= 0xffef) or
            (cp >= 0x20000 and cp <= 0x323af))
        {
            total += 1;
            in_word = false;
        } else if (cp <= 0x20 or cp == 0xa0 or (cp >= 0x2000 and cp <= 0x206f)) {
            in_word = false;
        } else {
            if (!in_word) total += 2;
            in_word = true;
        }
    }
    return total;
}

test "hook history preview word estimate handles Japanese and spaced text" {
    try std.testing.expectEqual(@as(usize, 4), units("one two"));
    try std.testing.expectEqual(@as(usize, 4), units("日本語文"));
    try std.testing.expectEqual(@as(usize, 6), units("日本語文 word"));
    try std.testing.expectEqual(@as(usize, 0), units(" \n\t"));
}
