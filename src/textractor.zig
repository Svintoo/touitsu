//! textractor.zig - Zig wrapper over tx_shim.dll (native x64 host plus automatic x86 helper routing).
//!
//! Written for Zig 0.17 (callconv(.c)/.winapi, unmanaged std.ArrayList).
//!
//! Threading: Textractor invokes callbacks on its own pipe threads. This wrapper
//! copies everything into an owned event queue guarded by a mutex; call `drain`
//! from your UI/main loop each frame.
//!
//! Requirements:
//!  - The allocator you pass MUST be thread-safe (page_allocator, c_allocator,
//!    DebugAllocator/GPA with default thread_safe).
//!  - The Client must not move or be freed after `start` (the shim keeps a pointer to it).
//!    Make it a global or heap allocate it. Textractor's Host has no teardown API, so
//!    treat it as process-lifetime.
//!
//! Usage:
//!   var tx: textractor.Client = .init(std.heap.page_allocator);
//!   tx.start();
//!   tx.attach(pid);
//!   var events: std.ArrayList(textractor.Event) = .empty;
//!   // each frame:
//!   try tx.drain(&events, alloc);
//!   for (events.items) |*ev| { handle(ev); ev.deinit(tx.alloc); }
//!   events.clearRetainingCapacity();

const std = @import("std");

const ThreadInfo = extern struct {
    handle: u64,
    pid: u32,
    addr: u64,
    ctx: u64,
    ctx2: u64,
    name: [*:0]const u16,
    hook_code: [*:0]const u16,
};

test "hook history preview queue remains bounded under callback flood" {
    var client = Client.init(std.testing.allocator);
    defer {
        for (client.queue.items) |*event| event.deinit(client.alloc);
        client.queue.deinit(client.alloc);
    }
    for (0..2000) |_| {
        const code = try client.alloc.dupe(u8, "HS0@1234");
        const text = try client.alloc.dupe(u8, "noisy sample");
        client.push(.{ .hook_found = .{ .pid = 1, .code = code, .text = text } });
    }
    try std.testing.expectEqual(@as(usize, 768), client.queue.items.len);
    client.push(.{ .disconnected = 1 });
    try std.testing.expectEqual(@as(usize, 769), client.queue.items.len);
    for (0..2000) |_| client.push(.{ .connected = 1 });
    try std.testing.expectEqual(@as(usize, 1024), client.queue.items.len);
}

const ProcessCb = *const fn (?*anyopaque, u32) callconv(.c) void;
const ThreadCb = *const fn (?*anyopaque, *const ThreadInfo) callconv(.c) void;
const OutputCb = *const fn (?*anyopaque, *const ThreadInfo, [*]const u16, usize) callconv(.c) void;

