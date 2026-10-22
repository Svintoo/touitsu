//! Touitsu - Textractor-style text hooker UI built on Knots + the embedded Textractor host.
//!
//! Flow: pick a process on the left -> it is attached -> saved hooks for that game are inserted
//! automatically -> pick a hook thread -> extracted text shows on the right (oldest first).
//! For a new game: use "Search for hooks" (advance the game's text while it runs), click a
//! candidate to insert it, then "Save selected hook" so it's loaded automatically next time.
//!
//! Needs a TrueType font with Japanese glyphs at src/fonts/jp.ttf (Knots has no font fallback).

const std = @import("std");
const knots = @import("knots");
const ui = @import("ui");
const tx = @import("components/textractor/textractor.zig");
const procs = @import("components/textractor/procs.zig");
const Reader = @import("components/reader/reader.zig");
const FontSettings = @import("components/fonts/font_settings.zig");
const BackgroundImage = @import("components/appearance/background_image.zig");
const AnkiSettings = @import("components/anki/anki_settings.zig");
const hookstore = @import("components/textractor/Hookstore.zig");
const AutoAttach = @import("components/textractor/auto_attach.zig");

const Rect = ui.component.Rect;

/// Thread-safe allocator for everything we keep and everything the Textractor wrapper
/// allocates on its own threads.
const alloc = std.heap.smp_allocator;

/// The Textractor host. Global: the shim keeps a pointer to it for the process lifetime.
var client: tx.Client = undefined;

const max_lines = 300;
const max_candidates = 400;

const Line = struct { id: usize, text: []u8 };

const ThreadEntry = struct {
    pid: u32,
    handle: u64,
    addr: u64,
    ctx: u64,
    ctx2: u64,
    name: []u8,
    code: []u8,
    accepted: bool = false,
    reduce_pairs: bool = false,
    flood: @import("components/textractor/capture_limits.zig").FloodGuard = .{},
    removed: bool = false,
    lines: std.ArrayList(Line) = .empty,

    fn deinit(self: *ThreadEntry) void {
        for (self.lines.items) |l| alloc.free(l.text);
        self.lines.deinit(alloc);
        alloc.free(self.name);
        alloc.free(self.code);
    }
};

const Selected = struct { pid: u32, handle: u64 };

/// A hook-search result: an /H code plus a sample of the text it produced.
const Candidate = struct { pid: u32, code: []u8, text: []u8, thread_handle: ?u64 = null };
const HookIdentity = struct { pid: u32, code: []u8 };

app: knots.App,
gpa: std.mem.Allocator,
store: hookstore.Store,
proc_list: []procs.Proc = &[_]procs.Proc{},
auto_attach: AutoAttach = .{},
last_process_scan_ms: ?i64 = null,
fullscreen_was_maximized: bool = false,
show_system_processes: bool = false,
expanded_process: ?u32 = null,
attached: std.ArrayList(u32) = .empty,
threads: std.ArrayList(ThreadEntry) = .empty,
selected: ?Selected = null,
selected_candidate: ?usize = null,
expanded_hook: ?u64 = null,
search_pid: ?u32 = null,
search_started_ms: ?i64 = null,
search_running: bool = false,
enabled_hooks: std.ArrayList(HookIdentity) = .empty,
user_chose: bool = false,
auto_switched: bool = false,
/// Thread to re-select after connecting (from the saved hooks file); owns `code`.
sel_hint: ?hookstore.Sel = null,
status: []const u8 = "",
hook_draft: std.ArrayList(u8) = .empty,
/// Empty the hook input at the start of the next frame (never mid-frame, see frame()).
hook_clear_pending: bool = false,
search_draft: std.ArrayList(u8) = .empty,
search_cp: u32 = 65001,
search_filters: @import("components/textractor/hook_sample_filter.zig").Options = .{},
candidates: std.ArrayList(Candidate) = .empty,
next_line_id: usize = 0,
pump_started: bool = false,
texthooking_collapsed: bool = false,
reader: Reader,
fonts: FontSettings,
background: BackgroundImage,
anki: AnkiSettings,
sidebar_tab: enum { textractor, dictionaries, fonts, theme, settings, anki, about } = .textractor,
about: @import("components/about/about.zig") = .{},
window_integration: @import("platform/window_integration.zig") = .{},

const Self = @This();

const SidebarUI = @import("ui/sidebar.zig").Components(Self);
const TextractorUI = @import("components/textractor/textractor_ui.zig").Components(Self);
const TexthookingSidebar = SidebarUI.Sidebar;
const ReaderView = SidebarUI.ReaderView;
const TextractorSettings = TextractorUI.Settings;
const HookPreview = TextractorUI.HookPreview;
const input_key = @import("components/textractor/textractor_ui.zig").input_key;

// ---- lifecycle ----

pub fn init(io: std.Io, gpa: std.mem.Allocator) !Self {
    return .{
        .app = try knots.App.init(io, gpa, .{
            .window = .{
                .width = 1100,
                .height = 760,
                .title = "Touitsu",
                .decorations = .native,
                .resizable = true,
            },
            // Replaces the built-in font. Knots has no font fallback, so this one font must
            // cover everything we show (Latin + Japanese).
            .ui = .{ .fonts = &.{
                .{ .name = "default", .data = @embedFile("fonts/jp.ttf") },
            } },
        }),
        .gpa = gpa,
        .store = try hookstore.Store.init(alloc),
        .reader = Reader.init(io),
        .fonts = FontSettings.init(io),
        .background = BackgroundImage.init(),
        .anki = AnkiSettings.init(gpa),
    };
}

pub fn deinit(self: *Self) void {
    const remaining = client.shutdown(5000);
    if (remaining != 0) std.log.warn("Textractor shutdown timed out with {d} connection(s) still pending", .{remaining});
    self.reader.deinit();
    self.anki.deinit();
    for (self.threads.items) |*t| t.deinit();
    self.threads.deinit(alloc);
    for (self.enabled_hooks.items) |hook| alloc.free(hook.code);
    self.enabled_hooks.deinit(alloc);
    self.attached.deinit(alloc);
    self.clearCandidates();
    self.candidates.deinit(alloc);
    if (self.sel_hint) |h| alloc.free(h.code);
    self.store.deinit();
    procs.free(alloc, self.proc_list);
    self.auto_attach.deinit();
    alloc.free(self.status);
    self.hook_draft.deinit(self.gpa);
    self.search_draft.deinit(self.gpa);
    self.app.deinit();
    self.fonts.deinit();
    self.background.deinit();
}

// ---- state ----

pub fn toggleFullscreen(self: *Self) void {
    const window = &self.app.main_viewport.window;
    const mode = window.getDisplayMode();
    if (mode == .fullscreen) {
        _ = window.setDisplayMode(if (self.fullscreen_was_maximized) .maximized else .windowed);
    } else {
        self.fullscreen_was_maximized = mode == .maximized;
        if (!window.setDisplayMode(.fullscreen)) self.setStatus("Could not enter fullscreen.", .{});
    }
}

pub fn setStatus(self: *Self, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(alloc, fmt, args) catch return;
    alloc.free(self.status);
    self.status = s;
}

pub fn refreshProcs(self: *Self) void {
    const fresh = procs.list(alloc) catch return;
    procs.free(alloc, self.proc_list);
    self.proc_list = fresh;
    for (self.proc_list) |process| {
        if (!process.attachable or self.isAttached(process.pid) or !AutoAttach.hasSavedName(&self.store, process.name)) continue;
        const path = procs.exePath(alloc, process.pid) catch continue;
        defer alloc.free(path);
        // Match the complete saved path, not just an executable's basename.
        const first_attempt = self.auto_attach.shouldAttach(&self.store, process, path, self.isAttached(process.pid)) catch continue;
        if (!first_attempt) continue;
        self.attach(process.pid) catch |err| self.setStatus("Could not auto-attach to {s}: {s}", .{ process.name, @errorName(err) });
    }
}

pub fn isAttached(self: *const Self, pid: u32) bool {
    return std.mem.indexOfScalar(u32, self.attached.items, pid) != null;
}

pub fn lastAttached(self: *const Self) ?u32 {
    if (self.attached.items.len == 0) return null;
    return self.attached.items[self.attached.items.len - 1];
}

