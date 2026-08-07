// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const pq = @import("pq");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.repo_mentions);

// These filters validate the user and role mention IDs stored on messages.

/// Keeps, in input order, the user ids that exist and are not soft-deleted.
/// Bots are allowed (they are ordinary users for mention purposes). Unknown or
/// deleted ids are silently dropped, mirroring how invalid mentions are ignored.
///
/// The returned slice is owned by the task and freed in `dispose`; the caller
/// must copy anything it needs to keep.
pub const FilterValidUsers = struct {
    pub const Result = []const root.types.UserId;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(FilterValidUsers, Result, anyerror);

    pub const Payload = struct {
        ids: []const root.types.UserId,
    };

    const State = enum {
        start,
        waiting,
    };

    allocator: std.mem.Allocator,
    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,
    ids_buf: ?[]u8 = null,
    valid: std.ArrayList(root.types.UserId) = .empty,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *FilterValidUsers = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            if (this.ids_buf == null) {
                this.ids_buf = root.db.encodeInt8Array(
                    root.types.UserId,
                    this.allocator,
                    this.payload.ids,
                ) catch |err| {
                    SCOPE.err("FilterValidUsers failed to encode the ids: {t}", .{err});

                    return .{ .err = err };
                };
            }

            const ids = this.ids_buf.?;

            switch (this.db.sendQueryParams(
                \\SELECT id
                \\FROM app.users
                \\WHERE id = ANY($1::bigint[])
                \\  AND deleted_at IS NULL;
            , &.{ids.ptr}, &.{@intCast(ids.len)}, &.{.binary}, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("FilterValidUsers failed to send: {t}", .{err});

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
                    SCOPE.err("FilterValidUsers failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                for (0..res.ntuples()) |i| {
                    const id = res.readInt(root.types.UserId, i, 0);

                    this.valid.append(this.allocator, id) catch |err| {
                        SCOPE.err("FilterValidUsers failed to grow the list: {t}", .{err});

                        return .{ .err = err };
                    };
                }

                const out = this.filtered() catch |err| {
                    SCOPE.err("FilterValidUsers failed to order the list: {t}", .{err});

                    return .{ .err = err };
                };

                return .{ .ready = out };
            }

            return .{ .ready = &.{} };
        }

        unreachable;
    }

    /// Returns the input ids that the query confirmed, preserving input order.
    fn filtered(this: *FilterValidUsers) ![]const root.types.UserId {
        // Rebuild in order of the parsed content, not the unordered DB result.
        var out: std.ArrayList(root.types.UserId) = .empty;
        errdefer out.deinit(this.allocator);

        for (this.payload.ids) |id| {
            for (this.valid.items) |valid_id| {
                if (valid_id == id) {
                    try out.append(this.allocator, id);

                    break;
                }
            }
        }

        this.valid.deinit(this.allocator);
        this.valid = out;

        return this.valid.items;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *FilterValidUsers = @ptrCast(@alignCast(ctx));

        if (this.ids_buf) |buf| {
            this.allocator.free(buf);
            this.ids_buf = null;
        }

        this.valid.deinit(this.allocator);

        this.db.release();
    }

    pub inline fn init(
        allocator: std.mem.Allocator,
        db: *root.db.Connection,
        payload: Payload,
    ) FilterValidUsers {
        db.acquire();

        return .{
            .allocator = allocator,
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *FilterValidUsers) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// Keeps, in input order, the role ids that belong to `guild_id`. Roles from
/// another guild or unknown ids are silently dropped.
///
/// The returned slice is owned by the task and freed in `dispose`; the caller
/// must copy anything it needs to keep.
pub const FilterValidRoles = struct {
    pub const Result = []const root.types.RoleId;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(FilterValidRoles, Result, anyerror);

    pub const Payload = struct {
        guild_id: root.types.GuildId,
        ids: []const root.types.RoleId,
    };

    const State = enum {
        start,
        waiting,
    };

    allocator: std.mem.Allocator,
    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,
    ids_buf: ?[]u8 = null,
    valid: std.ArrayList(root.types.RoleId) = .empty,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *FilterValidRoles = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            if (this.ids_buf == null) {
                this.ids_buf = root.db.encodeInt8Array(
                    root.types.RoleId,
                    this.allocator,
                    this.payload.ids,
                ) catch |err| {
                    SCOPE.err("FilterValidRoles failed to encode the ids: {t}", .{err});

                    return .{ .err = err };
                };
            }

            const guild_id_param = root.utils.intToArray(root.types.GuildId, this.payload.guild_id, .big);
            const ids = this.ids_buf.?;

            switch (this.db.sendQueryParams(
                \\SELECT id
                \\FROM app.roles
                \\WHERE guild_id = $2::bigint
                \\  AND id = ANY($1::bigint[]);
            , &.{
                ids.ptr,
                &guild_id_param,
            }, &.{
                @intCast(ids.len),
                guild_id_param.len,
            }, &.{
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("FilterValidRoles failed to send: {t}", .{err});

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
                    SCOPE.err("FilterValidRoles failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                for (0..res.ntuples()) |i| {
                    const id = res.readInt(root.types.RoleId, i, 0);

                    this.valid.append(this.allocator, id) catch |err| {
                        SCOPE.err("FilterValidRoles failed to grow the list: {t}", .{err});

                        return .{ .err = err };
                    };
                }

                const out = this.filtered() catch |err| {
                    SCOPE.err("FilterValidRoles failed to order the list: {t}", .{err});

                    return .{ .err = err };
                };

                return .{ .ready = out };
            }

            return .{ .ready = &.{} };
        }

        unreachable;
    }

    fn filtered(this: *FilterValidRoles) ![]const root.types.RoleId {
        var out: std.ArrayList(root.types.RoleId) = .empty;
        errdefer out.deinit(this.allocator);

        for (this.payload.ids) |id| {
            for (this.valid.items) |valid_id| {
                if (valid_id == id) {
                    try out.append(this.allocator, id);

                    break;
                }
            }
        }

        this.valid.deinit(this.allocator);
        this.valid = out;

        return this.valid.items;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *FilterValidRoles = @ptrCast(@alignCast(ctx));

        if (this.ids_buf) |buf| {
            this.allocator.free(buf);
            this.ids_buf = null;
        }

        this.valid.deinit(this.allocator);

        this.db.release();
    }

    pub inline fn init(
        allocator: std.mem.Allocator,
        db: *root.db.Connection,
        payload: Payload,
    ) FilterValidRoles {
        db.acquire();

        return .{
            .allocator = allocator,
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *FilterValidRoles) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};
