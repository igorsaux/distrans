// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const pq = @import("pq");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.repo_sync);

/// Changed-since delta scans. Each scope builds its whole JSON body in one
/// statement and returns it as a single text column: the payload is ids only
/// and bounded by the caller's lookback window, so there is nothing to stream.
///
/// The server cursor is the database's `now()` captured at query start; the
/// caller stores it and passes it as the next `since`. The `<= cursor.ts`
/// upper bound keeps the returned set from ever being newer than the cursor.
///
/// `channels` means any channel change in the guild, including message changes:
/// the union covers channel-row updates (metadata, position, ...) and channels
/// whose messages changed. The union deduplicates channels with both kinds of change.
/// The message branch is correlated per guild channel so it can use
/// `messages_channel_updated_idx (channel_id, updated_at)`.
const GUILD_QUERY: [:0]const u8 =
    \\WITH cursor AS MATERIALIZED (SELECT now() AS ts)
    \\SELECT json_build_object(
    \\  'updated_at', (SELECT (extract(epoch FROM ts) * 1000)::bigint FROM cursor),
    \\  'channels', (SELECT coalesce(json_agg(id::text ORDER BY id), '[]'::json)
    \\                 FROM (
    \\                   SELECT c.id
    \\                     FROM app.channels c, cursor
    \\                    WHERE c.guild_id = $1
    \\                      AND c.updated_at > to_timestamp($2::bigint / 1000.0)
    \\                      AND c.updated_at <= cursor.ts
    \\                   UNION
    \\                   SELECT c.id
    \\                     FROM app.channels c, cursor
    \\                    WHERE c.guild_id = $1
    \\                      AND EXISTS (
    \\                            SELECT 1
    \\                              FROM app.messages m
    \\                             WHERE m.channel_id = c.id
    \\                               AND m.guild_id = $1
    \\                               AND m.updated_at > to_timestamp($2::bigint / 1000.0)
    \\                               AND m.updated_at <= cursor.ts)
    \\                 ) changed),
    \\  'roles', (SELECT coalesce(json_agg(r.id::text ORDER BY r.id), '[]'::json)
    \\              FROM app.roles r, cursor
    \\             WHERE r.guild_id = $1
    \\               AND r.updated_at > to_timestamp($2::bigint / 1000.0)
    \\               AND r.updated_at <= cursor.ts),
    \\  'emojis', (SELECT coalesce(json_agg(e.id::text ORDER BY e.id), '[]'::json)
    \\               FROM app.emojis e, cursor
    \\              WHERE e.guild_id = $1
    \\                AND e.updated_at > to_timestamp($2::bigint / 1000.0)
    \\                AND e.updated_at <= cursor.ts),
    \\  'overwrites', (SELECT coalesce(json_agg(json_build_object(
    \\                    'channel_id', o.channel_id::text,
    \\                    'target_id', o.target_id::text,
    \\                    'type', CASE o.target_type WHEN 0 THEN 'role' ELSE 'member' END)
    \\                  ORDER BY o.channel_id, o.target_id), '[]'::json)
    \\                   FROM app.overwrites o, cursor
    \\                  WHERE o.guild_id = $1
    \\                    AND o.updated_at > to_timestamp($2::bigint / 1000.0)
    \\                    AND o.updated_at <= cursor.ts),
    \\  'member_roles', (SELECT coalesce(json_agg(r.id::text ORDER BY r.id), '[]'::json)
    \\                     FROM app.roles r
    \\                    WHERE r.guild_id = $1
    \\                      AND (r.id = $1 OR EXISTS(
    \\                           SELECT 1 FROM app.member_roles mr
    \\                            WHERE mr.guild_id = r.guild_id
    \\                              AND mr.role_id  = r.id
    \\                              AND mr.user_id  = $3)))
    \\)::text;
;

const MESSAGES_QUERY: [:0]const u8 =
    \\WITH cursor AS MATERIALIZED (SELECT now() AS ts)
    \\SELECT json_build_object(
    \\  'updated_at', (SELECT (extract(epoch FROM ts) * 1000)::bigint FROM cursor),
    \\  'messages', (SELECT coalesce(json_agg(m.id::text ORDER BY m.id), '[]'::json)
    \\                 FROM app.messages m, cursor
    \\                WHERE m.channel_id = $1
    \\                  AND m.updated_at > to_timestamp($2::bigint / 1000.0)
    \\                  AND m.updated_at <= cursor.ts)
    \\)::text;
