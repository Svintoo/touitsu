//! Native Yomitan v3 term dictionaries backed by SQLite. No browser or JS runtime.
const std = @import("std");
const zip = @import("dictionary_zip.zig");
const c = @import("../../platform/sqlite_api.zig");
const Japanese = @import("../../text/japanese.zig");
const a = std.heap.smp_allocator;

// Large dictionaries are processed bank by bank rather than held decompressed.
pub const max_dictionary_bytes: u64 = 16 * 1024 * 1024 * 1024;
pub const max_media_bytes = 64 * 1024 * 1024;
fn isImagePath(path: []const u8) bool {
    inline for (.{ ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp", ".svg" }) |extension| {
        if (std.ascii.endsWithIgnoreCase(path, extension)) return true;
    }
    return false;
}
fn hasImages(value: std.json.Value) bool {
    switch (value) {
        .array => for (value.array.items) |child| {
            if (hasImages(child)) return true;
        },
        .object => {
            if (value.object.get("tag")) |tag| {
                if (tag == .string and std.mem.eql(u8, tag.string, "img")) return true;
            }
            if (value.object.get("type")) |kind| {
                if (kind == .string and std.mem.eql(u8, kind.string, "image")) return true;
            }
            if (value.object.get("content")) |content| return hasImages(content);
        },
        else => {},
    }
    return false;
}

pub const Result = struct {
    term: []u8,
    reading: []u8,
    definition: []u8,
    dictionary: []u8,
    dictionary_id: i64 = 0,
    glossary: ?[]u8 = null,
    entry_id: i64 = 0,
    priority: i64 = 2147483647,
    depth: u8 = 0,
    match_kind: u8 = 0,
    deinflection: ?[]u8 = null,
    pub fn deinit(self: Result) void {
        a.free(self.term);
        a.free(self.reading);
        a.free(self.definition);
        a.free(self.dictionary);
        if (self.glossary) |glossary| a.free(glossary);
        if (self.deinflection) |reason| a.free(reason);
    }
};
pub const Dictionary = struct {
    id: usize,
    title: []u8,
    enabled: bool = true,
};
pub const Report = struct { title: []u8, entries: usize };
pub const PopupMatches = struct {
    results: std.ArrayList(Result),
    word_count: usize,
};
pub const Database = struct {
    db: *c.sqlite3,

    pub fn open(path: [:0]const u8) !Database {
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(path, &db, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX, null);
        if (rc != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return error.CannotOpenDictionaryDatabase;
        }
        var self: Database = .{ .db = db.? };
        errdefer self.close();
        _ = c.sqlite3_busy_timeout(self.db, 5000);
        try self.exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; CREATE TABLE IF NOT EXISTS dictionaries(id INTEGER PRIMARY KEY, title TEXT NOT NULL UNIQUE, revision TEXT NOT NULL); CREATE TABLE IF NOT EXISTS terms(dictionary_id INTEGER NOT NULL REFERENCES dictionaries(id) ON DELETE CASCADE, expression TEXT NOT NULL, reading TEXT NOT NULL, definition TEXT NOT NULL, rules TEXT NOT NULL); CREATE TABLE IF NOT EXISTS dictionary_sources(path TEXT PRIMARY KEY, title TEXT NOT NULL, fingerprint TEXT NOT NULL); CREATE INDEX IF NOT EXISTS terms_expression ON terms(expression); CREATE INDEX IF NOT EXISTS terms_reading ON terms(reading);");
        try self.exec("CREATE TABLE IF NOT EXISTS dictionary_priorities(title TEXT PRIMARY KEY, priority INTEGER NOT NULL)");
        try self.exec("CREATE TABLE IF NOT EXISTS dictionary_disabled(title TEXT PRIMARY KEY)");
        try self.exec("CREATE TABLE IF NOT EXISTS dictionary_media(dictionary_id INTEGER NOT NULL REFERENCES dictionaries(id) ON DELETE CASCADE,path TEXT NOT NULL,data BLOB NOT NULL,PRIMARY KEY(dictionary_id,path)); CREATE TABLE IF NOT EXISTS term_content(term_id INTEGER PRIMARY KEY,dictionary_id INTEGER NOT NULL REFERENCES dictionaries(id) ON DELETE CASCADE,glossary TEXT NOT NULL); CREATE TABLE IF NOT EXISTS dictionary_import_state(title TEXT PRIMARY KEY,version INTEGER NOT NULL)");
        try self.exec("CREATE TABLE IF NOT EXISTS dictionary_manual_imports(title TEXT PRIMARY KEY)");
        return self;
    }
    pub fn close(self: *Database) void {
        _ = c.sqlite3_close(self.db);
    }
    fn exec(self: *Database, sql: [:0]const u8) !void {
        if (c.sqlite3_exec(self.db, sql, null, null, null) != c.SQLITE_OK) return error.DictionaryDatabaseError;
    }
    fn prepare(self: *Database, sql: [:0]const u8) !*c.sqlite3_stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DictionaryDatabaseError;
        return stmt.?;
    }
    fn bind(stmt: *c.sqlite3_stmt, index: c_int, text: []const u8) !void {
        if (text.len > std.math.maxInt(c_int)) return error.DictionaryTextTooLong;
        // SQLITE_TRANSIENT: SQLite owns a copy, including after a parsed bank is freed.
        const transient: *const fn (?*anyopaque) callconv(.c) void = @ptrFromInt(std.math.maxInt(usize));
        if (c.sqlite3_bind_text(stmt, index, text.ptr, @intCast(text.len), transient) != c.SQLITE_OK) return error.DictionaryDatabaseError;
    }
    fn done(stmt: *c.sqlite3_stmt) !void {
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DictionaryDatabaseError;
    }
    fn column(stmt: *c.sqlite3_stmt, index: c_int) []const u8 {
        const ptr = c.sqlite3_column_text(stmt, index);
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, index));
        return if (ptr == null) "" else ptr.?[0..len];
    }
    pub fn counts(self: *Database) !struct { dictionaries: usize, terms: usize } {
        const stmt = try self.prepare("SELECT (SELECT count(*) FROM dictionaries), (SELECT count(*) FROM terms)");
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DictionaryDatabaseError;
        return .{ .dictionaries = @intCast(c.sqlite3_column_int64(stmt, 0)), .terms = @intCast(c.sqlite3_column_int64(stmt, 1)) };
    }
    pub fn sourceUnchanged(self: *Database, path: []const u8, fingerprint: []const u8) !bool {
        const stmt = try self.prepare("SELECT 1 FROM dictionary_sources JOIN dictionaries USING(title) JOIN dictionary_import_state USING(title) WHERE path=?1 AND fingerprint=?2 AND version=2");
        defer _ = c.sqlite3_finalize(stmt);
        try bind(stmt, 1, path);
        try bind(stmt, 2, fingerprint);
        const rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_ROW and rc != c.SQLITE_DONE) return error.DictionaryDatabaseError;
        return rc == c.SQLITE_ROW;
    }
    pub fn recordSource(self: *Database, path: []const u8, title: []const u8, fingerprint: []const u8) !void {
        const stmt = try self.prepare("INSERT OR REPLACE INTO dictionary_sources(path,title,fingerprint) VALUES(?1,?2,?3)");
        defer _ = c.sqlite3_finalize(stmt);
        try bind(stmt, 1, path);
        try bind(stmt, 2, title);
        try bind(stmt, 3, fingerprint);
        try done(stmt);
    }
    /// The folder is authoritative. Reconcile only after every archive has been checked.
    pub fn reconcileSources(self: *Database, paths: []const []u8) !void {
        try self.exec("BEGIN IMMEDIATE; CREATE TEMP TABLE IF NOT EXISTS present_sources(path TEXT PRIMARY KEY); DELETE FROM present_sources");
        errdefer self.exec("ROLLBACK") catch {};
        const stmt = try self.prepare("INSERT INTO present_sources(path) VALUES(?1)");
        defer _ = c.sqlite3_finalize(stmt);
        for (paths) |path| {
            _ = c.sqlite3_reset(stmt);
            try bind(stmt, 1, path);
            try done(stmt);
        }
        try self.exec("DELETE FROM dictionary_sources WHERE path NOT IN (SELECT path FROM present_sources); DELETE FROM dictionaries WHERE title NOT IN (SELECT title FROM dictionary_sources) AND title NOT IN (SELECT title FROM dictionary_manual_imports); COMMIT");
    }

    /// The entire replacement is transactional: a bad archive leaves existing dictionaries intact.
    pub fn importZip(self: *Database, bytes: []const u8) !Report {
        return self.importArchive(bytes, false);
    }
    pub fn importDroppedZip(self: *Database, bytes: []const u8) !Report {
        return self.importArchive(bytes, true);
    }
    fn importArchive(self: *Database, bytes: []const u8, keep: bool) !Report {
        var archive = try zip.Archive.init(bytes);
        var index: ?zip.Entry = null;
        while (try archive.next()) |entry| {
            if (std.mem.eql(u8, entry.name, "index.json")) {
                if (index != null) return error.DuplicateDictionaryIndex;
                index = entry;
            }
        }
        const metadata_bytes = try (index orelse return error.MissingDictionaryIndex).read(a);
        defer a.free(metadata_bytes);
        const metadata = try std.json.parseFromSlice(std.json.Value, a, metadata_bytes, .{ .allocate = .alloc_always });
        defer metadata.deinit();
        if (metadata.value != .object) return error.InvalidDictionaryIndex;
        const format = metadata.value.object.get("format") orelse return error.UnsupportedDictionaryFormat;
        if (format != .integer or format.integer != 3) return error.UnsupportedDictionaryFormat;
        const title = try string(metadata.value.object.get("title") orelse return error.InvalidDictionaryIndex);
        const revision = try string(metadata.value.object.get("revision") orelse return error.InvalidDictionaryIndex);
        if (title.len == 0) return error.InvalidDictionaryIndex;
        // Own the report before committing, so allocation failure cannot report a committed import as failed.
        const report_title = try a.dupe(u8, title);
        errdefer a.free(report_title);
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        const remove = try self.prepare("DELETE FROM dictionaries WHERE title=?1");
        defer _ = c.sqlite3_finalize(remove);
        try bind(remove, 1, title);
        try done(remove);
        const dictionary = try self.prepare("INSERT INTO dictionaries(title,revision) VALUES(?1,?2)");
        defer _ = c.sqlite3_finalize(dictionary);
        try bind(dictionary, 1, title);
        try bind(dictionary, 2, revision);
        try done(dictionary);
        const id = c.sqlite3_last_insert_rowid(self.db);
        const insert = try self.prepare("INSERT INTO terms(dictionary_id,expression,reading,definition,rules) VALUES(?1,?2,?3,?4,?5)");
        defer _ = c.sqlite3_finalize(insert);
        var count: usize = 0;
        var total_bytes: u64 = 0;
        var seen: std.StringHashMap(void) = .init(a);
        defer {
            var keys = seen.keyIterator();
            while (keys.next()) |k| a.free(k.*);
            seen.deinit();
        }
        archive = try zip.Archive.init(bytes);
        while (try archive.next()) |entry| {
            if (!isTermBank(entry.name)) continue;
            if (seen.contains(entry.name)) return error.DuplicateTermBank;
            const name = try a.dupe(u8, entry.name);
            seen.put(name, {}) catch |err| {
                a.free(name);
                return err;
            };
            total_bytes += entry.size;
            if (total_bytes > max_dictionary_bytes) return error.DictionaryTooLarge;
            const bank_bytes = try entry.read(a);
            defer a.free(bank_bytes);
            const bank = try std.json.parseFromSlice(std.json.Value, a, bank_bytes, .{ .allocate = .alloc_if_needed });
            defer bank.deinit();
            if (bank.value != .array) return error.InvalidTermBank;
            for (bank.value.array.items) |value| {
                if (value != .array or value.array.items.len != 8) return error.InvalidTermEntry;
                const fields = value.array.items;
                const term = try string(fields[0]);
                const reading = try string(fields[1]);
                const rules = try string(fields[3]);
                if (fields[5] != .array) return error.InvalidTermEntry;
                // Preserve image-only headwords too; they may be used as references.
                var definition: std.ArrayList(u8) = .empty;
                defer definition.deinit(a);
                for (fields[5].array.items, 0..) |gloss, i| {
                    if (i > 0) try definition.appendSlice(a, "\n");
                    try flatten(&definition, gloss, 0);
                }
                _ = c.sqlite3_reset(insert);
                try bind(insert, 2, term);
                try bind(insert, 3, reading);
                try bind(insert, 4, definition.items);
                try bind(insert, 5, rules);
                if (c.sqlite3_bind_int64(insert, 1, id) != c.SQLITE_OK) return error.DictionaryDatabaseError;
                try done(insert);
                if (hasImages(fields[5])) {
                    const content = try self.prepare("INSERT INTO term_content(term_id,dictionary_id,glossary) VALUES(?1,?2,?3)");
                    defer _ = c.sqlite3_finalize(content);
                    if (c.sqlite3_bind_int64(content, 1, c.sqlite3_last_insert_rowid(self.db)) != c.SQLITE_OK or c.sqlite3_bind_int64(content, 2, id) != c.SQLITE_OK) return error.DictionaryDatabaseError;
                    const json = try std.json.Stringify.valueAlloc(a, fields[5], .{});
                    defer a.free(json);
                    try bind(content, 3, json);
                    try done(content);
                }
                count += 1;
            }
        }
        if (count == 0) return error.NoTermEntries;
        // Store assets as archive-local blobs; no archive paths are extracted to disk.
        archive = try zip.Archive.init(bytes);
        while (try archive.next()) |entry| {
            if (!isImagePath(entry.name)) continue;
            total_bytes += entry.size;
            if (total_bytes > max_dictionary_bytes) return error.DictionaryTooLarge;
            if (entry.size > max_media_bytes) return error.DictionaryImageTooLarge;
            const data = try entry.read(a);
            defer a.free(data);
            const asset_stmt = try self.prepare("INSERT OR REPLACE INTO dictionary_media(dictionary_id,path,data) VALUES(?1,?2,?3)");
            defer _ = c.sqlite3_finalize(asset_stmt);
            if (c.sqlite3_bind_int64(asset_stmt, 1, id) != c.SQLITE_OK) return error.DictionaryDatabaseError;
            try bind(asset_stmt, 2, entry.name);
            if (c.sqlite3_bind_blob(asset_stmt, 3, data.ptr, @intCast(data.len), null) != c.SQLITE_OK) return error.DictionaryDatabaseError;
            try done(asset_stmt);
        }
        const version = try self.prepare("INSERT OR REPLACE INTO dictionary_import_state(title,version) VALUES(?1,2)");
        defer _ = c.sqlite3_finalize(version);
        try bind(version, 1, title);
        try done(version);
        if (keep) {
            const retained = try self.prepare("INSERT OR IGNORE INTO dictionary_manual_imports(title) VALUES(?1)");
            defer _ = c.sqlite3_finalize(retained);
            try bind(retained, 1, title);
            try done(retained);
        }
        try self.exec("COMMIT");
        return .{ .title = report_title, .entries = count };
    }
    pub fn media(self: *Database, dictionary_id: i64, path: []const u8) !?[]u8 {
        const stmt = try self.prepare("SELECT data FROM dictionary_media WHERE dictionary_id=?1 AND path=?2");
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_int64(stmt, 1, dictionary_id) != c.SQLITE_OK) return error.DictionaryDatabaseError;
        try bind(stmt, 2, path);
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return error.DictionaryDatabaseError;
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
        if (len > max_media_bytes) return error.DictionaryImageTooLarge;
        const data = c.sqlite3_column_blob(stmt, 0) orelse return null;
        return try a.dupe(u8, data[0..len]);
    }
    pub fn dictionaries(self: *Database) !std.ArrayList(Dictionary) {
        var list: std.ArrayList(Dictionary) = .empty;
        errdefer freeDictionaries(&list);
        const stmt = try self.prepare("SELECT dictionaries.id,dictionaries.title,NOT EXISTS(SELECT 1 FROM dictionary_disabled WHERE dictionary_disabled.title=dictionaries.title) FROM dictionaries LEFT JOIN dictionary_priorities USING(title) ORDER BY COALESCE(priority,2147483647),dictionaries.id");
        defer _ = c.sqlite3_finalize(stmt);
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.DictionaryDatabaseError;
            const title = try a.dupe(u8, column(stmt, 1));
            errdefer a.free(title);
            try list.append(a, .{ .id = @intCast(c.sqlite3_column_int64(stmt, 0)), .title = title, .enabled = c.sqlite3_column_int64(stmt, 2) != 0 });
        }
        return list;
    }
    // Save by title so replacing a ZIP also preserves its enabled state.
    pub fn setEnabled(self: *Database, title: []const u8, enabled: bool) !void {
        const stmt = try self.prepare(if (enabled)
            "DELETE FROM dictionary_disabled WHERE title=?1"
        else
            "INSERT OR IGNORE INTO dictionary_disabled(title) VALUES(?1)");
        defer _ = c.sqlite3_finalize(stmt);
        try bind(stmt, 1, title);
        try done(stmt);
    }

    // Move a dictionary to a unique rank and shift intervening dictionaries.
    // Save by title so replacing a ZIP preserves the user's ordering.
    pub fn setPriority(self: *Database, from: usize, to: usize) !void {
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        var list = try self.dictionaries();
        defer freeDictionaries(&list);
        if (from >= list.items.len or to >= list.items.len) return error.InvalidDictionaryPriority;
        const moved = list.orderedRemove(from);
        try list.insert(a, to, moved);
        for (list.items, 0..) |dictionary, index| {
            const stmt = try self.prepare("INSERT OR REPLACE INTO dictionary_priorities(title,priority) VALUES(?1,?2)");
            defer _ = c.sqlite3_finalize(stmt);
            try bind(stmt, 1, dictionary.title);
            if (c.sqlite3_bind_int64(stmt, 2, @intCast(index + 1)) != c.SQLITE_OK) return error.DictionaryDatabaseError;
            try done(stmt);
        }
        try self.exec("COMMIT");
    }
    /// Longest forward dictionary match, without fetching definitions or image data.
    pub fn scanWord(self: *Database, text: []const u8, start: usize) !?usize {
        var ends: [32]usize = undefined;
        const count = Japanese.prefixEnds(text, start, &ends);
        if (count == 0) return null;
        const stmt = try self.prepare("SELECT rules FROM terms JOIN dictionaries ON dictionaries.id=terms.dictionary_id WHERE (expression=?1 OR reading=?1) AND NOT EXISTS(SELECT 1 FROM dictionary_disabled WHERE dictionary_disabled.title=dictionaries.title)");
        defer _ = c.sqlite3_finalize(stmt);
        var index = count;
        while (index > 0) {
            index -= 1;
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            const forms = try Japanese.candidates(arena.allocator(), text[start..ends[index]]);
            for (forms) |form| {
                _ = c.sqlite3_reset(stmt);
                try bind(stmt, 1, form.text);
                while (true) {
                    const rc = c.sqlite3_step(stmt);
                    if (rc == c.SQLITE_DONE) break;
                    if (rc != c.SQLITE_ROW) return error.DictionaryDatabaseError;
                    if (Japanese.compatible(column(stmt, 0), form.classes)) return ends[index];
                }
            }
        }
        return null;
    }
    pub fn lookup(self: *Database, text: []const u8) !std.ArrayList(Result) {
        var results: std.ArrayList(Result) = .empty;
        errdefer {
            for (results.items) |result| result.deinit();
            results.deinit(a);
        }
        const query = std.mem.trim(u8, text, " \t\r\n");
        if (query.len == 0) return results;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const forms = try Japanese.candidates(arena.allocator(), query);
        for (forms) |form| {
            var matches = try self.lookupForm(form);
            defer matches.deinit(a);
            // Reserve before transferring ownership so allocation failure cannot leak matches.
            results.ensureUnusedCapacity(a, matches.items.len) catch |err| {
                for (matches.items) |result| result.deinit();
                return err;
            };
            for (matches.items) |result| {
                var duplicate = false;
                for (results.items) |*old| {
                    if (old.entry_id != result.entry_id) continue;
                    duplicate = true;
                    if (result.depth < old.depth) {
                        old.deinit();
                        old.* = result;
                    } else result.deinit();
                    break;
                }
                if (!duplicate) results.appendAssumeCapacity(result);
            }
            std.mem.sort(Result, results.items, {}, resultLessThan);
            while (results.items.len > 30) results.pop().?.deinit();
        }
        return results;
    }
    /// Keep full-word/deinflected matches together, then append exact matches
    /// for the starting kanji. Each group retains the configured dictionary order.
    pub fn lookupPopup(self: *Database, text: []const u8) !PopupMatches {
        var results = try self.lookup(text);
        errdefer {
            for (results.items) |result| result.deinit();
            results.deinit(a);
        }
        const word_count = results.items.len;
        const query = std.mem.trim(u8, text, " \t\r\n");
        if (Japanese.firstKanji(query)) |character| {
            if (character.len < query.len) {
                var matches = try self.lookupForm(.{ .text = character });
                defer matches.deinit(a);
                results.ensureUnusedCapacity(a, matches.items.len) catch |err| {
                    for (matches.items) |result| result.deinit();
                    return err;
                };
                for (matches.items) |result| {
                    var duplicate = false;
                    for (results.items) |old| {
                        if (old.entry_id == result.entry_id) {
                            duplicate = true;
                            break;
                        }
                    }
                    if (duplicate) result.deinit() else results.appendAssumeCapacity(result);
                }
            }
        }
        return .{ .results = results, .word_count = word_count };
    }
    fn lookupForm(self: *Database, candidate: Japanese.Candidate) !std.ArrayList(Result) {
        const text = candidate.text;
        var results: std.ArrayList(Result) = .empty;
        const query = std.mem.trim(u8, text, " \t\r\n");
        if (query.len == 0) return results;
        errdefer {
            for (results.items) |r| r.deinit();
            results.deinit(a);
        }
        const stmt = try self.prepare("SELECT expression,reading,definition,title,dictionaries.id,term_content.glossary,terms.rowid,COALESCE(priority,2147483647),terms.rules FROM terms JOIN dictionaries ON dictionaries.id=terms.dictionary_id LEFT JOIN dictionary_priorities USING(title) LEFT JOIN term_content ON term_content.term_id=terms.rowid WHERE (expression=?1 OR reading=?1) AND NOT EXISTS(SELECT 1 FROM dictionary_disabled WHERE dictionary_disabled.title=dictionaries.title) ORDER BY COALESCE(priority,2147483647),dictionaries.id,CASE WHEN expression=?1 THEN 0 ELSE 1 END,terms.rowid");
        defer _ = c.sqlite3_finalize(stmt);
        try bind(stmt, 1, query);
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.DictionaryDatabaseError;
            if (!Japanese.compatible(column(stmt, 8), candidate.classes)) continue;
            const term = try a.dupe(u8, column(stmt, 0));
            errdefer a.free(term);
            const reading = try a.dupe(u8, column(stmt, 1));
            errdefer a.free(reading);
            const definition = try a.dupe(u8, column(stmt, 2));
            errdefer a.free(definition);
            const dictionary = try a.dupe(u8, column(stmt, 3));
            errdefer a.free(dictionary);
            const raw = column(stmt, 5);
            const glossary = if (raw.len > 0) try a.dupe(u8, raw) else null;
            errdefer if (glossary) |value| a.free(value);
            const reason = if (candidate.depth > 0) try a.dupe(u8, candidate.reason) else null;
            errdefer if (reason) |value| a.free(value);
            try results.append(a, .{ .term = term, .reading = reading, .definition = definition, .dictionary = dictionary, .dictionary_id = c.sqlite3_column_int64(stmt, 4), .glossary = glossary, .entry_id = c.sqlite3_column_int64(stmt, 6), .priority = c.sqlite3_column_int64(stmt, 7), .depth = candidate.depth, .match_kind = if (std.mem.eql(u8, term, query)) 0 else 1, .deinflection = reason });
            if (results.items.len == 30) break;
        }
        return results;
    }
};

