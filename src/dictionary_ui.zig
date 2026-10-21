//! Dictionary controls, background import lifecycle, and cached native lookup results.
const std = @import("std");
const ui = @import("ui");
const native = @import("dictionary.zig");
const files = @import("dictionary_files.zig");
const a = std.heap.smp_allocator;
const Text = ui.component.Text;
const Image = @import("image_decode.zig");
const Content = @import("dictionary_content.zig");
const CachedImage = struct { dictionary_id: i64, path: []u8, monochrome: bool, image: ?Image };

pronunciation: @import("pronunciation.zig") = .{},
online_audio_allowed: bool = false,
path: ?[:0]u8 = null,
db: ?native.Database = null,
message: []const u8 = "Place dictionary ZIPs in dicts beside the executable.",
owned_message: ?[]u8 = null,
job: ?*Job = null,
thread: ?std.Thread = null,
dictionary_count: usize = 0,
term_count: usize = 0,
results: std.ArrayList(native.Result) = .empty,
word_count: usize = 0,
query: ?[]u8 = null,
lookup_failed: bool = false,
documents: std.ArrayList(?Content.Document) = .empty,
images: std.ArrayList(CachedImage) = .empty,
image_bytes: usize = 0,
image_version: u64 = 0,
scan_valid: bool = false,
scan_hash: u64 = 0,
scan_start: usize = 0,
scan_end: ?usize = null,
const Self = @This();

const Job = struct {
    io: std.Io,
    database: [:0]const u8,
    done: std.atomic.Value(bool) = .init(false),
    imported: usize = 0,
    failed: usize = 0,
    last_error: ?anyerror = null,
    failure: ?anyerror = null,
    status_mutex: std.Io.Mutex = .init,
    current_name: ?[]u8 = null,
    fn run(self: *Job) void {
        defer self.done.store(true, .release);
        self.work() catch |err| {
            self.failure = err;
        };
    }
    fn work(self: *Job) !void {
        var paths = try files.folderFiles(self.io, "dicts", ".zip");
        defer files.freePaths(&paths);
        var database = try native.Database.open(self.database);
        defer database.close();
        for (paths.items) |path| self.importOne(&database, path) catch |err| {
            self.failed += 1;
            self.last_error = err;
        };
        if (self.failed == 0) try database.reconcileSources(paths.items);
    }
    fn importOne(self: *Job, database: *native.Database, path: []const u8) !void {
        const name = try a.dupe(u8, std.fs.path.basename(path));
        self.status_mutex.lockUncancelable(self.io);
        if (self.current_name) |old| a.free(old);
        self.current_name = name;
        self.status_mutex.unlock(self.io);
        const archive = try files.mapArchive(path);
        defer archive.deinit();
        const bytes = archive.bytes;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        var fingerprint: [64]u8 = undefined;
        const hex = "0123456789abcdef";
        for (digest, 0..) |byte, i| {
            fingerprint[i * 2] = hex[byte >> 4];
            fingerprint[i * 2 + 1] = hex[byte & 15];
        }
        if (try database.sourceUnchanged(path, &fingerprint)) return;
        const report = try database.importZip(bytes);
        defer a.free(report.title);
        try database.recordSource(path, report.title, &fingerprint);
        self.imported += 1;
    }
    fn destroy(self: *Job) void {
        if (self.current_name) |name| a.free(name);
        a.destroy(self);
    }
};

