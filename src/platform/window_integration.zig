//! Windows integration around an unmodified Knots window.
const knots = @import("knots");
const Viewport = @typeInfo(@FieldType(knots.App, "main_viewport")).pointer.child;
const Window = @FieldType(Viewport, "window");
const FrameHandler = @typeInfo(@FieldType(Window, "frame_handler")).optional.child;
const HWND = ?*anyopaque;
const SubclassProc = *const fn (HWND, u32, usize, isize, usize, usize) callconv(.winapi) isize;

extern "comctl32" fn SetWindowSubclass(HWND, SubclassProc, usize, usize) callconv(.winapi) i32;
extern "comctl32" fn RemoveWindowSubclass(HWND, SubclassProc, usize) callconv(.winapi) i32;
extern "comctl32" fn DefSubclassProc(HWND, u32, usize, isize) callconv(.winapi) isize;
extern "user32" fn DefWindowProcW(HWND, u32, usize, isize) callconv(.winapi) isize;
extern "user32" fn GetWindowLongPtrW(HWND, i32) callconv(.winapi) isize;
extern "user32" fn LoadImageW(?*anyopaque, [*:0]align(1) const u16, u32, i32, i32, u32) callconv(.winapi) ?*anyopaque;
extern "user32" fn GetSystemMetrics(i32) callconv(.winapi) i32;
extern "user32" fn SendMessageW(HWND, u32, usize, isize) callconv(.winapi) isize;
extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.winapi) ?*anyopaque;

window: ?*Window = null,
hwnd: HWND = null,
frame_handler: ?FrameHandler = null,
const Self = @This();

/// Call once the application is at its final address, before App.start.
pub fn attach(self: *Self, window: *Window) !void {
    const hwnd = window.getWindowHandle().windows.hwnd;
    self.window = window;
    if (SetWindowSubclass(hwnd, nativeCaption, @intFromPtr(self), @intFromPtr(self)) == 0)
        return error.CannotInstallWindowIntegration;
    self.hwnd = hwnd;
    errdefer self.detach();

    // WM_SETICON sets the icon on this window without changing Knots' class.
    // LR_SHARED gives these resource icons module lifetime; do not destroy them.
    const instance = GetModuleHandleW(null);
    const big = LoadImageW(instance, @ptrFromInt(1), 1, GetSystemMetrics(11), GetSystemMetrics(12), 0x8000) orelse return error.CannotLoadWindowIcon;
    const small = LoadImageW(instance, @ptrFromInt(1), 1, GetSystemMetrics(49), GetSystemMetrics(50), 0x8000) orelse return error.CannotLoadWindowIcon;
    _ = SendMessageW(hwnd, 0x0080, 1, @bitCast(@intFromPtr(big)));
    _ = SendMessageW(hwnd, 0x0080, 0, @bitCast(@intFromPtr(small)));
}

/// App.start installs its handler before the first frame. Wrap that handler
/// from our first frame, before any asynchronous work requests further frames.
pub fn guardFrames(self: *Self) void {
    if (self.frame_handler != null) return;
    const window = self.window orelse return;
    self.frame_handler = window.frame_handler orelse return;
    window.setFrameHandler(.{ .ctx = self, .step = stepFrame });
}

pub fn detach(self: *Self) void {
    if (self.hwnd) |hwnd| _ = RemoveWindowSubclass(hwnd, nativeCaption, @intFromPtr(self));
    if (self.window) |window| {
        if (window.frame_handler) |handler| {
            if (handler.ctx == @as(*anyopaque, @ptrCast(self))) {
                if (self.frame_handler) |original| window.setFrameHandler(original);
            }
        }
    }
    self.* = .{};
}

fn stepFrame(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const window = self.window orelse return;
    const logical = window.getSize();
    const physical = window.getFramebufferSize();
    // The resize event is consumed once, but completion/paint events can keep
    // arriving while minimized. Do not enter App's frame machinery at zero size.
    if (logical.width == 0 or logical.height == 0 or physical.width == 0 or physical.height == 0) return;
    const original = self.frame_handler orelse return;
    original.step(original.ctx);
}

fn nativeCaption(hwnd: HWND, message: u32, wparam: usize, lparam: isize, _: usize, reference: usize) callconv(.winapi) isize {
    const self: *Self = @ptrFromInt(reference);
    // Knots intercepts HTMAXBUTTON for its custom TitleBar. Our native caption
    // must instead reach Windows' default handler, including snap/maximize.
    const native_caption = GetWindowLongPtrW(hwnd, -16) & 0x00c00000 != 0;
    if (native_caption and wparam == 9) switch (message) {
        0x00a0 => { // WM_NCMOUSEMOVE
            if (self.window) |window| window.pointerLeft();
            return DefWindowProcW(hwnd, message, wparam, lparam);
        },
        0x00a1, 0x00a2, 0x00a3 => return DefWindowProcW(hwnd, message, wparam, lparam),
        else => {},
    };
    return DefSubclassProc(hwnd, message, wparam, lparam);
}
