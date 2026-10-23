//! Bounds for untrusted hook output and hook preview text.
const std = @import("std");
pub const sample_code_units = 8192;
pub const message_bytes = 64 * 1024;
pub const events_per_second = 1000;
pub const bytes_per_second = 2 * 1024 * 1024;

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
        if (size > message_bytes or self.bytes + size > bytes_per_second or self.events >= events_per_second) {
            self.blocked = true;
            return false;
        }
        self.bytes += size;
        self.events += 1;
        return true;
    }
};

test {
    _ = @import("../../tests/components/textractor/capture_limits.zig");
}
