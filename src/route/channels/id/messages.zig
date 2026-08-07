// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../../root.zig");

const SCOPE = std.log.scoped(.@"/api/channels/{channel_id}/messages");

/// R2 - user must be logged
/// R3 - the channel exists
/// R4 - user has rights to view messages
/// R5 - each returned message includes its "attachments" (objects, ordered)
///      and its mentions ("mention_everyone", "mentions", "mention_roles")
const GetTask = struct {
    const Task = root.http.Task;

    pub const Response = root.route.types.Message;

    pub const Payload = struct {
        channel_id: root.types.ChannelId,
        limit: usize,
        mode: root.repo.channels.GetMessages.Mode,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    channel_exists_task: ?root.repo.channels.IsExists.Lazy = null,
    check_user_channel_rights_task: ?root.repo.rights.CheckUserChannelRights.Lazy = null,
    get_channel_messages_stream: ?root.repo.channels.GetMessages.Lazy = null,
    get_channel_messages_stream_result: std.ArrayList(Response) = .empty,
    body: ?[]const u8 = null,
    streamer: ?root.http.Response.Streamer = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *GetTask = @ptrCast(@alignCast(ctx));

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

        const db = this.db.?;

        // R3
        // await this.channel_exists_task
        {
            if (this.channel_exists_task == null) {
                this.channel_exists_task = .from(.init(db, .{
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

        // R4
        // await this.check_user_channels_rights_task
        {
            if (this.check_user_channel_rights_task == null) {
                this.check_user_channel_rights_task = .from(.init(this.db.?, .{
                    .guild_id = this.channel_exists_task.?.result.?.guild_id,
                    .channel_id = this.payload.channel_id,
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .required = .{ .read_messages = true },
                }));
            }

            while (this.check_user_channel_rights_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.check_user_channel_rights_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
            }
        }

        // await this.get_channel_messages_stream
        {
            if (this.get_channel_messages_stream == null) {
                this.get_channel_messages_stream = .from(.init(
                    db,
                    .{
                        .channel_id = this.payload.channel_id,
                        .limit = this.payload.limit,
                        .mode = this.payload.mode,
                        .user_id = this.bearer_middleware_task.?.result.?,
                    },
                ));
            }

            while (this.get_channel_messages_stream.?.await()) |res| {
                switch (res) {
                    .next => |n| {
                        const message = root.route.types.Message.fromRepo(this.response.allocator, n) catch |err| {
                            return .{ .err = err };
                        };

                        this.get_channel_messages_stream_result.append(this.response.allocator, message) catch |err| {
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

            std.json.fmt(this.get_channel_messages_stream_result.items, .{}).format(&writer.writer) catch {
                SCOPE.err("GET failed to JSON format the response", .{});

                return .{ .err = error.OutOfMemory };
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

        if (this.check_user_channel_rights_task) |*t| {
            t.dispose();
            this.check_user_channel_rights_task = null;
        }

        if (this.get_channel_messages_stream) |*s| {
            s.dispose();
            this.get_channel_messages_stream = null;
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

/// GET /api/channels/{channel_id}/messages
/// R1 - limit > 0 and limit <= root.options.api.messages.max_messages_limit
/// R2 - 'before', 'after' and 'around' are mutually exclusive
pub inline fn getHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    channel_id: root.types.ChannelId,
) !root.http.Task {
    _ = allocator;

    var limit: ?usize = null;

    var params: usize = 0;
    var before: ?usize = null;
    var after: ?usize = null;
    var around: ?usize = null;

    for (request.params) |kvp| {
        if (std.mem.eql(u8, kvp.key, "limit")) {
            limit = std.fmt.parseInt(usize, kvp.value, 10) catch {
                return try root.route.generic.badRequestReasonTask(response, "Bad 'limit' parameter");
            };

            // R1
            if (limit.? == 0 or limit.? > root.options.api.messages.max_messages_limit) {
                return try root.route.generic.badRequestReasonTask(response, "Bad 'limit' parameter");
            }
        } else if (std.mem.eql(u8, kvp.key, "before")) {
            before = std.fmt.parseInt(usize, kvp.value, 10) catch {
                return try root.route.generic.badRequestReasonTask(response, "Bad 'before' parameter");
            };

            params += 1;
        } else if (std.mem.eql(u8, kvp.key, "after")) {
            after = std.fmt.parseInt(usize, kvp.value, 10) catch {
                return try root.route.generic.badRequestReasonTask(response, "Bad 'after' parameter");
            };

            params += 1;
        } else if (std.mem.eql(u8, kvp.key, "around")) {
            around = std.fmt.parseInt(usize, kvp.value, 10) catch {
                return try root.route.generic.badRequestReasonTask(response, "Bad 'around' parameter");
            };

            params += 1;
        } else {
            return try root.route.generic.badRequestReasonTask(response, "Unknown parameter");
        }
    }

    // R2
    if (params > 1) {
        return try root.route.generic.badRequestReasonTask(
            response,
            "Parameters 'before', 'after' and 'around' are mutually exclusive",
        );
    }

    return try GetTask.task(request, response, .{
        .channel_id = channel_id,
        .limit = limit orelse 50,
        .mode = if (before != null)
            .{ .before = before.? }
        else if (after != null)
            .{ .after = after.? }
        else if (around != null)
            .{ .around = around.? }
        else
            .last,
    });
}

/// R2 - user must be logged
/// R3 - the channel exists
/// R4 - user has rights to create messages
/// R5-R11 are enforced by root.services.messages.Create (content,
///      reply_to_id, embeds, attachments, mentions, allowed_mentions); see that
///      file for the requirement list.
const PostTask = struct {
    const Task = root.http.Task;

    pub const Payload = struct {
        id: root.types.MessageId,
        channel_id: root.types.ChannelId,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    channel_exists_task: ?root.repo.channels.IsExists.Lazy = null,
    check_user_channel_rights_task: ?root.repo.rights.CheckUserChannelRights.Lazy = null,
    create_message_task: ?root.services.messages.Create.Lazy = null,
    body: ?[]u8 = null,
    streamer: ?root.http.Response.Streamer = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *PostTask = @ptrCast(@alignCast(ctx));

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

        // R4
        // await this.check_user_channel_rights_task
        {
            if (this.check_user_channel_rights_task == null) {
                this.check_user_channel_rights_task = .from(.init(this.db.?, .{
                    .guild_id = this.channel_exists_task.?.result.?.guild_id,
                    .channel_id = this.payload.channel_id,
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .required = .{ .send_messages = true },
                }));
            }

            while (this.check_user_channel_rights_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.check_user_channel_rights_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
            }
        }

        // R5-R11
        // await this.create_message_task
        {
            if (this.create_message_task == null) {
                this.create_message_task = root.services.messages.Create.lazy(
                    this.response,
                    this.request,
                    this.db.?,
                    .{
                        .id = this.payload.id,
                        .channel_id = this.payload.channel_id,
                        .guild_id = this.channel_exists_task.?.result.?.guild_id,
                        .author_id = this.bearer_middleware_task.?.result.?,
                        .webhook_id = null,
                    },
                );
            }

            while (this.create_message_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.create_message_task.?.result) {
                return .ready;
            }
        }

        if (this.body == null) {
            // R5-R11
            const message = this.create_message_task.?.ctx.message orelse {
                SCOPE.err("POST create task returned no message", .{});

                return .{ .err = error.Unexpected };
            };

            const response = root.route.types.Message.fromRepo(this.response.allocator, message) catch |err| {
                SCOPE.err("POST failed to build the response message: {t}", .{err});

                return .{ .err = err };
            };

            var writer: std.Io.Writer.Allocating = .init(this.response.allocator);

            std.json.fmt(response, .{}).format(&writer.writer) catch |err| {
                SCOPE.err("POST failed to serialize the response: {t}", .{err});

                return .{ .err = err };
            };

            this.body = writer.written();
        }

        if (this.streamer == null) {
            var writer = this.response.getWriter();

            if (!writer.writeCode(.created)) {
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
        const this: *PostTask = @ptrCast(@alignCast(ctx));

        if (this.bearer_middleware_task) |*t| {
            t.dispose();
            this.bearer_middleware_task = null;
        }

        if (this.channel_exists_task) |*t| {
            t.dispose();
            this.channel_exists_task = null;
        }

        if (this.check_user_channel_rights_task) |*t| {
            t.dispose();
            this.check_user_channel_rights_task = null;
        }

        if (this.create_message_task) |*t| {
            t.dispose();
            this.create_message_task = null;
        }

        if (this.db) |db| {
            db.release();
            this.db = null;
        }
    }

    pub inline fn task(
        request: *const root.http.Request,
        response: *root.http.Response,
        paylaod: Payload,
    ) !Task {
        const this = try response.allocator.create(PostTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .request = request,
            .response = response,
            .payload = paylaod,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// POST /api/channels/{channel_id}/messages
/// R1 - content type must be application/json (415) and body non-empty (400)
pub inline fn postHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    channel_id: root.types.ChannelId,
) !root.http.Task {
    _ = allocator;

    // R1
    if (try root.services.messages.ensureJsonBody(request, response)) |task| {
        return task;
    }

    const payload: PostTask.Payload = .{
        .id = root.sf_generator.generate(),
        .channel_id = channel_id,
    };

    return try PostTask.task(request, response, payload);
}