pub fn init(io: std.Io) Self {
    var self: Self = .{};
    self.path = files.databasePath() catch {
        self.message = "Could not determine the dictionary database path.";
        return self;
    };
    self.db = native.Database.open(self.path.?) catch {
        self.message = "Could not open dictionaries.sqlite3 beside the executable.";
        return self;
    };
    self.refreshCounts();
    self.startScan(io) catch |err| self.setMessage("Could not scan dicts: {s}", .{@errorName(err)});
    return self;
}
pub fn deinit(self: *Self) void {
    self.pronunciation.deinit();
    // A worker owns its connection and archive. Join before freeing its shared database path.
    if (self.thread) |thread| thread.join();
    if (self.job) |job| job.destroy();
    self.clearLookup();
    if (self.db) |*db| db.close();
    if (self.path) |path| a.free(path);
    if (self.owned_message) |message| a.free(message);
}
fn setMessage(self: *Self, comptime fmt: []const u8, args: anytype) void {
    const message = std.fmt.allocPrint(a, fmt, args) catch return;
    if (self.owned_message) |old| a.free(old);
    self.owned_message = message;
    self.message = message;
}
fn refreshCounts(self: *Self) void {
    if (self.db) |*db| {
        const counts = db.counts() catch {
            self.setMessage("Could not read dictionary database.", .{});
            return;
        };
        self.dictionary_count = counts.dictionaries;
        self.term_count = counts.terms;
    }
}
pub fn poll(self: *Self) void {
    const job = self.job orelse return;
    if (!job.done.load(.acquire)) return;
    self.thread.?.join();
    self.thread = null;
    defer {
        job.destroy();
        self.job = null;
    }
    if (job.failure) |err| {
        self.setMessage("dicts scan failed: {s}. Cached entries were kept.", .{@errorName(err)});
    } else if (job.failed > 0) {
        self.setMessage("{d} dictionary ZIP(s) failed: {s}", .{ job.failed, @errorName(job.last_error.?) });
    } else {
        self.setMessage("{d} dictionary ZIP(s) updated from dicts.", .{job.imported});
    }
    self.clearLookup();
    self.scan_valid = false;
    self.refreshCounts();
}
fn startScan(self: *Self, io: std.Io) !void {
    const path = self.path orelse return error.NoDatabasePath;
    const job = try a.create(Job);
    errdefer a.destroy(job);
    job.* = .{ .io = io, .database = path };
    self.thread = try std.Thread.spawn(.{}, Job.run, .{job});
    self.job = job;
    self.setMessage("Scanning dicts...", .{});
}

fn clearLookup(self: *Self) void {
    for (self.documents.items) |doc| {
        if (doc) |value| value.deinit();
    }
    self.documents.deinit(a);
    self.documents = .empty;
    for (self.images.items) |cached| {
        a.free(cached.path);
        if (cached.image) |image| image.deinit();
    }
    self.images.deinit(a);
    self.images = .empty;
    self.image_bytes = 0;
    self.image_version +%= 1;
    for (self.results.items) |result| result.deinit();
    self.results.deinit(a);
    self.results = .empty;
    self.word_count = 0;
    if (self.query) |query| a.free(query);
    self.query = null;
}
pub fn scanWord(self: *Self, text: []const u8, start: usize) !?usize {
    const hash = std.hash.Wyhash.hash(0, text);
    if (self.scan_valid and self.scan_hash == hash and self.scan_start == start) return self.scan_end;
    const end = if (self.db) |*db| try db.scanWord(text, start) else null;
    self.scan_hash = hash;
    self.scan_start = start;
    self.scan_end = end;
    self.scan_valid = true;
    return end;
}
pub fn lookup(self: *Self, text: []const u8) !void {
    if (self.query) |query| {
        if (std.mem.eql(u8, query, text)) return;
    }
    self.clearLookup();
    self.lookup_failed = false;
    self.query = try a.dupe(u8, text);
    if (self.db) |*db| {
        const matches = db.lookupPopup(text) catch {
            self.lookup_failed = true;
            return;
        };
        self.results = matches.results;
        self.word_count = matches.word_count;
        try self.documents.ensureTotalCapacity(a, self.results.items.len);
        for (self.results.items) |result| {
            const doc = if (result.glossary) |json| Content.Document.init(a, json) catch null else null;
            self.documents.appendAssumeCapacity(doc);
        }
    }
}

