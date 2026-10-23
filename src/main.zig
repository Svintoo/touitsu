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
const TexthookingSidebar = SidebarUI.Sidebar;
const ReaderView = SidebarUI.ReaderView;
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

test {
    _ = @import("tests/ui/sidebar.zig");
    _ = @import("tests/main.zig").Tests(.{
        .ensureThread = ensureThread,
        .pushLine = pushLine,
        .pushCandidate = pushCandidate,
        .handleEvent = handleEvent,
        .acceptHook = acceptHook,
        .deinitThread = ThreadEntry.deinit,
    });
}
