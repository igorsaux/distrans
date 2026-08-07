// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("root.zig");

/// Returns a slice of the next bytes of buffered data from the stream until
/// `delimiter` is found, advancing the seek position pastn the delimiter.
///
/// Returned slice excludes the delimiter.
pub inline fn readerTakeDelimiterScalar(this: *std.Io.Reader, scalar: u8) ?[]const u8 {
    const result = this.peekDelimiterInclusive(scalar) catch {
        return null;
    };

    this.toss(result.len);

    return result[0 .. result.len - 1];
}

/// Returns a slice of the next bytes of buffered data from the stream until
/// `delimiter` is found, advancing the seek position pastn the delimiter.
///
/// Returned slice excludes the delimiter.
pub inline fn readerTakeDelimiter(this: *std.Io.Reader, delimiter: []const u8) ?[]const u8 {
    std.debug.assert(delimiter.len > 0);

    var n: usize = 0;

    const result = this.peekDelimiterInclusive(delimiter[0]) catch {
        return null;
    };

    n += result.len;

    for (delimiter[1..], 1..) |scalar, i| {
        const bytes = this.peek(result.len + i) catch {
            return null;
        };

        if (bytes[bytes.len - 1] != scalar) {
            return null;
        }
    }

    n += delimiter.len - 1;
    this.toss(n);

    return result[0 .. result.len - 1];
}

pub inline fn eqlMaybe(comptime T: type, a: ?[]const T, b: []const T) bool {
    if (a == null) {
        return false;
    }

    return std.mem.eql(T, a.?, b);
}

pub inline fn startsWithMaybe(comptime T: type, haystak: ?[]const T, needle: []const T) bool {
    if (haystak == null) {
        return false;
    }

    return std.mem.startsWith(T, haystak.?, needle);
}

/// Compares a declared Content-Type against a candidate MIME type, ignoring any
/// `;`-separated parameters and surrounding whitespace. The comparison is
/// ASCII-case-insensitive. A null `declared` never matches.
pub inline fn matchMimeType(declared: ?[]const u8, candidate: []const u8) bool {
    const value = declared orelse return false;

    const trimmed = std.mem.trim(u8, std.mem.sliceTo(value, ';'), " \t");

    return std.ascii.eqlIgnoreCase(trimmed, candidate);
}

/// Compares a declared Content-Type against a whitelist pattern, ignoring any
/// `;`-separated parameters and surrounding whitespace (ASCII-case-insensitive).
/// A pattern of the form `<type>/*` (e.g. `text/*`) matches any declared type
/// with that type part; any other pattern is matched exactly. `*/*` is not
/// special and matches nothing. A null `declared` never matches.
pub inline fn mimePatternMatches(declared: ?[]const u8, pattern: []const u8) bool {
    if (std.mem.endsWith(u8, pattern, "/*") and pattern.len > 2) {
        const value = declared orelse return false;

        const trimmed = std.mem.trim(u8, std.mem.sliceTo(value, ';'), " \t");
        const slash = std.mem.findScalar(u8, trimmed, '/') orelse return false;

        return std.ascii.eqlIgnoreCase(trimmed[0..slash], pattern[0 .. pattern.len - 2]);
    }

    return matchMimeType(declared, pattern);
}

/// `null` whitelist = allow every type; empty = allow none; otherwise the
/// declared Content-Type must match one of the listed patterns (an exact type
/// or a `<type>/*` wildcard; see `mimePatternMatches`).
pub inline fn mimeAllowed(whitelist: ?[]const []const u8, declared: ?[]const u8) bool {
    const list = whitelist orelse return true;

    for (list) |candidate| {
        if (mimePatternMatches(declared, candidate)) {
            return true;
        }
    }

    return false;
}

/// Builds the `filename`/`filename*` parameters of a `Content-Disposition`
/// header for `name` (RFC 6266 + RFC 5987), e.g.
/// `filename="report.txt"; filename*=UTF-8''%D0%BE%D1%82%D1%87%D1%91%D1%82.txt`.
///
/// - `filename` is an ASCII fallback: the bytes that are valid `token`/`quoted`
///   characters (printable ASCII except `"`, `\`, `/`) are kept, everything else
///   (including every non-ASCII codepoint) becomes `_`; an empty fallback
///   becomes `download`.
/// - `filename*` is the exact name, UTF-8 percent-encoded with only the RFC 5987
///   `attr-char` set left literal, so non-ASCII (e.g. Cyrillic) names survive.
/// - `\r`/`\n` and all C0/C1 controls are dropped from both forms (header
///   injection defense); `name` must be valid UTF-8.
///
/// The result is owned by `allocator`.
pub inline fn fileNameDisposition(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "filename=\"");
    try appendAsciiFileNameFallback(allocator, &out, name);
    try out.appendSlice(allocator, "\"; filename*=UTF-8''");
    try appendRfc5987Encoded(allocator, &out, name);

    return out.toOwnedSlice(allocator);
}

/// A byte that may appear literally in an RFC 5987 `attr-char`
/// (`ALPHA / DIGIT / ! # $ & + - . ^ _ ` | ~`).
inline fn isRfc5987AttrChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '!', '#', '$', '&', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

