//! Persisted reader glass and application theme settings.
const std = @import("std");
const ui = @import("ui");
const files = @import("../../platform/dictionary_files.zig");
const disk = @import("../reader/reader_store.zig");
const a = std.heap.smp_allocator;
pub const Direction = @import("../reader/reading_layout.zig").Direction;
pub const ImageScaling = enum { fit, fill, stretch, original };
const ThemeChoice = enum { light, dark, forest_night, graphite_neon, gruvbox, midnight_ocean, monochrome_ash, nord_frost, rose_mist, warm_sand, uranium };
const themes = blk: {
    @setEvalBranchQuota(50000);
    break :blk [_]ui.Theme{
        ui.Theme.light,
        ui.Theme.dark,
        ui.Theme.parse(@import("../../themes/forest_night.zon")),
        ui.Theme.parse(@import("../../themes/graphite_neon.zon")),
        ui.Theme.parse(@import("../../themes/gruvbox.zon")),
        ui.Theme.parse(@import("../../themes/midnight_ocean.zon")),
        ui.Theme.parse(@import("../../themes/monochrome_ash.zon")),
        ui.Theme.parse(@import("../../themes/nord_frost.zon")),
        ui.Theme.parse(@import("../../themes/rose_mist.zon")),
        ui.Theme.parse(@import("../../themes/warm_sand.zon")),
        ui.Theme.parse(@import("../../themes/uranium.zon")),
    };
};
const ButtonMode = enum { solid, outline, ghost, glass };
const Buttons = struct {
    mode: ButtonMode = .solid,
    background: [4]f32 = .{ 0.23, 0.45, 0.85, 1 },
    foreground: [4]f32 = .{ 1, 1, 1, 1 },
    border: [4]f32 = .{ 0.23, 0.45, 0.85, 1 },
    border_width: f32 = 0,
    radius: f32 = 4,
    size: f32 = 1,
};
const Saved = struct {
    online_audio_enabled: bool = true,
    popup: @import("popup_appearance.zig") = .{},
    image_scaling: ImageScaling = .fit,
    buttons: Buttons = .{},
    theme: ThemeChoice = .uranium,
    direction: Direction = .horizontal,
    blur: f32 = 2,
    glass_response: f32 = 0,
    tint: [4]f32 = .{ 1, 1, 1, 20.0 / 255.0 },
};

online_audio_enabled: bool = true,
theme: ThemeChoice = .uranium,
image_scaling: ImageScaling = .fit,
direction: Direction = .horizontal,
blur: f32 = 2,
glass_response: f32 = 0,
tint: ui.Color = ui.Color.rgba(255, 255, 255, 20),
buttons: Buttons = .{},
popup: @import("popup_appearance.zig") = .{},
save_failed: bool = false,
const Self = @This();

