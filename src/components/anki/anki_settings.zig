//! Saved Anki configuration, asynchronous requests, and dictionary popup actions.
const std = @import("std");
const ui = @import("ui");
const api = @import("anki_connect.zig");
const files = @import("../../platform/dictionary_files.zig");
const disk = @import("../reader/reader_store.zig");
const formatting = @import("anki_format.zig");
const Entry = @import("../dictionaries/dictionary.zig").Result;
const a = std.heap.smp_allocator;
const Text = ui.component.Text;
const Self = @This();
const Saved = struct {
    enabled: bool = true,
    endpoint: []const u8 = "http://127.0.0.1:8765",
    api_key: []const u8 = "",
    deck: []const u8 = "Default",
    model: []const u8 = "Basic",
    front: []const u8 = "Front",
    back: []const u8 = "Back",
    formatting: []const formatting.Mapping = &.{},
};
gpa: std.mem.Allocator,
enabled: bool = true,
endpoint: std.ArrayList(u8) = .empty,
api_key: std.ArrayList(u8) = .empty,
deck: std.ArrayList(u8) = .empty,
model: std.ArrayList(u8) = .empty,
front: std.ArrayList(u8) = .empty,
back: std.ArrayList(u8) = .empty,
format_fields: std.ArrayList(Field) = .empty,
connected: bool = false,
status: []const u8 = "Waiting to connect...",
owned_status: ?[]u8 = null,
card_status: ?[]u8 = null,
card_key: ?[]u8 = null,
added: std.StringHashMapUnmanaged(i64) = .empty,
decks: Strings = .{},
models: Strings = .{},
fields: Strings = .{},
revision: usize = 0,
options_revision: usize = 0,
last_check: i64 = -30000,
needs_check: bool = true,
save_failed: bool = false,
job: ?*Job = null,
thread: ?std.Thread = null,

