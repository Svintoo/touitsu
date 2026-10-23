//! Tests for components/pronunciation/audio_sources.zig.
const subject = @import("../../../components/pronunciation/audio_sources.zig");

pub fn Tests(comptime private: anytype) type {
    return struct {
        const std = @import("std");
        const japanesePodUrl = subject.japanesePodUrl;
        const validDigest = private.validDigest;
        const validJapanesePod = subject.validJapanesePod;
        const download = subject.download;

        test "JapanesePod encodes both fields and omits duplicate kana headword" {
            const a = std.testing.allocator;
            const url = try japanesePodUrl(a, "食べる", "たべる");
            defer a.free(url);
            try std.testing.expectEqualStrings("https://assets.languagepod101.com/dictionary/japanese/audiomp3.php?kanji=%E9%A3%9F%E3%81%B9%E3%82%8B&kana=%E3%81%9F%E3%81%B9%E3%82%8B", url);
            const kana = try japanesePodUrl(a, "ねこ", "ねこ");
            defer a.free(kana);
            try std.testing.expect(std.mem.endsWith(u8, kana, "?kana=%E3%81%AD%E3%81%93"));
            const empty_reading = try japanesePodUrl(a, "a&b", "");
            defer a.free(empty_reading);
            try std.testing.expect(std.mem.endsWith(u8, empty_reading, "?kanji=a%26b"));
            try std.testing.expect(!validJapanesePod("<html>error</html>"));
            var missing: [32]u8 = undefined;
            _ = try std.fmt.hexToBytes(&missing, "ae6398b5a27bc8c0a771df6c907ade794be15518174773c58c7c7ddd17098906");
            try std.testing.expect(!validDigest(missing));
        }

        test "audio source fallback preserves exact reading and cancellation" {
            const Mock = struct {
                calls: usize = 0,
                mode: enum { success, invalid, unavailable, cancelled } = .success,
                pub fn fetch(self: *@This(), url: []const u8) ![]u8 {
                    self.calls += 1;
                    if (std.mem.startsWith(u8, url, "https://assets.languagepod101.com/")) {
                        return switch (self.mode) {
                            .success => std.testing.allocator.dupe(u8, "ID3pod"),
                            .invalid => std.testing.allocator.dupe(u8, "not audio"),
                            .unavailable => error.ServiceUnavailable,
                            .cancelled => error.Cancelled,
                        };
                    }
                    if (std.mem.startsWith(u8, url, "https://jisho.org/search/"))
                        return std.testing.allocator.dupe(u8, "<audio id='audio_word:right'><source src='https://jisho.org/right.mp3' type='audio/mpeg'></audio>");
                    try std.testing.expectEqualStrings("https://jisho.org/right.mp3", url);
                    return std.testing.allocator.dupe(u8, "ID3jisho");
                }
            };
            for ([_]@FieldType(Mock, "mode"){ .success, .invalid, .unavailable, .cancelled }) |mode| {
                var mock: Mock = .{ .mode = mode };
                if (mode == .cancelled) {
                    try std.testing.expectError(error.Cancelled, download(std.testing.allocator, &mock, "word", "right"));
                } else {
                    const audio = try download(std.testing.allocator, &mock, "word", "right");
                    defer std.testing.allocator.free(audio);
                    try std.testing.expectEqualStrings(if (mode == .success) "ID3pod" else "ID3jisho", audio);
                }
                try std.testing.expectEqual(@as(usize, if (mode == .success or mode == .cancelled) 1 else 3), mock.calls);
            }
        }
    };
}