pub fn renderStatus(self: *Self, frame: *ui.Frame) !void {
    var message = self.message;
    if (self.job) |job| {
        job.status_mutex.lockUncancelable(job.io);
        defer job.status_mutex.unlock(job.io);
        if (job.current_name) |name| message = try std.fmt.allocPrint(frame.arena(), "Scanning / importing: {s}", .{name});
    }
    const status = try std.fmt.allocPrint(frame.arena(), "Dictionaries: {d} / {d} entries\n{s}", .{ self.dictionary_count, self.term_count, message });
    try frame.e(Text{ .key = .src(@src()), .content = status, .style = &.{ .width = .grow(), .wrap = true, .font_size = .sm, .foreground = .dimmed }, .selectable = false });
}

pub fn renderSettings(self: *Self, frame: *ui.Frame) !void {
    const Section = @import("settings_section.zig");
    const imports: Section = .{ .key = .str("dictionary.settings.imports"), .title = "Import status" };
    _ = try imports.open(frame);
    try self.renderStatus(frame);
    try frame.e(Text{ .key = .str("dictionary.settings.import.help"), .content = "Dictionary ZIPs are scanned from the dicts folder beside Touitsu when the app starts.", .style = &.{ .width = .grow(), .wrap = true, .font_size = .sm, .foreground = .dimmed }, .selectable = false });
    try imports.close(frame);
    const priorities: Section = .{ .key = .str("dictionary.settings.priorities"), .title = "Lookup priority" };
    _ = try priorities.open(frame);
    defer priorities.close(frame) catch {};
    try frame.e(Text{ .key = .str("dictionary.settings.help"), .content = "1 is highest priority. Changing a rank shifts the others.", .style = &.{ .width = .grow(), .wrap = true, .font_size = .sm }, .selectable = false });
    const db = if (self.db) |*database| database else return;
    var list = db.dictionaries() catch {
        try frame.e(Text{ .key = .str("dictionary.settings.error"), .content = "Could not load dictionary priorities.", .selectable = false });
        return;
    };
    defer native.freeDictionaries(&list);
    if (list.items.len == 0) {
        try frame.e(Text{ .key = .str("dictionary.settings.empty"), .content = "No dictionaries imported yet.", .selectable = false });
        return;
    }
    const values = try frame.arena().alloc(usize, list.items.len);
    const labels = try frame.arena().alloc([]const u8, list.items.len);
    for (values, labels, 0..) |*value, *label, i| {
        value.* = i;
        label.* = try std.fmt.allocPrint(frame.arena(), "{d}", .{i + 1});
    }
    for (list.items, 0..) |dictionary, rank| {
        const row: ui.component.Rect = .{ .key = ui.Key.str("dictionary.settings.row").indexed(dictionary.id), .style = &.{ .width = .grow(), .direction = .row, .gap = 8, .@"align" = .center } };
        _ = try row.open(frame);
        // Knots borrows text until the frame is drawn, after this list is freed.
        const title = try frame.arena().dupe(u8, dictionary.title);
        try frame.e(Text{ .key = row.key.indexed(1), .content = title, .style = &.{ .width = .grow(), .wrap = true }, .selectable = false });
        const select_key = row.key.indexed(2);
        // SelectInput retains its selection; synchronize ranks shifted by another row.
        if (frame.ui().state.get(.select_input, select_key.hash())) |state| state.selected = @intCast(rank);
        const response = try frame.interact(ui.component.SelectInput(usize){ .key = select_key, .values = values, .labels = labels, .initial_selected = @intCast(rank), .style = &.{ .width = .fixed(72) } });
        try row.close(frame);
        if (response.selected) |selected| {
            db.setPriority(rank, selected.value) catch {
                self.setMessage("Could not save dictionary priority.", .{});
                return;
            };
            // Keep current popup results alive until this frame ends (Anki may borrow them).
            if (self.query) |query| a.free(query);
            self.query = null;
            frame.requestRedraw();
            break;
        }
    }
}

