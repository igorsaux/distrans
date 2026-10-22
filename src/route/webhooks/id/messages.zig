// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../../root.zig");

const SCOPE = std.log.scoped(.@"/api/webhooks/{webhook_id}/{token}/messages/{message_id}");

const Payload = struct {
    webhook_id: root.types.WebhookId,
    token: []const u8,
    message_id: root.types.MessageId,
};

/// GET /api/webhooks/{webhook_id}/{token}/messages/{message_id}
/// R1 - the webhook exists, is live and `token` hashes to its `token_hash`;
///      otherwise 404 (no session is involved)
/// R2 - the message exists, is live, belongs to the webhook's channel and was
///      posted by this webhook; otherwise 404
/// R3 - the canonical message object is returned
const GetTask = struct {
    const Task = root.http.Task;

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    db: ?*root.db.Connection = null,
    get_by_token_task: ?root.repo.webhooks.GetByToken.Lazy = null,
    message_is_exists_task: ?root.repo.messages.IsExists.Lazy = null,
    get_message_task: ?root.repo.messages.GetOne.Lazy = null,
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
        // await this.get_by_token_task
        {
            if (this.get_by_token_task == null) {
                this.get_by_token_task = .from(.init(this.response.allocator, this.db.?, .{
                    .id = this.payload.webhook_id,
                    .token_hash = root.services.tokens.webhookTokenHash(this.payload.token),
                }));
            }

            while (this.get_by_token_task.?.await()) |res| {
                return res.discard();
            }

            if (this.get_by_token_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Webhook not found");
            }
        }

        // R2
        // await this.message_is_exists_task
        {
            if (this.message_is_exists_task == null) {
                this.message_is_exists_task = .from(.init(this.db.?, .{
                    .id = this.payload.message_id,
                }));
            }

            while (this.message_is_exists_task.?.await()) |res| {
                return res.discard();
            }

            if (!messageBelongsToWebhook(
                this.message_is_exists_task.?.result,
                this.get_by_token_task.?.result.?,
                this.payload.webhook_id,
            )) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Message not found");
            }
        }

        // R3
        // await this.get_message_task
        {
            if (this.get_message_task == null) {
                this.get_message_task = .from(.init(
                    this.response.allocator,
                    this.db.?,
                    .{
                        .id = this.payload.message_id,
                        .me_user_id = 0,
                    },
                ));
            }

            while (this.get_message_task.?.await()) |res| {
                return res.discard();
            }

            if (this.get_message_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Message not found");
            }
        }

        if (this.body == null) {
            const message = root.route.types.Message.fromRepo(
                this.response.allocator,
                this.get_message_task.?.result.?,
            ) catch |err| {
                SCOPE.err("GET failed to build the response message: {t}", .{err});

                return .{ .err = err };
            };

            var writer: std.Io.Writer.Allocating = .init(this.response.allocator);

            std.json.fmt(message, .{}).format(&writer.writer) catch |err| {
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

        if (this.get_by_token_task) |*t| {
            t.dispose();
            this.get_by_token_task = null;
        }

        if (this.message_is_exists_task) |*t| {
            t.dispose();
            this.message_is_exists_task = null;
        }

        if (this.get_message_task) |*t| {
            t.dispose();
            this.get_message_task = null;
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

/// PATCH /api/webhooks/{webhook_id}/{token}/messages/{message_id}
/// R1 - the webhook exists, is live and `token` hashes to its `token_hash`;
///      otherwise 404
/// R2 - the message exists, is live, belongs to the webhook's channel and was
///      posted by this webhook; otherwise 404
/// R3 - content type must be application/json (415) and body non-empty (400)
/// R4 - the edit body is validated and applied exactly like
///      `PATCH /api/messages/{message_id}` (content and/or embeds); the shared
///      `services.messages.Edit` task enforces the rules and emits
///      `message_updated`
const PatchTask = struct {
    const Task = root.http.Task;

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    db: ?*root.db.Connection = null,
    get_by_token_task: ?root.repo.webhooks.GetByToken.Lazy = null,
    message_is_exists_task: ?root.repo.messages.IsExists.Lazy = null,
    edit_task: ?root.services.messages.Edit.Lazy = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *PatchTask = @ptrCast(@alignCast(ctx));

        if (this.db == null) {
            this.db = root.db_pool.rent() orelse {
                return .{ .pending = .db };
            };
        }

        // R1
        // await this.get_by_token_task
        {
            if (this.get_by_token_task == null) {
                this.get_by_token_task = .from(.init(this.response.allocator, this.db.?, .{
                    .id = this.payload.webhook_id,
                    .token_hash = root.services.tokens.webhookTokenHash(this.payload.token),
                }));
            }

            while (this.get_by_token_task.?.await()) |res| {
                return res.discard();
            }

            if (this.get_by_token_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Webhook not found");
            }
        }

        // R2
        // await this.message_is_exists_task
        {
            if (this.message_is_exists_task == null) {
                this.message_is_exists_task = .from(.init(this.db.?, .{
                    .id = this.payload.message_id,
                }));
            }

            while (this.message_is_exists_task.?.await()) |res| {
                return res.discard();
            }

            if (!messageBelongsToWebhook(
                this.message_is_exists_task.?.result,
                this.get_by_token_task.?.result.?,
                this.payload.webhook_id,
            )) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Message not found");
            }
        }

        // R4
        // await this.edit_task
        {
            if (this.edit_task == null) {
                this.edit_task = root.services.messages.Edit.lazy(
                    this.response,
                    this.request,
                    this.db.?,
                    .{
                        .id = this.payload.message_id,
                        .guild_id = this.message_is_exists_task.?.result.?.guild_id,
                        .channel_id = this.message_is_exists_task.?.result.?.channel_id,
                        .me_user_id = 0,
                    },
                );
            }

            while (this.edit_task.?.await()) |res| {
                return res.discard();
            }
        }

        return .ready;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *PatchTask = @ptrCast(@alignCast(ctx));

        if (this.get_by_token_task) |*t| {
            t.dispose();
            this.get_by_token_task = null;
        }

        if (this.message_is_exists_task) |*t| {
            t.dispose();
            this.message_is_exists_task = null;
        }

        if (this.edit_task) |*t| {
            t.dispose();
            this.edit_task = null;
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

/// DELETE /api/webhooks/{webhook_id}/{token}/messages/{message_id}
/// R1 - the webhook exists, is live and `token` hashes to its `token_hash`;
///      otherwise 404
/// R2 - the message exists, is live, belongs to the webhook's channel and was
///      posted by this webhook; otherwise 404
/// R3 - the message is soft-deleted, `message_deleted` is emitted and 204 is
///      returned
const DeleteTask = struct {
    const Task = root.http.Task;

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    db: ?*root.db.Connection = null,
    get_by_token_task: ?root.repo.webhooks.GetByToken.Lazy = null,
    message_is_exists_task: ?root.repo.messages.IsExists.Lazy = null,
    delete_task: ?root.repo.messages.SoftDelete.Lazy = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *DeleteTask = @ptrCast(@alignCast(ctx));

        if (this.db == null) {
            this.db = root.db_pool.rent() orelse {
                return .{ .pending = .db };
            };
        }

        // R1
        // await this.get_by_token_task
        {
            if (this.get_by_token_task == null) {
                this.get_by_token_task = .from(.init(this.response.allocator, this.db.?, .{
                    .id = this.payload.webhook_id,
                    .token_hash = root.services.tokens.webhookTokenHash(this.payload.token),
                }));
            }

            while (this.get_by_token_task.?.await()) |res| {
                return res.discard();
            }

            if (this.get_by_token_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Webhook not found");
            }
        }

        // R2
        // await this.message_is_exists_task
        {
            if (this.message_is_exists_task == null) {
                this.message_is_exists_task = .from(.init(this.db.?, .{
                    .id = this.payload.message_id,
                }));
            }

            while (this.message_is_exists_task.?.await()) |res| {
                return res.discard();
            }

            if (!messageBelongsToWebhook(
                this.message_is_exists_task.?.result,
                this.get_by_token_task.?.result.?,
                this.payload.webhook_id,
            )) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Message not found");
            }
        }

        // R3
        // await this.delete_task
        {
            if (this.delete_task == null) {
                this.delete_task = .from(.init(this.db.?, .{
                    .id = this.payload.message_id,
                }));
            }

            while (!this.delete_task.?.done) {
                if (this.delete_task.?.await()) |res| {
                    return res.discard();
                }

                root.bus.raise(.{
                    .message_deleted = .{
                        .guild_id = this.message_is_exists_task.?.result.?.guild_id,
                        .channel_id = this.message_is_exists_task.?.result.?.channel_id,
                        .id = this.payload.message_id,
                    },
                });
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
        const this: *DeleteTask = @ptrCast(@alignCast(ctx));

        if (this.get_by_token_task) |*t| {
            t.dispose();
            this.get_by_token_task = null;
        }

        if (this.message_is_exists_task) |*t| {
            t.dispose();
            this.message_is_exists_task = null;
        }

        if (this.delete_task) |*t| {
            t.dispose();
            this.delete_task = null;
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
        const this = try response.allocator.create(DeleteTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .request = request,
            .response = response,
            .payload = payload,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

inline fn messageBelongsToWebhook(
    message: root.repo.messages.IsExists.Result,
    webhook: root.repo.types.Webhook,
    webhook_id: root.types.WebhookId,
) bool {
    const item = message orelse return false;

    return item.webhook_id != null and
        item.webhook_id.? == webhook_id and
        item.channel_id == webhook.channel_id;
}

/// GET /api/webhooks/{webhook_id}/{token}/messages/{message_id}
/// R1 - no session; the token is the capability (see the R-list above GetTask)
pub inline fn getHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    webhook_id: root.types.WebhookId,
    token: []const u8,
    message_id: root.types.MessageId,
) !root.http.Task {
    _ = allocator;

    return try GetTask.task(request, response, .{
        .webhook_id = webhook_id,
        .token = token,
        .message_id = message_id,
    });
}

/// PATCH /api/webhooks/{webhook_id}/{token}/messages/{message_id}
/// R3 - content type must be application/json (415) and body non-empty (400)
pub inline fn patchHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    webhook_id: root.types.WebhookId,
    token: []const u8,
    message_id: root.types.MessageId,
) !root.http.Task {
    _ = allocator;

    // R3
    if (request.getContentLength() == 0) {
        return try root.route.generic.badRequestTask(response);
    }

    // R3
    if (!root.utils.startsWithMaybe(u8, request.content_type, "application/json")) {
        return try root.route.generic.unsupportedMediaTypeTask(response);
    }

    return try PatchTask.task(request, response, .{
        .webhook_id = webhook_id,
        .token = token,
        .message_id = message_id,
    });
}

/// DELETE /api/webhooks/{webhook_id}/{token}/messages/{message_id}
/// R1 - no session; the token is the capability (see the R-list above DeleteTask)
pub inline fn deleteHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    webhook_id: root.types.WebhookId,
    token: []const u8,
    message_id: root.types.MessageId,
) !root.http.Task {
    _ = allocator;

    return try DeleteTask.task(request, response, .{
        .webhook_id = webhook_id,
        .token = token,
        .message_id = message_id,
    });
}
