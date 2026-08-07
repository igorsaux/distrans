const std = @import("std");

const Entry = struct {
    cp: u21,
    decomposition: []const u21,
    compatibility: bool,
    combining_class: u8,
};

/// Codepoint properties derived from the UCD files and consumed by
/// `src/unicode.zig` for the sanitization profiles.
const Props = packed struct {
    control: bool = false,
    format: bool = false,
    private_use: bool = false,
    line_separator: bool = false,
    default_ignorable: bool = false,
    noncharacter: bool = false,
    bidi_control: bool = false,
};

const Range = struct {
    first: u21,
    last: u21,
};

/// Combines a canonical composition pair into a single lookup key.
fn compositionKey(first: u21, second: u21) u64 {
    return (@as(u64, first) << 21) | @as(u64, second);
}

fn allFalse(p: Props) bool {
    return !p.control and !p.format and !p.private_use and !p.line_separator and
        !p.default_ignorable and !p.noncharacter and !p.bidi_control;
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn setRange(props: []Props, range: Range, comptime field: []const u8) void {
    var cp = range.first;

    while (cp <= range.last) : (cp += 1) {
        @field(props[cp], field) = true;
    }
}

fn parseCodepointRange(token: []const u8) !Range {
    if (std.mem.find(u8, token, "..")) |dots| {
        return .{
            .first = try std.fmt.parseInt(u21, token[0..dots], 16),
            .last = try std.fmt.parseInt(u21, token[dots + 2 ..], 16),
        };
    }

    const cp = try std.fmt.parseInt(u21, token, 16);

    return .{ .first = cp, .last = cp };
}

/// Maps a value of the `General_Category` field to the props it sets.
fn categoryProps(category: []const u8) Props {
    if (std.mem.eql(u8, category, "Cc")) {
        return .{ .control = true };
    }

    if (std.mem.eql(u8, category, "Cf")) {
        return .{ .format = true };
    }

    if (std.mem.eql(u8, category, "Co")) {
        return .{ .private_use = true };
    }

    if (std.mem.eql(u8, category, "Zl") or std.mem.eql(u8, category, "Zp")) {
        return .{ .line_separator = true };
    }

    return .{};
}

/// Collects `code[..code]` ranges whose second field equals `property`.
fn collectPropertyRanges(arena: std.mem.Allocator, data: []const u8, property: []const u8) ![]Range {
    var ranges: std.ArrayList(Range) = .empty;
    defer ranges.deinit(arena);

    var lines = std.mem.splitScalar(u8, data, '\n');

    while (lines.next()) |raw_line| {
        var line = raw_line;

        if (std.mem.findScalar(u8, line, '#')) |hash| {
            line = line[0..hash];
        }

        line = std.mem.trim(u8, line, " \t\r");

        if (line.len == 0) {
            continue;
        }

        var fields = std.mem.splitScalar(u8, line, ';');

        const token = std.mem.trim(u8, fields.next() orelse continue, " \t");
        const name = std.mem.trim(u8, fields.next() orelse continue, " \t");

        if (!std.mem.eql(u8, name, property)) {
            continue;
        }

        try ranges.append(arena, try parseCodepointRange(token));
    }

    return arena.dupe(Range, ranges.items);
}

/// Collects `code[..code]` ranges from a single-column listing (no property).
fn collectCodepointRanges(arena: std.mem.Allocator, data: []const u8) ![]Range {
    var ranges: std.ArrayList(Range) = .empty;
    defer ranges.deinit(arena);

    var lines = std.mem.splitScalar(u8, data, '\n');

    while (lines.next()) |raw_line| {
        var line = raw_line;

        if (std.mem.findScalar(u8, line, '#')) |hash| {
            line = line[0..hash];
        }

        line = std.mem.trim(u8, line, " \t\r");

        if (line.len == 0) {
            continue;
        }

        var token_iter = std.mem.tokenizeAny(u8, line, " \t");
        const token = token_iter.next() orelse continue;

        try ranges.append(arena, try parseCodepointRange(token));
    }

    return arena.dupe(Range, ranges.items);
}

/// Reads a required file relative to `dir`.
fn readData(
    io: std.Io,
    dir: []const u8,
    arena: std.mem.Allocator,
    sub_path: []const u8,
) ![]u8 {
    const cwd = std.Io.Dir.cwd();

    return cwd.readFileAlloc(
        io,
        try std.fs.path.join(arena, &.{ dir, sub_path }),
        arena,
        .unlimited,
    );
}

/// Reads a file relative to `dir`, returning `null` when it does not exist.
fn readOptional(
    io: std.Io,
    dir: []const u8,
    arena: std.mem.Allocator,
    sub_path: []const u8,
) !?[]u8 {
    const cwd = std.Io.Dir.cwd();

    return cwd.readFileAlloc(
        io,
        try std.fs.path.join(arena, &.{ dir, sub_path }),
        arena,
        .unlimited,
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn writePropsArm(writer: *std.Io.Writer, first: u21, last: u21, p: Props) !void {
    if (allFalse(p)) {
        return;
    }

    try writer.writeAll("        0x");
    try writer.print("{X:0>4}", .{first});

    if (last != first) {
        try writer.writeAll("...0x");
        try writer.print("{X:0>4}", .{last});
    }

    try writer.writeAll(" => .{");

    if (p.control) try writer.writeAll(" .control = true,");
    if (p.format) try writer.writeAll(" .format = true,");
    if (p.private_use) try writer.writeAll(" .private_use = true,");
    if (p.line_separator) try writer.writeAll(" .line_separator = true,");
    if (p.default_ignorable) try writer.writeAll(" .default_ignorable = true,");
    if (p.noncharacter) try writer.writeAll(" .noncharacter = true,");
    if (p.bidi_control) try writer.writeAll(" .bidi_control = true,");

    try writer.writeAll(" },\n");
}

/// Decodes a space-separated list of hex codepoints into UTF-8.
fn codepointsToUtf8(buffer: []u8, spec: []const u8) ![]const u8 {
    var o: usize = 0;
    var tokens = std.mem.tokenizeAny(u8, spec, " \t");

    while (tokens.next()) |token| {
        const cp = try std.fmt.parseInt(u21, token, 16);

        o += std.unicode.utf8Encode(cp, buffer[o..]) catch return error.BadData;
    }

    return buffer[0..o];
}

/// Collects unique, sorted UTF-8 encodings of the `fully-qualified` emoji
/// sequences in `emoji-test.txt`.
fn collectEmoji(arena: std.mem.Allocator, data: []const u8) ![][]const u8 {
    var items: std.ArrayList([]const u8) = .empty;
    defer items.deinit(arena);

    var lines = std.mem.splitScalar(u8, data, '\n');

    while (lines.next()) |raw_line| {
        var line = raw_line;

        if (std.mem.findScalar(u8, line, '#')) |hash| {
            line = line[0..hash];
        }

        line = std.mem.trim(u8, line, " \t\r");

        if (line.len == 0) {
            continue;
        }

        var fields = std.mem.splitScalar(u8, line, ';');

        const sequence = std.mem.trim(u8, fields.next() orelse continue, " \t");
        const status = std.mem.trim(u8, fields.next() orelse continue, " \t");

        if (!std.mem.eql(u8, status, "fully-qualified")) {
            continue;
        }

        var buffer: [128]u8 = undefined;
        const utf8 = try codepointsToUtf8(&buffer, sequence);

        try items.append(arena, try arena.dupe(u8, utf8));
    }

    const slice = try arena.dupe([]const u8, items.items);

    std.mem.sort([]const u8, slice, {}, lessThanString);

    var n: usize = 0;

    for (slice) |item| {
        if (n == 0 or !std.mem.eql(u8, slice[n - 1], item)) {
            slice[n] = item;

            n += 1;
        }
    }

    return slice[0..n];
}

const NORMALIZATION_TEST_HEADER =
    \\fn decodeSequence(allocator: std.mem.Allocator, spec: []const u8) ![]u8 {
    \\    var out: std.ArrayList(u8) = .empty;
    \\    errdefer out.deinit(allocator);
    \\
    \\    var tokens = std.mem.tokenizeAny(u8, spec, " \t");
    \\
    \\    while (tokens.next()) |token| {
    \\        const cp = try std.fmt.parseInt(u21, token, 16);
    \\        var buffer: [4]u8 = undefined;
    \\        const n = std.unicode.utf8Encode(cp, &buffer) catch return error.BadTestData;
    \\
    \\        try out.appendSlice(allocator, buffer[0..n]);
    \\    }
    \\
    \\    return out.toOwnedSlice(allocator);
    \\}
    \\
    \\fn expectNfkc(allocator: std.mem.Allocator, expected: []const u8, input: []const u8) !void {
    \\    const out = try unicode.nfkc(allocator, input);
    \\
    \\    try std.testing.expectEqualStrings(expected, out);
    \\}
    \\
;

const NORMALIZATION_TEST_BODY =
    \\test "unicode: nfkc conformance (NormalizationTest.txt)" {
    \\    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    \\    defer arena_state.deinit();
    \\
    \\    const arena = arena_state.allocator();
    \\
    \\    var count: usize = 0;
    \\    var lines = std.mem.splitScalar(u8, NORMALIZATION_TEST_DATA, '\n');
    \\
    \\    while (lines.next()) |raw_line| {
    \\        var line = raw_line;
    \\
    \\        if (std.mem.findScalar(u8, line, '#')) |hash| {
    \\            line = line[0..hash];
    \\        }
    \\
    \\        line = std.mem.trim(u8, line, " \t\r");
    \\
    \\        if (line.len == 0 or line[0] == '@') {
    \\            continue;
    \\        }
    \\
    \\        var fields = std.mem.splitScalar(u8, line, ';');
    \\
    \\        const c1 = std.mem.trim(u8, fields.next() orelse continue, " \t");
    \\        const c2 = std.mem.trim(u8, fields.next() orelse continue, " \t");
    \\        const c3 = std.mem.trim(u8, fields.next() orelse continue, " \t");
    \\        const c4 = std.mem.trim(u8, fields.next() orelse continue, " \t");
    \\        const c5 = std.mem.trim(u8, fields.next() orelse continue, " \t");
    \\
    \\        const s1 = try decodeSequence(arena, c1);
    \\        const s2 = try decodeSequence(arena, c2);
    \\        const s3 = try decodeSequence(arena, c3);
    \\        const s4 = try decodeSequence(arena, c4);
    \\        const s5 = try decodeSequence(arena, c5);
    \\
    \\        try expectNfkc(arena, s4, s1);
    \\        try expectNfkc(arena, s4, s2);
    \\        try expectNfkc(arena, s4, s3);
    \\        try expectNfkc(arena, s4, s4);
    \\        try expectNfkc(arena, s4, s5);
    \\
    \\        count += 1;
    \\    }
    \\
    \\    try std.testing.expect(count > 0);
    \\}
    \\
;

const EMOJI_TEST_BODY =
    \\test "unicode: emoji fully-qualified set" {
    \\    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    \\    defer arena_state.deinit();
    \\
    \\    const arena = arena_state.allocator();
    \\
    \\    var fully_qualified: usize = 0;
    \\    var lines = std.mem.splitScalar(u8, EMOJI_TEST_DATA, '\n');
    \\
    \\    while (lines.next()) |raw_line| {
    \\        var line = raw_line;
    \\
    \\        if (std.mem.findScalar(u8, line, '#')) |hash| {
    \\            line = line[0..hash];
    \\        }
    \\
    \\        line = std.mem.trim(u8, line, " \t\r");
    \\
    \\        if (line.len == 0) {
    \\            continue;
    \\        }
    \\
    \\        var fields = std.mem.splitScalar(u8, line, ';');
    \\
    \\        const sequence = std.mem.trim(u8, fields.next() orelse continue, " \t");
    \\        const status = std.mem.trim(u8, fields.next() orelse continue, " \t");
    \\
    \\        const utf8 = try decodeSequence(arena, sequence);
    \\
    \\        const expected = std.mem.eql(u8, status, "fully-qualified");
    \\
    \\        try std.testing.expectEqual(expected, unicode.isFullyQualifiedEmoji(utf8));
    \\
    \\        if (expected) {
    \\            fully_qualified += 1;
    \\        }
    \\    }
    \\
    \\    try std.testing.expect(fully_qualified > 0);
    \\}
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    if (args.len != 6) {
        std.debug.print("usage: <UNICODE_DIR> <OUT_DATA> <OUT_TESTS> <OUT_NORM_TEST> <OUT_EMOJI_TEST>\n", .{});

        return error.BadArgs;
    }

    const cwd = std.Io.Dir.cwd();

    var data_file = try cwd.createFile(init.io, args[2], .{});
    defer data_file.close(init.io);

    var data_buffer: [4096]u8 = undefined;
    var data_writer = data_file.writer(init.io, &data_buffer);
    defer data_writer.flush() catch @panic("failed to flush");

    var tests_file = try cwd.createFile(init.io, args[3], .{});
    defer tests_file.close(init.io);

    var tests_buffer: [4096]u8 = undefined;
    var tests_writer = tests_file.writer(init.io, &tests_buffer);
    defer tests_writer.flush() catch @panic("failed to flush");

    const unicode_dir = args[1];
    const ucd_dir = try std.fs.path.join(arena, &.{ unicode_dir, "ucd" });

    const unicode_data = try readData(init.io, ucd_dir, arena, "UnicodeData.txt");
    const composition_exclusions_data = try readData(init.io, ucd_dir, arena, "CompositionExclusions.txt");
    const derived_core_properties_data = try readData(init.io, ucd_dir, arena, "DerivedCoreProperties.txt");
    const prop_list_data = try readData(init.io, ucd_dir, arena, "PropList.txt");

    const normalization_test_data = try readOptional(init.io, ucd_dir, arena, "NormalizationTest.txt");
    const emoji_test_data = try readOptional(init.io, unicode_dir, arena, "emoji/emoji-test.txt");

    // Copy the optional conformance suites next to the generated test file so
    // that it can `@embedFile` them by relative name: the generated file lives
    // in the build cache, outside of the source tree and of any embed dir.
    try cwd.writeFile(init.io, .{ .sub_path = args[4], .data = normalization_test_data orelse "" });
    try cwd.writeFile(init.io, .{ .sub_path = args[5], .data = emoji_test_data orelse "" });

    // Canonical combining class of every codepoint; default 0.
    const combining_classes = try arena.alloc(u8, 0x110000);
    @memset(combining_classes, 0);

    // Codepoint properties; filled from UnicodeData and the property files.
    const props = try arena.alloc(Props, 0x110000);
    @memset(props, .{});

    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(init.gpa);

    var range_first: u21 = 0;
    var range_props: Props = .{};
    var in_range = false;

    var iter = std.mem.splitScalar(u8, unicode_data, '\n');

    while (iter.next()) |line| {
        if (line.len == 0) {
            continue;
        }

        var fields = std.mem.splitScalar(u8, line, ';');

        const cp_hex = fields.next() orelse continue;
        const name = fields.next() orelse continue;
        const category = fields.next() orelse continue;
        const ccc_hex = fields.next() orelse continue;

        _ = fields.next();

        const mapping_field = fields.next() orelse "";

        const cp = try std.fmt.parseInt(u21, cp_hex, 16);

        // Range blocks (`<..., First>` / `<..., Last>`) carry the category on
        // the First line and no decomposition or combining class.
        if (std.mem.endsWith(u8, name, ", First>")) {
            in_range = true;
            range_first = cp;
            range_props = categoryProps(category);

            continue;
        }

        if (std.mem.endsWith(u8, name, ", Last>")) {
            var rcp = range_first;

            while (rcp <= cp) : (rcp += 1) {
                props[rcp] = range_props;
            }

            in_range = false;

            continue;
        }

        if (in_range) {
            continue;
        }

        props[cp] = categoryProps(category);

        const ccc = try std.fmt.parseInt(u8, ccc_hex, 10);

        combining_classes[cp] = ccc;

        var decomposition: []const u21 = &.{};
        var compatibility = false;

        if (mapping_field.len != 0) {
            var mapping = mapping_field;

            if (mapping[0] == '<') {
                const end = std.mem.findScalar(u8, mapping, '>') orelse return error.BadData;

                compatibility = true;
                mapping = mapping[end + 1 ..];
            }

            var cps: std.ArrayList(u21) = .empty;
            defer cps.deinit(init.gpa);

            var token_iter = std.mem.tokenizeScalar(u8, mapping, ' ');

            while (token_iter.next()) |token| {
                try cps.append(init.gpa, try std.fmt.parseInt(u21, token, 16));
            }

            decomposition = try arena.dupe(u21, cps.items);
        }

        if (decomposition.len == 0 and ccc == 0) {
            continue;
        }

        try entries.append(init.gpa, .{
            .cp = cp,
            .decomposition = decomposition,
            .compatibility = compatibility,
            .combining_class = ccc,
        });
    }

    for (try collectPropertyRanges(arena, derived_core_properties_data, "Default_Ignorable_Code_Point")) |range| {
        setRange(props, range, "default_ignorable");
    }

    for (try collectPropertyRanges(arena, prop_list_data, "Noncharacter_Code_Point")) |range| {
        setRange(props, range, "noncharacter");
    }

    for (try collectPropertyRanges(arena, prop_list_data, "Bidi_Control")) |range| {
        setRange(props, range, "bidi_control");
    }

    // Characters that must not be produced by canonical composition, even
    // though UnicodeData.txt lists a canonical decomposition for them
    // (script-specific and post-composition-version exclusions). Singleton and
    // non-starter decompositions are already filtered below.
    const excluded = try arena.alloc(bool, 0x110000);
    @memset(excluded, false);

    for (try collectCodepointRanges(arena, composition_exclusions_data)) |range| {
        var cp = range.first;

        while (cp <= range.last) : (cp += 1) {
            excluded[cp] = true;
        }
    }

    // Canonical composition pairs. A pair composes only if its first codepoint
    // is a starter (combining class 0), the pair is not a compatibility
    // decomposition, and the result is not a composition exclusion.
    var compositions: std.AutoHashMap(u64, u21) = .init(init.gpa);
    defer compositions.deinit();

    for (entries.items) |entry| {
        if (entry.compatibility) {
            continue;
        }

        if (excluded[entry.cp]) {
            continue;
        }

        if (entry.decomposition.len != 2) {
            continue;
        }

        const first = entry.decomposition[0];
        const second = entry.decomposition[1];

        if (combining_classes[first] != 0) {
            continue;
        }

        const gop = try compositions.getOrPut(compositionKey(first, second));

        if (!gop.found_existing) {
            gop.value_ptr.* = entry.cp;
        }
    }

    const composition_keys = try arena.alloc(u64, compositions.count());

    var key_len: usize = 0;
    var key_iter = compositions.keyIterator();

    while (key_iter.next()) |key| {
        composition_keys[key_len] = key.*;

        key_len += 1;
    }

    std.mem.sort(u64, composition_keys, {}, std.sort.asc(u64));

    // ------------------------------------------------------------------
    // Data file.
    // ------------------------------------------------------------------

    try data_writer.interface.writeAll(
        \\const std = @import("std");
        \\
        \\pub const DataEntry = struct {
        \\    decomposition: []const u21 = &.{},
        \\    compatibility: bool = false,
        \\    combining_class: u8 = 0,
        \\};
        \\
        \\pub const DATA: std.StaticStringMap(DataEntry) = .initComptime(.{
        \\
    );

    for (entries.items) |entry| {
        var cp_buffer: [8]u8 = undefined;
        const cp_key = try std.fmt.bufPrint(&cp_buffer, "{X:0>4}", .{entry.cp});

        try data_writer.interface.print("    .{{ \"{s}\", DataEntry{{", .{cp_key});

        if (entry.decomposition.len != 0) {
            try data_writer.interface.writeAll(" .decomposition = &.{ ");

            for (entry.decomposition) |cp| {
                try data_writer.interface.print("0x{X:0>4}, ", .{cp});
            }

            try data_writer.interface.writeAll("},");
        }

        if (entry.compatibility) {
            try data_writer.interface.writeAll(" .compatibility = true,");
        }

        if (entry.combining_class != 0) {
            try data_writer.interface.print(" .combining_class = {d},", .{entry.combining_class});
        }

        try data_writer.interface.writeAll(" } },\n");
    }

    try data_writer.interface.writeAll("});\n\n");

    try data_writer.interface.writeAll(
        \\pub const COMPOSITION: std.StaticStringMap(u21) = .initComptime(.{
        \\
    );

    for (composition_keys) |key| {
        const first: u21 = @intCast(key >> 21);
        const second: u21 = @intCast(key & 0x1FFFFF);
        const composed = compositions.get(key).?;

        var key_buffer: [16]u8 = undefined;
        const pair_key = try std.fmt.bufPrint(&key_buffer, "{X:0>6}{X:0>6}", .{ first, second });

        try data_writer.interface.print("    .{{ \"{s}\", 0x{X} }},\n", .{ pair_key, composed });
    }

    try data_writer.interface.writeAll("});\n\n");

    try data_writer.interface.writeAll(
        \\/// Properties of a codepoint that matter for the sanitization profiles:
        \\/// regex-free categorization derived from the UCD (`General_Category`,
        \\/// `Default_Ignorable_Code_Point`, `Noncharacter_Code_Point`,
        \\/// `Bidi_Control`).
        \\pub const CodePointProps = packed struct {
        \\    /// General_Category = Cc.
        \\    control: bool = false,
        \\    /// General_Category = Cf.
        \\    format: bool = false,
        \\    /// General_Category = Co.
        \\    private_use: bool = false,
        \\    /// General_Category = Zl or Zp.
        \\    line_separator: bool = false,
        \\    /// Default_Ignorable_Code_Point.
        \\    default_ignorable: bool = false,
        \\    /// Noncharacter_Code_Point.
        \\    noncharacter: bool = false,
        \\    /// Bidi_Control.
        \\    bidi_control: bool = false,
        \\};
        \\
        \\pub inline fn props(cp: u21) CodePointProps {
        \\    return switch (cp) {
        \\
    );

    {
        var start: u21 = 0;
        var cp: u21 = 1;

        while (cp <= 0x10FFFF) : (cp += 1) {
            if (!std.meta.eql(props[cp], props[start])) {
                try writePropsArm(&data_writer.interface, start, cp - 1, props[start]);

                start = cp;
            }
        }

        try writePropsArm(&data_writer.interface, start, 0x10FFFF, props[start]);
    }

    try data_writer.interface.writeAll("        else => .{},\n    };\n}\n\n");

    try data_writer.interface.writeAll(
        \\pub const EMOJI_FULLY_QUALIFIED: std.StaticStringMap(void) = .initComptime(.{
        \\
    );

    if (emoji_test_data) |data| {
        for (try collectEmoji(arena, data)) |item| {
            try data_writer.interface.writeAll("    .{ \"");

            for (item) |byte| {
                try data_writer.interface.print("\\x{X:0>2}", .{byte});
            }

            try data_writer.interface.writeAll("\", {} },\n");
        }
    }

    try data_writer.interface.writeAll("});\n");

    // ------------------------------------------------------------------
    // Test file.
    // ------------------------------------------------------------------

    try tests_writer.interface.writeAll(
        \\// Generated by tools/gen-unicode.zig. Do not edit.
        \\
        \\const std = @import("std");
        \\const unicode = @import("unicode");
        \\
        \\
    );

    if (normalization_test_data == null and emoji_test_data == null) {
        try tests_writer.interface.writeAll(
            \\test "unicode: external conformance data is not available" {
            \\    return error.SkipZigTest;
            \\}
            \\
        );

        return;
    }

    try tests_writer.interface.writeAll(NORMALIZATION_TEST_HEADER);

    if (normalization_test_data != null) {
        try tests_writer.interface.writeAll("const NORMALIZATION_TEST_DATA = @embedFile(\"NormalizationTest.txt\");\n\n");
        try tests_writer.interface.writeAll(NORMALIZATION_TEST_BODY);
    }

    if (emoji_test_data != null) {
        try tests_writer.interface.writeAll("const EMOJI_TEST_DATA = @embedFile(\"emoji-test.txt\");\n\n");
        try tests_writer.interface.writeAll(EMOJI_TEST_BODY);
    }
}
