// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const pq = @import("pq");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.repo_push_subscriptions);

// Browser Web Push subscriptions. `endpoint` is an opaque URL; `endpoint_hash`
// is sha256(endpoint) and is the globally unique key: one browser profile owns
// one endpoint and is logged into one account at a time, so an endpoint belongs
// to exactly one user. Tokens are never normalized or length-limited in
// codepoints, only in bytes.

/// The caller's subscriptions for `GET /api/users/@me/push-subscriptions`. The
/// secrets (`p256dh`/`auth`) are deliberately not selected.
pub const ListOwn = struct {
    pub const Item = struct {
        id: root.types.PushSubscriptionId,
        endpoint: []const u8,
        created_at: u64,
    };

    pub const Result = []const Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(ListOwn, Result, anyerror);

    pub const Payload = struct {
        user_id: root.types.UserId,
    };

    const State = enum {
        start,
        waiting,
    };

    allocator: std.mem.Allocator,
    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,
    items: std.ArrayList(Item) = .empty,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *ListOwn = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT id, endpoint, created_at
                \\FROM app.push_subscriptions
                \\WHERE user_id = $1
                \\ORDER BY created_at ASC;
            , &.{&user_id_param}, &.{user_id_param.len}, &.{.binary}, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("ListOwn failed to send query: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("ListOwn failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                std.debug.assert(res.nfields() >= 3);

                for (0..res.ntuples()) |i| {
                    const endpoint = res.readSliceDupe(this.allocator, i, 1) catch |err| {
                        SCOPE.err("ListOwn failed to read 'endpoint': {t}", .{err});

                        return .{ .err = err };
                    };

                    this.items.append(this.allocator, .{
                        .id = res.readInt(root.types.PushSubscriptionId, i, 0),
                        .endpoint = endpoint,
                        .created_at = @divFloor(res.readInt(u64, i, 2) + 946684800000000, 1000),
                    }) catch |err| {
                        this.allocator.free(endpoint);

                        SCOPE.err("ListOwn failed to grow the list: {t}", .{err});

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
        const this: *ListOwn = @ptrCast(@alignCast(ctx));

        for (this.items.items) |item| {
            this.allocator.free(item.endpoint);
        }

        this.items.deinit(this.allocator);

        this.db.release();
    }

    pub inline fn init(
        allocator: std.mem.Allocator,
        db: *root.db.Connection,
        payload: Payload,
    ) ListOwn {
        db.acquire();

        return .{
            .allocator = allocator,
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *ListOwn) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const CountOwn = struct {
    pub const Result = usize;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(CountOwn, Result, anyerror);

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
        const this: *CountOwn = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT count(*)
                \\FROM app.push_subscriptions
                \\WHERE user_id = $1;
            , &.{&user_id_param}, &.{user_id_param.len}, &.{.binary}, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("CountOwn failed to send query: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("CountOwn failed: {s}", .{res.errorMessage()});

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
        const this: *CountOwn = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) CountOwn {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *CountOwn) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// Inserts the subscription or reassigns the endpoint to this user. Because
/// `endpoint_hash` is globally unique, an endpoint already registered by another
/// account is taken over (`user_id` moves to the caller) instead of creating a
/// second row: a browser profile serves the account currently logged in there.
/// `created` is caller-relative — true when the caller did not own the endpoint
/// before (a fresh insert or a takeover, both answered 201) and false when the
/// caller already owned it (an idempotent re-post that refreshes the keys,
/// answered 200). Postgres encodes "this row was inserted, not updated" as
/// `xmax = 0`, but that is not caller-relative, so ownership is read from the
/// pre-statement snapshot in the `existing` CTE instead.
pub const Create = struct {
    pub const Item = struct {
        id: root.types.PushSubscriptionId,
        created: bool,
        created_at: u64,
    };

    pub const Result = Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Create, Result, anyerror);

    pub const Payload = struct {
        id: root.types.PushSubscriptionId,
        user_id: root.types.UserId,
        endpoint: []const u8,
        endpoint_hash: [32]u8,
        p256dh: [65]u8,
        auth: [16]u8,
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
            const id_param = root.utils.intToArray(root.types.PushSubscriptionId, this.payload.id, .big);
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);

            switch (this.db.sendQueryParams(
                \\WITH existing AS (
                \\    SELECT user_id
                \\    FROM app.push_subscriptions
                \\    WHERE endpoint_hash = $4
                \\),
                \\upsert AS (
                \\    INSERT INTO app.push_subscriptions
                \\        (id, user_id, endpoint, endpoint_hash, p256dh, auth)
                \\    VALUES ($1, $2, $3, $4, $5, $6)
                \\    ON CONFLICT (endpoint_hash)
                \\    DO UPDATE SET user_id  = EXCLUDED.user_id,
                \\                  endpoint = EXCLUDED.endpoint,
                \\                  p256dh   = EXCLUDED.p256dh,
                \\                  auth     = EXCLUDED.auth
                \\    RETURNING id, created_at
                \\)
                \\SELECT upsert.id,
                \\       ((SELECT user_id FROM existing) IS DISTINCT FROM $2) AS created,
                \\       upsert.created_at
                \\FROM upsert;
            , &.{
                &id_param,
                &user_id_param,
                this.payload.endpoint.ptr,
                &this.payload.endpoint_hash,
                &this.payload.p256dh,
                &this.payload.auth,
            }, &.{
                id_param.len,
                user_id_param.len,
                @intCast(this.payload.endpoint.len),
                @intCast(this.payload.endpoint_hash.len),
                @intCast(this.payload.p256dh.len),
                @intCast(this.payload.auth.len),
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

                std.debug.assert(res.ntuples() == 1);
                std.debug.assert(res.nfields() >= 3);

                return .{
                    .ready = .{
                        .id = res.readInt(root.types.PushSubscriptionId, 0, 0),
                        .created = res.readBool(0, 1),
                        .created_at = @divFloor(res.readInt(u64, 0, 2) + 946684800000000, 1000),
                    },
                };
            }

            return .{ .err = error.PGError };
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

pub const DeleteOwn = struct {
    pub const Result = bool;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(DeleteOwn, Result, anyerror);

    pub const Payload = struct {
        user_id: root.types.UserId,
        id: root.types.PushSubscriptionId,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *DeleteOwn = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const id_param = root.utils.intToArray(root.types.PushSubscriptionId, this.payload.id, .big);
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);

            switch (this.db.sendQueryParams(
                \\DELETE FROM app.push_subscriptions
                \\WHERE id = $1
                \\  AND user_id = $2
                \\RETURNING id;
            , &.{ &id_param, &user_id_param }, &.{ id_param.len, user_id_param.len }, &.{ .binary, .binary }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("DeleteOwn failed to send query: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("DeleteOwn failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .{ .ready = res.ntuples() != 0 };
            }

            return .{ .ready = false };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *DeleteOwn = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) DeleteOwn {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *DeleteOwn) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// Whether the user already has a subscription for this endpoint. Used to keep
/// `POST` idempotent at the per-user cap.
pub const ExistsEndpoint = struct {
    pub const Result = bool;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(ExistsEndpoint, Result, anyerror);

    pub const Payload = struct {
        user_id: root.types.UserId,
        endpoint_hash: [32]u8,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *ExistsEndpoint = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT 1
                \\FROM app.push_subscriptions
                \\WHERE user_id = $1
                \\  AND endpoint_hash = $2;
            , &.{
                &user_id_param,
                &this.payload.endpoint_hash,
            }, &.{
                user_id_param.len,
                @intCast(this.payload.endpoint_hash.len),
            }, &.{
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("ExistsEndpoint failed to send query: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("ExistsEndpoint failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .{ .ready = res.ntuples() != 0 };
            }

            return .{ .ready = false };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *ExistsEndpoint = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) ExistsEndpoint {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *ExistsEndpoint) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// Removes every push subscription of a user: called on a password change
/// (self-service or system reset) and on a user soft-delete. Idempotent.
pub const DeleteAllForUser = struct {
    pub const Result = void;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(DeleteAllForUser, Result, anyerror);

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
        const this: *DeleteAllForUser = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);

            switch (this.db.sendQueryParams(
                \\DELETE FROM app.push_subscriptions
                \\WHERE user_id = $1;
            , &.{&user_id_param}, &.{user_id_param.len}, &.{.binary}, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("DeleteAllForUser failed to send query: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("DeleteAllForUser failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .{ .ready = {} };
            }

            return .{ .ready = {} };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *DeleteAllForUser = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) DeleteAllForUser {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *DeleteAllForUser) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// Removes a subscription the push service reported as gone (HTTP 404/410).
/// Owned by the notification dispatcher, not by a request.
pub const DeleteByEndpointHash = struct {
    pub const Result = void;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(DeleteByEndpointHash, Result, anyerror);

    pub const Payload = struct {
        user_id: root.types.UserId,
        endpoint_hash: [32]u8,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *DeleteByEndpointHash = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);

            switch (this.db.sendQueryParams(
                \\DELETE FROM app.push_subscriptions
                \\WHERE user_id = $1
                \\  AND endpoint_hash = $2;
            , &.{
                &user_id_param,
                &this.payload.endpoint_hash,
            }, &.{
                user_id_param.len,
                @intCast(this.payload.endpoint_hash.len),
            }, &.{
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("DeleteByEndpointHash failed to send query: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("DeleteByEndpointHash failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .{ .ready = {} };
            }

            return .{ .pending = .db };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *DeleteByEndpointHash = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) DeleteByEndpointHash {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *DeleteByEndpointHash) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// Subscriptions of the given users, with their encryption material, for the
/// notification dispatcher. The returned slices are owned by `allocator` and
/// freed in `dispose`.
pub const ListForUsers = struct {
    pub const Item = struct {
        id: root.types.PushSubscriptionId,
        user_id: root.types.UserId,
        endpoint: []const u8,
        p256dh: []const u8,
        auth: []const u8,
    };

    pub const Result = []const Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(ListForUsers, Result, anyerror);

    pub const Payload = struct {
        user_ids: []const root.types.UserId,
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
    items: std.ArrayList(Item) = .empty,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *ListForUsers = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            if (this.ids_buf == null) {
                this.ids_buf = root.db.encodeInt8Array(
                    root.types.UserId,
                    this.allocator,
                    this.payload.user_ids,
                ) catch |err| {
                    SCOPE.err("ListForUsers failed to encode the ids: {t}", .{err});

                    return .{ .err = err };
                };
            }

            const ids = this.ids_buf.?;

            switch (this.db.sendQueryParams(
                \\SELECT id, user_id, endpoint, p256dh, auth
                \\FROM app.push_subscriptions
                \\WHERE user_id = ANY($1::bigint[]);
            , &.{ids.ptr}, &.{@intCast(ids.len)}, &.{.binary}, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("ListForUsers failed to send query: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("ListForUsers failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                std.debug.assert(res.nfields() >= 5);

                for (0..res.ntuples()) |i| {
                    const endpoint = res.readSliceDupe(this.allocator, i, 2) catch |err| {
                        SCOPE.err("ListForUsers failed to read 'endpoint': {t}", .{err});

                        return .{ .err = err };
                    };

                    const p256dh = res.readSliceDupe(this.allocator, i, 3) catch |err| {
                        this.allocator.free(endpoint);

                        SCOPE.err("ListForUsers failed to read 'p256dh': {t}", .{err});

                        return .{ .err = err };
                    };

                    const auth = res.readSliceDupe(this.allocator, i, 4) catch |err| {
                        this.allocator.free(endpoint);
                        this.allocator.free(p256dh);

                        SCOPE.err("ListForUsers failed to read 'auth': {t}", .{err});

                        return .{ .err = err };
                    };

                    this.items.append(this.allocator, .{
                        .id = res.readInt(root.types.PushSubscriptionId, i, 0),
                        .user_id = res.readInt(root.types.UserId, i, 1),
                        .endpoint = endpoint,
                        .p256dh = p256dh,
                        .auth = auth,
                    }) catch |err| {
                        this.allocator.free(endpoint);
                        this.allocator.free(p256dh);
                        this.allocator.free(auth);

                        SCOPE.err("ListForUsers failed to grow the list: {t}", .{err});

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
        const this: *ListForUsers = @ptrCast(@alignCast(ctx));

        for (this.items.items) |item| {
            this.allocator.free(item.endpoint);
            this.allocator.free(item.p256dh);
            this.allocator.free(item.auth);
        }

        this.items.deinit(this.allocator);

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
    ) ListForUsers {
        db.acquire();

        return .{
            .allocator = allocator,
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *ListForUsers) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};
