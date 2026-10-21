//! Executable-relative reader fonts and persisted typography controls.
const std = @import("std");
const ui = @import("ui");
const files = @import("dictionary_files.zig");
const disk = @import("reader_store.zig");
const a = std.heap.smp_allocator;
const Entry = struct { name: []u8, bytes: []u8, available: bool = false };
const Saved = struct { font: []const u8 = "default", reader_size: f32 = 28, popup_size: f32 = 18, line_spacing: f32 = 10, character_spacing: f32 = 0 };

entries: std.ArrayList(Entry) = .empty,
selected: usize = 0,
reader_size: f32 = 28,
popup_size: f32 = 18,
line_spacing: f32 = 10,
character_spacing: f32 = 0,
loaded: bool = false,
message: []const u8 = "Add Japanese-capable .ttf files to fonts, then restart Touitsu.",
const Self = @This();

pub fn init(io: std.Io) Self {
    var self: Self = .{};
    var paths = files.folderFiles(io, "fonts", ".ttf") catch {
        self.message = "Could not open the fonts folder. Using the bundled font.";
        return self;
    };
    defer files.freePaths(&paths);
    for (paths.items) |path| {
        if (self.entries.items.len >= 254) break;
        const bytes = files.readFile(path, 64 * 1024 * 1024) catch continue;
        const name = a.dupe(u8, std.fs.path.basename(path)) catch {
            a.free(bytes);
            continue;
        };
        self.entries.append(a, .{ .name = name, .bytes = bytes }) catch {
            a.free(name);
            a.free(bytes);
        };
    }
    self.load();
    return self;
}
/// FontSource borrows these names/bytes. Call only after Knots' App.deinit().
pub fn deinit(self: *Self) void {
    for (self.entries.items) |entry| {
        a.free(entry.name);
        a.free(entry.bytes);
    }
    self.entries.deinit(a);
}
pub fn ensureLoaded(self: *Self, frame: *ui.Frame) void {
    if (self.loaded) return;
    self.loaded = true;
    for (self.entries.items, 0..) |*entry, i| {
        frame.ui().font.addFace(entry.name, entry.bytes) catch {
            self.message = "Some fonts could not be loaded. Use supported TrueType .ttf files.";
            if (self.selected == i + 1) self.selected = 0;
            continue;
        };
        entry.available = true;
    }
}
pub fn fontName(self: *const Self) []const u8 {
    return if (self.selected == 0) "default" else self.entries.items[self.selected - 1].name;
}
fn load(self: *Self) void {
    const path = files.siblingPath("font-settings.json") catch return;
    defer a.free(path);
    const wide = std.unicode.utf8ToUtf16LeAllocZ(a, path) catch return;
    defer a.free(wide);
    const bytes = (disk.readAll(a, wide) catch return) orelse return;
    defer a.free(bytes);
    const parsed = std.json.parseFromSlice(Saved, a, bytes, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    self.reader_size = bounded(parsed.value.reader_size, 12, 64, 28);
    self.popup_size = bounded(parsed.value.popup_size, 12, 36, 18);
    self.line_spacing = bounded(parsed.value.line_spacing, 0, 40, 10);
    self.character_spacing = bounded(parsed.value.character_spacing, -5, 24, 0);
    for (self.entries.items, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.name, parsed.value.font)) {
            self.selected = i + 1;
            break;
        }
    }
}
fn bounded(value: f32, min: f32, max: f32, fallback: f32) f32 {
    return if (std.math.isFinite(value)) std.math.clamp(value, min, max) else fallback;
}
fn save(self: *Self) void {
    const bytes = std.json.Stringify.valueAlloc(a, Saved{ .font = self.fontName(), .reader_size = self.reader_size, .popup_size = self.popup_size, .line_spacing = self.line_spacing, .character_spacing = self.character_spacing }, .{}) catch return;
    defer a.free(bytes);
    const path = files.siblingPath("font-settings.json") catch return;
    defer a.free(path);
    const wide = std.unicode.utf8ToUtf16LeAllocZ(a, path) catch return;
    defer a.free(wide);
    disk.writeAll(wide, bytes) catch {
        self.message = "Could not save font-settings.json.";
    };
}
pub fn render(self: *Self, frame: *ui.Frame) !void {
    const Text = ui.component.Text;
    const Button = @import("project_button.zig");
    const section: @import("settings_section.zig") = .{ .key = .str("fonts.section"), .title = "Font settings" };
    _ = try section.open(frame);
    defer section.close(frame) catch {};
    try frame.e(Text{ .key = .src(@src()), .content = "Reader font", .selectable = false });
    if ((try frame.interact(Button{ .key = .src(@src()), .label = "Bundled Japanese font", .style = &.{ .width = .grow(), .background = if (self.selected == 0) .accent else .muted, .foreground = if (self.selected == 0) .on_accent else .text } })).clicked) {
        self.selected = 0;
        self.save();
    }
    for (self.entries.items, 0..) |entry, i| {
        if (!entry.available) continue;
        const selected = self.selected == i + 1;
        if ((try frame.interact(Button{ .key = ui.Key.str("font.option").indexed(i), .label = entry.name, .style = &.{ .width = .grow(), .background = if (selected) .accent else .muted, .foreground = if (selected) .on_accent else .text } })).clicked) {
            self.selected = i + 1;
            self.save();
        }
    }
    try self.slider(frame, .str("font.reader.size"), "Reader text", &self.reader_size, 12, 64);
    try self.slider(frame, .str("font.popup.size"), "Dictionary text", &self.popup_size, 12, 36);
    try self.slider(frame, .str("font.character.spacing"), "Character spacing", &self.character_spacing, -5, 24);
    try self.slider(frame, .str("font.line.spacing"), "Line spacing", &self.line_spacing, 0, 40);
    try frame.e(Text{ .key = .src(@src()), .content = "日本語の表示サンプル", .style = &.{ .width = .grow(), .wrap = true, .font = self.fontName(), .font_size = .{ .px = self.reader_size }, .padding = .xy(0, 12) }, .selectable = false });
    try frame.e(Text{ .key = .src(@src()), .content = self.message, .style = &.{ .width = .grow(), .wrap = true, .font_size = .sm, .foreground = .dimmed }, .selectable = false });
}
fn slider(self: *Self, frame: *ui.Frame, key: ui.Key, label: []const u8, value: *f32, min: f32, max: f32) !void {
    const caption = try std.fmt.allocPrint(frame.arena(), "{s}: {d:.0} px", .{ label, value.* });
    try frame.e(ui.component.Text{ .key = key.indexed(1), .content = caption, .selectable = false });
    if ((try frame.interact(ui.component.SliderInput{ .key = key, .value = value, .min = min, .max = max, .steps = 1 })).changed) {
        self.save();
        frame.requestRedraw();
    }
}
