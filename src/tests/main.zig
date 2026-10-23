//! Tests for main.zig.
const subject = @import("../main.zig");

pub fn Tests(comptime private: anytype) type {
    return struct {
        const std = @import("std");
        const ui = @import("ui");
        const tx = @import("../components/textractor/textractor.zig");
        const procs = @import("../components/textractor/procs.zig");
        const Reader = @import("../components/reader/reader.zig");
        const FontSettings = @import("../components/fonts/font_settings.zig");
        const BackgroundImage = @import("../components/appearance/background_image.zig");
        const AnkiSettings = @import("../components/anki/anki_settings.zig");
        const Rect = ui.component.Rect;
        const alloc = std.heap.smp_allocator;
        const Self = subject;
        const TextractorUI = @import("../components/textractor/textractor_ui.zig").Components(Self);
        const TextractorSettings = TextractorUI.Settings;
        const HookPreview = TextractorUI.HookPreview;
        const isBuiltin = subject.isBuiltin;

        test "hook history preview search candidates sort by code and preserve selection" {
            var self: Self = undefined;
            self.candidates = .empty;
            self.selected_candidate = null;
            defer {
                self.clearCandidates();
                self.candidates.deinit(alloc);
            }
            try private.pushCandidate(&self, 1, "HS2@30", "second", null);
            try private.pushCandidate(&self, 1, "HS1@20", "first", null);
            self.selected_candidate = 1;
            try private.pushCandidate(&self, 1, "HS1@10", "earlier", null);
            try std.testing.expectEqualStrings("HS1@10", self.candidates.items[0].code);
            try std.testing.expectEqualStrings("HS1@20", self.candidates.items[1].code);
            try std.testing.expectEqualStrings("HS2@30", self.candidates.items[2].code);
            try std.testing.expectEqual(@as(?usize, 2), self.selected_candidate);
            try private.pushCandidate(&self, 1, "HS1@20", "updated", 42);
            try std.testing.expectEqual(@as(usize, 3), self.candidates.items.len);
            try std.testing.expectEqualStrings("updated", self.candidates.items[1].text);
            try std.testing.expectEqual(@as(?u64, 42), self.candidates.items[1].thread_handle);
            try std.testing.expectEqual(@as(?usize, 2), self.selected_candidate);
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
            for ([_]@import("../components/reader/reading_layout.zig").Direction{ .horizontal, .vertical_left, .vertical_right, .horizontal }, 0..) |direction, mode| {
                var ui_context = try ui.Context.init(std.testing.allocator, .{ .ui = .{ .fonts = &.{.{ .name = "default", .data = @embedFile("../fonts/jp.ttf") }} } });
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
            var appearance: @import("../components/appearance/appearance_settings.zig") = .{};
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
            var audio: @import("../components/pronunciation/pronunciation.zig") = .{
                .status_key = std.hash.Wyhash.hash(std.hash.Wyhash.hash(0, "猫"), "ねこ"),
                .status = "Loading pronunciation...",
            };
            defer audio.deinit();
            var ui_context = try ui.Context.init(std.testing.allocator, .{ .ui = .{ .fonts = &.{.{ .name = "default", .data = @embedFile("../fonts/jp.ttf") }} } });
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
            var audio: @import("../components/pronunciation/pronunciation.zig") = .{};
            defer audio.deinit();
            try audio.play("猫", "ねこ", false);
            try std.testing.expect(audio.job == null);
            try std.testing.expect(audio.thread == null);
            const appearance: @import("../components/appearance/appearance_settings.zig") = .{};
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
            var ui_context = try ui.Context.init(std.testing.allocator, .{ .ui = .{ .fonts = &.{.{ .name = "default", .data = @embedFile("../fonts/jp.ttf") }} } });
            defer ui_context.deinit();
            var frame_ctx = try ui_context.beginFrame(.{ .input = .{ .pos = .{ 0, 0 }, .key_events = &.{.{ .key = .c, .action = .press, .mods = .{ .ctrl = true } }} }, .now_ms = 0, .delta_ns = 16_000_000, .logical_extent = .{ .width = 500, .height = 500 }, .physical_extent = .{ .width = 500, .height = 500 }, .content_scale = 1 });
            defer frame_ctx.deinit();
            frame_ctx.ui().state.selection_text = "reader selection";
            try @import("../ui/text_context_menu.zig").render(&frame_ctx, &window);
            const output = try ui_context.endFrame(&frame_ctx);
            try std.testing.expectEqualStrings("reader selection", output.clipboard_write.?);
        }

        test "hook history preview scrollbar drags never turn into text selections" {
            var ui_context = try ui.Context.init(std.testing.allocator, .{ .ui = .{ .fonts = &.{.{ .name = "default", .data = @embedFile("../fonts/jp.ttf") }} } });
            defer ui_context.deinit();
            const Selection = @import("../components/reader/shift_selection.zig");
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
            var ui_context = try ui.Context.init(std.testing.allocator, .{ .ui = .{ .fonts = &.{.{ .name = "default", .data = @embedFile("../fonts/jp.ttf") }} } });
            defer ui_context.deinit();
            var selection: @import("../components/reader/shift_selection.zig") = .{};
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
                for (self.threads.items) |*thread| private.deinitThread(thread);
                self.threads.deinit(alloc);
                for (self.enabled_hooks.items) |hook| alloc.free(hook.code);
                self.enabled_hooks.deinit(alloc);
                self.reader.deinit();
            }
            const meta: tx.ThreadMeta = .{ .pid = 42, .handle = 1, .addr = 1234, .ctx = 1, .ctx2 = 0, .name = @constCast("Test hook"), .hook_code = @constCast("HS0@1234") };
            _ = try private.ensureThread(&self, meta);
            var sibling = meta;
            sibling.handle = 2;
            sibling.ctx = 2;
            _ = try private.ensureThread(&self, sibling);
            var other = meta;
            other.handle = 3;
            other.addr = 9999;
            other.hook_code = @constCast("HS0@9999");
            _ = try private.ensureThread(&self, other);
            try private.acceptHook(&self, 42, meta.hook_code);
            try std.testing.expectEqual(@as(u64, 1), self.selected.?.handle);
            try private.acceptHook(&self, 42, other.hook_code);
            try std.testing.expectEqual(@as(u64, 1), self.selected.?.handle);
            self.threads.items[0].reduce_pairs = true;
            self.threads.items[1].reduce_pairs = true;
            try private.handleEvent(&self, .{ .text = .{ .meta = meta, .text = @constCast("aappppllee") } }, 0);
            try std.testing.expectEqualStrings("apple", self.reader.lines.items[0].text);
            self.selected = .{ .pid = 42, .handle = 3 };
            try private.handleEvent(&self, .{ .text = .{ .meta = other, .text = @constCast("book") } }, 0);
            try std.testing.expectEqualStrings("book", self.reader.lines.items[1].text);

            self.reader.capture_paused = true;
            const preview_count = self.threads.items[2].lines.items.len;
            try private.handleEvent(&self, .{ .text = .{ .meta = other, .text = @constCast("paused material") } }, 0);
            try std.testing.expectEqual(@as(usize, 2), self.reader.lines.items.len);
            try std.testing.expectEqual(preview_count + 1, self.threads.items[2].lines.items.len);
            self.reader.capture_paused = false;
            try private.handleEvent(&self, .{ .text = .{ .meta = other, .text = @constCast("resumed material") } }, 0);
            try std.testing.expectEqual(@as(usize, 3), self.reader.lines.items.len);
            try std.testing.expectEqualStrings("resumed material", self.reader.lines.items[2].text);

            var ui_context = try ui.Context.init(std.testing.allocator, .{ .ui = .{ .fonts = &.{.{ .name = "default", .data = @embedFile("../fonts/jp.ttf") }} } });
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
                .ui = .{ .fonts = &.{.{ .name = "default", .data = @embedFile("../fonts/jp.ttf") }} },
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
            for ([_]@import("../components/reader/reading_layout.zig").Direction{ .horizontal, .vertical_left, .vertical_right, .horizontal }, 0..) |direction, iteration| {
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
            for ([_]@import("../components/reader/reading_layout.zig").Direction{ .horizontal, .vertical_left, .vertical_right, .horizontal }, 0..) |direction, mode| {
                var ui_context = try ui.Context.init(std.testing.allocator, .{ .ui = .{ .fonts = &.{.{ .name = "default", .data = @embedFile("../fonts/jp.ttf") }} } });
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
                var saved_anchor: ?@import("../components/reader/reader_document.zig").Anchor = null;
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
                .ui = .{ .fonts = &.{.{ .name = "default", .data = @embedFile("../fonts/jp.ttf") }} },
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
                for (self.threads.items) |*thread| private.deinitThread(thread);
                self.threads.deinit(alloc);
                self.clearCandidates();
                self.candidates.deinit(alloc);
            }
            const thread = try private.ensureThread(&self, .{ .pid = 42, .handle = 7, .addr = 0, .ctx = 0, .ctx2 = 0, .name = @constCast("GetGlyphOutlineA"), .hook_code = @constCast("HS0@1234") });
            try private.pushLine(&self, thread, "Captured before selecting this hook");
            try private.pushCandidate(&self, thread.pid, thread.code, "Captured before selecting this hook", thread.handle);
            self.selected_candidate = 0;
            try std.testing.expect(self.selected == null);
            try std.testing.expect(!thread.accepted);
            var reader: Reader = .{ .dictionaries = .{} };
            defer reader.deinit();
            var fonts: FontSettings = .{};
            var background: BackgroundImage = .{};
            var anki: AnkiSettings = .{ .gpa = std.testing.allocator };
            const directions = [_]@import("../components/reader/reading_layout.zig").Direction{ .horizontal, .vertical_left, .vertical_right, .horizontal };
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
                .ui = .{ .fonts = &.{.{ .name = "default", .data = @embedFile("../fonts/jp.ttf") }} },
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
                for (self.threads.items) |*thread| private.deinitThread(thread);
                self.threads.deinit(alloc);
            }
            const console: tx.ThreadMeta = .{ .pid = 0, .handle = 1, .addr = 0, .ctx = 0, .ctx2 = 0, .name = @constCast("Console"), .hook_code = @constCast("") };
            const clipboard: tx.ThreadMeta = .{ .pid = 0, .handle = 2, .addr = 0, .ctx = 0, .ctx2 = 0, .name = @constCast("Clipboard"), .hook_code = @constCast("") };
            try private.handleEvent(&self, .{ .thread_created = console }, 0);
            try private.handleEvent(&self, .{ .thread_created = clipboard }, 0);
            try private.handleEvent(&self, .{ .text = .{ .meta = console, .text = @constCast("Unselected console") } }, 1);
            try std.testing.expect(self.selected == null);
            try std.testing.expectEqual(@as(usize, 0), self.reader.lines.items.len);
            self.selected = .{ .pid = 0, .handle = 2 };
            try private.handleEvent(&self, .{ .text = .{ .meta = clipboard, .text = @constCast("Copied text") } }, 2);
            try private.handleEvent(&self, .{ .text = .{ .meta = console, .text = @constCast("Console stays in preview") } }, 3);
            try std.testing.expectEqual(@as(usize, 1), self.reader.lines.items.len);
            try std.testing.expectEqualStrings("Copied text", self.reader.lines.items[0].text);
            var ui_context = try ui.Context.init(std.testing.allocator, .{ .ui = .{ .fonts = &.{.{ .name = "default", .data = @embedFile("../fonts/jp.ttf") }} } });
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
            var context = try ui.Context.init(std.testing.allocator, .{ .ui = .{ .fonts = &.{.{ .name = "default", .data = @embedFile("../fonts/jp.ttf") }} } });
            defer context.deinit();
            const paths = [_][]const u8{ "one.zip", "two.zip" };
            const dict_key: ui.Key = .str("test.drop.dictionaries");
            var pointer: [2]f32 = .{ -1, -1 };
            for (0..2) |iteration| {
                var frame_ctx = try context.beginFrame(.{ .input = .{ .pos = .{ pointer[0], pointer[1] } }, .now_ms = @intCast(iteration * 16), .delta_ns = 16_000_000, .logical_extent = .{ .width = 440, .height = 400 }, .physical_extent = .{ .width = 440, .height = 400 }, .content_scale = 1, .dropped_paths = if (iteration == 1) &paths else &.{} });
                defer frame_ctx.deinit();
                const root: Rect = .{ .key = .str("test.drop.root"), .style = &.{ .width = .fixed(440), .height = .fixed(400), .direction = .column } };
                _ = try root.open(&frame_ctx);
                const dict_paths = try @import("../ui/drops.zig").renderPaths(&frame_ctx, pointer, dict_key, "Dictionaries");
                const font_paths = try @import("../ui/drops.zig").renderPaths(&frame_ctx, pointer, .str("test.drop.fonts"), "Fonts");
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
    };
}