pub fn attach(self: *Self, pid: u32) !void {
    if (self.isAttached(pid)) return; // never inject the same process twice
    // A manual attempt also counts, so a failed/manual-detached game is not
    // immediately attached again by the periodic saved-game scan.
    for (self.proc_list) |process| {
        if (process.pid == pid) {
            _ = try self.auto_attach.claim(pid, process.started_at);
            break;
        }
    }
    try self.attached.append(alloc, pid);
    if (!client.attach(pid)) {
        self.forgetPid(pid);
        self.setStatus("Attach failed for {d}", .{pid});
        return;
    }
    self.setStatus("Attaching to {d}...", .{pid});
}

fn forgetPid(self: *Self, pid: u32) void {
    if (std.mem.indexOfScalar(u32, self.attached.items, pid)) |i| _ = self.attached.swapRemove(i);
    for (self.threads.items) |*thread| {
        if (thread.pid == pid) thread.removed = true;
    }
    if (self.selected) |selected| {
        if (selected.pid == pid) self.selected = null;
    }
    var i = self.enabled_hooks.items.len;
    while (i > 0) {
        i -= 1;
        if (self.enabled_hooks.items[i].pid == pid) {
            alloc.free(self.enabled_hooks.items[i].code);
            _ = self.enabled_hooks.orderedRemove(i);
        }
    }
}

pub fn detach(self: *Self, pid: u32) void {
    _ = client.detach(pid);
    self.forgetPid(pid);
    self.setStatus("Detached from {d}", .{pid});
}

/// Manual hook code typed by the user. Never lets bad input crash the app.
pub fn insertHook(self: *Self) void {
    const code = std.mem.trim(u8, self.hook_draft.items, " \t\r\n");
    if (code.len == 0) return;
    const pid = self.lastAttached() orelse {
        self.setStatus("Attach to a process first", .{});
        return;
    };
    if (!std.unicode.utf8ValidateSlice(code)) {
        // Shouldn't happen for typed text; show the raw bytes so we can see what's in the buffer.
        self.setStatus("Hook code isn't valid UTF-8 ({d} bytes, starts {x})", .{ code.len, code[0..@min(code.len, 16)] });
        self.hook_clear_pending = true;
        return;
    }
    for (self.enabled_hooks.items) |hook| {
        if (hook.pid == pid and std.mem.eql(u8, hook.code, code)) {
            self.setStatus("This hook is already active. Use Streams to select its context.", .{});
            return;
        }
    }
    const ok = client.insertHook(pid, code) catch false;
    if (ok) self.acceptHook(pid, code) catch {};
    self.setStatus("Hook {s}: {s}", .{ code, if (ok) "inserted" else "invalid code or process not connected" });
    if (ok) self.hook_clear_pending = true;
}

pub fn findThread(self: *Self, pid: u32, handle: u64) ?*ThreadEntry {
    for (self.threads.items) |*t| {
        if (t.pid == pid and t.handle == handle) return t;
    }
    return null;
}

pub fn isBuiltin(name: []const u8) bool {
    return std.mem.eql(u8, name, "Console") or std.mem.eql(u8, name, "Clipboard");
}

fn ensureThread(self: *Self, m: tx.ThreadMeta) !*ThreadEntry {
    if (self.findThread(m.pid, m.handle)) |t| return t;
    const name = try alloc.dupe(u8, m.name);
    errdefer alloc.free(name);
    const code = try alloc.dupe(u8, m.hook_code);
    errdefer alloc.free(code);
    try self.threads.append(alloc, .{
        .pid = m.pid,
        .handle = m.handle,
        .addr = m.addr,
        .ctx = m.ctx,
        .ctx2 = m.ctx2,
        .name = name,
        .code = code,
    });
    const t = &self.threads.items[self.threads.items.len - 1];
    if (self.store.entries.items.len > 0) {
        const exe = procs.exePath(alloc, m.pid) catch null;
        defer if (exe) |path| alloc.free(path);
        if (exe) |path| t.reduce_pairs = self.store.reducesPairs(path, t.code);
    }
    for (self.enabled_hooks.items) |hook| {
        if (hook.pid == t.pid and std.mem.eql(u8, hook.code, t.code)) t.accepted = true;
    }
    if (self.selected == null and t.accepted) self.selected = .{ .pid = t.pid, .handle = t.handle };
    // Re-select the thread that was selected last time for this game.
    if (self.sel_hint) |h| {
        if (t.accepted and h.ctx == t.ctx and h.ctx2 == t.ctx2 and std.mem.eql(u8, h.code, t.code)) {
            self.selected = .{ .pid = t.pid, .handle = t.handle };
            self.user_chose = true;
        }
    }
    return t;
}

fn acceptHook(self: *Self, pid: u32, code: []const u8) !void {
    var exists = false;
    for (self.enabled_hooks.items) |hook| {
        if (hook.pid == pid and std.mem.eql(u8, hook.code, code)) exists = true;
    }
    if (!exists) {
        const copy = try alloc.dupe(u8, code);
        errdefer alloc.free(copy);
        try self.enabled_hooks.append(alloc, .{ .pid = pid, .code = copy });
    }
    for (self.threads.items) |*thread| {
        if (thread.pid == pid and std.mem.eql(u8, thread.code, code)) {
            thread.accepted = true;
            thread.removed = false;
            if (self.selected == null) self.selected = .{ .pid = pid, .handle = thread.handle };
        }
    }
}

pub fn removeHook(self: *Self, thread: *ThreadEntry) void {
    if (!client.removeHook(thread.pid, thread.addr)) {
        self.setStatus("Could not remove hook (is the game still connected?)", .{});
        return;
    }
    const exe = procs.exePath(alloc, thread.pid) catch null;
    defer if (exe) |path| alloc.free(path);
    for (self.threads.items) |*item| {
        if (item.pid != thread.pid or item.addr != thread.addr) continue;
        item.accepted = false;
        item.removed = true;
        if (exe) |path| self.store.removeCode(path, item.code);
        var i = self.enabled_hooks.items.len;
        while (i > 0) {
            i -= 1;
            const hook = self.enabled_hooks.items[i];
            if (hook.pid == item.pid and std.mem.eql(u8, hook.code, item.code)) {
                alloc.free(hook.code);
                _ = self.enabled_hooks.orderedRemove(i);
            }
        }
        if (self.selected) |s| {
            if (s.pid == item.pid and s.handle == item.handle) self.selected = null;
        }
    }
    self.store.save() catch |err| return self.setStatus("Hook removed; couldn't update saved hooks: {s}", .{@errorName(err)});
    self.setStatus("Removed hook {s}", .{thread.code});
}

fn pushLine(self: *Self, th: *ThreadEntry, text: []const u8) !void {
    const copy = try alloc.dupe(u8, text);
    errdefer alloc.free(copy);
    try th.lines.append(alloc, .{ .id = self.next_line_id, .text = copy });
    self.next_line_id += 1;
    if (th.lines.items.len > max_lines) {
        const old = th.lines.orderedRemove(0);
        alloc.free(old.text);
    }
}

// ---- saved hooks ----

fn setSelHint(self: *Self, sel: hookstore.Sel) void {
    const copy = alloc.dupe(u8, sel.code) catch return;
    if (self.sel_hint) |old| alloc.free(old.code);
    self.sel_hint = .{ .ctx = sel.ctx, .ctx2 = sel.ctx2, .code = copy };
}

/// Called when the host reports a process connected: insert its saved hooks.
fn onConnected(self: *Self, pid: u32) void {
    const exe = procs.exePath(alloc, pid) catch {
        self.setStatus("Connected to {d} (couldn't read its path, so saved hooks were skipped)", .{pid});
        return;
    };
    defer alloc.free(exe);
    const entry = self.store.find(exe) orelse {
        self.setStatus("Connected to {d}: no saved hooks for this game", .{pid});
        return;
    };
    var inserted: usize = 0;
    for (entry.codes.items) |code| {
        if (client.insertHook(pid, code) catch false) {
            self.acceptHook(pid, code) catch {};
            inserted += 1;
        }
    }
    if (entry.sel) |s| self.setSelHint(s);
    self.setStatus("Connected to {d}\ninserted {d} of {d} saved hook(s)", .{ pid, inserted, entry.codes.items.len });
}

