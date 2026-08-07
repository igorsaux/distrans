// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const pq = @import("pq");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.repo_channels);

/// Inline reaction aggregate for one message, as a JSON array column (SQL NULL
/// when the message has no reactions). `user_param` is the placeholder of the
/// requesting user id (`me`), `message_ref` the outer column holding the
/// message id (`app.messages.id` or an alias). Mirrors `GetSummary`: soft-deleted
/// users are excluded and entries are ordered by first use.
pub inline fn reactionsAggregate(
    comptime user_param: usize,
    comptime message_ref: []const u8,
) []const u8 {
    return std.fmt.comptimePrint(
        \\,
        \\       (SELECT json_agg(json_build_object(
        \\            'emoji_id', rr.emoji_id::text,
        \\            'unicode_emoji', rr.unicode_emoji,
        \\            'count', rr.cnt,
        \\            'me', rr.me
        \\        ) ORDER BY rr.first_use, rr.emoji_id NULLS LAST, rr.unicode_emoji NULLS LAST)
        \\        FROM (
        \\            SELECT mr.emoji_id, mr.unicode_emoji, COUNT(*)::bigint AS cnt,
        \\                   bool_or(mr.user_id = ${d}) AS me, MIN(mr.created_at) AS first_use
        \\            FROM app.message_reactions AS mr
        \\            JOIN app.users AS u ON u.id = mr.user_id AND u.deleted_at IS NULL
        \\            WHERE mr.message_id = {s}
        \\            GROUP BY mr.emoji_id, mr.unicode_emoji
        \\        ) AS rr) AS reactions
        \\
    , .{ user_param, message_ref });
}

