// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const pq = @import("pq");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.repo_messages);

pub const IsExists = struct {
    const Item = struct {
        guild_id: root.types.GuildId,
        channel_id: root.types.ChannelId,
        author_id: ?root.types.UserId,
        webhook_id: ?root.types.WebhookId,
    };

    pub const Result = ?Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(IsExists, Result, anyerror);

    pub const Payload = struct {
        id: root.types.MessageId,
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
            const id_param = root.utils.intToArray(root.types.MessageId, this.payload.id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT c.guild_id,
                \\       m.channel_id,
                \\       m.author_id,
                \\       m.webhook_id
                \\FROM app.messages m
                \\JOIN app.channels c ON c.id = m.channel_id
                \\WHERE m.id = $1
                \\  AND m.deleted_at IS NULL;
            , &.{&id_param}, &.{id_param.len}, &.{.binary}, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("IsExists failed to send: {t}", .{err});

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

                std.debug.assert(res.nfields() >= 4);

                const item: Item = .{
                    .guild_id = res.readInt(root.types.GuildId, 0, 0),
                    .channel_id = res.readInt(root.types.ChannelId, 0, 1),
                    .author_id = res.readIntOptional(root.types.UserId, 0, 2),
                    .webhook_id = res.readIntOptional(root.types.WebhookId, 0, 3),
                };

                return .{ .ready = item };
            }

            return .{ .ready = null };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *IsExists = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) IsExists {
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

pub const Get = struct {
    const Item = struct {
        guild_id: root.types.GuildId,
        channel_id: root.types.ChannelId,
        author_id: ?root.types.UserId,
        webhook_id: ?root.types.WebhookId,
        content: []const u8,
        created_at: u64,
        reply_to_id: ?root.types.MessageId,
        edited_at: ?u64,
        embeds: ?[]const u8,
        /// Comma-joined attachment file ids, ordered by position; null when none.
        attachments: ?[]const u8,
        mention_everyone: bool,
        /// JSON array of user ids (decimal strings) in mention order; null when
        /// the message mentions nobody.
        mention_user_ids: ?[]const u8,
        /// JSON array of role ids (decimal strings) in mention order; null when
        /// the message mentions no roles.
        mention_role_ids: ?[]const u8,
        pinned: bool,
        /// JSON array of aggregated reactions (caller-specific `me`); null when
        /// the message has none.
        reactions: ?[]const u8,

        pub inline fn dupe(allocator: std.mem.Allocator, res: root.db.Result) !Item {
            const content = try res.readSliceDupe(allocator, 0, 3);
            errdefer allocator.free(content);

            const embeds = try res.readSliceOptionalDupe(allocator, 0, 7);
            errdefer if (embeds) |value| allocator.free(value);

            const attachments = try res.readSliceOptionalDupe(allocator, 0, 8);
            errdefer if (attachments) |value| allocator.free(value);

            const mention_user_ids = try res.readSliceOptionalDupe(allocator, 0, 9);
            errdefer if (mention_user_ids) |value| allocator.free(value);

            const mention_role_ids = try res.readSliceOptionalDupe(allocator, 0, 10);
            errdefer if (mention_role_ids) |value| allocator.free(value);

            const reactions = try res.readSliceOptionalDupe(allocator, 0, 14);
            errdefer if (reactions) |value| allocator.free(value);

            const edited_at = if (res.readIntOptional(u64, 0, 6)) |edited_at|
                @divFloor(edited_at + 946684800000000, 1000)
            else
                null;

            return .{
                .guild_id = res.readInt(root.types.GuildId, 0, 0),
                .channel_id = res.readInt(root.types.ChannelId, 0, 1),
                .author_id = res.readIntOptional(root.types.UserId, 0, 2),
                .webhook_id = res.readIntOptional(root.types.WebhookId, 0, 13),
                .content = content,
                .created_at = @divFloor((res.readInt(u64, 0, 4) + 946684800000000), 1000),
                .reply_to_id = res.readIntOptional(root.types.MessageId, 0, 5),
                .edited_at = edited_at,
                .embeds = embeds,
                .attachments = attachments,
                .mention_everyone = res.readBool(0, 11),
                .mention_user_ids = mention_user_ids,
                .mention_role_ids = mention_role_ids,
                .pinned = res.readBool(0, 12),
                .reactions = reactions,
            };
        }
    };

    pub const Result = ?Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Get, Result, anyerror);

    pub const Payload = struct {
        id: root.types.MessageId,
        /// Caller whose per-reaction `me` flag is computed.
        me_user_id: root.types.UserId,
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
            const id_param = root.utils.intToArray(root.types.MessageId, this.payload.id, .big);
            const me_user_id_param = root.utils.intToArray(root.types.UserId, this.payload.me_user_id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT c.guild_id,
                \\       m.channel_id,
                \\       m.author_id,
                \\       m.content,
                \\       m.created_at,
                \\       m.reply_to_id,
                \\       m.edited_at,
                \\       m.embeds,
                \\       (SELECT json_agg(json_build_object(
                \\            'id', f.id::text,
                \\            'name', f.name,
                \\            'size', f.size,
                \\            'content_type', f.content_type,
                \\            'hash', f.hash
                \\        ) ORDER BY ma.position)
                \\        FROM app.message_attachments ma
                \\        JOIN app.files f ON f.id = ma.file_id
                \\        WHERE ma.message_id = m.id) AS attachments,
                \\       (SELECT json_agg(t.u::text ORDER BY t.ord)
                \\        FROM unnest(m.mention_user_ids) WITH ORDINALITY AS t(u, ord)) AS mention_user_ids,
                \\       (SELECT json_agg(t.r::text ORDER BY t.ord)
                \\        FROM unnest(m.mention_role_ids) WITH ORDINALITY AS t(r, ord)) AS mention_role_ids,
                \\       m.mention_everyone,
                \\       m.pinned,
                \\       m.webhook_id
                ++ root.repo.channels.reactionsAggregate(2, "m.id") ++
                \\FROM app.messages m
                \\JOIN app.channels c ON c.id = m.channel_id
                \\WHERE m.id = $1
                \\  AND m.deleted_at IS NULL;
            , &.{
                &id_param,
                &me_user_id_param,
            }, &.{
                id_param.len,
                me_user_id_param.len,
            }, &.{
                .binary,
                .binary,
            }, .binary)) {
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

                std.debug.assert(res.ntuples() <= 1);
                std.debug.assert(res.nfields() >= 15);

                const item = Item.dupe(this.allocator, res) catch |err| {
                    SCOPE.err("Get failed to dupe: {t}", .{err});

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

/// Reads one live message in the wire-shaped row consumed by
/// `route.types.Message.fromRepo`. Unlike `repo.channels.GetMessages` the row
/// is returned (not streamed), so every owned field is duplicated into
/// `allocator` by `root.repo.types.Message.read`.
pub const GetOne = struct {
    pub const Result = ?root.repo.types.Message;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(GetOne, Result, anyerror);

    pub const Payload = struct {
        id: root.types.MessageId,
        /// Caller whose per-reaction `me` flag is computed; 0 for webhook
        /// messages (no author).
        me_user_id: root.types.UserId,
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
        const this: *GetOne = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const id_param = root.utils.intToArray(root.types.MessageId, this.payload.id, .big);
            const me_user_id_param = root.utils.intToArray(root.types.UserId, this.payload.me_user_id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT m.id,
                \\       m.author_id,
                \\       m.content,
                \\       m.created_at,
                \\       m.reply_to_id,
                \\       m.edited_at,
                \\       m.embeds,
                \\       (SELECT json_agg(json_build_object(
                \\            'id', f.id::text,
                \\            'name', f.name,
                \\            'size', f.size,
                \\            'content_type', f.content_type,
                \\            'hash', f.hash
                \\        ) ORDER BY ma.position)
                \\        FROM app.message_attachments ma
                \\        JOIN app.files f ON f.id = ma.file_id
                \\        WHERE ma.message_id = m.id) AS attachments,
                \\       (SELECT json_agg(t.u::text ORDER BY t.ord)
                \\        FROM unnest(m.mention_user_ids) WITH ORDINALITY AS t(u, ord)) AS mention_user_ids,
                \\       (SELECT json_agg(t.r::text ORDER BY t.ord)
                \\        FROM unnest(m.mention_role_ids) WITH ORDINALITY AS t(r, ord)) AS mention_role_ids,
                \\       m.mention_everyone,
                \\       m.pinned,
                \\       m.webhook_id,
                \\       m.channel_id
                ++ root.repo.channels.reactionsAggregate(2, "m.id") ++
                \\FROM app.messages m
                \\WHERE m.id = $1
                \\  AND m.deleted_at IS NULL;
            , &.{
                &id_param,
                &me_user_id_param,
            }, &.{
                id_param.len,
                me_user_id_param.len,
            }, &.{
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("GetOne failed to send query: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("GetOne failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                if (res.ntuples() == 0) {
                    return .{ .ready = null };
                }

                std.debug.assert(res.nfields() >= 15);

                const item = root.repo.types.Message.read(this.allocator, res, 0) catch |err| {
                    SCOPE.err("GetOne failed to read: {t}", .{err});

                    return .{ .err = err };
                };

                return .{ .ready = item };
            }

            return .{ .ready = null };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetOne = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(
        allocator: std.mem.Allocator,
        db: *root.db.Connection,
        payload: Payload,
    ) GetOne {
        db.acquire();

        return .{
            .allocator = allocator,
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *GetOne) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const SoftDelete = struct {
    const Item = void;

    pub const Result = Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(SoftDelete, Result, anyerror);

    pub const Payload = struct {
        id: root.types.MessageId,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *SoftDelete = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const id_param = root.utils.intToArray(root.types.MessageId, this.payload.id, .big);

            switch (this.db.sendQueryParams(
                \\WITH deleted AS (
                \\    UPDATE app.messages
                \\    SET content = '', embeds = NULL, author_id = NULL, webhook_id = NULL, deleted_at = now(), pinned = false,
                \\        mention_everyone = false, mention_user_ids = '{}'::bigint[], mention_role_ids = '{}'::bigint[]
                \\    WHERE id = $1
                \\      AND deleted_at IS NULL
                \\)
                \\DELETE FROM app.message_attachments WHERE message_id = $1;
            , &.{&id_param}, &.{id_param.len}, &.{.binary}, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("SoftDelete failed to send: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("SoftDelete failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .ready;
            }

            return .ready;
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *SoftDelete = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) SoftDelete {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *SoftDelete) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const Edit = struct {
    const Item = u64;

    pub const Result = ?Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Edit, Result, anyerror);

    pub const Payload = struct {
        pub const EmbedsMode = enum(u16) {
            keep,
            /// `null` clears the column.
            set,
        };

        id: root.types.MessageId,
        content: []const u8,
        embeds_mode: EmbedsMode,
        embeds: ?[]const u8,
        /// Replaces the message's attachment set; `content` is the source of
        /// truth and this is derived from it by the caller.
        attachments: []const root.types.FileId = &.{},
        /// Mentions are always recomputed from the new content on edit; the
        /// stored fields never go stale relative to `content`.
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
        const this: *Edit = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            if (this.attachments_buf == null) {
                this.attachments_buf = root.db.encodeInt8Array(
                    root.types.FileId,
                    this.allocator,
                    this.payload.attachments,
                ) catch |err| {
                    SCOPE.err("Edit failed to encode the attachments: {t}", .{err});

                    return .{ .err = err };
                };
            }

            if (this.mention_users_buf == null) {
                this.mention_users_buf = root.db.encodeInt8Array(
                    root.types.UserId,
                    this.allocator,
                    this.payload.mention_user_ids,
                ) catch |err| {
                    SCOPE.err("Edit failed to encode the mention users: {t}", .{err});

                    return .{ .err = err };
                };
            }

            if (this.mention_roles_buf == null) {
                this.mention_roles_buf = root.db.encodeInt8Array(
                    root.types.RoleId,
                    this.allocator,
                    this.payload.mention_role_ids,
                ) catch |err| {
                    SCOPE.err("Edit failed to encode the mention roles: {t}", .{err});

                    return .{ .err = err };
                };
            }

            const id_param = root.utils.intToArray(root.types.MessageId, this.payload.id, .big);
            const embeds_mode_param = root.utils.intToArray(u16, @intFromEnum(this.payload.embeds_mode), .big);
            const everyone_param = root.utils.intToArray(u8, if (this.payload.mention_everyone) 1 else 0, .big);
            const attachments = this.attachments_buf.?;
            const mention_users = this.mention_users_buf.?;
            const mention_roles = this.mention_roles_buf.?;

            switch (this.db.sendQueryParams(
                \\WITH edited AS (
                \\    UPDATE app.messages
                \\    SET content           = $2,
                \\        embeds            = CASE $3::smallint WHEN 0 THEN embeds ELSE $4::text END,
                \\        mention_everyone  = $5::boolean,
                \\        mention_user_ids  = $6::bigint[],
                \\        mention_role_ids  = $7::bigint[],
                \\        edited_at         = now()
                \\    WHERE id = $1
                \\      AND deleted_at IS NULL
                \\    RETURNING edited_at
                \\),
                \\del AS (
                \\    DELETE FROM app.message_attachments
                \\    WHERE message_id = $1
                \\      AND file_id <> ALL($8::bigint[])
                \\),
                \\ins AS (
                \\    INSERT INTO app.message_attachments (message_id, file_id, position)
                \\    SELECT $1, t.fid, t.ord - 1
                \\    FROM unnest($8::bigint[]) WITH ORDINALITY AS t(fid, ord)
                \\    ON CONFLICT (message_id, file_id) DO UPDATE SET position = EXCLUDED.position
                \\)
                \\SELECT edited_at FROM edited;
            , &.{
                &id_param,
                this.payload.content.ptr,
                &embeds_mode_param,
                if (this.payload.embeds) |embeds| embeds.ptr else null,
                &everyone_param,
                mention_users.ptr,
                mention_roles.ptr,
                attachments.ptr,
            }, &.{
                id_param.len,
                @intCast(this.payload.content.len),
                embeds_mode_param.len,
                if (this.payload.embeds) |embeds| @intCast(embeds.len) else 0,
                everyone_param.len,
                @intCast(mention_users.len),
                @intCast(mention_roles.len),
                @intCast(attachments.len),
            }, &.{
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
                    SCOPE.err("Edit failed to send: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("Edit failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                if (res.ntuples() == 0) {
                    return .{ .ready = null };
                }

                const edited_at = @divFloor(res.readInt(u64, 0, 0) + 946684800000000, 1000);

                return .{ .ready = edited_at };
            }

            return .{ .ready = null };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *Edit = @ptrCast(@alignCast(ctx));

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
        payload: Payload,
    ) Edit {
        db.acquire();

        return .{
            .allocator = allocator,
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *Edit) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};