pub fn init() Self {
    var self: Self = .{};
    self.theme = .light;
    _ = self.setTheme(.uranium);
    const path = files.siblingPath("appearance.json") catch return self;
    defer a.free(path);
    const wide = std.unicode.utf8ToUtf16LeAllocZ(a, path) catch return self;
    defer a.free(wide);
    const bytes = (disk.readAll(a, wide) catch return self) orelse return self;
    defer a.free(bytes);
    const parsed = std.json.parseFromSlice(Saved, a, bytes, .{ .ignore_unknown_fields = true }) catch return self;
    defer parsed.deinit();
    self.online_audio_enabled = parsed.value.online_audio_enabled;
    self.buttons = parsed.value.buttons;
    self.popup = parsed.value.popup;
    self.popup.sanitize();
    inline for (.{ "border_width", "radius", "size" }, .{ @as(f32, 0), @as(f32, 0), @as(f32, 0.6) }, .{ @as(f32, 6), @as(f32, 32), @as(f32, 1.8) }) |field, lo, hi| {
        const value = &@field(self.buttons, field);
        value.* = if (std.math.isFinite(value.*)) std.math.clamp(value.*, lo, hi) else lo;
    }
    inline for (.{ "background", "foreground", "border" }) |field| {
        for (&@field(self.buttons, field)) |*value| value.* = if (std.math.isFinite(value.*)) std.math.clamp(value.*, 0, 1) else 1;
    }
    self.theme = parsed.value.theme;
    self.image_scaling = parsed.value.image_scaling;
    self.direction = parsed.value.direction;
    if (std.math.isFinite(parsed.value.glass_response)) self.glass_response = std.math.clamp(parsed.value.glass_response, 0, 2);
    if (std.math.isFinite(parsed.value.blur)) self.blur = std.math.clamp(parsed.value.blur, 0, 40);
    for (parsed.value.tint, 0..) |channel, i| {
        if (std.math.isFinite(channel)) self.tint.value[i] = std.math.clamp(channel, 0, 1);
    }
    return self;
}
pub fn applyTheme(self: *const Self, frame: *ui.Frame) void {
    frame.ui().theme = themes[@backingInt(self.theme)];
    const b = self.buttons;
    var fill = b.background;
    if (b.mode == .glass) fill[3] *= 0.2;
    @import("../../ui/project_button.zig").current = .{
        .padding = .xy(12 * b.size, 6 * b.size),
        .font_size = .{ .px = 16 * b.size },
        .background = if (b.mode == .outline or b.mode == .ghost) .transparent else .{ .color = .{ .value = fill } },
        .foreground = .{ .color = .{ .value = b.foreground } },
        .border_color = .{ .color = .{ .value = b.border } },
        .border_width = .all(if (b.mode == .outline) @max(1, b.border_width) else b.border_width),
        .radius = .{ .fixed = b.radius },
        .backdrop = if (b.mode == .glass) @import("glass_material.zig").enhance(ui.Material.frosted, self.glass_response) else .none,
    };
}
pub fn material(self: *const Self) ui.Material {
    var glass = ui.Material.frosted;
    glass.blur = self.blur;
    return @import("glass_material.zig").enhance(glass, self.glass_response);
}
fn save(self: *Self) void {
    self.write() catch {
        self.save_failed = true;
        return;
    };
    self.save_failed = false;
}
fn write(self: *Self) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, Saved{ .online_audio_enabled = self.online_audio_enabled, .popup = self.popup, .image_scaling = self.image_scaling, .buttons = self.buttons, .theme = self.theme, .direction = self.direction, .blur = self.blur, .glass_response = self.glass_response, .tint = self.tint.value }, .{});
    defer a.free(bytes);
    const path = try files.siblingPath("appearance.json");
    defer a.free(path);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
    defer a.free(wide);
    try disk.writeAll(wide, bytes);
}
pub fn renderInternet(self: *Self, frame: *ui.Frame) !void {
    const changed = (try frame.interact(ui.component.Checkbox{ .key = .str("settings.internet.audio"), .label = "Allow internet for dictionary audio", .checked = &self.online_audio_enabled })).changed;
    try frame.e(ui.component.Text{ .key = .str("settings.internet.audio.description"), .content = "Audio lookup sends the entry's word and reading to JapanesePod101, with Jisho as a fallback. Used for playback and Anki audio. Requires an internet connection.", .selectable = false, .style = &.{ .width = .grow(), .wrap = true, .font_size = .sm, .foreground = .dimmed } });
    try self.finishChanges(frame, changed);
}

