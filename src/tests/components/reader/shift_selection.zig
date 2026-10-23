//! Tests for components/reader/shift_selection.zig.
const subject = @import("../../../components/reader/shift_selection.zig");

pub fn Tests(comptime private: anytype) type {
    return struct {
        const std = @import("std");
        const Range = subject.Range;
        const Entry = subject.Entry;
        const Self = subject;
        const hitGlyph = private.hitGlyph;

        test "multiline range copies UTF-8 in reading order and retains complete card context" {
            const entries = [_]Entry{
                .{ .id = 30, .line_id = 1, .text = "最初の行" },
                .{ .id = 10, .line_id = 2, .text = "真ん中" },
                .{ .id = 20, .line_id = 3, .text = "最後の行" },
            };
            var selection: Self = .{ .document = &entries };
            selection.extend(30, .{ .lo = 6, .hi = 9 });
            selection.extend(20, .{ .lo = 0, .hi = 3 });
            try std.testing.expectEqual(Range{ .lo = 6, .hi = 12 }, selection.rangeFor(30, 12).?);
            try std.testing.expectEqual(Range{ .lo = 0, .hi = 9 }, selection.rangeFor(10, 9).?);
            try std.testing.expectEqual(Range{ .lo = 0, .hi = 3 }, selection.rangeFor(20, 12).?);
            const selected = try selection.collect(std.testing.allocator, false);
            defer std.testing.allocator.free(selected);
            try std.testing.expectEqualStrings("の行\n真ん中\n最", selected);
            const context = try selection.collect(std.testing.allocator, true);
            defer std.testing.allocator.free(context);
            try std.testing.expectEqualStrings("最初の行\n真ん中\n最後の行", context);
            private.clear(&selection);
            selection.extend(20, .{ .lo = 0, .hi = 3 });
            selection.extend(30, .{ .lo = 6, .hi = 9 });
            const reverse = try selection.collect(std.testing.allocator, false);
            defer std.testing.allocator.free(reverse);
            try std.testing.expectEqualStrings(selected, reverse);
        }

        test "Shift gesture extends forward and backward and restarts after release" {
            var selection: Self = .{};
            selection.extend(1, .{ .lo = 3, .hi = 6 });
            try std.testing.expectEqual(Range{ .lo = 3, .hi = 6 }, selection.selected);
            selection.extend(1, .{ .lo = 9, .hi = 12 });
            try std.testing.expectEqual(Range{ .lo = 3, .hi = 12 }, selection.selected);
            selection.extend(1, .{ .lo = 0, .hi = 3 });
            try std.testing.expectEqual(Range{ .lo = 0, .hi = 6 }, selection.selected);
            selection.extending = false;
            selection.extend(1, .{ .lo = 6, .hi = 9 });
            try std.testing.expectEqual(Range{ .lo = 6, .hi = 9 }, selection.selected);
            selection.extend(2, .{ .lo = 0, .hi = 3 });
            try std.testing.expectEqual(Range{ .lo = 0, .hi = 3 }, selection.selected);
        }

        test "word expansion uses source bytes and whole-line selection takes precedence" {
            const Fake = struct {
                calls: usize = 0,
                fn lookup(pointer: *anyopaque, _: []const u8, start: usize) anyerror!?usize {
                    const self: *@This() = @ptrCast(@alignCast(pointer));
                    self.calls += 1;
                    return if (start == 0) 6 else null;
                }
            };
            var fake: Fake = .{};
            var selection: Self = .{ .word_selection = true, .scanner = .{ .context = &fake, .lookup = Fake.lookup } };
            selection.selectHit(7, "文字です", .{ .lo = 0, .hi = 3 });
            try std.testing.expectEqual(Range{ .lo = 0, .hi = 6 }, selection.selected);
            selection.selectHit(7, "文字です", .{ .lo = 6, .hi = 9 });
            try std.testing.expectEqual(Range{ .lo = 6, .hi = 9 }, selection.selected);
            selection.whole_line = true;
            selection.selectHit(7, "文字です", .{ .lo = 0, .hi = 3 });
            try std.testing.expectEqual(Range{ .lo = 0, .hi = 12 }, selection.selected);
            try std.testing.expectEqual(@as(usize, 2), fake.calls);
            selection.whole_line = false;
            selection.word_selection = false;
            selection.extending = false;
            selection.selectHit(7, "文字です", .{ .lo = 0, .hi = 3 });
            selection.selectHit(7, "文字です", .{ .lo = 3, .hi = 6 });
            try std.testing.expectEqual(Range{ .lo = 0, .hi = 6 }, selection.selected);
        }

        test "glyph hit testing preserves UTF-8 clusters on wrapped lines and rejects trailing space" {
            const Glyph = struct { x: f32, advance: f32, cluster: u32 };
            const glyphs = [_]Glyph{ .{ .x = 0, .advance = 20, .cluster = 0 }, .{ .x = 20, .advance = 20, .cluster = 3 } };
            try std.testing.expectEqual(Range{ .lo = 6, .hi = 9 }, hitGlyph(&glyphs, 6, 12, 10).?);
            try std.testing.expectEqual(Range{ .lo = 9, .hi = 12 }, hitGlyph(&glyphs, 6, 12, 25).?);
            try std.testing.expect(hitGlyph(&glyphs, 6, 12, 41) == null);
            try std.testing.expect(hitGlyph(&glyphs, 6, 12, -1) == null);
        }
    };
}
