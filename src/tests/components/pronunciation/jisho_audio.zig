//! Tests for components/pronunciation/jisho_audio.zig.
const subject = @import("../../../components/pronunciation/jisho_audio.zig");

const std = @import("std");
const searchUrl = subject.searchUrl;
const audioUrl = subject.audioUrl;

test "Jisho lookup encodes terms and matches exact reading" {
    const a = std.testing.allocator;
    const url = try searchUrl(a, "a/b ?");
    defer a.free(url);
    try std.testing.expectEqualStrings("https://jisho.org/search/a%2Fb%20%3F", url);
    const html = "<audio id='audio_word:wrong'><source src='https://jisho.org/wrong.mp3'></audio>" ++
        "<audio controls id=\"audio_word:right\"><source type='audio/ogg' src='https://jisho.org/audio.ogg'><source src='//d1vjc5dkcd3yh2.cloudfront.net/audio/a.mp3?x=1&amp;y=2' type='audio/mpeg'></audio>";
    const audio = try audioUrl(a, html, "word", "right");
    defer a.free(audio);
    try std.testing.expectEqualStrings("https://d1vjc5dkcd3yh2.cloudfront.net/audio/a.mp3?x=1&y=2", audio);
    try std.testing.expectError(error.AudioNotFound, audioUrl(a, html, "word", "missing"));
}
