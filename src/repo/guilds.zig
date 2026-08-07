// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const pq = @import("pq");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.repo_guilds);

pub const GetGuilds = struct {
    const Item = struct {
        id: root.types.GuildId,
        name: []const u8,
        avatar_hash: ?[]const u8,
    };

    pub const Result = Item;

    pub const Stream = root.task.Stream(Result, anyerror);
    pub const Lazy = root.task.LazyStream(GetGuilds, Result, anyerror);

    const State = union(enum) {
        start,
        waiting,
        yielding: struct {
            pos: usize = 0,
            res: root.db.Result,
        },
        done,
    };

    db: *root.db.Connection,
    state: State = .start,

    fn poll(ctx: *anyopaque) Stream.PollT {
        const this: *GetGuilds = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            switch (this.db.sendQueryParams(
                \\SELECT id, name, avatar_hash
                \\FROM app.guilds;
            , &.{}, &.{}, &.{}, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("GetGuilds failed to send query: {s}", .{this.db.errorMessage()});

                    return .{ .err = err };
                },
                else => |res| return res.toStreamPoll().mapDiscard(Result),
            }
        }

        while (this.state == .waiting or this.state == .yielding) {
            if (this.state == .waiting) {
                if (this.db.isBusy()) {
                    return .{ .pending = .db };
                }

                if (this.db.getResult()) |res| {
                    if (res.status() != pq.PGRES_TUPLES_OK) {
                        SCOPE.err("GetGuilds failed: {s}", .{res.errorMessage()});
                        res.deinit();

                        continue;
                    }

                    this.state = .{
                        .yielding = .{ .res = res },
                    };
                } else {
                    this.state = .done;
                }
            }

            if (this.state == .yielding) {
                const yield = &this.state.yielding;
                const res = yield.res;

                if (yield.pos >= res.ntuples()) {
                    res.deinit();
                    this.state = .waiting;

                    continue;
                }

                std.debug.assert(res.nfields() >= 3);

                const item: Result = .{
                    .id = res.readInt(root.types.GuildId, yield.pos, 0),
                    .name = res.readString(yield.pos, 1),
                    .avatar_hash = res.readStringOptional(yield.pos, 2),
                };

                yield.pos += 1;

                return .{
                    .yielded = item,
                };
            }
        }

        std.debug.assert(this.state == .done);

        return .done;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetGuilds = @ptrCast(@alignCast(ctx));

        if (this.state == .yielding) {
            this.state.yielding.res.deinit();
        }

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection) GetGuilds {
        db.acquire();

        return .{
            .db = db,
        };
    }

    pub inline fn stream(this: *GetGuilds) Stream {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const Exists = struct {
    const Item = bool;

    pub const Result = Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Exists, Result, anyerror);

    pub const Payload = struct {
        id: root.types.GuildId,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *Exists = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const id_param = root.utils.intToArray(root.types.GuildId, this.payload.id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT id FROM app.guilds WHERE id = $1;
            , &.{&id_param}, &.{id_param.len}, &.{.binary}, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("Exists failed to send query: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("Exists failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .{
                    .ready = res.ntuples() != 0,
                };
            }

            return .{ .ready = false };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *Exists = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) Exists {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *Exists) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const Create = struct {
    /// `null` means a guild with this id already exists (SQLSTATE 23505)
    pub const Result = ?void;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Create, Result, anyerror);

    pub const Payload = struct {
        id: root.types.GuildId,
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
        const this: *Create = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const id_param = root.utils.intToArray(root.types.GuildId, this.payload.id, .big);

            const default_permissions_param = root.utils.intToArray(
                root.types.Permissions.Int,
                root.types.Permissions.defaultEveryone().raw(),
                .big,
            );

            switch (this.db.sendQueryParams(
                \\WITH new_guild AS (
                \\    INSERT INTO app.guilds (id, name)
                \\    VALUES ($1::bigint, $2::text)
                \\    RETURNING id
                \\)
                \\INSERT INTO app.roles (id, guild_id, name, permissions)
                \\SELECT id, id, '@everyone', $3::bytea
                \\FROM new_guild;
            , &.{
                &id_param,
                this.payload.name.ptr,
                &default_permissions_param,
            }, &.{
                id_param.len,
                @intCast(this.payload.name.len),
                default_permissions_param.len,
            }, &.{
                .binary,
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("CreateGuild failed to send query: {s}", .{this.db.errorMessage()});

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
                        return .{ .ready = null };
                    }

                    SCOPE.err("CreateGuild failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .{ .ready = {} };
            } else {
                return .{ .ready = null };
            }
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

pub const GetRoles = struct {
    const Item = struct {
        id: root.types.RoleId,
        name: []const u8,
        position: root.types.Position,
        permissions: root.types.Permissions,
        color: ?root.types.Color,
        mentionable: bool,
    };

    pub const Result = Item;

    pub const Stream = root.task.Stream(Result, anyerror);
    pub const Lazy = root.task.LazyStream(GetRoles, Result, anyerror);

    pub const Payload = struct {
        guild_id: root.types.GuildId,
    };

    const State = union(enum) {
        start,
        waiting,
        yielding: struct {
            pos: usize = 0,
            res: root.db.Result,
            reverse: bool = false,
        },
    };

    payload: Payload,
    db: *root.db.Connection,
    state: State = .start,

    fn poll(ctx: *anyopaque) Stream.PollT {
        const this: *GetRoles = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const guild_id_param = root.utils.intToArray(root.types.GuildId, this.payload.guild_id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT r.id, r.name, r.position, r.permissions, r.color, r.mentionable
                \\FROM app.roles r
                \\WHERE r.guild_id = $1
                \\ORDER BY r.position ASC, r.id ASC;
            , &.{&guild_id_param}, &.{guild_id_param.len}, &.{.binary}, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("GetGuildRoles failed to send query: {t}", .{err});

                    return .{ .err = err };
                },
                else => |res| return res.toStreamPoll().mapDiscard(Result),
            }
        }

        while (this.state == .waiting or this.state == .yielding) {
            if (this.state == .waiting) {
                if (this.db.isBusy()) {
                    return .{ .pending = .db };
                }

                if (this.db.getResult()) |res| {
                    if (res.status() != pq.PGRES_TUPLES_OK) {
                        SCOPE.err("GetGuildRoles failed: {s}", .{res.errorMessage()});
                        res.deinit();

                        return .{ .err = error.PGError };
                    }

                    this.state = .{
                        .yielding = .{
                            .res = res,
                        },
                    };
                } else {
                    return .done;
                }
            }

            if (this.state == .yielding) {
                const yield = &this.state.yielding;
                const res = yield.res;

                if (yield.pos >= res.ntuples()) {
                    res.deinit();
                    this.state = .waiting;

                    continue;
                }

                std.debug.assert(res.nfields() >= 6);

                const item: Result = .{
                    .id = res.readInt(root.types.RoleId, yield.pos, 0),
                    .name = res.readString(yield.pos, 1),
                    .position = res.readInt(root.types.Position, yield.pos, 2),
                    .permissions = res.readPackedStruct(root.types.Permissions, yield.pos, 3),
                    .color = if (res.readIntOptional(u32, yield.pos, 4)) |color|
                        @truncate(color)
                    else
                        null,
                    .mentionable = res.readBool(yield.pos, 5),
                };

                yield.pos += 1;

                return .{ .yielded = item };
            }
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetRoles = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(
        db: *root.db.Connection,
        payload: Payload,
    ) GetRoles {
        db.acquire();

        return .{
            .payload = payload,
            .db = db,
        };
    }

    pub inline fn stream(this: *GetRoles) Stream {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const GetBasePermissions = struct {
    const Item = root.types.Permissions;

    pub const Result = ?Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(GetBasePermissions, Result, anyerror);

    pub const Payload = struct {
        guild_id: root.types.GuildId,
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
        const this: *GetBasePermissions = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const guild_id_param = root.utils.intToArray(root.types.GuildId, this.payload.guild_id, .big);
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT bit_or(r.permissions) AS base
                \\FROM app.roles AS r
                \\WHERE r.guild_id = $1
                \\  AND (r.id = $1 OR EXISTS (
                \\      SELECT 1 FROM app.member_roles AS mr
                \\      WHERE mr.guild_id = r.guild_id
                \\        AND mr.role_id  = r.id
                \\        AND mr.user_id  = $2
                \\  ));
            , &.{
                &guild_id_param,
                &user_id_param,
            }, &.{
                guild_id_param.len,
                user_id_param.len,
            }, &.{
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("GetGuildBasePermissions failed to send: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("GetGuildBasePermissions failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                if (res.ntuples() == 0 or res.isNull(0, 0)) {
                    return .{ .ready = null };
                }

                std.debug.assert(res.nfields() >= 1);

                return .{
                    .ready = res.readPackedStruct(root.types.Permissions, 0, 0),
                };
            }

            return .{ .ready = null };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetBasePermissions = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(
        db: *root.db.Connection,
        payload: Payload,
    ) GetBasePermissions {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *GetBasePermissions) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const Delete = struct {
    /// `true` = the guild was deleted, `false` = it did not exist
    pub const Result = bool;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Delete, Result, anyerror);

    pub const Payload = struct {
        id: root.types.GuildId,
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
            const id_param = root.utils.intToArray(root.types.GuildId, this.payload.id, .big);

            switch (this.db.sendQueryParams(
                \\WITH deleted AS (
                \\    DELETE FROM app.guilds
                \\    WHERE id = $1
                \\    RETURNING id
                \\)
                \\SELECT count(*) FROM deleted;
            , &.{&id_param}, &.{id_param.len}, &.{.binary}, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("DeleteGuild failed to send query: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("DeleteGuild failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                std.debug.assert(res.nfields() >= 1);

                return .{
                    .ready = res.readInt(u64, 0, 0) != 0,
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

pub const GetChannels = struct {
    const Item = struct {
        id: root.types.ChannelId,
        parent_id: ?root.types.ChannelId,
        kind: root.types.ChannelKind,
        name: []const u8,
        topic: ?[]const u8,
        position: root.types.Position,
        last_message_id: ?root.types.MessageId,
    };

    pub const Result = Item;

    pub const Stream = root.task.Stream(Result, anyerror);
    pub const Lazy = root.task.LazyStream(GetChannels, Result, anyerror);

    pub const Payload = struct {
        id: root.types.GuildId,
    };

    const State = union(enum) {
        start,
        waiting,
        yielding: struct {
            pos: usize = 0,
            res: root.db.Result,
        },
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Stream.PollT {
        const this: *GetChannels = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const id_param = root.utils.intToArray(root.types.GuildId, this.payload.id, .big);

            // The newest live message per channel is resolved with a recursive
            // loose index scan over `messages_guild_channel_last_idx`, not a
            // per-channel `ORDER BY id DESC LIMIT 1`: the latter lets the
            // planner pick `messages_pkey` (it expects a match within a few
            // entries) and, for a channel with no messages, walks the entire
            // index — O(channels x messages). The skip scan probes once per
            // non-empty channel and is O(channels) regardless of how many
            // channels are empty. Keep the index in sync with this query.
            switch (this.db.sendQueryParams(
                \\WITH RECURSIVE last_message AS (
                \\    (SELECT m.channel_id, m.id
                \\     FROM app.messages m
                \\     WHERE m.guild_id = $1
                \\       AND m.deleted_at IS NULL
                \\     ORDER BY m.channel_id, m.id DESC
                \\     LIMIT 1)
                \\    UNION ALL
                \\    SELECT n.channel_id, n.id
                \\    FROM last_message l, LATERAL (
                \\        SELECT m.channel_id, m.id
                \\        FROM app.messages m
                \\        WHERE m.guild_id = $1
                \\          AND m.deleted_at IS NULL
                \\          AND m.channel_id > l.channel_id
                \\        ORDER BY m.channel_id, m.id DESC
                \\        LIMIT 1
                \\    ) n
                \\)
                \\SELECT c.id, c.parent_id, c.kind, c.name, c.topic, c.position,
                \\       l.id AS last_message_id
                \\FROM app.channels c
                \\LEFT JOIN last_message l ON l.channel_id = c.id
                \\WHERE c.guild_id = $1
                \\ORDER BY
                \\CASE WHEN c.parent_id IS NULL THEN c.position
                \\     ELSE (SELECT p.position FROM app.channels p WHERE p.id = c.parent_id) END,
                \\CASE WHEN c.parent_id IS NULL THEN 0 ELSE 1 END,
                \\c.position, c.id;
            , &.{&id_param}, &.{id_param.len}, &.{.binary}, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("GetChannels failed to send query: {s}", .{this.db.errorMessage()});

                    return .{ .err = err };
                },
                else => |res| return res.toStreamPoll().mapDiscard(Result),
            }
        }

        while (this.state == .waiting or this.state == .yielding) {
            if (this.state == .waiting) {
                if (this.db.isBusy()) {
                    return .{ .pending = .db };
                }

                if (this.db.getResult()) |res| {
                    if (res.status() != pq.PGRES_TUPLES_OK) {
                        SCOPE.err("GetChannels failed: {s}", .{res.errorMessage()});
                        res.deinit();

                        return .{ .err = error.PGError };
                    }

                    this.state = .{ .yielding = .{ .res = res } };
                } else {
                    return .done;
                }
            }

            if (this.state == .yielding) {
                const yield = &this.state.yielding;
                const res = yield.res;

                if (yield.pos >= res.ntuples()) {
                    res.deinit();
                    this.state = .waiting;

                    continue;
                }

                std.debug.assert(res.nfields() >= 7);

                const item: Result = .{
                    .id = res.readInt(root.types.ChannelId, yield.pos, 0),
                    .parent_id = res.readIntOptional(root.types.ChannelId, yield.pos, 1),
                    .kind = res.readEnum(root.types.ChannelKind, yield.pos, 2),
                    .name = res.readString(yield.pos, 3),
                    .topic = res.readStringOptional(yield.pos, 4),
                    .position = res.readInt(root.types.Position, yield.pos, 5),
                    .last_message_id = res.readIntOptional(root.types.MessageId, yield.pos, 6),
                };

                yield.pos += 1;

                return .{ .yielded = item };
            }
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetChannels = @ptrCast(@alignCast(ctx));

        if (this.state == .yielding) {
            this.state.yielding.res.deinit();
        }

        this.db.release();
    }

    pub inline fn init(
        db: *root.db.Connection,
        payload: Payload,
    ) GetChannels {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn stream(this: *GetChannels) Stream {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const Update = struct {
    /// `null` = the guild does not exist
    pub const Result = ?void;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Update, Result, anyerror);

    pub const Payload = struct {
        guild_id: root.types.GuildId,
        name: ?[]const u8,
        name_set: bool,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *Update = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const set_name_param = root.utils.intToArray(u8, @intFromBool(this.payload.name_set), .big);
            const guild_id_param = root.utils.intToArray(root.types.GuildId, this.payload.guild_id, .big);

            switch (this.db.sendQueryParams(
                \\UPDATE app.guilds AS g
                \\SET name = CASE WHEN $1 THEN $2 ELSE g.name END
                \\WHERE g.id = $3
                \\RETURNING g.id;
            , &.{
                &set_name_param,
                if (this.payload.name) |name| name.ptr else null,
                &guild_id_param,
            }, &.{
                set_name_param.len,
                if (this.payload.name) |name| @intCast(name.len) else 0,
                guild_id_param.len,
            }, &.{
                .binary,
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("Update failed to send: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("Update failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .{ .ready = if (res.ntuples() == 0) null else {} };
            }

            return .{ .ready = null };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *Update = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(
        db: *root.db.Connection,
        payload: Payload,
    ) Update {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *Update) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// Reads the stored avatar bytes of a guild, but only when the stored hash
/// matches `payload.hash`. `null` = no guild/avatar or a hash mismatch.
pub const GetAvatar = struct {
    pub const Result = ?[]const u8;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(GetAvatar, Result, anyerror);

    pub const Payload = struct {
        guild_id: root.types.GuildId,
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
        const this: *GetAvatar = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const guild_id_param = root.utils.intToArray(root.types.GuildId, this.payload.guild_id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT avatar_data
                \\FROM app.guilds
                \\WHERE id = $1
                \\  AND avatar_hash = $2
                \\  AND avatar_data IS NOT NULL;
            , &.{
                &guild_id_param,
                this.payload.hash.ptr,
            }, &.{
                guild_id_param.len,
                @intCast(this.payload.hash.len),
            }, &.{
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("GetAvatar failed to send: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("GetAvatar failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                if (res.ntuples() == 0) {
                    return .{ .ready = null };
                }

                std.debug.assert(res.nfields() >= 1);

                const data = res.readSliceDupe(this.allocator, 0, 0) catch |err| {
                    SCOPE.err("GetAvatar failed to dupe 'avatar_data': {t}", .{err});

                    return .{ .err = err };
                };

                return .{ .ready = data };
            }

            return .{ .ready = null };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetAvatar = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(
        allocator: std.mem.Allocator,
        db: *root.db.Connection,
        payload: Payload,
    ) GetAvatar {
        db.acquire();

        return .{
            .allocator = allocator,
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *GetAvatar) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const SetAvatar = struct {
    pub const Result = ?void;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(SetAvatar, Result, anyerror);

    pub const Payload = struct {
        guild_id: root.types.GuildId,
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
        const this: *SetAvatar = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const guild_id_param = root.utils.intToArray(root.types.GuildId, this.payload.guild_id, .big);

            switch (this.db.sendQueryParams(
                \\UPDATE app.guilds
                \\SET avatar_data = $2, avatar_hash = $3
                \\WHERE id = $1
                \\RETURNING id;
            , &.{
                &guild_id_param,
                this.payload.data.ptr,
                this.payload.hash.ptr,
            }, &.{
                guild_id_param.len,
                @intCast(this.payload.data.len),
                @intCast(this.payload.hash.len),
            }, &.{
                .binary,
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("SetAvatar failed to send: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("SetAvatar failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .{ .ready = if (res.ntuples() == 0) null else {} };
            }

            return .{ .ready = null };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *SetAvatar = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) SetAvatar {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *SetAvatar) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const ClearAvatar = struct {
    pub const Result = ?void;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(ClearAvatar, Result, anyerror);

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
        const this: *ClearAvatar = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const guild_id_param = root.utils.intToArray(root.types.GuildId, this.payload.guild_id, .big);

            switch (this.db.sendQueryParams(
                \\UPDATE app.guilds
                \\SET avatar_data = NULL, avatar_hash = NULL
                \\WHERE id = $1
                \\RETURNING id;
            , &.{&guild_id_param}, &.{guild_id_param.len}, &.{.binary}, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("ClearAvatar failed to send: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("ClearAvatar failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .{ .ready = if (res.ntuples() == 0) null else {} };
            }

            return .{ .ready = null };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *ClearAvatar = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) ClearAvatar {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *ClearAvatar) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const GetCustomEmojis = struct {
    const Item = struct {
        id: root.types.EmojiId,
        name: []const u8,
        icon_hash: []const u8,
    };

    pub const Payload = struct {
        guild_id: root.types.GuildId,
        after: ?root.types.EmojiId,
        limit: usize,
    };

    pub const Result = Item;

    pub const Stream = root.task.Stream(Result, anyerror);
    pub const Lazy = root.task.LazyStream(GetCustomEmojis, Result, anyerror);

    const State = union(enum) {
        start,
        waiting,
        yielding: struct {
            pos: usize = 0,
            res: root.db.Result,
        },
        done,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Stream.PollT {
        const this: *GetCustomEmojis = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const limit_param = root.utils.intToArray(usize, this.payload.limit, .big);
            const guild_id_param = root.utils.intToArray(root.types.GuildId, this.payload.guild_id, .big);

            const res = blk: {
                if (this.payload.after == null) {
                    break :blk this.db.sendQueryParams(
                        \\SELECT id, name, icon_hash
                        \\FROM app.emojis
                        \\WHERE guild_id = $2
                        \\ORDER BY id ASC
                        \\LIMIT $1;
                    , &.{
                        &limit_param,
                        &guild_id_param,
                    }, &.{
                        limit_param.len,
                        guild_id_param.len,
                    }, &.{
                        .binary,
                        .binary,
                    }, .binary);
                }

                const after_param = root.utils.intToArray(root.types.EmojiId, this.payload.after.?, .big);

                break :blk this.db.sendQueryParams(
                    \\SELECT id, name, icon_hash
                    \\FROM app.emojis
                    \\WHERE guild_id = $2
                    \\  AND id > $3
                    \\ORDER BY id ASC
                    \\LIMIT $1;
                , &.{
                    &limit_param,
                    &guild_id_param,
                    &after_param,
                }, &.{
                    limit_param.len,
                    guild_id_param.len,
                    after_param.len,
                }, &.{
                    .binary,
                    .binary,
                    .binary,
                }, .binary);
            };

            switch (res) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("GetCustomEmojis failed to send: {s}", .{this.db.errorMessage()});

                    return .{ .err = err };
                },
                else => |r| return r.toStreamPoll().mapDiscard(Result),
            }
        }

        while (this.state == .waiting or this.state == .yielding) {
            if (this.state == .waiting) {
                if (this.db.isBusy()) {
                    return .{ .pending = .db };
                }

                if (this.db.getResult()) |res| {
                    if (res.status() != pq.PGRES_TUPLES_OK) {
                        SCOPE.err("GetCustomEmojis failed: {s}", .{res.errorMessage()});
                        res.deinit();

                        return .{ .err = error.PGError };
                    }

                    this.state = .{
                        .yielding = .{
                            .res = res,
                        },
                    };
                } else {
                    return .done;
                }
            }

            if (this.state == .yielding) {
                const yield = &this.state.yielding;
                const res = yield.res;

                const total = res.ntuples();

                if (yield.pos >= total) {
                    res.deinit();
                    this.state = .waiting;

                    continue;
                }

                std.debug.assert(res.nfields() >= 3);

                const item: Item = .{
                    .id = res.readInt(root.types.EmojiId, yield.pos, 0),
                    .name = res.readString(yield.pos, 1),
                    .icon_hash = res.readString(yield.pos, 2),
                };

                yield.pos += 1;

                return .{ .yielded = item };
            }
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetCustomEmojis = @ptrCast(@alignCast(ctx));

        if (this.state == .yielding) {
            this.state.yielding.res.deinit();
        }

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) GetCustomEmojis {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn stream(this: *GetCustomEmojis) Stream {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};
