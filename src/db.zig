// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const connection = @import("db/connection.zig");
pub const Connection = connection.Connection;
const migrations = @import("db/migrations.zig");
pub const applyMigrations = migrations.applyMigrations;
const pool = @import("db/pool.zig");
pub const Pool = pool.Pool;
const result = @import("db/result.zig");
pub const Result = result.Result;

/// Encodes `ids` in the PostgreSQL binary representation of a one-dimensional
/// `bigint[]` with no nulls (INT8OID), for use as a binary-format parameter.
/// `T` may be any integer type; the value is widened to `i64` without losing
/// bits (unsigned values are reinterpreted). Empty input encodes as a
/// zero-dimension array.
pub inline fn encodeInt8Array(comptime T: type, allocator: std.mem.Allocator, ids: []const T) ![]u8 {
    const info = @typeInfo(T);

    if (info != .int) {
        @compileError("encodeInt8Array: T must be an integer type");
    }

    const header: usize = if (ids.len == 0) 12 else 20;

    // Each element is a 4-byte length prefix followed by the 8-byte value.
    const buffer = try allocator.alloc(u8, header + ids.len * 12);
    errdefer allocator.free(buffer);

    std.mem.writeInt(i32, buffer[0..4], if (ids.len == 0) 0 else 1, .big);
    std.mem.writeInt(i32, buffer[4..8], 0, .big);
    // INT8OID
    std.mem.writeInt(i32, buffer[8..12], 20, .big);

    if (ids.len != 0) {
        std.mem.writeInt(i32, buffer[12..16], @intCast(ids.len), .big);
        std.mem.writeInt(i32, buffer[16..20], 1, .big);
    }

    for (ids, 0..) |id, i| {
        const value: i64 = switch (info.int.signedness) {
            .signed => @intCast(id),
            .unsigned => @bitCast(@as(u64, @intCast(id))),
        };

        const at = header + i * 12;

        std.mem.writeInt(i32, buffer[at..][0..4], 8, .big);
        std.mem.writeInt(i64, buffer[at + 4 ..][0..8], value, .big);
    }

    return buffer;
}

/// Like `encodeInt8Array`, but `values` may contain SQL NULLs: `values[i] ==
/// null` encodes as a length of -1 with no payload, and the array header sets
/// `hasnull` when at least one element is null. Used where a binary `bigint[]`
/// parameter mixes present and absent ids.
pub inline fn encodeInt8ArrayOptional(
    comptime T: type,
    allocator: std.mem.Allocator,
    values: []const ?T,
) ![]u8 {
    const info = @typeInfo(T);

    if (info != .int) {
        @compileError("encodeInt8ArrayOptional: T must be an integer type");
    }

    const header: usize = if (values.len == 0) 12 else 20;

    var size: usize = header;

    for (values) |value| {
        // 4-byte length prefix, plus 8 bytes of value unless null.
        size += if (value == null) 4 else 12;
    }

    const buffer = try allocator.alloc(u8, size);
    errdefer allocator.free(buffer);

    var has_null: i32 = 0;

    for (values) |value| {
        if (value == null) {
            has_null = 1;

            break;
        }
    }

    std.mem.writeInt(i32, buffer[0..4], if (values.len == 0) 0 else 1, .big);
    std.mem.writeInt(i32, buffer[4..8], has_null, .big);
    // INT8OID
    std.mem.writeInt(i32, buffer[8..12], 20, .big);

    if (values.len != 0) {
        std.mem.writeInt(i32, buffer[12..16], @intCast(values.len), .big);
        std.mem.writeInt(i32, buffer[16..20], 1, .big);
    }

    var at: usize = header;

    for (values) |value| {
        if (value) |v| {
            const widened: i64 = switch (info.int.signedness) {
                .signed => @intCast(v),
                .unsigned => @bitCast(@as(u64, @intCast(v))),
            };

            std.mem.writeInt(i32, buffer[at..][0..4], 8, .big);
            std.mem.writeInt(i64, buffer[at + 4 ..][0..8], widened, .big);
            at += 12;
        } else {
            std.mem.writeInt(i32, buffer[at..][0..4], -1, .big);
            at += 4;
        }
    }

    std.debug.assert(at == buffer.len);

    return buffer;
}

test "encodeInt8ArrayOptional" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Empty input: zero dimensions, no null flag.
    {
        const buf = try encodeInt8ArrayOptional(u64, allocator, &.{});
        defer allocator.free(buf);

        try testing.expectEqual(@as(usize, 12), buf.len);
        try testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, buf[0..4], .big));
        try testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, buf[4..8], .big));
        try testing.expectEqual(@as(i32, 20), std.mem.readInt(i32, buf[8..12], .big));
    }

    // No nulls: 20-byte header plus 12 bytes per element, hasnull = 0.
    {
        const values: []const ?u64 = &.{ 1, 2, 3 };
        const buf = try encodeInt8ArrayOptional(u64, allocator, values);
        defer allocator.free(buf);

        try testing.expectEqual(@as(usize, 20 + 3 * 12), buf.len);
        try testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, buf[0..4], .big));
        try testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, buf[4..8], .big));
        try testing.expectEqual(@as(i32, 3), std.mem.readInt(i32, buf[12..16], .big));
        try testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, buf[16..20], .big));

        var at: usize = 20;

        for ([_]u64{ 1, 2, 3 }) |expected| {
            try testing.expectEqual(@as(i32, 8), std.mem.readInt(i32, buf[at..][0..4], .big));
            try testing.expectEqual(@as(i64, @intCast(expected)), std.mem.readInt(i64, buf[at + 4 ..][0..8], .big));
            at += 12;
        }
    }

    // Mixed: a null costs 4 bytes, hasnull = 1.
    {
        const values: []const ?u64 = &.{ 7, null, 9 };
        const buf = try encodeInt8ArrayOptional(u64, allocator, values);
        defer allocator.free(buf);

        try testing.expectEqual(@as(usize, 20 + 12 + 4 + 12), buf.len);
        try testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, buf[4..8], .big));

        var at: usize = 20;

        try testing.expectEqual(@as(i32, 8), std.mem.readInt(i32, buf[at..][0..4], .big));
        try testing.expectEqual(@as(i64, 7), std.mem.readInt(i64, buf[at + 4 ..][0..8], .big));
        at += 12;

        try testing.expectEqual(@as(i32, -1), std.mem.readInt(i32, buf[at..][0..4], .big));
        at += 4;

        try testing.expectEqual(@as(i32, 8), std.mem.readInt(i32, buf[at..][0..4], .big));
        try testing.expectEqual(@as(i64, 9), std.mem.readInt(i64, buf[at + 4 ..][0..8], .big));
    }

    // All null.
    {
        const values: []const ?u64 = &.{ null, null };
        const buf = try encodeInt8ArrayOptional(u64, allocator, values);
        defer allocator.free(buf);

        try testing.expectEqual(@as(usize, 20 + 4 + 4), buf.len);
        try testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, buf[4..8], .big));
    }
}
