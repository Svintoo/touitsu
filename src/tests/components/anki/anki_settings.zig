//! Tests for components/anki/anki_settings.zig.
const subject = @import("../../../components/anki/anki_settings.zig");

pub fn Tests(comptime private: anytype) type {
    return struct {
        const std = @import("std");
        const a = std.heap.smp_allocator;
        const Self = subject;
        const Saved = private.Saved;
        const Strings = private.Strings;
        const audio_marker = private.audio_marker;
        const Job = private.Job;

        test "dropdown labels survive releasing their configuration owner during a frame" {
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            var choices: Strings = .{};
            const parsed = try std.json.parseFromSlice(std.json.Value, a, "[\"Basic\",\"日本語\"]", .{});
            defer parsed.deinit();
            try private.readStrings(&choices, parsed.value);
            const labels = try private.snapshotStrings(&choices, arena.allocator());
            private.deinitStrings(&choices);
            try std.testing.expectEqualStrings("Basic", labels[0]);
            try std.testing.expectEqualStrings("日本語", labels[1]);
            try std.testing.expect(std.unicode.utf8ValidateSlice(labels[1]));
        }

        test "field validation requires templates and a valid selected note type" {
            var self: Self = .{ .gpa = std.testing.allocator };
            defer self.deinit();
            try private.apply(&self, .{});
            const parsed = try std.json.parseFromSlice(std.json.Value, a, "[\"Default\",\"Basic\",\"Front\",\"Back\"]", .{});
            defer parsed.deinit();
            try private.readStrings(&self.decks, parsed.value);
            try private.readStrings(&self.models, parsed.value);
            try private.readStrings(&self.fields, parsed.value);
            try private.ensureFormatting(&self);
            try std.testing.expect(private.valid(&self));
            try private.set(&self, &self.format_fields.items[0].template, "{unknown}");
            try std.testing.expect(!private.valid(&self));
            try private.set(&self, &self.format_fields.items[0].template, "{expression}");
            try private.set(&self, &self.deck, "Missing");
            try std.testing.expect(!private.valid(&self));
        }

        test "added note identity follows Anki collection and selected word" {
            var self: Self = .{ .gpa = std.testing.allocator };
            defer self.deinit();
            try private.apply(&self, .{});
            const first = try private.entryKey(&self, "日本", "にほん", 1, 1, "Japan");
            defer a.free(first);
            const same = try private.entryKey(&self, "日本", "にほん", 1, 1, "Japan");
            defer a.free(same);
            try std.testing.expectEqualStrings(first, same);
            try private.set(&self, &self.endpoint, "http://127.0.0.1:9876");
            const other = try private.entryKey(&self, "日本", "にほん", 1, 1, "Japan");
            defer a.free(other);
            try std.testing.expect(!std.mem.eql(u8, first, other));
        }

        test "entries with the same spelling have independent Anki identity" {
            var self: Self = .{ .gpa = std.testing.allocator };
            defer self.deinit();
            try private.apply(&self, .{});
            const first = try private.entryKey(&self, "word", "reading", 1, 1, "first definition");
            defer a.free(first);
            const second = try private.entryKey(&self, "word", "reading", 1, 2, "second definition");
            defer a.free(second);
            const other_dictionary = try private.entryKey(&self, "word", "reading", 2, 1, "first definition");
            defer a.free(other_dictionary);
            try std.testing.expect(!std.mem.eql(u8, first, second));
            try std.testing.expect(!std.mem.eql(u8, first, other_dictionary));
        }

        test "card formatting survives save and restores per-model templates without overwriting edits" {
            var self: Self = .{ .gpa = std.testing.allocator };
            defer self.deinit();
            try private.apply(&self, .{ .model = "Mining", .formatting = &.{
                .{ .model = "Mining", .field = "Reading", .template = "<b>{reading}</b>" },
                .{ .model = "Other", .field = "Front", .template = "{expression}" },
                .{ .model = "Mining", .field = "Deleted field", .template = "old" },
            } });
            const fields = try std.json.parseFromSlice(std.json.Value, a, "[\"Reading\",\"Glossary\",\"Audio\",\"Sentence\",\"Hint\"]", .{});
            defer fields.deinit();
            try private.readStrings(&self.fields, fields.value);
            try private.ensureFormatting(&self);
            try std.testing.expectEqualStrings("<b>{reading}</b>", self.format_fields.items[0].template.items);
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const active = try private.activeMappings(&self, arena.allocator());
            try std.testing.expectEqual(@as(usize, 5), active.len);
            const encoded = try std.json.Stringify.valueAlloc(a, try private.config(&self, arena.allocator()), .{});
            defer a.free(encoded);
            const saved = try std.json.parseFromSlice(Saved, a, encoded, .{});
            defer saved.deinit();
            var restored: Self = .{ .gpa = std.testing.allocator };
            defer restored.deinit();
            try private.apply(&restored, saved.value);
            try std.testing.expectEqualStrings("<b>{reading}</b>", restored.format_fields.items[0].template.items);
            try std.testing.expectEqualStrings("Other", restored.format_fields.items[1].model);
        }

        test "offline card audio markers are removed without leaving a broken sound link" {
            var job: Job = .{ .kind = .add, .revision = 0, .endpoint = try a.dupe(u8, ""), .api_key = try a.dupe(u8, ""), .model = try a.dupe(u8, "") };
            defer {
                a.free(job.endpoint);
                a.free(job.api_key);
                a.free(job.model);
                if (job.body) |body| a.free(body);
            }
            job.body = try std.fmt.allocPrint(a, "{{\"Audio\":\"{s}\"}}", .{audio_marker});
            try private.attachJobAudio(&job);
            try std.testing.expectEqualStrings("{\"Audio\":\"\"}", job.body.?);
        }
    };
}
