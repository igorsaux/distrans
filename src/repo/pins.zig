// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const pq = @import("pq");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.repo_pins);

/// Pins a message. The guarded `UPDATE` makes the operation idempotent and
/// tells whether the row actually transitioned `false -> true`, so the caller
/// can dispatch a gateway event only on a real state change.
pub const Pin = struct {
    pub const Result = bool;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Pin, Result, anyerror);

    pub const Payload = struct {
        channel_id: root.types.ChannelId,
        message_id: root.types.MessageId,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *Pin = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const message_id_param = root.utils.intToArray(root.types.MessageId, this.payload.message_id, .big);
            const channel_id_param = root.utils.intToArray(root.types.ChannelId, this.payload.channel_id, .big);

            switch (this.db.sendQueryParams(
                \\UPDATE app.messages
                \\SET pinned = true
                \\WHERE id = $1
                \\  AND channel_id = $2
                \\  AND deleted_at IS NULL
                \\  AND NOT pinned
                \\RETURNING id;
            , &.{
                &message_id_param,
                &channel_id_param,
            }, &.{
                message_id_param.len,
                channel_id_param.len,
            }, &.{
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("Pin failed to send: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("Pin failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .{ .ready = res.ntuples() != 0 };
            }

            return .{ .ready = false };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *Pin = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) Pin {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *Pin) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// Unpins a message. Mirrors `Pin`; `Result` is true only when the row
/// transitioned `true -> false`.
pub const Unpin = struct {
    pub const Result = bool;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Unpin, Result, anyerror);

    pub const Payload = struct {
        channel_id: root.types.ChannelId,
        message_id: root.types.MessageId,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *Unpin = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const message_id_param = root.utils.intToArray(root.types.MessageId, this.payload.message_id, .big);
            const channel_id_param = root.utils.intToArray(root.types.ChannelId, this.payload.channel_id, .big);

            switch (this.db.sendQueryParams(
                \\UPDATE app.messages
                \\SET pinned = false
                \\WHERE id = $1
                \\  AND channel_id = $2
                \\  AND deleted_at IS NULL
                \\  AND pinned
                \\RETURNING id;
            , &.{
                &message_id_param,
                &channel_id_param,
            }, &.{
                message_id_param.len,
                channel_id_param.len,
            }, &.{
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("Unpin failed to send: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("Unpin failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .{ .ready = res.ntuples() != 0 };
            }

            return .{ .ready = false };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *Unpin = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) Unpin {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *Unpin) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// Ids of a channel's pinned (non-deleted) messages, ascending by message id
/// and keyset-paginated with `before`/`after`/`last` (mirrors
/// `channels.GetMessages`, minus `around`).
pub const GetPins = struct {
    pub const Result = root.types.MessageId;

    pub const Stream = root.task.Stream(Result, anyerror);
    pub const Lazy = root.task.LazyStream(GetPins, Result, anyerror);

    pub const Mode = union(enum) {
        before: root.types.MessageId,
        after: root.types.MessageId,
        last,
    };

    pub const Payload = struct {
        channel_id: root.types.ChannelId,
        limit: usize,
        mode: Mode,
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
    reverse: bool = false,

    fn poll(ctx: *anyopaque) Stream.PollT {
        const this: *GetPins = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const channel_id_param = root.utils.intToArray(root.types.ChannelId, this.payload.channel_id, .big);
            const limit_param = root.utils.intToArray(usize, this.payload.limit, .big);

            switch (this.payload.mode) {
                .last => {
                    switch (this.db.sendQueryParams(
                        \\SELECT id
                        \\FROM app.messages
                        \\WHERE channel_id = $1
                        \\  AND pinned
                        \\  AND deleted_at IS NULL
                        \\ORDER BY id DESC
                        \\LIMIT $2;
                    , &.{
                        &channel_id_param,
                        &limit_param,
                    }, &.{
                        channel_id_param.len,
                        limit_param.len,
                    }, &.{
                        .binary,
                        .binary,
                    }, .binary)) {
                        .ready => this.state = .waiting,
                        .err => |err| {
                            SCOPE.err("GetPins failed to send query: {s}", .{this.db.errorMessage()});

                            return .{ .err = err };
                        },
                        else => |res| return res.toStreamPoll().mapDiscard(Result),
                    }

                    this.reverse = true;
                },
                .before => |anchor| {
                    const anchor_param = root.utils.intToArray(root.types.MessageId, anchor, .big);

                    switch (this.db.sendQueryParams(
                        \\SELECT id
                        \\FROM app.messages
                        \\WHERE channel_id = $1
                        \\  AND pinned
                        \\  AND deleted_at IS NULL
                        \\  AND id < $2
                        \\ORDER BY id DESC
                        \\LIMIT $3;
                    , &.{
                        &channel_id_param,
                        &anchor_param,
                        &limit_param,
                    }, &.{
                        channel_id_param.len,
                        anchor_param.len,
                        limit_param.len,
                    }, &.{
                        .binary,
                        .binary,
                        .binary,
                    }, .binary)) {
                        .ready => this.state = .waiting,
                        .err => |err| {
                            SCOPE.err("GetPins failed to send query: {s}", .{this.db.errorMessage()});

                            return .{ .err = err };
                        },
                        else => |res| return res.toStreamPoll().mapDiscard(Result),
                    }

                    this.reverse = true;
                },
                .after => |anchor| {
                    const anchor_param = root.utils.intToArray(root.types.MessageId, anchor, .big);

                    switch (this.db.sendQueryParams(
                        \\SELECT id
                        \\FROM app.messages
                        \\WHERE channel_id = $1
                        \\  AND pinned
                        \\  AND deleted_at IS NULL
                        \\  AND id > $2
                        \\ORDER BY id ASC
                        \\LIMIT $3;
                    , &.{
                        &channel_id_param,
                        &anchor_param,
                        &limit_param,
                    }, &.{
                        channel_id_param.len,
                        anchor_param.len,
                        limit_param.len,
                    }, &.{
                        .binary,
                        .binary,
                        .binary,
                    }, .binary)) {
                        .ready => this.state = .waiting,
                        .err => |err| {
                            SCOPE.err("GetPins failed to send query: {s}", .{this.db.errorMessage()});

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
                        SCOPE.err("GetPins failed: {s}", .{res.errorMessage()});
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

                const total = res.ntuples();

                if (yield.pos >= total) {
                    res.deinit();
                    this.state = .waiting;

                    continue;
                }

                const idx = if (this.reverse)
                    total - 1 - yield.pos
                else
                    yield.pos;

                std.debug.assert(res.nfields() >= 1);

                const id = res.readInt(root.types.MessageId, idx, 0);

                yield.pos += 1;

                return .{ .yielded = id };
            }
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetPins = @ptrCast(@alignCast(ctx));

        if (this.state == .yielding) {
            this.state.yielding.res.deinit();
        }

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) GetPins {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn stream(this: *GetPins) Stream {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// Full pinned (non-deleted) messages of a channel, ascending by message id
/// and keyset-paginated with `before`/`after`/`last`. Mirrors
/// `channels.GetMessages`, restricted to pinned rows.
pub const GetPinnedMessages = struct {
    pub const Result = root.repo.types.Message;

    pub const Stream = root.task.Stream(Result, anyerror);
    pub const Lazy = root.task.LazyStream(GetPinnedMessages, Result, anyerror);

    pub const Mode = union(enum) {
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
        },
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,
    reverse: bool = false,

    fn poll(ctx: *anyopaque) Stream.PollT {
        const this: *GetPinnedMessages = @ptrCast(@alignCast(ctx));

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
                    ++ root.repo.channels.reactionsAggregate(3, "app.messages.id") ++
                        \\FROM app.messages
                        \\WHERE channel_id = $1
                        \\  AND pinned
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
                            SCOPE.err("GetPinnedMessages failed to send query: {s}", .{this.db.errorMessage()});

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
                    ++ root.repo.channels.reactionsAggregate(4, "app.messages.id") ++
                        \\FROM app.messages
                        \\WHERE channel_id = $1
                        \\  AND pinned
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
                            SCOPE.err("GetPinnedMessages failed to send query: {s}", .{this.db.errorMessage()});

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
                    ++ root.repo.channels.reactionsAggregate(4, "app.messages.id") ++
                        \\FROM app.messages
                        \\WHERE channel_id = $1
                        \\  AND pinned
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
                            SCOPE.err("GetPinnedMessages failed to send query: {s}", .{this.db.errorMessage()});

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
                        SCOPE.err("GetPinnedMessages failed: {s}", .{res.errorMessage()});
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

                const total = res.ntuples();

                if (yield.pos >= total) {
                    res.deinit();
                    this.state = .waiting;

                    continue;
                }

                const idx = if (this.reverse)
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
                    .channel_id = res.readInt(root.types.ChannelId, idx, 13),
                    .reactions = res.readStringOptional(idx, 14),
                };

                yield.pos += 1;

                return .{ .yielded = item };
            }
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetPinnedMessages = @ptrCast(@alignCast(ctx));

        if (this.state == .yielding) {
            this.state.yielding.res.deinit();
        }

        this.db.release();
    }

    pub inline fn init(
        db: *root.db.Connection,
        payload: Payload,
    ) GetPinnedMessages {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn stream(this: *GetPinnedMessages) Stream {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};
