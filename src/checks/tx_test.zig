//! tx_test.zig - console smoke test for the Textractor host and automatic x86/x64 routing.
//!
//!   set TX_PID=<pid of a running x86 or x64 program>
//!   zig-out\bin\tx_test.exe
//!
//! Optional: set TX_HOOK=/HS-4@0 (or any /H code) to insert a hook once connected.
//! Prints every event for ~60 s, then detaches.

const std = @import("std");
const tx = @import("../components/textractor/textractor.zig");

extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
extern "kernel32" fn OpenProcess(access: u32, inherit: i32, pid: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn WaitForSingleObject(h: ?*anyopaque, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn GetExitCodeProcess(h: ?*anyopaque, code: *u32) callconv(.winapi) i32;
extern "kernel32" fn GetEnvironmentVariableA(name: [*:0]const u8, buf: [*]u8, size: u32) callconv(.winapi) u32;

fn env(name: [*:0]const u8, buf: []u8) ?[]const u8 {
    const n = GetEnvironmentVariableA(name, buf.ptr, @intCast(buf.len));
    if (n == 0 or n >= buf.len) return null;
    return buf[0..n];
}

var client: tx.Client = undefined; // global: the shim keeps a pointer to it

pub fn main() !void {
    var pid_buf: [32]u8 = undefined;
    const pid_str = env("TX_PID", &pid_buf) orelse {
        std.debug.print("Set TX_PID=<process id> first.\n", .{});
        return;
    };
    const pid = try std.fmt.parseInt(u32, pid_str, 10);

    var hook_buf: [128]u8 = undefined;
    const hook = env("TX_HOOK", &hook_buf);

    const alloc = std.heap.page_allocator;
    client = .init(alloc);
    client.start();
    std.debug.print("host started; attaching to pid {d}\n", .{pid});
    if (!client.attach(pid)) std.debug.print("attach call failed\n", .{});

    // Watch the target so we can tell "game crashed" from "nothing happened".
    const SYNCHRONIZE: u32 = 0x00100000;
    const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;
    const target = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
    if (target == null) std.debug.print("(could not open target process for monitoring)\n", .{});
    var target_exited = false;

    var events: std.ArrayList(tx.Event) = .empty;
    var search_buf: [16]u8 = undefined;
    const search_cp: ?u32 = if (env("TX_SEARCH", &search_buf)) |sv| (std.fmt.parseInt(u32, sv, 10) catch null) else null;
    var hook_sent = false;
    var ticks: u32 = 0;
    while (ticks < 1200) : (ticks += 1) { // 1200 * 50 ms = 60 s
        Sleep(50);
        if (!target_exited and target != null and WaitForSingleObject(target, 0) == 0) {
            var code: u32 = 0;
            _ = GetExitCodeProcess(target, &code);
            std.debug.print("[TARGET PROCESS EXITED] exit code 0x{X}  (0xC0000005 = access violation / crash)\n", .{code});
            target_exited = true;
        }
        try client.drain(&events, alloc);
        for (events.items) |*ev| {
            switch (ev.*) {
                .backend_error => |error_info| std.debug.print("[backend error] pid {d}: {s}\n", .{ error_info.pid, error_info.message }),
                .connected => |p| {
                    std.debug.print("[connected] pid {d}\n", .{p});
                    if (hook) |h| if (!hook_sent) {
                        hook_sent = true;
                        const ok = try client.insertHook(p, h);
                        std.debug.print("[insert hook] {s} -> {}\n", .{ h, ok });
                    };
                    if (search_cp) |cp| {
                        const ok = try client.findHooks(p, cp, null);
                        std.debug.print("[search started] codepage {d} -> {}  (advance the game's text now)\n", .{ cp, ok });
                    }
                },
                .hook_found => |h| std.debug.print("[hook found] {s}   {s}\n", .{ h.code, h.text[0..@min(h.text.len, 80)] }),
                .disconnected => |p| std.debug.print("[disconnected] pid {d}\n", .{p}),
                .thread_created => |m| std.debug.print("[thread+] {s}  code={s}\n", .{ m.name, m.hook_code }),
                .thread_destroyed => |m| std.debug.print("[thread-] {s}\n", .{m.name}),
                .text => |t| {
                    const shown = t.text[0..@min(t.text.len, 120)];
                    std.debug.print("[text] ({s}) {s}\n", .{ t.meta.name, shown });
                    // Console-independent check: first code points as hex.
                    if (std.unicode.Utf8View.init(t.text)) |view| {
                        var it = view.iterator();
                        var n: usize = 0;
                        std.debug.print("        cps:", .{});
                        while (it.nextCodepoint()) |cp| : (n += 1) {
                            if (n >= 8) break;
                            std.debug.print(" U+{X:0>4}", .{cp});
                        }
                        std.debug.print("\n", .{});
                    } else |_| std.debug.print("        (invalid UTF-8)\n", .{});
                },
            }
            ev.deinit(alloc);
        }
        events.clearRetainingCapacity();
    }
    _ = client.detach(pid);
    std.debug.print("detached, done\n", .{});
}
