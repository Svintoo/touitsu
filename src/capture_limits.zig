//! Bounds for untrusted hook output and the reader's per-frame UI workload.
const std = @import("std");
pub const sample_bytes = 8192;
pub const page_chars = 512;
pub const page_lines = 48;

pub fn prefix(text: []const u8, max_chars: usize) []const u8 {
    var iter = (std.unicode.Utf8View.init(text) catch return "\xef\xbf\xbd").iterator();
    var end: usize = 0;
    var count: usize = 0;
    while (count < max_chars) : (count += 1) {
        const bytes = iter.nextCodepointSlice() orelse break;
        end += bytes.len;
    }
    return text[0..end];
}

pub const FloodGuard = struct {
    since_ms: ?i64 = null,
    bytes: usize = 0,
    events: usize = 0,
    blocked: bool = false,

    pub fn accept(self: *FloodGuard, now_ms: i64, size: usize) bool {
        if (self.blocked) return false;
        if (self.since_ms == null or now_ms - self.since_ms.? >= 1000 or now_ms < self.since_ms.?) {
            self.since_ms = now_ms;
            self.bytes = 0;
            self.events = 0;
        }
        if (size > sample_bytes or self.bytes + size > 32768 or self.events >= 40) {
            self.blocked = true;
            return false;
        }
        self.bytes += size;
        self.events += 1;
        return true;
    }
};

test "flood limits stop oversized and sustained hook output" {
    var guard: FloodGuard = .{};
    try std.testing.expect(!guard.accept(0, sample_bytes + 1));
    guard = .{};
    for (0..40) |_| try std.testing.expect(guard.accept(0, 5));
    try std.testing.expect(!guard.accept(0, 5));
    try std.testing.expect(!guard.accept(2000, 5));
    guard = .{};
    for (0..4) |_| try std.testing.expect(guard.accept(0, sample_bytes));
    try std.testing.expect(!guard.accept(0, 1));
    guard = .{};
    for (0..100) |i| try std.testing.expect(guard.accept(@intCast(i * 1000), 100));
}

test "character budget respects UTF-8 boundaries" {
    try std.testing.expectEqualStrings("a\xe3\x81\x82", prefix("a\xe3\x81\x82b", 2));
}
