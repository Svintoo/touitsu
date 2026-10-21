//! Textractor workspace: processes, active/saved hooks, search and previews.
const std = @import("std");
const ui = @import("ui");
const procs = @import("procs.zig");
const Rect = ui.component.Rect;
const Text = ui.component.Text;
const TextInput = ui.component.TextInput;
const TextractorButton = @import("project_button.zig");

const row_off: ui.Style = .{
    .width = .grow(),
    .height = .fixed(28),
    .padding = .xy(8, 0),
    .font_size = .sm,
    .background = .transparent,
    .foreground = .text,
    .hover = &.{ .background = .muted, .foreground = .text },
};
const row_on: ui.Style = .{
    .width = .grow(),
    .height = .fixed(28),
    .padding = .xy(8, 0),
    .font_size = .sm,
    .background = .muted,
    .foreground = .text,
};
const chip_off: ui.Style = .{
    .height = .fixed(28),
    .padding = .xy(10, 0),
    .font_size = .sm,
    .radius = .md,
    .background = .transparent,
    .foreground = .text,
    .hover = &.{ .background = .muted, .foreground = .text },
};
const chip_on: ui.Style = .{
    .height = .fixed(28),
    .padding = .xy(10, 0),
    .font_size = .sm,
    .radius = .md,
    .background = .muted,
    .foreground = .text,
};
const hook_remove_style: ui.Style = .{
    .width = .fixed(24),
    .height = .fixed(28),
    .padding = .all(0),
    .background = .transparent,
    .foreground = .text,
    .hover = &.{ .background = .accent, .foreground = .on_accent },
};
const panel: ui.Style = .{
    .width = .grow(),
    .height = .grow(),
    .direction = .column,
    .gap = 6,
    .padding = .all(12),
    .overflow = .scroll_y,
    .background = .bg,
    .radius = .md,
    .border_width = .all(1),
    .border_color = .toned,
};
pub const input_key: ui.Key = .str("hook.input");
const search_key: ui.Key = .str("search.input");
fn shortCode(code: []const u8) []const u8 {
    return code[0 .. std.mem.indexOfScalar(u8, code, '@') orelse code.len];
}

/// Copy `s` into the frame arena, replacing any invalid UTF-8 with U+FFFD. Knots keeps the
/// slice we hand it until the frame is drawn (after `frame` returns) and fails with
/// error.InvalidUtf8 on malformed text, so everything shown goes through here.
fn safeText(context: *ui.Frame, s: []const u8) []const u8 {
    const a = context.arena();
    var out = std.ArrayList(u8).initCapacity(a, s.len) catch return "";
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 0;
        if (n != 0 and i + n <= s.len and std.unicode.utf8ValidateSlice(s[i .. i + n])) {
            out.appendSlice(a, s[i .. i + n]) catch return "";
            i += n;
        } else {
            out.appendSlice(a, "\u{FFFD}") catch return "";
            i += 1;
        }
    }
    return out.items;
}

