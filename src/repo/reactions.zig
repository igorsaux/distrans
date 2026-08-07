// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const pq = @import("pq");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.repo_reactions);

/// A reaction target: a custom emoji (`app.emojis.id`) or exactly one
/// fully-qualified unicode sequence (see `root.unicode.isFullyQualifiedEmoji`).
pub const Emoji = union(enum) {
    custom: root.types.EmojiId,
    unicode: []const u8,
};

/// `emoji_kind` values, mirroring `reactions_kind_valid` in
/// migrations/5_reactions_and_emojis.sql.
pub const KIND_UNICODE: u16 = 0;
pub const KIND_CUSTOM: u16 = 1;

pub inline fn emojiKind(emoji: Emoji) u16 {
    return switch (emoji) {
        .custom => KIND_CUSTOM,
        .unicode => KIND_UNICODE,
    };
}

/// Builds the (nullable) `emoji_id` / `unicode_emoji` parameters for a
/// reaction target. `custom` and `unicode` are mutually exclusive by shape.
const EmojiParams = struct {
    custom_param: [8]u8 = undefined,
    custom_len: c_int = 0,
    unicode_param: ?[*]const u8 = null,
    unicode_len: c_int = 0,

    inline fn raw(this: *EmojiParams, emoji: Emoji) struct { id: ?[*]const u8, id_len: c_int, unicode: ?[*]const u8, unicode_len: c_int } {
        switch (emoji) {
            .custom => |id| {
                this.custom_param = root.utils.intToArray(root.types.EmojiId, id, .big);
                this.custom_len = this.custom_param.len;
            },
            .unicode => |text| {
                this.unicode_param = text.ptr;
                this.unicode_len = @intCast(text.len);
            },
        }

        return .{
            .id = if (emoji == .custom) &this.custom_param else null,
            .id_len = this.custom_len,
            .unicode = this.unicode_param,
            .unicode_len = this.unicode_len,
        };
    }
};

