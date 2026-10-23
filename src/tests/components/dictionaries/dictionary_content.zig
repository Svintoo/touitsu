//! Tests for components/dictionaries/dictionary_content.zig.
const subject = @import("../../../components/dictionaries/dictionary_content.zig");

const std = @import("std");
const Document = subject.Document;

test "structured images keep text order dimensions and archive paths" {
    const doc = try Document.init(std.testing.allocator, "[{\"type\":\"structured-content\",\"content\":[\"before\",{\"tag\":\"img\",\"path\":\"gaiji/glyph.svg\",\"width\":1,\"height\":1,\"sizeUnits\":\"em\",\"appearance\":\"monochrome\"},\"after\"]}]");
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 3), doc.parts.len);
    try std.testing.expectEqualStrings("before", doc.parts[0].text);
    try std.testing.expectEqualStrings("gaiji/glyph.svg", doc.parts[1].image.path);
    try std.testing.expect(doc.parts[1].image.em and doc.parts[1].image.monochrome);
    try std.testing.expectEqualStrings("after", doc.parts[2].text);
}
