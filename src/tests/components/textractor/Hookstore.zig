//! Tests for components/textractor/Hookstore.zig.
const subject = @import("../../../components/textractor/Hookstore.zig");

const std = @import("std");
const Store = subject.Store;

pub fn Tests(comptime private: anytype) type {
    return struct {
        test "parses a real Textractor savedHooks.txt line" {
            const a = std.testing.allocator;
            var s: Store = .{ .alloc = a, .path = undefined };
            defer {
                for (s.entries.items) |*e| private.deinitEntry(e, a);
                s.entries.deinit(a);
            }
            const exe = "D:\\XDfolder\\Nukitashi\\[240628] [Qruppo] 抜きゲーみたいな島に住んでる貧乳（わたし）はどうすりゃいいですか？ 1＋2 Remaster + Append + Drama CD\\Nuki1\\Game\\NUKITASHI.exe";
            try s.parseLine(exe ++ " , HS65001#-3C@193BA0:NUKITASHI.exe , |5369546549:0:HS65001#-3C@193BA0:NUKITASHI.exe\r");
            try std.testing.expectEqual(@as(usize, 1), s.entries.items.len);
            const e = s.find(exe).?;
            try std.testing.expectEqual(@as(usize, 1), e.codes.items.len);
            try std.testing.expectEqualStrings("HS65001#-3C@193BA0:NUKITASHI.exe", e.codes.items[0]);
            try std.testing.expectEqual(@as(u64, 5369546549), e.sel.?.ctx);
            try std.testing.expectEqual(@as(u64, 0), e.sel.?.ctx2);
            try std.testing.expectEqualStrings("HS65001#-3C@193BA0:NUKITASHI.exe", e.sel.?.code);
        }

        test "addCode dedupes and forget removes" {
            const a = std.testing.allocator;
            var s: Store = .{ .alloc = a, .path = undefined };
            defer {
                for (s.entries.items) |*e| private.deinitEntry(e, a);
                s.entries.deinit(a);
            }
            try s.addCode("C:\\g\\a.exe", "HS-4@0");
            try s.addCode("c:\\g\\A.EXE", "HS-4@0"); // same game, different case
            try s.addCode("C:\\g\\a.exe", "HQ0@1");
            try std.testing.expectEqual(@as(usize, 1), s.entries.items.len);
            try std.testing.expectEqual(@as(usize, 2), s.find("C:\\g\\a.exe").?.codes.items.len);
            s.forget("C:\\G\\A.exe");
            try std.testing.expectEqual(@as(usize, 0), s.entries.items.len);
        }

        test "hook post-processing round trips and does not duplicate saved hooks" {
            const a = std.testing.allocator;
            var store: Store = .{ .alloc = a, .path = try a.allocSentinel(u16, 0, 0) };
            defer store.deinit();
            const line = "C:\\game.exe , HS0@1234 , |7:8:HS0@1234 , |pairs:HS0@1234";
            try store.parseLine(line);
            try store.parseLine(line);
            const entry = store.find("c:\\GAME.exe").?;
            try std.testing.expectEqual(@as(usize, 1), entry.codes.items.len);
            try std.testing.expectEqual(@as(usize, 1), entry.doubled.items.len);
            try std.testing.expect(store.reducesPairs("C:\\game.exe", "HS0@1234"));
            try std.testing.expect(!store.reducesPairs("C:\\other.exe", "HS0@1234"));
            try std.testing.expect(!store.reducesPairs("C:\\game.exe", "HS0@9999"));
            store.removeCode("C:\\game.exe", entry.codes.items[0]);
            try std.testing.expectEqual(@as(usize, 0), entry.codes.items.len);
            try std.testing.expectEqual(@as(usize, 0), entry.doubled.items.len);
            try std.testing.expect(entry.sel == null);
        }
    };
}
