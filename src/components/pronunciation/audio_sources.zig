//! Recorded audio sources shared by playback and Anki export.
const std = @import("std");
const jisho = @import("jisho_audio.zig");

fn encoded(out: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (text) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(a, c);
        } else try out.appendSlice(a, &.{ '%', hex[c >> 4], hex[c & 15] });
    }
}

fn entirelyKana(text: []const u8) bool {
    const view = std.unicode.Utf8View.init(text) catch return false;
    var iterator = view.iterator();
    if (text.len == 0) return false;
    while (iterator.nextCodepoint()) |c| {
        if (!(c >= 0x3041 and c <= 0x3096) and !(c >= 0x309d and c <= 0x309f) and
            !(c >= 0x30a1 and c <= 0x30fa) and !(c >= 0x30fc and c <= 0x30ff)) return false;
    }
    return true;
}

pub fn japanesePodUrl(a: std.mem.Allocator, term: []const u8, reading: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "https://assets.languagepod101.com/dictionary/japanese/audiomp3.php?");
    const kana_only = std.mem.eql(u8, term, reading) and entirelyKana(term);
    if (term.len > 0 and !kana_only) {
        try out.appendSlice(a, "kanji=");
        try encoded(&out, a, term);
    }
    if (reading.len > 0) {
        if (term.len > 0 and !kana_only) try out.append(a, '&');
        try out.appendSlice(a, "kana=");
        try encoded(&out, a, reading);
    }
    return out.toOwnedSlice(a);
}

pub fn isMp3(audio: []const u8) bool {
    return audio.len >= 3 and (std.mem.startsWith(u8, audio, "ID3") or
        (audio[0] == 0xff and audio[1] & 0xe0 == 0xe0));
}

fn validDigest(digest: [32]u8) bool {
    // JapanesePod101 returns this placeholder recording for missing words.
    const missing = "\xae\x63\x98\xb5\xa2\x7b\xc8\xc0\xa7\x71\xdf\x6c\x90\x7a\xde\x79\x4b\xe1\x55\x18\x17\x47\x73\xc5\x8c\x7c\x7d\xdd\x17\x09\x89\x06";
    return !std.mem.eql(u8, &digest, missing);
}

pub fn validJapanesePod(audio: []const u8) bool {
    if (!isMp3(audio)) return false;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(audio, &digest, .{});
    return validDigest(digest);
}

fn fromJapanesePod(a: std.mem.Allocator, fetcher: anytype, term: []const u8, reading: []const u8) ![]u8 {
    const url = try japanesePodUrl(a, term, reading);
    defer a.free(url);
    const audio = try fetcher.fetch(url);
    errdefer a.free(audio);
    if (!validJapanesePod(audio)) return error.AudioNotFound;
    return audio;
}

pub fn download(a: std.mem.Allocator, fetcher: anytype, term: []const u8, reading: []const u8) ![]u8 {
    return fromJapanesePod(a, fetcher, term, reading) catch |err| {
        switch (err) {
            error.Cancelled, error.OutOfMemory => return err,
            else => {},
        }
        const url = try jisho.searchUrl(a, term);
        defer a.free(url);
        const html = try fetcher.fetch(url);
        defer a.free(html);
        const audio_url = try jisho.audioUrl(a, html, term, reading);
        defer a.free(audio_url);
        const audio = try fetcher.fetch(audio_url);
        errdefer a.free(audio);
        if (!isMp3(audio)) return error.AudioNotFound;
        return audio;
    };
}

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
