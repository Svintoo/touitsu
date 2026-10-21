//! Explicit live check: fetch a sample Jisho recording without playing sound.
const std = @import("std");
const jisho = @import("jisho_audio.zig");
const a = std.heap.smp_allocator;
extern fn touitsu_pronunciation_get([*:0]const u16, *?[*]u8, *usize) c_int;
extern fn touitsu_pronunciation_free([*]u8) void;

fn get(url: []const u8) ![]u8 {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, url);
    defer a.free(wide);
    var ptr: ?[*]u8 = null;
    var len: usize = 0;
    const code = touitsu_pronunciation_get(wide, &ptr, &len);
    if (code != 0) {
        std.debug.print("Jisho request failed: {d} (1=URL, 2=connection/timeout, 3=HTTP status, 4=size)\n", .{code});
        return error.RequestFailed;
    }
    defer touitsu_pronunciation_free(ptr.?);
    return a.dupe(u8, ptr.?[0..len]);
}

pub fn main(_: std.process.Init) !void {
    const html = try get("https://jisho.org/search/%E7%8C%AB");
    defer a.free(html);
    const url = try jisho.audioUrl(a, html, "猫", "ねこ");
    defer a.free(url);
    const audio = try get(url);
    defer a.free(audio);
    if (audio.len < 3 or !(std.mem.startsWith(u8, audio, "ID3") or (audio[0] == 0xff and audio[1] & 0xe0 == 0xe0))) return error.NotMp3;
    std.debug.print("Jisho exact-reading lookup and MP3 download passed ({d} bytes). No sound played.\n", .{audio.len});
}
