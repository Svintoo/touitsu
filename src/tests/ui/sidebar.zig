const std = @import("std");
const ui = @import("ui");
const App = @import("../../main.zig");
const Sidebar = @import("../../ui/sidebar.zig").Components(App).Sidebar;

test "hook history preview sidebar autohide slides its handle without moving the reader" {
    var context = try ui.Context.init(std.testing.allocator, .{
        .ui = .{ .fonts = &.{.{ .name = "default", .data = @embedFile("../../fonts/jp.ttf") }} },
    });
    defer context.deinit();
    var app: App = undefined;
    app.texthooking_collapsed = true;
    app.sidebar_tab = .about;
    app.about = .{};
    app.reader = .{ .dictionaries = .{}, .options = .{ .autohide = true } };
    defer app.reader.deinit();
    const times = [_]i64{ 0, 100, 3099, 3100, 3210, 3400, 3600, 3710, 3900 };
    var reader_x: f32 = 0;
    var reader_width: f32 = 0;
    var button_x: f32 = 0;
    for (times, 0..) |now, iteration| {
        const hidden = iteration >= 3 and iteration <= 5;
        var frame = try context.beginFrame(.{
            .input = .{ .pos = .{ -1, -1 }, .focused = iteration == 0 or iteration >= 6 },
            .now_ms = now,
            .delta_ns = 16_000_000,
            .logical_extent = .{ .width = 1200, .height = 600 },
            .physical_extent = .{ .width = 1200, .height = 600 },
            .content_scale = 1,
        });
        defer frame.deinit();
        app.reader.updateControlsVisibility(&frame, !app.texthooking_collapsed);
        try std.testing.expectEqual(hidden, app.reader.controls_hidden);
        const root: ui.component.Rect = .{ .key = .str("test.sidebar.root"), .style = &.{ .width = .fixed(1200), .height = .fixed(600), .direction = .row, .padding = .all(12), .gap = 12 } };
        _ = try root.open(&frame);
        try (Sidebar{ .self = &app }).render(&frame);
        try frame.e(ui.component.Rect{ .key = .str("test.reader"), .style = &.{ .width = .grow(), .height = .grow() } });
        try root.close(&frame);
        const output = try context.endFrame(&frame);
        const reader = context.ui.layout_ctx.pool.elements.items[context.ui.layout_ctx.slotForId(ui.Key.str("test.reader").hash()).?].box;
        const sidebar = context.ui.layout_ctx.pool.elements.items[context.ui.layout_ctx.slotForId(ui.Key.str("texthooking.viewport").hash()).?].box;
        try std.testing.expectEqual(@as(f32, 22), sidebar.w());
        if (iteration == 0) {
            reader_x = reader.x();
            reader_width = reader.w();
        }
        try std.testing.expectEqual(reader_x, reader.x());
        try std.testing.expectEqual(reader_width, reader.w());
        const button_slot = context.ui.layout_ctx.slotForId(ui.Key.str("sidebar.collapse.button").hash());
        if (iteration == 5) {
            try std.testing.expect(button_slot == null);
        } else if (button_slot) |slot| {
            const button = context.ui.layout_ctx.pool.elements.items[slot];
            if (iteration == 0) button_x = button.box.x();
            if (iteration == 4 or iteration == 7) try std.testing.expect(button.box.x() < button_x);
            if (iteration == 8) try std.testing.expectEqual(button_x, button.box.x());
            try std.testing.expectEqual(!hidden, button.interactive);
        } else return error.MissingSidebarButton;
        if (iteration == 4 or iteration == 7) try std.testing.expect(output.redraw);
    }
}
