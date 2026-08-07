// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const pq = @import("pq");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.repo_webhooks);

// Per-channel webhooks. Management is gated purely by
// the channel's `create_webhooks` / `modify_webhooks` / `delete_webhooks`
// permissions. The plaintext execute token is shown once on create; at rest
// only its sha256 (`token_hash`) is kept. Deletion is a soft-delete so messages
// posted by the webhook keep their attribution; management treats a deleted
// row as gone, but `Get` (the public attribution read) still returns it.

const COLUMNS =
    \\SELECT id, guild_id, channel_id, name, avatar_hash, created_at, deleted_at
    \\
;

/// Inserts a webhook if the channel is under `limit` live webhooks. A 0-row
/// result means either the limit was reached or the channel vanished; the
/// caller decides the status (channel existence is already checked upstream).
pub const Create = struct {
    pub const Result = bool;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Create, Result, anyerror);

    pub const Payload = struct {
        id: root.types.WebhookId,
        channel_id: root.types.ChannelId,
        name: []const u8,
        token_hash: [32]u8,
        limit: usize,
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
            const id_param = root.utils.intToArray(root.types.WebhookId, this.payload.id, .big);
            const channel_id_param = root.utils.intToArray(root.types.ChannelId, this.payload.channel_id, .big);
            const limit_param = root.utils.intToArray(usize, this.payload.limit, .big);

            switch (this.db.sendQueryParams(
                \\WITH inserted AS (
                \\    INSERT INTO app.webhooks (id, guild_id, channel_id, name, token_hash)
                \\    SELECT $1, c.guild_id, c.id, $3, $4
                \\    FROM app.channels c
                \\    WHERE c.id = $2
                \\      AND (SELECT count(*) FROM app.webhooks w
                \\           WHERE w.channel_id = c.id
                \\             AND w.deleted_at IS NULL) < $5
                \\    RETURNING id
                \\)
                \\SELECT id FROM inserted;
            , &.{
                &id_param,
                &channel_id_param,
                this.payload.name.ptr,
                &this.payload.token_hash,
                &limit_param,
            }, &.{
                id_param.len,
                channel_id_param.len,
                @intCast(this.payload.name.len),
                @intCast(this.payload.token_hash.len),
                limit_param.len,
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

                if (res.status() != pq.PGRES_TUPLES_OK) {
                    SCOPE.err("Create failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .{ .ready = res.ntuples() != 0 };
            }

            return .{ .ready = false };
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

/// Live (non-deleted) webhooks of a channel, ordered by id.
pub const ListForChannel = struct {
    pub const Result = []const root.repo.types.Webhook;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(ListForChannel, Result, anyerror);

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
    items: std.ArrayList(root.repo.types.Webhook) = .empty,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *ListForChannel = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const channel_id_param = root.utils.intToArray(root.types.ChannelId, this.payload.channel_id, .big);

            switch (this.db.sendQueryParams(COLUMNS ++
                \\FROM app.webhooks
                \\WHERE channel_id = $1
                \\  AND deleted_at IS NULL
                \\ORDER BY id ASC;
            , &.{&channel_id_param}, &.{channel_id_param.len}, &.{.binary}, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("ListForChannel failed to send query: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("ListForChannel failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                std.debug.assert(res.nfields() >= 7);

                for (0..res.ntuples()) |i| {
                    const item = root.repo.types.Webhook.read(this.allocator, res, i) catch |err| {
                        SCOPE.err("ListForChannel failed to read a row: {t}", .{err});

                        return .{ .err = err };
                    };

                    this.items.append(this.allocator, item) catch |err| {
                        item.deinit(this.allocator);

                        SCOPE.err("ListForChannel failed to grow the list: {t}", .{err});

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
        const this: *ListForChannel = @ptrCast(@alignCast(ctx));

        for (this.items.items) |item| {
            item.deinit(this.allocator);
        }

        this.items.deinit(this.allocator);

        this.db.release();
    }

    pub inline fn init(
        allocator: std.mem.Allocator,
        db: *root.db.Connection,
        payload: Payload,
    ) ListForChannel {
        db.acquire();

        return .{
            .allocator = allocator,
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *ListForChannel) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// A webhook by id, **including** soft-deleted rows: the public attribution
/// read keeps rendering name/avatar for messages posted by a deleted webhook.
/// Management endpoints use `GetLive` instead.
pub const Get = struct {
    pub const Result = ?root.repo.types.Webhook;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Get, Result, anyerror);

    pub const Payload = struct {
        id: root.types.WebhookId,
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
            const id_param = root.utils.intToArray(root.types.WebhookId, this.payload.id, .big);

            switch (this.db.sendQueryParams(COLUMNS ++
                \\FROM app.webhooks
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

                std.debug.assert(res.ntuples() <= 1);
                std.debug.assert(res.nfields() >= 7);

                const item = root.repo.types.Webhook.read(this.allocator, res, 0) catch |err| {
                    SCOPE.err("Get failed to read the row: {t}", .{err});

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

/// Reads the stored avatar bytes of a webhook, but only when the stored hash
/// matches `payload.hash`. Unlike the management endpoints this does **not**
/// filter soft-deleted rows: `GET /api/webhooks/{webhook_id}` keeps returning a
/// deleted webhook so its messages keep rendering, so the avatar must stay
/// resolvable too. `null` = no webhook/avatar or a hash mismatch.
pub const GetAvatar = struct {
    pub const Result = ?[]const u8;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(GetAvatar, Result, anyerror);

    pub const Payload = struct {
        id: root.types.WebhookId,
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
            const id_param = root.utils.intToArray(root.types.WebhookId, this.payload.id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT avatar_data
                \\FROM app.webhooks
                \\WHERE id = $1
                \\  AND avatar_hash = $2
                \\  AND avatar_data IS NOT NULL;
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

/// Resolves an execute token: the webhook must exist, not be soft-deleted and
/// its `token_hash` must match. Used by `POST /api/webhooks/{id}/{token}`.
pub const GetByToken = struct {
    pub const Result = ?root.repo.types.Webhook;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(GetByToken, Result, anyerror);

    pub const Payload = struct {
        id: root.types.WebhookId,
        token_hash: [32]u8,
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
        const this: *GetByToken = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const id_param = root.utils.intToArray(root.types.WebhookId, this.payload.id, .big);

            switch (this.db.sendQueryParams(COLUMNS ++
                \\FROM app.webhooks
                \\WHERE id = $1
                \\  AND token_hash = $2
                \\  AND deleted_at IS NULL;
            , &.{
                &id_param,
                &this.payload.token_hash,
            }, &.{
                id_param.len,
                @intCast(this.payload.token_hash.len),
            }, &.{
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("GetByToken failed to send query: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("GetByToken failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                if (res.ntuples() == 0) {
                    return .{ .ready = null };
                }

                std.debug.assert(res.ntuples() <= 1);
                std.debug.assert(res.nfields() >= 7);

                const item = root.repo.types.Webhook.read(this.allocator, res, 0) catch |err| {
                    SCOPE.err("GetByToken failed to read the row: {t}", .{err});

                    return .{ .err = err };
                };

                return .{ .ready = item };
            }

            return .{ .ready = null };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetByToken = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(
        allocator: std.mem.Allocator,
        db: *root.db.Connection,
        payload: Payload,
    ) GetByToken {
        db.acquire();

        return .{
            .allocator = allocator,
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *GetByToken) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// Renames a live webhook; a null `name` keeps the current one.
pub const Update = struct {
    pub const Result = bool;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Update, Result, anyerror);

    pub const Payload = struct {
        id: root.types.WebhookId,
        name: ?[]const u8 = null,
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
            const id_param = root.utils.intToArray(root.types.WebhookId, this.payload.id, .big);

            switch (this.db.sendQueryParams(
                \\UPDATE app.webhooks
                \\SET name = COALESCE($2::text, name)
                \\WHERE id = $1
                \\  AND deleted_at IS NULL
                \\RETURNING id;
            , &.{
                &id_param,
                if (this.payload.name) |name| name.ptr else null,
            }, &.{
                id_param.len,
                if (this.payload.name) |name| @intCast(name.len) else 0,
            }, &.{
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

    pub inline fn init(db: *root.db.Connection, payload: Payload) Update {
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

pub const SetAvatar = struct {
    pub const Result = bool;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(SetAvatar, Result, anyerror);

    pub const Payload = struct {
        id: root.types.WebhookId,
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
            const id_param = root.utils.intToArray(root.types.WebhookId, this.payload.id, .big);

            switch (this.db.sendQueryParams(
                \\UPDATE app.webhooks
                \\SET avatar_data = $2, avatar_hash = $3
                \\WHERE id = $1
                \\  AND deleted_at IS NULL
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
                    SCOPE.err("SetAvatar failed to send query: {s}", .{this.db.errorMessage()});

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

                return .{ .ready = res.ntuples() != 0 };
            }

            return .{ .ready = false };
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
    pub const Result = bool;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(ClearAvatar, Result, anyerror);

    pub const Payload = struct {
        id: root.types.WebhookId,
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
            const id_param = root.utils.intToArray(root.types.WebhookId, this.payload.id, .big);

            switch (this.db.sendQueryParams(
                \\UPDATE app.webhooks
                \\SET avatar_data = NULL, avatar_hash = NULL
                \\WHERE id = $1
                \\  AND deleted_at IS NULL
                \\RETURNING id;
            , &.{&id_param}, &.{id_param.len}, &.{.binary}, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("ClearAvatar failed to send query: {s}", .{this.db.errorMessage()});

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

                return .{ .ready = res.ntuples() != 0 };
            }

            return .{ .ready = false };
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

/// Soft-deletes a live webhook. Idempotent: a second call matches no row.
pub const SoftDelete = struct {
    pub const Result = bool;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(SoftDelete, Result, anyerror);

    pub const Payload = struct {
        id: root.types.WebhookId,
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
            const id_param = root.utils.intToArray(root.types.WebhookId, this.payload.id, .big);

            switch (this.db.sendQueryParams(
                \\UPDATE app.webhooks
                \\SET deleted_at = now()
                \\WHERE id = $1
                \\  AND deleted_at IS NULL
                \\RETURNING id;
            , &.{&id_param}, &.{id_param.len}, &.{.binary}, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("SoftDelete failed to send query: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("SoftDelete failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .{ .ready = res.ntuples() != 0 };
            }

            return .{ .ready = false };
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