/// A byte that may appear literally in the ASCII `filename` parameter: printable
/// ASCII minus `"`, `\` and `/`.
inline fn isAsciiFileNameFallbackByte(c: u8) bool {
    return c >= 0x20 and c <= 0x7E and c != '"' and c != '\\' and c != '/';
}

inline fn appendAsciiFileNameFallback(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
) !void {
    const start = out.items.len;

    var i: usize = 0;
    while (i < name.len) {
        const n = std.unicode.utf8ByteSequenceLength(name[i]) catch unreachable;

        if (n == 1) {
            // ASCII: drop CR/LF/controls implicitly (they are outside the range).
            try out.append(allocator, if (isAsciiFileNameFallbackByte(name[i])) name[i] else '_');
        } else {
            // A whole non-ASCII codepoint maps to a single `_`.
            try out.append(allocator, '_');
        }

        i += n;
    }

    if (out.items.len == start) {
        try out.appendSlice(allocator, "download");
    }
}

inline fn appendRfc5987Encoded(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
) !void {
    const hex = "0123456789ABCDEF";

    for (name) |c| {
        if (c == '\r' or c == '\n' or c < 0x20 or c == 0x7F) {
            // Drop CR/LF and controls (they are not attr-char either).
            continue;
        }

        if (isRfc5987AttrChar(c)) {
            try out.append(allocator, c);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex[c >> 4]);
            try out.append(allocator, hex[c & 0x0F]);
        }
    }
}

pub inline fn intToArray(comptime T: type, value: T, endian: std.builtin.Endian) [@sizeOf(T)]u8 {
    var array: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, array[0..@sizeOf(T)], value, endian);

    return array;
}

pub inline fn packedStructToArray(comptime T: type, value: T, endian: std.builtin.Endian) [@sizeOf(T)]u8 {
    const info = @typeInfo(T);

    if (info.@"struct".backing_integer == null) {
        @compileError("Not a packed struct");
    }

    const Int = info.@"struct".backing_integer.?;

    var array: [@sizeOf(Int)]u8 = undefined;
    std.mem.writeInt(Int, &array, @bitCast(value), endian);

    return array;
}

pub inline fn parsePackedStruct(comptime T: type, buf: []const u8, base: u8) !T {
    const info = @typeInfo(T);

    if (info.@"struct".backing_integer == null) {
        @compileError("Not a packed struct");
    }

    const Int = info.@"struct".backing_integer.?;

    const value = try std.fmt.parseInt(Int, buf, base);

    return @bitCast(value);
}

/// Allowlist-based username format check: `a-z`, `0-9`, `.`, `_` only;
/// the first and the last characters must be alphanumeric; `..` is forbidden.
pub inline fn isAsciiUsernameFormat(s: []const u8) bool {
    if (s.len == 0) {
        return false;
    }

    for (s) |c| {
        if (!isAsciiUsernameChar(c)) {
            return false;
        }
    }

    if (!isAsciiUsernameAlnum(s[0]) or !isAsciiUsernameAlnum(s[s.len - 1])) {
        return false;
    }

    var prev: u8 = 0;

    for (s) |c| {
        if (c == '.' and prev == '.') {
            return false;
        }

        prev = c;
    }

    return true;
}

inline fn isAsciiUsernameChar(c: u8) bool {
    return isAsciiUsernameAlnum(c) or c == '.' or c == '_';
}

inline fn isAsciiUsernameAlnum(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9');
}

/// Allowlist-based custom emoji name check: `a-z`, `0-9`, `_` only. Unlike
/// usernames there are no positional rules (the length bounds are enforced
/// against `api.emojis.*_name_codepoints` by the route handler).
pub inline fn isAsciiEmojiNameFormat(s: []const u8) bool {
    if (s.len == 0) {
        return false;
    }

    for (s) |c| {
        if (!isAsciiEmojiNameChar(c)) {
            return false;
        }
    }

    return true;
}

inline fn isAsciiEmojiNameChar(c: u8) bool {
    return isAsciiUsernameAlnum(c) or c == '_';
}

/// Usernames that must not be registered.
pub const RESERVED_USERNAMES = [_][]const u8{
    "admin",
    "moderator",
    "support",
    "system",
    "everyone",
    "here",
    "me",
    "null",
    "all",
    "staff",
};

pub inline fn isReservedUsername(s: []const u8) bool {
    for (RESERVED_USERNAMES) |reserved| {
        if (std.mem.eql(u8, s, reserved)) {
            return true;
        }
    }

    return false;
}

pub inline fn enumFromString(comptime T: type, input: []const u8) ?T {
    const info = @typeInfo(T);

    if (info != .@"enum") {
        @compileError("Not an enum");
    }

    inline for (info.@"enum".fields) |field| {
        if (std.mem.eql(u8, field.name, input)) {
            return @enumFromInt(field.value);
        }
    }

    return null;
}

test "matchMimeType: parameters, case, whitespace, null" {
    try std.testing.expect(matchMimeType("image/webp", "image/webp"));
    try std.testing.expect(matchMimeType("IMAGE/WEBP", "image/webp"));
    try std.testing.expect(matchMimeType("  image/webp  ", "image/webp"));
    try std.testing.expect(matchMimeType("image/webp; charset=binary", "image/webp"));
    try std.testing.expect(matchMimeType("text/plain;charset=utf-8", "text/plain"));
    try std.testing.expect(!matchMimeType("image/png", "image/webp"));
    try std.testing.expect(!matchMimeType("image/webpx", "image/webp"));
    try std.testing.expect(!matchMimeType(null, "image/webp"));
}