pub fn renderResults(self: *Self, frame: *ui.Frame, text: []const u8, anki: *@import("anki_settings.zig"), sentence: []const u8, entry_spacing: f32) !void {
    try self.lookup(text);
    if (self.results.items.len == 0) {
        const message = if (self.db == null or self.lookup_failed) "Dictionary lookup is unavailable. Check the dicts folder." else if (self.dictionary_count == 0) "Place Yomitan dictionary ZIPs in the dicts folder beside the executable, then restart Touitsu." else "No dictionary match for this selection.";
        try frame.e(Text{ .key = .src(@src()), .content = message, .style = &.{ .width = .grow(), .wrap = true }, .selectable = false });
        return;
    }
    const results_key: ui.Key = .str("dictionary.results");
    const measured = try frame.ui().state.getOrCreate(.measured, frame.ui().allocator, results_key.hash());
    const results: ui.component.Rect = .{ .key = results_key, .style = &.{ .width = .grow(), .height = .fit(), .direction = .column, .gap = 0 } };
    _ = try results.open(frame);
    const width = if (measured.width > 0) measured.width else @min(@as(f32, 400), @as(f32, @floatFromInt(frame.input().logical_extent.width)) - 40);
    var remaining: usize = 32;
    const has_character = self.results.items.len > self.word_count;
    if (self.word_count > 0) {
        // Keep space for the starting-character group even when a word has a long definition.
        var word_budget: usize = if (has_character) 24 else remaining;
        const initial_budget = word_budget;
        try self.renderEntries(frame, 0, self.word_count, width, &word_budget, anki, sentence, entry_spacing);
        remaining -= initial_budget - word_budget;
    }
    if (has_character) {
        try self.renderEntries(frame, self.word_count, self.results.items.len, width, &remaining, anki, sentence, entry_spacing);
    }
    try results.close(frame);
}

fn renderEntries(self: *Self, frame: *ui.Frame, start: usize, end: usize, width: f32, remaining: *usize, anki: *@import("anki_settings.zig"), sentence: []const u8, entry_spacing: f32) !void {
    for (self.results.items[start..end], start..) |result, i| {
        if (remaining.* == 0) break;
        if (i > 0) {
            const separator: ui.component.Rect = .{ .key = ui.Key.str("dictionary.entry.spacing").indexed(i), .style = &.{ .width = .grow(), .height = .fit(), .padding = .xy(0, entry_spacing / 2) } };
            _ = try separator.open(frame);
            try frame.e(ui.component.Rect{ .key = ui.Key.str("dictionary.entry.divider").indexed(i), .style = &.{ .width = .grow(), .height = .fixed(1), .background = .toned, .opacity = 0.5 } });
            try separator.close(frame);
        }
        const heading = try std.fmt.allocPrint(frame.arena(), "{s}  {s}", .{ result.term, result.reading });
        const actions: ui.component.Rect = .{ .key = ui.Key.str("dictionary.actions").indexed(i), .style = &.{ .width = .grow(), .direction = .row, .gap = 8, .@"align" = .center } };
        _ = try actions.open(frame);
        try frame.e(Text{ .key = ui.Key.str("dictionary.heading").indexed(i), .content = heading, .selectable = false, .style = &.{ .width = .grow(), .wrap = true } });
        const audio_key = ui.Key.str("dictionary.audio").indexed(i);
        try self.pronunciation.renderButton(frame, audio_key, result.term, result.reading, self.online_audio_allowed);
        try anki.renderAction(frame, ui.Key.str("dictionary.anki").indexed(i), result, sentence, self.online_audio_allowed);
        try actions.close(frame);
        try limitedText(frame, ui.Key.str("dictionary.name").indexed(i), result.dictionary, true, width, remaining);
        try self.pronunciation.renderStatus(frame, audio_key, result.term, result.reading, self.online_audio_allowed);
        try anki.renderCardStatus(frame, ui.Key.str("dictionary.anki.status").indexed(i), result);

        if (i < self.documents.items.len and self.documents.items[i] != null) {
            try self.renderRich(frame, ui.Key.str("dictionary.definition").indexed(i), result.dictionary_id, self.documents.items[i].?.parts, width, remaining);
        } else {
            try limitedText(frame, ui.Key.str("dictionary.definition").indexed(i), result.definition, false, width, remaining);
        }
    }
}

