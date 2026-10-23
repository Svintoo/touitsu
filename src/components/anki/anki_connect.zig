//! AnkiConnect v6 protocol. All network calls belong on a worker thread.
const std = @import("std");
const a = std.heap.smp_allocator;
extern fn touitsu_anki_post([*:0]const u16, [*]const u8, usize, *?[*]u8, *usize) c_int;
extern fn touitsu_anki_free([*]u8) void;

pub fn request(action: []const u8, params: anytype, key: []const u8) ![]u8 {
    // Zig's .{} is an empty tuple and serializes as []. AnkiConnect requires
    // an object for params, including actions that take no arguments.
    const wire_params = if (@TypeOf(params) == @TypeOf(.{})) struct {}{} else params;
    return std.json.Stringify.valueAlloc(a, .{ .action = action, .version = @as(u32, 6), .params = wire_params, .key = if (key.len == 0) @as(?[]const u8, null) else key }, .{});
}
pub fn post(endpoint: []const u8, body: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, endpoint, 0) != null) return error.InvalidAddress;
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, endpoint);
    defer a.free(wide);
    var ptr: ?[*]u8 = null;
    var len: usize = 0;
    switch (touitsu_anki_post(wide, body.ptr, body.len, &ptr, &len)) {
        0 => {},
        1 => return error.InvalidAddress,
        2 => return error.CannotConnect,
        3 => return error.HttpError,
        4 => return error.ResponseTooLarge,
        else => return error.OutOfMemory,
    }
    defer touitsu_anki_free(ptr.?);
    return a.dupe(u8, ptr.?[0..len]);
}
pub fn result(value: std.json.Value) !std.json.Value {
    if (value != .object) return error.InvalidResponse;
    const err = value.object.get("error") orelse return error.InvalidResponse;
    if (err != .null) return error.AnkiError;
    return value.object.get("result") orelse error.InvalidResponse;
}
pub fn html(text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (text) |c| switch (c) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        '"' => try out.appendSlice(a, "&quot;"),
        '\n' => try out.appendSlice(a, "<br>"),
        '\r' => {},
        else => try out.append(a, c),
    };
    return out.toOwnedSlice(a);
}
pub const Note = struct {
    deck: []const u8,
    model: []const u8,
    front_field: []const u8,
    back_field: []const u8,
    word: []const u8,
    reading: []const u8,
    definition: []const u8,
    sentence: []const u8,
    allow_duplicate: bool = false,
};
pub fn addRequest(note: Note, key: []const u8) ![]u8 {
    if (note.front_field.len == 0 or note.back_field.len == 0 or std.mem.eql(u8, note.front_field, note.back_field)) return error.InvalidFields;
    const front = try html(note.word);
    defer a.free(front);
    const reading = try html(note.reading);
    defer a.free(reading);
    const definition = try html(note.definition);
    defer a.free(definition);
    const sentence = try html(note.sentence);
    defer a.free(sentence);
    const back = try std.fmt.allocPrint(a, "{s}<br><br>{s}<br><br>{s}", .{ reading, definition, sentence });
    defer a.free(back);
    var fields: std.json.ObjectMap = .empty;
    defer fields.deinit(a);
    try fields.put(a, note.front_field, .{ .string = front });
    try fields.put(a, note.back_field, .{ .string = back });
    return request("addNote", .{ .note = .{ .deckName = note.deck, .modelName = note.model, .fields = std.json.Value{ .object = fields }, .options = .{ .allowDuplicate = note.allow_duplicate }, .tags = &[_][]const u8{"touitsu"} } }, key);
}

test {
    _ = @import("../../tests/components/anki/anki_connect.zig");
}
