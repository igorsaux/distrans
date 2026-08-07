// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const pq = @import("pq");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.repo_notifications);

// Per-user notification preferences. Guild rows carry the guild-level level
// plus the suppression flags; channel rows carry a single level that may
// inherit the guild one. The route layer does a read-modify-write so the
// upserts always receive a complete row (the DB binding has no NULL params).

pub const GetGuild = struct {
    pub const Item = struct {
        level: root.types.GuildNotificationLevel,
        suppress_everyone: bool,
        suppress_roles: bool,
        push: bool,
    };

    pub const Result = ?Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(GetGuild, Result, anyerror);

    pub const Payload = struct {
        user_id: root.types.UserId,
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
        const this: *GetGuild = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);
            const guild_id_param = root.utils.intToArray(root.types.GuildId, this.payload.guild_id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT level, suppress_everyone, suppress_roles, push
                \\FROM app.guild_notification_settings
                \\WHERE user_id = $1
                \\  AND guild_id = $2;
            , &.{
                &user_id_param,
                &guild_id_param,
            }, &.{
                user_id_param.len,
                guild_id_param.len,
            }, &.{
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("GetGuild failed to send query: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("GetGuild failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                if (res.ntuples() == 0) {
                    return .{ .ready = null };
                }

                std.debug.assert(res.nfields() >= 4);

                return .{
                    .ready = .{
                        .level = res.readEnum(root.types.GuildNotificationLevel, 0, 0),
                        .suppress_everyone = res.readBool(0, 1),
                        .suppress_roles = res.readBool(0, 2),
                        .push = res.readBool(0, 3),
                    },
                };
            }

            return .{ .ready = null };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetGuild = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(
        db: *root.db.Connection,
        payload: Payload,
    ) GetGuild {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *GetGuild) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const UpsertGuild = struct {
    pub const Result = void;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(UpsertGuild, Result, anyerror);

    pub const Payload = struct {
        user_id: root.types.UserId,
        guild_id: root.types.GuildId,
        level: root.types.GuildNotificationLevel,
        suppress_everyone: bool,
        suppress_roles: bool,
        push: bool,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *UpsertGuild = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);
            const guild_id_param = root.utils.intToArray(root.types.GuildId, this.payload.guild_id, .big);
            const level_param = root.utils.intToArray(u16, @intFromEnum(this.payload.level), .big);
            const suppress_everyone_param = root.utils.intToArray(u8, if (this.payload.suppress_everyone) 1 else 0, .big);
            const suppress_roles_param = root.utils.intToArray(u8, if (this.payload.suppress_roles) 1 else 0, .big);
            const push_param = root.utils.intToArray(u8, if (this.payload.push) 1 else 0, .big);

            switch (this.db.sendQueryParams(
                \\INSERT INTO app.guild_notification_settings
                \\    (user_id, guild_id, level, suppress_everyone, suppress_roles, push, updated_at)
                \\VALUES ($1, $2, $3::smallint, $4::boolean, $5::boolean, $6::boolean, now())
                \\ON CONFLICT (user_id, guild_id) DO UPDATE
                \\    SET level = EXCLUDED.level,
                \\        suppress_everyone = EXCLUDED.suppress_everyone,
                \\        suppress_roles = EXCLUDED.suppress_roles,
                \\        push = EXCLUDED.push,
                \\        updated_at = now();
            , &.{
                &user_id_param,
                &guild_id_param,
                &level_param,
                &suppress_everyone_param,
                &suppress_roles_param,
                &push_param,
            }, &.{
                user_id_param.len,
                guild_id_param.len,
                level_param.len,
                suppress_everyone_param.len,
                suppress_roles_param.len,
                push_param.len,
            }, &.{
                .binary,
                .binary,
                .binary,
                .binary,
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("UpsertGuild failed to send query: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("UpsertGuild failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .{ .ready = {} };
            }

            return .{ .pending = .db };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *UpsertGuild = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(
        db: *root.db.Connection,
        payload: Payload,
    ) UpsertGuild {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *UpsertGuild) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const GetChannel = struct {
    pub const Item = struct {
        level: root.types.ChannelNotificationLevel,
    };

    pub const Result = ?Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(GetChannel, Result, anyerror);

    pub const Payload = struct {
        user_id: root.types.UserId,
        channel_id: root.types.ChannelId,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *GetChannel = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);
            const channel_id_param = root.utils.intToArray(root.types.ChannelId, this.payload.channel_id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT level
                \\FROM app.channel_notification_settings
                \\WHERE user_id = $1
                \\  AND channel_id = $2;
            , &.{
                &user_id_param,
                &channel_id_param,
            }, &.{
                user_id_param.len,
                channel_id_param.len,
            }, &.{
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("GetChannel failed to send query: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("GetChannel failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                if (res.ntuples() == 0) {
                    return .{ .ready = null };
                }

                std.debug.assert(res.nfields() >= 1);

                return .{
                    .ready = .{
                        .level = res.readEnum(root.types.ChannelNotificationLevel, 0, 0),
                    },
                };
            }

            return .{ .ready = null };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetChannel = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(
        db: *root.db.Connection,
        payload: Payload,
    ) GetChannel {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *GetChannel) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const UpsertChannel = struct {
    pub const Result = void;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(UpsertChannel, Result, anyerror);

    pub const Payload = struct {
        user_id: root.types.UserId,
        channel_id: root.types.ChannelId,
        level: root.types.ChannelNotificationLevel,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *UpsertChannel = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);
            const channel_id_param = root.utils.intToArray(root.types.ChannelId, this.payload.channel_id, .big);
            const level_param = root.utils.intToArray(u16, @intFromEnum(this.payload.level), .big);

            switch (this.db.sendQueryParams(
                \\INSERT INTO app.channel_notification_settings
                \\    (user_id, channel_id, level, updated_at)
                \\VALUES ($1, $2, $3::smallint, now())
                \\ON CONFLICT (user_id, channel_id) DO UPDATE
                \\    SET level = EXCLUDED.level,
                \\        updated_at = now();
            , &.{
                &user_id_param,
                &channel_id_param,
                &level_param,
            }, &.{
                user_id_param.len,
                channel_id_param.len,
                level_param.len,
            }, &.{
                .binary,
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("UpsertChannel failed to send query: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("UpsertChannel failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .{ .ready = {} };
            }

            return .{ .pending = .db };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *UpsertChannel = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(
        db: *root.db.Connection,
        payload: Payload,
    ) UpsertChannel {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *UpsertChannel) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};
