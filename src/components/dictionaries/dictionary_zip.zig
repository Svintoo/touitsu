//! In-memory ZIP reader for Yomitan JSON banks. Never extracts archive paths to disk.
const std = @import("std");
const Allocator = std.mem.Allocator;
pub const max_bank_bytes = 128 * 1024 * 1024;

fn range(bytes: []const u8, offset: usize, len: usize) ![]const u8 {
    if (offset > bytes.len or len > bytes.len - offset) return error.InvalidZip;
    return bytes[offset..][0..len];
}
fn int(comptime T: type, bytes: []const u8, offset: usize) !T {
    return std.mem.readInt(T, (try range(bytes, offset, @sizeOf(T)))[0..@sizeOf(T)], .little);
}

pub const Entry = struct {
    name: []const u8,
    method: u16,
    crc: u32,
    compressed: []const u8,
    size: usize,

    pub fn read(self: Entry, a: Allocator) ![]u8 {
        if (self.size > max_bank_bytes) return error.DictionaryBankTooLarge;
        const out = try a.alloc(u8, self.size);
        errdefer a.free(out);
        switch (self.method) {
            0 => {
                if (self.compressed.len != out.len) return error.InvalidZip;
                @memcpy(out, self.compressed);
            },
            8 => {
                var input = std.Io.Reader.fixed(self.compressed);
                var window: [std.compress.flate.max_window_len]u8 = undefined;
                var inflater: std.compress.flate.Decompress = .init(&input, .raw, &window);
                inflater.reader.readSliceAll(out) catch return error.InvalidZipCompression;
                var extra: [1]u8 = undefined;
                const n = inflater.reader.readSliceShort(&extra) catch return error.InvalidZipCompression;
                if (n != 0) return error.InvalidZip;
            },
            else => return error.UnsupportedZipCompression,
        }
        if (std.hash.Crc32.hash(out) != self.crc) return error.ZipChecksumMismatch;
        return out;
    }
};

pub const Archive = struct {
    bytes: []const u8,
    position: usize,
    remaining: usize,
    directory_end: usize,

    pub fn init(bytes: []const u8) !Archive {
        if (bytes.len < 22) return error.InvalidZip;
        var pos = bytes.len - 22;
        const lower = bytes.len -| (65535 + 22);
        while (true) : (pos -= 1) {
            if (try int(u32, bytes, pos) == 0x06054b50 and pos + 22 + try int(u16, bytes, pos + 20) == bytes.len) break;
            if (pos == lower) return error.InvalidZip;
        }
        const count = try int(u16, bytes, pos + 10);
        const start = try int(u32, bytes, pos + 16);
        const size = try int(u32, bytes, pos + 12);
        if (count == 0xffff or start == 0xffffffff or size == 0xffffffff) return error.Zip64NotSupported;
        if (try int(u16, bytes, pos + 4) != 0 or try int(u16, bytes, pos + 6) != 0 or try int(u16, bytes, pos + 8) != count) return error.MultiDiskZipNotSupported;
        _ = try range(bytes, start, size);
        if (@as(u64, start) + size > pos) return error.InvalidZip;
        return .{ .bytes = bytes, .position = start, .remaining = count, .directory_end = @as(usize, start) + size };
    }

    pub fn next(self: *Archive) !?Entry {
        if (self.remaining == 0) return null;
        const pos = self.position;
        const b = self.bytes;
        if (try int(u32, b, pos) != 0x02014b50) return error.InvalidZip;
        const flags = try int(u16, b, pos + 8);
        if (flags & 1 != 0) return error.EncryptedZipNotSupported;
        const method = try int(u16, b, pos + 10);
        const size = try int(u32, b, pos + 24);
        const compressed_size = try int(u32, b, pos + 20);
        const name_len = try int(u16, b, pos + 28);
        const extra_len = try int(u16, b, pos + 30);
        const comment_len = try int(u16, b, pos + 32);
        const local = try int(u32, b, pos + 42);
        if (size == 0xffffffff or compressed_size == 0xffffffff or local == 0xffffffff) return error.Zip64NotSupported;
        if (try int(u16, b, pos + 34) != 0) return error.MultiDiskZipNotSupported;
        const name = try range(b, pos + 46, name_len);
        const end = pos + 46 + @as(usize, name_len) + extra_len + comment_len;
        if (end > self.directory_end) return error.InvalidZip;
        if (try int(u32, b, local) != 0x04034b50) return error.InvalidZip;
        const data_pos = @as(usize, local) + 30 + try int(u16, b, local + 26) + try int(u16, b, local + 28);
        const compressed = try range(b, data_pos, compressed_size);
        self.position = end;
        self.remaining -= 1;
        return .{ .name = name, .method = method, .crc = try int(u32, b, pos + 16), .compressed = compressed, .size = size };
    }
};
