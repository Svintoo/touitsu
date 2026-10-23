//! Tests for components/textractor/textractor.zig.
const subject = @import("../../../components/textractor/textractor.zig");

pub fn Tests(comptime private: anytype) type {
    return struct {
        const std = @import("std");
        const Event = subject.Event;
        const Client = subject.Client;

        test "hook history preview queue remains bounded under callback flood" {
            var client = Client.init(std.testing.allocator);
            defer {
                for (client.queue.items) |*event| event.deinit(client.alloc);
                client.queue.deinit(client.alloc);
            }
            for (0..2000) |_| {
                const code = try client.alloc.dupe(u8, "HS0@1234");
                const text = try client.alloc.dupe(u8, "noisy sample");
                private.push(&client, .{ .hook_found = .{ .pid = 1, .code = code, .text = text } });
            }
            try std.testing.expectEqual(@as(usize, 768), client.queue.items.len);
            private.push(&client, .{ .disconnected = 1 });
            try std.testing.expectEqual(@as(usize, 769), client.queue.items.len);
            for (0..2000) |_| private.push(&client, .{ .connected = 1 });
            try std.testing.expectEqual(@as(usize, 1024), client.queue.items.len);
        }

        test "hook history preview clipboard notifications are deduplicated without dropping deliberate repeated copies" {
            var client = Client.init(std.testing.allocator);
            defer {
                for (client.queue.items) |*event| event.deinit(client.alloc);
                client.queue.deinit(client.alloc);
            }
            const Source = struct {
                fn event(name: []const u8, text: []const u8) !Event {
                    return .{ .text = .{ .meta = .{ .pid = 0, .handle = 2, .addr = 0, .ctx = 0, .ctx2 = 0, .name = try std.testing.allocator.dupe(u8, name), .hook_code = try std.testing.allocator.dupe(u8, "") }, .text = try std.testing.allocator.dupe(u8, text) } };
                }
            };
            private.pushSequenced(&client, try Source.event("Clipboard", "copied line"), 10);
            private.pushSequenced(&client, try Source.event("Clipboard", "copied line"), 10);
            try std.testing.expectEqual(@as(usize, 1), client.queue.items.len);
            // A separate copy of the same sentence is a legitimate new reader entry.
            private.pushSequenced(&client, try Source.event("Clipboard", "copied line"), 11);
            try std.testing.expectEqual(@as(usize, 2), client.queue.items.len);
            // Changed content is preserved even if the clipboard changes during callbacks.
            private.pushSequenced(&client, try Source.event("Clipboard", "different line"), 11);
            try std.testing.expectEqual(@as(usize, 3), client.queue.items.len);
            // Never deduplicate game hooks or Console output, or assume sequence zero is valid.
            private.pushSequenced(&client, try Source.event("Console", "message"), 11);
            private.pushSequenced(&client, try Source.event("Console", "message"), 11);
            private.pushSequenced(&client, try Source.event("Clipboard", "copied line"), 0);
            private.pushSequenced(&client, try Source.event("Clipboard", "copied line"), 0);
            try std.testing.expectEqual(@as(usize, 7), client.queue.items.len);
        }
    };
}
