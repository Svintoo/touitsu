//! Native Windows clipboard menu for Knots' custom text controls.
const ui = @import("ui");
const Point = extern struct { x: i32, y: i32 };
extern "user32" fn CreatePopupMenu() callconv(.winapi) ?*anyopaque;
extern "user32" fn AppendMenuW(?*anyopaque, u32, usize, [*:0]const u16) callconv(.winapi) i32;
extern "user32" fn TrackPopupMenu(?*anyopaque, u32, i32, i32, i32, ?*anyopaque, ?*const anyopaque) callconv(.winapi) u32;
extern "user32" fn DestroyMenu(?*anyopaque) callconv(.winapi) i32;
extern "user32" fn GetCursorPos(*Point) callconv(.winapi) i32;
extern "user32" fn IsClipboardFormatAvailable(u32) callconv(.winapi) i32;

pub fn render(frame: *ui.Frame, window: anytype) !void {
    const u = frame.ui();
    var selected = u.state.selection_text;
    for (u.input.key_events) |event| {
        if (event.key == .c and event.action == .press and event.mods.ctrl and !event.mods.alt and selected.len > 0)
            try frame.writeClipboard(selected);
    }
    if (!u.input.mouseButton(.right).released) return;
    var editable = false;
    for (u.focus_order.items) |id| {
        if (u.state.get(.text_input, id) != null and u.isHoveredWithin(id)) {
            if (u.state.focused != id) selected = "";
            u.state.focused = id;
            editable = true;
            break;
        }
    }
    if (selected.len == 0 and !editable) return;
    const menu = CreatePopupMenu() orelse return;
    defer _ = DestroyMenu(menu);
    _ = AppendMenuW(menu, if (selected.len == 0) 1 else 0, 1, &@import("std").unicode.utf8ToUtf16LeStringLiteral("Copy\tCtrl+C").*);
    if (editable) _ = AppendMenuW(menu, if (IsClipboardFormatAvailable(13) == 0) 1 else 0, 2, &@import("std").unicode.utf8ToUtf16LeStringLiteral("Paste\tCtrl+V").*);
    var point: Point = undefined;
    if (GetCursorPos(&point) == 0) return;
    const command = TrackPopupMenu(menu, 0x100 | 0x2, point.x, point.y, 0, window.getWindowHandle().windows.hwnd, null);
    switch (command) {
        1 => if (selected.len > 0) try frame.writeClipboard(selected),
        2 => try window.requestPaste(),
        else => {},
    }
    frame.requestRedraw();
}