pub fn saveSelected(self: *Self) void {
    const sel = self.selected orelse {
        self.setStatus("Select a hook thread first", .{});
        return;
    };
    const th = self.findThread(sel.pid, sel.handle) orelse return;
    if (isBuiltin(th.name)) {
        self.setStatus("Select a real hook thread (not Console/Clipboard) to save", .{});
        return;
    }
    const exe = procs.exePath(alloc, th.pid) catch {
        self.setStatus("Couldn't read the process path (is the game still running?)", .{});
        return;
    };
    defer alloc.free(exe);
    self.store.addCode(exe, th.code) catch |e| return self.setStatus("Save failed: {s}", .{@errorName(e)});
    self.store.setPairs(exe, th.code, th.reduce_pairs) catch |e| return self.setStatus("Save failed: {s}", .{@errorName(e)});
    self.store.setSel(exe, th.ctx, th.ctx2, th.code) catch |e| return self.setStatus("Save failed: {s}", .{@errorName(e)});
    self.store.save() catch |e| return self.setStatus("Couldn't write hooks.txt: {s}", .{@errorName(e)});
    self.setStatus("Saved hook {s}", .{th.code});
}

pub fn setHookPairs(self: *Self, selected: *ThreadEntry, enabled: bool) void {
    for (self.threads.items) |*thread| {
        if (thread.pid == selected.pid and std.mem.eql(u8, thread.code, selected.code)) thread.reduce_pairs = enabled;
    }
    const exe = procs.exePath(alloc, selected.pid) catch return;
    defer alloc.free(exe);
    self.store.setPairs(exe, selected.code, enabled) catch return;
    self.store.save() catch self.setStatus("Could not save hook processing options", .{});
}

pub fn forgetSaved(self: *Self) void {
    const pid = self.lastAttached() orelse {
        self.setStatus("Attach to a process first", .{});
        return;
    };
    const exe = procs.exePath(alloc, pid) catch return;
    defer alloc.free(exe);
    self.store.forget(exe);
    self.store.save() catch {};
    self.setStatus("Forgot saved hooks for {s}", .{exe});
}

/// Remember which thread the user picked, but only for games that already have saved hooks.
pub fn rememberSelection(self: *Self, th: *const ThreadEntry) void {
    if (isBuiltin(th.name)) return;
    const exe = procs.exePath(alloc, th.pid) catch return;
    defer alloc.free(exe);
    if (self.store.find(exe) == null) return;
    self.store.setSel(exe, th.ctx, th.ctx2, th.code) catch return;
    self.store.save() catch {};
}

// ---- hook search ----

pub fn clearCandidates(self: *Self) void {
    self.selected_candidate = null;
    for (self.candidates.items) |c| {
        alloc.free(c.code);
        alloc.free(c.text);
    }
    self.candidates.clearRetainingCapacity();
}

fn pushCandidate(self: *Self, pid: u32, code: []const u8, text: []const u8, thread_handle: ?u64) !void {
    for (self.candidates.items) |*c| {
        if (c.pid == pid and std.mem.eql(u8, c.code, code)) {
            const copy = try alloc.dupe(u8, text);
            alloc.free(c.text);
            c.text = copy;
            if (thread_handle) |handle| c.thread_handle = handle;
            return;
        }
    }
    if (self.candidates.items.len >= max_candidates) return; // press Clear to collect more
    const c = try alloc.dupe(u8, code);
    errdefer alloc.free(c);
    const t = try alloc.dupe(u8, text);
    errdefer alloc.free(t);
    var index: usize = 0;
    while (index < self.candidates.items.len and
        std.mem.order(u8, self.candidates.items[index].code, code) != .gt) : (index += 1)
    {}
    try self.candidates.insert(alloc, index, .{ .pid = pid, .code = c, .text = t, .thread_handle = thread_handle });
    if (self.selected_candidate) |selected| {
        if (selected >= index) self.selected_candidate = selected + 1;
    }
}

test "hook history preview search candidates sort by code and preserve selection" {
    var self: Self = undefined;
    self.candidates = .empty;
    self.selected_candidate = null;
    defer {
        self.clearCandidates();
        self.candidates.deinit(alloc);
    }
    try self.pushCandidate(1, "HS2@30", "second", null);
    try self.pushCandidate(1, "HS1@20", "first", null);
    self.selected_candidate = 1;
    try self.pushCandidate(1, "HS1@10", "earlier", null);
    try std.testing.expectEqualStrings("HS1@10", self.candidates.items[0].code);
    try std.testing.expectEqualStrings("HS1@20", self.candidates.items[1].code);
    try std.testing.expectEqualStrings("HS2@30", self.candidates.items[2].code);
    try std.testing.expectEqual(@as(?usize, 2), self.selected_candidate);
    try self.pushCandidate(1, "HS1@20", "updated", 42);
    try std.testing.expectEqual(@as(usize, 3), self.candidates.items.len);
    try std.testing.expectEqualStrings("updated", self.candidates.items[1].text);
    try std.testing.expectEqual(@as(?u64, 42), self.candidates.items[1].thread_handle);
    try std.testing.expectEqual(@as(?usize, 2), self.selected_candidate);
}

pub fn startSearch(self: *Self, now_ms: i64) void {
    if (self.search_running) return;
    const pid = self.lastAttached() orelse {
        self.setStatus("Attach to a process first", .{});
        return;
    };
    const text = std.mem.trim(u8, self.search_draft.items, " \t\r\n");
    if (!std.unicode.utf8ValidateSlice(text)) {
        self.setStatus("Search text isn't valid UTF-8", .{});
        return;
    }
    self.clearCandidates();
    const ok = client.findHooks(pid, self.search_cp, if (text.len > 0) text else null) catch false;
    if (ok) {
        self.search_pid = pid;
        self.search_started_ms = now_ms;
        self.search_running = true;
        self.setStatus("Searching for 30 seconds... make the game show/advance text. Candidates appear below.", .{});
    } else {
        self.setStatus("Couldn't start the search (is the process connected?)", .{});
    }
}

pub fn useCandidate(self: *Self, c: Candidate) void {
    const live = if (c.thread_handle) |handle| if (self.findThread(c.pid, handle)) |thread| !thread.removed else false else false;
    const ok = live or (client.insertHook(c.pid, c.code) catch false);
    if (ok) {
        self.acceptHook(c.pid, c.code) catch {};
        if (c.thread_handle) |handle| self.selected = .{ .pid = c.pid, .handle = handle };
    }
    self.user_chose = true;
    self.setStatus("Hook {s}: {s}", .{ c.code, if (ok) "added to Active hooks; save it to restore it next time" else "failed" });
}

// ---- events ----

fn handleEvent(self: *Self, ev: tx.Event, now_ms: i64) !void {
    switch (ev) {
        .backend_error => |error_info| {
            if (error_info.pid != 0) self.forgetPid(error_info.pid);
            self.setStatus("{s}", .{error_info.message});
        },
        .connected => |pid| self.onConnected(pid),
        .disconnected => |pid| {
            self.forgetPid(pid);
            self.setStatus("Disconnected from {d}", .{pid});
        },
        .thread_created => |m| {
            if (self.threads.items.len >= 128 and self.findThread(m.pid, m.handle) == null) return;
            _ = try self.ensureThread(m);
        },
        .thread_destroyed => |m| {
            if (self.findThread(m.pid, m.handle)) |thread| thread.removed = true;
        }, // keep captured history for preview
        .hook_found => |h| try self.pushCandidate(h.pid, h.code, h.text, null),
        .text => |t| {
            if (self.threads.items.len >= 128 and self.findThread(t.meta.pid, t.meta.handle) == null) return;
            const th = try self.ensureThread(t.meta);
            const already_blocked = th.flood.blocked;
            if (!th.flood.accept(now_ms, t.text.len)) {
                if (!already_blocked) self.setStatus("Stopped noisy hook {s}: output exceeded safety limits. Remove this hook and select another.", .{th.name});
                return;
            }
            try self.pushLine(th, t.text);
            const builtin = isBuiltin(th.name);
            if (!builtin and self.search_running and self.search_pid == th.pid and !th.accepted and !th.removed) try self.pushCandidate(th.pid, th.code, t.text, th.handle);
            // Automatically select the first explicitly added or restored hook.
            if (!builtin and th.accepted and !self.user_chose and !self.auto_switched) {
                self.selected = .{ .pid = th.pid, .handle = th.handle };
                self.auto_switched = true;
            }
            if (self.selected) |sel| {
                if (!self.reader.capture_paused and (th.accepted or builtin) and !th.removed and sel.pid == th.pid and sel.handle == th.handle) {
                    if (th.reduce_pairs) {
                        const processed = try @import("components/textractor/hook_sample_filter.zig").reducePairs(alloc, t.text);
                        defer alloc.free(processed);
                        try self.reader.append(processed);
                    } else try self.reader.append(t.text);
                }
            }
        },
    }
}

