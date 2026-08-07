// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const pq = @import("pq");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.repo_notifications_fanout);

// Reads for the notification dispatcher: which users should be pushed for a
// newly created message, and the payload material for it.

/// Resolves the candidate recipients of a newly created message and their
/// effective notification settings. A user is a candidate when they are
/// explicitly mentioned, hold a mentioned role, or hold a push subscription
/// (the only users that can actually receive a push). The effective level
/// follows channel -> parent category -> guild; a candidate is returned only
/// when the effective level is not `nothing` and the message matches it:
/// `all_messages` (1) admits every message, while `only_mentions` (2) admits
/// only a direct mention, a non-suppressed role mention, or a non-suppressed
/// `@everyone`. The suppression flags gate only those mention kinds; they never
/// mute `all_messages`. `level` also defaults to `all_messages` when the user
/// has no settings row at all. A recipient is also dropped when the guild's
/// `push` toggle is off (`app.guild_notification_settings.push`, default true).
/// The author is always excluded.
///
/// `level` is the channel-level vocabulary (1 = all_messages, 2 = only_mentions,
/// 3 = nothing).
pub const ResolveRecipients = struct {
    pub const Item = struct {
        user_id: root.types.UserId,
        level: u16,
        suppress_everyone: bool,
        suppress_roles: bool,
        is_user_mention: bool,
        is_role_mention: bool,
    };

    pub const Result = []const Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(ResolveRecipients, Result, anyerror);

    pub const Payload = struct {
        user_ids: []const root.types.UserId,
        role_ids: []const root.types.RoleId,
        guild_id: root.types.GuildId,
        channel_id: root.types.ChannelId,
        /// Author to exclude from the recipients; null for a webhook message
        /// (no user author, so nobody is excluded).
        author_id: ?root.types.UserId = null,
        mention_everyone: bool,
        limit: usize,
    };

    const State = enum {
        start,
        waiting,
    };

    allocator: std.mem.Allocator,
    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,
    users_buf: ?[]u8 = null,
    roles_buf: ?[]u8 = null,
    items: std.ArrayList(Item) = .empty,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *ResolveRecipients = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            if (this.users_buf == null) {
                this.users_buf = root.db.encodeInt8Array(
                    root.types.UserId,
                    this.allocator,
                    this.payload.user_ids,
                ) catch |err| {
                    SCOPE.err("ResolveRecipients failed to encode the user ids: {t}", .{err});

                    return .{ .err = err };
                };
            }

            if (this.roles_buf == null) {
                this.roles_buf = root.db.encodeInt8Array(
                    root.types.RoleId,
                    this.allocator,
                    this.payload.role_ids,
                ) catch |err| {
                    SCOPE.err("ResolveRecipients failed to encode the role ids: {t}", .{err});

                    return .{ .err = err };
                };
            }

            const users = this.users_buf.?;
            const roles = this.roles_buf.?;

            const guild_id_param = root.utils.intToArray(root.types.GuildId, this.payload.guild_id, .big);
            const channel_id_param = root.utils.intToArray(root.types.ChannelId, this.payload.channel_id, .big);
            const author_id_param: ?[8]u8 = if (this.payload.author_id) |author_id|
                root.utils.intToArray(root.types.UserId, author_id, .big)
            else
                null;
            const mention_everyone_param = root.utils.intToArray(u8, if (this.payload.mention_everyone) 1 else 0, .big);
            const limit_param = root.utils.intToArray(i64, @intCast(this.payload.limit), .big);

            switch (this.db.sendQueryParams(
                \\WITH candidates AS (
                \\    SELECT u AS user_id
                \\    FROM unnest($1::bigint[]) AS u
                \\    WHERE EXISTS (
                \\        SELECT 1 FROM app.users x
                \\        WHERE x.id = u AND x.deleted_at IS NULL
                \\    )
                \\    UNION
                \\    SELECT mr.user_id
                \\    FROM app.member_roles mr
                \\    WHERE mr.role_id = ANY($2::bigint[])
                \\      AND mr.guild_id = $3::bigint
                \\    UNION
                \\    SELECT DISTINCT ps.user_id
                \\    FROM app.push_subscriptions ps
                \\    JOIN app.users x ON x.id = ps.user_id
                \\    WHERE x.deleted_at IS NULL
                \\),
                \\flags AS (
                \\    SELECT c.user_id,
                \\           (c.user_id = ANY($1::bigint[])) AS is_user_mention,
                \\           EXISTS (
                \\               SELECT 1 FROM app.member_roles mr
                \\               WHERE mr.user_id = c.user_id
                \\                 AND mr.role_id = ANY($2::bigint[])
                \\                 AND mr.guild_id = $3::bigint
                \\           ) AS is_role_mention
                \\    FROM candidates c
                \\),
                \\eff AS (
                \\    SELECT f.user_id,
                \\           f.is_user_mention,
                \\           f.is_role_mention,
                \\           (CASE
                \\               WHEN cs.level IS NOT NULL AND cs.level <> 0 THEN cs.level
                \\               WHEN ps.level IS NOT NULL AND ps.level <> 0 THEN ps.level
                \\               ELSE COALESCE(gs.level, 0) + 1
                \\           END)::smallint AS level,
                \\           COALESCE(gs.suppress_everyone, false) AS suppress_everyone,
                \\           COALESCE(gs.suppress_roles, false) AS suppress_roles,
                \\           COALESCE(gs.push, true) AS push
                \\    FROM flags f
                \\    LEFT JOIN app.channel_notification_settings cs
                \\        ON cs.user_id = f.user_id AND cs.channel_id = $4::bigint
                \\    LEFT JOIN app.channels parent
                \\        ON parent.id = (SELECT ch.parent_id FROM app.channels ch WHERE ch.id = $4::bigint)
                \\    LEFT JOIN app.channel_notification_settings ps
                \\        ON ps.user_id = f.user_id AND ps.channel_id = parent.id
                \\    LEFT JOIN app.guild_notification_settings gs
                \\        ON gs.user_id = f.user_id AND gs.guild_id = $3::bigint
                \\)
                \\SELECT e.user_id, e.level, e.suppress_everyone, e.suppress_roles,
                \\       e.is_user_mention, e.is_role_mention
                \\FROM eff e
                \\WHERE ($5::bigint IS NULL OR e.user_id <> $5::bigint)
                \\  AND e.level <> 3
                \\  AND e.push
                \\  AND (
                \\        e.level = 1
                \\     OR e.is_user_mention
                \\     OR (e.is_role_mention AND NOT e.suppress_roles)
                \\     OR ($6::boolean AND NOT e.suppress_everyone)
                \\  )
                \\ORDER BY e.is_user_mention DESC,
                \\         e.is_role_mention DESC,
                \\         ($6::boolean AND NOT e.suppress_everyone) DESC,
                \\         e.user_id
                \\LIMIT $7::bigint;
            , &.{
                users.ptr,
                roles.ptr,
                &guild_id_param,
                &channel_id_param,
                if (author_id_param != null) &author_id_param.? else null,
                &mention_everyone_param,
                &limit_param,
            }, &.{
                @intCast(users.len),
                @intCast(roles.len),
                guild_id_param.len,
                channel_id_param.len,
                if (author_id_param != null) author_id_param.?.len else 0,
                mention_everyone_param.len,
                limit_param.len,
            }, &.{
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
                    SCOPE.err("ResolveRecipients failed to send query: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("ResolveRecipients failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                std.debug.assert(res.nfields() >= 6);

                for (0..res.ntuples()) |i| {
                    this.items.append(this.allocator, .{
                        .user_id = res.readInt(root.types.UserId, i, 0),
                        .level = res.readInt(u16, i, 1),
                        .suppress_everyone = res.readBool(i, 2),
                        .suppress_roles = res.readBool(i, 3),
                        .is_user_mention = res.readBool(i, 4),
                        .is_role_mention = res.readBool(i, 5),
                    }) catch |err| {
                        SCOPE.err("ResolveRecipients failed to grow the list: {t}", .{err});

                        return .{ .err = err };
                    };
                }

                return .{ .ready = this.items.items };
            }

            return .{ .ready = &.{} };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *ResolveRecipients = @ptrCast(@alignCast(ctx));

        this.items.deinit(this.allocator);

        if (this.users_buf) |buf| {
            this.allocator.free(buf);
            this.users_buf = null;
        }

        if (this.roles_buf) |buf| {
            this.allocator.free(buf);
            this.roles_buf = null;
        }

        this.db.release();
    }

    pub inline fn init(
        allocator: std.mem.Allocator,
        db: *root.db.Connection,
        payload: Payload,
    ) ResolveRecipients {
        db.acquire();

        return .{
            .allocator = allocator,
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *ResolveRecipients) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// Material for the push payload: the (sanitized) message content, the channel
/// name, the author's display name and the author's avatar hash. The name and
/// avatar hash resolve to the user for a user message and to the webhook for a
/// webhook message. The slices are owned by the task and freed in `dispose`;
/// the dispatcher must consume them before disposing.
pub const GetMessageForPush = struct {
    pub const Item = struct {
        content: []const u8,
        channel_name: []const u8,
        author_name: []const u8,
        author_avatar_hash: ?[]const u8,
    };

    pub const Result = ?Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(GetMessageForPush, Result, anyerror);

    pub const Payload = struct {
        message_id: root.types.MessageId,
    };

    const State = enum {
        start,
        waiting,
    };

    allocator: std.mem.Allocator,
    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,
    content: ?[]const u8 = null,
    channel_name: ?[]const u8 = null,
    author_name: ?[]const u8 = null,
    author_avatar_hash: ?[]const u8 = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *GetMessageForPush = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const id_param = root.utils.intToArray(root.types.MessageId, this.payload.message_id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT m.content,
                \\       c.name,
                \\       COALESCE(NULLIF(u.display_name, ''), u.username, w.name, ''),
                \\       COALESCE(u.avatar_hash, w.avatar_hash)
                \\FROM app.messages m
                \\JOIN app.channels c ON c.id = m.channel_id
                \\LEFT JOIN app.users u ON u.id = m.author_id
                \\LEFT JOIN app.webhooks w ON w.id = m.webhook_id
                \\WHERE m.id = $1
                \\  AND m.deleted_at IS NULL;
            , &.{&id_param}, &.{id_param.len}, &.{.binary}, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("GetMessageForPush failed to send query: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("GetMessageForPush failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                if (res.ntuples() == 0) {
                    return .{ .ready = null };
                }

                std.debug.assert(res.nfields() >= 4);

                this.content = res.readSliceDupe(this.allocator, 0, 0) catch |err| {
                    SCOPE.err("GetMessageForPush failed to read 'content': {t}", .{err});

                    return .{ .err = err };
                };

                this.channel_name = res.readSliceDupe(this.allocator, 0, 1) catch |err| {
                    SCOPE.err("GetMessageForPush failed to read 'channel_name': {t}", .{err});

                    return .{ .err = err };
                };

                this.author_name = res.readSliceDupe(this.allocator, 0, 2) catch |err| {
                    SCOPE.err("GetMessageForPush failed to read 'author_name': {t}", .{err});

                    return .{ .err = err };
                };

                this.author_avatar_hash = res.readSliceOptionalDupe(this.allocator, 0, 3) catch |err| {
                    SCOPE.err("GetMessageForPush failed to read 'author_avatar_hash': {t}", .{err});

                    return .{ .err = err };
                };

                return .{
                    .ready = .{
                        .content = this.content.?,
                        .channel_name = this.channel_name.?,
                        .author_name = this.author_name.?,
                        .author_avatar_hash = this.author_avatar_hash,
                    },
                };
            }

            return .{ .ready = null };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetMessageForPush = @ptrCast(@alignCast(ctx));

        if (this.content) |value| {
            this.allocator.free(value);
            this.content = null;
        }

        if (this.channel_name) |value| {
            this.allocator.free(value);
            this.channel_name = null;
        }

        if (this.author_name) |value| {
            this.allocator.free(value);
            this.author_name = null;
        }

        if (this.author_avatar_hash) |value| {
            this.allocator.free(value);
            this.author_avatar_hash = null;
        }

        this.db.release();
    }

    pub inline fn init(
        allocator: std.mem.Allocator,
        db: *root.db.Connection,
        payload: Payload,
    ) GetMessageForPush {
        db.acquire();

        return .{
            .allocator = allocator,
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *GetMessageForPush) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};
