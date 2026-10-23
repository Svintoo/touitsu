//! Editable per-note-type field templates. Text values are escaped for Anki HTML.
const std = @import("std");
const api = @import("anki_connect.zig");
const a = std.heap.smp_allocator;
pub const Mapping = struct { model: []const u8, field: []const u8, template: []const u8 };
pub const Values = struct {
    expression: []const u8,
    reading: []const u8,
    glossary: []const u8,
    sentence: []const u8,
    dictionary: []const u8,
    audio: []const u8 = "",
};
pub fn readingFor(expression: []const u8, reading: []const u8) []const u8 {
    if (reading.len > 0) return reading;
    const view = std.unicode.Utf8View.init(expression) catch return "";
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (!((cp >= 0x3040 and cp <= 0x30ff) or (cp >= 0xff66 and cp <= 0xff9f))) return "";
    }
    return expression;
}
pub fn expand(template: []const u8, values: Values) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '{') {
            if (std.mem.indexOfScalarPos(u8, template, i + 1, '}')) |end| {
                const name = template[i + 1 .. end];
                var matched = false;
                inline for (.{ "expression", "reading", "glossary", "sentence", "dictionary", "audio" }) |field_name| {
                    if (std.mem.eql(u8, name, field_name) or (std.mem.eql(u8, name, "definition") and comptime std.mem.eql(u8, field_name, "glossary"))) {
                        const value = @field(values, field_name);
                        if (comptime std.mem.eql(u8, field_name, "audio")) {
                            try out.appendSlice(a, value);
                        } else {
                            const escaped = try api.html(value);
                            defer a.free(escaped);
                            try out.appendSlice(a, escaped);
                        }
                        matched = true;
                    }
                }
                if (!matched) return error.UnknownPlaceholder;
                i = end + 1;
                continue;
            }
            return error.UnclosedPlaceholder;
        }
        try out.append(a, template[i]);
        i += 1;
    }
    return out.toOwnedSlice(a);
}
pub fn addRequest(deck: []const u8, model: []const u8, mappings: []const Mapping, values: Values, key: []const u8) ![]u8 {
    var fields: std.json.ObjectMap = .empty;
    defer {
        for (fields.values()) |value| a.free(value.string);
        fields.deinit(a);
    }
    for (mappings) |mapping| {
        if (!std.mem.eql(u8, mapping.model, model)) continue;
        const value = try expand(mapping.template, values);
        errdefer a.free(value);
        try fields.put(a, mapping.field, .{ .string = value });
    }
    if (fields.count() == 0) return error.InvalidFields;
    return api.request("addNote", .{ .note = .{ .deckName = deck, .modelName = model, .fields = std.json.Value{ .object = fields }, .options = .{ .allowDuplicate = true }, .tags = &[_][]const u8{"touitsu"} } }, key);
}

test {
    _ = @import("../../tests/components/anki/anki_format.zig");
}