test "mimeAllowed: null, empty, list" {
    const whitelist = [_][]const u8{ "image/webp", "text/plain" };

    try std.testing.expect(mimeAllowed(null, "application/json"));
    try std.testing.expect(mimeAllowed(null, null));

    try std.testing.expect(!mimeAllowed(&.{}, "image/webp"));
    try std.testing.expect(!mimeAllowed(&.{}, null));

    try std.testing.expect(mimeAllowed(&whitelist, "image/webp"));
    try std.testing.expect(mimeAllowed(&whitelist, "TEXT/PLAIN; charset=utf-8"));
    try std.testing.expect(!mimeAllowed(&whitelist, "application/json"));
    try std.testing.expect(!mimeAllowed(&whitelist, null));
}

test "mimePatternMatches: type/* wildcard" {
    try std.testing.expect(mimePatternMatches("text/plain; charset=utf-8", "text/*"));
    try std.testing.expect(mimePatternMatches("TEXT/CSV", "text/*"));
    try std.testing.expect(mimePatternMatches("text/markdown", "text/*"));
    try std.testing.expect(!mimePatternMatches("application/json", "text/*"));
    try std.testing.expect(!mimePatternMatches("text", "text/*"));
    try std.testing.expect(!mimePatternMatches(null, "text/*"));

    try std.testing.expect(mimePatternMatches("image/avif", "image/*"));
    try std.testing.expect(!mimePatternMatches("text/plain", "image/*"));

    // `*/*` is not special: it matches nothing (use a null whitelist instead).
    try std.testing.expect(!mimePatternMatches("text/plain", "*/*"));

    // Exact patterns keep the previous behavior.
    try std.testing.expect(mimePatternMatches("image/webp", "image/webp"));
    try std.testing.expect(!mimePatternMatches("image/png", "image/webp"));
}

test "fileNameDisposition: ascii" {
    const out = try fileNameDisposition(std.testing.allocator, "report.txt");
    defer std.testing.allocator.free(out);

    try std.testing.expectEqualStrings(
        "filename=\"report.txt\"; filename*=UTF-8''report.txt",
        out,
    );
}

test "fileNameDisposition: non-ascii fallback and percent-encoding" {
    // "отчёт.txt"
    const out = try fileNameDisposition(std.testing.allocator, "отчёт.txt");
    defer std.testing.allocator.free(out);

    try std.testing.expectEqualStrings(
        "filename=\"_____.txt\"; filename*=UTF-8''%D0%BE%D1%82%D1%87%D1%91%D1%82.txt",
        out,
    );
}

test "fileNameDisposition: quotes, slash and controls sanitized" {
    const out = try fileNameDisposition(std.testing.allocator, "a\"b\\c/d\re\nf");
    defer std.testing.allocator.free(out);

    // Fallback maps `"`, `\`, `/` and controls to `_` -> `a_b_c_d_e_f`.
    // filename* percent-encodes `"` (`%22`), `\` (`%5C`) and `/` (`%2F`), drops CR/LF.
    try std.testing.expectEqualStrings(
        "filename=\"a_b_c_d_e_f\"; filename*=UTF-8''a%22b%5Cc%2Fdef",
        out,
    );
}

test "fileNameDisposition: empty name falls back to 'download'" {
    const out = try fileNameDisposition(std.testing.allocator, "");
    defer std.testing.allocator.free(out);

    try std.testing.expectEqualStrings(
        "filename=\"download\"; filename*=UTF-8''",
        out,
    );
}

test "fileNameDisposition: non-ascii fallback is all underscores" {
    // "яя" -> "__" (each non-ASCII codepoint maps to one `_`), name preserved in filename*.
    const out = try fileNameDisposition(std.testing.allocator, "яя");
    defer std.testing.allocator.free(out);

    try std.testing.expectEqualStrings(
        "filename=\"__\"; filename*=UTF-8''%D1%8F%D1%8F",
        out,
    );
}

test "fileNameDisposition: rfc5987 attr-chars stay literal" {
    const out = try fileNameDisposition(std.testing.allocator, "a b#c&d+e.f^g_h`i|j~k");
    defer std.testing.allocator.free(out);

    try std.testing.expectEqualStrings(
        "filename=\"a b#c&d+e.f^g_h`i|j~k\"; filename*=UTF-8''a%20b#c&d+e.f^g_h`i|j~k",
        out,
    );
}

test "isAsciiEmojiNameFormat: allowlist" {
    const accepted = [_][]const u8{ "a", "ab", "party_parrot", "a_b_c", "_x_", "1_2", "x1" };
    const rejected = [_][]const u8{ "", "A", "Ünïcode", "a.b", "a-b", "a b", "a/b", "a😀" };

    for (accepted) |s| {
        try std.testing.expect(isAsciiEmojiNameFormat(s));
    }

    for (rejected) |s| {
        try std.testing.expect(!isAsciiEmojiNameFormat(s));
    }
}

