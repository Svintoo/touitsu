//! Native Japanese lookup candidates. Grammar rules here are independent of the UI.
//! This implements common conjugations;
const std = @import("std");
pub const v1: u8 = 1;
pub const v5: u8 = 2;
pub const vs: u8 = 4;
pub const vk: u8 = 8;
pub const adj_i: u8 = 16;
pub const copula: u8 = 32;
const verbs = v1 | v5 | vs | vk;

/// Return the starting kanji as complete UTF-8 bytes, including supplementary CJK.
pub fn firstKanji(text: []const u8) ?[]const u8 {
    if (text.len == 0) return null;
    const size = std.unicode.utf8ByteSequenceLength(text[0]) catch return null;
    if (size > text.len) return null;
    const cp = std.unicode.utf8Decode(text[0..size]) catch return null;
    if ((cp >= 0x3400 and cp <= 0x4dbf) or (cp >= 0x4e00 and cp <= 0x9fff) or
        (cp >= 0xf900 and cp <= 0xfaff) or (cp >= 0x20000 and cp <= 0x323af) or cp == 0x3007)
        return text[0..size];
    return null;
}

pub const Candidate = struct {
    text: []const u8,
    classes: u8 = 0,
    depth: u8 = 0,
    reason: []const u8 = "",
};
const Rule = struct { suffix: []const u8, base: []const u8, accepts: u8, produces: u8, reason: []const u8 };
const Row = struct { dictionary: []const u8, a: []const u8, i: []const u8, e: []const u8, o: []const u8, past: []const u8, te: []const u8 };
const godan = [_]Row{
    .{ .dictionary = "う", .a = "わ", .i = "い", .e = "え", .o = "お", .past = "った", .te = "って" },
    .{ .dictionary = "く", .a = "か", .i = "き", .e = "け", .o = "こ", .past = "いた", .te = "いて" },
    .{ .dictionary = "ぐ", .a = "が", .i = "ぎ", .e = "げ", .o = "ご", .past = "いだ", .te = "いで" },
    .{ .dictionary = "す", .a = "さ", .i = "し", .e = "せ", .o = "そ", .past = "した", .te = "して" },
    .{ .dictionary = "つ", .a = "た", .i = "ち", .e = "て", .o = "と", .past = "った", .te = "って" },
    .{ .dictionary = "ぬ", .a = "な", .i = "に", .e = "ね", .o = "の", .past = "んだ", .te = "んで" },
    .{ .dictionary = "ぶ", .a = "ば", .i = "び", .e = "べ", .o = "ぼ", .past = "んだ", .te = "んで" },
    .{ .dictionary = "む", .a = "ま", .i = "み", .e = "め", .o = "も", .past = "んだ", .te = "んで" },
    .{ .dictionary = "る", .a = "ら", .i = "り", .e = "れ", .o = "ろ", .past = "った", .te = "って" },
};

