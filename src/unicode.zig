// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const unicode = @import("unicode_generated");

/// Text validation profile.
///
/// - `name` — user-visible names (guild/channel/role names, display names,
///   topics): every forbidden codepoint is rejected;
/// - `message` — message bodies: forbidden codepoints are stripped, except
///   the ones required for legit text (whitespace, ZWJ sequences, bidi
///   marks/isolates, variation selectors, tag characters).
pub const TextProfile = enum {
    name,
    message,
};

/// Position (in codepoints) and value of a forbidden codepoint found in a
/// string.
pub const TextViolation = struct {
    offset: usize,
    cp: u21,
};

/// Returns `true` if `cp` is invisible/unsafe: a control, format character
/// (zero-width, BiDi overrides, tag characters, ...), private-use codepoint
/// (tofu), line/paragraph separator, `Default_Ignorable_Code_Point`,
/// noncharacter, or `Bidi_Control` codepoint.
///
/// The properties are derived from the pinned UCD (`UnicodeData.txt`,
/// `DerivedCoreProperties.txt`, `PropList.txt`) by `tools/gen-unicode.zig`.
inline fn isInvisible(cp: u21) bool {
    const p = unicode.props(cp);

    return p.control or p.format or p.private_use or p.line_separator or
        p.default_ignorable or p.noncharacter or p.bidi_control or
        // U+2800 BRAILLE PATTERN BLANK renders as nothing; not a UCD property.
        cp == 0x2800;
}

/// Codepoints that are invisible by the `isInvisible` classification but are
/// still required for legit message text: tab/newline, ZWNJ/ZWJ, bidi marks
/// and isolates, variation selectors and tag characters.
inline fn isMessageKept(cp: u21) bool {
    return switch (cp) {
        0x0009,
        0x000A,
        0x200C...0x200F,
        0x2066...0x2069,
        0xFE00...0xFE0F,
        0xE0000...0xE007F,
        0xE0100...0xE01EF,
        => true,
        else => false,
    };
}

/// Returns `true` if `cp` must be rejected for the profile.
///
/// For `name` every invisible codepoint is rejected; for `message` only the
/// invisible codepoints that are not required by `isMessageKept` are.
pub inline fn isForbiddenCodepoint(profile: TextProfile, cp: u21) bool {
    if (!isInvisible(cp)) {
        return false;
    }

    return switch (profile) {
        .name => true,
        .message => !isMessageKept(cp),
    };
}

/// Returns the first codepoint forbidden for the profile, or `null` if the
/// string is clean.
///
/// The input must be valid UTF-8; `error.InvalidUtf8` is returned otherwise.
pub inline fn findForbiddenCodepoint(profile: TextProfile, s: []const u8) error{InvalidUtf8}!?TextViolation {
    var i: usize = 0;
    var offset: usize = 0;

    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return error.InvalidUtf8;

        if (i + n > s.len) {
            return error.InvalidUtf8;
        }

        const cp = std.unicode.utf8Decode(s[i..][0..n]) catch return error.InvalidUtf8;

        if (isForbiddenCodepoint(profile, cp)) {
            return .{ .offset = offset, .cp = cp };
        }

        i += n;
        offset += 1;
    }

    return null;
}

/// Message profile sanitizer: NFKC-normalizes `s` and returns a copy with
/// forbidden codepoints removed (see `isForbiddenCodepoint`).
///
/// The input must be valid UTF-8; `error.InvalidUtf8` is returned otherwise.
pub inline fn sanitizeMessageText(allocator: std.mem.Allocator, s: []const u8) error{ InvalidUtf8, OutOfMemory }![]u8 {
    const normalized = try nfkc(allocator, s);
    defer allocator.free(normalized);

    const buf = try allocator.alloc(u8, normalized.len);
    errdefer allocator.free(buf);

    var i: usize = 0;
    var o: usize = 0;

    while (i < normalized.len) {
        const n = std.unicode.utf8ByteSequenceLength(normalized[i]) catch return error.InvalidUtf8;

        if (i + n > normalized.len) {
            return error.InvalidUtf8;
        }

        const cp = std.unicode.utf8Decode(normalized[i..][0..n]) catch return error.InvalidUtf8;

        if (!isForbiddenCodepoint(.message, cp)) {
            @memcpy(buf[o..][0..n], normalized[i..][0..n]);

            o += n;
        }

        i += n;
    }

    if (o == buf.len) {
        return buf;
    }

    if (allocator.remap(buf, o)) |out| {
        return out;
    }

    const out = try allocator.alloc(u8, o);
    @memcpy(out, buf[0..o]);
    allocator.free(buf);

    return out;
}

