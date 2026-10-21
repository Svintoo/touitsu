//! Persisted appearance of the reader's dictionary popup.
const std = @import("std");
const ui = @import("ui");

follow_theme: bool = true,
background: [4]f32 = .{ 1, 1, 1, 1 },
foreground: [4]f32 = .{ 0.08, 0.08, 0.08, 1 },
border: [4]f32 = .{ 0.4, 0.4, 0.4, 1 },
opacity: f32 = 0.95,
blur: f32 = 8,
light_response: f32 = 0,
radius: f32 = 8,
border_width: f32 = 1,
width: f32 = 440,
height: f32 = 280,
padding: f32 = 12,
entry_spacing: f32 = 0,
const Self = @This();

pub fn sanitize(self: *Self) void {
    const defaults: Self = .{};
    inline for (.{ "opacity", "blur", "light_response", "radius", "border_width", "width", "height", "padding", "entry_spacing" }, .{ @as(f32, 0), 0, 0, 0, 0, 240, 120, 0, 0 }, .{ @as(f32, 1), 40, 2, 32, 6, 1000, 800, 32, 48 }) |field, lo, hi| {
        const value = &@field(self, field);
        value.* = if (std.math.isFinite(value.*)) std.math.clamp(value.*, lo, hi) else @field(defaults, field);
    }
    inline for (.{ "background", "foreground", "border" }) |field| {
        for (&@field(self, field)) |*value| value.* = if (std.math.isFinite(value.*)) std.math.clamp(value.*, 0, 1) else 1;
    }
}

pub fn backgroundColor(self: *const Self, theme: ui.Theme) ui.Color {
    var color: ui.Color = if (self.follow_theme) theme.elevated else .{ .value = self.background };
    color.value[3] *= self.opacity;
    return color;
}

pub fn material(self: *const Self) ui.Material {
    if (self.blur == 0 and self.light_response == 0) return .none;
    var result = ui.Material.frosted;
    result.blur = self.blur;
    return @import("glass_material.zig").enhance(result, self.light_response);
}

pub fn render(self: *Self, frame: *ui.Frame) !bool {
    var changed = (try frame.interact(ui.component.Checkbox{ .key = .str("popup.follow_theme"), .label = "Follow theme colors", .checked = &self.follow_theme })).changed;
    if (!self.follow_theme) {
        inline for (.{ "background", "foreground", "border" }, .{ "Background color", "Text color", "Border color" }) |field, label| {
            try frame.e(ui.component.Text{ .key = .str("popup.color.label." ++ field), .content = label, .selectable = false });
            var color: ui.Color = .{ .value = @field(self, field) };
            if ((try frame.interact(ui.component.ColorPicker{ .key = .str("popup.color." ++ field), .value = &color, .style = &.{ .width = .grow() } })).changed) {
                @field(self, field) = color.value;
                changed = true;
            }
        }
    }
    inline for (.{ "opacity", "blur", "light_response", "radius", "border_width", "width", "height", "padding", "entry_spacing" }, .{ "Background opacity", "Blur", "Glass light response", "Corner radius", "Border width", "Width", "Height", "Padding", "Entry vertical spacing" }, .{ @as(f32, 0), 0, 0, 0, 0, 240, 120, 0, 0 }, .{ @as(f32, 1), 40, 2, 32, 6, 1000, 800, 32, 48 }) |field, label, lo, hi| {
        const value = &@field(self, field);
        const caption = if (comptime (std.mem.eql(u8, field, "opacity") or std.mem.eql(u8, field, "light_response")))
            try std.fmt.allocPrint(frame.arena(), "{s}: {d:.0}%", .{ label, value.* * 100 })
        else
            try std.fmt.allocPrint(frame.arena(), "{s}: {d:.0} px", .{ label, value.* });
        try frame.e(ui.component.Text{ .key = .str("popup.label." ++ field), .content = caption, .selectable = false });
        if ((try frame.interact(ui.component.SliderInput{ .key = .str("popup." ++ field), .value = value, .min = lo, .max = hi, .steps = if (comptime (std.mem.eql(u8, field, "opacity") or std.mem.eql(u8, field, "light_response"))) 0.01 else 1 })).changed) changed = true;
    }
    return changed;
}
