//! Tests for text/japanese.zig.
const subject = @import("../../text/japanese.zig");

const std = @import("std");
const v1 = subject.v1;
const v5 = subject.v5;
const candidates = subject.candidates;
const compatible = subject.compatible;
const prefixEnds = subject.prefixEnds;

test "Japanese candidates cover common verbs adjectives and chained forms" {
    const pairs = [_][2][]const u8{
        .{ "食べました", "食べる" },
        .{ "食べませんでした", "食べる" },
        .{ "書いている", "書く" },
        .{ "読んでいました", "読む" },
        .{ "食べさせられませんでした", "食べる" },
        .{ "書かされました", "書く" },
        .{ "泳げなかった", "泳ぐ" },
        .{ "話したくなかった", "話す" },
        .{ "高くなかった", "高い" },
        .{ "高かったです", "高い" },
        .{ "勉強しました", "勉強する" },
        .{ "来られなかった", "来る" },
        .{ "行っちゃった", "行く" },
        .{ "読んじゃった", "読む" },
    };
    for (pairs) |pair| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const forms = try candidates(arena.allocator(), pair[0]);
        var found = false;
        for (forms) |form| {
            if (std.mem.eql(u8, form.text, pair[1])) {
                found = true;
                break;
            }
        }
        if (!found) std.debug.print("Missing deinflection: {s} -> {s}\n", .{ pair[0], pair[1] });
        try std.testing.expect(found);
        try std.testing.expect(forms.len <= 192);
    }
}

test "conjugation metadata and UTF-8 scan boundaries" {
    try std.testing.expect(compatible("v1", v1));
    try std.testing.expect(!compatible("v5", v1));
    try std.testing.expect(!compatible("adj-i", v5));
    try std.testing.expect(compatible("", v5));
    var ends: [32]usize = undefined;
    try std.testing.expectEqual(@as(usize, 2), prefixEnds("文字。次", 0, &ends));
    try std.testing.expectEqual(@as(usize, 6), ends[1]);
    try std.testing.expectEqual(@as(usize, 0), prefixEnds("文字", 1, &ends));
}
