//! Used only by test-anki-http with its isolated mock server.
const std = @import("std");
const api = @import("../components/anki/anki_connect.zig");
const a = std.heap.smp_allocator;

fn send(endpoint: []const u8, body: []const u8) !std.json.Parsed(std.json.Value) {
    const bytes = try api.post(endpoint, body);
    defer a.free(bytes);
    return std.json.parseFromSlice(std.json.Value, a, bytes, .{ .allocate = .alloc_always });
}
fn call(endpoint: []const u8, action: []const u8, params: anytype) !std.json.Parsed(std.json.Value) {
    const body = try api.request(action, params, "test-key");
    defer a.free(body);
    const parsed = try send(endpoint, body);
    errdefer parsed.deinit();
    _ = try api.result(parsed.value);
    return parsed;
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(a);
    defer a.free(args);
    const endpoint = args[1];
    const version = try call(endpoint, "version", .{});
    defer version.deinit();
    try std.testing.expectEqual(@as(i64, 6), (try api.result(version.value)).integer);
    inline for (.{ "deckNames", "modelNames" }) |action| {
        const parsed = try call(endpoint, action, .{});
        defer parsed.deinit();
        try std.testing.expect((try api.result(parsed.value)).array.items.len > 0);
    }
    const fields = try call(endpoint, "modelFieldNames", .{ .modelName = "Japanese" });
    defer fields.deinit();
    try std.testing.expectEqualStrings("Expression", (try api.result(fields.value)).array.items[0].string);
    const body = try api.addRequest(.{ .deck = "日本語", .model = "Japanese", .front_field = "Expression", .back_field = "Meaning", .word = "日本", .reading = "にほん", .definition = "Japan & <country>", .sentence = "日本へ行く。" }, "test-key");
    defer a.free(body);
    const added = try send(endpoint, body);
    defer added.deinit();
    const id = (try api.result(added.value)).integer;
    try std.testing.expectEqual(@as(i64, 1700000000123), id);
    const duplicate = try send(endpoint, body);
    defer duplicate.deinit();
    try std.testing.expectError(error.AnkiError, api.result(duplicate.value));
    const query = try std.fmt.allocPrint(a, "nid:{d}", .{id});
    defer a.free(query);
    const browse = try call(endpoint, "guiBrowse", .{ .query = query });
    defer browse.deinit();
    try std.testing.expectEqual(@as(usize, 1), (try api.result(browse.value)).array.items.len);
    try std.testing.expectError(error.InvalidAddress, api.post("file:///example", "{}"));
    const bad_http = try std.fmt.allocPrint(a, "{s}&fail=1", .{endpoint});
    defer a.free(bad_http);
    try std.testing.expectError(error.HttpError, api.post(bad_http, "{}"));
    try std.testing.expectError(error.SyntaxError, call(endpoint, "malformed", .{}));
}
