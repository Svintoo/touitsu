//! Tests for components/dictionaries/dictionary.zig.
const subject = @import("../../../components/dictionaries/dictionary.zig");

const std = @import("std");
const a = std.heap.smp_allocator;
const Database = subject.Database;
const freeDictionaries = subject.freeDictionaries;

pub fn Tests(comptime private: anytype) type {
    return struct {
        test "import compressed v3 dictionaries, look up Japanese terms and readings, flatten glossaries" {
            var db = try Database.open(":memory:");
            defer db.close();
            const report = try db.importZip(@embedFile("../../../testdata/dictionary-valid.zip"));
            defer a.free(report.title);
            try std.testing.expectEqual(@as(usize, 3), report.entries);
            var matches = try db.lookup("たべる");
            defer {
                for (matches.items) |r| r.deinit();
                matches.deinit(a);
            }
            try std.testing.expectEqual(@as(usize, 1), matches.items.len);
            try std.testing.expectEqualStrings("食べる", matches.items[0].term);
            try std.testing.expectEqualStrings("to eat\nto consume\nfood\n", matches.items[0].definition);
            try std.testing.expectEqualStrings("Touitsu test dictionary", matches.items[0].dictionary);
            var cats = try db.lookup("猫");
            defer {
                for (cats.items) |r| r.deinit();
                cats.deinit(a);
            }
            try std.testing.expectEqual(@as(usize, 2), cats.items.len);
            var miss = try db.lookup("食べました");
            defer {
                for (miss.items) |result| result.deinit();
                miss.deinit(a);
            }
            try std.testing.expectEqual(@as(usize, 1), miss.items.len);
            try std.testing.expect(miss.items[0].deinflection != null);
        }

        test "failed replacement rolls back and successful replacement does not duplicate terms" {
            var db = try Database.open(":memory:");
            defer db.close();
            const original = try db.importZip(@embedFile("../../../testdata/dictionary-valid.zip"));
            defer a.free(original.title);
            try std.testing.expectError(error.InvalidTermEntry, db.importZip(@embedFile("../../../testdata/dictionary-invalid.zip")));
            var counts = try db.counts();
            try std.testing.expectEqual(@as(usize, 3), counts.terms);
            try std.testing.expectEqual(@as(usize, 1), counts.dictionaries);
            const replacement = try db.importZip(@embedFile("../../../testdata/dictionary-replacement.zip"));
            defer a.free(replacement.title);
            counts = try db.counts();
            try std.testing.expectEqual(@as(usize, 1), counts.terms);
            try std.testing.expectEqual(@as(usize, 1), counts.dictionaries);
            var matches = try db.lookup("犬");
            defer {
                for (matches.items) |r| r.deinit();
                matches.deinit(a);
            }
            try std.testing.expectEqualStrings("dog", matches.items[0].definition);
        }

        test "unsupported dictionaries and truncated archives fail without modifying the database" {
            var db = try Database.open(":memory:");
            defer db.close();
            try std.testing.expectError(error.UnsupportedDictionaryFormat, db.importZip(@embedFile("../../../testdata/dictionary-v2.zip")));
            try std.testing.expectError(error.InvalidZip, db.importZip("not a zip"));
            const counts = try db.counts();
            try std.testing.expectEqual(@as(usize, 0), counts.dictionaries);
        }

        test "stored ZIP entries, checksum failures and blank queries" {
            var db = try Database.open(":memory:");
            defer db.close();
            const report = try db.importZip(@embedFile("../../../testdata/dictionary-stored.zip"));
            defer a.free(report.title);
            try std.testing.expectError(error.ZipChecksumMismatch, db.importZip(@embedFile("../../../testdata/dictionary-checksum.zip")));
            const counts = try db.counts();
            try std.testing.expectEqual(@as(usize, 3), counts.terms);
            var matches = try db.lookup(" \t\n");
            defer matches.deinit(a);
            try std.testing.expectEqual(@as(usize, 0), matches.items.len);
        }

        test "dictionaries and Japanese lookup survive closing and reopening SQLite" {
            var temp = std.testing.tmpDir(.{});
            defer temp.cleanup();
            const path = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}/dictionary.sqlite3", .{temp.sub_path}, 0);
            defer a.free(path);
            {
                var db = try Database.open(path);
                defer db.close();
                const report = try db.importZip(@embedFile("../../../testdata/dictionary-valid.zip"));
                defer a.free(report.title);
            }
            var reopened = try Database.open(path);
            defer reopened.close();
            var results = try reopened.lookup("食べる");
            defer {
                for (results.items) |r| r.deinit();
                results.deinit(a);
            }
            try std.testing.expectEqual(@as(usize, 1), results.items.len);
            try std.testing.expectEqualStrings("たべる", results.items[0].reading);
        }

        test "folder cache skips unchanged archives and removes dictionaries absent from the folder" {
            var db = try Database.open(":memory:");
            defer db.close();
            const report = try db.importZip(@embedFile("../../../testdata/dictionary-valid.zip"));
            defer a.free(report.title);
            try std.testing.expect(!(try db.sourceUnchanged("dicts/test.zip", "hash1")));
            try db.recordSource("dicts/test.zip", report.title, "hash1");
            try std.testing.expect(try db.sourceUnchanged("dicts/test.zip", "hash1"));
            try std.testing.expect(!(try db.sourceUnchanged("dicts/test.zip", "hash2")));
            const source = try a.dupe(u8, "dicts/test.zip");
            defer a.free(source);
            try db.reconcileSources(&.{source});
            var counts = try db.counts();
            try std.testing.expectEqual(@as(usize, 3), counts.terms);
            try db.reconcileSources(&.{});
            counts = try db.counts();
            try std.testing.expectEqual(@as(usize, 0), counts.terms);
            try std.testing.expectEqual(@as(usize, 0), counts.dictionaries);
            try std.testing.expect(!(try db.sourceUnchanged("dicts/test.zip", "hash1")));
        }

        test "dictionary priorities shift ranks and order lookup before the result limit" {
            var db = try Database.open(":memory:");
            defer db.close();
            try private.exec(&db, "INSERT INTO dictionaries(id,title,revision) VALUES(1,'First','1'),(2,'Second','1'),(3,'Third','1'); INSERT INTO terms(dictionary_id,expression,reading,definition,rules) VALUES(1,'word','','first',''),(2,'word','','second',''),(3,'word','','third','')");
            try db.setPriority(2, 0);
            {
                var list = try db.dictionaries();
                defer freeDictionaries(&list);
                try std.testing.expectEqualStrings("Third", list.items[0].title);
                try std.testing.expectEqualStrings("First", list.items[1].title);
                try std.testing.expectEqualStrings("Second", list.items[2].title);
                var matches = try db.lookup("word");
                defer {
                    for (matches.items) |result| result.deinit();
                    matches.deinit(a);
                }
                try std.testing.expectEqualStrings("Third", matches.items[0].dictionary);
            }
            try db.setPriority(0, 2);
            try private.exec(&db, "DELETE FROM terms WHERE dictionary_id=2; DELETE FROM dictionaries WHERE id=2; INSERT INTO dictionaries(id,title,revision) VALUES(4,'Second','2')");
            var list = try db.dictionaries();
            defer freeDictionaries(&list);
            try std.testing.expectEqualStrings("First", list.items[0].title);
            try std.testing.expectEqualStrings("Second", list.items[1].title);
            try std.testing.expectEqualStrings("Third", list.items[2].title);
            try std.testing.expectError(error.InvalidDictionaryPriority, db.setPriority(0, 5));
        }

        test "dictionary enabled state survives closing and reopening SQLite" {
            var temp = std.testing.tmpDir(.{});
            defer temp.cleanup();
            const path = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}/dictionary.sqlite3", .{temp.sub_path}, 0);
            defer a.free(path);
            {
                var db = try Database.open(path);
                defer db.close();
                try private.exec(&db, "INSERT INTO dictionaries(id,title,revision) VALUES(1,'Saved','1')");
                try db.setEnabled("Saved", false);
            }
            var reopened = try Database.open(path);
            defer reopened.close();
            var list = try reopened.dictionaries();
            defer freeDictionaries(&list);
            try std.testing.expect(!list.items[0].enabled);
            try reopened.setEnabled("Saved", true);
            var enabled = try reopened.dictionaries();
            defer freeDictionaries(&enabled);
            try std.testing.expect(enabled.items[0].enabled);
        }

        test "disabled dictionaries keep ranks and are excluded from lookups and word scans" {
            var db = try Database.open(":memory:");
            defer db.close();
            try private.exec(&db, "INSERT INTO dictionaries(id,title,revision) VALUES(1,'First','1'),(2,'Second','1'); INSERT INTO terms(dictionary_id,expression,reading,definition,rules) VALUES(1,'猫舌','','long',''),(1,'猫','','first',''),(2,'猫','','second','')");
            try db.setPriority(0, 0);
            try std.testing.expectEqual(@as(?usize, "猫舌".len), try db.scanWord("猫舌", 0));
            try db.setEnabled("First", false);
            {
                var list = try db.dictionaries();
                defer freeDictionaries(&list);
                try std.testing.expectEqualStrings("First", list.items[0].title);
                try std.testing.expect(!list.items[0].enabled);
                try std.testing.expect(list.items[1].enabled);
                var matches = try db.lookup("猫");
                defer {
                    for (matches.items) |result| result.deinit();
                    matches.deinit(a);
                }
                try std.testing.expectEqual(@as(usize, 1), matches.items.len);
                try std.testing.expectEqualStrings("Second", matches.items[0].dictionary);
                try std.testing.expectEqual(@as(?usize, "猫".len), try db.scanWord("猫舌", 0));
            }
            try db.setEnabled("Second", false);
            var popup = try db.lookupPopup("猫舌");
            defer {
                for (popup.results.items) |result| result.deinit();
                popup.results.deinit(a);
            }
            try std.testing.expectEqual(@as(usize, 0), popup.results.items.len);
            try std.testing.expectEqual(@as(?usize, null), try db.scanWord("猫舌", 0));
            try db.setPriority(0, 1);
            // ZIP replacement creates a new dictionary ID; title-based preferences remain.
            try private.exec(&db, "DELETE FROM terms WHERE dictionary_id=1; DELETE FROM dictionaries WHERE id=1; INSERT INTO dictionaries(id,title,revision) VALUES(3,'First','2'); INSERT INTO terms(dictionary_id,expression,reading,definition,rules) VALUES(3,'猫舌','','replacement','')");
            try std.testing.expectEqual(@as(?usize, null), try db.scanWord("猫舌", 0));
            try db.setEnabled("First", true);
            var list = try db.dictionaries();
            defer freeDictionaries(&list);
            try std.testing.expectEqualStrings("First", list.items[1].title);
            try std.testing.expect(list.items[1].enabled);
            try std.testing.expectEqual(@as(?usize, "猫舌".len), try db.scanWord("猫舌", 0));
        }

        test "image-only headwords are retained alongside searchable entries" {
            var db = try Database.open(":memory:");
            defer db.close();
            const report = try db.importZip(@embedFile("../../../testdata/dictionary-image-headword.zip"));
            defer a.free(report.title);
            try std.testing.expectEqual(@as(usize, 3), report.entries);
            for ([_][]const u8{ "word", "reading-only" }) |query| {
                var matches = try db.lookup(query);
                defer {
                    for (matches.items) |result| result.deinit();
                    matches.deinit(a);
                }
                try std.testing.expectEqual(@as(usize, 1), matches.items.len);
            }
        }

        test "dictionary media and structured content survive import and source upgrade" {
            var db = try Database.open(":memory:");
            defer db.close();
            const report = try db.importZip(@embedFile("../../../testdata/dictionary-image-headword.zip"));
            defer a.free(report.title);
            try db.recordSource("images.zip", report.title, "same-zip");
            try std.testing.expect(try db.sourceUnchanged("images.zip", "same-zip"));
            var matches = try db.lookup("word");
            defer {
                for (matches.items) |result| result.deinit();
                matches.deinit(a);
            }
            const result = matches.items[0];
            try std.testing.expect(result.glossary != null);
            try std.testing.expect(std.mem.indexOf(u8, result.glossary.?, "glyph.svg") != null);
            const png = (try db.media(result.dictionary_id, "picture.png")).?;
            defer a.free(png);
            try std.testing.expectEqualSlices(u8, @embedFile("../../../testdata/background-test.png"), png);
            const svg = (try db.media(result.dictionary_id, "glyph.svg")).?;
            defer a.free(svg);
            try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
            try std.testing.expect((try db.media(result.dictionary_id + 1, "picture.png")) == null);
            try private.exec(&db, "UPDATE dictionary_import_state SET version=1");
            try std.testing.expect(!try db.sourceUnchanged("images.zip", "same-zip"));
        }

        test "longest word scan and deinflected lookup share conjugation rules" {
            var db = try Database.open(":memory:");
            defer db.close();
            try private.exec(&db, "INSERT INTO dictionaries(id,title,revision) VALUES(1,'Tagged','1'),(2,'Native','1'); INSERT INTO terms(dictionary_id,expression,reading,definition,rules) VALUES(1,'文','','text','n'),(1,'文字','','characters','n'),(1,'食べる','','eat','v1'),(1,'書く','','write','v5'),(1,'高い','','high','adj-i'),(1,'偽る','','wrong conjugation metadata','n'),(2,'読む','','read',''),(2,'勉強','','study',''),(2,'食べる','','native eat','')");
            const examples = [_][2][]const u8{
                .{ "食べました", "食べる" },
                .{ "食べさせられませんでした", "食べる" },
                .{ "書いている", "書く" },
                .{ "高くなかった", "高い" },
                .{ "読んでいました", "読む" },
                .{ "勉強しました", "勉強" },
            };
            for (examples) |example| {
                var matches = try db.lookup(example[0]);
                defer {
                    for (matches.items) |result| result.deinit();
                    matches.deinit(a);
                }
                try std.testing.expect(matches.items.len > 0);
                try std.testing.expectEqualStrings(example[1], matches.items[0].term);
                try std.testing.expect(matches.items[0].deinflection != null);
                const source = try std.fmt.allocPrint(a, "{s}。次", .{example[0]});
                defer a.free(source);
                try std.testing.expectEqual(@as(?usize, example[0].len), try db.scanWord(source, 0));
            }
            try std.testing.expectEqual(@as(?usize, "文字".len), try db.scanWord("文字を読む", 0));
            try std.testing.expectEqual(@as(?usize, "文".len), try db.scanWord("文\n字", 0));
            try std.testing.expectEqual(@as(?usize, null), try db.scanWord("文字", 1));
            var invalid = try db.lookup("偽りました");
            defer {
                for (invalid.items) |result| result.deinit();
                invalid.deinit(a);
            }
            try std.testing.expectEqual(@as(usize, 0), invalid.items.len);
            try db.setPriority(1, 0);
            var ordered = try db.lookup("食べられました");
            defer {
                for (ordered.items) |result| result.deinit();
                ordered.deinit(a);
            }
            try std.testing.expectEqual(@as(usize, 2), ordered.items.len);
            try std.testing.expectEqualStrings("Native", ordered.items[0].dictionary);
            try std.testing.expectEqualStrings("Tagged", ordered.items[1].dictionary);
        }

        test "popup groups full words before their starting kanji and removes overlaps" {
            var db = try Database.open(":memory:");
            defer db.close();
            try private.exec(&db, "INSERT INTO dictionaries(id,title,revision) VALUES(1,'First','1'),(2,'Second','1'); INSERT INTO terms(dictionary_id,expression,reading,definition,rules) VALUES(1,'文字','','word first',''),(2,'文','','character second',''),(1,'文','','character first',''),(2,'文字','','word second',''),(1,'かな','','kana word',''),(1,'か','','kana character','')");
            try db.setPriority(1, 0);
            const queries = [_][]const u8{ "文字", "文でした", "文", "かな", "文不存在" };
            const expected_words = [_]usize{ 2, 2, 2, 1, 0 };
            const expected_counts = [_]usize{ 4, 2, 2, 1, 2 };
            for (queries, expected_words, expected_counts) |query, word_count, total| {
                var popup = try db.lookupPopup(query);
                defer {
                    for (popup.results.items) |result| result.deinit();
                    popup.results.deinit(a);
                }
                try std.testing.expectEqual(word_count, popup.word_count);
                try std.testing.expectEqual(total, popup.results.items.len);
                if (std.mem.eql(u8, query, "文字")) {
                    try std.testing.expectEqualStrings("文字", popup.results.items[0].term);
                    try std.testing.expectEqualStrings("文字", popup.results.items[1].term);
                    try std.testing.expectEqualStrings("文", popup.results.items[2].term);
                    try std.testing.expectEqualStrings("文", popup.results.items[3].term);
                    try std.testing.expectEqualStrings("Second", popup.results.items[0].dictionary);
                    try std.testing.expectEqualStrings("First", popup.results.items[1].dictionary);
                    try std.testing.expectEqualStrings("Second", popup.results.items[2].dictionary);
                }
            }
        }

        test "dropped dictionaries survive folder reconciliation without their original archive" {
            var db = try Database.open(":memory:");
            defer db.close();
            const report = try db.importDroppedZip(@embedFile("../../../testdata/dictionary-valid.zip"));
            defer a.free(report.title);
            try db.reconcileSources(&.{});
            var counts = try db.counts();
            try std.testing.expectEqual(@as(usize, 1), counts.dictionaries);
            try std.testing.expectEqual(@as(usize, 3), counts.terms);
            try std.testing.expectError(error.InvalidTermEntry, db.importDroppedZip(@embedFile("../../../testdata/dictionary-invalid.zip")));
            try db.reconcileSources(&.{});
            counts = try db.counts();
            try std.testing.expectEqual(@as(usize, 3), counts.terms);
        }
    };
}
