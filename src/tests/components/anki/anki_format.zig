//! Tests for components/anki/anki_format.zig.
const subject = @import("../../../components/anki/anki_format.zig");

const std = @import("std");
const a = std.heap.smp_allocator;
const readingFor = subject.readingFor;
const expand = subject.expand;
const addRequest = subject.addRequest;

test "custom mining fields receive only their chosen parts and escaped source text" {
    const body = try addRequest("Mining", "Mining-475ae", &.{
        .{ .model = "Mining-475ae", .field = "front", .template = "{expression}" },
        .{ .model = "Mining-475ae", .field = "Reading", .template = "{reading}" },
        .{ .model = "Mining-475ae", .field = "Glossary", .template = "<b>{glossary}</b>" },
        .{ .model = "Mining-475ae", .field = "Audio", .template = "{audio}" },
        .{ .model = "Mining-475ae", .field = "Hint", .template = "" },
    }, .{ .expression = "word", .reading = "kana", .glossary = "one & <two>", .sentence = "context", .dictionary = "source", .audio = "[sound:test.mp3]" }, "");
    defer a.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    const fields = parsed.value.object.get("params").?.object.get("note").?.object.get("fields").?.object;
    try std.testing.expectEqualStrings("word", fields.get("front").?.string);
    try std.testing.expectEqualStrings("kana", fields.get("Reading").?.string);
    try std.testing.expectEqualStrings("<b>one &amp; &lt;two&gt;</b>", fields.get("Glossary").?.string);
    try std.testing.expectEqualStrings("[sound:test.mp3]", fields.get("Audio").?.string);
    try std.testing.expectEqualStrings("", fields.get("Hint").?.string);
}

test "unknown Yomichan markers cannot silently become card contents" {
    try std.testing.expectError(error.UnknownPlaceholder, expand("{pitch-accent-graphs}", .{ .expression = "", .reading = "", .glossary = "", .sentence = "", .dictionary = "" }));
}

test "reading fallback uses kana expressions and never substitutes kanji" {
    try std.testing.expectEqualStrings("", readingFor("\u{65e5}\u{672c}", ""));
    try std.testing.expectEqualStrings("\u{306d}\u{3053}", readingFor("\u{306d}\u{3053}", ""));
    try std.testing.expectEqualStrings("\u{30cd}\u{30b3}", readingFor("\u{732b}", "\u{30cd}\u{30b3}"));
}