const Strings = struct {
    items: std.ArrayList([]const u8) = .empty,
    fn snapshot(self: *const Strings, allocator: std.mem.Allocator) ![][]const u8 {
        const labels = try allocator.alloc([]const u8, self.items.items.len);
        for (self.items.items, labels) |item, *copy| copy.* = try allocator.dupe(u8, item);
        return labels;
    }
    fn deinit(self: *Strings) void {
        for (self.items.items) |s| a.free(s);
        self.items.deinit(a);
        self.* = .{};
    }
    fn read(self: *Strings, value: std.json.Value) !void {
        if (value != .array) return error.InvalidResponse;
        for (value.array.items) |item| {
            if (item != .string) return error.InvalidResponse;
            const copy = try a.dupe(u8, item.string);
            errdefer a.free(copy);
            try self.items.append(a, copy);
        }
    }
    fn index(self: *const Strings, value: []const u8) ?u32 {
        for (self.items.items, 0..) |item, i| if (std.mem.eql(u8, item, value)) return @intCast(i);
        return null;
    }
};
const Field = struct {
    model: []u8,
    name: []u8,
    template: std.ArrayList(u8),
};
const audio_marker = "TOUITSU_AUDIO_PLACEHOLDER_7eab05";
const Kind = enum { check, ping, add, browse };
const Job = struct {
    kind: Kind,
    revision: usize,
    endpoint: []u8,
    api_key: []u8,
    model: []u8,
    body: ?[]u8 = null,
    key: ?[]u8 = null,
    done: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    message: ?[]u8 = null,
    note_id: ?i64 = null,
    audio_term: ?[]u8 = null,
    audio_reading: ?[]u8 = null,
    audio_missing: bool = false,
    decks: Strings = .{},
    models: Strings = .{},
    fields: Strings = .{},
    fn call(self: *Job, action: []const u8, params: anytype) !std.json.Parsed(std.json.Value) {
        const body = try api.request(action, params, self.api_key);
        defer a.free(body);
        return self.send(body);
    }
    fn send(self: *Job, body: []const u8) !std.json.Parsed(std.json.Value) {
        const bytes = try api.post(self.endpoint, body);
        defer a.free(bytes);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{ .allocate = .alloc_always });
        errdefer parsed.deinit();
        _ = api.result(parsed.value) catch |err| {
            if (parsed.value == .object) {
                if (parsed.value.object.get("error")) |message| {
                    if (message == .string) self.message = try a.dupe(u8, message.string);
                }
            }
            return err;
        };
        return parsed;
    }
    fn run(self: *Job) void {
        defer self.done.store(true, .release);
        self.work() catch |err| {
            self.failure = err;
        };
    }
    fn work(self: *Job) !void {
        switch (self.kind) {
            .check, .ping => {
                const version = try self.call("version", .{});
                defer version.deinit();
                const value = try api.result(version.value);
                if (value != .integer or value.integer < 6) return error.UnsupportedVersion;
                if (self.kind == .ping) return;
                const decks = try self.call("deckNames", .{});
                defer decks.deinit();
                try self.decks.read(try api.result(decks.value));
                const models = try self.call("modelNames", .{});
                defer models.deinit();
                try self.models.read(try api.result(models.value));
                if (self.models.items.items.len == 0) return error.NoNoteTypes;
                if (self.models.index(self.model) == null) {
                    const copy = try a.dupe(u8, self.models.items.items[0]);
                    a.free(self.model);
                    self.model = copy;
                }
                const fields = try self.call("modelFieldNames", .{ .modelName = self.model });
                defer fields.deinit();
                try self.fields.read(try api.result(fields.value));
            },
            .add, .browse => {
                if (self.kind == .add) try self.attachAudio();
                const parsed = try self.send(self.body.?);
                defer parsed.deinit();
                const value = try api.result(parsed.value);
                if (self.kind == .add) {
                    if (value != .integer or value.integer <= 0) return error.NoNoteCreated;
                    self.note_id = value.integer;
                } else if (value != .array) return error.InvalidResponse;
            },
        }
    }
    fn attachAudio(self: *Job) !void {
        if (std.mem.indexOf(u8, self.body.?, audio_marker) == null) return;
        var sound: []const u8 = "";
        var owned_sound: ?[]u8 = null;
        defer if (owned_sound) |value| a.free(value);
        if (self.audio_term) |term| {
            const bytes = @import("../pronunciation/pronunciation.zig").download(term, self.audio_reading.?) catch null;
            if (bytes) |audio| {
                defer a.free(audio);
                const encoded = try a.alloc(u8, std.base64.standard.Encoder.calcSize(audio.len));
                defer a.free(encoded);
                _ = std.base64.standard.Encoder.encode(encoded, audio);
                const filename = try std.fmt.allocPrint(a, "touitsu-{x}.mp3", .{std.hash.Wyhash.hash(0, audio)});
                defer a.free(filename);
                const stored = try self.call("storeMediaFile", .{ .filename = filename, .data = encoded });
                defer stored.deinit();
                const stored_name = try api.result(stored.value);
                if (stored_name != .string or !std.mem.eql(u8, filename, stored_name.string)) return error.InvalidResponse;
                owned_sound = try std.fmt.allocPrint(a, "[sound:{s}]", .{filename});
                sound = owned_sound.?;
            } else self.audio_missing = true;
        }
        const replaced = try std.mem.replaceOwned(u8, a, self.body.?, audio_marker, sound);
        a.free(self.body.?);
        self.body = replaced;
    }
    fn destroy(self: *Job) void {
        a.free(self.endpoint);
        a.free(self.api_key);
        a.free(self.model);
        if (self.audio_term) |value| a.free(value);
        if (self.audio_reading) |value| a.free(value);
        if (self.body) |body| a.free(body);
        if (self.key) |key| a.free(key);
        if (self.message) |message| a.free(message);
        self.decks.deinit();
        self.models.deinit();
        self.fields.deinit();
        a.destroy(self);
    }
};

