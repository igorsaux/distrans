// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const pq = @import("pq");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.repo_search);

/// Filters shared by the page query (`Search`) and the count query (`Count`).
/// A nullable field means "filter absent"; id-list fields match any of their
/// values (OR within a filter). The `read_messages` gate is passed in as
/// channel id arrays computed by the route
/// (`repo.rights.GetGuildChannelPermissions`), so the queries never re-derive
/// permissions.
pub const Filters = struct {
    guild_id: root.types.GuildId,

    channels: []const root.types.ChannelId = &.{},
    authors: []const root.types.UserId = &.{},
    mentions: []const root.types.UserId = &.{},
    mention_roles: []const root.types.RoleId = &.{},
    /// Bitmask: bit 0 = user, bit 1 = bot, bit 2 = webhook. `null` = absent.
    author_types: ?u8 = null,

    has_attachments: ?bool = null,
    pinned: ?bool = null,

    /// Message-text profile, already normalized and LIKE-escaped.
    content: ?[]const u8 = null,
    after_ms: ?u64 = null,
    before_ms: ?u64 = null,

    /// Whether the caller can read every channel of the guild (their base
    /// permissions include `read_messages`). Filled in by the route.
    base_readable: bool = false,
    /// Channels whose effective mask lacks `read_messages`; consulted only
    /// when `base_readable` is true.
    denied_channels: []const root.types.ChannelId = &.{},
    /// Channels whose effective mask includes `read_messages`; consulted only
    /// when `base_readable` is false.
    allowed_channels: []const root.types.ChannelId = &.{},
};

/// Shared `FROM`/`WHERE` of the search and count queries. Covers placeholders
/// `$1..$14` (the filters); each query appends its own trailing placeholders.
/// The `LEFT JOIN app.users` is required by the `author_types` filter.
const FILTERS_FROM_PREFIX: []const u8 =
    \\FROM app.messages m
    \\LEFT JOIN app.users u ON u.id = m.author_id
    \\WHERE m.guild_id = $1
    \\  AND m.deleted_at IS NULL
    \\  AND ($2::bigint[] IS NULL OR m.channel_id = ANY($2))
    \\  AND ($3::bigint[] IS NULL OR m.author_id = ANY($3))
    \\  AND ($4::bigint[] IS NULL OR m.mention_user_ids && $4)
    \\  AND ($5::bigint[] IS NULL OR m.mention_role_ids && $5)
    \\  AND ($6::boolean IS NULL OR m.pinned = $6)
;

const FILTERS_FROM_SUFFIX: []const u8 =
    \\  AND ($8::text IS NULL OR m.content ILIKE '%' || $8 || '%')
    \\  AND ($9::bigint IS NULL OR m.created_at >= to_timestamp($9::bigint::double precision / 1000.0))
    \\  AND ($10::bigint IS NULL OR m.created_at < to_timestamp($10::bigint::double precision / 1000.0))
    \\  AND ($11::smallint IS NULL OR
    \\          (m.webhook_id IS NOT NULL AND ($11::smallint & 4) <> 0)
    \\       OR (m.webhook_id IS NULL AND u.is_bot AND ($11::smallint & 2) <> 0)
    \\       OR (m.webhook_id IS NULL AND u.is_bot = false AND ($11::smallint & 1) <> 0))
    \\  AND (
    \\        ($12::boolean AND NOT (m.channel_id = ANY($13::bigint[])))
    \\     OR ((NOT $12::boolean) AND m.channel_id = ANY($14::bigint[])))
;

inline fn filtersFrom(comptime has_attachments: ?bool) []const u8 {
    const filter = if (has_attachments) |has|
        if (has)
            "  AND $7::boolean AND EXISTS (SELECT 1 FROM app.message_attachments ma WHERE ma.message_id = m.id)\n"
        else
            "  AND NOT $7::boolean AND NOT EXISTS (SELECT 1 FROM app.message_attachments ma WHERE ma.message_id = m.id)\n"
    else
        \\  AND ($7::boolean IS NULL OR $7 = EXISTS (
        \\        SELECT 1 FROM app.message_attachments ma WHERE ma.message_id = m.id))
        \\
    ;

    return FILTERS_FROM_PREFIX ++ filter ++ FILTERS_FROM_SUFFIX;
}

const PAGE_SELECT: []const u8 =
    \\SELECT m.id, m.author_id, m.content, m.created_at, m.reply_to_id, m.edited_at, m.embeds,
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
    \\       m.mention_everyone, m.pinned, m.webhook_id, m.channel_id
++ root.repo.channels.reactionsAggregate(17, "m.id") ++
    \\
;