/// Hangul syllable composition constants (UAX #15, section 10).
const HANGUL_S_BASE: u21 = 0xAC00;
const HANGUL_L_BASE: u21 = 0x1100;
const HANGUL_V_BASE: u21 = 0x1161;
const HANGUL_T_BASE: u21 = 0x11A7;
const HANGUL_L_COUNT: u21 = 19;
const HANGUL_V_COUNT: u21 = 21;
const HANGUL_T_COUNT: u21 = 28;
const HANGUL_N_COUNT: u21 = HANGUL_V_COUNT * HANGUL_T_COUNT;
const HANGUL_S_COUNT: u21 = HANGUL_L_COUNT * HANGUL_N_COUNT;

/// Looks up the generated Unicode data for `cp`, if it participates in any
/// decomposition or has a non-zero canonical combining class.
inline fn unicodeData(cp: u21) ?unicode.DataEntry {
    var buffer: [8]u8 = undefined;

    const key = std.fmt.bufPrint(&buffer, "{X:0>4}", .{cp}) catch {
        return null;
    };

    return unicode.DATA.get(key);
}

/// Canonical combining class of `cp` (0 for starters).
inline fn combiningClass(cp: u21) u8 {
    const entry = unicodeData(cp) orelse return 0;

    return entry.combining_class;
}

/// Appends the full compatibility decomposition of `cp` to `out`, following
/// the generated mappings recursively. Hangul syllables are decomposed
/// algorithmically. Codepoints without a mapping are appended as-is.
fn appendDecomposed(out: *std.ArrayList(u21), allocator: std.mem.Allocator, cp: u21) error{OutOfMemory}!void {
    if (cp >= HANGUL_S_BASE and cp < HANGUL_S_BASE + HANGUL_S_COUNT) {
        const s_index = cp - HANGUL_S_BASE;

        const l = HANGUL_L_BASE + s_index / HANGUL_N_COUNT;
        const v = HANGUL_V_BASE + (s_index % HANGUL_N_COUNT) / HANGUL_T_COUNT;
        const t = HANGUL_T_BASE + s_index % HANGUL_T_COUNT;

        try out.append(allocator, l);
        try out.append(allocator, v);

        if (s_index % HANGUL_T_COUNT != 0) {
            try out.append(allocator, t);
        }

        return;
    }

    if (unicodeData(cp)) |entry| {
        if (entry.decomposition.len != 0) {
            for (entry.decomposition) |part| {
                try appendDecomposed(out, allocator, part);
            }

            return;
        }
    }

    try out.append(allocator, cp);
}

/// Returns the canonical composition of `first` and `second`, or `null` if the
/// pair does not compose. Hangul LV/LVT composition is algorithmic.
inline fn composePair(first: u21, second: u21) ?u21 {
    if (first >= HANGUL_L_BASE and first < HANGUL_L_BASE + HANGUL_L_COUNT and
        second >= HANGUL_V_BASE and second < HANGUL_V_BASE + HANGUL_V_COUNT)
    {
        const l_index = first - HANGUL_L_BASE;
        const v_index = second - HANGUL_V_BASE;

        return HANGUL_S_BASE + (l_index * HANGUL_V_COUNT + v_index) * HANGUL_T_COUNT;
    }

    if (first >= HANGUL_S_BASE and first < HANGUL_S_BASE + HANGUL_S_COUNT and
        (first - HANGUL_S_BASE) % HANGUL_T_COUNT == 0 and
        second > HANGUL_T_BASE and second < HANGUL_T_BASE + HANGUL_T_COUNT)
    {
        return first + (second - HANGUL_T_BASE);
    }

    var buffer: [16]u8 = undefined;

    const key = std.fmt.bufPrint(&buffer, "{X:0>6}{X:0>6}", .{ first, second }) catch return null;

    return unicode.COMPOSITION.get(key);
}