// accept describes the intermediate dictionary-form verb produced by a previous
// reversal. It prevents, for example, treating an adjective as a polite verb.
const rules = blk: {
    @setEvalBranchQuota(100000);
    var list: []const Rule = &.{
        .{ .suffix = "ませんでした", .base = "る", .accepts = v1, .produces = v1, .reason = "polite negative past" },
        .{ .suffix = "ません", .base = "る", .accepts = v1, .produces = v1, .reason = "polite negative" },
        .{ .suffix = "ました", .base = "る", .accepts = v1, .produces = v1, .reason = "polite past" },
        .{ .suffix = "ます", .base = "る", .accepts = v1, .produces = v1, .reason = "polite" },
        .{ .suffix = "ましょう", .base = "る", .accepts = v1, .produces = v1, .reason = "polite volitional" },
        .{ .suffix = "ない", .base = "る", .accepts = adj_i, .produces = v1, .reason = "negative" },
        .{ .suffix = "ぬ", .base = "る", .accepts = verbs, .produces = v1, .reason = "negative" },
        .{ .suffix = "ず", .base = "る", .accepts = verbs, .produces = v1, .reason = "negative" },
        .{ .suffix = "た", .base = "る", .accepts = v1, .produces = v1, .reason = "past" },
        .{ .suffix = "て", .base = "る", .accepts = v1, .produces = v1, .reason = "te form" },
        .{ .suffix = "れば", .base = "る", .accepts = v1, .produces = v1, .reason = "conditional" },
        .{ .suffix = "ろ", .base = "る", .accepts = v1, .produces = v1, .reason = "imperative" },
        .{ .suffix = "よ", .base = "る", .accepts = v1, .produces = v1, .reason = "imperative" },
        .{ .suffix = "よう", .base = "る", .accepts = v1, .produces = v1, .reason = "volitional" },
        .{ .suffix = "られる", .base = "る", .accepts = v1, .produces = v1, .reason = "potential / passive" },
        .{ .suffix = "させる", .base = "る", .accepts = v1, .produces = v1, .reason = "causative" },
        .{ .suffix = "れる", .base = "る", .accepts = v1, .produces = v1, .reason = "colloquial potential" },
        .{ .suffix = "かった", .base = "い", .accepts = adj_i, .produces = adj_i, .reason = "adjective past" },
        .{ .suffix = "くない", .base = "い", .accepts = adj_i, .produces = adj_i, .reason = "adjective negative" },
        .{ .suffix = "く", .base = "い", .accepts = adj_i, .produces = adj_i, .reason = "adverbial" },
        .{ .suffix = "くて", .base = "い", .accepts = adj_i, .produces = adj_i, .reason = "adjective te form" },
        .{ .suffix = "ければ", .base = "い", .accepts = adj_i, .produces = adj_i, .reason = "adjective conditional" },
        .{ .suffix = "です", .base = "", .accepts = adj_i | copula, .produces = adj_i | copula, .reason = "polite copula" },
        .{ .suffix = "でした", .base = "", .accepts = copula, .produces = copula, .reason = "polite past copula" },
        .{ .suffix = "だった", .base = "", .accepts = copula, .produces = copula, .reason = "past copula" },
        .{ .suffix = "ではない", .base = "", .accepts = adj_i, .produces = copula, .reason = "negative copula" },
        .{ .suffix = "じゃない", .base = "", .accepts = adj_i, .produces = copula, .reason = "negative copula" },
        .{ .suffix = "たい", .base = "る", .accepts = adj_i, .produces = v1, .reason = "desiderative" },
        .{ .suffix = "たら", .base = "た", .accepts = verbs, .produces = verbs, .reason = "conditional" },
        .{ .suffix = "だら", .base = "だ", .accepts = verbs, .produces = v5, .reason = "conditional" },
        .{ .suffix = "たり", .base = "た", .accepts = verbs, .produces = verbs, .reason = "enumerative" },
        .{ .suffix = "だり", .base = "だ", .accepts = verbs, .produces = v5, .reason = "enumerative" },
        .{ .suffix = "ている", .base = "て", .accepts = v1, .produces = verbs, .reason = "progressive" },
        .{ .suffix = "でいる", .base = "で", .accepts = v1, .produces = v5, .reason = "progressive" },
        .{ .suffix = "てる", .base = "て", .accepts = v1, .produces = verbs, .reason = "colloquial progressive" },
        .{ .suffix = "でる", .base = "で", .accepts = v1, .produces = v5, .reason = "colloquial progressive" },
        .{ .suffix = "てしまう", .base = "て", .accepts = v5, .produces = verbs, .reason = "completion" },
        .{ .suffix = "でしまう", .base = "で", .accepts = v5, .produces = v5, .reason = "completion" },
        .{ .suffix = "ちゃう", .base = "て", .accepts = v5, .produces = verbs, .reason = "colloquial completion" },
        .{ .suffix = "じゃう", .base = "で", .accepts = v5, .produces = v5, .reason = "colloquial completion" },
        .{ .suffix = "ておく", .base = "て", .accepts = v5, .produces = verbs, .reason = "preparatory" },
        .{ .suffix = "でおく", .base = "で", .accepts = v5, .produces = v5, .reason = "preparatory" },
        .{ .suffix = "とく", .base = "て", .accepts = v5, .produces = verbs, .reason = "colloquial preparatory" },
        .{ .suffix = "どく", .base = "で", .accepts = v5, .produces = v5, .reason = "colloquial preparatory" },
        .{ .suffix = "すぎる", .base = "る", .accepts = v1, .produces = v1, .reason = "excessive" },
        .{ .suffix = "すぎる", .base = "い", .accepts = v1, .produces = adj_i, .reason = "excessive" },
    };
    for (godan) |row| {
        list = list ++ &[_]Rule{
            .{ .suffix = row.i ++ "ます", .base = row.dictionary, .accepts = v5, .produces = v5, .reason = "polite" },
            .{ .suffix = row.i ++ "ました", .base = row.dictionary, .accepts = v5, .produces = v5, .reason = "polite past" },
            .{ .suffix = row.i ++ "ません", .base = row.dictionary, .accepts = v5, .produces = v5, .reason = "polite negative" },
            .{ .suffix = row.i ++ "ませんでした", .base = row.dictionary, .accepts = v5, .produces = v5, .reason = "polite negative past" },
            .{ .suffix = row.i ++ "ましょう", .base = row.dictionary, .accepts = v5, .produces = v5, .reason = "polite volitional" },
            .{ .suffix = row.a ++ "ない", .base = row.dictionary, .accepts = adj_i, .produces = v5, .reason = "negative" },
            .{ .suffix = row.a ++ "ぬ", .base = row.dictionary, .accepts = verbs, .produces = v5, .reason = "negative" },
            .{ .suffix = row.a ++ "ず", .base = row.dictionary, .accepts = verbs, .produces = v5, .reason = "negative" },
            .{ .suffix = row.past, .base = row.dictionary, .accepts = v5, .produces = v5, .reason = "past" },
            .{ .suffix = row.te, .base = row.dictionary, .accepts = v5, .produces = v5, .reason = "te form" },
            .{ .suffix = row.e ++ "る", .base = row.dictionary, .accepts = v1, .produces = v5, .reason = "potential" },
            .{ .suffix = row.a ++ "れる", .base = row.dictionary, .accepts = v1, .produces = v5, .reason = "passive" },
            .{ .suffix = row.a ++ "せる", .base = row.dictionary, .accepts = v1, .produces = v5, .reason = "causative" },
            .{ .suffix = row.a ++ "される", .base = row.dictionary, .accepts = v1, .produces = v5, .reason = "causative passive" },
            .{ .suffix = row.e ++ "ば", .base = row.dictionary, .accepts = v5, .produces = v5, .reason = "conditional" },
            .{ .suffix = row.e, .base = row.dictionary, .accepts = v5, .produces = v5, .reason = "imperative" },
            .{ .suffix = row.o ++ "う", .base = row.dictionary, .accepts = v5, .produces = v5, .reason = "volitional" },
            .{ .suffix = row.i ++ "たい", .base = row.dictionary, .accepts = adj_i, .produces = v5, .reason = "desiderative" },
            .{ .suffix = row.i ++ "すぎる", .base = row.dictionary, .accepts = v1, .produces = v5, .reason = "excessive" },
        };
    }
    // Irregular suru/kuru forms and iku's exceptional te/past forms.
    for ([_]struct { stem: []const u8, base: []const u8, class: u8 }{
        .{ .stem = "し", .base = "する", .class = vs },
        .{ .stem = "き", .base = "くる", .class = vk },
        .{ .stem = "来", .base = "来る", .class = vk },
    }) |irregular| {
        list = list ++ &[_]Rule{
            .{ .suffix = irregular.stem ++ "ます", .base = irregular.base, .accepts = irregular.class, .produces = irregular.class, .reason = "polite" },
            .{ .suffix = irregular.stem ++ "ました", .base = irregular.base, .accepts = irregular.class, .produces = irregular.class, .reason = "polite past" },
            .{ .suffix = irregular.stem ++ "ません", .base = irregular.base, .accepts = irregular.class, .produces = irregular.class, .reason = "polite negative" },
            .{ .suffix = irregular.stem ++ "ませんでした", .base = irregular.base, .accepts = irregular.class, .produces = irregular.class, .reason = "polite negative past" },
            .{ .suffix = irregular.stem ++ "ましょう", .base = irregular.base, .accepts = irregular.class, .produces = irregular.class, .reason = "polite volitional" },
            .{ .suffix = irregular.stem ++ "た", .base = irregular.base, .accepts = irregular.class, .produces = irregular.class, .reason = "past" },
            .{ .suffix = irregular.stem ++ "て", .base = irregular.base, .accepts = irregular.class, .produces = irregular.class, .reason = "te form" },
            .{ .suffix = irregular.stem ++ "たい", .base = irregular.base, .accepts = adj_i, .produces = irregular.class, .reason = "desiderative" },
        };
    }
    list = list ++ &[_]Rule{
        .{ .suffix = "する", .base = "", .accepts = vs, .produces = vs, .reason = "suru compound" },
        .{ .suffix = "しない", .base = "する", .accepts = adj_i, .produces = vs, .reason = "negative" },
        .{ .suffix = "しなかった", .base = "する", .accepts = vs, .produces = vs, .reason = "negative past" },
        .{ .suffix = "すれば", .base = "する", .accepts = vs, .produces = vs, .reason = "conditional" },
        .{ .suffix = "しよう", .base = "する", .accepts = vs, .produces = vs, .reason = "volitional" },
        .{ .suffix = "される", .base = "する", .accepts = v1, .produces = vs, .reason = "passive" },
        .{ .suffix = "させる", .base = "する", .accepts = v1, .produces = vs, .reason = "causative" },
        .{ .suffix = "できる", .base = "する", .accepts = v1, .produces = vs, .reason = "potential" },
        .{ .suffix = "しろ", .base = "する", .accepts = vs, .produces = vs, .reason = "imperative" },
        .{ .suffix = "こない", .base = "くる", .accepts = adj_i, .produces = vk, .reason = "negative" },
        .{ .suffix = "来ない", .base = "来る", .accepts = adj_i, .produces = vk, .reason = "negative" },
        .{ .suffix = "こられる", .base = "くる", .accepts = v1, .produces = vk, .reason = "potential / passive" },
        .{ .suffix = "来られる", .base = "来る", .accepts = v1, .produces = vk, .reason = "potential / passive" },
        .{ .suffix = "こさせる", .base = "くる", .accepts = v1, .produces = vk, .reason = "causative" },
        .{ .suffix = "来させる", .base = "来る", .accepts = v1, .produces = vk, .reason = "causative" },
        .{ .suffix = "くれば", .base = "くる", .accepts = vk, .produces = vk, .reason = "conditional" },
        .{ .suffix = "来れば", .base = "来る", .accepts = vk, .produces = vk, .reason = "conditional" },
        .{ .suffix = "こよう", .base = "くる", .accepts = vk, .produces = vk, .reason = "volitional" },
        .{ .suffix = "来よう", .base = "来る", .accepts = vk, .produces = vk, .reason = "volitional" },
        .{ .suffix = "こい", .base = "くる", .accepts = vk, .produces = vk, .reason = "imperative" },
        .{ .suffix = "来い", .base = "来る", .accepts = vk, .produces = vk, .reason = "imperative" },
        .{ .suffix = "行った", .base = "行く", .accepts = v5, .produces = v5, .reason = "past" },
        .{ .suffix = "行って", .base = "行く", .accepts = v5, .produces = v5, .reason = "te form" },
        .{ .suffix = "いった", .base = "いく", .accepts = v5, .produces = v5, .reason = "past" },
        .{ .suffix = "いって", .base = "いく", .accepts = v5, .produces = v5, .reason = "te form" },
        .{ .suffix = "よかった", .base = "いい", .accepts = adj_i, .produces = adj_i, .reason = "adjective past" },
        .{ .suffix = "よくない", .base = "いい", .accepts = adj_i, .produces = adj_i, .reason = "adjective negative" },
    };
    break :blk list;
};