/// `ORDER BY` direction cannot be a bind parameter, so the page query exists in
/// two spellings (`newest` = descending, `oldest` = ascending); `LIMIT $15` is
/// the page size and `OFFSET $16` the page start. Active attachment filters have
/// their own spellings so PostgreSQL can plan them as semi/anti joins.
const PAGE_QUERY_DESC: [:0]const u8 = PAGE_SELECT ++ "\n" ++ filtersFrom(null) ++ "\nORDER BY m.id DESC\nLIMIT $15 OFFSET $16;";
const PAGE_QUERY_ASC: [:0]const u8 = PAGE_SELECT ++ "\n" ++ filtersFrom(null) ++ "\nORDER BY m.id ASC\nLIMIT $15 OFFSET $16;";
const PAGE_QUERY_DESC_ATTACHMENTS: [:0]const u8 = PAGE_SELECT ++ "\n" ++ filtersFrom(true) ++ "\nORDER BY m.id DESC\nLIMIT $15 OFFSET $16;";
const PAGE_QUERY_ASC_ATTACHMENTS: [:0]const u8 = PAGE_SELECT ++ "\n" ++ filtersFrom(true) ++ "\nORDER BY m.id ASC\nLIMIT $15 OFFSET $16;";
const PAGE_QUERY_DESC_NO_ATTACHMENTS: [:0]const u8 = PAGE_SELECT ++ "\n" ++ filtersFrom(false) ++ "\nORDER BY m.id DESC\nLIMIT $15 OFFSET $16;";
const PAGE_QUERY_ASC_NO_ATTACHMENTS: [:0]const u8 = PAGE_SELECT ++ "\n" ++ filtersFrom(false) ++ "\nORDER BY m.id ASC\nLIMIT $15 OFFSET $16;";

const COUNT_QUERY: [:0]const u8 = "SELECT count(*)\n" ++ filtersFrom(null) ++ ";";
const COUNT_QUERY_ATTACHMENTS: [:0]const u8 = "SELECT count(*)\n" ++ filtersFrom(true) ++ ";";
const COUNT_QUERY_NO_ATTACHMENTS: [:0]const u8 = "SELECT count(*)\n" ++ filtersFrom(false) ++ ";";

inline fn materializedPageQuery(comptime ascending: bool, comptime has_attachments: ?bool) [:0]const u8 {
    const direction = if (ascending) "ASC" else "DESC";

    return comptime "WITH matched AS MATERIALIZED (\nSELECT m.id\n" ++ filtersFrom(has_attachments) ++ "\n)\n" ++
        PAGE_SELECT ++ "\nFROM (\nSELECT id FROM matched ORDER BY id " ++ direction ++
        "\nLIMIT $15 OFFSET $16\n) page\nJOIN app.messages m ON m.id = page.id\nORDER BY m.id " ++ direction ++ ";";
}

inline fn pageQuery(ascending: bool, has_attachments: ?bool, materialize_matches: bool) [:0]const u8 {
    if (materialize_matches) {
        if (has_attachments) |has| {
            if (has) {
                return if (ascending) materializedPageQuery(true, true) else materializedPageQuery(false, true);
            }

            return if (ascending) materializedPageQuery(true, false) else materializedPageQuery(false, false);
        }

        return if (ascending) materializedPageQuery(true, null) else materializedPageQuery(false, null);
    }

    if (has_attachments) |has| {
        if (has) {
            return if (ascending) PAGE_QUERY_ASC_ATTACHMENTS else PAGE_QUERY_DESC_ATTACHMENTS;
        }

        return if (ascending) PAGE_QUERY_ASC_NO_ATTACHMENTS else PAGE_QUERY_DESC_NO_ATTACHMENTS;
    }

    return if (ascending) PAGE_QUERY_ASC else PAGE_QUERY_DESC;
}

inline fn countQuery(has_attachments: ?bool) [:0]const u8 {
    if (has_attachments) |has| {
        return if (has) COUNT_QUERY_ATTACHMENTS else COUNT_QUERY_NO_ATTACHMENTS;
    }

    return COUNT_QUERY;
}

