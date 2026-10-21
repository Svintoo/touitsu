//! Native Yomitan v3 term dictionaries backed by SQLite. No browser or JS runtime.
const std = @import("std");
const zip = @import("dictionary_zip.zig");
const c = @import("sqlite_api.zig");
const Japanese = @import("japanese.zig");
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
        try self.exec("CREATE TABLE IF NOT EXISTS dictionary_media(dictionary_id INTEGER NOT NULL REFERENCES dictionaries(id) ON DELETE CASCADE,path TEXT NOT NULL,data BLOB NOT NULL,PRIMARY KEY(dictionary_id,path)); CREATE TABLE IF NOT EXISTS term_content(term_id INTEGER PRIMARY KEY,dictionary_id INTEGER NOT NULL REFERENCES dictionaries(id) ON DELETE CASCADE,glossary TEXT NOT NULL); CREATE TABLE IF NOT EXISTS dictionary_import_state(title TEXT PRIMARY KEY,version INTEGER NOT NULL)");
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
        try self.exec("DELETE FROM dictionary_sources WHERE path NOT IN (SELECT path FROM present_sources); DELETE FROM dictionaries WHERE title NOT IN (SELECT title FROM dictionary_sources); COMMIT");
    }

    /// The entire replacement is transactional: a bad archive leaves existing dictionaries intact.
    pub fn importZip(self: *Database, bytes: []const u8) !Report {
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
        const stmt = try self.prepare("SELECT dictionaries.id,dictionaries.title FROM dictionaries LEFT JOIN dictionary_priorities USING(title) ORDER BY COALESCE(priority,2147483647),dictionaries.id");
        defer _ = c.sqlite3_finalize(stmt);
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.DictionaryDatabaseError;
            const title = try a.dupe(u8, column(stmt, 1));
            errdefer a.free(title);
            try list.append(a, .{ .id = @intCast(c.sqlite3_column_int64(stmt, 0)), .title = title });
        }
        return list;
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
        const stmt = try self.prepare("SELECT rules FROM terms WHERE expression=?1 OR reading=?1");
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
        const stmt = try self.prepare("SELECT expression,reading,definition,title,dictionaries.id,term_content.glossary,terms.rowid,COALESCE(priority,2147483647),terms.rules FROM terms JOIN dictionaries ON dictionaries.id=terms.dictionary_id LEFT JOIN dictionary_priorities USING(title) LEFT JOIN term_content ON term_content.term_id=terms.rowid WHERE expression=?1 OR reading=?1 ORDER BY COALESCE(priority,2147483647),dictionaries.id,CASE WHEN expression=?1 THEN 0 ELSE 1 END,terms.rowid");
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

test "import compressed v3 dictionaries, look up Japanese terms and readings, flatten glossaries" {
    var db = try Database.open(":memory:");
    defer db.close();
    const report = try db.importZip(@embedFile("testdata/dictionary-valid.zip"));
    defer a.free(report.title);
    try std.testing.expectEqual(@as(usize, 3), report.entries);
    var matches = try db.lookup("たべる");
    defer {
        for (matches.items) |r| r.deinit();
        matches.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 1), matches.items.len);
    try std.testing.expectEqualStrings("食べる", matches.items[0].term);
    try std.testing.expectEqualStrings("to eat\nto consume\nfood\n", matches.items[0].definition);
    try std.testing.expectEqualStrings("Touitsu test dictionary", matches.items[0].dictionary);
    var cats = try db.lookup("猫");
    defer {
        for (cats.items) |r| r.deinit();
        cats.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 2), cats.items.len);
    var miss = try db.lookup("食べました");
    defer {
        for (miss.items) |result| result.deinit();
        miss.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 1), miss.items.len);
    try std.testing.expect(miss.items[0].deinflection != null);
}

