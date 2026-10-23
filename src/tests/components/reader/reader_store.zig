//! Tests for components/reader/reader_store.zig.
const subject = @import("../../../components/reader/reader_store.zig");

const std = @import("std");
const readAll = subject.readAll;
const writeAll = subject.writeAll;

test "history replacement preserves UTF-8 and replaces the previous snapshot" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    const filename = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/reader.json", .{temp.sub_path});
    defer testing.allocator.free(filename);
    const path = try std.unicode.utf8ToUtf16LeAllocZ(testing.allocator, filename);
    defer testing.allocator.free(path);
    try writeAll(path, "{\"lines\":[\"日本語\"],\"elapsed_ms\":1200}");
    const first = (try readAll(testing.allocator, path)).?;
    defer testing.allocator.free(first);
    try testing.expectEqualStrings("{\"lines\":[\"日本語\"],\"elapsed_ms\":1200}", first);
    try writeAll(path, "{\"lines\":[],\"elapsed_ms\":0}");
    const second = (try readAll(testing.allocator, path)).?;
    defer testing.allocator.free(second);
    try testing.expectEqualStrings("{\"lines\":[],\"elapsed_ms\":0}", second);
}
