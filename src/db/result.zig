// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const pq = @import("pq");

pub const Result = struct {
    res: *pq.PGresult,

    pub inline fn deinit(this: Result) void {
        pq.PQclear(this.res);
    }

    pub inline fn status(this: Result) usize {
        return pq.PQresultStatus(this.res);
    }

    pub inline fn errorMessage(this: Result) [*c]const u8 {
        return pq.PQresultErrorMessage(this.res);
    }

    pub inline fn errorSqlstate(this: Result) [*c]const u8 {
        return pq.PQresultErrorField(this.res, pq.PG_DIAG_SQLSTATE);
    }

    pub inline fn nfields(this: Result) usize {
        return @intCast(pq.PQnfields(this.res));
    }

    pub inline fn ntuples(this: Result) usize {
        return @intCast(pq.PQntuples(this.res));
    }

    pub inline fn getValue(this: Result, tuple: usize, field: usize) [*c]const u8 {
        std.debug.assert(tuple <= std.math.maxInt(c_int));
        std.debug.assert(field <= std.math.maxInt(c_int));

        return pq.PQgetvalue(this.res, @intCast(tuple), @intCast(field));
    }

    pub inline fn getLength(this: Result, tuple: usize, field: usize) usize {
        std.debug.assert(tuple <= std.math.maxInt(c_int));
        std.debug.assert(field <= std.math.maxInt(c_int));

        return @intCast(pq.PQgetlength(this.res, @intCast(tuple), @intCast(field)));
    }

    pub inline fn isNull(this: Result, tuple: usize, field: usize) bool {
        std.debug.assert(tuple <= std.math.maxInt(c_int));
        std.debug.assert(field <= std.math.maxInt(c_int));

        return pq.PQgetisnull(this.res, @intCast(tuple), @intCast(field)) == 1;
    }

    pub inline fn readInt(this: Result, comptime T: type, tuple: usize, field: usize) T {
        std.debug.assert(tuple <= std.math.maxInt(c_int));
        std.debug.assert(field <= std.math.maxInt(c_int));

        std.debug.assert(!this.isNull(tuple, field));
        std.debug.assert(this.getLength(tuple, field) == @sizeOf(T));

        return std.mem.readInt(T, this.getValue(tuple, field)[0..@sizeOf(T)], .big);
    }

    pub inline fn readIntOptional(this: Result, comptime T: type, tuple: usize, field: usize) ?T {
        if (this.isNull(tuple, field) or this.getLength(tuple, field) == 0) {
            return null;
        }

        return this.readInt(T, tuple, field);
    }

    pub inline fn readPackedStruct(this: Result, comptime T: type, tuple: usize, field: usize) T {
        std.debug.assert(!this.isNull(tuple, field));
        std.debug.assert(this.getLength(tuple, field) == @sizeOf(T));

        const info = @typeInfo(T);

        if (info != .@"struct") {
            @compileError("Not a packed sturct");
        }

        if (info.@"struct".backing_integer == null) {
            @compileError("Not a packed sturct");
        }

        return @bitCast(this.readInt(info.@"struct".backing_integer.?, tuple, field));
    }

    pub inline fn readEnum(this: Result, comptime T: type, tuple: usize, field: usize) T {
        std.debug.assert(!this.isNull(tuple, field));
        std.debug.assert(this.getLength(tuple, field) == @sizeOf(T));

        const info = @typeInfo(T);

        if (info != .@"enum") {
            @compileError("Not a enum");
        }

        const tagInfo = @typeInfo(info.@"enum".tag_type);

        if (tagInfo != .int) {
            @compileError("Not a enum");
        }

        return std.enums.fromInt(T, this.readInt(info.@"enum".tag_type, tuple, field)).?;
    }

    pub inline fn readString(this: Result, tuple: usize, field: usize) []const u8 {
        std.debug.assert(tuple <= std.math.maxInt(c_int));
        std.debug.assert(field <= std.math.maxInt(c_int));

        std.debug.assert(!this.isNull(tuple, field));

        return this.getValue(tuple, field)[0..this.getLength(tuple, field)];
    }

    pub inline fn readStringOptional(this: Result, tuple: usize, field: usize) ?[]const u8 {
        if (this.isNull(tuple, field)) {
            return null;
        }

        return this.readString(tuple, field);
    }

    pub inline fn readSliceDupe(this: Result, allocator: std.mem.Allocator, tuple: usize, field: usize) ![]const u8 {
        const string = this.readString(tuple, field);

        return try allocator.dupe(u8, string);
    }

    pub inline fn readSliceOptionalDupe(this: Result, allocator: std.mem.Allocator, tuple: usize, field: usize) !?[]const u8 {
        const string = this.readStringOptional(tuple, field) orelse {
            return null;
        };

        return try allocator.dupe(u8, string);
    }

    pub inline fn readBool(this: Result, tuple: usize, field: usize) bool {
        return this.readInt(u8, tuple, field) == 1;
    }
};
