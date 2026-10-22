//! procs.zig - list running processes (Win32 Toolhelp), like Textractor's "attach" dialog.

const std = @import("std");

pub const Proc = struct {
    pid: u32,
    /// UTF-8 executable name, owned by the list.
    name: []u8,
    /// Both x86 and x64 use architecture-matched backends.
    attachable: bool,
    is_32bit: bool,
    is_system: bool = false,
    started_at: u64 = 0,
};

const HANDLE = ?*anyopaque;

const PROCESSENTRY32W = extern struct {
    dwSize: u32,
    cntUsage: u32,
    th32ProcessID: u32,
    th32DefaultHeapID: usize,
    th32ModuleID: u32,
    cntThreads: u32,
    th32ParentProcessID: u32,
    pcPriClassBase: i32,
    dwFlags: u32,
    szExeFile: [260]u16,
};

extern "kernel32" fn CreateToolhelp32Snapshot(flags: u32, pid: u32) callconv(.winapi) HANDLE;
extern "kernel32" fn Process32FirstW(snap: HANDLE, entry: *PROCESSENTRY32W) callconv(.winapi) i32;
extern "kernel32" fn Process32NextW(snap: HANDLE, entry: *PROCESSENTRY32W) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) i32;
extern "kernel32" fn OpenProcess(access: u32, inherit: i32, pid: u32) callconv(.winapi) HANDLE;
extern "kernel32" fn IsWow64Process(h: HANDLE, out: *i32) callconv(.winapi) i32;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
const FileTime = extern struct { low: u32, high: u32 };
extern "kernel32" fn GetProcessTimes(HANDLE, *FileTime, *FileTime, *FileTime, *FileTime) callconv(.winapi) i32;
extern "kernel32" fn GetWindowsDirectoryW(buffer: [*]u16, size: u32) callconv(.winapi) u32;
extern "kernel32" fn CompareStringOrdinal(a: [*]const u16, a_len: i32, b: [*]const u16, b_len: i32, ignore_case: i32) callconv(.winapi) i32;

const TH32CS_SNAPPROCESS: u32 = 2;
const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;

fn lessThan(_: void, a: Proc, b: Proc) bool {
    if (std.ascii.eqlIgnoreCase(a.name, b.name)) return a.pid < b.pid;
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

/// Snapshot of processes this program can open (protected/elevated ones are skipped).
pub fn list(alloc: std.mem.Allocator) ![]Proc {
    const snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == null or @intFromPtr(snap.?) == std.math.maxInt(usize)) return error.SnapshotFailed;
    defer _ = CloseHandle(snap);

    var out: std.ArrayList(Proc) = .empty;
    errdefer {
        for (out.items) |p| alloc.free(p.name);
        out.deinit(alloc);
    }

    const self_pid = GetCurrentProcessId();
    var windows_path: [1024]u16 = undefined;
    const windows_len = GetWindowsDirectoryW(&windows_path, windows_path.len);
    var entry: PROCESSENTRY32W = undefined;
    entry.dwSize = @sizeOf(PROCESSENTRY32W);
    var more = Process32FirstW(snap, &entry) != 0;
    while (more) : (more = Process32NextW(snap, &entry) != 0) {
        const pid = entry.th32ProcessID;
        if (pid == 0 or pid == 4 or pid == self_pid) continue;

        const h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if (h == null) continue;
        defer _ = CloseHandle(h);
        var wow64: i32 = 0;
        if (IsWow64Process(h, &wow64) == 0) continue;
        const is_32bit_process = wow64 != 0;
        var image_path: [32768]u16 = undefined;
        var image_len: u32 = image_path.len;
        const is_system = QueryFullProcessImageNameW(h, 0, &image_path, &image_len) != 0 and
            windows_len > 0 and windows_len < windows_path.len and image_len > windows_len and
            image_path[windows_len] == '\\' and
            CompareStringOrdinal(&image_path, @intCast(windows_len), &windows_path, @intCast(windows_len), 1) == 2;

        const wide = std.mem.sliceTo(&entry.szExeFile, 0);
        if (wide.len == 0) continue;
        const name = try std.unicode.utf16LeToUtf8Alloc(alloc, wide);
        errdefer alloc.free(name);
        if (std.ascii.eqlIgnoreCase(name, "tx_helper.exe")) {
            alloc.free(name);
            continue;
        }
        try out.append(alloc, .{
            .pid = pid,
            .name = name,
            .attachable = true,
            .is_32bit = is_32bit_process,
            .is_system = is_system,
            .started_at = creationTime(h),
        });
    }
    std.sort.pdq(Proc, out.items, {}, lessThan);
    return out.toOwnedSlice(alloc);
}

fn creationTime(handle: HANDLE) u64 {
    var created: FileTime = undefined;
    var exited: FileTime = undefined;
    var kernel: FileTime = undefined;
    var user: FileTime = undefined;
    if (GetProcessTimes(handle, &created, &exited, &kernel, &user) == 0) return 0;
    return @as(u64, created.high) << 32 | created.low;
}

pub fn free(alloc: std.mem.Allocator, procs: []Proc) void {
    for (procs) |p| alloc.free(p.name);
    alloc.free(procs);
}

extern "kernel32" fn QueryFullProcessImageNameW(h: HANDLE, flags: u32, name: [*]u16, size: *u32) callconv(.winapi) i32;

/// Full path of a running process's exe, as UTF-8 (caller frees). Same form Textractor saves.
pub fn exePath(alloc: std.mem.Allocator, pid: u32) ![]u8 {
    const h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
    if (h == null) return error.OpenFailed;
    defer _ = CloseHandle(h);
    var buf: [1024]u16 = undefined;
    var size: u32 = buf.len;
    if (QueryFullProcessImageNameW(h, 0, &buf, &size) == 0) return error.QueryFailed;
    return std.unicode.utf16LeToUtf8Alloc(alloc, buf[0..size]);
}