/// NFKC normalization (compatibility decomposition, canonical ordering,
/// canonical composition) over the pinned Unicode version.
///
/// The returned slice is owned by the caller.
pub fn nfkc(allocator: std.mem.Allocator, s: []const u8) error{ InvalidUtf8, OutOfMemory }![]u8 {
    var decomposed: std.ArrayList(u21) = .empty;
    defer decomposed.deinit(allocator);

    var i: usize = 0;

    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return error.InvalidUtf8;

        if (i + n > s.len) {
            return error.InvalidUtf8;
        }

        const cp = std.unicode.utf8Decode(s[i..][0..n]) catch return error.InvalidUtf8;

        try appendDecomposed(&decomposed, allocator, cp);

        i += n;
    }

    const items = decomposed.items;

    if (items.len == 0) {
        return allocator.alloc(u8, 0);
    }

    // Canonical ordering: stable insertion sort of non-starters by combining
    // class (UAX #15, "Canonical Ordering Algorithm").
    var j: usize = 1;

    while (j < items.len) : (j += 1) {
        const cc = combiningClass(items[j]);

        if (cc == 0) {
            continue;
        }

        var k = j;

        while (k > 0 and combiningClass(items[k - 1]) > cc) {
            std.mem.swap(u21, &items[k - 1], &items[k]);

            k -= 1;
        }
    }

    // Canonical composition (UAX #15, "Canonical Composition Algorithm").
    var starter_pos: usize = 0;
    var starter: u21 = items[0];
    var comp_pos: usize = 1;
    var last_class: u8 = combiningClass(starter);

    if (last_class != 0) {
        last_class = 255;
    }

    var decomp_pos: usize = 1;

    while (decomp_pos < items.len) : (decomp_pos += 1) {
        const cp = items[decomp_pos];
        const cc = combiningClass(cp);

        if (last_class == 0 or last_class < cc) {
            if (composePair(starter, cp)) |composite| {
                items[starter_pos] = composite;
                starter = composite;

                continue;
            }
        }

        if (cc == 0) {
            starter_pos = comp_pos;
            starter = cp;
        }

        last_class = cc;
        items[comp_pos] = cp;
        comp_pos += 1;
    }

    const buf = try allocator.alloc(u8, comp_pos * 4);
    errdefer allocator.free(buf);

    var o: usize = 0;

    for (items[0..comp_pos]) |cp| {
        o += std.unicode.utf8Encode(cp, buf[o..]) catch unreachable;
    }

    if (o == buf.len) {
        return buf;
    }

    if (allocator.remap(buf, o)) |out| {
        return out;
    }

    const out = try allocator.alloc(u8, o);
    @memcpy(out, buf[0..o]);
    allocator.free(buf);

    return out;
}

/// Canonical entry point for normalizing user-supplied text: NFKC over the
/// pinned Unicode version. The returned slice is owned by the caller.
pub inline fn normalize(allocator: std.mem.Allocator, s: []const u8) error{ InvalidUtf8, OutOfMemory }![]u8 {
    return nfkc(allocator, s);
}

/// Returns `true` if `s` is exactly one `fully-qualified` RGI emoji sequence
/// from `emoji/emoji-test.txt`.
///
/// The match is byte-exact against the raw sequence and rejects concatenations
/// as well as minimally-qualified, unqualified and component sequences. The
/// input must **not** be NFKC-normalized first: normalization decomposes some
/// RGI emoji, which would make the match fail.
pub inline fn isFullyQualifiedEmoji(s: []const u8) bool {
    return unicode.EMOJI_FULLY_QUALIFIED.get(s) != null;
}

/// Canonicalizes a unicode reaction target: returns the fully-qualified RGI
/// sequence for an emoji in any qualification form (`unqualified` and
/// `minimally-qualified` forms are generated from `emoji-test.txt`), or the
/// regional indicator itself, which has no RGI form. Returns `null` for
/// anything that is not exactly one emoji sequence (components, concatenations,
/// arbitrary text).
///
/// Callers store and look up the canonical form so two renderings of one emoji
/// cannot become two different reactions.
pub inline fn canonicalReactionEmoji(s: []const u8) ?[]const u8 {
    if (unicode.EMOJI_CANONICAL.get(s)) |canonical| {
        return canonical;
    }

    if (isFullyQualifiedEmoji(s) or isRegionalIndicator(s)) {
        return s;
    }

    return null;
}

/// Returns `true` if `s` is exactly one regional indicator symbol
/// (U+1F1E6 .. U+1F1FF), the letter emoji flags are built from.
///
/// `emoji-test.txt` only lists regional indicator *pairs* (and longer flag
/// sequences) as fully-qualified.
pub inline fn isRegionalIndicator(s: []const u8) bool {
    // U+1F1E6 .. U+1F1FF encode as F0 9F 87 A6 .. F0 9F 87 BF.
    return s.len == 4 and s[0] == 0xF0 and s[1] == 0x9F and s[2] == 0x87 and
        s[3] >= 0xA6 and s[3] <= 0xBF;
}

