// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../root.zig");

const SCOPE = std.log.scoped(.@"/api/channels/{channel_id}/webhooks");

/// GET /api/channels/{channel_id}/webhooks
/// R1 - user must be logged
/// R2 - the channel exists
/// R3 - the response is the channel's live webhooks, ordered by id (the execute
///      token is never included)
const GetTask = struct {
    const Task = root.http.Task;

    pub const Payload = struct {
        channel_id: root.types.ChannelId,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    channel_exists_task: ?root.repo.channels.IsExists.Lazy = null,
    list_task: ?root.repo.webhooks.ListForChannel.Lazy = null,
    items: std.ArrayList(root.route.types.Webhook) = .empty,
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

        // R3
        // await this.list_task
        {
            if (this.list_task == null) {
                this.list_task = .from(.init(this.response.allocator, this.db.?, .{
                    .channel_id = this.payload.channel_id,
                }));
            }

            while (this.list_task.?.await()) |res| {
                return res.discard();
            }

            for (this.list_task.?.result) |item| {
                const webhook = root.route.types.Webhook.fromRepo(this.response.allocator, item) catch |err| {
                    SCOPE.err("GET failed to build a webhook object: {t}", .{err});

                    return .{ .err = err };
                };

                this.items.append(this.response.allocator, webhook) catch |err| {
                    SCOPE.err("GET failed to append a webhook: {t}", .{err});

                    return .{ .err = err };
                };
            }
        }

        if (this.body == null) {
            var writer: std.Io.Writer.Allocating = .init(this.response.allocator);

            std.json.fmt(this.items.items, .{}).format(&writer.writer) catch |err| {
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

        if (this.list_task) |*t| {
            t.dispose();
            this.list_task = null;
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

/// POST /api/channels/{channel_id}/webhooks
/// R1 - user must be logged
/// R2 - the channel exists
/// R3 - user has `create_webhooks` on the channel
/// R4 - content type must be application/json (415) and body non-empty (400)
/// R5 - "name" must be present, a string; NFKC-normalized, within
///      api.webhooks.max_name_codepoints and passing the `.name` profile
/// R6 - the channel must hold fewer than api.webhooks.max_webhooks_per_channel
///      live webhooks, otherwise 400 "'webhooks' is too many"
/// R7 - the webhook is created and `201 {"id","token"}` is returned; the
///      plaintext token is shown exactly once and never stored
const PostTask = struct {
    const Task = root.http.Task;

    pub const Payload = struct {
        id: root.types.WebhookId,
        channel_id: root.types.ChannelId,
    };

    pub const Response = struct {
        id: []const u8,
        token: []const u8,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    channel_exists_task: ?root.repo.channels.IsExists.Lazy = null,
    check_user_channel_rights_task: ?root.repo.rights.CheckUserChannelRights.Lazy = null,
    name: ?[]const u8 = null,
    token: ?[]u8 = null,
    create_task: ?root.repo.webhooks.Create.Lazy = null,
    event_raised: bool = false,
    body: ?[]const u8 = null,
    streamer: ?root.http.Response.Streamer = null,
    audit_log: ?root.repo.audit_log.Insert.Lazy = null,
    audit_entries: [1]root.repo.audit_log.Insert.Entry = undefined,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *PostTask = @ptrCast(@alignCast(ctx));

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

        // R3
        // await this.check_user_channel_rights_task
        {
            if (this.check_user_channel_rights_task == null) {
                this.check_user_channel_rights_task = .from(.init(this.db.?, .{
                    .guild_id = this.channel_exists_task.?.result.?.guild_id,
                    .channel_id = this.payload.channel_id,
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .required = .{ .create_webhooks = true },
                }));
            }

            while (this.check_user_channel_rights_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.check_user_channel_rights_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
            }
        }

        // R4, R5
        if (this.name == null) {
            // R4
            if (!this.request.contentIsAvailable()) {
                return .{ .pending = .want_read };
            }

            // R4
            if (this.request.getContentLength() == 0) {
                return root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad Request");
            }

            // R4
            if (!root.utils.startsWithMaybe(u8, this.request.content_type, "application/json")) {
                return root.route.generic.responseErrorMessage(this.response, .unsupported_media_type, "Unsupported Media Type");
            }

            const root_value = std.json.parseFromSliceLeaky(std.json.Value, this.response.allocator, this.request.getContent(), .{}) catch {
                return root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad JSON");
            };

            if (root_value != .object) {
                return root.route.generic.responseErrorMessage(this.response, .bad_request, "Expected an object");
            }

            // R5
            const name_value = root_value.object.get("name") orelse {
                return root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is missing");
            };

            // R5
            if (name_value != .string) {
                return root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is not a string");
            }

            const name = root.unicode.normalize(this.response.allocator, name_value.string) catch |err| switch (err) {
                error.InvalidUtf8 => return root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is invalid"),
                error.OutOfMemory => return .{ .err = error.OutOfMemory },
            };

            // R5
            if (std.unicode.utf8CountCodepoints(name) catch unreachable >
                root.options.api.webhooks.max_name_codepoints)
            {
                return root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is too long");
            }

            // R5
            if ((root.unicode.findForbiddenCodepoint(.name, name) catch null) != null) {
                return root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is invalid");
            }

            this.name = name;
        }

        // R7
        if (this.token == null) {
            this.token = root.services.tokens.generateWebhookToken(this.response.allocator) catch |err| {
                SCOPE.err("POST failed to generate a token: {t}", .{err});

                return .{ .err = err };
            };
        }

        // R6
        // await this.create_task
        {
            if (this.create_task == null) {
                this.create_task = .from(.init(this.db.?, .{
                    .id = this.payload.id,
                    .channel_id = this.payload.channel_id,
                    .name = this.name.?,
                    .token_hash = root.services.tokens.webhookTokenHash(this.token.?),
                    .limit = root.options.api.webhooks.max_webhooks_per_channel,
                }));
            }

            while (this.create_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.create_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .bad_request, "'webhooks' is too many");
            }
        }

        // R7
        if (!this.event_raised) {
            this.event_raised = true;

            root.bus.raise(.{
                .webhook_created = .{
                    .id = this.payload.id,
                    .guild_id = this.channel_exists_task.?.result.?.guild_id,
                    .channel_id = this.payload.channel_id,
                },
            });
        }

        // await this.audit_log
        {
            if (this.audit_log == null) {
                this.audit_entries[0] = .{
                    .action = .webhook_create,
                    .target_id = this.payload.id,
                    .channel_id = this.payload.channel_id,
                };

                this.audit_log = .from(root.repo.audit_log.Insert.init(this.db.?, this.response.allocator, .{
                    .guild_id = this.channel_exists_task.?.result.?.guild_id,
                    .actor_id = this.bearer_middleware_task.?.result.?,
                    .entries = this.audit_entries[0..1],
                }));
            }

            while (this.audit_log.?.await()) |res| {
                return res.discard();
            }
        }

        if (this.body == null) {
            const response: Response = .{
                .id = std.fmt.allocPrint(this.response.allocator, "{}", .{this.payload.id}) catch |err| {
                    SCOPE.err("POST failed to stringify 'id': {t}", .{err});

                    return .{ .err = err };
                },
                .token = this.token.?,
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

        if (this.create_task) |*t| {
            t.dispose();
            this.create_task = null;
        }

        if (this.audit_log) |*a| {
            a.dispose();
            this.audit_log = null;
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
        const this = try response.allocator.create(PostTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .request = request,
            .response = response,
            .payload = payload,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// GET /api/channels/{channel_id}/webhooks
/// R1 - user must be logged (see the R-list above GetTask)
pub inline fn getHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    channel_id: root.types.ChannelId,
) !root.http.Task {
    _ = allocator;

    return try GetTask.task(request, response, .{
        .channel_id = channel_id,
    });
}

/// POST /api/channels/{channel_id}/webhooks
/// R1 - the request body is checked in PostTask (auth first, then JSON body)
pub inline fn postHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    channel_id: root.types.ChannelId,
) !root.http.Task {
    _ = allocator;

    return try PostTask.task(request, response, .{
        .id = root.sf_generator.generate(),
        .channel_id = channel_id,
    });
}