// Plain Win32 slim reader/writer lock; avoids depending on std mutex APIs that moved around.
const SRWLOCK = extern struct { ptr: ?*anyopaque = null };
extern "kernel32" fn AcquireSRWLockExclusive(l: *SRWLOCK) callconv(.winapi) void;
extern "kernel32" fn ReleaseSRWLockExclusive(l: *SRWLOCK) callconv(.winapi) void;
extern "kernel32" fn CreateEventW(attrs: ?*anyopaque, manual_reset: i32, initial: i32, name: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn SetEvent(h: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn WaitForSingleObject(h: ?*anyopaque, ms: u32) callconv(.winapi) u32;
extern "user32" fn GetClipboardSequenceNumber() callconv(.winapi) u32;

extern fn tx_start(
    user: ?*anyopaque,
    on_connect: ProcessCb,
    on_disconnect: ProcessCb,
    on_create: ThreadCb,
    on_destroy: ThreadCb,
    on_output: OutputCb,
) callconv(.c) void;
const ErrorCb = *const fn (?*anyopaque, u32, [*:0]const u16) callconv(.c) void;
extern fn tx_set_error_callback(?*anyopaque, ErrorCb) callconv(.c) void;
extern fn tx_probe_x86() callconv(.c) bool;
extern fn tx_attach(pid: u32) callconv(.c) bool;
extern fn tx_detach(pid: u32) callconv(.c) bool;
extern fn tx_shutdown(timeout_ms: u32) callconv(.c) u32;
extern fn tx_insert_hook(pid: u32, code: [*:0]const u16) callconv(.c) bool;
extern fn tx_remove_hook(pid: u32, address: u64) callconv(.c) bool;

const FoundCb = *const fn (?*anyopaque, u32, [*:0]const u16, [*]const u16, usize) callconv(.c) void;
extern fn tx_set_find_callback(user: ?*anyopaque, cb: FoundCb) callconv(.c) void;
extern fn tx_find_hooks(pid: u32, codepage: u32, text: ?[*:0]const u16) callconv(.c) bool;

pub const ThreadMeta = struct {
    handle: u64,
    pid: u32,
    addr: u64,
    ctx: u64,
    ctx2: u64,
    name: []u8,
    hook_code: []u8,

    fn free(self: ThreadMeta, a: std.mem.Allocator) void {
        a.free(self.name);
        a.free(self.hook_code);
    }
};

pub const Event = union(enum) {
    backend_error: struct { pid: u32, message: []u8 },
    connected: u32,
    disconnected: u32,
    thread_created: ThreadMeta,
    thread_destroyed: ThreadMeta,
    text: struct { meta: ThreadMeta, text: []u8 },
    /// A candidate from hook search: `code` is an /H code you can insert, `text` a sample it produced.
    hook_found: struct { pid: u32, code: []u8, text: []u8 },

    pub fn deinit(self: *Event, a: std.mem.Allocator) void {
        switch (self.*) {
            .backend_error => |error_info| a.free(error_info.message),
            .thread_created, .thread_destroyed => |m| m.free(a),
            .text => |t| {
                t.meta.free(a);
                a.free(t.text);
            },
            .hook_found => |h| {
                a.free(h.code);
                a.free(h.text);
            },
            else => {},
        }
    }
};

pub const Client = struct {
    alloc: std.mem.Allocator,
    srw: SRWLOCK = .{},
    /// Auto-reset Win32 event, signalled whenever an event is queued (see `wait`).
    wake: ?*anyopaque = null,
    queue: std.ArrayList(Event) = .empty,
    clipboard_sequence: ?u32 = null,
    clipboard_text_hash: u64 = 0,

    pub fn init(alloc: std.mem.Allocator) Client {
        return .{ .alloc = alloc };
    }

    /// Starts the host. Call once. `self` must have a stable address from here on.
    pub fn start(self: *Client) void {
        self.wake = CreateEventW(null, 0, 0, null);
        tx_set_error_callback(self, cbError);
        tx_start(self, cbConnect, cbDisconnect, cbCreate, cbDestroy, cbOutput);
        tx_set_find_callback(self, cbFound);
    }

    pub fn probe32(_: *Client) bool {
        return tx_probe_x86();
    }

    /// Blocks until an event is queued or `timeout_ms` passes. Safe to call from any thread;
    /// meant for a background task (e.g. Knots' `dispatch`) that wakes the UI.
    pub fn wait(self: *Client, timeout_ms: u32) void {
        if (self.wake) |h| _ = WaitForSingleObject(h, timeout_ms);
    }

    /// Returns false if the host threw (bad/unknown process).
    pub fn attach(_: *Client, pid: u32) bool {
        return tx_attach(pid);
    }

    /// Returns false if the host doesn't know the process (e.g. it already disconnected/crashed).
    pub fn detach(_: *Client, pid: u32) bool {
        return tx_detach(pid);
    }

    /// Detach all live connections and wait for disconnect confirmation. Late
    /// connections are detached too. Returns the number still pending at timeout.
    pub fn shutdown(_: *Client, timeout_ms: u32) u32 {
        return tx_shutdown(timeout_ms);
    }

    /// `code` is a Textractor /H hook code in UTF-8, e.g. "/HS-4@0". Returns false if invalid.
    pub fn insertHook(self: *Client, pid: u32, code: []const u8) !bool {
        const w = try std.unicode.utf8ToUtf16LeAllocZ(self.alloc, code);
        defer self.alloc.free(w);
        return tx_insert_hook(pid, w.ptr);
    }

    pub fn removeHook(_: *Client, pid: u32, address: u64) bool {
        return tx_remove_hook(pid, address);
    }

    /// Starts a hook search in the target. Results arrive as `.hook_found` events while the game
    /// runs (let it display text). `text` null = generic search; otherwise search for that text.
    /// `codepage`: 932 Shift-JIS, 65001 UTF-8, 936 GBK, ...
    pub fn findHooks(self: *Client, pid: u32, codepage: u32, text: ?[]const u8) !bool {
        if (text) |t| {
            const w = try std.unicode.utf8ToUtf16LeAllocZ(self.alloc, t);
            defer self.alloc.free(w);
            return tx_find_hooks(pid, codepage, w.ptr);
        }
        return tx_find_hooks(pid, codepage, null);
    }

    /// Signal the target's named cancellation event (works for either target architecture).
    pub fn stopSearch(_: *Client, pid: u32) void {
        const Api = struct {
            extern "kernel32" fn OpenEventW(u32, i32, [*:0]const u16) callconv(.winapi) ?*anyopaque;
            extern "kernel32" fn CloseHandle(?*anyopaque) callconv(.winapi) i32;
        };
        var name: [96]u8 = undefined;
        const utf8_name = std.fmt.bufPrint(&name, "Local\\TouitsuHookSearchStop.{d}", .{pid}) catch return;
        var wide: [96:0]u16 = @splat(0);
        for (utf8_name, 0..) |c, i| wide[i] = c;
        const event = Api.OpenEventW(2, 0, &wide) orelse return;
        defer _ = Api.CloseHandle(event);
        _ = SetEvent(event);
    }

    /// Moves all pending events into `out` (caller owns them; call `Event.deinit`).
    pub fn drain(self: *Client, out: *std.ArrayList(Event), out_alloc: std.mem.Allocator) !void {
        AcquireSRWLockExclusive(&self.srw);
        defer ReleaseSRWLockExclusive(&self.srw);
        try out.appendSlice(out_alloc, self.queue.items);
        self.queue.clearRetainingCapacity();
    }

    // ---- internals (called from Textractor threads) ----

    fn push(self: *Client, ev: Event) void {
        const sequence = if (ev == .text and ev.text.meta.pid == 0 and std.mem.eql(u8, ev.text.meta.name, "Clipboard")) GetClipboardSequenceNumber() else 0;
        self.pushSequenced(ev, sequence);
    }

    fn pushSequenced(self: *Client, ev: Event, sequence: u32) void {
        AcquireSRWLockExclusive(&self.srw);
        defer ReleaseSRWLockExclusive(&self.srw);
        // The host's initial clipboard read and multiple update notifications can
        // report the same clipboard contents more than once. Keep deliberate
        // copies of identical text: each new clipboard change has a new sequence.
        const clipboard = ev == .text and ev.text.meta.pid == 0 and std.mem.eql(u8, ev.text.meta.name, "Clipboard");
        const text_hash = if (clipboard) std.hash.Wyhash.hash(0, ev.text.text) else 0;
        if (clipboard and sequence != 0 and self.clipboard_sequence == sequence and self.clipboard_text_hash == text_hash) {
            var duplicate = ev;
            duplicate.deinit(self.alloc);
            return;
        }
        // Bound pending callbacks even while the UI is busy. Reserve room for lifecycle events.
        const data_event = ev == .text or ev == .hook_found;
        if (self.queue.items.len >= (if (data_event) @as(usize, 768) else @as(usize, 1024))) {
            var dropped = ev;
            dropped.deinit(self.alloc);
            return;
        }
        self.queue.append(self.alloc, ev) catch {
            var e = ev;
            e.deinit(self.alloc);
            return;
        };
        if (clipboard and sequence != 0) {
            self.clipboard_sequence = sequence;
            self.clipboard_text_hash = text_hash;
        }
        if (self.wake) |h| _ = SetEvent(h);
    }

    fn utf8(self: *Client, w: []const u16) ![]u8 {
        return std.unicode.utf16LeToUtf8Alloc(self.alloc, w);
    }

    fn meta(self: *Client, info: *const ThreadInfo) !ThreadMeta {
        const name = try self.utf8(std.mem.span(info.name));
        errdefer self.alloc.free(name);
        const code = try self.utf8(std.mem.span(info.hook_code));
        return .{
            .handle = info.handle,
            .pid = info.pid,
            .addr = info.addr,
            .ctx = info.ctx,
            .ctx2 = info.ctx2,
            .name = name,
            .hook_code = code,
        };
    }

    fn fromUser(user: ?*anyopaque) *Client {
        return @ptrCast(@alignCast(user.?));
    }

    fn cbError(user: ?*anyopaque, pid: u32, message: [*:0]const u16) callconv(.c) void {
        const self = fromUser(user);
        const copy = self.utf8(std.mem.span(message)) catch return;
        self.push(.{ .backend_error = .{ .pid = pid, .message = copy } });
    }

    fn cbConnect(user: ?*anyopaque, pid: u32) callconv(.c) void {
        fromUser(user).push(.{ .connected = pid });
    }

    fn cbDisconnect(user: ?*anyopaque, pid: u32) callconv(.c) void {
        fromUser(user).push(.{ .disconnected = pid });
    }

    fn cbCreate(user: ?*anyopaque, info: *const ThreadInfo) callconv(.c) void {
        const self = fromUser(user);
        const m = self.meta(info) catch return;
        self.push(.{ .thread_created = m });
    }

    fn cbDestroy(user: ?*anyopaque, info: *const ThreadInfo) callconv(.c) void {
        const self = fromUser(user);
        const m = self.meta(info) catch return;
        self.push(.{ .thread_destroyed = m });
    }

    fn boundedSample(text: []const u16) []const u16 {
        var end = @min(text.len, @import("capture_limits.zig").sample_bytes);
        if (end > 0 and end < text.len and text[end - 1] >= 0xd800 and text[end - 1] <= 0xdbff) end -= 1;
        return text[0..end];
    }

    fn cbFound(user: ?*anyopaque, pid: u32, code: [*:0]const u16, text: [*]const u16, len: usize) callconv(.c) void {
        const self = fromUser(user);
        const c = self.utf8(std.mem.span(code)) catch return;
        const t = self.utf8(boundedSample(text[0..len])) catch {
            self.alloc.free(c);
            return;
        };
        self.push(.{ .hook_found = .{ .pid = pid, .code = c, .text = t } });
    }

    fn cbOutput(user: ?*anyopaque, info: *const ThreadInfo, text: [*]const u16, len: usize) callconv(.c) void {
        const self = fromUser(user);
        const m = self.meta(info) catch return;
        const t = self.utf8(boundedSample(text[0..len])) catch {
            m.free(self.alloc);
            return;
        };
        self.push(.{ .text = .{ .meta = m, .text = t } });
    }
};

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
    client.pushSequenced(try Source.event("Clipboard", "copied line"), 10);
    client.pushSequenced(try Source.event("Clipboard", "copied line"), 10);
    try std.testing.expectEqual(@as(usize, 1), client.queue.items.len);
    // A separate copy of the same sentence is a legitimate new reader entry.
    client.pushSequenced(try Source.event("Clipboard", "copied line"), 11);
    try std.testing.expectEqual(@as(usize, 2), client.queue.items.len);
    // Changed content is preserved even if the clipboard changes during callbacks.
    client.pushSequenced(try Source.event("Clipboard", "different line"), 11);
    try std.testing.expectEqual(@as(usize, 3), client.queue.items.len);
    // Never deduplicate game hooks or Console output, or assume sequence zero is valid.
    client.pushSequenced(try Source.event("Console", "message"), 11);
    client.pushSequenced(try Source.event("Console", "message"), 11);
    client.pushSequenced(try Source.event("Clipboard", "copied line"), 0);
    client.pushSequenced(try Source.event("Clipboard", "copied line"), 0);
    try std.testing.expectEqual(@as(usize, 7), client.queue.items.len);
}