/// Shared embed text-field validator. `value` must be a JSON string; it is
/// sanitized with the message-text profile and counted towards the embed's
/// total codepoint budget (`total_codepoints`) before the per-field `limit`.
///
/// `label` is the comptime field descriptor used in the error messages, e.g.
/// `"'title'"` or `"'name' of an author"`. Returns the sanitized slice, or
/// `null` after having written a 400 response.
fn parseEmbedTextField(
    response: *root.http.Response,
    value: std.json.Value,
    comptime label: []const u8,
    limit: usize,
    total_codepoints: *usize,
) !?[]const u8 {
    if (value != .string) {
        _ = root.route.generic.responseErrorMessage(
            response,
            .bad_request,
            "Bad embed: field " ++ label ++ " is not a string",
        );

        return null;
    }

    const sanitized = root.unicode.sanitizeMessageText(response.allocator, value.string) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            _ = root.route.generic.responseErrorMessage(
                response,
                .bad_request,
                "Bad embed: field " ++ label ++ " is invalid",
            );

            return null;
        },
    };

    const len = std.unicode.utf8CountCodepoints(sanitized) catch unreachable;

    total_codepoints.* += len;

    if (total_codepoints.* > root.options.api.embeds.max_total_codepoints) {
        _ = root.route.generic.responseErrorMessage(response, .bad_request, "Bad embed: content is too long");

        return null;
    }

    if (len > limit) {
        _ = root.route.generic.responseErrorMessage(
            response,
            .bad_request,
            "Bad embed: field " ++ label ++ " is too long",
        );

        return null;
    }

    return sanitized;
}

/// Shared embed URL-field validator. `value` must be a JSON string; URLs do
/// not count towards the embed's text codepoint budget. Returns the sanitized
/// slice, or `null` after having written a 400 response.
fn parseEmbedUrlField(
    response: *root.http.Response,
    value: std.json.Value,
    comptime label: []const u8,
) !?[]const u8 {
    if (value != .string) {
        _ = root.route.generic.responseErrorMessage(
            response,
            .bad_request,
            "Bad embed: field " ++ label ++ " is not a string",
        );

        return null;
    }

    const sanitized = root.unicode.sanitizeMessageText(response.allocator, value.string) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            _ = root.route.generic.responseErrorMessage(
                response,
                .bad_request,
                "Bad embed: field " ++ label ++ " is invalid",
            );

            return null;
        },
    };

    if (std.unicode.utf8CountCodepoints(sanitized) catch unreachable > root.options.api.embeds.max_url_codepoints) {
        _ = root.route.generic.responseErrorMessage(
            response,
            .bad_request,
            "Bad embed: field " ++ label ++ " is too long",
        );

        return null;
    }

    return sanitized;
}