/// Per-guild message search. Mirrors `repo.channels.GetMessages` (streamed) but
/// with a fixed, fully parameterized filter query and `offset`/`limit`
/// pagination. `m.id` is unique, so offset pagination is stable. `channel_id`
/// is appended to every row (index 13) so the route can stamp it on results.
pub const Search = struct {
    pub const Result = root.repo.types.Message;

    pub const Stream = root.task.Stream(Result, anyerror);
    pub const Lazy = root.task.LazyStream(Search, Result, anyerror);

    pub const Payload = struct {
        filters: Filters,
        limit: usize,
        offset: usize = 0,
        /// `true` for `sort=oldest` (id ascending), `false` for the default
        /// `sort=newest` (id descending).
        ascending: bool = false,
        materialize_matches: bool = false,
        /// Caller whose per-reaction `me` flag is computed.
        me_user_id: root.types.UserId,
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
    channels_buf: ?[]u8 = null,
    authors_buf: ?[]u8 = null,
    mentions_buf: ?[]u8 = null,
    mention_roles_buf: ?[]u8 = null,
    denied_buf: ?[]u8 = null,
    allowed_buf: ?[]u8 = null,

    fn poll(ctx: *anyopaque) Stream.PollT {
        const this: *Search = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const filters = this.payload.filters;

            if (this.channels_buf == null) {
                this.channels_buf = root.db.encodeInt8Array(
                    root.types.ChannelId,
                    this.allocator,
                    filters.channels,
                ) catch |err| {
                    SCOPE.err("Search failed to encode the channels: {t}", .{err});

                    return .{ .err = err };
                };
            }

            if (this.authors_buf == null) {
                this.authors_buf = root.db.encodeInt8Array(
                    root.types.UserId,
                    this.allocator,
                    filters.authors,
                ) catch |err| {
                    SCOPE.err("Search failed to encode the authors: {t}", .{err});

                    return .{ .err = err };
                };
            }

            if (this.mentions_buf == null) {
                this.mentions_buf = root.db.encodeInt8Array(
                    root.types.UserId,
                    this.allocator,
                    filters.mentions,
                ) catch |err| {
                    SCOPE.err("Search failed to encode the mentions: {t}", .{err});

                    return .{ .err = err };
                };
            }

            if (this.mention_roles_buf == null) {
                this.mention_roles_buf = root.db.encodeInt8Array(
                    root.types.RoleId,
                    this.allocator,
                    filters.mention_roles,
                ) catch |err| {
                    SCOPE.err("Search failed to encode the mention roles: {t}", .{err});

                    return .{ .err = err };
                };
            }

            if (this.denied_buf == null) {
                this.denied_buf = root.db.encodeInt8Array(
                    root.types.ChannelId,
                    this.allocator,
                    filters.denied_channels,
                ) catch |err| {
                    SCOPE.err("Search failed to encode the denied channels: {t}", .{err});

                    return .{ .err = err };
                };
            }

            if (this.allowed_buf == null) {
                this.allowed_buf = root.db.encodeInt8Array(
                    root.types.ChannelId,
                    this.allocator,
                    filters.allowed_channels,
                ) catch |err| {
                    SCOPE.err("Search failed to encode the allowed channels: {t}", .{err});

                    return .{ .err = err };
                };
            }

            const guild_id_param = root.utils.intToArray(root.types.GuildId, filters.guild_id, .big);
            const pinned_param = if (filters.pinned) |pinned|
                root.utils.intToArray(u8, if (pinned) 1 else 0, .big)
            else
                null;
            const has_attachments_param = if (filters.has_attachments) |has_attachments|
                root.utils.intToArray(u8, if (has_attachments) 1 else 0, .big)
            else
                null;
            const author_types_param = if (filters.author_types) |author_types|
                root.utils.intToArray(u16, author_types, .big)
            else
                null;
            const after_ms_param = if (filters.after_ms) |after_ms|
                root.utils.intToArray(u64, after_ms, .big)
            else
                null;
            const before_ms_param = if (filters.before_ms) |before_ms|
                root.utils.intToArray(u64, before_ms, .big)
            else
                null;
            const base_readable_param = root.utils.intToArray(u8, if (filters.base_readable) 1 else 0, .big);
            const limit_param = root.utils.intToArray(i64, @intCast(this.payload.limit), .big);
            const offset_param = root.utils.intToArray(i64, @intCast(this.payload.offset), .big);
            const me_user_id_param = root.utils.intToArray(root.types.UserId, this.payload.me_user_id, .big);

            const content = filters.content;
            const channels = this.channels_buf.?;
            const authors = this.authors_buf.?;
            const mentions = this.mentions_buf.?;
            const mention_roles = this.mention_roles_buf.?;
            const denied = this.denied_buf.?;
            const allowed = this.allowed_buf.?;

            const has_channels = filters.channels.len != 0;
            const has_authors = filters.authors.len != 0;
            const has_mentions = filters.mentions.len != 0;
            const has_mention_roles = filters.mention_roles.len != 0;

            var params: [17]?[*]const u8 = .{
                &guild_id_param,
                if (has_channels) channels.ptr else null,
                if (has_authors) authors.ptr else null,
                if (has_mentions) mentions.ptr else null,
                if (has_mention_roles) mention_roles.ptr else null,
                if (pinned_param != null) &pinned_param.? else null,
                if (has_attachments_param != null) &has_attachments_param.? else null,
                if (content) |text| text.ptr else null,
                if (after_ms_param != null) &after_ms_param.? else null,
                if (before_ms_param != null) &before_ms_param.? else null,
                if (author_types_param != null) &author_types_param.? else null,
                &base_readable_param,
                denied.ptr,
                allowed.ptr,
                &limit_param,
                &offset_param,
                &me_user_id_param,
            };

            var lengths: [17]c_int = .{
                @intCast(guild_id_param.len),
                if (has_channels) @intCast(channels.len) else 0,
                if (has_authors) @intCast(authors.len) else 0,
                if (has_mentions) @intCast(mentions.len) else 0,
                if (has_mention_roles) @intCast(mention_roles.len) else 0,
                if (pinned_param != null) @intCast(pinned_param.?.len) else 0,
                if (has_attachments_param != null) @intCast(has_attachments_param.?.len) else 0,
                if (content) |text| @intCast(text.len) else 0,
                if (after_ms_param != null) @intCast(after_ms_param.?.len) else 0,
                if (before_ms_param != null) @intCast(before_ms_param.?.len) else 0,
                if (author_types_param != null) @intCast(author_types_param.?.len) else 0,
                @intCast(base_readable_param.len),
                @intCast(denied.len),
                @intCast(allowed.len),
                @intCast(limit_param.len),
                @intCast(offset_param.len),
                @intCast(me_user_id_param.len),
            };

            var formats: [17]root.db.Connection.Format = @splat(.binary);

            const query = pageQuery(this.payload.ascending, filters.has_attachments, this.payload.materialize_matches);

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

                std.debug.assert(res.nfields() >= 15);

                const idx = yield.pos;

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
        const this: *Search = @ptrCast(@alignCast(ctx));

        if (this.state == .yielding) {
            this.state.yielding.res.deinit();
        }

        if (this.channels_buf) |buf| {
            this.allocator.free(buf);
            this.channels_buf = null;
        }

        if (this.authors_buf) |buf| {
            this.allocator.free(buf);
            this.authors_buf = null;
        }

        if (this.mentions_buf) |buf| {
            this.allocator.free(buf);
            this.mentions_buf = null;
        }

        if (this.mention_roles_buf) |buf| {
            this.allocator.free(buf);
            this.mention_roles_buf = null;
        }

        if (this.denied_buf) |buf| {
            this.allocator.free(buf);
            this.denied_buf = null;
        }

        if (this.allowed_buf) |buf| {
            this.allocator.free(buf);
            this.allowed_buf = null;
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

/// Exact number of messages matching the same `Filters` as `Search`. Run as a
/// separate query so `total` stays correct even when the requested page is
/// empty (an out-of-range `offset`).
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
    channels_buf: ?[]u8 = null,
    authors_buf: ?[]u8 = null,
    mentions_buf: ?[]u8 = null,
    mention_roles_buf: ?[]u8 = null,
    denied_buf: ?[]u8 = null,
    allowed_buf: ?[]u8 = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *Count = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const filters = this.payload.filters;

            if (this.channels_buf == null) {
                this.channels_buf = root.db.encodeInt8Array(
                    root.types.ChannelId,
                    this.allocator,
                    filters.channels,
                ) catch |err| {
                    SCOPE.err("Count failed to encode the channels: {t}", .{err});

                    return .{ .err = err };
                };
            }

            if (this.authors_buf == null) {
                this.authors_buf = root.db.encodeInt8Array(
                    root.types.UserId,
                    this.allocator,
                    filters.authors,
                ) catch |err| {
                    SCOPE.err("Count failed to encode the authors: {t}", .{err});

                    return .{ .err = err };
                };
            }

            if (this.mentions_buf == null) {
                this.mentions_buf = root.db.encodeInt8Array(
                    root.types.UserId,
                    this.allocator,
                    filters.mentions,
                ) catch |err| {
                    SCOPE.err("Count failed to encode the mentions: {t}", .{err});

                    return .{ .err = err };
                };
            }

            if (this.mention_roles_buf == null) {
                this.mention_roles_buf = root.db.encodeInt8Array(
                    root.types.RoleId,
                    this.allocator,
                    filters.mention_roles,
                ) catch |err| {
                    SCOPE.err("Count failed to encode the mention roles: {t}", .{err});

                    return .{ .err = err };
                };
            }

            if (this.denied_buf == null) {
                this.denied_buf = root.db.encodeInt8Array(
                    root.types.ChannelId,
                    this.allocator,
                    filters.denied_channels,
                ) catch |err| {
                    SCOPE.err("Count failed to encode the denied channels: {t}", .{err});

                    return .{ .err = err };
                };
            }

            if (this.allowed_buf == null) {
                this.allowed_buf = root.db.encodeInt8Array(
                    root.types.ChannelId,
                    this.allocator,
                    filters.allowed_channels,
                ) catch |err| {
                    SCOPE.err("Count failed to encode the allowed channels: {t}", .{err});

                    return .{ .err = err };
                };
            }

            const guild_id_param = root.utils.intToArray(root.types.GuildId, filters.guild_id, .big);
            const pinned_param = if (filters.pinned) |pinned|
                root.utils.intToArray(u8, if (pinned) 1 else 0, .big)
            else
                null;
            const has_attachments_param = if (filters.has_attachments) |has_attachments|
                root.utils.intToArray(u8, if (has_attachments) 1 else 0, .big)
            else
                null;
            const author_types_param = if (filters.author_types) |author_types|
                root.utils.intToArray(u16, author_types, .big)
            else
                null;
            const after_ms_param = if (filters.after_ms) |after_ms|
                root.utils.intToArray(u64, after_ms, .big)
            else
                null;
            const before_ms_param = if (filters.before_ms) |before_ms|
                root.utils.intToArray(u64, before_ms, .big)
            else
                null;
            const base_readable_param = root.utils.intToArray(u8, if (filters.base_readable) 1 else 0, .big);

            const content = filters.content;
            const channels = this.channels_buf.?;
            const authors = this.authors_buf.?;
            const mentions = this.mentions_buf.?;
            const mention_roles = this.mention_roles_buf.?;
            const denied = this.denied_buf.?;
            const allowed = this.allowed_buf.?;

            const has_channels = filters.channels.len != 0;
            const has_authors = filters.authors.len != 0;
            const has_mentions = filters.mentions.len != 0;
            const has_mention_roles = filters.mention_roles.len != 0;

            var params: [14]?[*]const u8 = .{
                &guild_id_param,
                if (has_channels) channels.ptr else null,
                if (has_authors) authors.ptr else null,
                if (has_mentions) mentions.ptr else null,
                if (has_mention_roles) mention_roles.ptr else null,
                if (pinned_param != null) &pinned_param.? else null,
                if (has_attachments_param != null) &has_attachments_param.? else null,
                if (content) |text| text.ptr else null,
                if (after_ms_param != null) &after_ms_param.? else null,
                if (before_ms_param != null) &before_ms_param.? else null,
                if (author_types_param != null) &author_types_param.? else null,
                &base_readable_param,
                denied.ptr,
                allowed.ptr,
            };

            var lengths: [14]c_int = .{
                @intCast(guild_id_param.len),
                if (has_channels) @intCast(channels.len) else 0,
                if (has_authors) @intCast(authors.len) else 0,
                if (has_mentions) @intCast(mentions.len) else 0,
                if (has_mention_roles) @intCast(mention_roles.len) else 0,
                if (pinned_param != null) @intCast(pinned_param.?.len) else 0,
                if (has_attachments_param != null) @intCast(has_attachments_param.?.len) else 0,
                if (content) |text| @intCast(text.len) else 0,
                if (after_ms_param != null) @intCast(after_ms_param.?.len) else 0,
                if (before_ms_param != null) @intCast(before_ms_param.?.len) else 0,
                if (author_types_param != null) @intCast(author_types_param.?.len) else 0,
                @intCast(base_readable_param.len),
                @intCast(denied.len),
                @intCast(allowed.len),
            };

            var formats: [14]root.db.Connection.Format = @splat(.binary);

            switch (this.db.sendQueryParams(countQuery(filters.has_attachments), &params, &lengths, &formats, .binary)) {
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

        if (this.channels_buf) |buf| {
            this.allocator.free(buf);
            this.channels_buf = null;
        }

        if (this.authors_buf) |buf| {
            this.allocator.free(buf);
            this.authors_buf = null;
        }

        if (this.mentions_buf) |buf| {
            this.allocator.free(buf);
            this.mentions_buf = null;
        }

        if (this.mention_roles_buf) |buf| {
            this.allocator.free(buf);
            this.mention_roles_buf = null;
        }

        if (this.denied_buf) |buf| {
            this.allocator.free(buf);
            this.denied_buf = null;
        }

        if (this.allowed_buf) |buf| {
            this.allocator.free(buf);
            this.allowed_buf = null;
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
