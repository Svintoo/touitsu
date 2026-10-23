//! Sidebar navigation, collapse control, and settings-page routing.
const ui = @import("ui");
const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = @import("project_button.zig");

pub fn Components(comptime App: type) type {
    return struct {
        const Self = App;
        const TextractorUI = @import("../components/textractor/textractor_ui.zig").Components(App);
        /// All Textractor controls live in one scrollable sidebar category.
        pub const Sidebar = struct {
            self: *Self,

            pub fn render(sidebar: *const Sidebar, context: *ui.Frame) anyerror!void {
                const self = sidebar.self;
                // Reserve a scrollbar gutter without narrowing the sidebar controls.
                const scrollbar_gutter = context.ui().theme.scrollbar_thickness + 8;
                // Autohide changes only the handle's visibility, never the reader's width.
                const toggle_width: f32 = 22;
                const available: f32 = @floatFromInt(context.input().logical_extent.width);
                const content_width = if (self.sidebar_tab == .textractor) @max(0, available * 0.75 - toggle_width - scrollbar_gutter) else @min(516, @max(0, available * 0.75 - toggle_width - scrollbar_gutter));
                const width = context.ui().anim(ui.Key.str("texthooking.sidebar").hash(), "width", if (self.texthooking_collapsed) toggle_width else content_width + scrollbar_gutter + toggle_width, .{ .duration_ms = 220 });
                const viewport: Rect = .{ .key = ui.Key.str("texthooking.viewport"), .style = &.{
                    .width = .fixed(width),
                    .height = .grow(),
                    .overflow = .hidden,
                } };
                _ = try viewport.open(context);
                defer viewport.close(context) catch {};
                try context.e(.{
                    Rect{ .key = .src(@src()), .style = &.{
                        .width = .fixed(width),
                        .height = .grow(),
                        .direction = .row,
                        .background = .elevated,
                        .radius = if (self.texthooking_collapsed) .none else .{ .corners = .{ .md, .none, .none, .md } },
                        .overflow = .hidden,
                    } },
                    .{
                        // Clip the fixed-width contents while the edge control follows the animation.
                        Rect{ .key = .src(@src()), .style = &.{ .width = .fixed(@max(0, width - toggle_width)), .height = .grow(), .overflow = .hidden } },
                        .{
                            Rect{ .key = .src(@src()), .style = &.{ .width = .fixed(content_width + scrollbar_gutter), .height = .grow(), .direction = .row, .gap = 12, .padding = .all(12) } },
                            .{
                                Rect{ .key = .str("sidebar.navigation"), .style = &.{
                                    .width = .fixed(160),
                                    .height = .grow(),
                                    .direction = .column,
                                    .gap = 12,
                                    .padding = .all(8),
                                    .background = .bg,
                                    .radius = .md,
                                } },
                                .{
                                    Text{ .key = .src(@src()), .content = "Touitsu", .style = &.{ .font_size = .xl }, .selectable = false },
                                    SidebarTabs{ .self = self },
                                },
                                SidebarContent{ .self = self },
                            },
                        },
                        SidebarCollapse{ .self = self },
                    },
                });
            }
        };

        const SidebarCollapse = struct {
            self: *Self,
            pub fn render(control: *const SidebarCollapse, context: *ui.Frame) anyerror!void {
                const hidden = control.self.reader.controls_hidden;
                const slide = context.ui().anim(ui.Key.str("sidebar.collapse").hash(), "slide", if (hidden) -22 else 0, .{ .duration_ms = 220 });
                if (hidden and slide <= -22) return;
                const slot: Rect = .{ .key = .str("sidebar.collapse.slot"), .style = &.{ .width = .fixed(22), .height = .grow(), .overflow = .hidden } };
                _ = try slot.open(context);
                defer slot.close(context) catch {};
                const button: Button = .{ .key = .str("sidebar.collapse.button"), .appearance = .explicit, .disabled = hidden, .style = &.{
                    .width = .fixed(22),
                    .height = .grow(),
                    .padding = .all(0),
                    .position = .absolute,
                    .offset = .{ slide, 0 },
                    .justify = .center,
                    .@"align" = .center,
                    .radius = .none,
                    .background = .transparent,
                    .foreground = .dimmed,
                    .border_width = .{ .value = .{ 0, 0, 0, 1 } },
                    .border_color = .toned,
                    .hover = &.{ .background = .muted, .foreground = .text },
                } };
                // The absolute offset slides the handle inside its reserved, clipped slot.
                const response = try button.openResponse(context);
                try context.e(ui.component.Image{
                    .key = .str("sidebar.collapse.icon"),
                    .source = .{ .pixels = .{ .data = @embedFile("../icons/burger-menu.rgba"), .width = 48, .height = 48, .upload_policy = .versioned } },
                    .style = &.{ .width = .fixed(16), .height = .fixed(16), .foreground = .text },
                });
                try button.close(context);
                try context.ui().setAccessibility(response.id, .{ .role = .button, .name = if (control.self.texthooking_collapsed) "Open sidebar" else "Collapse sidebar", .state = .{ .disabled = hidden } });
                if (response.clicked) {
                    control.self.texthooking_collapsed = !control.self.texthooking_collapsed;
                    context.requestRedraw();
                }
            }
        };

        const SidebarTabs = struct {
            self: *Self,
            pub fn render(tabs: *const SidebarTabs, context: *ui.Frame) anyerror!void {
                const row: Rect = .{ .key = .src(@src()), .style = &.{ .width = .fixed(144), .height = .grow(), .direction = .column, .gap = 8, .overflow = .scroll_y } };
                _ = try row.open(context);
                // Add each menu item's icon beside its label here when your SVGs are ready.
                // Textractor icon: add to the .textractor item.
                // Dictionaries icon: add to the .dictionaries item.
                // Font settings icon: add to the .fonts item.
                // Theme icon: add to the .theme item.
                // Anki Settings icon: add to the .anki item.
                const items = .{ .{ .tab = .textractor, .label = "Textractor" }, .{ .tab = .dictionaries, .label = "Dictionaries" }, .{ .tab = .fonts, .label = "Font settings" }, .{ .tab = .theme, .label = "Theme" }, .{ .tab = .settings, .label = "Settings" }, .{ .tab = .anki, .label = "Anki Settings" }, .{ .tab = .about, .label = "About" } };
                inline for (items, 0..) |item, i| {
                    const active = tabs.self.sidebar_tab == item.tab;
                    if ((try context.interact(ui.component.Button{ .key = ui.Key.str("sidebar.tab").indexed(i), .label = item.label, .style = &.{
                        .width = .grow(),
                        .height = .fixed(28),
                        .padding = .xy(4, 0),
                        .font_size = .sm,
                        .background = .transparent,
                        .foreground = if (active) .accent else .text,
                        .border_width = .all(1),
                        .border_color = if (active) .accent else .toned,
                        .radius = .md,
                        .hover = &.{ .background = .muted, .border_color = .accent },
                    } })).clicked) {
                        tabs.self.sidebar_tab = item.tab;
                        context.requestRedraw();
                    }
                }
                try row.close(context);
            }
        };

        const SidebarContent = struct {
            self: *Self,
            pub fn render(content: *const SidebarContent, context: *ui.Frame) anyerror!void {
                const self = content.self;
                Button.settings_outline = true;
                defer Button.settings_outline = false;
                const body: Rect = .{ .key = ui.Key.str("sidebar.body").indexed(@backingInt(self.sidebar_tab)), .style = &.{ .width = .grow(), .height = .grow(), .direction = .column, .gap = 10, .padding = .init(0, context.ui().theme.scrollbar_thickness + 8, 0, 0), .overflow = if (self.sidebar_tab == .textractor) .hidden else .scroll_y } };
                _ = try body.open(context);
                switch (self.sidebar_tab) {
                    .textractor => try (TextractorUI.Settings{ .self = self }).render(context),
                    .fonts => try self.fonts.render(context, self.reader.shift_selection.pointer),
                    .dictionaries => try self.reader.dictionaries.renderSettings(context, self.reader.shift_selection.pointer),
                    .theme => try self.background.renderThemeSettings(context, self.reader.shift_selection.pointer),
                    .settings => {
                        const section: @import("settings_section.zig") = .{ .key = .str("settings.reader"), .title = "Settings" };
                        _ = try section.open(context);
                        try self.background.appearance.renderDirection(context);
                        try section.close(context);
                        const display: @import("settings_section.zig") = .{ .key = .str("settings.display"), .title = "Display" };
                        _ = try display.open(context);
                        if ((try context.interact(Button{ .key = .str("settings.fullscreen"), .label = if (self.app.main_viewport.window.getDisplayMode() == .fullscreen) "Leave fullscreen (F11)" else "Fullscreen (F11)" })).clicked) {
                            self.toggleFullscreen();
                            context.requestRedraw();
                        }
                        try context.e(Text{ .key = .str("settings.fullscreen.help"), .content = "F11 toggles fullscreen. Escape returns to the previous window mode.", .style = &.{ .width = .grow(), .wrap = true, .font_size = .sm, .foreground = .dimmed }, .selectable = false });
                        try display.close(context);
                        const internet: @import("settings_section.zig") = .{ .key = .str("settings.internet"), .title = "Internet audio" };
                        _ = try internet.open(context);
                        try self.background.appearance.renderInternet(context);
                        try internet.close(context);
                    },
                    .anki => try self.anki.render(context),
                    .about => try self.about.render(context),
                }
                try body.close(context);
            }
        };

        pub const ReaderView = struct {
            self: *Self,

            pub fn render(view: *const ReaderView, context: *ui.Frame) anyerror!void {
                try view.self.reader.render(context, &view.self.fonts, &view.self.background, &view.self.anki);
            }
        };
    };
}
