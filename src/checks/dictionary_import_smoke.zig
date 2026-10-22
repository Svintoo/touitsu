//! Isolated verification tool; never opens the application's dictionary database by default.
const std = @import("std");
const Dictionary = @import("../components/dictionaries/dictionary.zig");
const files = @import("../platform/dictionary_files.zig");
const zip = @import("../components/dictionaries/dictionary_zip.zig");
const Image = @import("../platform/image_decode.zig");
const a = std.heap.smp_allocator;
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(a);
    defer a.free(args);
    if (args.len < 3) return error.ExpectedDatabaseAndZipPaths;
    if (std.mem.eql(u8, args[1], "--lookup")) {
        const db_path = try std.fmt.allocPrintSentinel(a, "{s}", .{args[2]}, 0);
        defer a.free(db_path);
        var db = try Dictionary.Database.open(db_path);
        defer db.close();
        for (args[3..]) |query| {
            const end = try db.scanWord(query, 0);
            const popup = try db.lookupPopup(query);
            var results = popup.results;
            defer {
                for (results.items) |result| result.deinit();
                results.deinit(a);
            }
            std.debug.print("{s}: scan {d}/{d} bytes, {d} results\n", .{ query, end orelse 0, query.len, results.items.len });
            if (results.items.len > 0) std.debug.print("  {s} ({s}) [{s}]\n", .{ results.items[0].term, results.items[0].dictionary, results.items[0].deinflection orelse "exact" });
            std.debug.print("  Word group: {d}, starting-character group: {d}\n", .{ popup.word_count, results.items.len - popup.word_count });
            if (results.items.len > popup.word_count) std.debug.print("  Starting character: {s}\n", .{results.items[popup.word_count].term});
        }
        return;
    }
    const path = try std.fmt.allocPrintSentinel(a, "{s}", .{args[1]}, 0);
    defer a.free(path);
    var database = try Dictionary.Database.open(path);
    defer database.close();
    for (args[2..]) |archive_path| {
        std.debug.print("Importing {s}\n", .{archive_path});
        const mapped = try files.mapArchive(archive_path);
        defer mapped.deinit();
        const report = try database.importZip(mapped.bytes);
        defer a.free(report.title);
        std.debug.print("Imported {s}: {d} entries\n", .{ report.title, report.entries });
        var list = try database.dictionaries();
        defer Dictionary.freeDictionaries(&list);
        var id: i64 = 0;
        for (list.items) |dictionary| {
            if (std.mem.eql(u8, dictionary.title, report.title)) id = @intCast(dictionary.id);
        }
        var archive = try zip.Archive.init(mapped.bytes);
        var raster_checked = false;
        var svg_checked = false;
        while (try archive.next()) |entry| {
            const svg = std.ascii.endsWithIgnoreCase(entry.name, ".svg");
            const png = std.ascii.endsWithIgnoreCase(entry.name, ".png");
            if ((!svg or svg_checked) and (!png or raster_checked)) continue;
            const media = (try database.media(id, entry.name)) orelse return error.MissingImportedMedia;
            defer a.free(media);
            const image = try Image.memory(media, svg);
            defer image.deinit();
            std.debug.print("Decoded {s}: {d}x{d}\n", .{ entry.name, image.width, image.height });
            if (svg) svg_checked = true else raster_checked = true;
            if (raster_checked and svg_checked) break;
        }
    }
    const counts = try database.counts();
    std.debug.print("Verified {d} dictionaries / {d} entries\n", .{ counts.dictionaries, counts.terms });
}