/// Moves queued Textractor events into app state. Main thread only. Returns true if anything changed.
fn drainEvents(self: *Self, now_ms: i64) !bool {
    var events: std.ArrayList(tx.Event) = .empty;
    defer events.deinit(alloc);
    try client.drain(&events, alloc);
    for (events.items) |*ev| {
        defer ev.deinit(alloc);
        try self.handleEvent(ev.*, now_ms);
    }
    if (events.items.len > 0) self.reader.save();
    return events.items.len > 0;
}

// ---- background pump (Knots `dispatch`) ----

/// Hook events wake immediately. The timeout only refreshes timers/background jobs.
/// Touches no app state.
fn waitForEvents() anyerror!void {
    client.wait(1000);
}

/// Runs inside Knots' completion frame: absorb events and re-arm the wait.
fn pump(view: *knots.View, frame_ctx: *ui.Frame, result: anyerror!void) !void {
    const self: *Self = @alignCast(@fieldParentPtr("app", view.app));
    result catch {};
    const now = frame_ctx.ui().input.now_ms;
    if (self.store.entries.items.len > 0 and (self.last_process_scan_ms == null or now - self.last_process_scan_ms.? >= 2000)) {
        self.last_process_scan_ms = now;
        self.refreshProcs();
    }
    if (self.search_running and frame_ctx.ui().input.now_ms - self.search_started_ms.? >= 30000) {
        client.stopSearch(self.search_pid.?);
        self.search_running = false;
        self.setStatus("Search done (30 seconds). Select a candidate to inspect it.", .{});
    }
    _ = try self.drainEvents(frame_ctx.ui().input.now_ms);
    // Dispatch completions already run inside a frame; no extra redraw is needed.
    try view.app.dispatch(view.id, waitForEvents, .{}, pump);
}

// ---- UI ----

pub fn frame(view: *knots.View, context: *ui.Frame) !void {
    const self: *Self = @alignCast(@fieldParentPtr("app", view.app));
    for (context.ui().input.key_events) |event| {
        if (event.action != .press) continue;
        if (event.key == .f11 or (event.key == .escape and self.app.main_viewport.window.getDisplayMode() == .fullscreen)) {
            self.toggleFullscreen();
            context.requestRedraw();
        }
    }
    self.window_integration.guardFrames();
    self.reader.tick(context);
    self.reader.updateControlsVisibility(context, !self.texthooking_collapsed);
    self.background.appearance.applyTheme(context);
    try self.anki.tick(context);
    self.fonts.ensureLoaded(context);
    self.reader.shift_selection.sample(self.app.main_viewport.window.getWindowHandle().windows.hwnd, context.ui().content_scale);
    if (!self.pump_started) {
        self.pump_started = true;
        try view.app.dispatch(view.id, waitForEvents, .{}, pump);
    }
    const size = context.input().logical_extent;

    // TextInput keeps its own cursor/selection and a view of our buffer, so we only ever empty
    // the buffer here, before this frame builds the input, never in the middle of a frame.
    if (self.hook_clear_pending) {
        self.hook_clear_pending = false;
        self.hook_draft.clearRetainingCapacity();
        if (context.ui().state.get(.text_input, input_key.hash())) |st| {
            st.cursor = 0;
            st.sel_anchor = 0;
        }
    }

    try context.e(.{
        Rect{ .key = .src(@src()), .style = &.{
            .width = .fixed(@floatFromInt(size.width)),
            .height = .fixed(@floatFromInt(size.height)),
            .padding = .all(12),
            .direction = .row,
            .gap = 12,
            .background = .bg,
        } },
        .{
            TexthookingSidebar{ .self = self },
            ReaderView{ .self = self },
        },
    });
    try @import("ui/text_context_menu.zig").render(context, &self.app.main_viewport.window);
    if (self.reader.scroll_pending > 0) context.requestRedraw();
}

pub fn main(init_: std.process.Init) !void {
    var self = try Self.init(init_.io, init_.gpa);
    defer self.deinit();
    client = .init(alloc);
    client.start();
    try self.window_integration.attach(&self.app.main_viewport.window);
    defer self.window_integration.detach();
    // Textractor's Host::Start installs a WH_GETMESSAGE hook on this thread.
    // Register our window so Windows actually posts the WM_CLIPBOARDUPDATE
    // messages that wake its clipboard reader.
    const Clipboard = struct {
        extern "user32" fn AddClipboardFormatListener(?*anyopaque) callconv(.winapi) i32;
        extern "user32" fn RemoveClipboardFormatListener(?*anyopaque) callconv(.winapi) i32;
    };
    const hwnd = self.app.main_viewport.window.getWindowHandle().windows.hwnd;
    const clipboard_registered = Clipboard.AddClipboardFormatListener(hwnd) != 0;
    defer if (clipboard_registered) {
        _ = Clipboard.RemoveClipboardFormatListener(hwnd);
    };
    if (!clipboard_registered) self.setStatus("Could not enable Windows clipboard monitoring.", .{});
    self.refreshProcs();
    try self.app.start(frame);
}

test "hook history preview evicts oldest reader lines at the word budget" {
    var reader: Reader = .{ .dictionaries = .{} };
    defer reader.deinit();
    const text = try std.testing.allocator.alloc(u8, 500_000 * 2);
    defer std.testing.allocator.free(text);
    for (0..500_000) |i| @memcpy(text[i * 2 ..][0..2], "a ");
    try reader.append(text);
    try std.testing.expectEqual(@as(usize, 1), reader.lines.items.len);
    try reader.append("newest word");
    try std.testing.expectEqual(@as(usize, 1), reader.lines.items.len);
    try std.testing.expectEqualStrings("newest word", reader.lines.items[0].text);
    try std.testing.expectEqual(@as(usize, 4), reader.history_units);
    try std.testing.expectEqual(@as(usize, 11), reader.history_bytes);
}

test "hook history preview multiline drag selects context in horizontal and both vertical directions" {
    for ([_]@import("components/reader/reading_layout.zig").Direction{ .horizontal, .vertical_left, .vertical_right, .horizontal }, 0..) |direction, mode| {
        var ui_context = try ui.Context.init(std.testing.allocator, .{ .ui = .{ .fonts = &.{.{ .name = "default", .data = @embedFile("fonts/jp.ttf") }} } });
        defer ui_context.deinit();
        var reader: Reader = .{ .dictionaries = .{} };
        defer reader.deinit();
        try reader.append("一行目");
        try reader.append("二行目");
        try reader.append("三行目");
        var fonts: FontSettings = .{ .reader_size = 20, .character_spacing = if (mode == 3) 1 else 0 };
        var background: BackgroundImage = .{};
        background.appearance.direction = direction;
        var anki: AnkiSettings = .{ .gpa = std.testing.allocator };
        var start_point: [2]f32 = .{ 0, 0 };
        var end_point: [2]f32 = .{ 0, 0 };
        const cells = direction != .horizontal or mode == 3;
        for (0..5) |iteration| {
            const point = if (iteration < 3) start_point else end_point;
            var frame_ctx = try ui_context.beginFrame(.{
                .input = .{ .pos = .{ point[0], point[1] }, .mouse = .{ .{ .down = iteration == 2 or iteration == 3, .pressed = iteration == 2, .released = iteration == 4 }, .{}, .{}, .{}, .{} } },
                .now_ms = @intCast(iteration * 16),
                .delta_ns = 16_000_000,
                .logical_extent = .{ .width = 1000, .height = 600 },
                .physical_extent = .{ .width = 1000, .height = 600 },
                .content_scale = 1,
            });
            defer frame_ctx.deinit();
            reader.shift_selection.pointer = point;
            const root: Rect = .{ .key = .str("test.multiline.root"), .style = &.{ .width = .fixed(1000), .height = .fixed(600) } };
            _ = try root.open(&frame_ctx);
            try reader.render(&frame_ctx, &fonts, &background, &anki);
            try root.close(&frame_ctx);
            if (iteration == 4) {
                try std.testing.expect(reader.shift_selection.multipleEntries());
                try std.testing.expectEqualStrings("一行目\n二行目\n三", frame_ctx.ui().state.selection_text);
                const context = try reader.shift_selection.collect(frame_ctx.arena(), true);
                try std.testing.expectEqualStrings("一行目\n二行目\n三行目", context);
            }
            _ = try ui_context.endFrame(&frame_ctx);
            if (iteration <= 1) {
                for ([_]usize{ 0, 2 }, 0..) |line_id, endpoint| {
                    const key = ui.Key.str("reader.line").indexed(line_id);
                    const box = if (cells)
                        ui_context.ui.state.get(.measured, ui.Key.str("reader.vertical.cell").indexed(line_id).indexed(0).hash()).?.box
                    else
                        ui_context.ui.state.get(.text_select, key.hash()).?.box;
                    const position: [2]f32 = .{ box.x() + 2, box.y() + 5 };
                    if (endpoint == 0) start_point = position else end_point = position;
                }
            }
        }
    }
}