/// Parses and validates one rich embed. Validation is strict: when a
/// sub-object is present its required fields must be present as well. Returns
/// `null` after having written a 400 response, so callers must treat `null` as
/// "error already handled".
pub inline fn parseEmbed(response: *root.http.Response, root_value: std.json.Value) !?root.types.Embed {
    if (root_value != .object) {
        _ = root.route.generic.responseErrorMessage(response, .bad_request, "Bad embed: is not an object");

        return null;
    }

    var embed: root.types.Embed = .{};

    // `type` is optional and defaults to `rich`; any other value is rejected.
    if (root_value.object.get("type")) |type_value| {
        if (type_value != .string or !std.mem.eql(u8, type_value.string, "rich")) {
            _ = root.route.generic.responseErrorMessage(response, .bad_request, "Bad embed: unknown 'type' value");

            return null;
        }
    }

    // Excluding the URLs.
    var total_codepoints: usize = 0;

    if (root_value.object.get("title")) |title_value| {
        if (title_value != .null) {
            embed.title = try parseEmbedTextField(
                response,
                title_value,
                "'title'",
                root.options.api.embeds.max_title_codepoints,
                &total_codepoints,
            ) orelse return null;
        }
    }

    if (root_value.object.get("description")) |description_value| {
        if (description_value != .null) {
            embed.description = try parseEmbedTextField(
                response,
                description_value,
                "'description'",
                root.options.api.embeds.max_description_codepoints,
                &total_codepoints,
            ) orelse return null;
        }
    }

    if (root_value.object.get("url")) |url_value| {
        if (url_value != .null) {
            embed.url = try parseEmbedUrlField(response, url_value, "'url'") orelse return null;
        }
    }

    if (root_value.object.get("timestamp")) |timestamp_value| {
        if (timestamp_value != .integer and timestamp_value != .null) {
            _ = root.route.generic.responseErrorMessage(response, .bad_request, "Bad embed: field 'timestamp' is not an integer");

            return null;
        }

        if (timestamp_value == .integer) {
            if (timestamp_value.integer < 0) {
                _ = root.route.generic.responseErrorMessage(response, .bad_request, "Bad embed: field 'timestamp' is invalid");

                return null;
            }

            embed.timestamp = @intCast(timestamp_value.integer);
        }
    }

    if (root_value.object.get("color")) |color_value| {
        if (color_value != .integer and color_value != .null) {
            _ = root.route.generic.responseErrorMessage(response, .bad_request, "Bad embed: field 'color' is not an integer");

            return null;
        }

        if (color_value == .integer) {
            if (color_value.integer < 0 or color_value.integer > std.math.maxInt(root.types.Color)) {
                _ = root.route.generic.responseErrorMessage(response, .bad_request, "Bad embed: field 'color' is invalid");

                return null;
            }

            embed.color = @intCast(color_value.integer);
        }
    }

    if (root_value.object.get("footer")) |footer_value| {
        if (footer_value != .object and footer_value != .null) {
            _ = root.route.generic.responseErrorMessage(response, .bad_request, "Bad embed: field 'footer' is not an object");

            return null;
        }

        if (footer_value == .object) {
            var footer: root.types.Embed.Footer = .{};

            const text_value = footer_value.object.get("text") orelse {
                _ = root.route.generic.responseErrorMessage(response, .bad_request, "Bad embed: field 'footer' is missing 'text'");

                return null;
            };

            footer.text = try parseEmbedTextField(
                response,
                text_value,
                "'text' of a footer",
                root.options.api.embeds.max_footer_codepoints,
                &total_codepoints,
            ) orelse return null;

            if (footer_value.object.get("icon_url")) |icon_url_value| {
                if (icon_url_value != .null) {
                    footer.icon_url = try parseEmbedUrlField(response, icon_url_value, "'icon_url' of a footer") orelse return null;
                }
            }

            embed.footer = footer;
        }
    }

    if (root_value.object.get("image")) |image_value| {
        if (image_value != .object and image_value != .null) {
            _ = root.route.generic.responseErrorMessage(response, .bad_request, "Bad embed: field 'image' is not an object");

            return null;
        }

        if (image_value == .object) {
            const url_value = image_value.object.get("url") orelse {
                _ = root.route.generic.responseErrorMessage(response, .bad_request, "Bad embed: field 'image' is missing 'url'");

                return null;
            };

            embed.image = .{
                .url = try parseEmbedUrlField(response, url_value, "'url' of an image") orelse return null,
            };
        }
    }

    if (root_value.object.get("thumbnail")) |thumbnail_value| {
        if (thumbnail_value != .object and thumbnail_value != .null) {
            _ = root.route.generic.responseErrorMessage(response, .bad_request, "Bad embed: field 'thumbnail' is not an object");

            return null;
        }

        if (thumbnail_value == .object) {
            const url_value = thumbnail_value.object.get("url") orelse {
                _ = root.route.generic.responseErrorMessage(response, .bad_request, "Bad embed: field 'thumbnail' is missing 'url'");

                return null;
            };

            embed.thumbnail = .{
                .url = try parseEmbedUrlField(response, url_value, "'url' of a thumbnail") orelse return null,
            };
        }
    }

    if (root_value.object.get("video")) |video_value| {
        if (video_value != .object and video_value != .null) {
            _ = root.route.generic.responseErrorMessage(response, .bad_request, "Bad embed: field 'video' is not an object");

            return null;
        }

        if (video_value == .object) {
            const url_value = video_value.object.get("url") orelse {
                _ = root.route.generic.responseErrorMessage(response, .bad_request, "Bad embed: field 'video' is missing 'url'");

                return null;
            };

            embed.video = .{
                .url = try parseEmbedUrlField(response, url_value, "'url' of a video") orelse return null,
            };
        }
    }

    if (root_value.object.get("author")) |author_value| {
        if (author_value != .object and author_value != .null) {
            _ = root.route.generic.responseErrorMessage(response, .bad_request, "Bad embed: field 'author' is not an object");

            return null;
        }

        if (author_value == .object) {
            var author: root.types.Embed.Author = .{};

            const name_value = author_value.object.get("name") orelse {
                _ = root.route.generic.responseErrorMessage(response, .bad_request, "Bad embed: field 'author' is missing 'name'");

                return null;
            };

            author.name = try parseEmbedTextField(
                response,
                name_value,
                "'name' of an author",
                root.options.api.embeds.max_author_name_codepoints,
                &total_codepoints,
            ) orelse return null;

            if (author_value.object.get("url")) |url_value| {
                if (url_value != .null) {
                    author.url = try parseEmbedUrlField(response, url_value, "'url' of an author") orelse return null;
                }
            }

            if (author_value.object.get("icon_url")) |icon_url_value| {
                if (icon_url_value != .null) {
                    author.icon_url = try parseEmbedUrlField(response, icon_url_value, "'icon_url' of an author") orelse return null;
                }
            }

            embed.author = author;
        }
    }

    if (root_value.object.get("fields")) |fields_value| {
        if (fields_value != .array and fields_value != .null) {
            _ = root.route.generic.responseErrorMessage(response, .bad_request, "Bad embed: field 'fields' is not an array");

            return null;
        }

        if (fields_value == .array) {
            if (fields_value.array.items.len > root.options.api.embeds.max_fields) {
                _ = root.route.generic.responseErrorMessage(response, .bad_request, "Bad embed: too many fields");

                return null;
            }

            var fields: std.ArrayList(root.types.Embed.Field) = .empty;
            try fields.ensureTotalCapacityPrecise(response.allocator, fields_value.array.items.len);

            for (fields_value.array.items) |field_value| {
                // null in an array is meaningless
                if (field_value != .object) {
                    _ = root.route.generic.responseErrorMessage(response, .bad_request, "Bad embed: field is not an object");

                    return null;
                }

                var field: root.types.Embed.Field = .{};

                const name_value = field_value.object.get("name") orelse {
                    _ = root.route.generic.responseErrorMessage(response, .bad_request, "Bad embed: field is missing 'name'");

                    return null;
                };

                field.name = try parseEmbedTextField(
                    response,
                    name_value,
                    "'name' of a field",
                    root.options.api.embeds.max_field_name_codepoints,
                    &total_codepoints,
                ) orelse return null;

                const value_value = field_value.object.get("value") orelse {
                    _ = root.route.generic.responseErrorMessage(response, .bad_request, "Bad embed: field is missing 'value'");

                    return null;
                };

                field.value = try parseEmbedTextField(
                    response,
                    value_value,
                    "'value' of a field",
                    root.options.api.embeds.max_field_value_codepoints,
                    &total_codepoints,
                ) orelse return null;

                if (field_value.object.get("inline")) |inline_value| {
                    if (inline_value != .bool) {
                        _ = root.route.generic.responseErrorMessage(response, .bad_request, "Bad embed: field 'inline' of a field is not a bool");

                        return null;
                    }

                    field.@"inline" = inline_value.bool;
                }

                fields.appendAssumeCapacity(field);
            }

            embed.fields = try fields.toOwnedSlice(response.allocator);
        }
    }

    return embed;
}