test "failed replacement rolls back and successful replacement does not duplicate terms" {
    var db = try Database.open(":memory:");
    defer db.close();
    const original = try db.importZip(@embedFile("testdata/dictionary-valid.zip"));
    defer a.free(original.title);
    try std.testing.expectError(error.InvalidTermEntry, db.importZip(@embedFile("testdata/dictionary-invalid.zip")));
    var counts = try db.counts();
    try std.testing.expectEqual(@as(usize, 3), counts.terms);
    try std.testing.expectEqual(@as(usize, 1), counts.dictionaries);
    const replacement = try db.importZip(@embedFile("testdata/dictionary-replacement.zip"));
    defer a.free(replacement.title);
    counts = try db.counts();
    try std.testing.expectEqual(@as(usize, 1), counts.terms);
    try std.testing.expectEqual(@as(usize, 1), counts.dictionaries);
    var matches = try db.lookup("犬");
    defer {
        for (matches.items) |r| r.deinit();
        matches.deinit(a);
    }
    try std.testing.expectEqualStrings("dog", matches.items[0].definition);
}

test "unsupported dictionaries and truncated archives fail without modifying the database" {
    var db = try Database.open(":memory:");
    defer db.close();
    try std.testing.expectError(error.UnsupportedDictionaryFormat, db.importZip(@embedFile("testdata/dictionary-v2.zip")));
    try std.testing.expectError(error.InvalidZip, db.importZip("not a zip"));
    const counts = try db.counts();
    try std.testing.expectEqual(@as(usize, 0), counts.dictionaries);
}

test "stored ZIP entries, checksum failures and blank queries" {
    var db = try Database.open(":memory:");
    defer db.close();
    const report = try db.importZip(@embedFile("testdata/dictionary-stored.zip"));
    defer a.free(report.title);
    try std.testing.expectError(error.ZipChecksumMismatch, db.importZip(@embedFile("testdata/dictionary-checksum.zip")));
    const counts = try db.counts();
    try std.testing.expectEqual(@as(usize, 3), counts.terms);
    var matches = try db.lookup(" \t\n");
    defer matches.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), matches.items.len);
}