fn cachedImage(self: *Self, dictionary_id: i64, path: []const u8, monochrome: bool) !?Image {
    for (self.images.items) |cached| {
        if (cached.dictionary_id == dictionary_id and cached.monochrome == monochrome and std.mem.eql(u8, cached.path, path)) return cached.image;
    }
    const copy = try a.dupe(u8, path);
    errdefer a.free(copy);
    var image: ?Image = null;
    if (self.image_bytes < 32 * 1024 * 1024) {
        if (self.db) |*db| {
            if (db.media(dictionary_id, path) catch null) |data| {
                defer a.free(data);
                image = Image.memory(data, std.ascii.endsWithIgnoreCase(path, ".svg")) catch null;
            }
        }
    }
    if (image) |value| {
        if (self.image_bytes + value.pixels.len > 32 * 1024 * 1024) {
            value.deinit();
            image = null;
        } else if (monochrome) {
            // Tint an alpha mask with the theme's text color, including dark themes.
            var i: usize = 0;
            while (i < value.pixels.len) : (i += 4) @memset(value.pixels[i..][0..3], 255);
        }
    }
    errdefer if (image) |value| value.deinit();
    try self.images.append(a, .{ .dictionary_id = dictionary_id, .path = copy, .monochrome = monochrome, .image = image });
    if (image) |value| self.image_bytes += value.pixels.len;
    return image;
}