pub inline fn parseEmbeds(response: *root.http.Response, root_value: std.json.Value) !?std.ArrayList(root.types.Embed) {
    if (root_value != .array) {
        _ = root.route.generic.responseErrorMessage(response, .bad_request, "'embeds' is not an array");

        return null;
    }

    if (root_value.array.items.len > root.options.api.messages.max_embeds) {
        _ = root.route.generic.responseErrorMessage(response, .bad_request, "'embeds' is too large");

        return null;
    }

    var embeds: std.ArrayList(root.types.Embed) = .empty;
    try embeds.ensureTotalCapacityPrecise(response.allocator, root_value.array.items.len);

    for (root_value.array.items) |embed_value| {
        const embed = try parseEmbed(response, embed_value) orelse {
            return null;
        };

        embeds.appendAssumeCapacity(embed);
    }

    return embeds;
}

/// Serializes validated embeds to the compact JSON stored in the DB and
/// returned to clients.
pub inline fn serializeEmbeds(allocator: std.mem.Allocator, embeds: []const root.types.Embed) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);

    std.json.fmt(embeds, .{}).format(&writer.writer) catch |err| {
        return err;
    };

    return writer.written();
}

/// A parsed mention set: who a message body mentions, in first-appearance
/// order, deduplicated. `everyone` collapses `@everyone` and `@here` into one
/// flag (matching the single `app.messages.mention_everyone` column).
pub const Mentions = struct {
    everyone: bool = false,
    user_ids: std.ArrayList(root.types.UserId) = .empty,
    role_ids: std.ArrayList(root.types.RoleId) = .empty,

    pub fn deinit(this: *Mentions, allocator: std.mem.Allocator) void {
        this.user_ids.deinit(allocator);
        this.role_ids.deinit(allocator);
    }
};

inline fn mentionsAppendUnique(
    comptime T: type,
    allocator: std.mem.Allocator,
    list: *std.ArrayList(T),
    id: T,
) !void {
    for (list.items) |existing| {
        if (existing == id) {
            return;
        }
    }

    try list.append(allocator, id);
}

/// Scans sanitized message content for mention syntax and
/// collects the mentioned user/role ids and the `@everyone`/`@here` flag.
///
/// This records who was mentioned; notification recipient eligibility is
/// resolved separately using role `mentionable` and `mention_everyone` rights.
///
/// Recognized forms: `<@ID>`, `<@!ID>` (legacy nickname form, same user),
/// `<@&ROLE_ID>`, `@everyone`, `@here`. `<#channel>` is intentionally not
/// recognized (channels are not a supported mention target here). An
/// `@everyone`/`@here` token only counts when it is not preceded by an
/// alphanumeric byte (so `foo@everything` does not match).
///
/// The caller owns the returned lists; free them with `Mentions.deinit` (or the
/// arena allocator backs them).
pub fn parseMentions(allocator: std.mem.Allocator, content: []const u8) !Mentions {
    var mentions: Mentions = .{};

    var i: usize = 0;

    while (i < content.len) {
        const c = content[i];

        if (c == '<' and i + 2 < content.len and content[i + 1] == '@') {
            const tag = content[i + 2];

            const kind: enum { user, role } = if (tag == '&')
                .role
            else
                .user;

            const digits_start = i + 2 + @as(usize, if (tag == '&' or tag == '!') 1 else 0);

            var end = digits_start;

            while (end < content.len and content[end] >= '0' and content[end] <= '9') : (end += 1) {}

            if (end > digits_start and end < content.len and content[end] == '>') {
                const digits = content[digits_start..end];

                switch (kind) {
                    .user => {
                        const id = std.fmt.parseInt(root.types.UserId, digits, 10) catch {
                            i = end + 1;

                            continue;
                        };

                        try mentionsAppendUnique(root.types.UserId, allocator, &mentions.user_ids, id);
                    },
                    .role => {
                        const id = std.fmt.parseInt(root.types.RoleId, digits, 10) catch {
                            i = end + 1;

                            continue;
                        };

                        try mentionsAppendUnique(root.types.RoleId, allocator, &mentions.role_ids, id);
                    },
                }

                i = end + 1;

                continue;
            }
        }

        if (c == '@' and (i == 0 or !std.ascii.isAlphanumeric(content[i - 1]))) {
            const every = std.mem.startsWith(u8, content[i..], "@everyone");
            const here = !every and std.mem.startsWith(u8, content[i..], "@here");

            if (every or here) {
                const len: usize = if (every) "@everyone".len else "@here".len;
                const next = i + len;

                if (next == content.len or !std.ascii.isAlphanumeric(content[next])) {
                    mentions.everyone = true;

                    i = next;

                    continue;
                }
            }
        }

        i += 1;
    }

    return mentions;
}

