// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../root.zig");

pub const avatar = @import("id/avatar.zig");
pub const github = @import("id/github.zig");
pub const messages = @import("id/messages.zig");
pub const token = @import("id/token.zig");

const SCOPE = std.log.scoped(.@"/api/webhooks/{webhook_id}");

/// GET /api/webhooks/{webhook_id}
/// R1 - user must be logged
/// R2 - the webhook exists (soft-deleted rows are still returned so messages
///      posted by a deleted webhook keep rendering name/avatar)
const GetTask = struct {
    const Task = root.http.Task;

    pub const Payload = struct {
        webhook_id: root.types.WebhookId,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    get_task: ?root.repo.webhooks.Get.Lazy = null,
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
        // await this.get_task
        {
            if (this.get_task == null) {
                this.get_task = .from(.init(this.response.allocator, this.db.?, .{
                    .id = this.payload.webhook_id,
                }));
            }

            while (this.get_task.?.await()) |res| {
                return res.discard();
            }

            if (this.get_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Webhook not found");
            }
        }

        if (this.body == null) {
            const webhook = root.route.types.Webhook.fromRepo(this.response.allocator, this.get_task.?.result.?) catch |err| {
                SCOPE.err("GET failed to build the response: {t}", .{err});

                return .{ .err = err };
            };

            var writer: std.Io.Writer.Allocating = .init(this.response.allocator);

            std.json.fmt(webhook, .{}).format(&writer.writer) catch |err| {
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

/// PATCH /api/webhooks/{webhook_id}
/// R1 - user must be logged
/// R2 - the webhook exists and is not soft-deleted
/// R3 - user has `modify_webhooks` on the webhook's channel
/// R4 - content type must be application/json (415) and body non-empty (400)
/// R5 - optional "name" must be a string; NFKC-normalized, within
///      api.webhooks.max_name_codepoints and passing the `.name` profile
/// R6 - the change is applied and the request succeeds with 204 No Content
///      (an absent "name" is a no-op that also succeeds)
const PatchTask = struct {
    const Task = root.http.Task;

    pub const Payload = struct {
        webhook_id: root.types.WebhookId,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    get_task: ?root.repo.webhooks.Get.Lazy = null,
    check_user_channel_rights_task: ?root.repo.rights.CheckUserChannelRights.Lazy = null,
    parsed: bool = false,
    name: ?[]const u8 = null,
    update_task: ?root.repo.webhooks.Update.Lazy = null,
    event_raised: bool = false,
    audit_log: ?root.repo.audit_log.Insert.Lazy = null,
    audit_entries: [1]root.repo.audit_log.Insert.Entry = undefined,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *PatchTask = @ptrCast(@alignCast(ctx));

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
        // await this.get_task
        {
            if (this.get_task == null) {
                this.get_task = .from(.init(this.response.allocator, this.db.?, .{
                    .id = this.payload.webhook_id,
                }));
            }

            while (this.get_task.?.await()) |res| {
                return res.discard();
            }

            if (this.get_task.?.result == null or this.get_task.?.result.?.deleted_at != null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Webhook not found");
            }
        }

        // R3
        // await this.check_user_channel_rights_task
        {
            if (this.check_user_channel_rights_task == null) {
                this.check_user_channel_rights_task = .from(.init(this.db.?, .{
                    .guild_id = this.get_task.?.result.?.guild_id,
                    .channel_id = this.get_task.?.result.?.channel_id,
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .required = .{ .modify_webhooks = true },
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
        if (!this.parsed) {
            this.parsed = true;

            // R4
            if (this.request.getContentLength() == 0) {
                return root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad Request");
            }

            // R4
            if (!root.utils.startsWithMaybe(u8, this.request.content_type, "application/json")) {
                return root.route.generic.responseErrorMessage(this.response, .unsupported_media_type, "Unsupported Media Type");
            }

            if (!this.request.contentIsAvailable()) {
                return .{ .pending = .want_read };
            }

            const root_value = std.json.parseFromSliceLeaky(std.json.Value, this.response.allocator, this.request.getContent(), .{}) catch {
                return root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad JSON");
            };

            if (root_value != .object) {
                return root.route.generic.responseErrorMessage(this.response, .bad_request, "Expected an object");
            }

            if (root_value.object.get("name")) |name_value| {
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
        }

        // R6
        if (this.name != null) {
            // await this.update_task
            {
                if (this.update_task == null) {
                    this.update_task = .from(.init(this.db.?, .{
                        .id = this.payload.webhook_id,
                        .name = this.name,
                    }));
                }

                while (this.update_task.?.await()) |res| {
                    return res.discard();
                }

                if (!this.update_task.?.result) {
                    return root.route.generic.responseErrorMessage(this.response, .not_found, "Webhook not found");
                }
            }

            // R6
            if (!this.event_raised) {
                this.event_raised = true;

                root.bus.raise(.{
                    .webhook_updated = .{
                        .id = this.payload.webhook_id,
                        .guild_id = this.get_task.?.result.?.guild_id,
                        .channel_id = this.get_task.?.result.?.channel_id,
                    },
                });
            }

            // await this.audit_log
            {
                if (this.audit_log == null) {
                    this.audit_entries[0] = .{
                        .action = .webhook_name_update,
                        .target_id = this.payload.webhook_id,
                        .channel_id = this.get_task.?.result.?.channel_id,
                    };

                    this.audit_log = .from(root.repo.audit_log.Insert.init(this.db.?, this.response.allocator, .{
                        .guild_id = this.get_task.?.result.?.guild_id,
                        .actor_id = this.bearer_middleware_task.?.result.?,
                        .entries = this.audit_entries[0..1],
                    }));
                }

                while (this.audit_log.?.await()) |res| {
                    return res.discard();
                }
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

        if (this.get_task) |*t| {
            t.dispose();
            this.get_task = null;
        }

        if (this.check_user_channel_rights_task) |*t| {
            t.dispose();
            this.check_user_channel_rights_task = null;
        }

        if (this.update_task) |*t| {
            t.dispose();
            this.update_task = null;
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

/// DELETE /api/webhooks/{webhook_id}
/// R1 - user must be logged
/// R2 - the webhook exists and is not soft-deleted
/// R3 - user has `delete_webhooks` on the webhook's channel
/// R4 - the webhook is soft-deleted and the request succeeds with 204 No Content
const DeleteTask = struct {
    const Task = root.http.Task;

    pub const Payload = struct {
        webhook_id: root.types.WebhookId,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    get_task: ?root.repo.webhooks.Get.Lazy = null,
    check_user_channel_rights_task: ?root.repo.rights.CheckUserChannelRights.Lazy = null,
    delete_task: ?root.repo.webhooks.SoftDelete.Lazy = null,
    event_raised: bool = false,
    audit_log: ?root.repo.audit_log.Insert.Lazy = null,
    audit_entries: [1]root.repo.audit_log.Insert.Entry = undefined,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *DeleteTask = @ptrCast(@alignCast(ctx));

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
        // await this.get_task
        {
            if (this.get_task == null) {
                this.get_task = .from(.init(this.response.allocator, this.db.?, .{
                    .id = this.payload.webhook_id,
                }));
            }

            while (this.get_task.?.await()) |res| {
                return res.discard();
            }

            if (this.get_task.?.result == null or this.get_task.?.result.?.deleted_at != null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Webhook not found");
            }
        }

        // R3
        // await this.check_user_channel_rights_task
        {
            if (this.check_user_channel_rights_task == null) {
                this.check_user_channel_rights_task = .from(.init(this.db.?, .{
                    .guild_id = this.get_task.?.result.?.guild_id,
                    .channel_id = this.get_task.?.result.?.channel_id,
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .required = .{ .delete_webhooks = true },
                }));
            }

            while (this.check_user_channel_rights_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.check_user_channel_rights_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
            }
        }

        // R4
        // await this.delete_task
        {
            if (this.delete_task == null) {
                this.delete_task = .from(.init(this.db.?, .{
                    .id = this.payload.webhook_id,
                }));
            }

            while (this.delete_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.delete_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Webhook not found");
            }
        }

        // R4
        if (!this.event_raised) {
            this.event_raised = true;

            root.bus.raise(.{
                .webhook_deleted = .{
                    .id = this.payload.webhook_id,
                    .guild_id = this.get_task.?.result.?.guild_id,
                    .channel_id = this.get_task.?.result.?.channel_id,
                },
            });
        }

        // await this.audit_log
        {
            if (this.audit_log == null) {
                this.audit_entries[0] = .{
                    .action = .webhook_delete,
                    .target_id = this.payload.webhook_id,
                    .channel_id = this.get_task.?.result.?.channel_id,
                };

                this.audit_log = .from(root.repo.audit_log.Insert.init(this.db.?, this.response.allocator, .{
                    .guild_id = this.get_task.?.result.?.guild_id,
                    .actor_id = this.bearer_middleware_task.?.result.?,
                    .entries = this.audit_entries[0..1],
                }));
            }

            while (this.audit_log.?.await()) |res| {
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
        const this: *DeleteTask = @ptrCast(@alignCast(ctx));

        if (this.bearer_middleware_task) |*t| {
            t.dispose();
            this.bearer_middleware_task = null;
        }

        if (this.get_task) |*t| {
            t.dispose();
            this.get_task = null;
        }

        if (this.check_user_channel_rights_task) |*t| {
            t.dispose();
            this.check_user_channel_rights_task = null;
        }

        if (this.delete_task) |*t| {
            t.dispose();
            this.delete_task = null;
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

/// GET /api/webhooks/{webhook_id}
/// R1 - user must be logged (see the R-list above GetTask)
pub inline fn getHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    webhook_id: root.types.WebhookId,
) !root.http.Task {
    _ = allocator;

    return try GetTask.task(request, response, .{
        .webhook_id = webhook_id,
    });
}

/// PATCH /api/webhooks/{webhook_id}
/// R1 - the JSON body is checked in PatchTask after auth/existence/rights
pub inline fn patchHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    webhook_id: root.types.WebhookId,
) !root.http.Task {
    _ = allocator;

    return try PatchTask.task(request, response, .{
        .webhook_id = webhook_id,
    });
}

/// DELETE /api/webhooks/{webhook_id}
/// R1 - user must be logged (see the R-list above DeleteTask)
pub inline fn deleteHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    webhook_id: root.types.WebhookId,
) !root.http.Task {
    _ = allocator;

    return try DeleteTask.task(request, response, .{
        .webhook_id = webhook_id,
    });
}
