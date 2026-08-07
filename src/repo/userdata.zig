// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const pq = @import("pq");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.repo_userdata);

pub const Get = struct {
    pub const Item = struct {
        data: []const u8,
        updated_at: u64,

        pub inline fn dupe(allocator: std.mem.Allocator, res: root.db.Result) !Item {
            const data = try res.readSliceDupe(allocator, 0, 0);
            errdefer allocator.free(data);

            return .{
                .data = data,
                .updated_at = res.readInt(u64, 0, 1),
            };
        }
    };

    pub const Result = ?Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Get, Result, anyerror);

    pub const Payload = struct {
        user_id: root.types.UserId,
    };

    const State = enum {
        start,
        waiting,
    };

    allocator: std.mem.Allocator,
    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *Get = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT data, (extract(epoch FROM updated_at) * 1000)::bigint
                \\FROM app.userdata
                \\WHERE user_id = $1;
            , &.{&user_id_param}, &.{user_id_param.len}, &.{.binary}, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("GetUserdata failed to send query: {s}", .{this.db.errorMessage()});

                    return .{ .err = err };
                },
                else => |res| return res.mapDiscard(Result),
            }
        }

        while (this.state == .waiting) {
            if (this.db.isBusy()) {
                return .{ .pending = .db };
            }

            if (this.db.getResult()) |res| {
                defer res.deinit();

                if (res.status() != pq.PGRES_TUPLES_OK) {
                    SCOPE.err("GetUserdata failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                if (res.ntuples() == 0) {
                    return .{ .ready = null };
                }

                std.debug.assert(res.nfields() >= 2);

                const item = Item.dupe(this.allocator, res) catch |err| {
                    SCOPE.err("GetUserdata failed to dupe result: {t}", .{err});

                    return .{ .err = err };
                };

                return .{ .ready = item };
            }

            return .{ .ready = null };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *Get = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(
        allocator: std.mem.Allocator,
        db: *root.db.Connection,
        payload: Payload,
    ) Get {
        db.acquire();

        return .{
            .allocator = allocator,
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *Get) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const Upsert = struct {
    pub const Result = u64;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Upsert, Result, anyerror);

    pub const Payload = struct {
        user_id: root.types.UserId,
        data: []const u8,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *Upsert = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);

            switch (this.db.sendQueryParams(
                \\INSERT INTO app.userdata (user_id, data, updated_at)
                \\VALUES ($1, $2, now())
                \\ON CONFLICT (user_id) DO UPDATE
                \\    SET data = EXCLUDED.data,
                \\        updated_at = now()
                \\RETURNING (extract(epoch FROM updated_at) * 1000)::bigint;
            , &.{
                &user_id_param,
                this.payload.data.ptr,
            }, &.{
                user_id_param.len,
                @intCast(this.payload.data.len),
            }, &.{
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("UpsertUserdata failed to send query: {s}", .{this.db.errorMessage()});

                    return .{ .err = err };
                },
                else => |res| return res.mapDiscard(Result),
            }
        }

        while (this.state == .waiting) {
            if (this.db.isBusy()) {
                return .{ .pending = .db };
            }

            if (this.db.getResult()) |res| {
                defer res.deinit();

                if (res.status() != pq.PGRES_TUPLES_OK) {
                    SCOPE.err("UpsertUserdata failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                if (res.ntuples() == 0) {
                    SCOPE.err("UpsertUserdata returned no row", .{});

                    return .{ .err = error.PGError };
                }

                std.debug.assert(res.nfields() >= 1);

                return .{ .ready = res.readInt(u64, 0, 0) };
            }

            return .{ .pending = .db };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *Upsert = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(
        db: *root.db.Connection,
        payload: Payload,
    ) Upsert {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *Upsert) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};
