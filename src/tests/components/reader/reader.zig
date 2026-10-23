const std = @import("std");
const ui = @import("ui");
const Reader = @import("../../../components/reader/reader.zig");
const FontSettings = @import("../../../components/fonts/font_settings.zig");
const BackgroundImage = @import("../../../components/appearance/background_image.zig");
const AnkiSettings = @import("../../../components/anki/anki_settings.zig");
const Button = @import("../../../ui/project_button.zig");

const Harness = struct {
    context: ui.Context,
    reader: Reader = .{ .dictionaries = .{} },
    fonts: FontSettings = .{},
    background: BackgroundImage = .{},
    anki: AnkiSettings = .{ .gpa = std.testing.allocator },
    now: i64 = 0,

    fn draw(self: *Harness, action: ?ui.Key, pointer: ?[2]f32) !ui.Frame.Output {
        if (action) |key| try self.context.enqueueAccessibilityAction(.{ .id = key.hash(), .action = .click });
        self.now += 200;
        var frame = try self.context.beginFrame(.{
            .input = .{ .pos = .{ -1, -1 } },
            .now_ms = self.now,
            .delta_ns = 200_000_000,
            .logical_extent = .{ .width = 1200, .height = 600 },
            .physical_extent = .{ .width = 1200, .height = 600 },
            .content_scale = 1,
        });
        defer frame.deinit();
        self.background.appearance.applyTheme(&frame);
        self.reader.shift_selection.pointer = pointer;
        const root: ui.component.Rect = .{ .key = .str("test.reader.root"), .style = &.{ .width = .fixed(1200), .height = .fixed(600) } };
        _ = try root.open(&frame);
        try self.reader.render(&frame, &self.fonts, &self.background, &self.anki);
        try root.close(&frame);
        return self.context.endFrame(&frame);
    }

    fn settle(self: *Harness) !ui.Frame.Output {
        _ = try self.draw(null, null);
        return self.draw(null, null);
    }
};

fn expectActions(output: ui.Frame.Output, delete_enabled: bool, undo_enabled: bool) !void {
    var found: usize = 0;
    for (output.accessibility.nodes) |node| {
        const enabled = if (std.mem.eql(u8, node.name, "Delete last")) delete_enabled else if (std.mem.eql(u8, node.name, "Undo")) undo_enabled else continue;
        found += 1;
        try std.testing.expectEqual(!enabled, node.state.disabled);
        try std.testing.expectEqual(enabled, node.actions.contains(.click));
    }
    try std.testing.expectEqual(@as(usize, 2), found);
}

test "hook history preview reader delete and undo follow availability and shared button appearance" {
    const original_style = Button.current;
    defer Button.current = original_style;
    inline for (.{ .solid, .outline, .ghost, .glass }) |mode| {
        var harness: Harness = .{ .context = try ui.Context.init(std.testing.allocator, .{
            .ui = .{ .fonts = &.{.{ .name = "default", .data = @embedFile("../../../fonts/jp.ttf") }} },
        }) };
        defer harness.context.deinit();
        defer harness.reader.deinit();
        harness.background.appearance.buttons.mode = mode;
        try expectActions(try harness.settle(), false, false);
        // Empty controls ignore activation, including Undo with no deleted lines.
        _ = try harness.draw(.str("reader.undo"), null);
        _ = try harness.draw(.str("reader.delete_last"), null);
        try std.testing.expectEqual(@as(usize, 0), harness.reader.lines.items.len);

        try harness.reader.append("First line");
        try harness.reader.append("Second line");
        try expectActions(try harness.settle(), true, false);
        const row = harness.context.ui.state.get(.measured, ui.Key.str("reader.row").indexed(0).hash()).?.box;
        const pointer = [2]f32{ row.x() + 4, row.y() + 4 };
        // Delete an individual line through its hover control.
        _ = try harness.draw(ui.Key.str("reader.delete").indexed(0), pointer);
        try std.testing.expectEqual(@as(usize, 1), harness.reader.lines.items.len);
        const output = try harness.settle();
        try expectActions(output, true, true);

        // Both enabled actions have the same rendered surface as the other toolbar buttons.
        var compared = false;
        for (output.accessibility.nodes) |node| {
            if (!std.mem.eql(u8, node.name, "Pause capture")) continue;
            compared = true;
            const reference = harness.context.ui.layout_ctx.slotForId(node.id).?;
            for ([_]ui.Key{ .str("reader.delete_last"), .str("reader.undo") }) |key| {
                const slot = harness.context.ui.layout_ctx.slotForId(key.hash()).?;
                try std.testing.expectEqualDeep(harness.context.ui.decorations.items[reference], harness.context.ui.decorations.items[slot]);
            }
        }
        try std.testing.expect(compared);

        _ = try harness.draw(.str("reader.delete_last"), null);
        try std.testing.expectEqual(@as(usize, 0), harness.reader.lines.items.len);
        try expectActions(try harness.settle(), false, true);
        _ = try harness.draw(.str("reader.undo"), null);
        try std.testing.expectEqualStrings("Second line", harness.reader.lines.items[0].text);
        try expectActions(try harness.settle(), true, true);
        _ = try harness.draw(.str("reader.undo"), null);
        try std.testing.expectEqual(@as(usize, 2), harness.reader.lines.items.len);
        try std.testing.expectEqualStrings("First line", harness.reader.lines.items[0].text);
        try std.testing.expectEqualStrings("Second line", harness.reader.lines.items[1].text);
        try expectActions(try harness.settle(), true, false);
    }
}
