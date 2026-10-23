//! Tests for components/anki/anki_connect.zig.
const subject = @import("../../../components/anki/anki_connect.zig");

const std = @import("std");
const a = std.heap.smp_allocator;
const request = subject.request;
const result = subject.result;
const addRequest = subject.addRequest;

test "parameterless actions send an empty JSON object" {
    inline for (.{ "version", "deckNames", "modelNames" }) |action| {
        const bytes = try request(action, .{}, "");
        defer a.free(bytes);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
        defer parsed.deinit();
        const params = parsed.value.object.get("params").?;
        try std.testing.expect(params == .object);
        try std.testing.expectEqual(@as(usize, 0), params.object.count());
    }
}

test "card mapping escapes HTML and preserves Japanese and source sentence" {
    const bytes = try addRequest(.{ .deck = "Japanese", .model = "Basic", .front_field = "Front", .back_field = "Back", .word = "日本", .reading = "にほん", .definition = "Japan & <country>\nmeaning", .sentence = "日本へ行く。" }, "");
    defer a.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer parsed.deinit();
    const note = parsed.value.object.get("params").?.object.get("note").?;
    const fields = note.object.get("fields").?.object;
    try std.testing.expectEqualStrings("日本", fields.get("Front").?.string);
    try std.testing.expectEqualStrings("にほん<br><br>Japan &amp; &lt;country&gt;<br>meaning<br><br>日本へ行く。", fields.get("Back").?.string);
    try std.testing.expect(!note.object.get("options").?.object.get("allowDuplicate").?.bool);
}

test "Anki response distinguishes API errors and malformed data" {
    const good = try std.json.parseFromSlice(std.json.Value, a, "{\"result\":123,\"error\":null}", .{});
    defer good.deinit();
    try std.testing.expectEqual(@as(i64, 123), (try result(good.value)).integer);
    const bad = try std.json.parseFromSlice(std.json.Value, a, "{\"result\":null,\"error\":\"duplicate\"}", .{});
    defer bad.deinit();
    try std.testing.expectError(error.AnkiError, result(bad.value));
    try std.testing.expectError(error.InvalidResponse, result(.null));
}

test "chosen entry permits another definition of the same word" {
    const body = try addRequest(.{ .deck = "Default", .model = "Basic", .front_field = "Front", .back_field = "Back", .word = "word", .reading = "reading", .definition = "chosen definition", .sentence = "context", .allow_duplicate = true }, "");
    defer a.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    const note = parsed.value.object.get("params").?.object.get("note").?;
    try std.testing.expect(note.object.get("options").?.object.get("allowDuplicate").?.bool);
    try std.testing.expectEqualStrings("reading<br><br>chosen definition<br><br>context", note.object.get("fields").?.object.get("Back").?.string);
}