/// Inserts a reaction. The unique index `reactions_uniq` makes the operation
/// idempotent; `Result` tells whether a row was actually inserted.
pub const Add = struct {
    pub const Result = bool;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Add, Result, anyerror);

    pub const Payload = struct {
        message_id: root.types.MessageId,
        user_id: root.types.UserId,
        emoji: Emoji,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *Add = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const message_id_param = root.utils.intToArray(root.types.MessageId, this.payload.message_id, .big);
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);
            const kind_param = root.utils.intToArray(u16, emojiKind(this.payload.emoji), .big);

            var emoji_params: EmojiParams = .{};
            const params = emoji_params.raw(this.payload.emoji);

            switch (this.db.sendQueryParams(
                \\INSERT INTO app.message_reactions (message_id, user_id, emoji_kind, emoji_id, unicode_emoji)
                \\VALUES ($1, $2, $3, $4, $5)
                \\ON CONFLICT DO NOTHING
                \\RETURNING 1;
            , &.{
                &message_id_param,
                &user_id_param,
                &kind_param,
                params.id,
                params.unicode,
            }, &.{
                message_id_param.len,
                user_id_param.len,
                kind_param.len,
                params.id_len,
                params.unicode_len,
            }, &.{
                .binary,
                .binary,
                .binary,
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("Add failed to send: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("Add failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .{ .ready = res.ntuples() != 0 };
            }

            return .{ .ready = false };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *Add = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) Add {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *Add) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// A reaction that was removed, dupe-allocated for the caller.
pub const RemovedItem = struct {
    emoji_kind: u16,
    emoji_id: ?root.types.EmojiId,
    unicode_emoji: ?[]const u8,
};

/// Removes a user's reaction (a specific emoji, or all of them when `emoji`
/// is `null`). Returns the removed rows so the caller can dispatch one event
/// per reaction. Idempotent: removing a non-existent reaction yields an empty
/// list.
pub const Remove = struct {
    pub const Result = []const RemovedItem;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Remove, Result, anyerror);

    pub const Payload = struct {
        message_id: root.types.MessageId,
        user_id: root.types.UserId,
        emoji: ?Emoji,
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
        const this: *Remove = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const message_id_param = root.utils.intToArray(root.types.MessageId, this.payload.message_id, .big);
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);

            var emoji_params: EmojiParams = .{};
            var kind_param: [2]u8 = undefined;
            var params: [5]?[*]const u8 = undefined;
            var params_length: [5]c_int = undefined;

            if (this.payload.emoji) |emoji| {
                kind_param = root.utils.intToArray(u16, emojiKind(emoji), .big);

                const raw = emoji_params.raw(emoji);

                params = .{ &message_id_param, &user_id_param, &kind_param, raw.id, raw.unicode };
                params_length = .{ message_id_param.len, user_id_param.len, kind_param.len, raw.id_len, raw.unicode_len };

                switch (this.db.sendQueryParams(
                    \\DELETE FROM app.message_reactions
                    \\WHERE message_id = $1
                    \\  AND user_id = $2
                    \\  AND emoji_kind = $3
                    \\  AND emoji_id IS NOT DISTINCT FROM $4
                    \\  AND unicode_emoji IS NOT DISTINCT FROM $5
                    \\RETURNING emoji_kind, emoji_id, unicode_emoji;
                , &params, &params_length, &.{ .binary, .binary, .binary, .binary, .binary }, .binary)) {
                    .ready => this.state = .waiting,
                    .err => |err| {
                        SCOPE.err("Remove failed to send: {s}", .{this.db.errorMessage()});

                        return .{ .err = err };
                    },
                    else => |res| return res.mapDiscard(Result),
                }
            } else {
                params[0] = &message_id_param;
                params[1] = &user_id_param;
                params_length[0] = message_id_param.len;
                params_length[1] = user_id_param.len;

                switch (this.db.sendQueryParams(
                    \\DELETE FROM app.message_reactions
                    \\WHERE message_id = $1
                    \\  AND user_id = $2
                    \\RETURNING emoji_kind, emoji_id, unicode_emoji;
                , params[0..2], params_length[0..2], &.{ .binary, .binary }, .binary)) {
                    .ready => this.state = .waiting,
                    .err => |err| {
                        SCOPE.err("Remove failed to send: {s}", .{this.db.errorMessage()});

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

                if (res.status() != pq.PGRES_TUPLES_OK) {
                    SCOPE.err("Remove failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                const total = res.ntuples();

                const items = this.allocator.alloc(RemovedItem, total) catch |err| {
                    SCOPE.err("Remove failed to allocate: {t}", .{err});

                    return .{ .err = err };
                };

                for (0..total) |i| {
                    items[i] = .{
                        .emoji_kind = res.readInt(u16, i, 0),
                        .emoji_id = res.readIntOptional(root.types.EmojiId, i, 1),
                        .unicode_emoji = res.readSliceOptionalDupe(this.allocator, i, 2) catch |err| {
                            SCOPE.err("Remove failed to dupe 'unicode_emoji': {t}", .{err});

                            return .{ .err = err };
                        },
                    };
                }

                return .{ .ready = items };
            }

            return .{ .ready = &.{} };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *Remove = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(
        allocator: std.mem.Allocator,
        db: *root.db.Connection,
        payload: Payload,
    ) Remove {
        db.acquire();

        return .{
            .allocator = allocator,
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *Remove) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// `present` is whether any user has reacted to the message with `emoji`;
/// `distinct` is the number of distinct emoji the message currently has
/// (the value the `api.messages.max_reactions` cap applies to).
pub const GetStats = struct {
    pub const Result = struct {
        present: bool,
        distinct: u64,
    };

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(GetStats, Result, anyerror);

    pub const Payload = struct {
        message_id: root.types.MessageId,
        emoji: Emoji,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *GetStats = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const message_id_param = root.utils.intToArray(root.types.MessageId, this.payload.message_id, .big);
            const kind_param = root.utils.intToArray(u16, emojiKind(this.payload.emoji), .big);

            var emoji_params: EmojiParams = .{};
            const params = emoji_params.raw(this.payload.emoji);

            switch (this.db.sendQueryParams(
                \\SELECT COUNT(DISTINCT (emoji_id, unicode_emoji)),
                \\       COUNT(*) FILTER (
                \\           WHERE emoji_kind = $2
                \\             AND emoji_id IS NOT DISTINCT FROM $3
                \\             AND unicode_emoji IS NOT DISTINCT FROM $4
                \\       ) > 0
                \\FROM app.message_reactions
                \\WHERE message_id = $1;
            , &.{
                &message_id_param,
                &kind_param,
                params.id,
                params.unicode,
            }, &.{
                message_id_param.len,
                kind_param.len,
                params.id_len,
                params.unicode_len,
            }, &.{
                .binary,
                .binary,
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("GetStats failed to send: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("GetStats failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                if (res.ntuples() == 0) {
                    return .{ .ready = .{ .present = false, .distinct = 0 } };
                }

                std.debug.assert(res.nfields() >= 2);

                return .{ .ready = .{
                    .present = res.readBool(0, 1),
                    .distinct = @intCast(res.readInt(u64, 0, 0)),
                } };
            }

            return .{ .ready = .{ .present = false, .distinct = 0 } };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetStats = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) GetStats {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *GetStats) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// Ids of the users who reacted to a message with one emoji, ascending by
/// `app.message_reactions.user_id` and keyset-paginated with `after`. Soft-deleted
/// (and missing) users are excluded, matching the inline reaction `count`.
pub const GetUsers = struct {
    pub const Result = []const root.types.UserId;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(GetUsers, Result, anyerror);

    pub const Payload = struct {
        message_id: root.types.MessageId,
        emoji: Emoji,
        after: ?root.types.UserId,
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

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *GetUsers = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const message_id_param = root.utils.intToArray(root.types.MessageId, this.payload.message_id, .big);
            const kind_param = root.utils.intToArray(u16, emojiKind(this.payload.emoji), .big);
            const limit_param = root.utils.intToArray(usize, this.payload.limit, .big);

            var emoji_params: EmojiParams = .{};
            const params = emoji_params.raw(this.payload.emoji);

            const res = blk: {
                if (this.payload.after == null) {
                    break :blk this.db.sendQueryParams(
                        \\SELECT mr.user_id
                        \\FROM app.message_reactions AS mr
                        \\JOIN app.users AS u
                        \\  ON u.id = mr.user_id AND u.deleted_at IS NULL
                        \\WHERE mr.message_id = $1
                        \\  AND mr.emoji_kind = $2
                        \\  AND mr.emoji_id IS NOT DISTINCT FROM $3
                        \\  AND mr.unicode_emoji IS NOT DISTINCT FROM $4
                        \\ORDER BY mr.user_id ASC
                        \\LIMIT $5;
                    , &.{
                        &message_id_param,
                        &kind_param,
                        params.id,
                        params.unicode,
                        &limit_param,
                    }, &.{
                        message_id_param.len,
                        kind_param.len,
                        params.id_len,
                        params.unicode_len,
                        limit_param.len,
                    }, &.{
                        .binary,
                        .binary,
                        .binary,
                        .binary,
                        .binary,
                    }, .binary);
                }

                const after_param = root.utils.intToArray(root.types.UserId, this.payload.after.?, .big);

                break :blk this.db.sendQueryParams(
                    \\SELECT mr.user_id
                    \\FROM app.message_reactions AS mr
                    \\JOIN app.users AS u
                    \\  ON u.id = mr.user_id AND u.deleted_at IS NULL
                    \\WHERE mr.message_id = $1
                    \\  AND mr.emoji_kind = $2
                    \\  AND mr.emoji_id IS NOT DISTINCT FROM $3
                    \\  AND mr.unicode_emoji IS NOT DISTINCT FROM $4
                    \\  AND mr.user_id > $5
                    \\ORDER BY mr.user_id ASC
                    \\LIMIT $6;
                , &.{
                    &message_id_param,
                    &kind_param,
                    params.id,
                    params.unicode,
                    &after_param,
                    &limit_param,
                }, &.{
                    message_id_param.len,
                    kind_param.len,
                    params.id_len,
                    params.unicode_len,
                    after_param.len,
                    limit_param.len,
                }, &.{
                    .binary,
                    .binary,
                    .binary,
                    .binary,
                    .binary,
                    .binary,
                }, .binary);
            };

            switch (res) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("GetUsers failed to send: {s}", .{this.db.errorMessage()});

                    return .{ .err = err };
                },
                else => |r| return r.mapDiscard(Result),
            }
        }

        while (this.state == .waiting) {
            if (this.db.isBusy()) {
                return .{ .pending = .db };
            }

            if (this.db.getResult()) |res| {
                defer res.deinit();

                if (res.status() != pq.PGRES_TUPLES_OK) {
                    SCOPE.err("GetUsers failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                const total = res.ntuples();

                const items = this.allocator.alloc(root.types.UserId, total) catch |err| {
                    SCOPE.err("GetUsers failed to allocate: {t}", .{err});

                    return .{ .err = err };
                };

                for (0..total) |i| {
                    std.debug.assert(res.nfields() >= 1);

                    items[i] = res.readInt(root.types.UserId, i, 0);
                }

                return .{ .ready = items };
            }

            return .{ .ready = &.{} };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetUsers = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(
        allocator: std.mem.Allocator,
        db: *root.db.Connection,
        payload: Payload,
    ) GetUsers {
        db.acquire();

        return .{
            .allocator = allocator,
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *GetUsers) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};