/// All strings belong to the supplied allocator (normally a short-lived arena).
pub fn candidates(a: std.mem.Allocator, text: []const u8) ![]const Candidate {
    var list: std.ArrayList(Candidate) = .empty;
    try list.append(a, .{ .text = text });
    var cursor: usize = 0;
    while (cursor < list.items.len and list.items.len < 192) : (cursor += 1) {
        const previous = list.items[cursor];
        if (previous.depth >= 6) continue;
        for (rules) |rule| {
            if (previous.classes != 0 and previous.classes & rule.accepts == 0) continue;
            if (!std.mem.endsWith(u8, previous.text, rule.suffix)) continue;
            const stem = previous.text[0 .. previous.text.len - rule.suffix.len];
            if (stem.len == 0 and rule.base.len == 0) continue;
            const restored = try std.mem.concat(a, u8, &.{ stem, rule.base });
            var duplicate = false;
            for (list.items) |old| {
                if (old.classes == rule.produces and std.mem.eql(u8, old.text, restored)) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;
            const reason = if (previous.depth == 0) rule.reason else try std.fmt.allocPrint(a, "{s} / {s}", .{ previous.reason, rule.reason });
            try list.append(a, .{ .text = restored, .classes = rule.produces, .depth = previous.depth + 1, .reason = reason });
            if (list.items.len >= 192) break;
        }
    }
    return list.items;
}

pub fn compatible(tags: []const u8, required: u8) bool {
    if (required == 0) return true;
    // Many monolingual dictionaries provide no conjugation metadata. Candidates
    // still have to resolve to an actual headword/reading in those dictionaries.
    if (std.mem.trim(u8, tags, " \t\r\n").len == 0) return true;
    var it = std.mem.tokenizeAny(u8, tags, " \t\r\n");
    while (it.next()) |tag| {
        if (required & v1 != 0 and std.mem.startsWith(u8, tag, "v1")) return true;
        if (required & v5 != 0 and std.mem.startsWith(u8, tag, "v5")) return true;
        if (required & vs != 0 and std.mem.startsWith(u8, tag, "vs")) return true;
        if (required & vk != 0 and std.mem.eql(u8, tag, "vk")) return true;
        if (required & adj_i != 0 and std.mem.startsWith(u8, tag, "adj-i")) return true;
        if (required & copula != 0 and (std.mem.eql(u8, tag, "adj-na") or std.mem.eql(u8, tag, "n"))) return true;
    }
    return false;
}

/// Scan forward from a UTF-8 glyph boundary, stopping at a sentence boundary.
pub fn prefixEnds(text: []const u8, start: usize, ends: *[32]usize) usize {
    if (start >= text.len or text[start] & 0xc0 == 0x80) return 0;
    var offset = start;
    var count: usize = 0;
    while (offset < text.len and count < ends.len) {
        const size = std.unicode.utf8ByteSequenceLength(text[offset]) catch break;
        if (offset + size > text.len) break;
        const cp = std.unicode.utf8Decode(text[offset..][0..size]) catch break;
        if (@import("../components/reader/reader_text.zig").isWhitespace(cp) or cp == '。' or cp == '、' or cp == '！' or cp == '？' or cp == '「' or cp == '」' or cp == '『' or cp == '』' or cp == '（' or cp == '）' or cp == '!' or cp == '?') break;
        offset += size;
        ends[count] = offset;
        count += 1;
    }
    return count;
}

test "Japanese candidates cover common verbs adjectives and chained forms" {
    const pairs = [_][2][]const u8{
        .{ "食べました", "食べる" },
        .{ "食べませんでした", "食べる" },
        .{ "書いている", "書く" },
        .{ "読んでいました", "読む" },
        .{ "食べさせられませんでした", "食べる" },
        .{ "書かされました", "書く" },
        .{ "泳げなかった", "泳ぐ" },
        .{ "話したくなかった", "話す" },
        .{ "高くなかった", "高い" },
        .{ "高かったです", "高い" },
        .{ "勉強しました", "勉強する" },
        .{ "来られなかった", "来る" },
        .{ "行っちゃった", "行く" },
        .{ "読んじゃった", "読む" },
    };
    for (pairs) |pair| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const forms = try candidates(arena.allocator(), pair[0]);
        var found = false;
        for (forms) |form| {
            if (std.mem.eql(u8, form.text, pair[1])) {
                found = true;
                break;
            }
        }
        if (!found) std.debug.print("Missing deinflection: {s} -> {s}\n", .{ pair[0], pair[1] });
        try std.testing.expect(found);
        try std.testing.expect(forms.len <= 192);
    }
}
test "conjugation metadata and UTF-8 scan boundaries" {
    try std.testing.expect(compatible("v1", v1));
    try std.testing.expect(!compatible("v5", v1));
    try std.testing.expect(!compatible("adj-i", v5));
    try std.testing.expect(compatible("", v5));
    var ends: [32]usize = undefined;
    try std.testing.expectEqual(@as(usize, 2), prefixEnds("文字。次", 0, &ends));
    try std.testing.expectEqual(@as(usize, 6), ends[1]);
    try std.testing.expectEqual(@as(usize, 0), prefixEnds("文字", 1, &ends));
}
