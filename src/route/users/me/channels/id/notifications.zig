// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../../../../root.zig");

const SCOPE = std.log.scoped(.@"/api/users/@me/channels/{channel_id}/notifications");

/// R1 - user must be logged (bearer); deleted users are rejected
/// R2 - the channel must exist (404 "Channel not found"); categories are
///      valid targets too (they are the middle tier of the inheritance chain)
/// R3 - responds 200 with the caller's stored `level` and the resolved
///      `effective_level`; a missing row is `level` = "inherit" (never 404)
/// R4 - the effective level resolves channel -> parent category -> guild:
///      `inherit` on a text channel falls back to its parent category's level
///      (which may itself inherit from the guild); a category has no parent,
///      so `inherit` falls back to the guild. `effective_level` is never
///      `inherit`.
const GetTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        channel_id: root.types.ChannelId,
    };

    const Response = struct {
        level: []const u8,
        effective_level: []const u8,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    channel_exists_task: ?root.repo.channels.IsExists.Lazy = null,
    get_task: ?root.repo.notifications.GetChannel.Lazy = null,
    get_parent_task: ?root.repo.notifications.GetChannel.Lazy = null,
    get_guild_task: ?root.repo.notifications.GetGuild.Lazy = null,
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

        // R2
        // await this.channel_exists_task
        {
            if (this.channel_exists_task == null) {
                this.channel_exists_task = .from(.init(this.db.?, .{
                    .channel_id = this.payload.channel_id,
                }));
            }

            while (this.channel_exists_task.?.await()) |res| {
                return res.discard();
            }

            if (this.channel_exists_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Channel not found");
            }
        }

        // await this.get_task
        {
            if (this.get_task == null) {
                this.get_task = .from(.init(this.db.?, .{
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .channel_id = this.payload.channel_id,
                }));
            }

            while (this.get_task.?.await()) |res| {
                return res.discard();
            }
        }

        if (this.body == null) {
            const ChannelLevel = root.types.ChannelNotificationLevel;

            // R3
            const raw: ChannelLevel = if (this.get_task.?.result) |row|
                row.level
            else
                .default;

            // R4
            var effective: ChannelLevel = raw;

            if (effective == .inherit) {
                if (this.channel_exists_task.?.result.?.parent_id) |parent_id| {
                    // await this.get_parent_task
                    {
                        if (this.get_parent_task == null) {
                            this.get_parent_task = .from(.init(this.db.?, .{
                                .user_id = this.bearer_middleware_task.?.result.?,
                                .channel_id = parent_id,
                            }));
                        }

                        while (this.get_parent_task.?.await()) |res| {
                            return res.discard();
                        }
                    }

                    if (this.get_parent_task.?.result) |row| {
                        if (row.level != .inherit) {
                            effective = row.level;
                        }
                    }
                }
            }

            if (effective == .inherit) {
                // await this.get_guild_task
                {
                    if (this.get_guild_task == null) {
                        this.get_guild_task = .from(.init(this.db.?, .{
                            .user_id = this.bearer_middleware_task.?.result.?,
                            .guild_id = this.channel_exists_task.?.result.?.guild_id,
                        }));
                    }

                    while (this.get_guild_task.?.await()) |res| {
                        return res.discard();
                    }
                }

                const guild_level = if (this.get_guild_task.?.result) |row|
                    row.level
                else
                    root.types.GuildNotificationLevel.default;

                effective = switch (guild_level) {
                    .all_messages => .all_messages,
                    .only_mentions => .only_mentions,
                    .nothing => .nothing,
                };
            }

            const response: Response = .{
                .level = @tagName(raw),
                .effective_level = @tagName(effective),
            };

            var writer: std.Io.Writer.Allocating = .init(this.response.allocator);

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
        const this: *GetTask = @ptrCast(@alignCast(ctx));

        if (this.bearer_middleware_task) |*t| {
            t.dispose();
            this.bearer_middleware_task = null;
        }

        if (this.channel_exists_task) |*t| {
            t.dispose();
            this.channel_exists_task = null;
        }

        if (this.get_task) |*t| {
            t.dispose();
            this.get_task = null;
        }

        if (this.get_parent_task) |*t| {
            t.dispose();
            this.get_parent_task = null;
        }

        if (this.get_guild_task) |*t| {
            t.dispose();
            this.get_guild_task = null;
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

/// R1 - content type must be application/json (415) and body non-empty (400)
/// R2 - user must be logged (bearer); deleted users are rejected
/// R3 - the channel must exist (404 "Channel not found"); categories are
///      valid targets too
/// R4 - the body must be a JSON object with at least one recognized field
///      (400 "Expected an object" / "Nothing to update")
/// R5 - optional "level": one of inherit/all_messages/only_mentions/nothing
///      (400 "'level' is not a string" / "'level' is invalid")
/// R6 - the level present is merged into the caller's settings (absent =
///      unchanged) and stored; responds 204 No Content, no gateway event
const PatchTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        channel_id: root.types.ChannelId,
    };

    const Content = struct {
        level: root.types.ChannelNotificationLevel = .default,
        level_set: bool = false,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    channel_exists_task: ?root.repo.channels.IsExists.Lazy = null,
    content: ?Content = null,
    get_task: ?root.repo.notifications.GetChannel.Lazy = null,
    upsert_task: ?root.repo.notifications.UpsertChannel.Lazy = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *PatchTask = @ptrCast(@alignCast(ctx));

        if (this.db == null) {
            this.db = root.db_pool.rent() orelse {
                return .{ .pending = .db };
            };
        }

        // R2
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

        // R3
        // await this.channel_exists_task
        {
            if (this.channel_exists_task == null) {
                this.channel_exists_task = .from(.init(this.db.?, .{
                    .channel_id = this.payload.channel_id,
                }));
            }

            while (this.channel_exists_task.?.await()) |res| {
                return res.discard();
            }

            if (this.channel_exists_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Channel not found");
            }
        }

        // R4, R5
        if (this.content == null) {
            if (!this.request.contentIsAvailable()) {
                return .{ .pending = .want_read };
            }

            const root_value = std.json.parseFromSliceLeaky(std.json.Value, this.response.allocator, this.request.getContent(), .{}) catch {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad JSON");

                return .ready;
            };

            if (root_value != .object) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Expected an object");

                return .ready;
            }

            var content: Content = .{};

            // R5
            if (root_value.object.get("level")) |level_value| {
                if (level_value != .string) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'level' is not a string");

                    return .ready;
                }

                content.level = root.utils.enumFromString(root.types.ChannelNotificationLevel, level_value.string) orelse {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'level' is invalid");

                    return .ready;
                };
                content.level_set = true;
            }

            // R4
            if (!content.level_set) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Nothing to update");

                return .ready;
            }

            this.content = content;
        }

        // R6
        // await this.get_task
        {
            if (this.get_task == null) {
                this.get_task = .from(.init(this.db.?, .{
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .channel_id = this.payload.channel_id,
                }));
            }

            while (this.get_task.?.await()) |res| {
                return res.discard();
            }
        }

        // R6
        // await this.upsert_task
        {
            if (this.upsert_task == null) {
                const content = this.content.?;
                const current: root.repo.notifications.GetChannel.Item = this.get_task.?.result orelse .{
                    .level = .default,
                };

                this.upsert_task = .from(.init(this.db.?, .{
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .channel_id = this.payload.channel_id,
                    .level = if (content.level_set) content.level else current.level,
                }));
            }

            while (this.upsert_task.?.await()) |res| {
                return res.discard();
            }
        }

        var writer = this.response.getWriter();

        if (!writer.writeCode(.no_content)) {
            return .{ .pending = .want_write };
        }

        if (!writer.emptyBody()) {
            return .{ .pending = .want_write };
        }

        writer.commit();

        return .ready;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *PatchTask = @ptrCast(@alignCast(ctx));

        if (this.bearer_middleware_task) |*t| {
            t.dispose();
            this.bearer_middleware_task = null;
        }

        if (this.channel_exists_task) |*t| {
            t.dispose();
            this.channel_exists_task = null;
        }

        if (this.get_task) |*t| {
            t.dispose();
            this.get_task = null;
        }

        if (this.upsert_task) |*t| {
            t.dispose();
            this.upsert_task = null;
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
        const this = try response.allocator.create(PatchTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .request = request,
            .response = response,
            .payload = payload,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// GET /api/users/@me/channels/{channel_id}/notifications
/// R1 - user must be logged (see the R-list above GetTask)
pub inline fn getHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    channel_id: root.types.ChannelId,
) !GetTask.Task {
    _ = allocator;

    return try GetTask.task(request, response, .{
        .channel_id = channel_id,
    });
}

/// PATCH /api/users/@me/channels/{channel_id}/notifications
/// R1 - content type must be application/json (415) and body non-empty (400)
///      (see the R-list above PatchTask)
pub inline fn patchHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    channel_id: root.types.ChannelId,
) !PatchTask.Task {
    _ = allocator;

    // R1
    if (request.getContentLength() == 0) {
        return try root.route.generic.badRequestTask(response);
    }

    // R1
    if (!root.utils.startsWithMaybe(u8, request.content_type, "application/json")) {
        return try root.route.generic.unsupportedMediaTypeTask(response);
    }

    return try PatchTask.task(request, response, .{
        .channel_id = channel_id,
    });
}