test "hook history preview theme change sets contrasting text and preserves later overrides" {
    var appearance: @import("components/appearance/appearance_settings.zig") = .{};
    appearance.buttons.mode = .outline;
    try std.testing.expect(appearance.setTheme(.dark));
    const dark_text = appearance.buttons.foreground;
    try std.testing.expect(appearance.setTheme(.light));
    try std.testing.expect(appearance.buttons.foreground[0] < dark_text[0]);
    const custom = [4]f32{ 0.2, 0.4, 0.6, 1 };
    appearance.buttons.foreground = custom;
    try std.testing.expect(!appearance.setTheme(.light));
    try std.testing.expectEqual(custom, appearance.buttons.foreground);
    appearance.buttons.mode = .solid;
    appearance.buttons.background = .{ 1, 1, 1, 1 };
    try std.testing.expect(appearance.setTheme(.dark));
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 1 }, appearance.buttons.foreground);
    appearance.buttons.background = .{ 0, 0, 0, 1 };
    try std.testing.expect(appearance.setTheme(.light));
    try std.testing.expectEqual([4]f32{ 1, 1, 1, 1 }, appearance.buttons.foreground);
    try std.testing.expect(appearance.setTheme(.uranium));
    try std.testing.expectEqual(@as(f32, 1.4), appearance.glass_response);
    try std.testing.expect(appearance.material().isValid());
    try std.testing.expect(appearance.material().specular > 0);
    try std.testing.expect(appearance.popup.material().isValid());
}

test "hook history preview pronunciation loading status renders beside Play" {
    var audio: @import("components/pronunciation/pronunciation.zig") = .{
        .status_key = std.hash.Wyhash.hash(std.hash.Wyhash.hash(0, "猫"), "ねこ"),
        .status = "Loading pronunciation...",
    };
    defer audio.deinit();
    var ui_context = try ui.Context.init(std.testing.allocator, .{ .ui = .{ .fonts = &.{.{ .name = "default", .data = @embedFile("fonts/jp.ttf") }} } });
    defer ui_context.deinit();
    var frame_ctx = try ui_context.beginFrame(.{ .input = .{ .pos = .{ 0, 0 } }, .now_ms = 0, .delta_ns = 16_000_000, .logical_extent = .{ .width = 440, .height = 280 }, .physical_extent = .{ .width = 440, .height = 280 }, .content_scale = 1 });
    defer frame_ctx.deinit();
    try audio.renderButton(&frame_ctx, .str("test.pronunciation.play"), "猫", "ねこ", true);
    try audio.renderStatus(&frame_ctx, .str("test.pronunciation.play"), "猫", "ねこ", true);
    const output = try ui_context.endFrame(&frame_ctx);
    var status_found = false;
    for (output.accessibility.nodes) |node| {
        if (node.state.value_text) |value| {
            if (std.mem.eql(u8, value, "Loading pronunciation...")) status_found = true;
        }
    }
    try std.testing.expect(status_found);
}

test "hook history preview pronunciation respects disabled internet despite enabled defaults" {
    var audio: @import("components/pronunciation/pronunciation.zig") = .{};
    defer audio.deinit();
    try audio.play("猫", "ねこ", false);
    try std.testing.expect(audio.job == null);
    try std.testing.expect(audio.thread == null);
    const appearance: @import("components/appearance/appearance_settings.zig") = .{};
    try std.testing.expect(appearance.online_audio_enabled);
}

test "hook history preview Ctrl C copies selected reader text" {
    const MockWindow = struct {
        pub fn getWindowHandle(_: *@This()) struct { windows: struct { hwnd: ?*anyopaque = null } = .{} } {
            return .{};
        }
        pub fn requestPaste(_: *@This()) !void {}
    };
    var window: MockWindow = .{};
    var ui_context = try ui.Context.init(std.testing.allocator, .{ .ui = .{ .fonts = &.{.{ .name = "default", .data = @embedFile("fonts/jp.ttf") }} } });
    defer ui_context.deinit();
    var frame_ctx = try ui_context.beginFrame(.{ .input = .{ .pos = .{ 0, 0 }, .key_events = &.{.{ .key = .c, .action = .press, .mods = .{ .ctrl = true } }} }, .now_ms = 0, .delta_ns = 16_000_000, .logical_extent = .{ .width = 500, .height = 500 }, .physical_extent = .{ .width = 500, .height = 500 }, .content_scale = 1 });
    defer frame_ctx.deinit();
    frame_ctx.ui().state.selection_text = "reader selection";
    try @import("ui/text_context_menu.zig").render(&frame_ctx, &window);
    const output = try ui_context.endFrame(&frame_ctx);
    try std.testing.expectEqualStrings("reader selection", output.clipboard_write.?);
}

test "hook history preview scrollbar drags never turn into text selections" {
    var ui_context = try ui.Context.init(std.testing.allocator, .{ .ui = .{ .fonts = &.{.{ .name = "default", .data = @embedFile("fonts/jp.ttf") }} } });
    defer ui_context.deinit();
    const Selection = @import("components/reader/shift_selection.zig");
    for ([_]bool{ false, true }) |horizontal| {
        var selection: Selection = .{ .horizontal_scrollbar = horizontal, .active_id = 123, .anchor_id = 123 };
        for (0..4) |phase| {
            const pointer: [2]f32 = if (phase == 0) (if (horizontal) .{ 150, 299 } else .{ 399, 150 }) else .{ 150, 150 };
            selection.pointer = pointer;
            var frame_ctx = try ui_context.beginFrame(.{ .input = .{ .pos = .{ pointer[0], pointer[1] }, .mouse = .{ .{ .down = phase != 2, .pressed = phase == 0 or phase == 3, .released = phase == 2 }, .{}, .{}, .{}, .{} } }, .now_ms = @intCast(phase * 16), .delta_ns = 16_000_000, .logical_extent = .{ .width = 400, .height = 300 }, .physical_extent = .{ .width = 400, .height = 300 }, .content_scale = 1 });
            defer frame_ctx.deinit();
            const log = try ui_context.ui.state.getOrCreate(.measured, ui_context.ui.allocator, ui.Key.str("reader.log").hash());
            log.* = .{ .width = 400, .height = 300, .box = @TypeOf(log.box).init(0, 0, 400, 300) };
            selection.beginPointer(&frame_ctx);
            if (phase <= 1) {
                try std.testing.expect(selection.scrollbar_dragging);
                try std.testing.expect(!selection.mouse_dragging);
                try std.testing.expectEqual(@as(?u64, 123), selection.active_id);
            } else if (phase == 2) {
                try std.testing.expect(!selection.scrollbar_dragging);
                try std.testing.expect(!selection.mouse_dragging);
            } else {
                try std.testing.expect(!selection.scrollbar_dragging);
                try std.testing.expect(selection.mouse_dragging);
            }
            _ = try ui_context.endFrame(&frame_ctx);
        }
    }
}

test "hook history preview reader text supports ordinary mouse drag selection" {
    var ui_context = try ui.Context.init(std.testing.allocator, .{ .ui = .{ .fonts = &.{.{ .name = "default", .data = @embedFile("fonts/jp.ttf") }} } });
    defer ui_context.deinit();
    var selection: @import("components/reader/shift_selection.zig") = .{};
    var selected_bytes: usize = 0;
    for (0..4) |iteration| {
        var frame_ctx = try ui_context.beginFrame(.{
            .input = .{ .pos = .{ if (iteration < 2) 2 else 60, 5 }, .mouse = .{ .{ .down = iteration == 1 or iteration == 2, .pressed = iteration == 1, .released = iteration == 3 }, .{}, .{}, .{}, .{} } },
            .now_ms = @intCast(iteration * 16),
            .delta_ns = 16_000_000,
            .logical_extent = .{ .width = 500, .height = 300 },
            .physical_extent = .{ .width = 500, .height = 300 },
            .content_scale = 1,
        });
        defer frame_ctx.deinit();
        try selection.renderText(&frame_ctx, .{ .key = .str("reader.test.drag"), .content = "copy this text", .style = &.{ .width = .fixed(400), .font_size = .{ .px = 16 } } });
        selected_bytes = frame_ctx.ui().state.selection_text.len;
        _ = try ui_context.endFrame(&frame_ctx);
    }
    try std.testing.expect(selected_bytes > 0);
}

