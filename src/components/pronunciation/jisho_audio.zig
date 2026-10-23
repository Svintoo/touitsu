//! Jisho's word-and-reading audio lookup. No network work in this module.
const std = @import("std");

pub fn searchUrl(a: std.mem.Allocator, term: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "https://jisho.org/search/");
    const hex = "0123456789ABCDEF";
    for (term) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(a, c);
        } else try out.appendSlice(a, &.{ '%', hex[c >> 4], hex[c & 15] });
    }
    return out.toOwnedSlice(a);
}

fn attribute(tag: []const u8, wanted: []const u8) ?[]const u8 {
    var i: usize = std.mem.indexOfScalar(u8, tag, ' ') orelse return null;
    while (i < tag.len) {
        while (i < tag.len and std.ascii.isWhitespace(tag[i])) : (i += 1) {}
        const start = i;
        while (i < tag.len and tag[i] != '=' and !std.ascii.isWhitespace(tag[i]) and tag[i] != '>') : (i += 1) {}
        const name = tag[start..i];
        const name_end = i;
        while (i < tag.len and std.ascii.isWhitespace(tag[i])) : (i += 1) {}
        if (i == tag.len or tag[i] != '=') {
            i = @max(name_end, start + 1);
            continue;
        }
        i += 1;
        while (i < tag.len and std.ascii.isWhitespace(tag[i])) : (i += 1) {}
        if (i == tag.len) return null;
        const quote = tag[i];
        const quoted = quote == '"' or quote == '\'';
        if (quoted) i += 1;
        const value_start = i;
        while (i < tag.len and (if (quoted) tag[i] != quote else !std.ascii.isWhitespace(tag[i]) and tag[i] != '>')) : (i += 1) {}
        if (std.ascii.eqlIgnoreCase(name, wanted)) return tag[value_start..i];
        if (quoted and i < tag.len) i += 1;
    }
    return null;
}

pub fn audioUrl(a: std.mem.Allocator, html: []const u8, term: []const u8, reading: []const u8) ![]u8 {
    const id = try std.fmt.allocPrint(a, "audio_{s}:{s}", .{ term, if (reading.len > 0) reading else term });
    defer a.free(id);
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, html, offset, "<audio")) |start| {
        const opening_end = std.mem.indexOfScalarPos(u8, html, start, '>') orelse break;
        const end = std.mem.indexOfPos(u8, html, opening_end, "</audio>") orelse break;
        offset = end + 8;
        const found_id = attribute(html[start .. opening_end + 1], "id") orelse continue;
        if (!std.mem.eql(u8, found_id, id)) continue;
        var cursor = opening_end;
        while (std.mem.indexOfPos(u8, html[0..end], cursor, "<source")) |source| {
            const source_end = std.mem.indexOfScalarPos(u8, html, source, '>') orelse break;
            cursor = source_end + 1;
            const tag = html[source .. source_end + 1];
            if (attribute(tag, "type")) |kind| {
                if (!std.ascii.eqlIgnoreCase(kind, "audio/mpeg")) continue;
            }
            const raw = attribute(tag, "src") orelse continue;
            const decoded = try std.mem.replaceOwned(u8, a, raw, "&amp;", "&");
            defer a.free(decoded);
            if (std.mem.startsWith(u8, decoded, "//")) return std.fmt.allocPrint(a, "https:{s}", .{decoded});
            if (std.mem.startsWith(u8, decoded, "/")) return std.fmt.allocPrint(a, "https://jisho.org{s}", .{decoded});
            if (std.mem.startsWith(u8, decoded, "https://")) return a.dupe(u8, decoded);
        }
    }
    return error.AudioNotFound;
}

test {
    _ = @import("../../tests/components/pronunciation/jisho_audio.zig");
}
