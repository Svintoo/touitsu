const std = @import("std");
const ui = @import("ui");
const disk = @import("reader_store.zig");
const SelectionPopup = @import("selection_popup.zig");
const ShiftSelection = @import("shift_selection.zig");
const DictionaryUI = @import("dictionary_ui.zig");
const FontSettings = @import("font_settings.zig");
const BackgroundImage = @import("background_image.zig");
const flow = @import("reading_layout.zig");
const VerticalReader = @import("vertical_reader.zig");
const limits = @import("capture_limits.zig");
const a = std.heap.smp_allocator;
const Text = ui.component.Text;
const Rect = ui.component.Rect;
const Button = @import("project_button.zig");
const isWhitespace = @import("reader_text.zig").isWhitespace;
const isSpecial = @import("reader_text.zig").isSpecial;
const Options = struct {
    show_counts: bool = true,
    show_timer: bool = true,
    overlay_counts: bool = false,
    remove_whitespace: bool = false,
    near_end_only: bool = true,
    store_lines: bool = true,
    exclude_special: bool = false,
    select_line: bool = false,
    word_selection: bool = true,
    autohide: bool = false,
};
const key: ui.Key = .str("reader.log");
const Line = struct { id: usize, text: []u8 };
const Deleted = struct { index: usize, line: Line };
const Snapshot = struct { lines: []const []const u8, elapsed_ms: u64, options: Options = .{} };

lines: std.ArrayList(Line) = .empty,
undo: std.ArrayList(Deleted) = .empty,
next_id: usize = 0,
page_end: ?usize = null,
elapsed_ms: u64 = 0,
last_ms: ?i64 = null,
paused: bool = true,
near_bottom: bool = true,
direction: flow.Direction = .horizontal,
scroll_pending: u8 = 2,
path: ?[:0]u16 = null,
save_error: bool = false,
options: Options = .{},
controls_hidden: bool = false,
unfocused_since_ms: ?i64 = null,
dictionaries: DictionaryUI,
shift_selection: ShiftSelection = .{},
const Self = @This();