// App supplies hook state and actions; the native client stays outside the UI.
pub fn Components(comptime App: type) type {
    return struct {
        const Self = App;
        fn sampleText(self: *Self, context: *ui.Frame, text: []const u8) ![]const u8 {
            const filter = @import("hook_sample_filter.zig");
            const sample = try filter.clean(context.arena(), text, self.search_filters);
            if (!self.search_filters.unsupported) return sample;
            const face = try context.ui().font.getFace(null);
            var output: std.ArrayList(u8) = .empty;
            var iter = (try std.unicode.Utf8View.init(sample)).iterator();
            while (iter.nextCodepointSlice()) |bytes| {
                const cp = try std.unicode.utf8Decode(bytes);
                if (cp == '\n' or cp == '\r' or cp == '\t' or @backingInt(face.true_type.codepointGlyphIndex(cp)) != 0)
                    try output.appendSlice(context.arena(), bytes);
            }
            return output.items;
        }

        /// Wide Textractor workspace; other settings retain their compact sidebar.
        pub const Settings = struct {
            self: *Self,

            pub fn render(settings: *const Settings, context: *ui.Frame) anyerror!void {
                try (Status{ .self = settings.self }).render(context);
                const screen_width = context.input().logical_extent.width;
                const count: usize = if (screen_width >= 1000) 2 else 1;
                const columns: Rect = .{ .key = .str("textractor.columns"), .style = &.{ .width = .grow(), .height = .grow(), .direction = if (count == 1) .column else .row, .gap = 16, .overflow = if (count == 1) .scroll_y else .hidden } };
                _ = try columns.open(context);
                for (0..count) |index| {
                    const column: Rect = .{ .key = ui.Key.str("textractor.column").indexed(index), .style = &.{ .width = .grow(), .height = if (count == 1) .fit() else .grow(), .direction = .column, .gap = 10, .padding = .init(0, context.ui().theme.scrollbar_thickness + 8, 8, 0), .overflow = if (count == 1) .visible else .scroll_y } };
                    _ = try column.open(context);
                    if (index == 0) try settings.processes(context, count == 3);
                    if (count == 1 or (count == 2 and index == 0) or (count == 3 and index == 1)) try settings.hooks(context);
                    if (index + 1 == count) try settings.search(context);
                    try column.close(context);
                }
                try columns.close(context);
            }

            fn processes(settings: *const Settings, context: *ui.Frame, separate_column: bool) !void {
                const height: f32 = @floatFromInt(context.input().logical_extent.height);
                const list_height = @max(300, if (separate_column) height - 240 else height * 0.45);
                try context.e(.{
                    Text{ .key = .str("process.heading"), .content = "Processes", .selectable = false },
                    Toolbar{ .self = settings.self },
                    Rect{ .key = .str("process.panel"), .style = &panel.with(.{ .height = .fixed(list_height) }) },
                    .{ProcessList{ .self = settings.self }},
                });
            }

            fn hooks(settings: *const Settings, context: *ui.Frame) !void {
                try context.e(.{
                    Text{ .key = .str("active.heading"), .content = "Active hooks", .selectable = false },
                    Rect{ .key = .str("active.panel"), .style = &comptime panel.with(.{ .height = .fixed(260) }) },
                    .{ThreadList{ .self = settings.self }},
                    HookEntry{ .self = settings.self },
                    HookProcessing{ .self = settings.self },
                    SaveBar{ .self = settings.self },
                    Text{ .key = .str("saved.heading"), .content = "Saved hooks", .selectable = false },
                    Text{ .key = .str("saved.help"), .content = "Saved hooks for the attached game, loaded automatically next session.", .selectable = false, .style = &.{ .wrap = true, .font_size = .sm, .foreground = .dimmed } },
                    Rect{ .key = .str("saved.panel"), .style = &comptime panel.with(.{ .height = .fixed(260) }) },
                    .{SavedHooks{ .self = settings.self }},
                });
            }

            fn search(settings: *const Settings, context: *ui.Frame) !void {
                const height: f32 = @floatFromInt(context.input().logical_extent.height);
                try context.e(.{
                    Text{ .key = .str("search.heading"), .content = "Search for hooks", .selectable = false },
                    CodepageRow{ .self = settings.self },
                    SearchRow{ .self = settings.self },
                    SearchFilters{ .self = settings.self },
                    Rect{ .key = .str("search.panel"), .style = &panel.with(.{ .height = .fixed(@max(380, height * 0.55)) }) },
                    .{Candidates{ .self = settings.self }},
                    HookPreview{ .self = settings.self },
                    AddCandidate{ .self = settings.self },
                });
            }
        };

        const Toolbar = struct {
            self: *Self,

            pub fn render(bar: *const Toolbar, context: *ui.Frame) anyerror!void {
                if ((try context.interact(TextractorButton{ .key = .src(@src()), .label = "Refresh process list" })).clicked) {
                    bar.self.refreshProcs();
                    context.requestRedraw();
                }
                if ((try context.interact(ui.component.Checkbox{ .key = .str("process.show_system"), .label = "Show system processes", .checked = &bar.self.show_system_processes })).changed) context.requestRedraw();
            }
        };

        const ProcessList = struct {
            self: *Self,

            pub fn render(list: *const ProcessList, context: *ui.Frame) anyerror!void {
                const self = list.self;
                var start: usize = 0;
                while (start < self.proc_list.len) {
                    var end = start + 1;
                    while (end < self.proc_list.len and std.ascii.eqlIgnoreCase(self.proc_list[start].name, self.proc_list[end].name)) : (end += 1) {}
                    const group = self.proc_list[start..end];
                    start = end;
                    var count: usize = 0;
                    var first: ?procs.Proc = null;
                    var attached = false;
                    for (group) |p| {
                        if (!self.show_system_processes and p.is_system and !self.isAttached(p.pid)) continue;
                        if (first == null) first = p;
                        count += 1;
                        attached = attached or self.isAttached(p.pid);
                    }
                    const representative = first orelse continue;
                    if (count == 1) {
                        try renderProcess(self, context, representative, false);
                        continue;
                    }
                    const expanded = self.expanded_process == group[0].pid;
                    const label = safeText(context, try std.fmt.allocPrint(context.arena(), "{s} {s}  ({d} processes)", .{ if (expanded) "v" else ">", representative.name, count }));
                    if ((try context.interact(TextractorButton{ .key = ui.Key.str("process.group").indexed(group[0].pid), .label = label, .style = if (attached) &row_on else &row_off })).clicked) {
                        self.expanded_process = if (expanded) null else group[0].pid;
                        context.requestRedraw();
                    }
                    if (expanded) for (group) |p| {
                        if (!self.show_system_processes and p.is_system and !self.isAttached(p.pid)) continue;
                        try renderProcess(self, context, p, true);
                    };
                }
            }

            fn renderProcess(self: *Self, context: *ui.Frame, p: procs.Proc, nested: bool) !void {
                const label = safeText(context, try std.fmt.allocPrint(context.arena(), "{s}{s}  [{d}]  {s}", .{
                    if (nested) "    " else "", p.name, p.pid, if (p.is_32bit) "x86" else "x64",
                }));
                if ((try context.interact(TextractorButton{ .key = ui.Key.str("proc").indexed(p.pid), .label = label, .disabled = !p.attachable, .style = if (self.isAttached(p.pid)) &row_on else &row_off })).clicked) {
                    if (self.isAttached(p.pid)) self.detach(p.pid) else try self.attach(p.pid);
                    context.requestRedraw();
                }
            }
        };

        /// Show saved configuration for the most recently attached game.
        const SavedHooks = struct {
            self: *Self,
            pub fn render(saved: *const SavedHooks, context: *ui.Frame) anyerror!void {
                const self = saved.self;
                const exe = if (self.lastAttached()) |pid| procs.exePath(context.arena(), pid) catch null else null;
                var removal: ?struct { game: usize, hook: usize } = null;
                var count: usize = 0;
                for (self.store.entries.items, 0..) |entry, game_index| {
                    if (!std.ascii.eqlIgnoreCase(entry.exe, exe orelse continue)) continue;
                    if (entry.codes.items.len == 0) continue;
                    try context.e(Text{ .key = ui.Key.str("saved.game").indexed(game_index), .content = safeText(context, entry.exe), .style = &.{ .width = .grow(), .wrap = true, .font_size = .sm, .foreground = .dimmed } });
                    for (entry.codes.items, 0..) |code, hook_index| {
                        count += 1;
                        const row_key = ui.Key.str("saved.hook").indexed(game_index).indexed(hook_index);
                        const row: Rect = .{ .key = row_key, .style = &.{ .width = .grow(), .direction = .row, .gap = 6, .@"align" = .center } };
                        _ = try row.open(context);
                        // The store can change below; Knots borrows text through endFrame.
                        try context.e(Text{ .key = row_key.indexed(1), .content = safeText(context, code), .style = &.{ .width = .grow(), .wrap = true, .font_size = .sm } });
                        const button: TextractorButton = .{ .key = row_key.indexed(2), .label = "x", .style = &hook_remove_style };
                        const response = try button.openResponse(context);
                        try button.close(context);
                        try context.ui().setAccessibility(response.id, .{ .role = .button, .name = "Remove saved hook" });
                        if (response.clicked) removal = .{ .game = game_index, .hook = hook_index };
                        try row.close(context);
                    }
                }
                if (count == 0) try context.e(Text{ .key = .str("saved.empty"), .content = if (self.lastAttached() == null) "Attach to a game to see its saved hooks." else if (exe == null) "Couldn't read the attached game's path." else "No saved hooks for this game. Add a search result, then save the active hook.", .selectable = false, .style = &.{ .width = .grow(), .wrap = true, .foreground = .dimmed, .font_size = .sm } });
                if (removal) |item| {
                    const entry = &self.store.entries.items[item.game];
                    self.store.removeCode(entry.exe, entry.codes.items[item.hook]);
                    self.store.save() catch |err| {
                        self.setStatus("Couldn't update saved hooks: {s}", .{@errorName(err)});
                        return;
                    };
                    self.setStatus("Removed saved hook. Active extraction is unchanged.", .{});
                    context.requestRedraw();
                }
            }
        };

        pub const ThreadList = struct {
            self: *Self,
            pub fn render(list: *const ThreadList, context: *ui.Frame) anyerror!void {
                const self = list.self;
                // Built-in sources are always available, independently of game hook codes.
                for (self.threads.items, 0..) |*thread, index| {
                    if (!App.isBuiltin(thread.name) or thread.removed) continue;
                    const active = if (self.selected) |selected| selected.pid == thread.pid and selected.handle == thread.handle else false;
                    if ((try context.interact(TextractorButton{ .key = ui.Key.str("builtin.thread").indexed(index), .label = thread.name, .style = if (active) &row_on else &row_off })).clicked) {
                        self.selected = .{ .pid = thread.pid, .handle = thread.handle };
                        self.selected_candidate = null;
                        self.user_chose = true;
                    }
                }
                for (self.threads.items, 0..) |*first, index| {
                    if (App.isBuiltin(first.name) or !first.accepted or first.removed) continue;
                    var duplicate = false;
                    for (self.threads.items[0..index]) |prior| {
                        if (prior.accepted and !prior.removed and prior.pid == first.pid and std.mem.eql(u8, prior.code, first.code)) {
                            duplicate = true;
                            break;
                        }
                    }
                    if (duplicate) continue;
                    var representative = first;
                    var streams: usize = 0;
                    for (self.threads.items) |*thread| {
                        if (!thread.accepted or thread.removed or thread.pid != first.pid or !std.mem.eql(u8, thread.code, first.code)) continue;
                        streams += 1;
                        if (self.selected) |selected| {
                            if (selected.pid == thread.pid and selected.handle == thread.handle) representative = thread;
                        }
                    }
                    const row: Rect = .{ .key = ui.Key.str("active.hook.row").indexed(index), .style = &.{ .width = .grow(), .direction = .row, .gap = 4 } };
                    _ = try row.open(context);
                    const active = if (self.selected) |selected| selected.pid == representative.pid and selected.handle == representative.handle else false;
                    const label = try std.fmt.allocPrint(context.arena(), "{s} ({d} streams)", .{ representative.name, streams });
                    if ((try context.interact(TextractorButton{ .key = ui.Key.str("thread").indexed(index), .label = label, .style = if (active) &row_on else &row_off })).clicked) {
                        self.selected = .{ .pid = representative.pid, .handle = representative.handle };
                        self.selected_candidate = null;
                        self.user_chose = true;
                        self.rememberSelection(representative);
                    }
                    if (streams > 1) {
                        if ((try context.interact(TextractorButton{ .key = ui.Key.str("active.hook.streams").indexed(index), .label = "Streams" })).clicked)
                            self.expanded_hook = if (self.expanded_hook == first.handle) null else first.handle;
                    }
                    if ((try context.interact(TextractorButton{ .key = ui.Key.str("active.hook.remove").indexed(index), .label = "x", .style = &hook_remove_style })).clicked) self.removeHook(first);
                    try row.close(context);
                    if (self.expanded_hook != first.handle) continue;
                    for (self.threads.items, 0..) |*thread, stream_index| {
                        if (!thread.accepted or thread.removed or thread.pid != first.pid or !std.mem.eql(u8, thread.code, first.code)) continue;
                        const chosen = if (self.selected) |selected| selected.pid == thread.pid and selected.handle == thread.handle else false;
                        const stream_label = try std.fmt.allocPrint(context.arena(), "Context {X}:{X} ({d} lines)", .{ thread.ctx, thread.ctx2, thread.lines.items.len });
                        if ((try context.interact(TextractorButton{ .key = ui.Key.str("active.hook.stream").indexed(stream_index), .label = stream_label, .style = if (chosen) &row_on else &row_off })).clicked) {
                            self.selected = .{ .pid = thread.pid, .handle = thread.handle };
                            self.selected_candidate = null;
                            self.user_chose = true;
                            self.rememberSelection(thread);
                        }
                    }
                }
            }
        };

        /// Inspect captured history immediately, without adding another hook's old text to the reader.
        pub const HookPreview = struct {
            self: *Self,

            pub fn render(preview: *const HookPreview, context: *ui.Frame) anyerror!void {
                const self = preview.self;
                try context.e(Text{ .key = .src(@src()), .content = "Selected hook preview", .selectable = false });
                var selection = self.selected;
                if (self.selected_candidate) |index| {
                    if (index < self.candidates.items.len) {
                        const candidate = self.candidates.items[index];
                        if (candidate.thread_handle) |handle| {
                            selection = .{ .pid = candidate.pid, .handle = handle };
                        } else {
                            try context.e(Text{ .key = .src(@src()), .content = safeText(context, shortCode(candidate.code)), .style = &.{ .wrap = true, .font_size = .sm, .foreground = .dimmed } });
                            const sample_box: Rect = .{ .key = .str("candidate.preview"), .style = &comptime panel.with(.{ .height = .fixed(260) }) };
                            _ = try sample_box.open(context);
                            try context.e(Text{ .key = .str("candidate.preview.text"), .content = try sampleText(self, context, candidate.text), .style = &.{ .width = .grow(), .wrap = true } });
                            try sample_box.close(context);
                            return;
                        }
                    }
                }
                const selected = selection orelse {
                    try context.e(Text{ .key = .src(@src()), .content = "Select a search result to inspect its text, then add it if it looks correct.", .selectable = false, .style = &.{ .wrap = true } });
                    return;
                };
                const thread = self.findThread(selected.pid, selected.handle) orelse return;
                try context.e(Text{ .key = .src(@src()), .content = safeText(context, try std.fmt.allocPrint(context.arena(), "{s} [{d}]\n{s}\nContext {X}:{X}", .{ thread.name, thread.pid, shortCode(thread.code), thread.ctx, thread.ctx2 })), .style = &.{ .font_size = .sm, .foreground = .dimmed, .wrap = true } });
                // Separate scroll state per thread; newest samples appear first for live inspection.
                const box: Rect = .{ .key = ui.Key.str("hook.preview").indexed(thread.pid).indexed(@intCast(thread.handle)), .style = &comptime panel.with(.{ .height = .fixed(260) }) };
                _ = try box.open(context);
                if (thread.lines.items.len == 0) {
                    try context.e(Text{ .key = .src(@src()), .content = "No text captured yet. Advance the game while this hook is active.", .selectable = false, .style = &.{ .wrap = true, .font_size = .sm, .foreground = .dimmed } });
                } else {
                    for (0..thread.lines.items.len) |offset| {
                        const line = thread.lines.items[thread.lines.items.len - 1 - offset];
                        try context.e(Text{ .key = ui.Key.str("hook.preview.line").indexed(line.id), .content = try sampleText(self, context, if (thread.reduce_pairs) try @import("hook_sample_filter.zig").reducePairs(context.arena(), line.text) else line.text), .style = &.{ .width = .grow(), .wrap = true, .font_size = .sm } });
                    }
                }
                try box.close(context);
            }
        };

        /// Manual hook code (Textractor /H syntax), applied to the most recently attached process.
        const HookEntry = struct {
            self: *Self,

            pub fn render(entry: *const HookEntry, context: *ui.Frame) anyerror!void {
                const self = entry.self;
                const row: Rect = .{ .key = .src(@src()), .style = &.{ .width = .grow(), .direction = .row, .gap = 8, .@"align" = .center } };
                _ = try row.open(context);
                const submit_on_enter = context.ui().focused(input_key.hash()) and context.ui().input.keyPressed(.enter);
                try context.e(TextInput{ .key = input_key, .buf = &self.hook_draft, .placeholder = "HS65001#-3C@193BA0:game.exe", .style = &.{ .radius = .md } });
                const clicked = (try context.interact(TextractorButton{ .key = .src(@src()), .label = "Add hook" })).clicked;
                if (submit_on_enter or clicked) {
                    self.insertHook();
                    context.requestRedraw();
                }
                try row.close(context);
            }
        };

        const HookProcessing = struct {
            self: *Self,
            pub fn render(control: *const HookProcessing, context: *ui.Frame) anyerror!void {
                const selected = control.self.selected orelse return;
                const thread = control.self.findThread(selected.pid, selected.handle) orelse return;
                try context.e(Text{ .key = .str("hook.processing.title"), .content = "Selected hook post-processing", .selectable = false });
                var enabled = thread.reduce_pairs;
                if ((try context.interact(ui.component.Checkbox{ .key = .str("hook.processing.pairs"), .label = "Reduce doubled characters", .checked = &enabled })).changed) {
                    control.self.setHookPairs(thread, enabled);
                    context.requestRedraw();
                }
            }
        };

        const SaveBar = struct {
            self: *Self,

            pub fn render(bar: *const SaveBar, context: *ui.Frame) anyerror!void {
                const self = bar.self;
                const row: Rect = .{ .key = .src(@src()), .style = &.{ .width = .grow(), .direction = .row, .gap = 8 } };
                _ = try row.open(context);
                if ((try context.interact(TextractorButton{ .key = .src(@src()), .label = "Save selected hook", .disabled = self.selected == null })).clicked) {
                    self.saveSelected();
                    context.requestRedraw();
                }
                if ((try context.interact(TextractorButton{ .key = .src(@src()), .label = "Forget game" })).clicked) {
                    self.forgetSaved();
                    context.requestRedraw();
                }
                try row.close(context);
            }
        };

        const Status = struct {
            self: *Self,

            pub fn render(s: *const Status, context: *ui.Frame) anyerror!void {
                const self = s.self;
                const text = if (self.status.len == 0) "Pick a process on the left to attach." else safeText(context, self.status);
                try context.e(Text{ .key = .src(@src()), .content = text, .style = &.{ .font_size = .sm, .foreground = .dimmed }, .selectable = false });
            }
        };

        /// Which encoding the search should look for. Pick the one the game stores its text in
        /// (modern engines: UTF-8; older Japanese games: Shift-JIS).
        const CodepageRow = struct {
            self: *Self,

            const Option = struct { label: []const u8, cp: u32 };
            const options = [_]Option{
                .{ .label = "Shift-JIS", .cp = 932 },
                .{ .label = "UTF-8", .cp = 65001 },
                .{ .label = "GBK", .cp = 936 },
            };

            pub fn render(r: *const CodepageRow, context: *ui.Frame) anyerror!void {
                const self = r.self;
                const row: Rect = .{ .key = .src(@src()), .style = &.{ .width = .grow(), .direction = .row, .gap = 6, .@"align" = .center } };
                _ = try row.open(context);
                try context.e(Text{ .key = .src(@src()), .content = "Encoding:", .style = &.{ .font_size = .sm, .foreground = .dimmed }, .selectable = false });
                for (options) |opt| {
                    const res = try context.interact(TextractorButton{
                        .key = ui.Key.str("cp").indexed(opt.cp),
                        .label = opt.label,
                        .style = if (self.search_cp == opt.cp) &chip_on else &chip_off,
                    });
                    if (res.clicked) {
                        self.search_cp = opt.cp;
                        context.requestRedraw();
                    }
                }
                try row.close(context);
            }
        };

        const SearchRow = struct {
            self: *Self,

            pub fn render(r: *const SearchRow, context: *ui.Frame) anyerror!void {
                const self = r.self;
                try context.e(Text{ .key = search_key.indexed(100), .content = "Search for hooks of text appearing ingame", .selectable = false, .style = &.{ .width = .grow(), .wrap = true } });
                try context.e(TextInput{ .key = search_key, .buf = &self.search_draft, .style = &.{ .width = .grow(), .radius = .md } });
                const row: Rect = .{ .key = .src(@src()), .style = &.{ .width = .grow(), .direction = .row, .gap = 8, .@"align" = .center } };
                _ = try row.open(context);
                if ((try context.interact(TextractorButton{ .key = .src(@src()), .label = if (self.search_running) "Searching..." else "Search", .disabled = self.search_running })).clicked) {
                    self.startSearch(context.input().now_ms);
                    context.requestRedraw();
                }
                if ((try context.interact(TextractorButton{ .key = .src(@src()), .label = "Clear" })).clicked) {
                    self.clearCandidates();
                    context.requestRedraw();
                }
                try row.close(context);
            }
        };

        const SearchFilters = struct {
            self: *Self,
            pub fn render(filters: *const SearchFilters, context: *ui.Frame) anyerror!void {
                inline for (.{
                    .{ "controls", "Hide null / control characters" },
                    .{ "invalid", "Hide invalid / replacement characters" },
                    .{ "private_use", "Hide private-use characters" },
                    .{ "unsupported", "Hide characters missing from UI font" },
                    .{ "japanese_only", "Japanese samples only" },
                }) |option| {
                    if ((try context.interact(ui.component.Checkbox{ .key = .str("search.filter." ++ option[0]), .label = option[1], .checked = &@field(filters.self.search_filters, option[0]) })).changed) context.requestRedraw();
                }
            }
        };

        /// Discovery is separate from activation: clicking a candidate only previews it.
        const Candidates = struct {
            self: *Self,

            pub fn render(c: *const Candidates, context: *ui.Frame) anyerror!void {
                const self = c.self;
                for (self.candidates.items, 0..) |cand, i| {
                    const sample = try sampleText(self, context, cand.text);
                    if (std.mem.trim(u8, sample, " \t\r\n").len == 0) continue;
                    if (self.search_filters.japanese_only and !@import("hook_sample_filter.zig").hasJapanese(sample)) continue;
                    const label = safeText(context, try std.fmt.allocPrint(context.arena(), "{s}\n{s}", .{ shortCode(cand.code), sample }));
                    const res = try context.interact(TextractorButton{
                        .key = ui.Key.str("cand").indexed(i),
                        .label = label,
                        .style = &(if (self.selected_candidate == i) row_on else row_off).with(.{ .height = .fit(), .padding = .all(8), .overflow = .hidden, .justify = .start }),
                        .parts = .{ .label = &.{ .width = .grow(), .wrap = true } },
                    });
                    if (res.clicked) {
                        self.selected_candidate = i;
                        context.requestRedraw();
                    }
                }
            }
        };

        const AddCandidate = struct {
            self: *Self,
            pub fn render(action: *const AddCandidate, context: *ui.Frame) anyerror!void {
                const self = action.self;
                var disabled = true;
                if (self.selected_candidate) |index| {
                    if (index < self.candidates.items.len) {
                        const candidate = self.candidates.items[index];
                        disabled = !self.isAttached(candidate.pid);
                        for (self.enabled_hooks.items) |hook| {
                            if (hook.pid == candidate.pid and std.mem.eql(u8, hook.code, candidate.code)) disabled = true;
                        }
                    }
                }
                if ((try context.interact(TextractorButton{ .key = .str("candidate.add"), .label = "Add selected hook", .disabled = disabled })).clicked) {
                    if (self.selected_candidate) |index| {
                        if (index < self.candidates.items.len) self.useCandidate(self.candidates.items[index]);
                    }
                    context.requestRedraw();
                }
            }
        };
    };
}