test "hook history preview groups streams and applies processing only to the selected hook" {
    var self: Self = undefined;
    self.store = .{ .alloc = alloc, .path = undefined };
    self.threads = .empty;
    self.enabled_hooks = .empty;
    self.selected = null;
    self.selected_candidate = null;
    self.sel_hint = null;
    self.next_line_id = 0;
    self.user_chose = true;
    self.search_running = false;
    self.expanded_hook = null;
    self.reader = .{ .dictionaries = .{} };
    defer {
        for (self.threads.items) |*thread| thread.deinit();
        self.threads.deinit(alloc);
        for (self.enabled_hooks.items) |hook| alloc.free(hook.code);
        self.enabled_hooks.deinit(alloc);
        self.reader.deinit();
    }
    const meta: tx.ThreadMeta = .{ .pid = 42, .handle = 1, .addr = 1234, .ctx = 1, .ctx2 = 0, .name = @constCast("Test hook"), .hook_code = @constCast("HS0@1234") };
    _ = try self.ensureThread(meta);
    var sibling = meta;
    sibling.handle = 2;
    sibling.ctx = 2;
    _ = try self.ensureThread(sibling);
    var other = meta;
    other.handle = 3;
    other.addr = 9999;
    other.hook_code = @constCast("HS0@9999");
    _ = try self.ensureThread(other);
    try self.acceptHook(42, meta.hook_code);
    try std.testing.expectEqual(@as(u64, 1), self.selected.?.handle);
    try self.acceptHook(42, other.hook_code);
    try std.testing.expectEqual(@as(u64, 1), self.selected.?.handle);
    self.threads.items[0].reduce_pairs = true;
    self.threads.items[1].reduce_pairs = true;
    try self.handleEvent(.{ .text = .{ .meta = meta, .text = @constCast("aappppllee") } }, 0);
    try std.testing.expectEqualStrings("apple", self.reader.lines.items[0].text);
    self.selected = .{ .pid = 42, .handle = 3 };
    try self.handleEvent(.{ .text = .{ .meta = other, .text = @constCast("book") } }, 0);
    try std.testing.expectEqualStrings("book", self.reader.lines.items[1].text);

    self.reader.capture_paused = true;
    const preview_count = self.threads.items[2].lines.items.len;
    try self.handleEvent(.{ .text = .{ .meta = other, .text = @constCast("paused material") } }, 0);
    try std.testing.expectEqual(@as(usize, 2), self.reader.lines.items.len);
    try std.testing.expectEqual(preview_count + 1, self.threads.items[2].lines.items.len);
    self.reader.capture_paused = false;
    try self.handleEvent(.{ .text = .{ .meta = other, .text = @constCast("resumed material") } }, 0);
    try std.testing.expectEqual(@as(usize, 3), self.reader.lines.items.len);
    try std.testing.expectEqualStrings("resumed material", self.reader.lines.items[2].text);

    var ui_context = try ui.Context.init(std.testing.allocator, .{ .ui = .{ .fonts = &.{.{ .name = "default", .data = @embedFile("fonts/jp.ttf") }} } });
    defer ui_context.deinit();
    var frame_ctx = try ui_context.beginFrame(.{ .input = .{ .pos = .{ 0, 0 } }, .now_ms = 0, .delta_ns = 16_000_000, .logical_extent = .{ .width = 600, .height = 500 }, .physical_extent = .{ .width = 600, .height = 500 }, .content_scale = 1 });
    defer frame_ctx.deinit();
    try (TextractorUI.ThreadList{ .self = &self }).render(&frame_ctx);
    const output = try ui_context.endFrame(&frame_ctx);
    var removal_buttons: usize = 0;
    for (output.accessibility.nodes) |node| {
        if (std.mem.eql(u8, node.name, "x")) removal_buttons += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), removal_buttons);
}

test "hook history preview minimum fonts at 4K keep paragraph accessibility below the node limit" {
    var ui_context = try ui.Context.init(std.testing.allocator, .{
        .ui = .{ .fonts = &.{.{ .name = "default", .data = @embedFile("fonts/jp.ttf") }} },
    });
    defer ui_context.deinit();
    var reader: Reader = .{ .dictionaries = .{} };
    defer reader.deinit();
    const noisy = try alloc.alloc(u8, 20000);
    defer alloc.free(noisy);
    @memset(noisy, 'a');
    for (0..100) |_| try reader.append(noisy);
    var fonts: FontSettings = .{};
    var background: BackgroundImage = .{};
    var anki: AnkiSettings = .{ .gpa = std.testing.allocator };
    for ([_]@import("components/reader/reading_layout.zig").Direction{ .horizontal, .vertical_left, .vertical_right, .horizontal }, 0..) |direction, iteration| {
        background.appearance.direction = direction;
        fonts.reader_size = if (iteration == 0) 28 else 12;
        fonts.character_spacing = if (iteration == 3) 1 else 0;
        var frame_ctx = try ui_context.beginFrame(.{ .input = .{ .pos = .{ 0, 0 } }, .now_ms = @intCast(iteration * 16), .delta_ns = 16_000_000, .logical_extent = .{ .width = 3840, .height = 2160 }, .physical_extent = .{ .width = 3840, .height = 2160 }, .content_scale = 1 });
        defer frame_ctx.deinit();
        const root: Rect = .{ .key = .str("test.flood.root"), .style = &.{ .width = .fixed(3840), .height = .fixed(2160) } };
        _ = try root.open(&frame_ctx);
        try reader.render(&frame_ctx, &fonts, &background, &anki);
        try root.close(&frame_ctx);
        const output = try ui_context.endFrame(&frame_ctx);
        // The viewport contains many thousands of glyphs at the minimum font.
        // Semantics must scale with paragraphs, not with those glyphs.
        try std.testing.expect(output.accessibility.nodes.len < 2048);
        // Virtualization must preserve the complete source text.
        try std.testing.expectEqual(@as(usize, 100), reader.lines.items.len);
        try std.testing.expectEqual(@as(usize, 20000), reader.lines.items[99].text.len);
    }
}