pub fn init(gpa: std.mem.Allocator) Self {
    var self: Self = .{ .gpa = gpa };
    self.load() catch {};
    if (self.endpoint.items.len == 0) self.endpoint.appendSlice(gpa, "http://127.0.0.1:8765") catch {};
    return self;
}
fn config(self: *const Self, allocator: std.mem.Allocator) !Saved {
    return .{ .enabled = self.enabled, .endpoint = self.endpoint.items, .api_key = self.api_key.items, .deck = self.deck.items, .model = self.model.items, .front = self.front.items, .back = self.back.items, .formatting = try self.mappings(allocator) };
}
fn set(self: *Self, buf: *std.ArrayList(u8), text: []const u8) !void {
    try buf.ensureTotalCapacity(self.gpa, text.len);
    buf.clearRetainingCapacity();
    try buf.appendSlice(self.gpa, text);
}
fn path() ![:0]u16 {
    const utf8 = try files.siblingPath("anki-settings.json");
    defer a.free(utf8);
    return std.unicode.utf8ToUtf16LeAllocZ(a, utf8);
}
fn load(self: *Self) !void {
    const wide = try path();
    defer a.free(wide);
    const bytes = (try disk.readAll(a, wide)) orelse {
        try self.apply(.{});
        return;
    };
    defer a.free(bytes);
    const parsed = try std.json.parseFromSlice(Saved, a, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try self.apply(parsed.value);
}
fn apply(self: *Self, saved: Saved) !void {
    self.enabled = saved.enabled;
    for (saved.formatting) |mapping| try self.addField(mapping);
    inline for (.{ "endpoint", "api_key", "deck", "model", "front", "back" }) |name| try self.set(&@field(self, name), @field(saved, name));
}
fn write(self: *Self) !void {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const bytes = try std.json.Stringify.valueAlloc(a, try self.config(arena.allocator()), .{});
    defer a.free(bytes);
    const wide = try path();
    defer a.free(wide);
    try disk.writeAll(wide, bytes);
}
fn save(self: *Self) void {
    self.write() catch {
        self.save_failed = true;
        return;
    };
    self.save_failed = false;
}
pub fn deinit(self: *Self) void {
    if (self.thread) |thread| thread.join();
    if (self.job) |job| job.destroy();
    inline for (.{ "endpoint", "api_key", "deck", "model", "front", "back" }) |name| @field(self, name).deinit(self.gpa);
    self.decks.deinit();
    self.models.deinit();
    self.fields.deinit();
    for (self.format_fields.items) |*field| {
        self.gpa.free(field.model);
        self.gpa.free(field.name);
        field.template.deinit(self.gpa);
    }
    self.format_fields.deinit(self.gpa);
    if (self.owned_status) |s| a.free(s);
    if (self.card_status) |s| a.free(s);
    if (self.card_key) |s| a.free(s);
    var it = self.added.keyIterator();
    while (it.next()) |key| a.free(key.*);
    self.added.deinit(a);
}
fn setMessage(self: *Self, text: []const u8) void {
    const copy = a.dupe(u8, text) catch return;
    if (self.owned_status) |old| a.free(old);
    self.owned_status = copy;
    self.status = copy;
}
fn invalidate(self: *Self) void {
    self.revision += 1;
    self.connected = false;
    self.needs_check = true;
    self.setMessage(if (self.enabled) "Waiting to connect..." else "Integration disabled.");
    self.save();
}
fn start(self: *Self, kind: Kind, body: ?[]u8, key: ?[]u8) !void {
    return self.startWithAudio(kind, body, key, null, null);
}
fn startWithAudio(self: *Self, kind: Kind, body: ?[]u8, key: ?[]u8, term: ?[]const u8, reading: ?[]const u8) !void {
    // Takes ownership of body/key even when starting the worker fails.
    errdefer {
        if (body) |b| a.free(b);
        if (key) |k| a.free(k);
    }
    if (self.job != null) return error.RequestInProgress;
    const endpoint = try a.dupe(u8, std.mem.trim(u8, self.endpoint.items, " \t\r\n"));
    errdefer a.free(endpoint);
    const api_key = try a.dupe(u8, self.api_key.items);
    errdefer a.free(api_key);
    const model = try a.dupe(u8, self.model.items);
    errdefer a.free(model);
    const audio_term = if (term) |value| try a.dupe(u8, value) else null;
    errdefer if (audio_term) |value| a.free(value);
    const audio_reading = if (reading) |value| try a.dupe(u8, value) else null;
    errdefer if (audio_reading) |value| a.free(value);
    const job = try a.create(Job);
    errdefer a.destroy(job);
    job.* = .{ .kind = kind, .revision = self.revision, .endpoint = endpoint, .api_key = api_key, .model = model, .body = body, .key = key, .audio_term = audio_term, .audio_reading = audio_reading };
    self.thread = try std.Thread.spawn(.{}, Job.run, .{job});
    self.job = job;
}
pub fn tick(self: *Self, frame: *ui.Frame) !void {
    if (self.job) |job| {
        if (job.done.load(.acquire)) {
            self.thread.?.join();
            self.thread = null;
            defer {
                job.destroy();
                self.job = null;
            }
            // Record successful additions even if settings changed while sending.
            if (job.note_id) |id| {
                const slot = try self.added.getOrPut(a, job.key.?);
                if (!slot.found_existing) {
                    // Transfer the snapshot key, so a successful add needs no
                    // additional allocation to remember its note ID.
                    slot.key_ptr.* = job.key.?;
                    job.key = null;
                }
                slot.value_ptr.* = id;
            }
            if (job.revision == self.revision) {
                if (job.kind == .add or job.kind == .browse) {
                    if (self.card_status) |s| a.free(s);
                    self.card_status = if (job.failure) |err| try a.dupe(u8, job.message orelse @errorName(err)) else if (job.audio_missing) try a.dupe(u8, "Added without audio: no recording available or service offline.") else null;
                    //self.card_status = if (job.failure) |err| try std.fmt.allocPrint(a, "{s}{s}", .{ job.message orelse @errorName(err), if (job.kind == .add) " (not retried automatically)" else "" }) else try a.dupe(u8, if (job.kind == .add) "Added to Anki." else "Opened in Anki.");
                } else if (job.failure) |err| {
                    self.connected = false;
                    self.setMessage(job.message orelse @errorName(err));
                } else {
                    self.connected = true;
                    self.setMessage("Connected to AnkiConnect.");
                    if (job.kind == .check) {
                        self.decks.deinit();
                        self.decks = job.decks;
                        job.decks = .{};
                        self.models.deinit();
                        self.models = job.models;
                        job.models = .{};
                        self.fields.deinit();
                        self.fields = job.fields;
                        job.fields = .{};
                        try self.set(&self.model, job.model);
                        if (self.decks.index(self.deck.items) == null and self.decks.items.items.len > 0) try self.set(&self.deck, self.decks.items.items[0]);
                        if (self.fields.index(self.front.items) == null and self.fields.items.items.len > 0) try self.set(&self.front, self.fields.items.items[0]);
                        if (self.fields.index(self.back.items) == null and self.fields.items.items.len > 1) try self.set(&self.back, self.fields.items.items[1]);
                        try self.ensureFormatting();
                        self.options_revision += 1;
                        self.save();
                    }
                }
            }
            frame.requestRedraw();
        }
    }
    const now = frame.ui().input.now_ms;
    if (self.enabled and self.job == null and (self.needs_check or now - self.last_check >= 10000)) {
        const kind: Kind = if (self.needs_check or !self.connected) .check else .ping;
        self.needs_check = false;
        self.last_check = now;
        self.start(kind, null, null) catch |err| self.setMessage(@errorName(err));
        if (kind == .check and self.job != null) self.setMessage("Checking AnkiConnect...");
    }
}
fn label(frame: *ui.Frame, key: ui.Key, text: []const u8) !void {
    // Knots shapes text after the entire frame has been built. A later control
    // can replace status strings during this frame, so retain a frame-local copy.
    try frame.e(Text{ .key = key, .content = try frame.arena().dupe(u8, text), .selectable = false, .style = &.{ .wrap = true, .width = .grow() } });
}
fn choose(self: *Self, frame: *ui.Frame, key: ui.Key, choices: *const Strings, buf: *std.ArrayList(u8)) !bool {
    if (choices.items.items.len == 0) return false;
    const labels = try choices.snapshot(frame.arena());
    const response = try frame.interact(ui.component.SelectInput([]const u8){ .key = key.indexed(self.options_revision), .labels = labels, .values = labels, .initial_selected = choices.index(buf.items), .style = &.{ .width = .grow() } });
    if (response.selected) |selected| {
        try self.set(buf, selected.value);
        return true;
    }
    return false;
}
pub fn render(self: *Self, frame: *ui.Frame) !void {
    const section: @import("../../ui/settings_section.zig") = .{ .key = .str("anki.section"), .title = "Anki Settings" };
    _ = try section.open(frame);
    defer section.close(frame) catch {};
    if ((try frame.interact(ui.component.Checkbox{ .key = .str("anki.enabled"), .label = "Enable Anki integration", .checked = &self.enabled })).changed) self.invalidate();
    try label(frame, .src(@src()), "AnkiConnect server address");
    // Compare hashes because TextInput edits the caller-owned buffer in place.
    const old = std.hash.Wyhash.hash(0, self.endpoint.items);
    try frame.e(ui.component.TextInput{ .key = .str("anki.endpoint"), .buf = &self.endpoint, .bytes_max = 2048, .placeholder = "http://127.0.0.1:8765" });
    const old_key = std.hash.Wyhash.hash(0, self.api_key.items);
    try label(frame, .src(@src()), "API key (if configured in AnkiConnect)");
    try frame.e(ui.component.TextInput{ .key = .str("anki.key"), .buf = &self.api_key, .bytes_max = 512 });
    if (old != std.hash.Wyhash.hash(0, self.endpoint.items) or old_key != std.hash.Wyhash.hash(0, self.api_key.items)) {
        self.invalidate();
        // Wait briefly after typing before connecting to an incomplete address.
        self.needs_check = false;
        self.last_check = frame.ui().input.now_ms;
    }
    try label(frame, .src(@src()), self.status);
    if ((try frame.interact(@import("../../ui/project_button.zig"){ .key = .str("anki.check"), .label = if (self.job != null) "Working..." else "Check connection", .disabled = !self.enabled or self.job != null })).clicked) self.needs_check = true;
    try label(frame, .src(@src()), "Deck");
    if (try self.choose(frame, .str("anki.deck"), &self.decks, &self.deck)) self.save();
    try label(frame, .src(@src()), "Note type");
    if (try self.choose(frame, .str("anki.model"), &self.models, &self.model)) {
        self.fields.deinit();
        self.invalidate();
    }
    try self.renderFormatting(frame);
    if (self.save_failed) try label(frame, .src(@src()), "Could not save anki-settings.json.");
}
fn valid(self: *const Self) bool {
    if (self.decks.index(self.deck.items) == null or self.models.index(self.model.items) == null) return false;
    var populated = false;
    for (self.format_fields.items) |field| {
        if (!std.mem.eql(u8, field.model, self.model.items) or self.fields.index(field.name) == null) continue;
        if (field.template.items.len > 0) populated = true;
        const expanded = formatting.expand(field.template.items, .{ .expression = "", .reading = "", .glossary = "", .sentence = "", .dictionary = "" }) catch return false;
        a.free(expanded);
    }
    return populated;
}
fn addField(self: *Self, mapping: formatting.Mapping) !void {
    const model = try self.gpa.dupe(u8, mapping.model);
    errdefer self.gpa.free(model);
    const name = try self.gpa.dupe(u8, mapping.field);
    errdefer self.gpa.free(name);
    var template: std.ArrayList(u8) = .empty;
    errdefer template.deinit(self.gpa);
    try template.appendSlice(self.gpa, mapping.template);
    try self.format_fields.append(self.gpa, .{ .model = model, .name = name, .template = template });
}
fn mappings(self: *const Self, allocator: std.mem.Allocator) ![]formatting.Mapping {
    const items = try allocator.alloc(formatting.Mapping, self.format_fields.items.len);
    for (items, self.format_fields.items) |*item, field| item.* = .{ .model = field.model, .field = field.name, .template = field.template.items };
    return items;
}
fn activeMappings(self: *const Self, allocator: std.mem.Allocator) ![]formatting.Mapping {
    var items: std.ArrayList(formatting.Mapping) = .empty;
    errdefer items.deinit(allocator);
    for (self.format_fields.items) |field| {
        if (std.mem.eql(u8, field.model, self.model.items) and self.fields.index(field.name) != null)
            try items.append(allocator, .{ .model = field.model, .field = field.name, .template = field.template.items });
    }
    return items.toOwnedSlice(allocator);
}
fn ensureFormatting(self: *Self) !void {
    for (self.fields.items.items) |name| {
        var found = false;
        for (self.format_fields.items) |field| {
            if (std.mem.eql(u8, field.model, self.model.items) and std.mem.eql(u8, field.name, name)) {
                found = true;
                break;
            }
        }
        if (found) continue;
        const template: []const u8 = if (std.ascii.eqlIgnoreCase(name, "Reading")) "{reading}" else if (std.ascii.eqlIgnoreCase(name, "Glossary") or std.ascii.eqlIgnoreCase(name, "Definition")) "{glossary}" else if (std.ascii.eqlIgnoreCase(name, "Sentence")) "{sentence}" else if (std.ascii.eqlIgnoreCase(name, "Audio")) "{audio}" else if (std.ascii.eqlIgnoreCase(name, "Expression") or std.ascii.eqlIgnoreCase(name, "Word") or std.mem.eql(u8, name, self.front.items)) "{expression}" else if (std.mem.eql(u8, name, self.back.items)) "{reading}<br><br>{glossary}<br><br>{sentence}<br>{audio}" else "";
        try self.addField(.{ .model = self.model.items, .field = name, .template = template });
    }
}
fn renderFormatting(self: *Self, frame: *ui.Frame) !void {
    const section: @import("../../ui/settings_section.zig") = .{ .key = .str("anki.formatting"), .title = "Card formatting" };
    _ = try section.open(frame);
    defer section.close(frame) catch {};
    try label(frame, .src(@src()), "Placeholders: {expression}, {reading} (kana), {glossary}, {sentence}, {dictionary}, {audio}. HTML such as <br> is supported.");
    if (self.fields.items.items.len == 0) try label(frame, .src(@src()), "Connect to Anki and choose a note type to edit its fields.");
    for (self.format_fields.items, 0..) |*field, i| {
        if (!std.mem.eql(u8, field.model, self.model.items) or self.fields.index(field.name) == null) continue;
        try label(frame, ui.Key.str("anki.format.name").indexed(i), field.name);
        const old = std.hash.Wyhash.hash(0, field.template.items);
        try frame.e(ui.component.TextInput{ .key = ui.Key.str("anki.format.template").indexed(i), .buf = &field.template, .bytes_max = 8192, .placeholder = "Empty" });
        if (old != std.hash.Wyhash.hash(0, field.template.items)) self.save();
        const expanded = formatting.expand(field.template.items, .{ .expression = "", .reading = "", .glossary = "", .sentence = "", .dictionary = "" }) catch {
            try label(frame, ui.Key.str("anki.format.error").indexed(i), "Unknown or incomplete placeholder. Correct this template before adding cards.");
            continue;
        };
        a.free(expanded);
    }
}

fn entryKey(self: *const Self, word: []const u8, reading: []const u8, dictionary_id: i64, entry_id: i64, definition: []const u8) ![]u8 {
    const templates = try self.mappings(a);
    defer a.free(templates);
    return std.json.Stringify.valueAlloc(a, .{ templates, self.endpoint.items, self.api_key.items, self.deck.items, self.model.items, self.front.items, self.back.items, word, reading, dictionary_id, entry_id, definition }, .{});
}
pub fn renderAction(self: *Self, frame: *ui.Frame, action_key: ui.Key, entry: Entry, sentence: []const u8, online_audio_allowed: bool) !void {
    if (!self.enabled or !self.connected) return;
    const key = try self.entryKey(entry.term, entry.reading, entry.dictionary_id, entry.entry_id, entry.definition);
    defer a.free(key);
    const id = self.added.get(key);
    const style = @import("../../ui/popup_button.zig").style(frame.ui().theme);
    if ((try frame.interact(@import("../../ui/project_button.zig"){ .key = action_key, .label = if (id != null) "Show in Anki" else "Add to Anki", .disabled = self.job != null or (id == null and !self.valid()), .appearance = .explicit, .style = &style })).clicked) {
        if (self.card_status) |s| a.free(s);
        self.card_status = null;
        if (self.card_key) |s| a.free(s);
        self.card_key = try a.dupe(u8, key);
        if (id) |note_id| {
            const query = try std.fmt.allocPrint(a, "nid:{d}", .{note_id});
            defer a.free(query);
            const body = try api.request("guiBrowse", .{ .query = query }, self.api_key.items);
            try self.start(.browse, body, null);
        } else {
            const templates = try self.activeMappings(a);
            defer a.free(templates);
            const body = try formatting.addRequest(self.deck.items, self.model.items, templates, .{ .expression = entry.term, .reading = formatting.readingFor(entry.term, entry.reading), .glossary = entry.definition, .sentence = sentence, .dictionary = entry.dictionary, .audio = if (online_audio_allowed) audio_marker else "" }, self.api_key.items);
            const copy = a.dupe(u8, key) catch |err| {
                a.free(body);
                return err;
            };
            try self.startWithAudio(.add, body, copy, if (online_audio_allowed) entry.term else null, if (online_audio_allowed) entry.reading else null);
        }
    }
}
pub fn renderCardStatus(self: *Self, frame: *ui.Frame, status_key: ui.Key, entry: Entry) !void {
    if (!self.enabled) return;
    const key = try self.entryKey(entry.term, entry.reading, entry.dictionary_id, entry.entry_id, entry.definition);
    defer a.free(key);
    if (self.card_key) |current| {
        if (std.mem.eql(u8, key, current)) {
            if (self.card_status) |text| try label(frame, status_key, text);
        }
    }
}

test "dropdown labels survive releasing their configuration owner during a frame" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var choices: Strings = .{};
    const parsed = try std.json.parseFromSlice(std.json.Value, a, "[\"Basic\",\"日本語\"]", .{});
    defer parsed.deinit();
    try choices.read(parsed.value);
    const labels = try choices.snapshot(arena.allocator());
    choices.deinit();
    try std.testing.expectEqualStrings("Basic", labels[0]);
    try std.testing.expectEqualStrings("日本語", labels[1]);
    try std.testing.expect(std.unicode.utf8ValidateSlice(labels[1]));
}