/// Theme changes choose a readable default once; subsequent color edits remain user-owned.
pub fn setTheme(self: *Self, choice: ThemeChoice) bool {
    if (self.theme == choice) return false;
    self.theme = choice;
    const theme = themes[@backingInt(choice)];
    if (choice == .uranium) {
        self.buttons.mode = .glass;
        self.buttons.background = theme.primary.value;
        self.buttons.border = theme.primary.value;
        self.buttons.border_width = 1;
        self.glass_response = 1.4;
        self.blur = 10;
        self.tint = theme.bg;
        self.tint.value[3] = 0.12;
        self.popup.light_response = 1.4;
    }
    if (self.buttons.mode == .outline or self.buttons.mode == .ghost) {
        self.buttons.foreground = theme.text.value;
    } else {
        var fill = self.buttons.background;
        if (self.buttons.mode == .glass) fill[3] *= 0.2;
        var luminance: f32 = 0;
        for ([_]f32{ 0.2126, 0.7152, 0.0722 }, 0..) |weight, i| {
            const channel = fill[i] * fill[3] + theme.bg.value[i] * (1 - fill[3]);
            const linear = if (channel <= 0.04045) channel / 12.92 else std.math.pow(f32, (channel + 0.055) / 1.055, 2.4);
            luminance += weight * linear;
        }
        const channel: f32 = if (luminance > 0.179) 0 else 1;
        self.buttons.foreground = .{ channel, channel, channel, 1 };
    }
    return true;
}

