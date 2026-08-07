// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const pq = @import("pq");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.repo_audit_log);

/// Appends one or more `app.audit_log` rows in a single `INSERT`. The ids are
/// fresh snowflakes. Rows are written after the audited mutation has succeeded,
/// so the action / target ids are the best-effort values already known to the
/// handler; no before / after snapshot is stored.
///
/// The task never fails: an insert error is logged and swallowed, because the
/// audited mutation has already succeeded and must not be reported as failed.
pub const Insert = struct {
    pub const Result = bool;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Insert, Result, anyerror);

    /// One audited change. `guild_id` / `actor_id` come from the `Payload`; the
    /// caller builds a compile-time-sized array of these and passes a slice
    /// that outlives the task.
    pub const Entry = struct {
        action: root.types.AuditAction,
        /// Primary target id (channel, role, emoji, webhook or message id),
        /// depending on `action`.
        target_id: ?u64 = null,
        /// The affected member for `role_grant` / `role_revoke` and the member
        /// overwrite actions.
        target_user_id: ?root.types.UserId = null,
        channel_id: ?root.types.ChannelId = null,
    };

    pub const Payload = struct {
        guild_id: root.types.GuildId,
        /// `null` for an action with no session actor (never a system endpoint).
        actor_id: ?root.types.UserId = null,
        /// The rows to append. Never empty; must outlive the task.
        entries: []const Entry,
    };

    const State = enum {
        start,
        waiting,
    };

    const COLUMNS = 7;

    const INSERT_QUERY: [:0]const u8 =
        \\INSERT INTO app.audit_log
        \\  (id, guild_id, actor_id, action, target_id, target_user_id, channel_id)
        \\SELECT * FROM unnest($1::bigint[], $2::bigint[], $3::bigint[],
        \\                     $4::bigint[], $5::bigint[], $6::bigint[], $7::bigint[]);
    ;

    allocator: std.mem.Allocator,
    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    /// Builds the seven encoded `bigint[]` columns in `bufs`, allocated with
    /// `allocator`. The caller frees them once the query has been sent (libpq
    /// copies the parameters before `sendQueryParams` returns).
    inline fn encode(this: *Insert, bufs: *[COLUMNS][]u8) !void {
        const entries = this.payload.entries;
        const n = entries.len;

        std.debug.assert(n != 0);

        const required = try this.allocator.alloc(u64, n);
        defer this.allocator.free(required);

        const optional = try this.allocator.alloc(?u64, n);
        defer this.allocator.free(optional);

        var count: usize = 0;

        errdefer {
            for (bufs[0..count]) |buf| {
                this.allocator.free(buf);
            }
        }

        for (required) |*value| {
            value.* = root.sf_generator.generate();
        }

        bufs[count] = try root.db.encodeInt8Array(u64, this.allocator, required);
        count += 1;

        for (required) |*value| {
            value.* = this.payload.guild_id;
        }

        bufs[count] = try root.db.encodeInt8Array(u64, this.allocator, required);
        count += 1;

        for (optional) |*value| {
            value.* = this.payload.actor_id;
        }

        bufs[count] = try root.db.encodeInt8ArrayOptional(u64, this.allocator, optional);
        count += 1;

        for (entries, required) |entry, *value| {
            value.* = @intFromEnum(entry.action);
        }

        bufs[count] = try root.db.encodeInt8Array(u64, this.allocator, required);
        count += 1;

        for (entries, optional) |entry, *value| {
            value.* = entry.target_id;
        }

        bufs[count] = try root.db.encodeInt8ArrayOptional(u64, this.allocator, optional);
        count += 1;

        for (entries, optional) |entry, *value| {
            value.* = entry.target_user_id;
        }

        bufs[count] = try root.db.encodeInt8ArrayOptional(u64, this.allocator, optional);
        count += 1;

        for (entries, optional) |entry, *value| {
            value.* = entry.channel_id;
        }

        bufs[count] = try root.db.encodeInt8ArrayOptional(u64, this.allocator, optional);
        count += 1;
    }

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *Insert = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            var bufs: [COLUMNS][]u8 = undefined;

            this.encode(&bufs) catch |err| {
                // Best effort: the audited mutation already succeeded.
                SCOPE.err("Insert failed to encode the columns: {t}", .{err});

                return .{ .ready = false };
            };

            defer {
                for (bufs) |buf| {
                    this.allocator.free(buf);
                }
            }

            var params: [COLUMNS]?[*]const u8 = undefined;
            var lengths: [COLUMNS]c_int = undefined;

            inline for (0..COLUMNS) |i| {
                params[i] = bufs[i].ptr;
                lengths[i] = @intCast(bufs[i].len);
            }

            var formats: [COLUMNS]root.db.Connection.Format = @splat(.binary);

            switch (this.db.sendQueryParams(INSERT_QUERY, &params, &lengths, &formats, .binary)) {
                .ready => this.state = .waiting,
                .pending => |pending| return .{ .pending = pending },
                .err => |err| {
                    SCOPE.err("Insert failed to send query: {s} {t}", .{ this.db.errorMessage(), err });

                    return .{ .ready = false };
                },
            }
        }

        while (this.state == .waiting) {
            if (this.db.isBusy()) {
                return .{ .pending = .db };
            }

            if (this.db.getResult()) |res| {
                defer res.deinit();

                if (res.status() != pq.PGRES_COMMAND_OK) {
                    SCOPE.err("Insert failed: {s}", .{res.errorMessage()});

                    return .{ .ready = false };
                }

                return .{ .ready = true };
            }

            return .{ .ready = false };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *Insert = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(
        db: *root.db.Connection,
        allocator: std.mem.Allocator,
        payload: Payload,
    ) Insert {
        db.acquire();

        return .{
            .allocator = allocator,
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *Insert) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// Filters shared by the page query (`Search`) and the count query (`Count`).
/// A nullable field means "filter absent"; `actions` matches any of its values
/// (OR within the filter) and holds the numeric `@intFromEnum(AuditAction)`
/// values (see `app.audit_log.action`).
pub const Filters = struct {
    guild_id: root.types.GuildId,
    actor_id: ?root.types.UserId = null,
    actions: []const u64 = &.{},
};

/// Shared `FROM`/`WHERE` of the search and count queries. Covers placeholders
/// `$1..$3` (the filters).
const FILTERS_FROM: []const u8 =
    \\FROM app.audit_log a
    \\WHERE a.guild_id = $1
    \\  AND ($2::bigint IS NULL OR a.actor_id = $2)
    \\  AND ($3::bigint[] IS NULL OR a.action = ANY($3))
;

const PAGE_SELECT: []const u8 =
    \\SELECT a.id, a.actor_id, a.action, a.target_id, a.target_user_id,
    \\       a.channel_id, a.created_at
;

/// `ORDER BY` direction cannot be a bind parameter, so the page query exists in
/// two spellings (`newest` = descending, `oldest` = ascending); `LIMIT $4` is
/// the page size and `OFFSET $5` the page start.
const PAGE_QUERY_DESC: [:0]const u8 = PAGE_SELECT ++ "\n" ++ FILTERS_FROM ++ "\nORDER BY a.id DESC\nLIMIT $4 OFFSET $5;";
const PAGE_QUERY_ASC: [:0]const u8 = PAGE_SELECT ++ "\n" ++ FILTERS_FROM ++ "\nORDER BY a.id ASC\nLIMIT $4 OFFSET $5;";

const COUNT_QUERY: [:0]const u8 = "SELECT count(*)\n" ++ FILTERS_FROM ++ ";";

/// Per-guild audit log, streamed like `repo.search.Search` with `offset`/`limit`
/// pagination. `a.id` is unique, so offset pagination is stable.
pub const Search = struct {
    pub const Item = struct {
        id: root.types.AuditLogId,
        actor_id: ?root.types.UserId,
        action: root.types.AuditAction,
        target_id: ?u64,
        target_user_id: ?root.types.UserId,
        channel_id: ?root.types.ChannelId,
        /// Unix epoch, milliseconds.
        created_at: u64,
    };

    pub const Result = Item;

    pub const Stream = root.task.Stream(Result, anyerror);
    pub const Lazy = root.task.LazyStream(Search, Result, anyerror);

    pub const Payload = struct {
        filters: Filters,
        limit: usize,
        offset: usize = 0,
        /// `true` for `sort=oldest` (id ascending), `false` for the default
        /// `sort=newest` (id descending).
        ascending: bool = false,
    };

    const State = union(enum) {
        start,
        waiting,
        yielding: struct {
            pos: usize = 0,
            res: root.db.Result,
        },
    };

    allocator: std.mem.Allocator,
    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,
    actions_buf: ?[]u8 = null,

    fn poll(ctx: *anyopaque) Stream.PollT {
        const this: *Search = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const filters = this.payload.filters;

            if (this.actions_buf == null) {
                const actions = root.db.encodeInt8Array(
                    u64,
                    this.allocator,
                    filters.actions,
                ) catch |err| {
                    SCOPE.err("Search failed to encode the actions: {t}", .{err});

                    return .{ .err = err };
                };

                this.actions_buf = actions;
            }

            const guild_id_param = root.utils.intToArray(root.types.GuildId, filters.guild_id, .big);
            const actor_id_param = if (filters.actor_id) |actor_id|
                root.utils.intToArray(root.types.UserId, actor_id, .big)
            else
                null;
            const limit_param = root.utils.intToArray(i64, @intCast(this.payload.limit), .big);
            const offset_param = root.utils.intToArray(i64, @intCast(this.payload.offset), .big);

            const actions = this.actions_buf.?;
            const has_actions = filters.actions.len != 0;

            var params: [5]?[*]const u8 = .{
                &guild_id_param,
                if (actor_id_param != null) &actor_id_param.? else null,
                if (has_actions) actions.ptr else null,
                &limit_param,
                &offset_param,
            };

            var lengths: [5]c_int = .{
                @intCast(guild_id_param.len),
                if (actor_id_param != null) @intCast(actor_id_param.?.len) else 0,
                if (has_actions) @intCast(actions.len) else 0,
                @intCast(limit_param.len),
                @intCast(offset_param.len),
            };

            var formats: [5]root.db.Connection.Format = @splat(.binary);

            const query = if (this.payload.ascending) PAGE_QUERY_ASC else PAGE_QUERY_DESC;

            switch (this.db.sendQueryParams(query, &params, &lengths, &formats, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("Search failed to send query: {s}", .{this.db.errorMessage()});

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
                        SCOPE.err("Search failed: {s}", .{res.errorMessage()});
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

                const idx = yield.pos;

                const item: Item = .{
                    .id = res.readInt(root.types.AuditLogId, idx, 0),
                    .actor_id = res.readIntOptional(root.types.UserId, idx, 1),
                    .action = @enumFromInt(@as(u16, @intCast(res.readInt(u64, idx, 2)))),
                    .target_id = res.readIntOptional(u64, idx, 3),
                    .target_user_id = res.readIntOptional(root.types.UserId, idx, 4),
                    .channel_id = res.readIntOptional(root.types.ChannelId, idx, 5),
                    .created_at = @divFloor(res.readInt(u64, idx, 6) + 946684800000000, 1000),
                };

                yield.pos += 1;

                return .{ .yielded = item };
            }
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *Search = @ptrCast(@alignCast(ctx));

        if (this.state == .yielding) {
            this.state.yielding.res.deinit();
        }

        if (this.actions_buf) |buf| {
            this.allocator.free(buf);
            this.actions_buf = null;
        }

        this.db.release();
    }

    pub inline fn init(
        allocator: std.mem.Allocator,
        db: *root.db.Connection,
        payload: Payload,
    ) Search {
        db.acquire();

        return .{
            .allocator = allocator,
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn stream(this: *Search) Stream {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// Exact number of entries matching the same `Filters` as `Search`, so `total`
/// stays correct even when the requested page is empty.
pub const Count = struct {
    pub const Result = u64;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Count, Result, anyerror);

    pub const Payload = struct {
        filters: Filters,
    };

    const State = enum {
        start,
        waiting,
    };

    allocator: std.mem.Allocator,
    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,
    actions_buf: ?[]u8 = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *Count = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const filters = this.payload.filters;

            if (this.actions_buf == null) {
                const actions = root.db.encodeInt8Array(
                    u64,
                    this.allocator,
                    filters.actions,
                ) catch |err| {
                    SCOPE.err("Count failed to encode the actions: {t}", .{err});

                    return .{ .err = err };
                };

                this.actions_buf = actions;
            }

            const guild_id_param = root.utils.intToArray(root.types.GuildId, filters.guild_id, .big);
            const actor_id_param = if (filters.actor_id) |actor_id|
                root.utils.intToArray(root.types.UserId, actor_id, .big)
            else
                null;

            const actions = this.actions_buf.?;
            const has_actions = filters.actions.len != 0;

            var params: [3]?[*]const u8 = .{
                &guild_id_param,
                if (actor_id_param != null) &actor_id_param.? else null,
                if (has_actions) actions.ptr else null,
            };

            var lengths: [3]c_int = .{
                @intCast(guild_id_param.len),
                if (actor_id_param != null) @intCast(actor_id_param.?.len) else 0,
                if (has_actions) @intCast(actions.len) else 0,
            };

            var formats: [3]root.db.Connection.Format = @splat(.binary);

            switch (this.db.sendQueryParams(COUNT_QUERY, &params, &lengths, &formats, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("Count failed to send query: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("Count failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                if (res.ntuples() == 0) {
                    return .{ .ready = 0 };
                }

                return .{ .ready = res.readInt(u64, 0, 0) };
            }

            return .{ .ready = 0 };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *Count = @ptrCast(@alignCast(ctx));

        if (this.actions_buf) |buf| {
            this.allocator.free(buf);
            this.actions_buf = null;
        }

        this.db.release();
    }

    pub inline fn init(
        allocator: std.mem.Allocator,
        db: *root.db.Connection,
        payload: Payload,
    ) Count {
        db.acquire();

        return .{
            .allocator = allocator,
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *Count) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};