test "field validation requires templates and a valid selected note type" {
    var self: Self = .{ .gpa = std.testing.allocator };
    defer self.deinit();
    try self.apply(.{});
    const parsed = try std.json.parseFromSlice(std.json.Value, a, "[\"Default\",\"Basic\",\"Front\",\"Back\"]", .{});
    defer parsed.deinit();
    try self.decks.read(parsed.value);
    try self.models.read(parsed.value);
    try self.fields.read(parsed.value);
    try self.ensureFormatting();
    try std.testing.expect(self.valid());
    try self.set(&self.format_fields.items[0].template, "{unknown}");
    try std.testing.expect(!self.valid());
    try self.set(&self.format_fields.items[0].template, "{expression}");
    try self.set(&self.deck, "Missing");
    try std.testing.expect(!self.valid());
}
test "added note identity follows Anki collection and selected word" {
    var self: Self = .{ .gpa = std.testing.allocator };
    defer self.deinit();
    try self.apply(.{});
    const first = try self.entryKey("日本", "にほん", 1, 1, "Japan");
    defer a.free(first);
    const same = try self.entryKey("日本", "にほん", 1, 1, "Japan");
    defer a.free(same);
    try std.testing.expectEqualStrings(first, same);
    try self.set(&self.endpoint, "http://127.0.0.1:9876");
    const other = try self.entryKey("日本", "にほん", 1, 1, "Japan");
    defer a.free(other);
    try std.testing.expect(!std.mem.eql(u8, first, other));
}