pub fn renderTheme(self: *Self, frame: *ui.Frame) !void {
    const Text = ui.component.Text;
    var changed = false;
    try frame.e(Text{ .key = .src(@src()), .content = "Theme", .selectable = false });
    const selection = try frame.interact(ui.component.SelectInput(ThemeChoice){
        .key = .str("settings.theme"),
        .labels = &.{ "Light", "Dark", "Forest night", "Graphite neon", "Gruvbox", "Midnight ocean", "Monochrome ash", "Nord frost", "Rose mist", "Warm sand", "Uranium" },
        .values = &.{ .light, .dark, .forest_night, .graphite_neon, .gruvbox, .midnight_ocean, .monochrome_ash, .nord_frost, .rose_mist, .warm_sand, .uranium },
        .initial_selected = @intCast(@backingInt(self.theme)),
        .style = &.{ .width = .grow() },
    });
    if (selection.selected) |selected| {
        changed = self.setTheme(selected.value);
    }
    try self.finishChanges(frame, changed);
}
pub fn renderDirection(self: *Self, frame: *ui.Frame) !void {
    const Text = ui.component.Text;
    var changed = false;
    try frame.e(Text{ .key = .src(@src()), .content = "Text direction", .selectable = false });
    const direction = try frame.interact(ui.component.SelectInput(Direction){
        .key = .str("settings.reading.direction"),
        .labels = &.{ "Horizontal", "Vertical: left to right", "Vertical: right to left" },
        .values = &.{ .horizontal, .vertical_left, .vertical_right },
        .initial_selected = @intCast(@backingInt(self.direction)),
        .style = &.{ .width = .grow() },
    });
    if (direction.selected) |selected| {
        self.direction = selected.value;
        changed = true;
    }
    try self.finishChanges(frame, changed);
}
pub fn renderImageScaling(self: *Self, frame: *ui.Frame) !void {
    try frame.e(ui.component.Text{ .key = .src(@src()), .content = "Image scaling", .selectable = false });
    const selection = try frame.interact(ui.component.SelectInput(ImageScaling){
        .key = .str("settings.background.scaling"),
        .labels = &.{ "Fit (show whole image)", "Fill (crop to fill)", "Stretch (fill without cropping)", "Original size (centered)" },
        .values = &.{ .fit, .fill, .stretch, .original },
        .initial_selected = @intCast(@backingInt(self.image_scaling)),
        .style = &.{ .width = .grow() },
    });
    if (selection.selected) |selected| {
        self.image_scaling = selected.value;
        try self.finishChanges(frame, true);
    }
}
pub fn renderGlass(self: *Self, frame: *ui.Frame) !void {
    const Text = ui.component.Text;
    var changed = false;
    try frame.e(Text{ .key = .src(@src()), .content = "Reader glass", .style = &.{ .padding = .xy(0, 6) }, .selectable = false });
    const blur_label = try std.fmt.allocPrint(frame.arena(), "Blur: {d:.0} px", .{self.blur});
    try frame.e(Text{ .key = .src(@src()), .content = blur_label, .selectable = false });
    if ((try frame.interact(ui.component.SliderInput{ .key = .str("settings.glass.blur"), .value = &self.blur, .min = 0, .max = 40, .steps = 1 })).changed) changed = true;
    const response_label = try std.fmt.allocPrint(frame.arena(), "Glass light response: {d:.0}%", .{self.glass_response * 100});
    try frame.e(Text{ .key = .str("settings.glass.response.label"), .content = response_label, .selectable = false });
    if ((try frame.interact(ui.component.SliderInput{ .key = .str("settings.glass.response"), .value = &self.glass_response, .min = 0, .max = 2, .steps = 0.05 })).changed) changed = true;
    try frame.e(Text{ .key = .src(@src()), .content = "Tint color", .selectable = false });
    if ((try frame.interact(ui.component.ColorPicker{ .key = .str("settings.glass.tint"), .value = &self.tint, .style = &.{ .width = .grow() } })).changed) changed = true;
    const opacity_label = try std.fmt.allocPrint(frame.arena(), "Tint opacity: {d:.0}%", .{self.tint.value[3] * 100});
    try frame.e(Text{ .key = .src(@src()), .content = opacity_label, .selectable = false });
    if ((try frame.interact(ui.component.SliderInput{ .key = .str("settings.glass.opacity"), .value = &self.tint.value[3], .min = 0, .max = 1, .steps = 0.01 })).changed) changed = true;
    try self.finishChanges(frame, changed);
}
pub fn renderPopup(self: *Self, frame: *ui.Frame) !void {
    try self.finishChanges(frame, try self.popup.render(frame));
}
pub fn renderButtons(self: *Self, frame: *ui.Frame) !void {
    const Text = ui.component.Text;
    var changed = false;
    const mode = try frame.interact(ui.component.SelectInput(ButtonMode){
        .key = .str("settings.buttons.mode"),
        .labels = &.{ "Solid", "Outline", "Ghost", "Glass" },
        .values = &.{ .solid, .outline, .ghost, .glass },
        .initial_selected = @intCast(@backingInt(self.buttons.mode)),
        .style = &.{ .width = .grow() },
    });
    if (mode.selected) |selected| {
        self.buttons.mode = selected.value;
        changed = true;
    }
    inline for (.{ "background", "foreground", "border" }, .{ "Button color / opacity", "Button text color", "Button border color" }) |field, label| {
        try frame.e(Text{ .key = .str("settings.buttons.label." ++ field), .content = label, .selectable = false });
        var color: ui.Color = .{ .value = @field(self.buttons, field) };
        if ((try frame.interact(ui.component.ColorPicker{ .key = .str("settings.buttons." ++ field), .value = &color, .style = &.{ .width = .grow() } })).changed) {
            @field(self.buttons, field) = color.value;
            changed = true;
        }
    }
    inline for (.{ "border_width", "radius", "size" }, .{ "Border width", "Corner radius", "Button size" }, .{ @as(f32, 0), @as(f32, 0), @as(f32, 0.6) }, .{ @as(f32, 6), @as(f32, 32), @as(f32, 1.8) }) |field, label, lo, hi| {
        const value = &@field(self.buttons, field);
        try frame.e(Text{ .key = .str("settings.buttons.label." ++ field), .content = try std.fmt.allocPrint(frame.arena(), "{s}: {d:.1}", .{ label, value.* }), .selectable = false });
        if ((try frame.interact(ui.component.SliderInput{ .key = .str("settings.buttons." ++ field), .value = value, .min = lo, .max = hi, .steps = 0.1 })).changed) changed = true;
    }
    _ = try frame.interact(@import("../../ui/project_button.zig"){ .key = .str("settings.buttons.preview"), .label = "Button preview" });
    try self.finishChanges(frame, changed);
}
fn finishChanges(self: *Self, frame: *ui.Frame, changed: bool) !void {
    const Text = ui.component.Text;
    if (changed) {
        self.save();
        self.applyTheme(frame);
        frame.requestRedraw();
    }
    if (self.save_failed) try frame.e(Text{ .key = .src(@src()), .content = "Could not save appearance.json.", .selectable = false });
}
