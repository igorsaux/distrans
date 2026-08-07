// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const pq = @import("pq");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.repo_emojis);

pub const Get = struct {
    pub const Item = struct {
        guild_id: root.types.GuildId,
    };

    pub const Result = ?Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Get, Result, anyerror);

    pub const Payload = struct {
        id: root.types.EmojiId,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *Get = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const id_param = root.utils.intToArray(root.types.EmojiId, this.payload.id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT guild_id
                \\FROM app.emojis
                \\WHERE id = $1;
            , &.{&id_param}, &.{id_param.len}, &.{.binary}, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("Get failed to send query: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("Get failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                if (res.ntuples() == 0) {
                    return .{ .ready = null };
                }

                std.debug.assert(res.nfields() >= 1);

                const item: Item = .{
                    .guild_id = res.readInt(root.types.GuildId, 0, 0),
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

    pub inline fn init(db: *root.db.Connection, payload: Payload) Get {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *Get) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const GetIcon = struct {
    pub const Item = []const u8;

    pub const Result = ?Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(GetIcon, Result, anyerror);

    pub const Payload = struct {
        id: root.types.EmojiId,
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
        const this: *GetIcon = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const id_param = root.utils.intToArray(root.types.EmojiId, this.payload.id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT icon_data
                \\FROM app.emojis
                \\WHERE id = $1
                \\  AND icon_hash = $2;
            , &.{
                &id_param,
                this.payload.hash.ptr,
            }, &.{
                id_param.len,
                @intCast(this.payload.hash.len),
            }, &.{
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("GetIcon failed to send query: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("GetIcon failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                if (res.ntuples() == 0) {
                    return .{ .ready = null };
                }

                std.debug.assert(res.nfields() >= 1);

                const data = res.readSliceDupe(this.allocator, 0, 0) catch |err| {
                    SCOPE.err("GetIcon failed to dupe 'icon_data': {t}", .{err});

                    return .{ .err = err };
                };

                return .{ .ready = data };
            }

            return .{ .ready = null };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetIcon = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(
        allocator: std.mem.Allocator,
        db: *root.db.Connection,
        payload: Payload,
    ) GetIcon {
        db.acquire();

        return .{
            .allocator = allocator,
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *GetIcon) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const SetIcon = struct {
    /// `null` = the emoji does not exist
    pub const Result = ?void;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(SetIcon, Result, anyerror);

    pub const Payload = struct {
        id: root.types.EmojiId,
        data: []const u8,
        hash: []const u8,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *SetIcon = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const id_param = root.utils.intToArray(root.types.EmojiId, this.payload.id, .big);

            switch (this.db.sendQueryParams(
                \\UPDATE app.emojis
                \\SET icon_data = $2, icon_hash = $3
                \\WHERE id = $1
                \\RETURNING id;
            , &.{
                &id_param,
                this.payload.data.ptr,
                this.payload.hash.ptr,
            }, &.{
                id_param.len,
                @intCast(this.payload.data.len),
                @intCast(this.payload.hash.len),
            }, &.{
                .binary,
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("SetIcon failed to send query: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("SetIcon failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .{ .ready = if (res.ntuples() == 0) null else {} };
            }

            return .{ .ready = null };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *SetIcon = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) SetIcon {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *SetIcon) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const Create = struct {
    /// `null` = the (guild_id, name) pair is already taken (SQLSTATE 23505)
    pub const Result = ?void;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Create, Result, anyerror);

    pub const Payload = struct {
        id: root.types.EmojiId,
        guild_id: root.types.GuildId,
        name: []const u8,
        icon_data: []const u8,
        icon_hash: []const u8,
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
            const id_param = root.utils.intToArray(root.types.EmojiId, this.payload.id, .big);
            const guild_id_param = root.utils.intToArray(root.types.GuildId, this.payload.guild_id, .big);

            switch (this.db.sendQueryParams(
                \\INSERT INTO app.emojis (id, guild_id, name, icon_data, icon_hash)
                \\VALUES ($1, $2, $3, $4, $5);
            , &.{
                &id_param,
                &guild_id_param,
                this.payload.name.ptr,
                this.payload.icon_data.ptr,
                this.payload.icon_hash.ptr,
            }, &.{
                id_param.len,
                guild_id_param.len,
                @intCast(this.payload.name.len),
                @intCast(this.payload.icon_data.len),
                @intCast(this.payload.icon_hash.len),
            }, &.{
                .binary,
                .binary,
                .binary,
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("Create failed to send query: {s}", .{this.db.errorMessage()});

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

                    // The only unique constraint reachable here is (guild_id, name);
                    // the snowflake primary key cannot realistically collide.
                    if (sqlstate != null and std.mem.eql(u8, std.mem.span(sqlstate), "23505")) {
                        return .{ .ready = null };
                    }

                    SCOPE.err("Create failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .{ .ready = {} };
            }

            return .{ .ready = null };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *Create = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) Create {
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

pub const Rename = struct {
    pub const Result = enum {
        ok,
        not_found,
        /// A different emoji in the same guild already uses `name` (SQLSTATE 23505)
        name_taken,
    };

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Rename, Result, anyerror);

    pub const Payload = struct {
        id: root.types.EmojiId,
        name: []const u8,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *Rename = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const id_param = root.utils.intToArray(root.types.EmojiId, this.payload.id, .big);

            switch (this.db.sendQueryParams(
                \\UPDATE app.emojis
                \\SET name = $2
                \\WHERE id = $1
                \\RETURNING id;
            , &.{
                &id_param,
                this.payload.name.ptr,
            }, &.{
                id_param.len,
                @intCast(this.payload.name.len),
            }, &.{
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("Rename failed to send query: {s}", .{this.db.errorMessage()});

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
                    const sqlstate = res.errorSqlstate();

                    if (sqlstate != null and std.mem.eql(u8, std.mem.span(sqlstate), "23505")) {
                        return .{ .ready = .name_taken };
                    }

                    SCOPE.err("Rename failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .{ .ready = if (res.ntuples() == 0) .not_found else .ok };
            }

            return .{ .ready = .not_found };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *Rename = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) Rename {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *Rename) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const CountByGuild = struct {
    pub const Result = u64;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(CountByGuild, Result, anyerror);

    pub const Payload = struct {
        guild_id: root.types.GuildId,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *CountByGuild = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const guild_id_param = root.utils.intToArray(root.types.GuildId, this.payload.guild_id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT COUNT(*)
                \\FROM app.emojis
                \\WHERE guild_id = $1;
            , &.{&guild_id_param}, &.{guild_id_param.len}, &.{.binary}, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("CountByGuild failed to send query: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("CountByGuild failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                std.debug.assert(res.ntuples() >= 1 and res.nfields() >= 1);

                return .{ .ready = @intCast(res.readInt(u64, 0, 0)) };
            }

            return .{ .ready = 0 };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *CountByGuild = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) CountByGuild {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *CountByGuild) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const Delete = struct {
    /// `null` = the emoji does not exist
    pub const Result = ?void;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Delete, Result, anyerror);

    pub const Payload = struct {
        id: root.types.EmojiId,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *Delete = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const emoji_id_param = root.utils.intToArray(root.types.EmojiId, this.payload.id, .big);

            switch (this.db.sendQueryParams(
                \\DELETE FROM app.emojis
                \\WHERE id = $1
                \\RETURNING id;
            , &.{
                &emoji_id_param,
            }, &.{
                emoji_id_param.len,
            }, &.{
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("Delete failed to send query: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("Delete failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                if (res.ntuples() == 0) {
                    return .{ .ready = null };
                }

                return .{ .ready = {} };
            }

            return .{ .ready = null };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *Delete = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) Delete {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *Delete) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};
