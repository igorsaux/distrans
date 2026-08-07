// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../../../../root.zig");

const SCOPE = std.log.scoped(.@"/api/users/@me/guilds/{guild_id}/notifications");

/// R1 - user must be logged (bearer); deleted users are rejected
/// R2 - the guild must exist (404 "Guild not found")
/// R3 - responds 200 with the caller's guild notification settings; the
///      defaults (all_messages, false, false, true) are returned when the
///      user has never changed them (never 404)
const GetTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        guild_id: root.types.GuildId,
    };

    const Response = struct {
        level: []const u8,
        suppress_everyone: bool,
        suppress_roles: bool,
        push: bool,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    guild_exists_task: ?root.repo.guilds.Exists.Lazy = null,
    get_task: ?root.repo.notifications.GetGuild.Lazy = null,
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
        // await this.guild_exists_task
        {
            if (this.guild_exists_task == null) {
                this.guild_exists_task = .from(.init(this.db.?, .{
                    .id = this.payload.guild_id,
                }));
            }

            while (this.guild_exists_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.guild_exists_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Guild not found");
            }
        }

        // await this.get_task
        {
            if (this.get_task == null) {
                this.get_task = .from(.init(this.db.?, .{
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .guild_id = this.payload.guild_id,
                }));
            }

            while (this.get_task.?.await()) |res| {
                return res.discard();
            }
        }

        if (this.body == null) {
            // R3
            const response: Response = if (this.get_task.?.result) |row| .{
                .level = @tagName(row.level),
                .suppress_everyone = row.suppress_everyone,
                .suppress_roles = row.suppress_roles,
                .push = row.push,
            } else .{
                .level = @tagName(root.types.GuildNotificationLevel.default),
                .suppress_everyone = false,
                .suppress_roles = false,
                .push = true,
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

        if (this.guild_exists_task) |*t| {
            t.dispose();
            this.guild_exists_task = null;
        }

        if (this.get_task) |*t| {
            t.dispose();
            this.get_task = null;
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
/// R3 - the guild must exist (404 "Guild not found")
/// R4 - the body must be a JSON object with at least one recognized field
///      (400 "Expected an object" / "Nothing to update")
/// R5 - optional "level": one of all_messages/only_mentions/nothing
///      (400 "'level' is not a string" / "'level' is invalid")
/// R6 - optional "suppress_everyone"/"suppress_roles"/"push": JSON boolean
///      (400 "'<field>' is not a boolean")
/// R7 - the fields present are merged into the caller's settings (absent =
///      unchanged) and stored; responds 204 No Content, no gateway event
const PatchTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        guild_id: root.types.GuildId,
    };

    const Content = struct {
        level: root.types.GuildNotificationLevel = .default,
        level_set: bool = false,
        suppress_everyone: bool = false,
        suppress_everyone_set: bool = false,
        suppress_roles: bool = false,
        suppress_roles_set: bool = false,
        push: bool = false,
        push_set: bool = false,

        inline fn anySet(this: *const Content) bool {
            return this.level_set or
                this.suppress_everyone_set or
                this.suppress_roles_set or
                this.push_set;
        }
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    guild_exists_task: ?root.repo.guilds.Exists.Lazy = null,
    content: ?Content = null,
    get_task: ?root.repo.notifications.GetGuild.Lazy = null,
    upsert_task: ?root.repo.notifications.UpsertGuild.Lazy = null,

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
        // await this.guild_exists_task
        {
            if (this.guild_exists_task == null) {
                this.guild_exists_task = .from(.init(this.db.?, .{
                    .id = this.payload.guild_id,
                }));
            }

            while (this.guild_exists_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.guild_exists_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Guild not found");
            }
        }

        // R4, R5, R6
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

                content.level = root.utils.enumFromString(root.types.GuildNotificationLevel, level_value.string) orelse {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'level' is invalid");

                    return .ready;
                };
                content.level_set = true;
            }

            // R6
            if (root_value.object.get("suppress_everyone")) |value| {
                if (value != .bool) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'suppress_everyone' is not a boolean");

                    return .ready;
                }

                content.suppress_everyone = value.bool;
                content.suppress_everyone_set = true;
            }

            // R6
            if (root_value.object.get("suppress_roles")) |value| {
                if (value != .bool) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'suppress_roles' is not a boolean");

                    return .ready;
                }

                content.suppress_roles = value.bool;
                content.suppress_roles_set = true;
            }

            // R6
            if (root_value.object.get("push")) |value| {
                if (value != .bool) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'push' is not a boolean");

                    return .ready;
                }

                content.push = value.bool;
                content.push_set = true;
            }

            // R4
            if (!content.anySet()) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Nothing to update");

                return .ready;
            }

            this.content = content;
        }

        // R7
        // await this.get_task
        {
            if (this.get_task == null) {
                this.get_task = .from(.init(this.db.?, .{
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .guild_id = this.payload.guild_id,
                }));
            }

            while (this.get_task.?.await()) |res| {
                return res.discard();
            }
        }

        // R7
        // await this.upsert_task
        {
            if (this.upsert_task == null) {
                const content = this.content.?;
                const current: root.repo.notifications.GetGuild.Item = this.get_task.?.result orelse .{
                    .level = .default,
                    .suppress_everyone = false,
                    .suppress_roles = false,
                    .push = true,
                };

                this.upsert_task = .from(.init(this.db.?, .{
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .guild_id = this.payload.guild_id,
                    .level = if (content.level_set) content.level else current.level,
                    .suppress_everyone = if (content.suppress_everyone_set) content.suppress_everyone else current.suppress_everyone,
                    .suppress_roles = if (content.suppress_roles_set) content.suppress_roles else current.suppress_roles,
                    .push = if (content.push_set) content.push else current.push,
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

        if (this.guild_exists_task) |*t| {
            t.dispose();
            this.guild_exists_task = null;
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

/// GET /api/users/@me/guilds/{guild_id}/notifications
/// R1 - user must be logged (see the R-list above GetTask)
pub inline fn getHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    guild_id: root.types.GuildId,
) !GetTask.Task {
    _ = allocator;

    return try GetTask.task(request, response, .{
        .guild_id = guild_id,
    });
}

/// PATCH /api/users/@me/guilds/{guild_id}/notifications
/// R1 - content type must be application/json (415) and body non-empty (400)
///      (see the R-list above PatchTask)
pub inline fn patchHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    guild_id: root.types.GuildId,
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
        .guild_id = guild_id,
    });
}