// Flow text and glyph images together, keeping images in their original glossary position.
fn renderRich(self: *Self, frame: *ui.Frame, key: ui.Key, dictionary_id: i64, parts: []const Content.Part, width: f32, remaining: *usize) !void {
    if (remaining.* == 0) return;
    const u = frame.ui();
    const content = u.contents.items[u.currentSlot()];
    const size = content.font_size;
    const line_height = try u.lineHeight(size, content.font);
    const available = @max(1, width);
    const max_height = @as(f32, @floatFromInt(remaining.*)) * line_height;
    const face = try u.font.getFace(content.font);
    var x: f32 = 0;
    var y: f32 = 0;
    var row_height = line_height;
    var used_height: f32 = 0;
    const Placement = struct {
        x: f32,
        y: f32,
        width: f32 = 0,
        height: f32 = 0,
        content: union(enum) { text: []const u8, image: Image },
        monochrome: bool = false,
        version: u64 = 0,
    };
    var placements: std.ArrayList(Placement) = .empty;
    defer placements.deinit(frame.arena());
    for (parts, 0..) |part, part_index| {
        if (y + line_height > max_height + 0.01) break;
        switch (part) {
            .text => |raw_text| {
                var text = raw_text;
                if (part_index == 0) text = std.mem.trimStart(u8, text, " \t\r\n");
                if (part_index + 1 == parts.len) text = std.mem.trimEnd(u8, text, " \t\r\n");
                var offset: usize = 0;
                while (offset < text.len and y + line_height <= max_height + 0.01) {
                    if (available - x < size and x > 0) {
                        y += row_height;
                        x = 0;
                        row_height = line_height;
                        if (y + line_height > max_height + 0.01) break;
                    }
                    const shaped = try face.shapeWrapped(text[offset..], size * u.content_scale, @max(1, available - x) * u.content_scale);
                    if (shaped.lines.len == 0) break;
                    const line = shaped.lines[0];
                    const end = @min(text.len - offset, line.byte_end);
                    if (end > line.byte_start) {
                        try placements.append(frame.arena(), .{ .x = x, .y = y, .content = .{ .text = text[offset + line.byte_start .. offset + end] } });
                        x += line.width / u.content_scale;
                        used_height = @max(used_height, y + row_height);
                    }
                    if (shaped.lines.len > 1) {
                        const next = shaped.lines[1].byte_start;
                        if (next == 0) break;
                        offset += next;
                        y += row_height;
                        x = 0;
                        row_height = line_height;
                        used_height = @max(used_height, @min(y, max_height));
                    } else break;
                }
            },
            .image => |spec| {
                if (try self.cachedImage(dictionary_id, spec.path, spec.monochrome)) |image| {
                    const aspect = @as(f32, @floatFromInt(image.width)) / @as(f32, @floatFromInt(image.height));
                    const unit: f32 = if (spec.em) size else 1;
                    var w = if (spec.width) |value| value * unit else if (spec.height) |value| value * unit * aspect else if (spec.monochrome) size * aspect else @min(available, @as(f32, @floatFromInt(image.width)));
                    var h = if (spec.height) |value| value * unit else w / aspect;
                    const scale = @min(@as(f32, 1), available / @max(1, w));
                    w *= scale;
                    h *= scale;
                    if (x > 0 and (x + w > available or h > line_height * 1.5)) {
                        y += row_height;
                        x = 0;
                        row_height = line_height;
                    }
                    if (y + line_height > max_height + 0.01) break;
                    const fit = @min(@as(f32, 1), (max_height - y) / @max(1, h));
                    w *= fit;
                    h *= fit;
                    const rounded_height = @ceil(h / line_height) * line_height;
                    row_height = @max(row_height, rounded_height);
                    try placements.append(frame.arena(), .{ .x = x, .y = y, .width = @max(1, w), .height = @max(1, h), .content = .{ .image = image }, .monochrome = spec.monochrome, .version = std.hash.Wyhash.hash(self.image_version, spec.path) ^ @as(u64, @bitCast(dictionary_id)) });
                    x += w;
                    used_height = @max(used_height, y + row_height);
                } else {
                    const label = if (spec.alt.len > 0) spec.alt else "Image unavailable";
                    try placements.append(frame.arena(), .{ .x = 0, .y = y, .content = .{ .text = label } });
                    used_height = @max(used_height, y + line_height);
                    y += row_height;
                    x = 0;
                    row_height = line_height;
                }
            },
        }
    }
    const rect: ui.component.Rect = .{ .key = key, .style = &.{ .width = .grow(), .height = .fixed(@max(0, used_height)), .overflow = .hidden } };
    _ = try rect.open(frame);
    for (placements.items, 0..) |placed, i| {
        switch (placed.content) {
            .text => |text| try frame.e(Text{ .key = key.indexed(i), .content = text, .selectable = false, .style = &.{ .position = .absolute, .offset = .{ placed.x, placed.y }, .font = content.font, .font_size = .{ .px = size }, .wrap = false } }),
            .image => |image| try frame.e(ui.component.Image{ .key = key.indexed(i), .source = .{ .pixels = .{ .data = image.pixels, .width = image.width, .height = image.height, .upload_policy = .versioned, .version = placed.version } }, .style = &.{ .position = .absolute, .offset = .{ placed.x, placed.y }, .width = .fixed(placed.width), .height = .fixed(placed.height), .foreground = if (placed.monochrome) .text else .{ .color = .{ .value = .{ 1, 1, 1, 1 } } } } }),
        }
    }
    try rect.close(frame);
    const lines: usize = @intFromFloat(@ceil(@max(0, used_height) / line_height));
    remaining.* -|= lines;
}

// Count shaped visual lines, including wrapping, across all dictionary information.
fn limitedText(frame: *ui.Frame, key: ui.Key, raw_text: []const u8, small: bool, width: f32, remaining: *usize) !void {
    const text = std.mem.trim(u8, raw_text, " \t\r\n");
    if (remaining.* == 0 or text.len == 0) return;
    const u = frame.ui();
    const content = u.contents.items[u.currentSlot()];
    const size = if (small) (ui.FontSize.Input{ .sm = {} }).resolve(&u.theme) else content.font_size;
    const face = try u.font.getFace(content.font);
    const shaped = try face.shapeWrapped(text, size * u.content_scale, @max(1, width) * u.content_scale);
    const count = @min(remaining.*, shaped.lines.len);
    if (count == 0) return;
    // End at the last displayed line's end to avoid adding a trailing empty line.
    const end = @min(text.len, shaped.lines[count - 1].byte_end);
    try frame.e(Text{ .key = key, .content = text[0..end], .style = &.{ .width = .grow(), .wrap = true, .font_size = .{ .px = size }, .foreground = if (small) .dimmed else .text }, .selectable = false });
    remaining.* -= count;
}