fn resultLessThan(_: void, lhs: Result, rhs: Result) bool {
    if (lhs.priority != rhs.priority) return lhs.priority < rhs.priority;
    if (lhs.dictionary_id != rhs.dictionary_id) return lhs.dictionary_id < rhs.dictionary_id;
    if (lhs.depth != rhs.depth) return lhs.depth < rhs.depth;
    if (lhs.match_kind != rhs.match_kind) return lhs.match_kind < rhs.match_kind;
    return lhs.entry_id < rhs.entry_id;
}

pub fn freeDictionaries(list: *std.ArrayList(Dictionary)) void {
    for (list.items) |dictionary| a.free(dictionary.title);
    list.deinit(a);
}

fn string(value: std.json.Value) ![]const u8 {
    if (value != .string) return error.InvalidDictionaryText;
    if (!std.unicode.utf8ValidateSlice(value.string)) return error.InvalidDictionaryText;
    return value.string;
}
fn isTermBank(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "term_bank_") or !std.mem.endsWith(u8, name, ".json")) return false;
    const digits = name[10 .. name.len - 5];
    if (digits.len == 0) return false;
    for (digits) |ch| if (ch < '0' or ch > '9') return false;
    return true;
}
/// Plain-text definitions for Anki and text-only entries; image-bearing glossaries
/// are also retained separately for native popup rendering.
fn flatten(out: *std.ArrayList(u8), value: std.json.Value, depth: usize) !void {
    if (depth > 64) return error.DictionaryContentTooDeep;
    switch (value) {
        .string => try out.appendSlice(a, try string(value)),
        .array => for (value.array.items) |child| {
            try flatten(out, child, depth + 1);
        },
        .object => {
            if (value.object.get("tag")) |tag| {
                if (tag == .string and std.mem.eql(u8, tag.string, "br")) {
                    try out.append(a, '\n');
                    return;
                }
            }
            if (value.object.get("content")) |content| {
                try flatten(out, content, depth + 1);
            } else if (value.object.get("text")) |text| {
                try flatten(out, text, depth + 1);
            } else if (value.object.get("description")) |description| {
                try flatten(out, description, depth + 1);
            } else if (value.object.get("alt")) |alt| {
                try flatten(out, alt, depth + 1);
            }
            if (value.object.get("tag")) |tag| {
                if (tag == .string and (std.mem.eql(u8, tag.string, "div") or std.mem.eql(u8, tag.string, "li") or std.mem.eql(u8, tag.string, "tr"))) try out.append(a, '\n');
            }
        },
        else => return error.InvalidGlossary,
    }
}

test {
    _ = @import("../../tests/components/dictionaries/dictionary.zig").Tests(.{ .exec = Database.exec });
}