test "dictionaries and Japanese lookup survive closing and reopening SQLite" {
    const Delete = struct {
        extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
        extern "kernel32" fn DeleteFileW([*:0]const u16) callconv(.winapi) i32;
    };
    const path = try std.fmt.allocPrintSentinel(a, "zig-out/dictionary-test-{d}.sqlite3", .{Delete.GetCurrentProcessId()}, 0);
    defer a.free(path);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
    defer a.free(wide);
    defer _ = Delete.DeleteFileW(wide);
    {
        var db = try Database.open(path);
        defer db.close();
        const report = try db.importZip(@embedFile("testdata/dictionary-valid.zip"));
        defer a.free(report.title);
    }
    var reopened = try Database.open(path);
    defer reopened.close();
    var results = try reopened.lookup("食べる");
    defer {
        for (results.items) |r| r.deinit();
        results.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqualStrings("たべる", results.items[0].reading);
}

test "folder cache skips unchanged archives and removes dictionaries absent from the folder" {
    var db = try Database.open(":memory:");
    defer db.close();
    const report = try db.importZip(@embedFile("testdata/dictionary-valid.zip"));
    defer a.free(report.title);
    try std.testing.expect(!(try db.sourceUnchanged("dicts/test.zip", "hash1")));
    try db.recordSource("dicts/test.zip", report.title, "hash1");
    try std.testing.expect(try db.sourceUnchanged("dicts/test.zip", "hash1"));
    try std.testing.expect(!(try db.sourceUnchanged("dicts/test.zip", "hash2")));
    const source = try a.dupe(u8, "dicts/test.zip");
    defer a.free(source);
    try db.reconcileSources(&.{source});
    var counts = try db.counts();
    try std.testing.expectEqual(@as(usize, 3), counts.terms);
    try db.reconcileSources(&.{});
    counts = try db.counts();
    try std.testing.expectEqual(@as(usize, 0), counts.terms);
    try std.testing.expectEqual(@as(usize, 0), counts.dictionaries);
    try std.testing.expect(!(try db.sourceUnchanged("dicts/test.zip", "hash1")));
}

test "dictionary priorities shift ranks and order lookup before the result limit" {
    var db = try Database.open(":memory:");
    defer db.close();
    try db.exec("INSERT INTO dictionaries(id,title,revision) VALUES(1,'First','1'),(2,'Second','1'),(3,'Third','1'); INSERT INTO terms(dictionary_id,expression,reading,definition,rules) VALUES(1,'word','','first',''),(2,'word','','second',''),(3,'word','','third','')");
    try db.setPriority(2, 0);
    {
        var list = try db.dictionaries();
        defer freeDictionaries(&list);
        try std.testing.expectEqualStrings("Third", list.items[0].title);
        try std.testing.expectEqualStrings("First", list.items[1].title);
        try std.testing.expectEqualStrings("Second", list.items[2].title);
        var matches = try db.lookup("word");
        defer {
            for (matches.items) |result| result.deinit();
            matches.deinit(a);
        }
        try std.testing.expectEqualStrings("Third", matches.items[0].dictionary);
    }
    try db.setPriority(0, 2);
    try db.exec("DELETE FROM terms WHERE dictionary_id=2; DELETE FROM dictionaries WHERE id=2; INSERT INTO dictionaries(id,title,revision) VALUES(4,'Second','2')");
    var list = try db.dictionaries();
    defer freeDictionaries(&list);
    try std.testing.expectEqualStrings("First", list.items[0].title);
    try std.testing.expectEqualStrings("Second", list.items[1].title);
    try std.testing.expectEqualStrings("Third", list.items[2].title);
    try std.testing.expectError(error.InvalidDictionaryPriority, db.setPriority(0, 5));
}

test "image-only headwords are retained alongside searchable entries" {
    var db = try Database.open(":memory:");
    defer db.close();
    const report = try db.importZip(@embedFile("testdata/dictionary-image-headword.zip"));
    defer a.free(report.title);
    try std.testing.expectEqual(@as(usize, 3), report.entries);
    for ([_][]const u8{ "word", "reading-only" }) |query| {
        var matches = try db.lookup(query);
        defer {
            for (matches.items) |result| result.deinit();
            matches.deinit(a);
        }
        try std.testing.expectEqual(@as(usize, 1), matches.items.len);
    }
}

test "dictionary media and structured content survive import and source upgrade" {
    var db = try Database.open(":memory:");
    defer db.close();
    const report = try db.importZip(@embedFile("testdata/dictionary-image-headword.zip"));
    defer a.free(report.title);
    try db.recordSource("images.zip", report.title, "same-zip");
    try std.testing.expect(try db.sourceUnchanged("images.zip", "same-zip"));
    var matches = try db.lookup("word");
    defer {
        for (matches.items) |result| result.deinit();
        matches.deinit(a);
    }
    const result = matches.items[0];
    try std.testing.expect(result.glossary != null);
    try std.testing.expect(std.mem.indexOf(u8, result.glossary.?, "glyph.svg") != null);
    const png = (try db.media(result.dictionary_id, "picture.png")).?;
    defer a.free(png);
    try std.testing.expectEqualSlices(u8, @embedFile("testdata/background-test.png"), png);
    const svg = (try db.media(result.dictionary_id, "glyph.svg")).?;
    defer a.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect((try db.media(result.dictionary_id + 1, "picture.png")) == null);
    try db.exec("UPDATE dictionary_import_state SET version=1");
    try std.testing.expect(!try db.sourceUnchanged("images.zip", "same-zip"));
}

test "longest word scan and deinflected lookup share conjugation rules" {
    var db = try Database.open(":memory:");
    defer db.close();
    try db.exec("INSERT INTO dictionaries(id,title,revision) VALUES(1,'Tagged','1'),(2,'Native','1'); INSERT INTO terms(dictionary_id,expression,reading,definition,rules) VALUES(1,'文','','text','n'),(1,'文字','','characters','n'),(1,'食べる','','eat','v1'),(1,'書く','','write','v5'),(1,'高い','','high','adj-i'),(1,'偽る','','wrong conjugation metadata','n'),(2,'読む','','read',''),(2,'勉強','','study',''),(2,'食べる','','native eat','')");
    const examples = [_][2][]const u8{
        .{ "食べました", "食べる" },
        .{ "食べさせられませんでした", "食べる" },
        .{ "書いている", "書く" },
        .{ "高くなかった", "高い" },
        .{ "読んでいました", "読む" },
        .{ "勉強しました", "勉強" },
    };
    for (examples) |example| {
        var matches = try db.lookup(example[0]);
        defer {
            for (matches.items) |result| result.deinit();
            matches.deinit(a);
        }
        try std.testing.expect(matches.items.len > 0);
        try std.testing.expectEqualStrings(example[1], matches.items[0].term);
        try std.testing.expect(matches.items[0].deinflection != null);
        const source = try std.fmt.allocPrint(a, "{s}。次", .{example[0]});
        defer a.free(source);
        try std.testing.expectEqual(@as(?usize, example[0].len), try db.scanWord(source, 0));
    }
    try std.testing.expectEqual(@as(?usize, "文字".len), try db.scanWord("文字を読む", 0));
    try std.testing.expectEqual(@as(?usize, "文".len), try db.scanWord("文\n字", 0));
    try std.testing.expectEqual(@as(?usize, null), try db.scanWord("文字", 1));
    var invalid = try db.lookup("偽りました");
    defer {
        for (invalid.items) |result| result.deinit();
        invalid.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 0), invalid.items.len);
    try db.setPriority(1, 0);
    var ordered = try db.lookup("食べられました");
    defer {
        for (ordered.items) |result| result.deinit();
        ordered.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 2), ordered.items.len);
    try std.testing.expectEqualStrings("Native", ordered.items[0].dictionary);
    try std.testing.expectEqualStrings("Tagged", ordered.items[1].dictionary);
}