/// Parses the JSON array of decimal-string mention ids emitted by the message
/// queries (`repo.channels.GetMessages` / `repo.messages.Get`) into a slice of
/// strings. A null/empty input yields an empty slice.
pub inline fn parseMentionIds(
    allocator: std.mem.Allocator,
    json: ?[]const u8,
) ![]const []const u8 {
    const text = json orelse return &.{};

    if (text.len == 0) {
        return &.{};
    }

    return std.json.parseFromSliceLeaky([]const []const u8, allocator, text, .{}) catch |err| {
        std.log.scoped(.utils).err("failed to parse mention ids from DB: {t}", .{err});

        return err;
    };
}

/// Splits a comma-separated decimal id list (already percent-decoded by the
/// HTTP parser) into parsed ids. Rejects an empty input, an empty element
/// (`a,,b`), a trailing comma, a non-numeric element, and lists longer than
/// `max`.
pub inline fn parseIdList(
    comptime T: type,
    allocator: std.mem.Allocator,
    raw: []const u8,
    max: usize,
) ![]T {
    if (raw.len == 0) {
        return error.Empty;
    }

    var ids: std.ArrayList(T) = .empty;
    errdefer ids.deinit(allocator);

    var it = std.mem.splitScalar(u8, raw, ',');

    while (it.next()) |part| {
        if (part.len == 0) {
            return error.Empty;
        }

        if (ids.items.len == max) {
            return error.TooMany;
        }

        const id = std.fmt.parseInt(T, part, 10) catch {
            return error.Invalid;
        };

        try ids.append(allocator, id);
    }

    return ids.toOwnedSlice(allocator);
}

/// Escapes `\`, `%` and `_` so `text` can be embedded into a SQL `LIKE`/`ILIKE`
/// pattern (backslash is the default escape character) and match literally.
pub inline fn escapeLikePattern(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (text) |chr| {
        switch (chr) {
            '\\', '%', '_' => {
                try out.append(allocator, '\\');
                try out.append(allocator, chr);
            },
            else => try out.append(allocator, chr),
        }
    }

    return out.toOwnedSlice(allocator);
}

/// The `allowed_mentions` resolution: which mention kinds the author lets
/// through. `all` keeps everything of that kind, `none` drops it, `list` keeps
/// only the listed ids. A default value allows everything.
pub const AllowedMentions = struct {
    pub const Set = union(enum) {
        all,
        none,
        list: []const u64,
    };

    users: Set = .all,
    roles: Set = .all,
    everyone: bool = true,

    pub inline fn allows(_: AllowedMentions, set: Set, id: u64) bool {
        return switch (set) {
            .all => true,
            .none => false,
            .list => |ids| for (ids) |allowed| {
                if (allowed == id) {
                    return true;
                }
            } else false,
        };
    }
};

/// Parses and validates the optional `allowed_mentions` object. Returns `null`
/// (after writing a 400 response) on invalid input; an absent field yields the
/// permissive default. `parse` is mutually exclusive with `users`/`roles`.
pub inline fn parseAllowedMentions(
    response: *root.http.Response,
    root_value: std.json.Value,
) !?AllowedMentions {
    if (root_value != .object) {
        _ = root.route.generic.responseErrorMessage(response, .bad_request, "'allowed_mentions' is not an object");

        return null;
    }

    const has_parse = root_value.object.get("parse") != null;
    const has_users = root_value.object.get("users") != null;
    const has_roles = root_value.object.get("roles") != null;

    if (has_parse and (has_users or has_roles)) {
        _ = root.route.generic.responseErrorMessage(response, .bad_request, "'allowed_mentions.parse' is mutually exclusive with 'users' and 'roles'");

        return null;
    }

    var result: AllowedMentions = .{};

    if (has_users or has_roles) {
        // An explicit id list restricts that kind and disables the others.
        result.everyone = false;
        result.users = .none;
        result.roles = .none;

        if (has_users) {
            const users = try parseAllowedMentionIds(response, root_value.object.get("users").?, root.options.api.messages.max_allowed_mention_users) orelse return null;

            result.users = .{ .list = users };
        }

        if (has_roles) {
            const roles = try parseAllowedMentionIds(response, root_value.object.get("roles").?, root.options.api.messages.max_allowed_mention_roles) orelse return null;

            result.roles = .{ .list = roles };
        }

        return result;
    }

    if (has_parse) {
        const parse_value = root_value.object.get("parse").?;

        if (parse_value != .array) {
            _ = root.route.generic.responseErrorMessage(response, .bad_request, "'allowed_mentions.parse' is not an array");

            return null;
        }

        var users: bool = false;
        var roles: bool = false;
        var everyone: bool = false;

        for (parse_value.array.items) |item| {
            if (item != .string) {
                _ = root.route.generic.responseErrorMessage(response, .bad_request, "'allowed_mentions.parse' is invalid");

                return null;
            }

            if (std.mem.eql(u8, item.string, "users")) {
                users = true;
            } else if (std.mem.eql(u8, item.string, "roles")) {
                roles = true;
            } else if (std.mem.eql(u8, item.string, "everyone")) {
                everyone = true;
            } else {
                _ = root.route.generic.responseErrorMessage(response, .bad_request, "'allowed_mentions.parse' is invalid");

                return null;
            }
        }

        result = .{
            .users = if (users) .all else .none,
            .roles = if (roles) .all else .none,
            .everyone = everyone,
        };
    }

    return result;
}

