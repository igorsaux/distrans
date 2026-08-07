// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

pub const MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const FrameHeader = packed struct {
    pub const Opcode = enum(u4) {
        text = 0x1,
        binary = 0x2,
        close = 0x8,
        ping = 0x9,
        pong = 0xa,
        _,
    };

    len: u7,
    mask: bool,
    opcode: Opcode,
    rsv3: u1 = 0,
    rsv2: u1 = 0,
    rsv1: u1 = 0,
    fin: bool,
};

pub const TokenBufferSize = std.base64.standard.Encoder.calcSize(std.crypto.hash.Sha1.digest_length);

pub inline fn makeToken(key: []const u8, buffer: *[TokenBufferSize]u8) []const u8 {
    var hasher: std.crypto.hash.Sha1 = .init(.{});

    hasher.update(key);
    hasher.update(MAGIC);

    const hashed_token = hasher.finalResult();

    return std.base64.standard.Encoder.encode(buffer, &hashed_token);
}

pub inline fn writeFrame(
    writer: *std.Io.Writer,
    opcode: FrameHeader.Opcode,
    payload: []const u8,
) bool {
    const frame_len: u7 = if (payload.len <= std.math.maxInt(u7))
        @intCast(payload.len)
    else if (payload.len <= std.math.maxInt(u16))
        126
    else
        127;

    return writeFrameDirect(writer, .{
        .fin = true,
        .opcode = opcode,
        .len = frame_len,
        .mask = false,
    }, payload);
}

pub inline fn writeFrameDirect(
    writer: *std.Io.Writer,
    frame: FrameHeader,
    payload: []const u8,
) bool {
    writer.writeStruct(frame, .big) catch {
        return false;
    };

    if (frame.len == 126) {
        writer.writeInt(u16, @intCast(payload.len), .big) catch {
            return false;
        };
    } else if (frame.len == 127) {
        writer.writeInt(u64, payload.len, .big) catch {
            return false;
        };
    }

    writer.writeAll(payload) catch {
        return false;
    };

    return true;
}

pub const ParsedFrame = struct {
    opcode: FrameHeader.Opcode,
    fin: bool,
    payload: []u8,
    total_len: usize,
};

pub const FrameParseError = error{
    Incomplete,
    ProtocolError,
};

/// Parses a single client frame from `data` (unmasks the payload in place).
/// `Incomplete` means more bytes are needed; `ProtocolError` on invalid frames.
pub fn parseFrame(data: []u8) FrameParseError!ParsedFrame {
    if (data.len < @sizeOf(FrameHeader)) {
        return error.Incomplete;
    }

    var reader: std.Io.Reader = .fixed(data);

    const frame = reader.takeStruct(FrameHeader, .big) catch {
        return error.Incomplete;
    };

    if (!frame.mask) {
        // client should mask
        return error.ProtocolError;
    }

    const payload_len: usize = blk: {
        if (frame.len == 126) {
            break :blk reader.takeInt(u16, .big) catch {
                return error.Incomplete;
            };
        } else if (frame.len == 127) {
            break :blk reader.takeInt(u64, .big) catch {
                return error.Incomplete;
            };
        } else {
            break :blk frame.len;
        }
    };

    var mask: [4]u8 = undefined;

    reader.readSliceAll(&mask) catch {
        return error.Incomplete;
    };

    const rest = data[reader.seek..];

    if (rest.len < payload_len) {
        return error.Incomplete;
    }

    const payload = rest[0..payload_len];

    for (payload, 0..) |b, i| {
        payload[i] = b ^ mask[i % 4];
    }

    return .{
        .opcode = frame.opcode,
        .fin = frame.fin,
        .payload = payload,
        .total_len = reader.seek + payload.len,
    };
}