test "findForbiddenCodepoint: strict profile rejects each forbidden class" {
    const strict_cases = [_][]const u8{
        "a\x01b", // C0 control
        "a\x7Fb", // C0 control (DEL)
        "a\u{009F}b", // C1 control
        "a\nb", // LF
        "a\u{00AD}b", // soft hyphen (Default_Ignorable)
        "a\u{200B}b", // zero-width space (Default_Ignorable)
        "a\u{200C}b", // ZWNJ (Cf)
        "a\u{200D}b", // ZWJ (Cf)
        "a\u{200E}b", // LRM (Bidi_Control)
        "a\u{202E}b", // BiDi override (Bidi_Control)
        "a\u{2066}b", // isolate (Bidi_Control)
        "a\u{2060}b", // word joiner (Cf)
        "a\u{FEFF}b", // BOM (Cf)
        "a\u{FE0F}b", // variation selector (Default_Ignorable)
        "a\u{E0041}b", // tag character (Cf)
        "a\u{FDD0}b", // noncharacter
        "a\u{2028}b", // line separator (Zl)
        "a\u{2029}b", // paragraph separator (Zp)
        "a\u{3164}b", // hangul filler
        "a\u{115F}b", // hangul filler
        "a\u{FFA0}b", // halfwidth hangul filler
        "a\u{2800}b", // blank braille pattern
        "a\u{E000}b", // private use area
        "a\u{F0000}b", // private use area plane 15
        "a\u{10FFFD}b", // private use area plane 16
    };

    for (strict_cases) |s| {
        const violation = try findForbiddenCodepoint(.name, s);

        if (violation == null) {
            std.debug.print("expected a violation in '{any}'\n", .{s});

            return error.TestUnexpectedResult;
        }
    }
}

test "findForbiddenCodepoint: clean strings pass" {
    const clean_cases = [_][]const u8{
        "hello",
        "привет",
        "olá, mundo",
    };

    for (clean_cases) |s| {
        const violation = try findForbiddenCodepoint(.name, s);

        if (violation != null) {
            std.debug.print("unexpected violation at codepoint 0x{X} in '{any}'\n", .{ violation.?.cp, s });

            return error.TestUnexpectedResult;
        }
    }
}

test "findForbiddenCodepoint: violation offset and codepoint" {
    const violation = (try findForbiddenCodepoint(.name, "a\u{200B}b")).?;

    try std.testing.expectEqual(@as(usize, 1), violation.offset);
    try std.testing.expectEqual(@as(u21, 0x200B), violation.cp);
}

test "findForbiddenCodepoint: invalid UTF-8 is an error" {
    try std.testing.expectError(error.InvalidUtf8, findForbiddenCodepoint(.name, "a\xffb"));
    try std.testing.expectError(error.InvalidUtf8, findForbiddenCodepoint(.name, "a\xe2\x80"));
}

test "sanitizeMessageText: keeps legit text" {
    const cases = [_][]const u8{
        "hello world",
        "привет\nмир\t",
        "👨‍👩‍👧", // ZWJ sequence
        "a\u{200C}b\u{200D}c\u{200E}d\u{200F}e", // ZWNJ, ZWJ, LRM, RLM
        "a\u{2066}b\u{2067}c\u{2068}d\u{2069}e", // isolates
        "\u{2764}\u{FE0F}", // heart + VS16
        "\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}", // tag sequence (Scotland)
    };

    for (cases) |s| {
        const sanitized = try sanitizeMessageText(std.testing.allocator, s);
        defer std.testing.allocator.free(sanitized);

        try std.testing.expectEqualStrings(s, sanitized);
    }
}

test "sanitizeMessageText: strips forbidden codepoints" {
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "a\u{200B}b", .expected = "ab" },
        .{ .input = "a\u{202E}b\u{200B}c", .expected = "abc" },
        .{ .input = "a\u{2800}b", .expected = "ab" },
        .{ .input = "a\u{E000}b", .expected = "ab" },
        .{ .input = "a\rb", .expected = "ab" }, // CR is forbidden
        .{ .input = "a\u{FEFF}b", .expected = "ab" },
        .{ .input = "a\u{2028}b", .expected = "ab" },
        .{ .input = "a\u{00AD}b", .expected = "ab" },
        .{ .input = "пр\u{200B}ивет", .expected = "привет" },
    };

    for (cases) |case| {
        const sanitized = try sanitizeMessageText(std.testing.allocator, case.input);
        defer std.testing.allocator.free(sanitized);

        try std.testing.expectEqualStrings(case.expected, sanitized);
    }
}

