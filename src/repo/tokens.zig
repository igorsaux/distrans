// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const pq = @import("pq");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.repo_tokens);

pub const Insert = struct {
    pub const Result = void;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Insert, Result, anyerror);

    pub const Payload = struct {
        token_hash: [32]u8,
        user_id: root.types.UserId,
        expires_at_us: u64,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *Insert = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);
            const expires_at_us_param = root.utils.intToArray(u64, this.payload.expires_at_us, .big);

            switch (this.db.sendQueryParams(
                \\INSERT INTO app.refresh_tokens (token_hash, user_id, expires_at)
                \\VALUES ($1, $2, $3);
            , &.{
                &this.payload.token_hash,
                &user_id_param,
                &expires_at_us_param,
            }, &.{
                this.payload.token_hash.len,
                user_id_param.len,
                expires_at_us_param.len,
            }, &.{
                .binary,
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("InsertRefreshToken failed to send query: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("InsertRefreshToken failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                continue;
            }

            return .ready;
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *Insert = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(
        db: *root.db.Connection,
        payload: Payload,
    ) Insert {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *Insert) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const Replace = struct {
    const Item = root.types.UserId;

    pub const Result = ?Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Replace, Result, anyerror);

    pub const Payload = struct {
        old_refresh_token_hash: [32]u8,
        new_refresh_token_hash: [32]u8,
        expires_at_us: u64,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *Replace = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const expires_at_us_param = root.utils.intToArray(u64, this.payload.expires_at_us, .big);

            switch (this.db.sendQueryParams(
                \\WITH
                \\cleanup AS (
                \\    DELETE FROM app.refresh_tokens
                \\    WHERE expires_at < now()
                \\),
                \\old_token AS (
                \\    DELETE FROM app.refresh_tokens
                \\    WHERE token_hash = $1
                \\      AND expires_at > now()
                \\    RETURNING user_id
                \\),
                \\new_token AS (
                \\    INSERT INTO app.refresh_tokens (token_hash, user_id, expires_at)
                \\    SELECT $2, user_id, $3
                \\    FROM old_token
                \\    RETURNING token_hash, user_id
                \\)
                \\SELECT user_id FROM new_token;
            , &.{
                &this.payload.old_refresh_token_hash,
                &this.payload.new_refresh_token_hash,
                expires_at_us_param[0..@sizeOf(u64)],
            }, &.{
                this.payload.old_refresh_token_hash.len,
                this.payload.new_refresh_token_hash.len,
                @intCast(expires_at_us_param.len),
            }, &.{ .binary, .binary, .binary }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("ReplaceRefreshToken failed to send query: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("ReplaceRefreshToken failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                if (res.ntuples() == 0) {
                    continue;
                }

                std.debug.assert(res.nfields() >= 1);

                return .{
                    .ready = res.readInt(root.types.UserId, 0, 0),
                };
            }

            return .{ .ready = null };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *Replace = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(
        db: *root.db.Connection,
        payload: Payload,
    ) Replace {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *Replace) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const Delete = struct {
    const Item = bool;

    pub const Result = Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Delete, Result, anyerror);

    pub const Payload = struct {
        refresh_token_hash: [32]u8,
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
            switch (this.db.sendQueryParams(
                \\WITH removed AS (
                \\    DELETE FROM app.refresh_tokens
                \\    WHERE token_hash = $1
                \\    RETURNING expires_at > now() AS was_valid
                \\)
                \\SELECT COALESCE(bool_or(was_valid), false) AS was_valid
                \\FROM removed;
            , &.{
                &this.payload.refresh_token_hash,
            }, &.{
                this.payload.refresh_token_hash.len,
            }, &.{
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("DeleteToken failed to send: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("DeleteToken failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                if (res.ntuples() == 0) {
                    return .{ .ready = false };
                }

                std.debug.assert(res.nfields() >= 1);

                return .{
                    .ready = res.readBool(0, 0),
                };
            }

            return .{ .ready = false };
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

pub const DeleteExcept = struct {
    const Item = void;

    pub const Result = Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(DeleteExcept, Result, anyerror);

    pub const Payload = struct {
        user_id: root.types.UserId,
        except_refresh_token_hash: [32]u8,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *DeleteExcept = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);

            switch (this.db.sendQueryParams(
                \\DELETE FROM app.refresh_tokens WHERE user_id = $1 AND token_hash <> $2;
            , &.{
                &user_id_param,
                &this.payload.except_refresh_token_hash,
            }, &.{
                user_id_param.len,
                this.payload.except_refresh_token_hash.len,
            }, &.{
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("DeleteExcept failed to send: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("DeleteExcept failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .ready;
            }

            return .ready;
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *DeleteExcept = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(
        db: *root.db.Connection,
        payload: Payload,
    ) DeleteExcept {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *DeleteExcept) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const DeleteAll = struct {
    const Item = void;

    pub const Result = Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(DeleteAll, Result, anyerror);

    pub const Payload = struct {
        user_id: root.types.UserId,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *DeleteAll = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);

            switch (this.db.sendQueryParams(
                \\DELETE FROM app.refresh_tokens WHERE user_id = $1;
            , &.{
                &user_id_param,
            }, &.{
                user_id_param.len,
            }, &.{
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("DeleteAll failed to send: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("DeleteAll failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .ready;
            }

            return .ready;
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *DeleteAll = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) DeleteAll {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *DeleteAll) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const ReplaceBotToken = struct {
    const Item = void;

    pub const Result = Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(ReplaceBotToken, Result, anyerror);

    pub const Payload = struct {
        user_id: root.types.UserId,
        token_hash: [32]u8,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *ReplaceBotToken = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);

            switch (this.db.sendQueryParams(
                \\WITH
                \\removed AS (
                \\    DELETE FROM app.bot_tokens
                \\    WHERE user_id = $1
                \\)
                \\INSERT INTO app.bot_tokens (user_id, token_hash)
                \\VALUES ($1, $2);
            , &.{
                &user_id_param,
                &this.payload.token_hash,
            }, &.{
                user_id_param.len,
                this.payload.token_hash.len,
            }, &.{
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("ReplaceBotToken failed to send query: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("ReplaceBotToken failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .ready;
            }

            return .ready;
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *ReplaceBotToken = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) ReplaceBotToken {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *ReplaceBotToken) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const GetBotTokenUser = struct {
    const Item = root.types.UserId;

    pub const Result = ?Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(GetBotTokenUser, Result, anyerror);

    pub const Payload = struct {
        token_hash: [32]u8,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *GetBotTokenUser = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            switch (this.db.sendQueryParams(
                \\SELECT u.id
                \\FROM app.bot_tokens AS t
                \\JOIN app.users AS u ON u.id = t.user_id
                \\WHERE t.token_hash = $1
                \\  AND u.deleted_at IS NULL;
            , &.{
                &this.payload.token_hash,
            }, &.{
                this.payload.token_hash.len,
            }, &.{
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("GetBotTokenUser failed to send query: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("GetBotTokenUser failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                if (res.ntuples() == 0) {
                    return .{ .ready = null };
                }

                std.debug.assert(res.nfields() >= 1);

                return .{
                    .ready = res.readInt(root.types.UserId, 0, 0),
                };
            }

            return .{ .ready = null };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetBotTokenUser = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) GetBotTokenUser {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *GetBotTokenUser) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};
