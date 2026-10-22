//! Online pronunciation, fetched and played off the UI thread.
const std = @import("std");
const ui = @import("ui");
const sources = @import("audio_sources.zig");
const a = std.heap.smp_allocator;
extern fn touitsu_pronunciation_get([*:0]const u16, *?[*]u8, *usize) c_int;
extern fn touitsu_pronunciation_free([*]u8) void;
extern fn touitsu_pronunciation_play([*]const u8, usize, *const fn (?*anyopaque) callconv(.c) bool, ?*anyopaque) c_int;
extern fn touitsu_pronunciation_stop() void;

job: ?*Job = null,
thread: ?std.Thread = null,
cache: ?[]u8 = null,
cache_key: u64 = 0,
status_key: u64 = 0,
status: []const u8 = "",
const Self = @This();

const Job = struct {
    key: u64,
    term: []u8,
    reading: []u8,
    audio: ?[]u8 = null,
    cancelled: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,

    fn isCancelled(pointer: ?*anyopaque) callconv(.c) bool {
        const self: *Job = @ptrCast(@alignCast(pointer.?));
        return self.cancelled.load(.acquire);
    }
    pub fn fetch(self: *Job, url: []const u8) ![]u8 {
        if (self.cancelled.load(.acquire)) return error.Cancelled;
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, url);
        defer a.free(wide);
        var ptr: ?[*]u8 = null;
        var len: usize = 0;
        switch (touitsu_pronunciation_get(wide, &ptr, &len)) {
            0 => {},
            1 => return error.UnsupportedAudioUrl,
            2 => return error.OfflineOrTimedOut,
            3 => return error.ServiceUnavailable,
            4 => return error.ResponseTooLarge,
            else => return error.OutOfMemory,
        }
        defer if (ptr) |data| touitsu_pronunciation_free(data);
        return a.dupe(u8, ptr.?[0..len]);
    }
    fn work(self: *Job) !void {
        if (self.audio == null) {
            self.audio = try sources.download(a, self, self.term, self.reading);
        }
        if (self.cancelled.load(.acquire)) return error.Cancelled;
        if (touitsu_pronunciation_play(self.audio.?.ptr, self.audio.?.len, isCancelled, self) != 0) return error.CannotPlayAudio;
    }
    fn run(self: *Job) void {
        defer self.done.store(true, .release);
        self.work() catch |err| {
            self.failure = err;
        };
    }
    fn destroy(self: *Job) void {
        a.free(self.term);
        a.free(self.reading);
        if (self.audio) |audio| a.free(audio);
        a.destroy(self);
    }
};

fn keyFor(term: []const u8, reading: []const u8) u64 {
    return std.hash.Wyhash.hash(std.hash.Wyhash.hash(0, term), reading);
}

pub fn deinit(self: *Self) void {
    if (self.job) |job| {
        job.cancelled.store(true, .release);
        touitsu_pronunciation_stop();
    }
    if (self.thread) |thread| thread.join();
    if (self.job) |job| job.destroy();
    if (self.cache) |audio| a.free(audio);
}

pub fn tick(self: *Self, frame: *ui.Frame, allowed: bool) void {
    const job = self.job orelse return;
    if (!allowed) job.cancelled.store(true, .release);
    if (!job.done.load(.acquire)) {
        frame.requestRedraw();
        return;
    }
    self.thread.?.join();
    self.thread = null;
    self.job = null;
    defer job.destroy();
    self.status = if (!allowed) "Online pronunciation is disabled." else if (job.failure) |err| switch (err) {
        error.AudioNotFound => "No recording found for this word and reading.",
        error.OfflineOrTimedOut => "Offline or pronunciation request timed out.",
        error.ServiceUnavailable => "Pronunciation audio is currently unavailable.",
        error.Cancelled => "Playback cancelled.",
        else => "Could not load or play pronunciation.",
    } else "";
    if (allowed and job.failure == null and job.audio != null) {
        if (self.cache) |audio| a.free(audio);
        self.cache = job.audio;
        self.cache_key = job.key;
        job.audio = null;
    }
}

pub fn play(self: *Self, term: []const u8, reading: []const u8, allowed: bool) !void {
    if (!allowed or self.job != null) return;
    const term_copy = try a.dupe(u8, term);
    errdefer a.free(term_copy);
    const reading_copy = try a.dupe(u8, reading);
    errdefer a.free(reading_copy);
    const job = try a.create(Job);
    errdefer a.destroy(job);
    job.* = .{ .key = keyFor(term, reading), .term = term_copy, .reading = reading_copy };
    if (self.cache != null and self.cache_key == job.key) job.audio = try a.dupe(u8, self.cache.?);
    errdefer if (job.audio) |audio| a.free(audio);
    self.thread = try std.Thread.spawn(.{}, Job.run, .{job});
    self.job = job;
    self.status_key = job.key;
    self.status = "Loading pronunciation...";
}

pub fn renderButton(self: *Self, frame: *ui.Frame, key: ui.Key, term: []const u8, reading: []const u8, allowed: bool) !void {
    if (!allowed) return;
    const style = @import("../../ui/popup_button.zig").style(frame.ui().theme);
    if ((try frame.interact(@import("../../ui/project_button.zig"){
        .key = key,
        .label = "Play pronunciation",
        .icon = .{ .pixels = .{ .data = @embedFile("../../icons/speaker.rgba"), .width = 48, .height = 48, .upload_policy = .versioned } },
        .disabled = self.job != null,
        .appearance = .explicit,
        .style = &style,
    })).clicked) try self.play(term, reading, allowed);
}

pub fn renderStatus(self: *const Self, frame: *ui.Frame, key: ui.Key, term: []const u8, reading: []const u8, allowed: bool) !void {
    if (!allowed) return;
    if (self.status_key == keyFor(term, reading) and self.status.len > 0)
        try frame.e(ui.component.Text{ .key = ui.Key.str("pronunciation.status").indexed(key.hash()), .content = self.status, .selectable = false, .style = &.{ .width = .grow(), .wrap = true, .font_size = .sm, .foreground = .dimmed } });
}

/// Fetch an owned MP3 without playback. Caller must run off the UI thread and check opt-in.
pub fn download(term: []const u8, reading: []const u8) ![]u8 {
    var job: Job = .{ .key = 0, .term = @constCast(term), .reading = @constCast(reading) };
    return sources.download(a, &job, term, reading);
}