;

const USERS_QUERY: [:0]const u8 =
    \\WITH cursor AS MATERIALIZED (SELECT now() AS ts)
    \\SELECT json_build_object(
    \\  'updated_at', (SELECT (extract(epoch FROM ts) * 1000)::bigint FROM cursor),
    \\  'users', (SELECT coalesce(json_agg(u.id::text ORDER BY u.id), '[]'::json)
    \\              FROM app.users u, cursor
    \\             WHERE u.updated_at > to_timestamp($1::bigint / 1000.0)
    \\               AND u.updated_at <= cursor.ts)
    \\)::text;
;

/// One changed-since scope. `member_roles` in the guild scope carries the
/// caller's **complete current** role set (not filtered by `since`) exactly as
/// `repo.users.GetRoles` computes it: the implicit `@everyone` role (id ==
/// guild id) plus every granted role. Grant and revoke hard-delete the row, so a
/// delta filter cannot express revocation and a stale set would be a permissions
/// bug; omitting `@everyone` would zero the client's guild base permissions
/// (`@everyone` is the only role a clean member holds).
pub const Sync = struct {
    pub const Result = []const u8;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Sync, Result, anyerror);

    pub const Scope = enum {
        guild,
        messages,
        users,
    };

    pub const Payload = struct {
        scope: Scope,
        /// Epoch milliseconds lower bound (exclusive).
        since_ms: u64,
        guild_id: root.types.GuildId = 0,
        channel_id: root.types.ChannelId = 0,
        /// Only used by the `guild` scope's `member_roles`.
        user_id: root.types.UserId = 0,
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
        const this: *Sync = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const guild_id_param = root.utils.intToArray(root.types.GuildId, this.payload.guild_id, .big);
            const channel_id_param = root.utils.intToArray(root.types.ChannelId, this.payload.channel_id, .big);
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);
            const since_param = root.utils.intToArray(u64, this.payload.since_ms, .big);

            var params: [3]?[*]const u8 = undefined;
            var lengths: [3]c_int = undefined;
            var formats: [3]root.db.Connection.Format = undefined;
            var query: [:0]const u8 = undefined;
            var count: usize = undefined;

            switch (this.payload.scope) {
                .guild => {
                    params[0] = &guild_id_param;
                    params[1] = &since_param;
                    params[2] = &user_id_param;

                    lengths[0] = @intCast(guild_id_param.len);
                    lengths[1] = @intCast(since_param.len);
                    lengths[2] = @intCast(user_id_param.len);

                    formats[0] = .binary;
                    formats[1] = .binary;
                    formats[2] = .binary;

                    query = GUILD_QUERY;
                    count = 3;
                },
                .messages => {
                    params[0] = &channel_id_param;
                    params[1] = &since_param;

                    lengths[0] = @intCast(channel_id_param.len);
                    lengths[1] = @intCast(since_param.len);

                    formats[0] = .binary;
                    formats[1] = .binary;

                    query = MESSAGES_QUERY;
                    count = 2;
                },
                .users => {
                    params[0] = &since_param;

                    lengths[0] = @intCast(since_param.len);

                    formats[0] = .binary;

                    query = USERS_QUERY;
                    count = 1;
                },
            }

            switch (this.db.sendQueryParams(
                query,
                params[0..count],
                lengths[0..count],
                formats[0..count],
                .binary,
            )) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("Sync failed to send query: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("Sync failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                if (res.ntuples() == 0 or res.isNull(0, 0)) {
                    SCOPE.err("Sync returned no body", .{});

                    return .{ .err = error.PGError };
                }

                const body = res.readSliceDupe(this.allocator, 0, 0) catch |err| {
                    SCOPE.err("Sync failed to dupe the body: {t}", .{err});

                    return .{ .err = err };
                };

                return .{ .ready = body };
            }

            SCOPE.err("Sync returned no result", .{});

            return .{ .err = error.PGError };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *Sync = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(
        allocator: std.mem.Allocator,
        db: *root.db.Connection,
        payload: Payload,
    ) Sync {
        db.acquire();

        return .{
            .allocator = allocator,
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *Sync) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};
