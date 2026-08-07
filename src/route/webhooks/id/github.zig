// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../../root.zig");

const SCOPE = std.log.scoped(.@"/api/webhooks/{webhook_id}/{token}/github");

/// POST /api/webhooks/{webhook_id}/{token}/github
/// R1 - the webhook exists, is not soft-deleted and `token` hashes to its
///      stored `token_hash`; otherwise 404 (no session is involved)
/// R2 - the `X-GitHub-Event` header must be present; otherwise 400
/// R3 - the body must be non-empty and `application/json` or
///      `application/x-www-form-urlencoded` (415 otherwise), and no larger than
///      `api.github.max_body_bytes` (413 otherwise)
/// R4 - the JSON payload is taken from the body directly (JSON) or from the
///      `payload` form field; it must parse to an object or 400 is returned
/// R5 - the event is rendered to one embed through `services.github.transform`
///      and posted via the shared `services.messages.Create`; an event that is
///      not rendered posts nothing
/// R6 - success is `204 No Content`
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
    body_task: ?root.route.generic.Body.Lazy = null,
    is_form: bool = false,
    parsed: bool = false,
    embed: ?root.types.Embed = null,
    embeds: ?[]const u8 = null,
    create_message_task: ?root.services.messages.Create.Lazy = null,

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
        const event = this.request.findHeader("X-GitHub-Event") orelse {
            return root.route.generic.responseErrorMessage(this.response, .bad_request, "Missing event");
        };

        if (event.len == 0) {
            return root.route.generic.responseErrorMessage(this.response, .bad_request, "Missing event");
        }

        // R3, R4
        // await this.body_task
        if (this.body_task == null) {
            // These checks must run before the body is consumed: `Body` drains
            // the request, so `getContentLength()` becomes 0 afterwards.
            if (this.request.getContentLength() == 0) {
                return root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad Request");
            }

            const content_type = this.request.content_type orelse "";
            const is_json = root.utils.startsWithMaybe(u8, content_type, "application/json");

            this.is_form = root.utils.startsWithMaybe(u8, content_type, "application/x-www-form-urlencoded");

            if (!is_json and !this.is_form) {
                return root.route.generic.responseErrorMessage(this.response, .unsupported_media_type, "Unsupported Media Type");
            }

            this.body_task = .from(.init(
                this.request,
                this.response,
                root.options.api.github.max_body_bytes,
            ));
        }

        {
            while (this.body_task.?.await()) |res| {
                switch (res) {
                    .pending => |pending| return .{ .pending = pending },
                    .err => |err| {
                        if (err == error.BodyTooLarge) {
                            return root.route.generic.responseErrorMessage(this.response, .content_too_large, "Request body is too large");
                        }

                        SCOPE.err("POST failed to buffer the body: {t}", .{err});

                        return .{ .err = err };
                    },
                    .ready => unreachable,
                }
            }
        }

        // R4, R5
        if (!this.parsed) {
            const json_text = if (!this.is_form)
                this.body_task.?.result
            else
                extractFormPayload(this.response.allocator, this.body_task.?.result) catch |err| {
                    SCOPE.err("POST failed to read the form payload: {t}", .{err});

                    return .{ .err = err };
                } orelse {
                    return root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad JSON");
                };

            const root_value = std.json.parseFromSliceLeaky(std.json.Value, this.response.allocator, json_text, .{}) catch {
                return root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad JSON");
            };

            if (root_value != .object) {
                return root.route.generic.responseErrorMessage(this.response, .bad_request, "Expected an object");
            }

            this.embed = root.services.github.transform(this.response.allocator, event, root_value) catch |err| {
                SCOPE.err("POST failed to render the event: {t}", .{err});

                return .{ .err = err };
            };

            if (this.embed != null) {
                this.embeds = root.utils.serializeEmbeds(this.response.allocator, &.{this.embed.?}) catch |err| {
                    SCOPE.err("POST failed to serialize the embed: {t}", .{err});

                    return .{ .err = err };
                };
            }

            this.parsed = true;
        }

        const webhook = this.get_by_token_task.?.result.?;

        // R5
        if (this.embeds == null) {
            return writeNoContent(this.response);
        }

        // R5
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
                        .preset = .{
                            .content = "",
                            .reply_to_id = null,
                            .embeds = this.embeds,
                            .attachments = &.{},
                        },
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

        // R6
        return writeNoContent(this.response);
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *ExecuteTask = @ptrCast(@alignCast(ctx));

        if (this.get_by_token_task) |*t| {
            t.dispose();
            this.get_by_token_task = null;
        }

        if (this.body_task) |*t| {
            t.dispose();
            this.body_task = null;
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

fn writeNoContent(response: *root.http.Response) root.http.Task.PollT {
    var writer = response.getWriter();

    if (!writer.writeCode(.no_content)) {
        return .{ .pending = .want_write };
    }

    if (!writer.emptyBody()) {
        return .{ .pending = .want_write };
    }

    writer.commit();

    return .ready;
}

/// Extracts the `payload` field of an `application/x-www-form-urlencoded` body
/// (GitHub's `application/x-www-form-urlencoded` delivery format) and
/// percent-decodes it. `null` when the field is missing or empty.
inline fn extractFormPayload(allocator: std.mem.Allocator, body: []const u8) !?[]const u8 {
    var iterator = std.mem.splitScalar(u8, body, '&');

    while (iterator.next()) |pair| {
        const separator = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = pair[0..separator];

        if (!std.mem.eql(u8, key, "payload")) {
            continue;
        }

        const value = pair[separator + 1 ..];

        if (value.len == 0) {
            return null;
        }

        const buffer = try allocator.dupe(u8, value);

        for (buffer) |*character| {
            if (character.* == '+') {
                character.* = ' ';
            }
        }

        return std.Uri.percentDecodeInPlace(buffer);
    }

    return null;
}

/// POST /api/webhooks/{webhook_id}/{token}/github
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