pub fn init(io: std.Io) Self {
    var self: Self = .{ .dictionaries = DictionaryUI.init(io) };
    self.path = disk.defaultPath(a) catch return self;
    const bytes = (disk.readAll(a, self.path.?) catch {
        self.save_error = true;
        return self;
    }) orelse return self;
    defer a.free(bytes);
    const parsed = std.json.parseFromSlice(Snapshot, a, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch {
        self.save_error = true;
        return self;
    };
    defer parsed.deinit();
    self.options = parsed.value.options;
    self.elapsed_ms = parsed.value.elapsed_ms;
    for (if (self.options.store_lines) parsed.value.lines else &.{}) |text| self.append(text) catch {
        self.save_error = true;
        break;
    };
    return self;
}

pub fn deinit(self: *Self) void {
    self.dictionaries.deinit();
    self.save();
    for (self.lines.items) |line| a.free(line.text);
    self.lines.deinit(a);
    for (self.undo.items) |item| a.free(item.line.text);
    self.undo.deinit(a);
    if (self.path) |path| a.free(path);
}

pub fn append(self: *Self, text: []const u8) !void {
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return;
    var filtered: std.ArrayList(u8) = .empty;
    defer filtered.deinit(a);
    if (self.options.remove_whitespace) {
        const view = std.unicode.Utf8View.init(text) catch return;
        var it = view.iterator();
        while (it.nextCodepointSlice()) |bytes| {
            if (!isWhitespace(try std.unicode.utf8Decode(bytes))) try filtered.appendSlice(a, bytes);
        }
    }
    const incoming = if (self.options.remove_whitespace) filtered.items else text;
    if (incoming.len == 0) return;
    const copy = try a.dupe(u8, incoming);
    errdefer a.free(copy);
    try self.lines.append(a, .{ .id = self.next_id, .text = copy });
    self.next_id += 1;
    if (!self.options.near_end_only or self.near_bottom) self.scroll_pending = 2;
}

pub fn save(self: *Self) void {
    const path = self.path orelse {
        self.save_error = true;
        return;
    };
    const texts = a.alloc([]const u8, (if (self.options.store_lines) self.lines.items.len else 0)) catch {
        self.save_error = true;
        return;
    };
    defer a.free(texts);
    for (texts, 0..) |*text, i| text.* = self.lines.items[i].text;
    const bytes = std.json.Stringify.valueAlloc(a, Snapshot{ .lines = texts, .elapsed_ms = self.elapsed_ms, .options = self.options }, .{}) catch {
        self.save_error = true;
        return;
    };
    defer a.free(bytes);
    disk.writeAll(path, bytes) catch {
        self.save_error = true;
        return;
    };
    self.save_error = false;
}

// The existing event pump redraws every 50 ms, including while unfocused.
// Update before rendering either the sidebar or reader so both hide together.
pub fn updateControlsVisibility(self: *Self, context: *ui.Frame, sidebar_open: bool) void {
    const input = context.ui().input;
    if (!self.options.autohide or input.focused or sidebar_open) {
        self.unfocused_since_ms = null;
        self.controls_hidden = false;
        return;
    }
    if (self.unfocused_since_ms == null) self.unfocused_since_ms = input.now_ms;
    self.controls_hidden = input.now_ms - self.unfocused_since_ms.? >= 3000;
    if (self.controls_hidden) {
        if (context.ui().state.get(.menu_button, ui.Key.str("reader.controls").hash())) |menu| menu.open = false;
    }
}

// Uses measurements retained from the completed frame, before incoming text is appended.
pub fn tick(self: *Self, context: *ui.Frame) void {
    self.dictionaries.poll();
    const now = context.ui().input.now_ms;
    if (self.last_ms) |last| {
        if (!self.paused and self.lines.items.len > 0) self.elapsed_ms += @intCast(@max(0, now - last));
    }
    self.last_ms = now;
    const u = context.ui();
    if (u.state.get(.measured, key.hash())) |viewport| {
        if (u.state.get(.measured, ui.Key.str("reader.content").hash())) |content| {
            const axis: usize = if (self.direction == .horizontal) 1 else 0;
            const maximum = if (axis == 1) @max(0, content.height + 32 - viewport.height) else @max(0, content.width + 32 - viewport.width);
            const target = flow.latest(self.direction, maximum);
            if (u.state.get(.scroll, key.hash())) |scroll| {
                if (self.scroll_pending > 0) {
                    if (axis == 1) scroll.offset[1] = target else scroll.offset[0] = target;
                    self.scroll_pending -= 1;
                }
                self.near_bottom = @abs(target - (if (axis == 1) scroll.offset[1] else scroll.offset[0])) < 300;
            }
        }
    }
}

fn remove(self: *Self, index: usize) !void {
    try self.undo.append(a, .{ .index = index, .line = self.lines.items[index] });
    _ = self.lines.orderedRemove(index);
    self.save();
}

pub fn render(self: *Self, context: *ui.Frame, fonts: *FontSettings, background: *BackgroundImage, anki: *@import("anki_settings.zig")) anyerror!void {
    self.dictionaries.online_audio_allowed = background.appearance.online_audio_enabled;
    self.dictionaries.pronunciation.tick(context, background.appearance.online_audio_enabled);
    if (self.direction != background.appearance.direction) {
        self.direction = background.appearance.direction;
        self.scroll_pending = 2;
        self.near_bottom = true;
        if (context.ui().state.get(.scroll, key.hash())) |scroll| scroll.offset = .{ 0, 0 };
    }
    try self.routeVerticalWheel(context);
    self.shift_selection.beginPointer(context);
    const end = @min(self.page_end orelse self.lines.items.len, self.lines.items.len);
    var start = end;
    var chars_left: usize = limits.page_chars;
    var page: std.ArrayList(Line) = .empty;
    while (start > 0 and page.items.len < limits.page_lines and chars_left > 0) {
        const original = self.lines.items[start - 1];
        const text = limits.prefix(original.text, chars_left);
        var iter = (try std.unicode.Utf8View.init(text)).iterator();
        while (iter.nextCodepoint()) |_| chars_left -= 1;
        try page.append(context.arena(), .{ .id = original.id, .text = @constCast(text) });
        start -= 1;
    }
    // Collected newest-first; layout below expects chronological order.
    std.mem.reverse(Line, page.items);
    const column: Rect = .{ .key = .src(@src()), .style = &.{ .width = .grow(), .height = .grow(), .direction = .column, .gap = 8 } };
    _ = try column.open(context);
    if (!self.controls_hidden) {
        const bar: Rect = .{ .key = .src(@src()), .style = &.{ .width = .grow(), .direction = .row, .gap = 8, .@"align" = .center, .overflow = .visible } };
        _ = try bar.open(context);
        if (!self.options.overlay_counts) {
            try context.e(Text{ .key = .str("reader.counts.toolbar"), .content = try self.counterLabel(context), .style = &.{ .width = .grow(), .font_size = .{ .px = 12 }, .foreground = .dimmed }, .selectable = false });
        } else {
            try context.e(Rect{ .key = .str("reader.controls.spacer"), .style = &.{ .width = .grow() } });
        }
        if ((try context.interact(Button{ .key = .src(@src()), .label = if (self.paused) "Resume" else "Pause" })).clicked) self.paused = !self.paused;
        // CHANGE HERE: set .icon to .{ .pixels = .{ .data = @embedFile("icons/your-icon.rgba"), .width = 48, .height = 48 } }.
        if ((try context.interact(Button{ .key = .src(@src()), .label = "Delete last", .icon = null, .disabled = self.lines.items.len == 0 })).clicked) try self.remove(self.lines.items.len - 1);
        // CHANGE HERE: set .icon to .{ .pixels = .{ .data = @embedFile("icons/your-icon.rgba"), .width = 48, .height = 48 } }.
        if ((try context.interact(Button{ .key = .src(@src()), .label = "Undo", .icon = null, .disabled = self.undo.items.len == 0 })).clicked) {
            const item = self.undo.items[self.undo.items.len - 1];
            try self.lines.insert(a, @min(item.index, self.lines.items.len), item.line);
            _ = self.undo.pop();
            self.save();
        }
        // CHANGE HERE: set .icon to .{ .pixels = .{ .data = @embedFile("icons/your-icon.rgba"), .width = 48, .height = 48 } }.
        if ((try context.interact(Button{ .key = .src(@src()), .label = "Latest", .icon = null })).clicked) {
            self.page_end = null;
            self.scroll_pending = 2;
            self.near_bottom = true;
        }
        const menu: ui.component.MenuButton(ControlMenu) = .{
            .key = .str("reader.controls"),
            .label = "Options",
            .menu = .{ .reader = self },
            .close_on_popup_click = false,
            .fallback_menu_height = 380,
            .style = &@import("project_button.zig").current,
            .parts = .{ .popup = &.{ .width = .fixed(320), .gap = 8, .padding = .all(12) } },
        };
        _ = try menu.open(context);
        try menu.close(context);
        try bar.close(context);
    }
    if (start > 0 or self.page_end != null or chars_left == 0) {
        const navigation: Rect = .{ .key = .str("reader.history.navigation"), .style = &.{ .width = .grow(), .direction = .row, .gap = 8 } };
        _ = try navigation.open(context);
        if ((try context.interact(Button{ .key = .str("reader.history.older"), .label = "Older", .disabled = start == 0 })).clicked) self.page_end = start;
        if ((try context.interact(Button{ .key = .str("reader.history.latest"), .label = "Latest", .disabled = self.page_end == null })).clicked) self.page_end = null;
        try context.e(Text{ .key = .str("reader.history.notice"), .content = "Showing a limited page of history; long entries are shortened for display.", .style = &.{ .width = .grow(), .wrap = true, .font_size = .sm, .foreground = .dimmed }, .selectable = false });
        try navigation.close(context);
    }
    self.shift_selection.whole_line = self.options.select_line;
    self.shift_selection.word_selection = self.options.word_selection;
    self.shift_selection.scanner = if (self.dictionaries.dictionary_count > 0) .{ .context = &self.dictionaries, .lookup = scanWord } else null;
    const selection_entries = try context.arena().alloc(ShiftSelection.Entry, page.items.len);
    for (page.items, selection_entries) |line, *entry| entry.* = .{ .id = ui.Key.str("reader.line").indexed(line.id).hash(), .line_id = line.id, .text = line.text };
    self.shift_selection.document = selection_entries;
    try self.shift_selection.hitDocument(context, fonts.fontName(), fonts.reader_size, self.direction != .horizontal or fonts.character_spacing > 0);

    if (self.save_error) try context.e(Text{ .key = .src(@src()), .content = "Could not save or load reader-history.json", .selectable = false });
    _ = try context.ui().state.getOrCreate(.measured, context.ui().allocator, BackgroundImage.canvas_key.hash());
    const canvas: Rect = .{ .key = BackgroundImage.canvas_key, .style = &.{ .width = .grow(), .height = .grow(), .direction = .layer, .overflow = .hidden } };
    _ = try canvas.open(context);
    try background.renderBehind(context);
    const overlay_spacing: f32 = if (self.options.overlay_counts) 10 else 0;
    const log: Rect = .{ .key = key, .style = &.{ .width = .grow(), .height = .grow(), .direction = .column, .gap = 10, .padding = .init(16 + overlay_spacing, 16, 16, 16), .overflow = if (self.direction == .horizontal) .scroll_y else .scroll_x, .backdrop = background.appearance.material(), .background = .{ .color = background.appearance.tint } } };
    _ = try context.ui().state.getOrCreate(.measured, context.ui().allocator, key.hash());
    _ = try context.ui().state.getOrCreate(.scroll, context.ui().allocator, key.hash());
    const content_key: ui.Key = .str("reader.content");
    _ = try context.ui().state.getOrCreate(.measured, context.ui().allocator, content_key.hash());
    _ = try log.open(context);
    const vertical = self.direction != .horizontal;
    // Rendering entries grows the measured-state map and can invalidate its pointers.
    // Keep the dimensions by value for the entire loop.
    const canvas_measure = context.ui().state.get(.measured, BackgroundImage.canvas_key.hash()).?.*;
    const available_height = @max(1, canvas_measure.height - 32 - overlay_spacing - context.ui().theme.scrollbar_thickness - 36);
    const cell_size = fonts.reader_size * 1.3;
    const rows: usize = @max(1, @as(usize, @intFromFloat(@floor(available_height / (cell_size + fonts.character_spacing)))));
    var content_width: f32 = @max(0, canvas_measure.width - 32);
    if (vertical) {
        var total: f32 = 0;
        for (page.items, 0..) |line, i| {
            const text = if (std.unicode.utf8ValidateSlice(line.text)) line.text else "\u{FFFD}";
            var layout = try flow.build(context.arena(), text, rows);
            defer layout.cells.deinit(context.arena());
            total += @as(f32, @floatFromInt(layout.columns)) * cell_size;
            if (i > 0) total += fonts.line_spacing;
        }
        content_width = @max(content_width, total);
    }
    const content: Rect = .{ .key = content_key, .style = &.{
        .width = if (vertical) .fixed(content_width) else .grow(),
        .height = if (vertical) .fixed(@as(f32, @floatFromInt(rows)) * (cell_size + fonts.character_spacing) + 36) else .fit(),
        .direction = if (vertical) .row else .column,
        .gap = fonts.line_spacing,
        .justify = if (self.direction == .vertical_right) .end else .start,
    } };
    _ = try content.open(context);
    var delete_index: ?usize = null;
    var selection_popup: SelectionPopup = .{};
    for (0..page.items.len) |order| {
        const i = if (self.direction == .vertical_right) page.items.len - 1 - order else order;
        const line = page.items[i];
        if (vertical or fonts.character_spacing > 0) {
            const text = if (std.unicode.utf8ValidateSlice(line.text)) line.text else "\u{FFFD}";
            if (try VerticalReader.renderEntry(context, line.id, text, fonts, self.direction, rows, @max(1, canvas_measure.width - 72), &self.shift_selection, &selection_popup)) delete_index = start + i;
            continue;
        }
        const row: Rect = .{ .key = ui.Key.str("reader.row").indexed(line.id), .style = &.{ .width = .grow(), .direction = .row, .gap = 8 } };
        _ = try context.ui().state.getOrCreate(.measured, context.ui().allocator, row.key.hash());
        _ = try row.open(context);
        // Malformed UTF-8 from a hook must not reach Knots' text shaper.
        const text = if (std.unicode.utf8ValidateSlice(line.text)) line.text else "\u{FFFD}";
        const text_key = ui.Key.str("reader.line").indexed(line.id);
        _ = try context.ui().state.getOrCreate(.measured, context.ui().allocator, text_key.indexed(1).hash());
        try self.shift_selection.renderText(context, Text{ .key = text_key, .content = text, .style = &.{ .width = .grow(), .wrap = true, .font = fonts.fontName(), .font_size = .{ .px = fonts.reader_size }, .padding = .xy(4, 3) } });
        try selection_popup.observe(context, ui.Key.str("reader.line").indexed(line.id), text);
        var hovered = false;
        if (self.shift_selection.pointer) |pointer| {
            if (context.ui().state.get(.measured, row.key.hash())) |measured| hovered = measured.box.contains(pointer);
        }
        // Keep wrapping stable while positioning the button after the last visual line.
        try context.e(ui.component.Spacer{ .key = ui.Key.str("reader.delete.space").indexed(line.id), .style = &.{ .width = .fixed(28), .height = .fixed(28) } });
        if (hovered) {
            var button_offset: [2]f32 = .{ 12, 3 };
            if (context.ui().state.get(.measured, text_key.indexed(1).hash())) |body| {
                const scale = context.ui().content_scale;
                const face = try context.ui().font.getFace(fonts.fontName());
                const shaped = try face.shapeWrapped(text, fonts.reader_size * scale, body.width * scale);
                if (shaped.lines.len > 0) {
                    const last = shaped.lines[shaped.lines.len - 1];
                    button_offset = .{ 4 + last.width / scale + 8, 3 + last.y / scale + @max(0, (shaped.line_height / scale - 28) / 2) };
                }
            }
            if ((try context.interact(ui.component.Button{ .key = ui.Key.str("reader.delete").indexed(line.id), .label = "x", .style = &.{ .position = .absolute, .offset = button_offset, .width = .fixed(28), .height = .fixed(28), .padding = .all(0), .background = .transparent, .foreground = .dimmed, .hover = &.{ .background = .muted, .foreground = .text } } })).clicked) delete_index = start + i;
        }
        try row.close(context);
    }
    try content.close(context);
    try log.close(context);
    if (self.options.overlay_counts) {
        const overlay: Rect = .{ .key = .str("reader.counts.overlay.row"), .style = &.{ .position = .absolute, .offset = .{ 8, 8 }, .width = .fixed(@max(0, canvas_measure.width - 16)), .direction = .row, .justify = .end } };
        _ = try overlay.open(context);
        try context.e(Text{
            .key = .str("reader.counts.overlay"),
            .content = try self.counterLabel(context),
            .style = &.{ .font_size = .{ .px = 12 }, .foreground = .text, .background = .bg, .padding = .xy(6, 3), .radius = .sm },
            .selectable = false,
        });
        try overlay.close(context);
    }
    try canvas.close(context);
    if (self.shift_selection.finishFrame(context)) selection_popup = .{};
    if (delete_index) |i| {
        try self.remove(i);
        selection_popup = .{};
    }
    if (self.shift_selection.active_id != null) {
        const selected_text = try self.shift_selection.collect(context.arena(), false);
        if (selected_text.len > 0) context.ui().state.selection_text = selected_text;
        if (self.shift_selection.multipleEntries()) {
            selection_popup.sentence = try self.shift_selection.collect(context.arena(), true);
            // Keep dictionary/Anki headword lookup on the drag endpoint while the
            // card's sentence contains all selected context lines.
            for (selection_entries) |entry| {
                if (entry.id != self.shift_selection.active_id.?) continue;
                const lo = @min(self.shift_selection.focus_range.lo, entry.text.len);
                var hi: usize = @min(self.shift_selection.focus_range.hi, entry.text.len);
                if (self.shift_selection.scanner) |scanner| hi = (scanner.lookup(scanner.context, entry.text, lo) catch null) orelse hi;
                selection_popup.text = entry.text[lo..@min(hi, entry.text.len)];
                break;
            }
        }
    }
    if (self.shift_selection.mouse_dragging) selection_popup = .{};
    try column.close(context);
    try selection_popup.render(context, &self.dictionaries, fonts, anki, &background.appearance.popup);
}

// Knots handles ordinary vertical scrolling and horizontal trackpad gestures.
// Map the wheel's vertical component onto the reading axis for vertical writing.
fn routeVerticalWheel(self: *Self, context: *ui.Frame) !void {
    if (self.direction == .horizontal) return;
    const u = context.ui();
    const pointer = self.shift_selection.pointer orelse return;
    const viewport = u.state.get(.measured, key.hash()) orelse return;
    const content = u.state.get(.measured, ui.Key.str("reader.content").hash()) orelse return;
    if (!viewport.box.contains(pointer)) return;
    if (u.state.get(.floating_window, ui.Key.str("reader.selection.popup").hash())) |popup| {
        if (popup.visible_frame + 1 >= u.state.frame and pointer[0] >= popup.render_position[0] and pointer[0] < popup.render_position[0] + popup.render_size[0] and pointer[1] >= popup.render_position[1] and pointer[1] < popup.render_position[1] + popup.render_size[1]) return;
    }
    const wheel = u.input.scroll;
    const line_height = try u.lineHeight(u.scroll_line_size.resolve(&u.theme), null);
    const delta = wheel.pixel[1] + wheel.line[1] * line_height + wheel.page[1] * @max(0, viewport.width - line_height);
    if (delta == 0) return;
    const maximum = @max(0, content.width + 32 - viewport.width);
    if (u.state.get(.scroll, key.hash())) |scroll| {
        scroll.offset[0] = std.math.clamp(scroll.offset[0] + flow.wheel(self.direction, delta), 0, maximum);
        self.scroll_pending = 0;
        self.near_bottom = @abs(flow.latest(self.direction, maximum) - scroll.offset[0]) < 300;
    }
}

fn scanWord(pointer: *anyopaque, text: []const u8, start: usize) anyerror!?usize {
    const dictionaries: *DictionaryUI = @ptrCast(@alignCast(pointer));
    return dictionaries.scanWord(text, start);
}

const ControlMenu = struct {
    reader: *Self,
    pub fn render(menu: *const @This(), frame: *ui.Frame) anyerror!void {
        const self = menu.reader;
        if ((try frame.interact(Button{ .key = .str("reader.clear"), .label = "Clear all lines", .disabled = self.lines.items.len == 0 })).clicked) {
            try self.undo.ensureUnusedCapacity(a, self.lines.items.len);
            while (self.lines.items.len > 0) {
                const index = self.lines.items.len - 1;
                self.undo.appendAssumeCapacity(.{ .index = index, .line = self.lines.pop().? });
            }
            self.shift_selection.active_id = null;
            self.save();
        }
        if ((try frame.interact(Button{ .key = .str("reader.reset.timer"), .label = "Reset timer" })).clicked) {
            self.elapsed_ms = 0;
            self.last_ms = frame.ui().input.now_ms;
            self.save();
        }
        inline for (.{
            .{ "show_counts", "Show character / line count" },
            .{ "show_timer", "Show timer and chars/hour" },
            .{ "overlay_counts", "Overlay char/line count and chars/hour" },
            .{ "remove_whitespace", "Remove all whitespace characters" },
            .{ "near_end_only", "Only autoscroll when near latest text" },
            .{ "store_lines", "Store lines persistently" },
            .{ "exclude_special", "Don't count special chars" },
            .{ "select_line", "Always select entire line" },
            .{ "word_selection", "Automatically select dictionary words" },
            .{ "autohide", "Autohide controls after 3s unfocused" },
        }) |option| {
            if ((try frame.interact(ui.component.Checkbox{ .key = .str("reader.option." ++ option[0]), .label = option[1], .checked = &@field(self.options, option[0]) })).changed) self.save();
        }
    }
};

fn counterLabel(self: *const Self, context: *ui.Frame) ![]const u8 {
    var chars: usize = 0;
    for (self.lines.items) |line| {
        var iter = std.unicode.Utf8View.init(line.text) catch continue;
        var points = iter.iterator();
        while (points.nextCodepoint()) |cp| {
            if (!isWhitespace(cp) and (!self.options.exclude_special or !isSpecial(cp))) {
                chars += 1;
            }
        }
    }
    const seconds = self.elapsed_ms / 1000;
    const rate = if (self.elapsed_ms > 0) chars * 3600000 / self.elapsed_ms else 0;
    const counts = if (self.options.show_counts) try std.fmt.allocPrint(context.arena(), "{d} chars / {d} lines", .{ chars, self.lines.items.len }) else "";
    const timer = if (self.options.show_timer) try std.fmt.allocPrint(context.arena(), "{d:0>2}:{d:0>2}:{d:0>2} {d}/hr", .{ seconds / 3600, seconds / 60 % 60, seconds % 60, rate }) else "";
    const label = try std.fmt.allocPrint(context.arena(), "{s}  {s}", .{ counts, timer });
    return label;
}
