//! Settings drop zone and the image behind the reader's glass surface.
const std = @import("std");
const ui = @import("ui");
const Image = @import("../../platform/image_decode.zig");
const Drops = @import("../../ui/drops.zig");
const Appearance = @import("appearance_settings.zig");
const files = @import("../../platform/dictionary_files.zig");
const disk = @import("../reader/reader_store.zig");
const a = std.heap.smp_allocator;
pub const canvas_key: ui.Key = .str("reader.canvas");

appearance: Appearance = .{},
image: ?Image = null,
version: u64 = 1,
message: []const u8 = "Drop a picture to place it behind the reader glass.",
const Self = @This();

pub fn init() Self {
    var self: Self = .{ .appearance = Appearance.init() };
    const path = files.siblingPath("reader-background.image") catch return self;
    defer a.free(path);
    self.image = Image.load(path) catch return self;
    self.message = "Background image restored.";
    return self;
}
pub fn deinit(self: *Self) void {
    if (self.image) |image| image.deinit();
}
fn useImage(self: *Self, path: []const u8) !void {
    // Decode before replacing either the current texture or the saved background.
    const image = try Image.load(path);
    errdefer image.deinit();
    const bytes = try files.readFile(path, 64 * 1024 * 1024);
    defer a.free(bytes);
    const saved_path = try files.siblingPath("reader-background.image");
    defer a.free(saved_path);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, saved_path);
    defer a.free(wide);
    try disk.writeAll(wide, bytes);
    if (self.image) |old| old.deinit();
    self.image = image;
    self.version += 1;
    self.message = "Background image saved.";
}
fn remove(self: *Self) !void {
    const Delete = struct {
        extern "kernel32" fn DeleteFileW([*:0]const u16) callconv(.winapi) i32;
    };
    const path = try files.siblingPath("reader-background.image");
    defer a.free(path);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
    defer a.free(wide);
    if (Delete.DeleteFileW(wide) == 0) return error.CannotRemoveBackground;
    if (self.image) |image| image.deinit();
    self.image = null;
    self.version += 1;
    self.message = "Background image removed.";
}
pub fn renderThemeSettings(self: *Self, frame: *ui.Frame, pointer: ?[2]f32) !void {
    const Section = @import("../../ui/settings_section.zig");
    const general: Section = .{ .key = .str("settings.theme.section"), .title = "Color theme" };
    _ = try general.open(frame);
    try self.appearance.renderTheme(frame);
    try general.close(frame);
    const background: Section = .{ .key = .str("settings.background"), .title = "Background and glass" };
    _ = try background.open(frame);
    try frame.e(ui.component.Text{ .key = .src(@src()), .content = "Background image", .selectable = false });
    if (try Drops.render(frame, pointer)) |path| {
        self.useImage(path) catch {
            self.message = "Could not load or save that image. Try a PNG or JPEG under 64 MB (up to 8192 pixels per side).";
        };
        frame.requestRedraw();
    }
    if ((try frame.interact(@import("../../ui/project_button.zig"){ .key = .src(@src()), .label = "Remove background", .disabled = self.image == null })).clicked) {
        self.remove() catch {
            self.message = "Could not remove the saved background.";
        };
        frame.requestRedraw();
    }
    try frame.e(ui.component.Text{ .key = .src(@src()), .content = self.message, .style = &.{ .width = .grow(), .wrap = true, .font_size = .sm, .foreground = .dimmed }, .selectable = false });
    try self.appearance.renderImageScaling(frame);
    try self.appearance.renderGlass(frame);
    try background.close(frame);
    const popup: Section = .{ .key = .str("settings.popup.appearance"), .title = "Dictionary popup" };
    _ = try popup.open(frame);
    try self.appearance.renderPopup(frame);
    try popup.close(frame);
    const buttons: Section = .{ .key = .str("settings.button.appearance"), .title = "Button appearance" };
    _ = try buttons.open(frame);
    try self.appearance.renderButtons(frame);
    try buttons.close(frame);
}

pub fn renderBehind(self: *const Self, frame: *ui.Frame) !void {
    const image = self.image orelse return;
    const measured = try frame.ui().state.getOrCreate(.measured, frame.ui().allocator, canvas_key.hash());
    if (measured.width <= 0 or measured.height <= 0) {
        frame.requestRedraw();
        return;
    }
    const size = scaledSize(self.appearance.image_scaling, measured.width, measured.height, @floatFromInt(image.width), @floatFromInt(image.height));
    try frame.e(ui.component.Image{
        .key = .str("reader.background.image"),
        .source = .{ .pixels = .{ .data = image.pixels, .width = image.width, .height = image.height, .upload_policy = .versioned, .version = self.version } },
        .style = &.{ .position = .absolute, .width = .fixed(size[0]), .height = .fixed(size[1]), .offset = .{ (measured.width - size[0]) / 2, (measured.height - size[1]) / 2 } },
    });
}
fn scaledSize(mode: Appearance.ImageScaling, width: f32, height: f32, image_w: f32, image_h: f32) [2]f32 {
    const scale = switch (mode) {
        .fit => @min(width / image_w, height / image_h),
        .fill => @max(width / image_w, height / image_h),
        .stretch => return .{ width, height },
        .original => return .{ image_w, image_h },
    };
    return .{ image_w * scale, image_h * scale };
}