pub const IsExists = struct {
    const Item = struct {
        guild_id: root.types.GuildId,
        kind: root.types.ChannelKind,
        parent_id: ?root.types.ChannelId,
    };

    pub const Result = ?Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(IsExists, Result, anyerror);

    pub const Payload = struct {
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
        const this: *IsExists = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const id_param = root.utils.intToArray(root.types.ChannelId, this.payload.channel_id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT guild_id, kind, parent_id
                \\FROM app.channels
                \\WHERE id = $1;
            , &.{&id_param}, &.{id_param.len}, &.{.binary}, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("IsExists failed to send query: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("IsExists failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                if (res.ntuples() == 0) {
                    return .{ .ready = null };
                }

                std.debug.assert(res.nfields() >= 3);

                return .{
                    .ready = .{
                        .guild_id = res.readInt(root.types.GuildId, 0, 0),
                        .kind = res.readEnum(root.types.ChannelKind, 0, 1),
                        .parent_id = res.readIntOptional(root.types.ChannelId, 0, 2),
                    },
                };
            }

            return .{ .ready = null };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *IsExists = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(
        db: *root.db.Connection,
        payload: Payload,
    ) IsExists {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *IsExists) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const SetOverwrite = struct {
    const Item = void;

    pub const Result = Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(SetOverwrite, Result, anyerror);

    pub const Payload = struct {
        channel_id: root.types.ChannelId,
        target: root.types.Overwrites.Target,
        overwrites: root.types.Overwrites,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *SetOverwrite = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const channel_id_param = root.utils.intToArray(root.types.ChannelId, this.payload.channel_id, .big);
            const target_type_param = root.utils.intToArray(u16, @intFromEnum(this.payload.target.ty()), .big);
            const target_id_param = switch (this.payload.target) {
                .role => |role_id| root.utils.intToArray(root.types.RoleId, role_id, .big),
                .member => |user_id| root.utils.intToArray(root.types.UserId, user_id, .big),
            };
            const allow_param = root.utils.intToArray(root.types.Permissions.Int, this.payload.overwrites.allow.raw(), .big);
            const deny_param = root.utils.intToArray(root.types.Permissions.Int, this.payload.overwrites.deny.raw(), .big);

            switch (this.db.sendQueryParams(
                \\INSERT INTO app.overwrites AS o
                \\       (guild_id, channel_id, target_type, role_id, user_id, allow, deny)
                \\SELECT c.guild_id,
                \\       c.id,
                \\       $2::SMALLINT,
                \\       CASE WHEN $2::SMALLINT = 0 THEN $3::BIGINT END,
                \\       CASE WHEN $2::SMALLINT = 1 THEN $3::BIGINT END,
                \\       $4::BYTEA,
                \\       $5::BYTEA
                \\FROM app.channels c
                \\WHERE c.id = $1::BIGINT
                \\ON CONFLICT (channel_id, target_type, target_id) DO UPDATE
                \\SET allow = EXCLUDED.allow,
                \\    deny  = EXCLUDED.deny;
            , &.{
                &channel_id_param,
                &target_type_param,
                &target_id_param,
                &allow_param,
                &deny_param,
            }, &.{
                channel_id_param.len,
                target_type_param.len,
                target_id_param.len,
                allow_param.len,
                deny_param.len,
            }, &.{
                .binary,
                .binary,
                .binary,
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("SetOverwrite failed to send: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("SetOverwrite failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .ready;
            }

            return .ready;
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *SetOverwrite = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(
        db: *root.db.Connection,
        payload: Payload,
    ) SetOverwrite {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *SetOverwrite) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const GetOverwrites = struct {
    pub const Result = root.repo.types.Overwrite;

    pub const Stream = root.task.Stream(Result, anyerror);
    pub const Lazy = root.task.LazyStream(GetOverwrites, Result, anyerror);

    pub const Payload = struct {
        channel_id: root.types.ChannelId,
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
        const this: *GetOverwrites = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const channel_id_param = root.utils.intToArray(root.types.ChannelId, this.payload.channel_id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT target_type, target_id, allow, deny
                \\FROM app.overwrites
                \\WHERE channel_id = $1
                \\ORDER BY target_type, target_id;
            , &.{&channel_id_param}, &.{channel_id_param.len}, &.{.binary}, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("GetOverwrites failed to send query: {s}", .{this.db.errorMessage()});

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
                        SCOPE.err("GetOverwrites failed: {s}", .{res.errorMessage()});
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

                std.debug.assert(res.nfields() >= 4);

                const ty = res.readEnum(root.types.Overwrites.Type, yield.pos, 0);
                const overwrites: root.types.Overwrites = .{
                    .allow = res.readPackedStruct(root.types.Permissions, yield.pos, 2),
                    .deny = res.readPackedStruct(root.types.Permissions, yield.pos, 3),
                };

                const item: root.repo.types.Overwrite = switch (ty) {
                    .role => .{
                        .channel_id = this.payload.channel_id,
                        .target = .{ .role = res.readInt(root.types.RoleId, yield.pos, 1) },
                        .overwrites = overwrites,
                    },
                    .member => .{
                        .channel_id = this.payload.channel_id,
                        .target = .{ .member = res.readInt(root.types.UserId, yield.pos, 1) },
                        .overwrites = overwrites,
                    },
                };

                yield.pos += 1;

                return .{ .yielded = item };
            }
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetOverwrites = @ptrCast(@alignCast(ctx));

        if (this.state == .yielding) {
            this.state.yielding.res.deinit();
        }

        this.db.release();
    }

    pub inline fn init(
        db: *root.db.Connection,
        payload: Payload,
    ) GetOverwrites {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn stream(this: *GetOverwrites) Stream {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const GetOverwrite = struct {
    const Item = struct {
        guild_id: root.types.GuildId,
        overwrites: root.types.Overwrites,
    };

    pub const Result = ?Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(GetOverwrite, Result, anyerror);

    pub const Payload = struct {
        channel_id: root.types.ChannelId,
        target: root.types.Overwrites.Target,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *GetOverwrite = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const channel_id_param = root.utils.intToArray(root.types.ChannelId, this.payload.channel_id, .big);
            const target_type_param = root.utils.intToArray(u16, @intFromEnum(this.payload.target.ty()), .big);
            const target_id_param = switch (this.payload.target) {
                .role => |role_id| root.utils.intToArray(root.types.RoleId, role_id, .big),
                .member => |user_id| root.utils.intToArray(root.types.UserId, user_id, .big),
            };

            switch (this.db.sendQueryParams(
                \\SELECT o.guild_id, o.allow, o.deny
                \\FROM app.overwrites o
                \\WHERE o.channel_id  = $1::BIGINT
                \\  AND o.target_type = $2::SMALLINT
                \\  AND o.target_id   = $3::BIGINT;
            , &.{
                &channel_id_param,
                &target_type_param,
                &target_id_param,
            }, &.{
                channel_id_param.len,
                target_type_param.len,
                target_id_param.len,
            }, &.{
                .binary,
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("GetOverwrite failed to send: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("GetOverwrite failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                if (res.ntuples() == 0) {
                    return .{ .ready = null };
                }

                const item: Item = .{
                    .guild_id = res.readInt(root.types.GuildId, 0, 0),
                    .overwrites = .{
                        .allow = res.readPackedStruct(root.types.Permissions, 0, 1),
                        .deny = res.readPackedStruct(root.types.Permissions, 0, 2),
                    },
                };

                return .{ .ready = item };
            }

            return .{ .ready = null };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetOverwrite = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) GetOverwrite {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *GetOverwrite) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const RemoveOverwrite = struct {
    const Item = void;

    pub const Result = Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(RemoveOverwrite, Result, anyerror);

    pub const Payload = struct {
        channel_id: root.types.ChannelId,
        target: root.types.Overwrites.Target,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *RemoveOverwrite = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const channel_id_param = root.utils.intToArray(root.types.ChannelId, this.payload.channel_id, .big);
            const target_type_param = root.utils.intToArray(u16, @intFromEnum(this.payload.target.ty()), .big);
            const target_id_param = switch (this.payload.target) {
                .role => |role_id| root.utils.intToArray(root.types.RoleId, role_id, .big),
                .member => |user_id| root.utils.intToArray(root.types.UserId, user_id, .big),
            };

            switch (this.db.sendQueryParams(
                \\DELETE FROM app.overwrites
                \\WHERE channel_id  = $1::BIGINT
                \\  AND target_type = $2::SMALLINT
                \\  AND target_id   = $3::BIGINT;
            , &.{
                &channel_id_param,
                &target_type_param,
                &target_id_param,
            }, &.{
                channel_id_param.len,
                target_type_param.len,
                target_id_param.len,
            }, &.{
                .binary,
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("RemoveOverwrite failed to send: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("RemoveOverwrite failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .ready;
            }

            return .ready;
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *RemoveOverwrite = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(
        db: *root.db.Connection,
        payload: Payload,
    ) RemoveOverwrite {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *RemoveOverwrite) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const Create = struct {
    pub const Result = void;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Create, Result, anyerror);

    pub const Payload = struct {
        id: root.types.ChannelId,
        guild_id: root.types.GuildId,
        name: []const u8,
        topic: ?[]const u8,
        kind: root.types.ChannelKind,
        parent_id: ?root.types.ChannelId,
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
            const id_param = root.utils.intToArray(root.types.ChannelId, this.payload.id, .big);
            const guild_id_param = root.utils.intToArray(root.types.GuildId, this.payload.guild_id, .big);
            const parent_id_param = root.utils.intToArray(root.types.ChannelId, this.payload.parent_id orelse 0, .big);
            const kind_param = root.utils.intToArray(u16, @intFromEnum(this.payload.kind), .big);
            const topic = this.payload.topic orelse "";

            // With a parent category: insert the channel and copy ("sync")
            // the parent's overwrites in a single statement.
            if (this.payload.parent_id != null) {
                switch (this.db.sendQueryParams(
                    \\WITH new_channel AS (
                    \\    INSERT INTO app.channels (id, guild_id, parent_id, kind, name, topic)
                    \\    VALUES ($1::bigint, $2::bigint, $3::bigint, $4::smallint, $5::text, NULLIF($6::text, ''))
                    \\    RETURNING id
                    \\),
                    \\synced AS (
                    \\    INSERT INTO app.overwrites (guild_id, channel_id, target_type, role_id, user_id, allow, deny)
                    \\    SELECT o.guild_id, $1::bigint, o.target_type, o.role_id, o.user_id, o.allow, o.deny
                    \\    FROM app.overwrites AS o
                    \\    WHERE o.channel_id = $3::bigint
                    \\    RETURNING 1
                    \\)
                    \\SELECT (SELECT count(*) FROM synced);
                , &.{
                    &id_param,
                    &guild_id_param,
                    &parent_id_param,
                    &kind_param,
                    this.payload.name.ptr,
                    topic.ptr,
                }, &.{
                    id_param.len,
                    guild_id_param.len,
                    parent_id_param.len,
                    kind_param.len,
                    @intCast(this.payload.name.len),
                    @intCast(topic.len),
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
                        SCOPE.err("Create failed to send query: {s}", .{this.db.errorMessage()});

                        return .{ .err = err };
                    },
                    else => |res| return res.mapDiscard(Result),
                }
            } else {
                switch (this.db.sendQueryParams(
                    \\INSERT INTO app.channels (id, guild_id, parent_id, kind, name, topic)
                    \\VALUES ($1::bigint, $2::bigint, NULLIF($3::bigint, 0), $4::smallint, $5::text, NULLIF($6::text, ''));
                , &.{
                    &id_param,
                    &guild_id_param,
                    &parent_id_param,
                    &kind_param,
                    this.payload.name.ptr,
                    topic.ptr,
                }, &.{
                    id_param.len,
                    guild_id_param.len,
                    parent_id_param.len,
                    kind_param.len,
                    @intCast(this.payload.name.len),
                    @intCast(topic.len),
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
                        SCOPE.err("Create failed to send query: {s}", .{this.db.errorMessage()});

                        return .{ .err = err };
                    },
                    else => |res| return res.mapDiscard(Result),
                }
            }
        }

        while (this.state == .waiting) {
            if (this.db.isBusy()) {
                return .{ .pending = .db };
            }

            if (this.db.getResult()) |res| {
                defer res.deinit();

                const expected: pq.ExecStatusType = if (this.payload.parent_id != null)
                    pq.PGRES_TUPLES_OK
                else
                    pq.PGRES_COMMAND_OK;

                if (res.status() != expected) {
                    SCOPE.err("Create failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                continue;
            }

            return .ready;
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

pub const Get = struct {
    const Item = struct {
        guild_id: root.types.GuildId,
        parent_id: ?root.types.ChannelId,
        kind: root.types.ChannelKind,
        name: []const u8,
        topic: ?[]const u8,
        position: root.types.Position,
        last_message_id: ?root.types.MessageId,

        pub inline fn dupe(allocator: std.mem.Allocator, res: root.db.Result) !Item {
            const name = try res.readSliceDupe(allocator, 0, 3);
            errdefer allocator.free(name);

            const topic = try res.readSliceOptionalDupe(allocator, 0, 4);
            errdefer if (topic != null) allocator.free(topic.?);

            return .{
                .guild_id = res.readInt(root.types.GuildId, 0, 0),
                .parent_id = res.readIntOptional(root.types.ChannelId, 0, 1),
                .kind = res.readEnum(root.types.ChannelKind, 0, 2),
                .name = name,
                .topic = topic,
                .position = res.readInt(root.types.Position, 0, 5),
                .last_message_id = res.readIntOptional(root.types.MessageId, 0, 6),
            };
        }
    };

    pub const Result = ?Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Get, Result, anyerror);

    pub const Payload = struct {
        channel_id: root.types.ChannelId,
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
            const id_param = root.utils.intToArray(root.types.ChannelId, this.payload.channel_id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT c.guild_id, c.parent_id, c.kind, c.name, c.topic, c.position,
                \\       lm.last_message_id
                \\FROM app.channels c
                \\LEFT JOIN LATERAL (
                \\    SELECT m.id AS last_message_id
                \\    FROM app.messages m
                \\    WHERE m.channel_id = c.id
                \\      AND m.deleted_at IS NULL
                \\    ORDER BY m.id DESC
                \\    LIMIT 1
                \\) lm ON TRUE
                \\WHERE c.id = $1;
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

                std.debug.assert(res.nfields() >= 7);

                const item = Item.dupe(this.allocator, res) catch |err| {
                    SCOPE.err("Get failed to dupe result: {t}", .{err});

                    return .{ .err = err };
                };

                return .{
                    .ready = item,
                };
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

pub const Update = struct {
    pub const Result = bool;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Update, Result, anyerror);

    pub const Payload = struct {
        pub const TopicMode = enum(u16) {
            keep,
            /// '' becomes NULL
            set,
        };

        channel_id: root.types.ChannelId,
        name: []const u8,
        topic_mode: TopicMode,
        topic: []const u8,
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
            const id_param = root.utils.intToArray(root.types.ChannelId, this.payload.channel_id, .big);
            const topic_mode_param = root.utils.intToArray(u16, @intFromEnum(this.payload.topic_mode), .big);

            switch (this.db.sendQueryParams(
                \\UPDATE app.channels SET
                \\    name  = COALESCE(NULLIF($2::text, ''), name),
                \\    topic = CASE $3::smallint WHEN 0 THEN topic ELSE NULLIF($4::text, '') END
                \\WHERE id = $1::bigint
                \\RETURNING id;
            , &.{
                &id_param,
                this.payload.name.ptr,
                &topic_mode_param,
                this.payload.topic.ptr,
            }, &.{
                id_param.len,
                @intCast(this.payload.name.len),
                topic_mode_param.len,
                @intCast(this.payload.topic.len),
            }, &.{
                .binary,
                .binary,
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("Update failed to send query: {s}", .{this.db.errorMessage()});

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

                return .{ .ready = res.ntuples() != 0 };
            }

            return .{ .ready = false };
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

pub const Move = struct {
    pub const Result = bool;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Move, Result, anyerror);

    pub const Payload = struct {
        pub const ParentMode = enum(u16) {
            keep_parent = 0,
            move_to_root = 1,
            set_parent = 2,
        };

        channel_id: root.types.ChannelId,
        parent_mode: ParentMode,
        parent_id: root.types.ChannelId,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *Move = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const id_param = root.utils.intToArray(root.types.ChannelId, this.payload.channel_id, .big);
            const parent_mode_param = root.utils.intToArray(u16, @intFromEnum(this.payload.parent_mode), .big);
            const parent_id_param = root.utils.intToArray(root.types.ChannelId, this.payload.parent_id, .big);

            switch (this.db.sendQueryParams(
                \\UPDATE app.channels SET
                \\    parent_id = CASE $2::smallint WHEN 0 THEN parent_id
                \\                                  WHEN 1 THEN NULL
                \\                                  ELSE $3::bigint END
                \\WHERE id = $1::bigint
                \\RETURNING id;
            , &.{
                &id_param,
                &parent_mode_param,
                &parent_id_param,
            }, &.{
                id_param.len,
                parent_mode_param.len,
                parent_id_param.len,
            }, &.{
                .binary,
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("Move failed to send query: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("Move failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .{ .ready = res.ntuples() != 0 };
            }

            return .{ .ready = false };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *Move = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(
        db: *root.db.Connection,
        payload: Payload,
    ) Move {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *Move) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// Assign dense positions 0..K-1 to the channels of one parent scope (a
/// category, or the root when `parent_id` is null) following the given order.
/// `ids_csv` is a comma-separated list of decimal channel ids in the target
/// order (validated by the caller).
pub const Reorder = struct {
    pub const Result = void;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Reorder, Result, anyerror);

    pub const Payload = struct {
        guild_id: root.types.GuildId,
        /// `null` = the root scope (categories + root channels)
        parent_id: ?root.types.ChannelId,
        ids_csv: []const u8,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *Reorder = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const guild_id_param = root.utils.intToArray(root.types.GuildId, this.payload.guild_id, .big);
            const parent_id_param = if (this.payload.parent_id) |parent_id|
                root.utils.intToArray(root.types.ChannelId, parent_id, .big)
            else
                null;

            switch (this.db.sendQueryParams(
                \\UPDATE app.channels AS c
                \\SET position = (t.ord - 1)::smallint
                \\FROM unnest(string_to_array($3::text, ',')) WITH ORDINALITY AS t(id, ord)
                \\WHERE c.guild_id = $1::bigint
                \\  AND c.parent_id IS NOT DISTINCT FROM $2::bigint
                \\  AND c.id = t.id::bigint;
            , &.{
                &guild_id_param,
                if (parent_id_param != null) &parent_id_param.? else null,
                this.payload.ids_csv.ptr,
            }, &.{
                guild_id_param.len,
                if (parent_id_param != null) parent_id_param.?.len else 0,
                @intCast(this.payload.ids_csv.len),
            }, &.{
                .binary,
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("Reorder failed to send: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("Reorder failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .ready;
            }

            return .ready;
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *Reorder = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) Reorder {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *Reorder) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const Delete = struct {
    pub const Result = bool;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Delete, Result, anyerror);

    pub const Payload = struct {
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
        const this: *Delete = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const id_param = root.utils.intToArray(root.types.ChannelId, this.payload.channel_id, .big);

            switch (this.db.sendQueryParams(
                \\DELETE FROM app.channels WHERE id = $1::bigint RETURNING id;
            , &.{&id_param}, &.{id_param.len}, &.{.binary}, .binary)) {
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

                return .{ .ready = res.ntuples() != 0 };
            }

            return .{ .ready = false };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *Delete = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(
        db: *root.db.Connection,
        payload: Payload,
    ) Delete {
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

pub const GetMessages = struct {
    pub const Result = root.repo.types.Message;

    pub const Stream = root.task.Stream(Result, anyerror);
    pub const Lazy = root.task.LazyStream(GetMessages, Result, anyerror);

    pub const Mode = union(enum) {
        around: root.types.MessageId,
        before: root.types.MessageId,
        after: root.types.MessageId,
        last,
    };

    pub const Payload = struct {
        channel_id: root.types.ChannelId,
        limit: usize,
        mode: Mode,
        /// Caller whose per-reaction `me` flag is computed.
        user_id: root.types.UserId,
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

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,
    reverse: bool = false,

    fn poll(ctx: *anyopaque) Stream.PollT {
        const this: *GetMessages = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const channel_id_param = root.utils.intToArray(root.types.ChannelId, this.payload.channel_id, .big);
            const limit_param = root.utils.intToArray(usize, this.payload.limit, .big);
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);

            switch (this.payload.mode) {
                .last => {
                    switch (this.db.sendQueryParams(
                        \\SELECT id, author_id, content, created_at, reply_to_id, edited_at, embeds,
                        \\       (SELECT json_agg(json_build_object(
                        \\            'id', f.id::text,
                        \\            'name', f.name,
                        \\            'size', f.size,
                        \\            'content_type', f.content_type,
                        \\            'hash', f.hash
                        \\        ) ORDER BY ma.position)
                        \\        FROM app.message_attachments ma
                        \\        JOIN app.files f ON f.id = ma.file_id
                        \\        WHERE ma.message_id = app.messages.id) AS attachments,
                        \\       (SELECT json_agg(t.u::text ORDER BY t.ord)
                        \\        FROM unnest(mention_user_ids) WITH ORDINALITY AS t(u, ord)) AS mention_user_ids,
                        \\       (SELECT json_agg(t.r::text ORDER BY t.ord)
                        \\        FROM unnest(mention_role_ids) WITH ORDINALITY AS t(r, ord)) AS mention_role_ids,
                        \\       mention_everyone,
                        \\       pinned,
                        \\       webhook_id,
                        \\       channel_id
                        ++ reactionsAggregate(3, "app.messages.id") ++
                        \\FROM app.messages
                        \\WHERE channel_id = $1
                        \\  AND deleted_at IS NULL
                        \\ORDER BY id DESC
                        \\LIMIT $2;
                    , &.{
                        &channel_id_param,
                        &limit_param,
                        &user_id_param,
                    }, &.{
                        channel_id_param.len,
                        limit_param.len,
                        user_id_param.len,
                    }, &.{
                        .binary,
                        .binary,
                        .binary,
                    }, .binary)) {
                        .ready => this.state = .waiting,
                        .err => |err| {
                            SCOPE.err("GetMessages failed to send query: {s}", .{this.db.errorMessage()});

                            return .{ .err = err };
                        },
                        else => |res| return res.toStreamPoll().mapDiscard(Result),
                    }

                    this.reverse = true;
                },
                .before => |anchor| {
                    const anchor_param = root.utils.intToArray(root.types.MessageId, anchor, .big);

                    switch (this.db.sendQueryParams(
                        \\SELECT id, author_id, content, created_at, reply_to_id, edited_at, embeds,
                        \\       (SELECT json_agg(json_build_object(
                        \\            'id', f.id::text,
                        \\            'name', f.name,
                        \\            'size', f.size,
                        \\            'content_type', f.content_type,
                        \\            'hash', f.hash
                        \\        ) ORDER BY ma.position)
                        \\        FROM app.message_attachments ma
                        \\        JOIN app.files f ON f.id = ma.file_id
                        \\        WHERE ma.message_id = app.messages.id) AS attachments,
                        \\       (SELECT json_agg(t.u::text ORDER BY t.ord)
                        \\        FROM unnest(mention_user_ids) WITH ORDINALITY AS t(u, ord)) AS mention_user_ids,
                        \\       (SELECT json_agg(t.r::text ORDER BY t.ord)
                        \\        FROM unnest(mention_role_ids) WITH ORDINALITY AS t(r, ord)) AS mention_role_ids,
                        \\       mention_everyone,
                        \\       pinned,
                        \\       webhook_id,
                        \\       channel_id
                        ++ reactionsAggregate(4, "app.messages.id") ++
                        \\FROM app.messages
                        \\WHERE channel_id = $1
                        \\  AND deleted_at IS NULL
                        \\  AND id < $2
                        \\ORDER BY id DESC
                        \\LIMIT $3;
                    , &.{
                        &channel_id_param,
                        &anchor_param,
                        &limit_param,
                        &user_id_param,
                    }, &.{
                        channel_id_param.len,
                        anchor_param.len,
                        limit_param.len,
                        user_id_param.len,
                    }, &.{
                        .binary,
                        .binary,
                        .binary,
                        .binary,
                    }, .binary)) {
                        .ready => this.state = .waiting,
                        .err => |err| {
                            SCOPE.err("GetMessages failed to send query: {s}", .{this.db.errorMessage()});

                            return .{ .err = err };
                        },
                        else => |res| return res.toStreamPoll().mapDiscard(Result),
                    }

                    this.reverse = true;
                },
                .after => |anchor| {
                    const anchor_param = root.utils.intToArray(root.types.MessageId, anchor, .big);

                    switch (this.db.sendQueryParams(
                        \\SELECT id, author_id, content, created_at, reply_to_id, edited_at, embeds,
                        \\       (SELECT json_agg(json_build_object(
                        \\            'id', f.id::text,
                        \\            'name', f.name,
                        \\            'size', f.size,
                        \\            'content_type', f.content_type,
                        \\            'hash', f.hash
                        \\        ) ORDER BY ma.position)
                        \\        FROM app.message_attachments ma
                        \\        JOIN app.files f ON f.id = ma.file_id
                        \\        WHERE ma.message_id = app.messages.id) AS attachments,
                        \\       (SELECT json_agg(t.u::text ORDER BY t.ord)
                        \\        FROM unnest(mention_user_ids) WITH ORDINALITY AS t(u, ord)) AS mention_user_ids,
                        \\       (SELECT json_agg(t.r::text ORDER BY t.ord)
                        \\        FROM unnest(mention_role_ids) WITH ORDINALITY AS t(r, ord)) AS mention_role_ids,
                        \\       mention_everyone,
                        \\       pinned,
                        \\       webhook_id,
                        \\       channel_id
                        ++ reactionsAggregate(4, "app.messages.id") ++
                        \\FROM app.messages
                        \\WHERE channel_id = $1
                        \\  AND deleted_at IS NULL
                        \\  AND id > $2
                        \\ORDER BY id ASC
                        \\LIMIT $3;
                    , &.{
                        &channel_id_param,
                        &anchor_param,
                        &limit_param,
                        &user_id_param,
                    }, &.{
                        channel_id_param.len,
                        anchor_param.len,
                        limit_param.len,
                        user_id_param.len,
                    }, &.{
                        .binary,
                        .binary,
                        .binary,
                        .binary,
                    }, .binary)) {
                        .ready => this.state = .waiting,
                        .err => |err| {
                            SCOPE.err("GetMessages failed to send query: {s}", .{this.db.errorMessage()});

                            return .{ .err = err };
                        },
                        else => |res| return res.toStreamPoll().mapDiscard(Result),
                    }
                },
                .around => |anchor| {
                    const anchor_param = root.utils.intToArray(root.types.MessageId, anchor, .big);

                    const before_count = (this.payload.limit + 1) / 2;
                    const after_count = this.payload.limit / 2;

                    const before_count_param = root.utils.intToArray(usize, before_count, .big);
                    const after_count_param = root.utils.intToArray(usize, after_count, .big);

                    switch (this.db.sendQueryParams(
                        \\WITH before AS (
                        \\    SELECT id, author_id, content, created_at, reply_to_id, edited_at, embeds,
                        \\           (SELECT json_agg(json_build_object(
                        \\                'id', f.id::text,
                        \\                'name', f.name,
                        \\                'size', f.size,
                        \\                'content_type', f.content_type,
                        \\                'hash', f.hash
                        \\            ) ORDER BY ma.position)
                        \\            FROM app.message_attachments ma
                        \\            JOIN app.files f ON f.id = ma.file_id
                        \\            WHERE ma.message_id = app.messages.id) AS attachments,
                        \\           (SELECT json_agg(t.u::text ORDER BY t.ord)
                        \\            FROM unnest(mention_user_ids) WITH ORDINALITY AS t(u, ord)) AS mention_user_ids,
                        \\           (SELECT json_agg(t.r::text ORDER BY t.ord)
                        \\            FROM unnest(mention_role_ids) WITH ORDINALITY AS t(r, ord)) AS mention_role_ids,
                        \\           mention_everyone,
                        \\           pinned,
                        \\           webhook_id,
                        \\           channel_id
                        ++ reactionsAggregate(5, "app.messages.id") ++
                        \\    FROM app.messages
                        \\    WHERE channel_id = $1
                        \\      AND deleted_at IS NULL
                        \\      AND id <= $2
                        \\    ORDER BY id DESC LIMIT $3
                        \\),
                        \\after AS (
                        \\    SELECT id, author_id, content, created_at, reply_to_id, edited_at, embeds,
                        \\           (SELECT json_agg(json_build_object(
                        \\                'id', f.id::text,
                        \\                'name', f.name,
                        \\                'size', f.size,
                        \\                'content_type', f.content_type,
                        \\                'hash', f.hash
                        \\            ) ORDER BY ma.position)
                        \\            FROM app.message_attachments ma
                        \\            JOIN app.files f ON f.id = ma.file_id
                        \\            WHERE ma.message_id = app.messages.id) AS attachments,
                        \\           (SELECT json_agg(t.u::text ORDER BY t.ord)
                        \\            FROM unnest(mention_user_ids) WITH ORDINALITY AS t(u, ord)) AS mention_user_ids,
                        \\           (SELECT json_agg(t.r::text ORDER BY t.ord)
                        \\            FROM unnest(mention_role_ids) WITH ORDINALITY AS t(r, ord)) AS mention_role_ids,
                        \\           mention_everyone,
                        \\           pinned,
                        \\           webhook_id,
                        \\           channel_id
                        ++ reactionsAggregate(5, "app.messages.id") ++
                        \\    FROM app.messages
                        \\    WHERE channel_id = $1
                        \\      AND deleted_at IS NULL
                        \\      AND id > $2
                        \\    ORDER BY id ASC LIMIT $4
                        \\)
                        \\SELECT id, author_id, content, created_at, reply_to_id, edited_at, embeds, attachments,
                        \\       mention_user_ids, mention_role_ids, mention_everyone, pinned, webhook_id, channel_id, reactions
                        \\FROM before
                        \\UNION ALL
                        \\SELECT id, author_id, content, created_at, reply_to_id, edited_at, embeds, attachments,
                        \\       mention_user_ids, mention_role_ids, mention_everyone, pinned, webhook_id, channel_id, reactions
                        \\FROM after
                        \\ORDER BY id ASC;
                    , &.{
                        &channel_id_param,
                        &anchor_param,
                        &before_count_param,
                        &after_count_param,
                        &user_id_param,
                    }, &.{
                        channel_id_param.len,
                        anchor_param.len,
                        before_count_param.len,
                        after_count_param.len,
                        user_id_param.len,
                    }, &.{
                        .binary,
                        .binary,
                        .binary,
                        .binary,
                        .binary,
                    }, .binary)) {
                        .ready => this.state = .waiting,
                        .err => |err| {
                            SCOPE.err("GetMessages failed to send query: {s}", .{this.db.errorMessage()});

                            return .{ .err = err };
                        },
                        else => |res| return res.toStreamPoll().mapDiscard(Result),
                    }
                },
            }
        }

        while (this.state == .waiting or this.state == .yielding) {
            if (this.state == .waiting) {
                if (this.db.isBusy()) {
                    return .{ .pending = .db };
                }

                if (this.db.getResult()) |res| {
                    if (res.status() != pq.PGRES_TUPLES_OK) {
                        SCOPE.err("GetMessages failed: {s}", .{res.errorMessage()});
                        res.deinit();

                        return .{ .err = error.PGError };
                    }

                    this.state = .{
                        .yielding = .{
                            .res = res,
                            .reverse = this.reverse,
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

                const idx = if (yield.reverse)
                    total - 1 - yield.pos
                else
                    yield.pos;

                std.debug.assert(res.nfields() >= 15);

                const edited_at = if (res.readIntOptional(u64, idx, 5)) |edited_at|
                    @divFloor(edited_at + 946684800000000, 1000)
                else
                    null;

                const item: root.repo.types.Message = .{
                    .id = res.readInt(root.types.MessageId, idx, 0),
                    .channel_id = res.readInt(root.types.ChannelId, idx, 13),
                    .author_id = res.readIntOptional(root.types.UserId, idx, 1),
                    .content = res.readString(idx, 2),
                    .created_at = @divFloor(res.readInt(u64, idx, 3) + 946684800000000, 1000),
                    .reply_to_id = res.readIntOptional(root.types.MessageId, idx, 4),
                    .edited_at = edited_at,
                    .embeds = res.readStringOptional(idx, 6),
                    .attachments = res.readStringOptional(idx, 7),
                    .mention_user_ids = res.readStringOptional(idx, 8),
                    .mention_role_ids = res.readStringOptional(idx, 9),
                    .mention_everyone = res.readBool(idx, 10),
                    .pinned = res.readBool(idx, 11),
                    .webhook_id = res.readIntOptional(root.types.WebhookId, idx, 12),
                    .reactions = res.readStringOptional(idx, 14),
                };

                yield.pos += 1;

                return .{ .yielded = item };
            }
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetMessages = @ptrCast(@alignCast(ctx));

        if (this.state == .yielding) {
            this.state.yielding.res.deinit();
        }

        this.db.release();
    }

    pub inline fn init(
        db: *root.db.Connection,
        payload: Payload,
    ) GetMessages {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn stream(this: *GetMessages) Stream {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const InsertMessage = struct {
    const Item = bool;

    pub const Result = Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(InsertMessage, Result, anyerror);

    pub const Payload = struct {
        id: root.types.MessageId,
        channel_id: root.types.ChannelId,
        author_id: ?root.types.UserId = null,
        webhook_id: ?root.types.WebhookId = null,
        content: []const u8,
        reply_to_id: ?root.types.MessageId,
        embeds: ?[]const u8,
        attachments: []const root.types.FileId = &.{},
        mention_everyone: bool = false,
        mention_user_ids: []const root.types.UserId = &.{},
        mention_role_ids: []const root.types.RoleId = &.{},
    };

    const State = enum {
        start,
        waiting,
    };

    allocator: std.mem.Allocator,
    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,
    attachments_buf: ?[]u8 = null,
    mention_users_buf: ?[]u8 = null,
    mention_roles_buf: ?[]u8 = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *InsertMessage = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            if (this.attachments_buf == null) {
                this.attachments_buf = root.db.encodeInt8Array(
                    root.types.FileId,
                    this.allocator,
                    this.payload.attachments,
                ) catch |err| {
                    SCOPE.err("InsertMessage failed to encode the attachments: {t}", .{err});

                    return .{ .err = err };
                };
            }

            if (this.mention_users_buf == null) {
                this.mention_users_buf = root.db.encodeInt8Array(
                    root.types.UserId,
                    this.allocator,
                    this.payload.mention_user_ids,
                ) catch |err| {
                    SCOPE.err("InsertMessage failed to encode the mention users: {t}", .{err});

                    return .{ .err = err };
                };
            }

            if (this.mention_roles_buf == null) {
                this.mention_roles_buf = root.db.encodeInt8Array(
                    root.types.RoleId,
                    this.allocator,
                    this.payload.mention_role_ids,
                ) catch |err| {
                    SCOPE.err("InsertMessage failed to encode the mention roles: {t}", .{err});

                    return .{ .err = err };
                };
            }

            const id_param = root.utils.intToArray(root.types.MessageId, this.payload.id, .big);
            const channel_id_param = root.utils.intToArray(root.types.ChannelId, this.payload.channel_id, .big);
            const author_id_param = if (this.payload.author_id) |author_id|
                root.utils.intToArray(root.types.UserId, author_id, .big)
            else
                null;
            const webhook_id_param = if (this.payload.webhook_id) |webhook_id|
                root.utils.intToArray(root.types.WebhookId, webhook_id, .big)
            else
                null;
            const reply_to_id_param = root.utils.intToArray(root.types.MessageId, this.payload.reply_to_id orelse 0, .big);
            const everyone_param = root.utils.intToArray(u8, if (this.payload.mention_everyone) 1 else 0, .big);
            const attachments = this.attachments_buf.?;
            const mention_users = this.mention_users_buf.?;
            const mention_roles = this.mention_roles_buf.?;

            switch (this.db.sendQueryParams(
                \\WITH
                \\channel AS (
                \\    SELECT id, guild_id FROM app.channels
                \\    WHERE id = $2
                \\),
                \\new_message AS (
                \\    INSERT INTO app.messages (id, channel_id, guild_id, author_id, webhook_id, content, reply_to_id, embeds,
                \\                              mention_everyone, mention_user_ids, mention_role_ids)
                \\    SELECT $1, c.id, c.guild_id, $3::bigint, $11::bigint, $4, NULLIF($5::bigint, 0), $6::text, $8::boolean, $9::bigint[], $10::bigint[]
                \\    FROM channel c
                \\    RETURNING id
                \\),
                \\new_attachments AS (
                \\    INSERT INTO app.message_attachments (message_id, file_id, position)
                \\    SELECT m.id, t.fid, t.ord - 1
                \\    FROM new_message m, unnest($7::bigint[]) WITH ORDINALITY AS t(fid, ord)
                \\)
                \\SELECT id FROM new_message;
            , &.{
                &id_param,
                &channel_id_param,
                if (author_id_param != null) &author_id_param.? else null,
                this.payload.content.ptr,
                &reply_to_id_param,
                if (this.payload.embeds) |embeds| embeds.ptr else null,
                attachments.ptr,
                &everyone_param,
                mention_users.ptr,
                mention_roles.ptr,
                if (webhook_id_param != null) &webhook_id_param.? else null,
            }, &.{
                id_param.len,
                channel_id_param.len,
                if (author_id_param != null) author_id_param.?.len else 0,
                @intCast(this.payload.content.len),
                reply_to_id_param.len,
                if (this.payload.embeds) |embeds| @intCast(embeds.len) else 0,
                @intCast(attachments.len),
                everyone_param.len,
                @intCast(mention_users.len),
                @intCast(mention_roles.len),
                if (webhook_id_param != null) webhook_id_param.?.len else 0,
            }, &.{
                .binary,
                .binary,
                .binary,
                .binary,
                .binary,
                .binary,
                .binary,
                .binary,
                .binary,
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("InsertMessage failed to send query: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("InsertMessage failed to add a message: {s}", .{res.errorMessage()});

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
        const this: *InsertMessage = @ptrCast(@alignCast(ctx));

        if (this.attachments_buf) |buf| {
            this.allocator.free(buf);
            this.attachments_buf = null;
        }

        if (this.mention_users_buf) |buf| {
            this.allocator.free(buf);
            this.mention_users_buf = null;
        }

        if (this.mention_roles_buf) |buf| {
            this.allocator.free(buf);
            this.mention_roles_buf = null;
        }

        this.db.release();
    }

    pub inline fn init(
        allocator: std.mem.Allocator,
        db: *root.db.Connection,
        message: Payload,
    ) InsertMessage {
        db.acquire();

        return .{
            .allocator = allocator,
            .db = db,
            .payload = message,
        };
    }

    pub inline fn task(this: *InsertMessage) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// Every overwrite of a guild, for embedding the full overwrite list in the
/// channel collection (`GET /guilds/{guild_id}/channels`). Unfiltered by the
/// caller: overwrites are metadata, readable by any authenticated user.
pub const GetAllOverwrites = struct {
    pub const Result = root.repo.types.Overwrite;

    pub const Stream = root.task.Stream(Result, anyerror);
    pub const Lazy = root.task.LazyStream(GetAllOverwrites, Result, anyerror);

    pub const Payload = struct {
        guild_id: root.types.GuildId,
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
        const this: *GetAllOverwrites = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const guild_id_param = root.utils.intToArray(root.types.GuildId, this.payload.guild_id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT target_type, target_id, allow, deny, channel_id
                \\FROM app.overwrites
                \\WHERE guild_id = $1
                \\ORDER BY channel_id, target_type, target_id;
            , &.{&guild_id_param}, &.{guild_id_param.len}, &.{.binary}, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("GetAllOverwrites failed to send: {s}", .{this.db.errorMessage()});

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
                        SCOPE.err("GetAllOverwrites failed: {s}", .{res.errorMessage()});
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

                std.debug.assert(res.nfields() >= 5);

                const ty = res.readEnum(root.types.Overwrites.Type, yield.pos, 0);
                const overwrites: root.types.Overwrites = .{
                    .allow = res.readPackedStruct(root.types.Permissions, yield.pos, 2),
                    .deny = res.readPackedStruct(root.types.Permissions, yield.pos, 3),
                };

                const item: root.repo.types.Overwrite = switch (ty) {
                    .role => .{
                        .channel_id = res.readInt(root.types.ChannelId, yield.pos, 4),
                        .target = .{ .role = res.readInt(root.types.RoleId, yield.pos, 1) },
                        .overwrites = overwrites,
                    },
                    .member => .{
                        .channel_id = res.readInt(root.types.ChannelId, yield.pos, 4),
                        .target = .{ .member = res.readInt(root.types.UserId, yield.pos, 1) },
                        .overwrites = overwrites,
                    },
                };

                yield.pos += 1;

                return .{ .yielded = item };
            }
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetAllOverwrites = @ptrCast(@alignCast(ctx));

        if (this.state == .yielding) {
            this.state.yielding.res.deinit();
        }

        this.db.release();
    }

    pub inline fn init(
        db: *root.db.Connection,
        payload: Payload,
    ) GetAllOverwrites {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn stream(this: *GetAllOverwrites) Stream {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};
