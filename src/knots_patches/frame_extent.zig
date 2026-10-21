//! UI frames need nonzero client and framebuffer sizes, including after minimize.
const std = @import("std");
pub fn canRender(logical: anytype, physical: anytype) bool {
    return logical.width > 0 and logical.height > 0 and physical.width > 0 and physical.height > 0;
}
test "skip minimized and transient zero extents, resume after restore or maximize" {
    const Size = struct { width: u32, height: u32 };
    const normal: Size = .{ .width = 1100, .height = 760 };
    const maximized: Size = .{ .width = 1920, .height = 1040 };
    const minimized: Size = .{ .width = 0, .height = 0 };
    try std.testing.expect(canRender(normal, normal));
    try std.testing.expect(canRender(maximized, maximized));
    try std.testing.expect(!canRender(minimized, minimized));
    try std.testing.expect(!canRender(normal, minimized));
    try std.testing.expect(!canRender(minimized, normal));
    try std.testing.expect(!canRender(Size{ .width = 0, .height = 760 }, normal));
    try std.testing.expect(!canRender(normal, Size{ .width = 1920, .height = 0 }));
    try std.testing.expect(canRender(normal, normal));
}