test "popup groups full words before their starting kanji and removes overlaps" {
    var db = try Database.open(":memory:");
    defer db.close();
    try db.exec("INSERT INTO dictionaries(id,title,revision) VALUES(1,'First','1'),(2,'Second','1'); INSERT INTO terms(dictionary_id,expression,reading,definition,rules) VALUES(1,'文字','','word first',''),(2,'文','','character second',''),(1,'文','','character first',''),(2,'文字','','word second',''),(1,'かな','','kana word',''),(1,'か','','kana character','')");
    try db.setPriority(1, 0);
    const queries = [_][]const u8{ "文字", "文でした", "文", "かな", "文不存在" };
    const expected_words = [_]usize{ 2, 2, 2, 1, 0 };
    const expected_counts = [_]usize{ 4, 2, 2, 1, 2 };
    for (queries, expected_words, expected_counts) |query, word_count, total| {
        var popup = try db.lookupPopup(query);
        defer {
            for (popup.results.items) |result| result.deinit();
            popup.results.deinit(a);
        }
        try std.testing.expectEqual(word_count, popup.word_count);
        try std.testing.expectEqual(total, popup.results.items.len);
        if (std.mem.eql(u8, query, "文字")) {
            try std.testing.expectEqualStrings("文字", popup.results.items[0].term);
            try std.testing.expectEqualStrings("文字", popup.results.items[1].term);
            try std.testing.expectEqualStrings("文", popup.results.items[2].term);
            try std.testing.expectEqualStrings("文", popup.results.items[3].term);
            try std.testing.expectEqualStrings("Second", popup.results.items[0].dictionary);
            try std.testing.expectEqualStrings("First", popup.results.items[1].dictionary);
            try std.testing.expectEqualStrings("Second", popup.results.items[2].dictionary);
        }
    }
}