test "sanitizeMessageText: strips multibyte codepoints without breaking neighbors" {
    const sanitized = try sanitizeMessageText(std.testing.allocator, "па\u{202E}ра");
    defer std.testing.allocator.free(sanitized);

    try std.testing.expectEqualStrings("пара", sanitized);
}

test "sanitizeMessageText: strips everything to empty" {
    const sanitized = try sanitizeMessageText(std.testing.allocator, "\u{200B}\u{202E}");
    defer std.testing.allocator.free(sanitized);

    try std.testing.expectEqual(@as(usize, 0), sanitized.len);
}

test "sanitizeMessageText: invalid UTF-8 is an error" {
    try std.testing.expectError(error.InvalidUtf8, sanitizeMessageText(std.testing.allocator, "a\xffb"));
}

test "sanitizeMessageText: applies NFKC before stripping" {
    const sanitized = try sanitizeMessageText(std.testing.allocator, "\u{FF21}\u{FF22}\u{200B}\u{FB01}");
    defer std.testing.allocator.free(sanitized);

    try std.testing.expectEqualStrings("ABfi", sanitized);
}

test "normalize: applies NFKC" {
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "e\u{0301}", .expected = "\u{00E9}" }, // é
        .{ .input = "\u{FB01}", .expected = "fi" }, // ligature
        .{ .input = "\u{FF21}", .expected = "A" }, // fullwidth A
        .{ .input = "\u{00A0}", .expected = " " }, // no-break space
    };

    for (cases) |case| {
        const normalized = try normalize(std.testing.allocator, case.input);
        defer std.testing.allocator.free(normalized);

        try std.testing.expectEqualStrings(case.expected, normalized);
    }
}

test "normalize: invalid UTF-8 is an error" {
    try std.testing.expectError(error.InvalidUtf8, normalize(std.testing.allocator, "a\xffb"));
}

test "isFullyQualifiedEmoji: rejects non-emoji and partial sequences" {
    try std.testing.expect(!isFullyQualifiedEmoji(""));
    try std.testing.expect(!isFullyQualifiedEmoji("a"));
    try std.testing.expect(!isFullyQualifiedEmoji("hello"));
    try std.testing.expect(!isFullyQualifiedEmoji("\u{263A}")); // unqualified
    try std.testing.expect(!isFullyQualifiedEmoji("\u{1F3FB}")); // component
}

test "canonicalReactionEmoji: canonicalizes every qualification form" {
    try std.testing.expectEqualStrings("\u{1F44D}", canonicalReactionEmoji("\u{1F44D}").?);
    try std.testing.expectEqualStrings(
        "\u{2764}\u{FE0F}",
        canonicalReactionEmoji("\u{2764}\u{FE0F}").?,
    );
    // Unqualified and minimally-qualified forms map to the same sequence.
    try std.testing.expectEqualStrings("\u{2764}\u{FE0F}", canonicalReactionEmoji("\u{2764}").?);
    try std.testing.expectEqualStrings(
        "\u{0031}\u{FE0F}\u{20E3}",
        canonicalReactionEmoji("\u{0031}\u{20E3}").?,
    );
    // A lone regional indicator has no RGI form and is kept as-is.
    try std.testing.expectEqualStrings("\u{1F1F5}", canonicalReactionEmoji("\u{1F1F5}").?);

    try std.testing.expect(canonicalReactionEmoji("") == null);
    try std.testing.expect(canonicalReactionEmoji("a") == null);
    try std.testing.expect(canonicalReactionEmoji("\u{1F44D}\u{1F44D}") == null); // concatenation
    try std.testing.expect(canonicalReactionEmoji("\u{1F3FB}") == null); // component
    try std.testing.expect(canonicalReactionEmoji("\u{2764}x") == null);
}

test "isRegionalIndicator: accepts exactly one regional indicator" {
    try std.testing.expect(isRegionalIndicator("\u{1F1E6}")); // A
    try std.testing.expect(isRegionalIndicator("\u{1F1F5}")); // P
    try std.testing.expect(isRegionalIndicator("\u{1F1FF}")); // Z

    try std.testing.expect(!isRegionalIndicator(""));
    try std.testing.expect(!isRegionalIndicator("a"));
    try std.testing.expect(!isRegionalIndicator("\u{1F1E6}\u{1F1F7}")); // AR, a flag
    try std.testing.expect(!isRegionalIndicator("\u{1F1E5}")); // not an indicator
    try std.testing.expect(!isRegionalIndicator("\u{1F3FB}")); // component
}
