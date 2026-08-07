// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../../root.zig");

const SCOPE = std.log.scoped(.@"/api/guilds/{guild_id}/audit-log");

inline fn badParameter(response: *root.http.Response, comptime name: []const u8) !root.http.Task {
    return try root.route.generic.badRequestReasonTask(response, "Bad '" ++ name ++ "' parameter");
}

/// R1 - user must be logged
/// R2 - the guild exists (404 "Guild not found")
/// R3 - the caller must have the base `view_audit_log` permission (403 "Missing
///      permissions")
/// R4 - the response is the envelope `{"entries": [...], "total": N}`, ordered by
///      `sort` (newest first by default) and paginated with `offset`/`limit`;
///      `total` is the exact number of matches, independent of the requested page
const GetTask = struct {
    const Task = root.http.Task;

    pub const ResponseItem = struct {
        id: []const u8,
        actor_id: ?[]const u8,
        action: []const u8,
        target_id: ?[]const u8,
        target_user_id: ?[]const u8,
        channel_id: ?[]const u8,
        /// Unix epoch, milliseconds.
        created_at: u64,
    };

    pub const Response = struct {
        entries: []const ResponseItem,
        total: u64,
    };

    pub const Payload = struct {
        filters: root.repo.audit_log.Filters,
        limit: usize,
        offset: usize = 0,
        /// `true` for `sort=oldest` (id ascending).
        ascending: bool = false,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    guild_exists_task: ?root.repo.guilds.Exists.Lazy = null,
    check_user_guild_rights_task: ?root.repo.rights.CheckUserGuildRights.Lazy = null,
    count_task: ?root.repo.audit_log.Count.Lazy = null,
    total: u64 = 0,
    search_stream: ?root.repo.audit_log.Search.Lazy = null,
    result: std.ArrayList(ResponseItem) = .empty,
    body: ?[]const u8 = null,
    streamer: ?root.http.Response.Streamer = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *GetTask = @ptrCast(@alignCast(ctx));

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
                    .id = this.payload.filters.guild_id,
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
        // await this.check_user_guild_rights_task
        {
            if (this.check_user_guild_rights_task == null) {
                this.check_user_guild_rights_task = .from(.init(db, .{
                    .guild_id = this.payload.filters.guild_id,
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .required = .{ .view_audit_log = true },
                }));
            }

            while (this.check_user_guild_rights_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.check_user_guild_rights_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
            }
        }

        // R4
        // await this.count_task
        {
            if (this.count_task == null) {
                this.count_task = .from(.init(
                    this.response.allocator,
                    db,
                    .{ .filters = this.payload.filters },
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
                        .filters = this.payload.filters,
                        .limit = this.payload.limit,
                        .offset = this.payload.offset,
                        .ascending = this.payload.ascending,
                    },
                ));
            }

            while (this.search_stream.?.await()) |res| {
                switch (res) {
                    .next => |n| {
                        const item = this.makeItem(n) catch |err| {
                            SCOPE.err("GET failed to build an entry: {t}", .{err});

                            return .{ .err = err };
                        };

                        this.result.append(this.response.allocator, item) catch |err| {
                            SCOPE.err("GET failed to append an entry: {t}", .{err});

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
                .entries = this.result.items,
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

    fn makeItem(this: *GetTask, n: root.repo.audit_log.Search.Item) !ResponseItem {
        const allocator = this.response.allocator;

        const id = std.fmt.allocPrint(allocator, "{}", .{n.id}) catch |err| {
            return err;
        };
        errdefer allocator.free(id);

        const actor_id = if (n.actor_id) |actor_id|
            std.fmt.allocPrint(allocator, "{}", .{actor_id}) catch |err| {
                return err;
            }
        else
            null;

        const target_id = if (n.target_id) |target_id|
            std.fmt.allocPrint(allocator, "{}", .{target_id}) catch |err| {
                return err;
            }
        else
            null;

        const target_user_id = if (n.target_user_id) |target_user_id|
            std.fmt.allocPrint(allocator, "{}", .{target_user_id}) catch |err| {
                return err;
            }
        else
            null;

        const channel_id = if (n.channel_id) |channel_id|
            std.fmt.allocPrint(allocator, "{}", .{channel_id}) catch |err| {
                return err;
            }
        else
            null;

        return .{
            .id = id,
            .actor_id = actor_id,
            .action = @tagName(n.action),
            .target_id = target_id,
            .target_user_id = target_user_id,
            .channel_id = channel_id,
            .created_at = n.created_at,
        };
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetTask = @ptrCast(@alignCast(ctx));

        if (this.bearer_middleware_task) |*t| {
            t.dispose();
            this.bearer_middleware_task = null;
        }

        if (this.guild_exists_task) |*t| {
            t.dispose();
            this.guild_exists_task = null;
        }

        if (this.check_user_guild_rights_task) |*t| {
            t.dispose();
            this.check_user_guild_rights_task = null;
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
        const this = try response.allocator.create(GetTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .request = request,
            .response = response,
            .payload = payload,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// GET /api/guilds/{guild_id}/audit-log
/// R1 - `limit` is 1..api.audit_log.max_entries_limit, `offset` is a
///      non-negative integer and `sort` is newest|oldest (parsed here)
/// R2 - `user` is a decimal user id and `action` is a comma-separated list of
///      known action names (parsed here)
pub inline fn getHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    guild_id: root.types.GuildId,
) !root.http.Task {
    _ = allocator;

    var limit: usize = @min(25, root.options.api.audit_log.max_entries_limit);
    var offset: usize = 0;
    var ascending: bool = false;
    var actor_id: ?root.types.UserId = null;
    var actions: []const u64 = &.{};

    for (request.params) |kvp| {
        const key = kvp.key;
        const value = kvp.value;

        if (std.mem.eql(u8, key, "limit")) {
            limit = std.fmt.parseInt(usize, value, 10) catch {
                return try badParameter(response, "limit");
            };

            // R1
            if (limit == 0 or limit > root.options.api.audit_log.max_entries_limit) {
                return try badParameter(response, "limit");
            }
        } else if (std.mem.eql(u8, key, "offset")) {
            offset = std.fmt.parseInt(usize, value, 10) catch {
                return try badParameter(response, "offset");
            };

            // R1
            if (offset > std.math.maxInt(i64)) {
                return try badParameter(response, "offset");
            }
        } else if (std.mem.eql(u8, key, "sort")) {
            // R1
            if (std.mem.eql(u8, value, "newest")) {
                ascending = false;
            } else if (std.mem.eql(u8, value, "oldest")) {
                ascending = true;
            } else {
                return try badParameter(response, "sort");
            }
        } else if (std.mem.eql(u8, key, "user")) {
            // R2
            actor_id = std.fmt.parseInt(root.types.UserId, value, 10) catch {
                return try badParameter(response, "user");
            };
        } else if (std.mem.eql(u8, key, "action")) {
            // R2
            var parsed: std.ArrayList(u64) = .empty;

            var it = std.mem.splitScalar(u8, value, ',');

            while (it.next()) |part| {
                if (part.len == 0) {
                    return try badParameter(response, "action");
                }

                const action = std.meta.stringToEnum(root.types.AuditAction, part) orelse {
                    return try badParameter(response, "action");
                };

                parsed.append(response.allocator, @intFromEnum(action)) catch |err| {
                    return err;
                };
            }

            if (parsed.items.len == 0) {
                return try badParameter(response, "action");
            }

            actions = parsed.items;
        } else {
            return try root.route.generic.badRequestReasonTask(response, "Unknown parameter");
        }
    }

    return try GetTask.task(request, response, .{
        .filters = .{
            .guild_id = guild_id,
            .actor_id = actor_id,
            .actions = actions,
        },
        .limit = limit,
        .offset = offset,
        .ascending = ascending,
    });
}