inline fn parseAllowedMentionIds(
    response: *root.http.Response,
    value: std.json.Value,
    max: usize,
) !?[]const u64 {
    if (value != .array) {
        _ = root.route.generic.responseErrorMessage(response, .bad_request, "'allowed_mentions' is invalid");

        return null;
    }

    if (value.array.items.len > max) {
        _ = root.route.generic.responseErrorMessage(response, .bad_request, "'allowed_mentions' is too long");

        return null;
    }

    const ids = try response.allocator.alloc(u64, value.array.items.len);

    for (value.array.items, 0..) |item, i| {
        if (item != .string) {
            _ = root.route.generic.responseErrorMessage(response, .bad_request, "'allowed_mentions' is invalid");

            return null;
        }

        ids[i] = std.fmt.parseInt(u64, item.string, 10) catch {
            _ = root.route.generic.responseErrorMessage(response, .bad_request, "'allowed_mentions' is invalid");

            return null;
        };
    }

    return ids;
}

/// The attachment reference scheme embedded in message content
/// Any occurrence of `attachment://` followed by a decimal file id is a reference.
pub const ATTACHMENT_SCHEME = "attachment://";

/// Scans sanitized message content for `attachment://<fileId>` references and
/// returns the referenced file ids in first-appearance order, de-duplicated.
///
/// The id is the maximal run of ASCII digits directly after the scheme. A
/// scheme not followed by a digit, or by a decimal that does not fit
/// `root.types.FileId`, is ordinary text: it is skipped rather than rejected, so
/// prose can never fail a request. External `https://…` links are ignored.
///
/// The caller owns the returned slice; the result is empty (not null) when the
/// content references nothing.
pub inline fn parseAttachmentIds(
    allocator: std.mem.Allocator,
    content: []const u8,
) ![]const root.types.FileId {
    var ids: std.ArrayList(root.types.FileId) = .empty;
    errdefer ids.deinit(allocator);

    var i: usize = 0;

    while (std.mem.indexOfPos(u8, content, i, ATTACHMENT_SCHEME)) |scheme_at| {
        const digits_start = scheme_at + ATTACHMENT_SCHEME.len;

        var end = digits_start;

        while (end < content.len and content[end] >= '0' and content[end] <= '9') : (end += 1) {}

        if (end == digits_start) {
            i = digits_start;

            continue;
        }

        i = end;

        const id = std.fmt.parseInt(root.types.FileId, content[digits_start..end], 10) catch {
            // Overflow / out-of-range: not a usable reference, treat as text.
            continue;
        };

        var seen = false;

        for (ids.items) |existing| {
            if (existing == id) {
                seen = true;

                break;
            }
        }

        if (!seen) {
            try ids.append(allocator, id);
        }
    }

    return try ids.toOwnedSlice(allocator);
}

test "parseAttachmentIds: markdown tokens, order, dedupe" {
    const content =
        "![a](attachment://100) and [b](attachment://200) then [a again](attachment://100)";

    const ids = try parseAttachmentIds(std.testing.allocator, content);
    defer std.testing.allocator.free(ids);

    try std.testing.expectEqualSlices(root.types.FileId, &.{ 100, 200 }, ids);
}

test "parseAttachmentIds: bare scheme and mixed separators" {
    const ids = try parseAttachmentIds(std.testing.allocator, "see attachment://7 andattachment://8");
    defer std.testing.allocator.free(ids);

    try std.testing.expectEqualSlices(root.types.FileId, &.{ 7, 8 }, ids);
}

test "parseAttachmentIds: non-references ignored" {
    const cases = [_][]const u8{
        "attachment://",
        "attachment://abc",
        "attachment://x1",
        "https://example.com/files/attachment://12",
        "no scheme at all",
        "",
    };

    // The `https://…attachment://12` case still contains the literal scheme, so
    // it resolves to 12; every other case yields nothing.
    const ids = try parseAttachmentIds(std.testing.allocator, cases[3]);
    defer std.testing.allocator.free(ids);

    try std.testing.expectEqualSlices(root.types.FileId, &.{12}, ids);

    for ([_][]const u8{ cases[0], cases[1], cases[2], cases[4], cases[5] }) |case| {
        const none = try parseAttachmentIds(std.testing.allocator, case);
        defer std.testing.allocator.free(none);

        try std.testing.expectEqual(@as(usize, 0), none.len);
    }
}

test "parseAttachmentIds: overflowing digit run is ordinary text" {
    const ids = try parseAttachmentIds(
        std.testing.allocator,
        "attachment://99999999999999999999999999",
    );
    defer std.testing.allocator.free(ids);

    try std.testing.expectEqual(@as(usize, 0), ids.len);
}