test "hook history preview reader scrolls its full document in every reading direction" {
    for ([_]@import("components/reader/reading_layout.zig").Direction{ .horizontal, .vertical_left, .vertical_right, .horizontal }, 0..) |direction, mode| {
        var ui_context = try ui.Context.init(std.testing.allocator, .{ .ui = .{ .fonts = &.{.{ .name = "default", .data = @embedFile("fonts/jp.ttf") }} } });
        defer ui_context.deinit();
        var reader: Reader = .{ .dictionaries = .{}, .direction = direction };
        defer reader.deinit();
        var long: std.ArrayList(u8) = .empty;
        defer long.deinit(alloc);
        for (0..200) |_| try long.appendSlice(alloc, "日本語の文章");
        try reader.append(long.items);
        for (0..200) |_| try reader.append("日本語の文章を読みながら辞書で調べます。画面を埋める文章の続きです。");
        reader.scroll_pending = 0;
        var fonts: FontSettings = .{};
        if (mode == 3) fonts.character_spacing = 1;
        var background: BackgroundImage = .{};
        background.appearance.direction = direction;
        var anki: AnkiSettings = .{ .gpa = std.testing.allocator };
        const axis: usize = if (direction == .horizontal) 1 else 0;
        var wheel_start: f32 = 0;
        var saved_anchor: ?@import("components/reader/reader_document.zig").Anchor = null;
        for (0..10) |phase| {
            if ((phase >= 3 and phase <= 7) or phase == 9) {
                const viewport = ui_context.ui.state.get(.measured, ui.Key.str("reader.log").hash()).?.*;
                const content = ui_context.ui.state.get(.measured, ui.Key.str("reader.content").hash()).?.*;
                const maximum = if (axis == 1) content.height + 32 - viewport.height else content.width + 32 - viewport.width;
                const target = switch (phase) {
                    3, 7, 9 => maximum / 2,
                    4, 5 => maximum,
                    else => 0,
                };
                const scroll = ui_context.ui.state.get(.scroll, ui.Key.str("reader.log").hash()).?;
                if (axis == 1) scroll.offset[1] = target else scroll.offset[0] = target;
                if (phase == 7) wheel_start = target;
                if (phase == 9) {
                    saved_anchor = reader.document.anchor(target, direction == .vertical_right);
                    reader.scroll_pending = 0;
                    reader.near_bottom = false;
                    try reader.append("新しい文章が届いても読んでいる位置を保ちます。");
                    try std.testing.expectEqual(@as(u8, 0), reader.scroll_pending);
                }
            }
            var pointer: [2]f32 = .{ 0, 0 };
            if (phase == 7) {
                const viewport = ui_context.ui.state.get(.measured, ui.Key.str("reader.log").hash()).?.*;
                pointer = .{ viewport.box.x() + viewport.width / 2, viewport.box.y() + viewport.height / 2 };
            }
            reader.shift_selection.pointer = pointer;
            var frame_ctx = try ui_context.beginFrame(.{ .input = .{ .pos = .{ pointer[0], pointer[1] }, .scroll = .{ .pixel = .{ 0, if (phase == 7) @as(f32, 100) else 0 } } }, .now_ms = @intCast(phase * 16), .delta_ns = 16_000_000, .logical_extent = .{ .width = 1400, .height = 900 }, .physical_extent = .{ .width = 1400, .height = 900 }, .content_scale = 1 });
            defer frame_ctx.deinit();
            if (phase == 8) {
                reader.scroll_pending = 2;
                reader.tick(&frame_ctx);
            }
            const root: Rect = .{ .key = .str("test.document.root"), .style = &.{ .width = .fixed(1400), .height = .fixed(900), .direction = .row } };
            _ = try root.open(&frame_ctx);
            try reader.render(&frame_ctx, &fonts, &background, &anki);
            try root.close(&frame_ctx);
            _ = try ui_context.endFrame(&frame_ctx);
            try std.testing.expectEqual(@as(usize, if (phase == 9) 202 else 201), reader.document.entries.items.len);
            try std.testing.expectEqualStrings(long.items, reader.document.entries.items[0].text);
            if (phase < 2) continue;
            const viewport = ui_context.ui.state.get(.measured, ui.Key.str("reader.log").hash()).?.*;
            const content = ui_context.ui.state.get(.measured, ui.Key.str("reader.content").hash()).?.*;
            try std.testing.expect(viewport.width > 1200);
            try std.testing.expect(viewport.height > 700);
            try std.testing.expect(if (axis == 1) content.height > viewport.height * 5 else content.width > viewport.width * 5);
            if (phase == 4) {
                const offset = ui_context.ui.state.getScroll(ui.Key.str("reader.log").hash());
                try std.testing.expect(offset[axis] > 0);
                const end_id = if (direction == .vertical_right) reader.lines.items[0].id else reader.lines.items[200].id;
                try std.testing.expect(ui_context.ui.layout_ctx.slotForId(ui.Key.str("reader.placement").indexed(end_id).hash()) != null);
            }
            if (phase == 6) {
                const start_id = if (direction == .vertical_right) reader.lines.items[200].id else reader.lines.items[0].id;
                try std.testing.expect(ui_context.ui.layout_ctx.slotForId(ui.Key.str("reader.placement").indexed(start_id).hash()) != null);
            }
            if (phase == 7) {
                const offset = ui_context.ui.state.getScroll(ui.Key.str("reader.log").hash());
                try std.testing.expect(if (direction == .vertical_right) offset[axis] < wheel_start else offset[axis] > wheel_start);
            }
            if (phase == 8) {
                const offset = ui_context.ui.state.getScroll(ui.Key.str("reader.log").hash());
                try std.testing.expect(if (direction == .vertical_right) offset[axis] == 0 else offset[axis] > wheel_start);
                try std.testing.expect(ui_context.ui.layout_ctx.slotForId(ui.Key.str("reader.placement").indexed(reader.lines.items[200].id).hash()) != null);
            }
            if (phase == 9) {
                const saved = saved_anchor.?;
                const offset = ui_context.ui.state.getScroll(ui.Key.str("reader.log").hash());
                const i = reader.document.indices.get(saved.id).?;
                try std.testing.expectApproxEqAbs(saved.screen, reader.document.position(i, direction == .vertical_right) - offset[axis], 0.1);
            }
        }
    }
}

test "hook history preview and reader survive layout state growth" {
    var ui_context = try ui.Context.init(std.testing.allocator, .{
        .ui = .{ .fonts = &.{.{ .name = "default", .data = @embedFile("fonts/jp.ttf") }} },
    });
    defer ui_context.deinit();
    // No app initialization, persistent files, native injection or network requests.
    var self: Self = undefined;
    self.threads = .empty;
    self.selected = null;
    self.selected_candidate = null;
    self.store = .{ .alloc = alloc, .path = undefined };
    self.expanded_hook = null;
    self.enabled_hooks = .empty;
    self.search_filters = .{};
    self.reader.options = .{};
    self.candidates = .empty;
    self.sel_hint = null;
    self.next_line_id = 0;
    defer {
        for (self.threads.items) |*thread| thread.deinit();
        self.threads.deinit(alloc);
        self.clearCandidates();
        self.candidates.deinit(alloc);
    }
    const thread = try self.ensureThread(.{ .pid = 42, .handle = 7, .addr = 0, .ctx = 0, .ctx2 = 0, .name = @constCast("GetGlyphOutlineA"), .hook_code = @constCast("HS0@1234") });
    try self.pushLine(thread, "Captured before selecting this hook");
    try self.pushCandidate(thread.pid, thread.code, "Captured before selecting this hook", thread.handle);
    self.selected_candidate = 0;
    try std.testing.expect(self.selected == null);
    try std.testing.expect(!thread.accepted);
    var reader: Reader = .{ .dictionaries = .{} };
    defer reader.deinit();
    var fonts: FontSettings = .{};
    var background: BackgroundImage = .{};
    var anki: AnkiSettings = .{ .gpa = std.testing.allocator };
    const directions = [_]@import("components/reader/reading_layout.zig").Direction{ .horizontal, .vertical_left, .vertical_right, .horizontal };
    for (directions, 0..) |direction, iteration| {
        // New entries force the measured-state hash map to grow during rendering.
        for (0..64) |_| try reader.append("日本語のテキスト");
        background.appearance.direction = direction;
        fonts.character_spacing = if (iteration == 3) 1 else 0;
        var frame_ctx = try ui_context.beginFrame(.{ .input = .{ .pos = .{ 0, 0 } }, .now_ms = @intCast(iteration * 16), .delta_ns = 16_000_000, .logical_extent = .{ .width = 1100, .height = 760 }, .physical_extent = .{ .width = 1100, .height = 760 }, .content_scale = 1 });
        defer frame_ctx.deinit();
        const root: Rect = .{ .key = .str("test.root"), .style = &.{ .width = .fixed(1100), .height = .fixed(760), .direction = .row } };
        _ = try root.open(&frame_ctx);
        const sidebar: Rect = .{ .key = .str("test.sidebar"), .style = &.{ .width = .fixed(360), .height = .grow(), .direction = .column } };
        _ = try sidebar.open(&frame_ctx);
        try (HookPreview{ .self = &self }).render(&frame_ctx);
        try sidebar.close(&frame_ctx);
        try reader.render(&frame_ctx, &fonts, &background, &anki);
        try root.close(&frame_ctx);
        const output = try ui_context.endFrame(&frame_ctx);
        var found_sample = false;
        for (output.accessibility.nodes) |node| {
            if (node.state.value_text) |value| {
                if (std.mem.eql(u8, value, "Captured before selecting this hook")) found_sample = true;
            }
        }
        try std.testing.expect(found_sample);
    }
}