test "entries with the same spelling have independent Anki identity" {
    var self: Self = .{ .gpa = std.testing.allocator };
    defer self.deinit();
    try self.apply(.{});
    const first = try self.entryKey("word", "reading", 1, 1, "first definition");
    defer a.free(first);
    const second = try self.entryKey("word", "reading", 1, 2, "second definition");
    defer a.free(second);
    const other_dictionary = try self.entryKey("word", "reading", 2, 1, "first definition");
    defer a.free(other_dictionary);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    try std.testing.expect(!std.mem.eql(u8, first, other_dictionary));
}

test "card formatting survives save and restores per-model templates without overwriting edits" {
    var self: Self = .{ .gpa = std.testing.allocator };
    defer self.deinit();
    try self.apply(.{ .model = "Mining", .formatting = &.{
        .{ .model = "Mining", .field = "Reading", .template = "<b>{reading}</b>" },
        .{ .model = "Other", .field = "Front", .template = "{expression}" },
        .{ .model = "Mining", .field = "Deleted field", .template = "old" },
    } });
    const fields = try std.json.parseFromSlice(std.json.Value, a, "[\"Reading\",\"Glossary\",\"Audio\",\"Sentence\",\"Hint\"]", .{});
    defer fields.deinit();
    try self.fields.read(fields.value);
    try self.ensureFormatting();
    try std.testing.expectEqualStrings("<b>{reading}</b>", self.format_fields.items[0].template.items);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const active = try self.activeMappings(arena.allocator());
    try std.testing.expectEqual(@as(usize, 5), active.len);
    const encoded = try std.json.Stringify.valueAlloc(a, try self.config(arena.allocator()), .{});
    defer a.free(encoded);
    const saved = try std.json.parseFromSlice(Saved, a, encoded, .{});
    defer saved.deinit();
    var restored: Self = .{ .gpa = std.testing.allocator };
    defer restored.deinit();
    try restored.apply(saved.value);
    try std.testing.expectEqualStrings("<b>{reading}</b>", restored.format_fields.items[0].template.items);
    try std.testing.expectEqualStrings("Other", restored.format_fields.items[1].model);
}
test "offline card audio markers are removed without leaving a broken sound link" {
    var job: Job = .{ .kind = .add, .revision = 0, .endpoint = try a.dupe(u8, ""), .api_key = try a.dupe(u8, ""), .model = try a.dupe(u8, "") };
    defer {
        a.free(job.endpoint);
        a.free(job.api_key);
        a.free(job.model);
        if (job.body) |body| a.free(body);
    }
    job.body = try std.fmt.allocPrint(a, "{{\"Audio\":\"{s}\"}}", .{audio_marker});
    try job.attachAudio();
    try std.testing.expectEqualStrings("{\"Audio\":\"\"}", job.body.?);
}
