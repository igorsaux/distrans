// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../../root.zig");

const SCOPE = std.log.scoped(.@"/api/guilds/{guild_id}/messages/search");

inline fn badParameter(response: *root.http.Response, comptime name: []const u8) !root.http.Task {
    return try root.route.generic.badRequestReasonTask(response, "Bad '" ++ name ++ "' parameter");
}

inline fn parseBool(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "true")) {
        return true;
    }

    if (std.mem.eql(u8, value, "false")) {
        return false;
    }

    return null;
}

/// Parses `author_types` into a mask (bit 0 = user, bit 1 = bot, bit 2 =
/// webhook). Returns `null` on an empty list or an unknown value.
inline fn parseAuthorTypes(value: []const u8) ?u8 {
    if (value.len == 0) {
        return null;
    }

    var mask: u8 = 0;
    var it = std.mem.splitScalar(u8, value, ',');

    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "user")) {
            mask |= 1;
        } else if (std.mem.eql(u8, part, "bot")) {
            mask |= 2;
        } else if (std.mem.eql(u8, part, "webhook")) {
            mask |= 4;
        } else {
            return null;
        }
    }

    return mask;
}

/// R1 - user must be logged
/// R2 - the guild exists (404 "Guild not found")
/// R3 - results are restricted to channels where the caller has effective
///      read_messages; unreadable channels are silently excluded (never 403)
/// R4 - the response is the envelope `{"messages": [...], "total": N}` where
///      `messages` are full message objects (`channel_id` included), ordered by
///      `sort` (newest first by default, oldest first when requested) and
///      paginated with `offset`/`limit`; `total` is the exact number of
///      matches, independent of the requested page
const SearchTask = struct {
    const Task = root.http.Task;

    pub const Response = struct {
        messages: []const root.route.types.Message,
        total: u64,
    };

    pub const Payload = struct {
        filters: root.repo.search.Filters,
        limit: usize,
        offset: usize = 0,
        /// `true` when `sort=oldest` (id ascending).
        ascending: bool = false,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    guild_exists_task: ?root.repo.guilds.Exists.Lazy = null,
    get_guild_channel_permissions_task: ?root.repo.rights.GetGuildChannelPermissions.Lazy = null,
    filters: root.repo.search.Filters = undefined,
    rights_ready: bool = false,
    count_task: ?root.repo.search.Count.Lazy = null,
    total: u64 = 0,
    search_stream: ?root.repo.search.Search.Lazy = null,
    result: std.ArrayList(root.route.types.Message) = .empty,
    body: ?[]const u8 = null,
    streamer: ?root.http.Response.Streamer = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *SearchTask = @ptrCast(@alignCast(ctx));

        if (this.db == null) {
            this.db = root.db_pool.rent() orelse {
                return .{ .pending = .db };
            };
        }

        // R1
        // await this.bearer_middleware_task
        {
            if (this.bearer_middleware_task == null) {
                this.bearer_middleware_task = .from(.init(this.request, this.response, this.db.?));
            }

            while (this.bearer_middleware_task.?.await()) |res| {
                return res.discard();
            }

            if (this.bearer_middleware_task.?.result == null) {
                // response handled in the middleware
                return .ready;
            }
        }

        const db = this.db.?;

        // R2
        // await this.guild_exists_task
        {
            if (this.guild_exists_task == null) {
                this.guild_exists_task = .from(.init(db, .{
                    .id = this.filters.guild_id,
                }));
            }

            while (this.guild_exists_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.guild_exists_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Guild not found");
            }
        }

        // R3
        // await this.get_guild_channel_permissions_task
        {
            if (this.get_guild_channel_permissions_task == null) {
                this.get_guild_channel_permissions_task = .from(.init(this.response.allocator, db, .{
                    .guild_id = this.filters.guild_id,
                    .user_id = this.bearer_middleware_task.?.result.?,
                }));
            }

            while (this.get_guild_channel_permissions_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.rights_ready) {
                const permissions = this.get_guild_channel_permissions_task.?.result;

                this.filters.base_readable = permissions.base.read_messages;

                var denied: std.ArrayList(root.types.ChannelId) = .empty;
                var allowed: std.ArrayList(root.types.ChannelId) = .empty;

                for (permissions.channels) |channel| {
                    if (channel.permissions.read_messages) {
                        if (!this.filters.base_readable) {
                            allowed.append(this.response.allocator, channel.channel_id) catch |err| {
                                SCOPE.err("GET failed to append an allowed channel: {t}", .{err});

                                return .{ .err = err };
                            };
                        }
                    } else if (this.filters.base_readable) {
                        denied.append(this.response.allocator, channel.channel_id) catch |err| {
                            SCOPE.err("GET failed to append a denied channel: {t}", .{err});

                            return .{ .err = err };
                        };
                    }
                }

                this.filters.denied_channels = denied.items;
                this.filters.allowed_channels = allowed.items;
                this.rights_ready = true;
            }
        }

        // R4
        // await this.count_task
        {
            if (this.count_task == null) {
                this.count_task = .from(.init(
                    this.response.allocator,
                    db,
                    .{ .filters = this.filters },
                ));
            }

            while (this.count_task.?.await()) |res| {
                return res.discard();
            }

            this.total = this.count_task.?.result;
        }

        // R4
        // await this.search_stream
        {
            if (this.search_stream == null) {
                this.search_stream = .from(.init(
                    this.response.allocator,
                    db,
                    .{
                        .filters = this.filters,
                        .limit = this.payload.limit,
                        .offset = this.payload.offset,
                        .ascending = this.payload.ascending,
                        .me_user_id = this.bearer_middleware_task.?.result.?,
                    },
                ));
            }

            while (this.search_stream.?.await()) |res| {
                switch (res) {
                    .next => |n| {
                        const message = root.route.types.Message.fromRepo(this.response.allocator, n) catch |err| {
                            return .{ .err = err };
                        };

                        this.result.append(this.response.allocator, message) catch |err| {
                            SCOPE.err("GET failed to append a message: {t}", .{err});

                            return .{ .err = err };
                        };
                    },
                    .poll => |p| return p.discard(),
                }
            }
        }

        if (this.body == null) {
            var writer: std.Io.Writer.Allocating = .init(this.response.allocator);

            const response: Response = .{
                .messages = this.result.items,
                .total = this.total,
            };

            std.json.fmt(response, .{}).format(&writer.writer) catch |err| {
                SCOPE.err("GET failed to serialize the response: {t}", .{err});

                return .{ .err = err };
            };

            this.body = writer.written();
        }

        if (this.streamer == null) {
            var writer = this.response.getWriter();

            if (!writer.writeCode(.ok)) {
                return .{ .pending = .want_write };
            }

            if (!writer.beginJSON(this.body.?.len)) {
                return .{ .pending = .want_write };
            }

            writer.commit();
            this.streamer = this.response.getStreamer(this.body.?);
        }

        return this.streamer.?.poll();
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *SearchTask = @ptrCast(@alignCast(ctx));

        if (this.bearer_middleware_task) |*t| {
            t.dispose();
            this.bearer_middleware_task = null;
        }

        if (this.guild_exists_task) |*t| {
            t.dispose();
            this.guild_exists_task = null;
        }

        if (this.get_guild_channel_permissions_task) |*t| {
            t.dispose();
            this.get_guild_channel_permissions_task = null;
        }

        if (this.count_task) |*t| {
            t.dispose();
            this.count_task = null;
        }

        if (this.search_stream) |*s| {
            s.dispose();
            this.search_stream = null;
        }

        if (this.db) |db| {
            db.release();
            this.db = null;
        }
    }

    pub inline fn task(
        request: *const root.http.Request,
        response: *root.http.Response,
        payload: Payload,
    ) !Task {
        const this = try response.allocator.create(SearchTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .request = request,
            .response = response,
            .payload = payload,
            .filters = payload.filters,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// GET /api/guilds/{guild_id}/messages/search
/// R1 - limit > 0 and limit <= api.messages.max_messages_limit (parsed here)
/// R2 - every filter parameter is well-formed (parsed here)
/// R3 - 'sort' is newest|oldest and 'offset' is a non-negative integer
///      (parsed here)
pub inline fn searchHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    guild_id: root.types.GuildId,
) !root.http.Task {
    _ = allocator;

    const max_filter_ids = root.options.api.search.max_filter_ids;

    var limit: usize = @min(25, root.options.api.messages.max_messages_limit);
    var offset: usize = 0;
    var ascending: bool = false;
    var channels: []const root.types.ChannelId = &.{};
    var authors: []const root.types.UserId = &.{};
    var mentions: []const root.types.UserId = &.{};
    var mention_roles: []const root.types.RoleId = &.{};
    var author_types: ?u8 = null;
    var has_attachments: ?bool = null;
    var pinned: ?bool = null;
    var content: ?[]const u8 = null;
    var after_ms: ?u64 = null;
    var before_ms: ?u64 = null;

    for (request.params) |kvp| {
        const key = kvp.key;
        const value = kvp.value;

        if (std.mem.eql(u8, key, "limit")) {
            limit = std.fmt.parseInt(usize, value, 10) catch {
                return try badParameter(response, "limit");
            };

            // R1
            if (limit == 0 or limit > root.options.api.messages.max_messages_limit) {
                return try badParameter(response, "limit");
            }
        } else if (std.mem.eql(u8, key, "offset")) {
            offset = std.fmt.parseInt(usize, value, 10) catch {
                return try badParameter(response, "offset");
            };

            // R3
            if (offset > std.math.maxInt(i64)) {
                return try badParameter(response, "offset");
            }
        } else if (std.mem.eql(u8, key, "sort")) {
            // R3
            if (std.mem.eql(u8, value, "newest")) {
                ascending = false;
            } else if (std.mem.eql(u8, value, "oldest")) {
                ascending = true;
            } else {
                return try badParameter(response, "sort");
            }
        } else if (std.mem.eql(u8, key, "channels")) {
            channels = root.utils.parseIdList(root.types.ChannelId, response.allocator, value, max_filter_ids) catch {
                return try badParameter(response, "channels");
            };
        } else if (std.mem.eql(u8, key, "authors")) {
            authors = root.utils.parseIdList(root.types.UserId, response.allocator, value, max_filter_ids) catch {
                return try badParameter(response, "authors");
            };
        } else if (std.mem.eql(u8, key, "mentions")) {
            mentions = root.utils.parseIdList(root.types.UserId, response.allocator, value, max_filter_ids) catch {
                return try badParameter(response, "mentions");
            };
        } else if (std.mem.eql(u8, key, "mention_roles")) {
            mention_roles = root.utils.parseIdList(root.types.RoleId, response.allocator, value, max_filter_ids) catch {
                return try badParameter(response, "mention_roles");
            };
        } else if (std.mem.eql(u8, key, "author_types")) {
            author_types = parseAuthorTypes(value) orelse {
                return try badParameter(response, "author_types");
            };
        } else if (std.mem.eql(u8, key, "has_attachments")) {
            has_attachments = parseBool(value) orelse {
                return try badParameter(response, "has_attachments");
            };
        } else if (std.mem.eql(u8, key, "pinned")) {
            pinned = parseBool(value) orelse {
                return try badParameter(response, "pinned");
            };
        } else if (std.mem.eql(u8, key, "content")) {
            const normalized = root.unicode.normalize(response.allocator, value) catch |err| switch (err) {
                error.InvalidUtf8 => return try badParameter(response, "content"),
                error.OutOfMemory => return error.OutOfMemory,
            };

            const codepoints = std.unicode.utf8CountCodepoints(normalized) catch unreachable;

            if (codepoints < root.options.api.search.min_content_codepoints or
                codepoints > root.options.api.search.max_content_codepoints)
            {
                return try badParameter(response, "content");
            }

            content = root.utils.escapeLikePattern(response.allocator, normalized) catch |err| {
                return err;
            };
        } else if (std.mem.eql(u8, key, "after")) {
            after_ms = std.fmt.parseInt(u64, value, 10) catch {
                return try badParameter(response, "after");
            };
        } else if (std.mem.eql(u8, key, "before")) {
            before_ms = std.fmt.parseInt(u64, value, 10) catch {
                return try badParameter(response, "before");
            };
        } else {
            return try root.route.generic.badRequestReasonTask(response, "Unknown parameter");
        }
    }

    return try SearchTask.task(request, response, .{
        .filters = .{
            .guild_id = guild_id,
            .channels = channels,
            .authors = authors,
            .mentions = mentions,
            .mention_roles = mention_roles,
            .author_types = author_types,
            .has_attachments = has_attachments,
            .pinned = pinned,
            .content = content,
            .after_ms = after_ms,
            .before_ms = before_ms,
        },
        .limit = limit,
        .offset = offset,
        .ascending = ascending,
    });
}