test "hook history preview settings show saved hooks and grouped processes at responsive widths" {
    var ui_context = try ui.Context.init(std.testing.allocator, .{
        .ui = .{ .fonts = &.{.{ .name = "default", .data = @embedFile("fonts/jp.ttf") }} },
    });
    defer ui_context.deinit();
    var self: Self = undefined;
    self.gpa = std.testing.allocator;
    self.store = .{ .alloc = alloc, .path = try alloc.allocSentinel(u16, 0, 0) };
    defer self.store.deinit();
    try self.store.parseLine("C:\\Games\\ClosedGame.exe , HS0@1234 , |0:0:HS0@1234");
    const Win32 = struct {
        extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
    };
    const current_pid = Win32.GetCurrentProcessId();
    const current_exe = try procs.exePath(alloc, current_pid);
    defer alloc.free(current_exe);
    try self.store.addCode(current_exe, "HS0@5678");
    self.proc_list = @constCast(&[_]procs.Proc{
        .{ .pid = 10, .name = @constCast("browser.exe"), .attachable = true, .is_32bit = false },
        .{ .pid = 11, .name = @constCast("browser.exe"), .attachable = true, .is_32bit = false },
        .{ .pid = 12, .name = @constCast("system.exe"), .attachable = true, .is_32bit = false, .is_system = true },
    });
    self.show_system_processes = false;
    self.expanded_process = null;
    self.attached = .empty;
    defer self.attached.deinit(alloc);
    self.threads = .empty;
    self.selected = null;
    self.selected_candidate = null;
    self.search_filters = .{};
    self.reader.options = .{};
    self.candidates = .empty;
    self.enabled_hooks = .empty;
    self.status = "";
    self.search_cp = 65001;
    self.search_running = false;
    self.expanded_hook = null;
    self.search_filters = .{};
    self.reader.options = .{};
    self.hook_draft = .empty;
    self.search_draft = .empty;
    defer self.hook_draft.deinit(self.gpa);
    defer self.search_draft.deinit(self.gpa);
    for ([_]u32{ 1100, 1920, 800 }, 0..) |width, iteration| {
        if (iteration == 1) {
            self.expanded_process = 10;
            try self.attached.append(alloc, current_pid);
        }
        if (iteration == 2) {
            self.show_system_processes = true;
            self.attached.clearRetainingCapacity();
            self.store.removeCode("C:\\Games\\ClosedGame.exe", "HS0@1234");
            try std.testing.expect(self.store.entries.items[0].sel == null);
        }
        var frame_ctx = try ui_context.beginFrame(.{ .input = .{ .pos = .{ 0, 0 } }, .now_ms = @intCast(iteration * 16), .delta_ns = 16_000_000, .logical_extent = .{ .width = width, .height = 900 }, .physical_extent = .{ .width = width, .height = 900 }, .content_scale = 1 });
        defer frame_ctx.deinit();
        const root: Rect = .{ .key = .str("test.settings.root"), .style = &.{ .width = .fixed(@as(f32, @floatFromInt(width)) * 0.75), .height = .fixed(760), .direction = .column } };
        _ = try root.open(&frame_ctx);
        try (TextractorSettings{ .self = &self }).render(&frame_ctx);
        try root.close(&frame_ctx);
        const output = try ui_context.endFrame(&frame_ctx);
        var remove_buttons: usize = 0;
        var browser_groups: usize = 0;
        var system_visible = false;
        var subprocess_visible = false;
        for (output.accessibility.nodes) |node| {
            if (std.mem.eql(u8, node.name, "Remove saved hook")) remove_buttons += 1;
            if (std.mem.indexOf(u8, node.name, "browser.exe  (2 processes)") != null) browser_groups += 1;
            if (std.mem.indexOf(u8, node.name, "system.exe") != null) system_visible = true;
            if (std.mem.indexOf(u8, node.name, "[11]") != null) subprocess_visible = true;
        }
        try std.testing.expectEqual(@as(usize, if (iteration == 1) 1 else 0), remove_buttons);
        try std.testing.expectEqual(@as(usize, 1), browser_groups);
        try std.testing.expectEqual(iteration == 2, system_visible);
        try std.testing.expectEqual(iteration != 0, subprocess_visible);
    }
}

test "hook history preview built-in sources remain separate and feed only the selected reader source" {
    var self: Self = undefined;
    self.threads = .empty;
    self.store = .{ .alloc = alloc, .path = undefined };
    self.enabled_hooks = .empty;
    self.selected = null;
    self.selected_candidate = null;
    self.sel_hint = null;
    self.next_line_id = 0;
    self.status = "";
    self.reader = .{ .dictionaries = .{} };
    defer self.reader.deinit();
    defer {
        for (self.threads.items) |*thread| thread.deinit();
        self.threads.deinit(alloc);
    }
    const console: tx.ThreadMeta = .{ .pid = 0, .handle = 1, .addr = 0, .ctx = 0, .ctx2 = 0, .name = @constCast("Console"), .hook_code = @constCast("") };
    const clipboard: tx.ThreadMeta = .{ .pid = 0, .handle = 2, .addr = 0, .ctx = 0, .ctx2 = 0, .name = @constCast("Clipboard"), .hook_code = @constCast("") };
    try self.handleEvent(.{ .thread_created = console }, 0);
    try self.handleEvent(.{ .thread_created = clipboard }, 0);
    try self.handleEvent(.{ .text = .{ .meta = console, .text = @constCast("Unselected console") } }, 1);
    try std.testing.expect(self.selected == null);
    try std.testing.expectEqual(@as(usize, 0), self.reader.lines.items.len);
    self.selected = .{ .pid = 0, .handle = 2 };
    try self.handleEvent(.{ .text = .{ .meta = clipboard, .text = @constCast("Copied text") } }, 2);
    try self.handleEvent(.{ .text = .{ .meta = console, .text = @constCast("Console stays in preview") } }, 3);
    try std.testing.expectEqual(@as(usize, 1), self.reader.lines.items.len);
    try std.testing.expectEqualStrings("Copied text", self.reader.lines.items[0].text);
    var ui_context = try ui.Context.init(std.testing.allocator, .{ .ui = .{ .fonts = &.{.{ .name = "default", .data = @embedFile("fonts/jp.ttf") }} } });
    defer ui_context.deinit();
    var frame_ctx = try ui_context.beginFrame(.{ .input = .{ .pos = .{ 0, 0 } }, .now_ms = 0, .delta_ns = 16_000_000, .logical_extent = .{ .width = 440, .height = 280 }, .physical_extent = .{ .width = 440, .height = 280 }, .content_scale = 1 });
    defer frame_ctx.deinit();
    try (TextractorUI.ThreadList{ .self = &self }).render(&frame_ctx);
    const output = try ui_context.endFrame(&frame_ctx);
    var sources: usize = 0;
    for (output.accessibility.nodes) |node| {
        if (isBuiltin(node.name)) sources += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), sources);
}

test "hook history preview asset drop zones accept multiple paths only inside their own surface" {
    var context = try ui.Context.init(std.testing.allocator, .{ .ui = .{ .fonts = &.{.{ .name = "default", .data = @embedFile("fonts/jp.ttf") }} } });
    defer context.deinit();
    const paths = [_][]const u8{ "one.zip", "two.zip" };
    const dict_key: ui.Key = .str("test.drop.dictionaries");
    var pointer: [2]f32 = .{ -1, -1 };
    for (0..2) |iteration| {
        var frame_ctx = try context.beginFrame(.{ .input = .{ .pos = .{ pointer[0], pointer[1] } }, .now_ms = @intCast(iteration * 16), .delta_ns = 16_000_000, .logical_extent = .{ .width = 440, .height = 400 }, .physical_extent = .{ .width = 440, .height = 400 }, .content_scale = 1, .dropped_paths = if (iteration == 1) &paths else &.{} });
        defer frame_ctx.deinit();
        const root: Rect = .{ .key = .str("test.drop.root"), .style = &.{ .width = .fixed(440), .height = .fixed(400), .direction = .column } };
        _ = try root.open(&frame_ctx);
        const dict_paths = try @import("ui/drops.zig").renderPaths(&frame_ctx, pointer, dict_key, "Dictionaries");
        const font_paths = try @import("ui/drops.zig").renderPaths(&frame_ctx, pointer, .str("test.drop.fonts"), "Fonts");
        try root.close(&frame_ctx);
        try std.testing.expectEqual(@as(usize, 0), font_paths.len);
        if (iteration == 1) {
            try std.testing.expectEqual(@as(usize, 2), dict_paths.len);
            try std.testing.expectEqualStrings("two.zip", dict_paths[1]);
        }
        _ = try context.endFrame(&frame_ctx);
        const measured = context.ui.state.get(.measured, dict_key.hash()).?;
        pointer = .{ measured.box.x() + 10, measured.box.y() + 10 };
    }
}
