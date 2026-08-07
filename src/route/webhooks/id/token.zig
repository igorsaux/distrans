// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../../root.zig");

const SCOPE = std.log.scoped(.@"/api/webhooks/{webhook_id}/{token}");

/// POST /api/webhooks/{webhook_id}/{token}
/// R1 - the webhook exists, is not soft-deleted and `token` hashes to its
///      stored `token_hash`; otherwise 404 (no session is involved)
/// R2 - content type must be application/json (415) and body non-empty (400)
/// R3 - the message payload is validated exactly like
///      `POST /api/channels/{channel_id}/messages` R5-R11 (content,
///      reply_to_id, embeds, attachments, mentions, allowed_mentions); the
///      shared `messages.Create` task enforces them
/// R4 - the message is stored as the webhook (author_id NULL, webhook_id set)
///      and `201 {"id"}` is returned; the gateway event and notifications are
///      emitted exactly like a user message
const ExecuteTask = struct {
    const Task = root.http.Task;

    pub const Payload = struct {
        id: root.types.MessageId,
        webhook_id: root.types.WebhookId,
        token: []const u8,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    db: ?*root.db.Connection = null,
    get_by_token_task: ?root.repo.webhooks.GetByToken.Lazy = null,
    create_message_task: ?root.services.messages.Create.Lazy = null,
    body: ?[]const u8 = null,
    streamer: ?root.http.Response.Streamer = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *ExecuteTask = @ptrCast(@alignCast(ctx));

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
        if (this.request.getContentLength() == 0) {
            return root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad Request");
        }

        // R2
        if (!root.utils.startsWithMaybe(u8, this.request.content_type, "application/json")) {
            return root.route.generic.responseErrorMessage(this.response, .unsupported_media_type, "Unsupported Media Type");
        }

        const webhook = this.get_by_token_task.?.result.?;

        // R3, R4
        // await this.create_message_task
        {
            if (this.create_message_task == null) {
                this.create_message_task = root.services.messages.Create.lazy(
                    this.response,
                    this.request,
                    this.db.?,
                    .{
                        .id = this.payload.id,
                        .channel_id = webhook.channel_id,
                        .guild_id = webhook.guild_id,
                        .author_id = null,
                        .webhook_id = this.payload.webhook_id,
                    },
                );
            }

            while (this.create_message_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.create_message_task.?.result) {
                // response already written by the create task
                return .ready;
            }
        }

        if (this.body == null) {
            // R3, R4
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
        const this: *ExecuteTask = @ptrCast(@alignCast(ctx));

        if (this.get_by_token_task) |*t| {
            t.dispose();
            this.get_by_token_task = null;
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
        webhook_id: root.types.WebhookId,
        token: []const u8,
    ) !Task {
        const this = try response.allocator.create(ExecuteTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .request = request,
            .response = response,
            .payload = .{
                .id = root.sf_generator.generate(),
                .webhook_id = webhook_id,
                .token = token,
            },
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// POST /api/webhooks/{webhook_id}/{token}
/// R1 - no session; the token is the capability (see the R-list above
///      ExecuteTask)
pub inline fn executeHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    webhook_id: root.types.WebhookId,
    token: []const u8,
) !root.http.Task {
    _ = allocator;

    return try ExecuteTask.task(request, response, webhook_id, token);
}
