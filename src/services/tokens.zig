// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
pub const Signer = std.crypto.auth.hmac.sha2.HmacSha256;
pub const base64 = std.base64.url_safe_no_pad;

const root = @import("../root.zig");

pub inline fn generateRefreshToken(allocator: std.mem.Allocator) ![]u8 {
    var buffer: [128]u8 = undefined;

    try std.Io.randomSecure(root.io, &buffer);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();

    try std.base64.url_safe_no_pad.Encoder.encodeWriter(&writer.writer, &buffer);

    return writer.written();
}

pub inline fn isBotToken(token: []const u8) bool {
    return std.mem.startsWith(u8, token, "bot_");
}

pub inline fn botTokenHash(token: []const u8) [32]u8 {
    var output: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &output, .{});

    return output;
}

pub inline fn generateBotToken(allocator: std.mem.Allocator) ![]u8 {
    var buffer: [32]u8 = undefined;

    try std.Io.randomSecure(root.io, &buffer);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();

    try writer.writer.writeAll("bot_");
    try std.base64.url_safe_no_pad.Encoder.encodeWriter(&writer.writer, &buffer);

    return writer.written();
}

/// Webhook execute token: 32 random bytes, base64url without padding, no
/// prefix. The plaintext is returned once on create; only its sha256 is stored.
pub inline fn generateWebhookToken(allocator: std.mem.Allocator) ![]u8 {
    var buffer: [32]u8 = undefined;

    try std.Io.randomSecure(root.io, &buffer);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();

    try std.base64.url_safe_no_pad.Encoder.encodeWriter(&writer.writer, &buffer);

    return writer.written();
}

pub inline fn webhookTokenHash(token: []const u8) [32]u8 {
    var output: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &output, .{});

    return output;
}

pub const JwtPayload = struct {
    sub: []const u8,
    exp: u64,
};

pub fn generateAccessToken(
    allocator: std.mem.Allocator,
    user_id: root.types.UserId,
) ![]u8 {
    const jwt_header_json = "{ \"alg\": \"HS256\", \"typ\": \"JWT\" }";

    const now_s: u64 = @intCast(std.Io.Timestamp.now(root.io, .real).toSeconds());
    const sub = try std.fmt.allocPrint(allocator, "{}", .{user_id});
    errdefer allocator.free(sub);

    var json_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer json_writer.deinit();

    try std.json.fmt(JwtPayload{
        .sub = sub,
        .exp = now_s + root.options.auth.access_token_exp_s,
    }, .{}).format(&json_writer.writer);
    const jwt_payload_json = json_writer.written();

    var base64_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer base64_writer.deinit();

    try base64.Encoder.encodeWriter(&base64_writer.writer, jwt_header_json);
    try base64_writer.writer.writeByte('.');
    try base64.Encoder.encodeWriter(&base64_writer.writer, jwt_payload_json);

    var sign_buffer: [Signer.mac_length]u8 = undefined;
    Signer.create(&sign_buffer, base64_writer.written(), root.options.auth.access_token_key);

    try base64_writer.writer.writeByte('.');
    try base64.Encoder.encodeWriter(&base64_writer.writer, &sign_buffer);

    return base64_writer.written();
}

pub const AccessTokenParts = struct {
    header_payload: []const u8,
    header: []const u8,
    payload: []const u8,
    signature: []const u8,

    pub inline fn split(input: []const u8) ?AccessTokenParts {
        const sign_delim = std.mem.findScalarLast(u8, input, '.') orelse {
            return null;
        };

        if (sign_delim + 1 >= input.len) {
            return null;
        }

        const signature = input[sign_delim + 1 ..];

        if (signature.len == 0) {
            return null;
        }

        const header_payload = input[0..sign_delim];

        const header_payload_delim = std.mem.findScalar(u8, header_payload, '.') orelse {
            return null;
        };

        const header = input[0..header_payload_delim];

        if (header.len == 0) {
            return null;
        }

        const payload = input[header_payload_delim + 1 .. sign_delim];

        if (payload.len == 0) {
            return null;
        }

        return .{
            .header_payload = header_payload,
            .header = header,
            .payload = payload,
            .signature = signature,
        };
    }

    pub inline fn verify(this: AccessTokenParts) bool {
        const sign_len = base64.Decoder.calcSizeForSlice(this.signature) catch {
            return false;
        };

        if (sign_len != Signer.mac_length) {
            return false;
        }

        var sign: [Signer.mac_length]u8 = undefined;
        base64.Decoder.decode(&sign, this.signature) catch {
            return false;
        };

        return verifySign(this.header_payload, &sign, root.options.auth.access_token_key);
    }

    pub inline fn parsePayload(this: AccessTokenParts, allocator: std.mem.Allocator) !JwtPayload {
        const payload_len = try base64.Decoder.calcSizeForSlice(this.payload);

        const raw_payload = try allocator.alloc(u8, payload_len);

        try base64.Decoder.decode(raw_payload, this.payload);

        return try std.json.parseFromSliceLeaky(
            JwtPayload,
            allocator,
            raw_payload,
            .{},
        );
    }
};

pub inline fn verifySign(data: []const u8, sign: []const u8, key: []const u8) bool {
    var new_sign: [Signer.mac_length]u8 = undefined;
    Signer.create(&new_sign, data, key);

    return std.mem.eql(u8, sign, &new_sign);
}

pub const REFRESH_COOKIE_NAME = "refresh_token";
pub const REFRESH_COOKIE_PATH = "/api";

pub inline fn extractRefreshTokenHash(cookies: []const []const u8) ?[32]u8 {
    for (cookies) |cookie| {
        const delim = std.mem.findScalar(u8, cookie, '=') orelse {
            return null;
        };

        if (!std.mem.eql(u8, cookie[0..delim], "refresh_token")) {
            return null;
        }

        var output: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(cookie[delim + 1 ..], &output, .{});

        return output;
    }

    return null;
}
