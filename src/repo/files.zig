// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const pq = @import("pq");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.repo_files);

pub const Create = struct {
    pub const Item = bool;

    pub const Result = Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Create, Result, anyerror);

    pub const Payload = struct {
        id: root.types.FileId,
        name: []const u8,
        hash: []const u8,
        size: u64,
        content_type: []const u8,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *Create = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const id_param = root.utils.intToArray(root.types.FileId, this.payload.id, .big);
            const size_param = root.utils.intToArray(u64, this.payload.size, .big);

            switch (this.db.sendQueryParams(
                \\INSERT INTO app.files (id, name, hash, size, content_type)
                \\VALUES ($1, $2, $3, $4, $5);
            , &.{
                &id_param,
                this.payload.name.ptr,
                this.payload.hash.ptr,
                &size_param,
                this.payload.content_type.ptr,
            }, &.{
                id_param.len,
                @intCast(this.payload.name.len),
                @intCast(this.payload.hash.len),
                size_param.len,
                @intCast(this.payload.content_type.len),
            }, &.{
                .binary,
                .binary,
                .binary,
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("Create failed to send: {t}", .{err});

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

                if (res.status() != pq.PGRES_COMMAND_OK) {
                    const sqlstate = res.errorSqlstate();

                    if (sqlstate != null and std.mem.eql(u8, std.mem.span(sqlstate), "23505")) {
                        return .{ .ready = false };
                    }

                    SCOPE.err("Create failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .{ .ready = true };
            }

            return .{ .ready = false };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *Create = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(
        db: *root.db.Connection,
        payload: Payload,
    ) Create {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *Create) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const GetByHash = struct {
    pub const Item = struct {
        id: root.types.FileId,
        name: []const u8,
        size: u64,
        content_type: []const u8,

        pub inline fn dupe(allocator: std.mem.Allocator, res: root.db.Result) !Item {
            const name = try res.readSliceDupe(allocator, 0, 1);
            errdefer allocator.free(name);

            const content_type = try res.readSliceDupe(allocator, 0, 3);
            errdefer allocator.free(content_type);

            return .{
                .id = res.readInt(root.types.FileId, 0, 0),
                .name = name,
                .size = res.readInt(u64, 0, 2),
                .content_type = content_type,
            };
        }
    };

    pub const Result = ?Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(GetByHash, Result, anyerror);

    pub const Payload = struct {
        hash: []const u8,
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
        const this: *GetByHash = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            switch (this.db.sendQueryParams(
                \\SELECT id, name, size, content_type
                \\FROM app.files
                \\WHERE hash = $1;
            , &.{this.payload.hash.ptr}, &.{@intCast(this.payload.hash.len)}, &.{.binary}, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("GetByHash failed to send: {t}", .{err});

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
                    SCOPE.err("GetByHash failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                if (res.ntuples() == 0) {
                    return .{ .ready = null };
                }

                std.debug.assert(res.nfields() >= 4);

                const item = Item.dupe(this.allocator, res) catch |err| {
                    SCOPE.err("GetByHash failed to dupe: {t}", .{err});

                    return .{ .err = err };
                };

                return .{ .ready = item };
            }

            return .{ .ready = null };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetByHash = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(
        allocator: std.mem.Allocator,
        db: *root.db.Connection,
        payload: Payload,
    ) GetByHash {
        db.acquire();

        return .{
            .allocator = allocator,
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *GetByHash) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// Deletes up to `limit` files older than `grace_s` that no message references,
/// returning their hashes. The delete is the atomic gate: once a row is gone no
/// `message_attachments` row can reference it (the FK has no `ON DELETE`), so
/// the caller can safely remove the matching S3 object afterwards.
///
/// The returned hashes are owned by the task and freed in `dispose`; the caller
/// must copy anything it needs to keep.
pub const SelectOrphans = struct {
    pub const Result = []const []const u8;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(SelectOrphans, Result, anyerror);

    pub const Payload = struct {
        grace_s: u64,
        limit: u64,
    };

    const State = enum {
        start,
        waiting,
    };

    allocator: std.mem.Allocator,
    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,
    hashes: std.ArrayList([]const u8) = .empty,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *SelectOrphans = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const grace_param = root.utils.intToArray(u64, this.payload.grace_s, .big);
            const limit_param = root.utils.intToArray(u64, this.payload.limit, .big);

            switch (this.db.sendQueryParams(
                \\DELETE FROM app.files
                \\WHERE id IN (
                \\    SELECT f.id
                \\    FROM app.files f
                \\    WHERE f.created_at < now() - ($1::bigint * interval '1 second')
                \\      AND NOT EXISTS (
                \\          SELECT 1 FROM app.message_attachments a
                \\          WHERE a.file_id = f.id
                \\      )
                \\    ORDER BY f.created_at
                \\    LIMIT $2::bigint
                \\)
                \\RETURNING hash;
            , &.{
                &grace_param,
                &limit_param,
            }, &.{
                grace_param.len,
                limit_param.len,
            }, &.{
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("SelectOrphans failed to send: {t}", .{err});

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
                    SCOPE.err("SelectOrphans failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                for (0..res.ntuples()) |i| {
                    const hash = res.readSliceDupe(this.allocator, i, 0) catch |err| {
                        SCOPE.err("SelectOrphans failed to dupe a hash: {t}", .{err});

                        return .{ .err = err };
                    };

                    this.hashes.append(this.allocator, hash) catch |err| {
                        this.allocator.free(hash);

                        SCOPE.err("SelectOrphans failed to grow the list: {t}", .{err});

                        return .{ .err = err };
                    };
                }

                return .{ .ready = this.hashes.items };
            }

            return .{ .ready = &.{} };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *SelectOrphans = @ptrCast(@alignCast(ctx));

        for (this.hashes.items) |hash| {
            this.allocator.free(hash);
        }

        this.hashes.deinit(this.allocator);

        this.db.release();
    }

    pub inline fn init(
        allocator: std.mem.Allocator,
        db: *root.db.Connection,
        payload: Payload,
    ) SelectOrphans {
        db.acquire();

        return .{
            .allocator = allocator,
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *SelectOrphans) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// Counts how many of the given file ids exist. Used to validate message
/// attachments before the insert.
pub const CountExisting = struct {
    pub const Result = usize;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(CountExisting, Result, anyerror);

    pub const Payload = struct {
        ids: []const root.types.FileId,
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

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *CountExisting = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            if (this.ids_buf == null) {
                this.ids_buf = root.db.encodeInt8Array(
                    root.types.FileId,
                    this.allocator,
                    this.payload.ids,
                ) catch |err| {
                    SCOPE.err("CountExisting failed to encode the ids: {t}", .{err});

                    return .{ .err = err };
                };
            }

            const ids = this.ids_buf.?;

            switch (this.db.sendQueryParams(
                \\SELECT count(*)
                \\FROM app.files
                \\WHERE id = ANY($1::bigint[]);
            , &.{ids.ptr}, &.{@intCast(ids.len)}, &.{.binary}, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("CountExisting failed to send: {t}", .{err});

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
                    SCOPE.err("CountExisting failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                std.debug.assert(res.ntuples() == 1);
                std.debug.assert(res.nfields() >= 1);

                return .{ .ready = res.readInt(usize, 0, 0) };
            }

            return .{ .ready = 0 };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *CountExisting = @ptrCast(@alignCast(ctx));

        if (this.ids_buf) |buf| {
            this.allocator.free(buf);
            this.ids_buf = null;
        }

        this.db.release();
    }

    pub inline fn init(
        allocator: std.mem.Allocator,
        db: *root.db.Connection,
        payload: Payload,
    ) CountExisting {
        db.acquire();

        return .{
            .allocator = allocator,
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *CountExisting) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};
