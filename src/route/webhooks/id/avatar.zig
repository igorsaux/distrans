// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../../root.zig");

const SCOPE = std.log.scoped(.@"/api/webhooks/{webhook_id}/avatar");

/// GET /api/webhooks/{webhook_id}/avatar?hash={hash}
/// R1 - the "hash" query parameter must be present and match the stored hash of
///      an existing webhook's avatar, otherwise 404 "Avatar not found". Unlike
///      the management endpoints a soft-deleted webhook is still served, so its
///      messages keep rendering name/avatar.
/// R2 - only "hash" is accepted; any other query parameter is 400
const GetTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        webhook_id: root.types.WebhookId,
        hash: ?[]const u8,
    };

    response: *root.http.Response,
    payload: Payload,
    db: ?*root.db.Connection = null,
    get_avatar_task: ?root.repo.webhooks.GetAvatar.Lazy = null,
    streamer: ?root.http.Response.Streamer = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *GetTask = @ptrCast(@alignCast(ctx));

        // R1
        const hash = this.payload.hash orelse {
            return root.route.generic.responseErrorMessage(this.response, .not_found, "Avatar not found");
        };

        if (hash.len == 0) {
            return root.route.generic.responseErrorMessage(this.response, .not_found, "Avatar not found");
        }

        if (this.db == null) {
            this.db = root.db_pool.rent() orelse {
                return .{ .pending = .db };
            };
        }

        // R1
        // await this.get_avatar_task
        {
            if (this.get_avatar_task == null) {
                this.get_avatar_task = .from(.init(this.response.allocator, this.db.?, .{
                    .id = this.payload.webhook_id,
                    .hash = hash,
                }));
            }

            while (this.get_avatar_task.?.await()) |res| {
                return res.discard();
            }

            if (this.get_avatar_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Avatar not found");
            }
        }

        if (this.streamer == null) {
            var writer = this.response.getWriter();

            if (!writer.writeCode(.ok)) {
                return .{ .pending = .want_write };
            }

            if (!writer.writeHeader("Cache-Control", "{s}", .{"private, max-age=31536000, immutable"})) {
                return .{ .pending = .want_write };
            }

            if (!writer.beginBody("image/webp", this.get_avatar_task.?.result.?.len)) {
                return .{ .pending = .want_write };
            }

            writer.commit();
            this.streamer = this.response.getStreamer(this.get_avatar_task.?.result.?);
        }

        return this.streamer.?.poll();
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetTask = @ptrCast(@alignCast(ctx));

        if (this.get_avatar_task) |*t| {
            t.dispose();
            this.get_avatar_task = null;
        }

        if (this.db) |db| {
            db.release();
            this.db = null;
        }
    }

    pub inline fn task(
        response: *root.http.Response,
        payload: Payload,
    ) !Task {
        const this = try response.allocator.create(GetTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .response = response,
            .payload = payload,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// PUT /api/webhooks/{webhook_id}/avatar
/// R1 - user must be logged
/// R2 - the webhook exists and is not soft-deleted
/// R3 - user has `modify_webhooks` on the webhook's channel
/// R4 - the body must be non-empty with a supported raster Content-Type
///      (image/webp, image/gif, image/png); an empty body is 400 "Bad image",
///      an unsupported type is 415
/// R5 - the body must not exceed media.avatar.max_input_bytes (413 "Image is
///      too large") and must be a valid WebP/GIF/PNG within the media.avatar
///      dimension and animation caps (400 "Bad image")
/// R6 - the image is re-encoded to WebP, stored and returned as
///      200 {"avatar_hash": "<hash>"}
const PutTask = struct {
    pub const Task = root.http.Task;

    pub const Response = struct {
        avatar_hash: []const u8,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: struct {
        webhook_id: root.types.WebhookId,
    },
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    get_task: ?root.repo.webhooks.Get.Lazy = null,
    check_user_channel_rights_task: ?root.repo.rights.CheckUserChannelRights.Lazy = null,
    body_task: ?root.route.generic.Body.Lazy = null,
    encode_task: ?root.services.media.Encode.Lazy = null,
    set_avatar_task: ?root.repo.webhooks.SetAvatar.Lazy = null,
    event_raised: bool = false,
    body: ?[]const u8 = null,
    streamer: ?root.http.Response.Streamer = null,
    audit_log: ?root.repo.audit_log.Insert.Lazy = null,
    audit_entries: [1]root.repo.audit_log.Insert.Entry = undefined,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *PutTask = @ptrCast(@alignCast(ctx));

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

        // R4
        if (this.body_task == null) {
            if (this.request.getContentLength() == 0) {
                return root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad image");
            }

            if (!root.services.media.isSupportedMime(this.request.content_type)) {
                return root.route.generic.responseErrorMessage(this.response, .unsupported_media_type, "Unsupported Media Type");
            }

            this.body_task = .from(.init(
                this.request,
                this.response,
                root.options.media.avatar.max_input_bytes,
            ));
        }

        // R5
        // await this.body_task
        {
            while (this.body_task.?.await()) |res| {
                switch (res) {
                    .pending => |p| return .{ .pending = p },
                    .err => |err| {
                        if (err == error.BodyTooLarge) {
                            return root.route.generic.responseErrorMessage(this.response, .content_too_large, "Image is too large");
                        }

                        SCOPE.err("PUT failed to buffer the body: {t}", .{err});

                        return .{ .err = err };
                    },
                    .ready => unreachable,
                }
            }
        }

        // R5, R6
        // await this.encode_task
        {
            if (this.encode_task == null) {
                this.encode_task = .from(.init(.{
                    .data = this.body_task.?.result,
                    .mime_type = this.request.content_type orelse "",
                    .limits = .{
                        .max_input_bytes = root.options.media.avatar.max_input_bytes,
                        .max_output_bytes = root.options.media.avatar.max_output_bytes,
                        .max_dimensions = root.options.media.avatar.max_dimensions,
                        .max_animation_frames = root.options.media.avatar.max_animation_frames,
                        .min_animation_frame_delay_ms = root.options.media.avatar.min_animation_frame_delay_ms,
                        .max_animation_frame_delay_ms = root.options.media.avatar.max_animation_frame_delay_ms,
                        .max_animation_duration_ms = root.options.media.avatar.max_animation_duration_ms,
                    },
                    .options = .{
                        .lossless = root.options.media.avatar.lossless,
                        .quality = root.options.media.avatar.quality,
                        .compression_level = root.options.media.avatar.compression_level,
                    },
                }));
            }

            while (this.encode_task.?.await()) |res| {
                switch (res) {
                    .pending => |p| return .{ .pending = p },
                    .err => |err| {
                        if (err == root.services.media.Error.BadImage) {
                            return root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad image");
                        }

                        SCOPE.err("PUT failed to encode the avatar: {t}", .{err});

                        return .{ .err = err };
                    },
                    .ready => unreachable,
                }
            }
        }

        // R6
        // await this.set_avatar_task
        {
            if (this.set_avatar_task == null) {
                this.set_avatar_task = .from(.init(this.db.?, .{
                    .id = this.payload.webhook_id,
                    .data = this.encode_task.?.result.data,
                    .hash = this.encode_task.?.result.hash[0..],
                }));
            }

            while (this.set_avatar_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.set_avatar_task.?.result) {
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
                    .action = .webhook_avatar_update,
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

        if (this.body == null) {
            var writer: std.Io.Writer.Allocating = .init(this.response.allocator);

            const response: Response = .{
                .avatar_hash = this.encode_task.?.result.hash[0..],
            };

            std.json.fmt(response, .{}).format(&writer.writer) catch |err| {
                SCOPE.err("PUT failed to serialize the response: {t}", .{err});

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
        const this: *PutTask = @ptrCast(@alignCast(ctx));

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

        if (this.body_task) |*t| {
            t.dispose();
            this.body_task = null;
        }

        if (this.encode_task) |*t| {
            t.dispose();
            this.encode_task = null;
        }

        if (this.set_avatar_task) |*t| {
            t.dispose();
            this.set_avatar_task = null;
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
        webhook_id: root.types.WebhookId,
    ) !Task {
        const this = try response.allocator.create(PutTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .request = request,
            .response = response,
            .payload = .{ .webhook_id = webhook_id },
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// DELETE /api/webhooks/{webhook_id}/avatar
/// R1 - user must be logged
/// R2 - the webhook exists and is not soft-deleted
/// R3 - user has `modify_webhooks` on the webhook's channel
/// R4 - the avatar is cleared and the request succeeds with 204 No Content
///      (clearing is idempotent)
const DeleteTask = struct {
    pub const Task = root.http.Task;

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: struct {
        webhook_id: root.types.WebhookId,
    },
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    get_task: ?root.repo.webhooks.Get.Lazy = null,
    check_user_channel_rights_task: ?root.repo.rights.CheckUserChannelRights.Lazy = null,
    clear_avatar_task: ?root.repo.webhooks.ClearAvatar.Lazy = null,
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

        // R4
        // await this.clear_avatar_task
        {
            if (this.clear_avatar_task == null) {
                this.clear_avatar_task = .from(.init(this.db.?, .{
                    .id = this.payload.webhook_id,
                }));
            }

            while (this.clear_avatar_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.clear_avatar_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Webhook not found");
            }
        }

        // R4
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
                    .action = .webhook_avatar_delete,
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

        if (this.clear_avatar_task) |*t| {
            t.dispose();
            this.clear_avatar_task = null;
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
        webhook_id: root.types.WebhookId,
    ) !Task {
        const this = try response.allocator.create(DeleteTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .request = request,
            .response = response,
            .payload = .{ .webhook_id = webhook_id },
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// GET /api/webhooks/{webhook_id}/avatar?hash={hash}
/// Public endpoint: no authentication required.
/// R1 - the "hash" query parameter must match (see the R-list above GetTask)
/// R2 - only "hash" is accepted (see the R-list above GetTask)
pub inline fn getHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    webhook_id: root.types.WebhookId,
) !GetTask.Task {
    _ = allocator;

    var hash: ?[]const u8 = null;

    for (request.params) |kvp| {
        if (std.mem.eql(u8, kvp.key, "hash")) {
            hash = kvp.value;
        } else {
            return try root.route.generic.badRequestReasonTask(response, "Unknown parameter");
        }
    }

    return try GetTask.task(response, .{
        .webhook_id = webhook_id,
        .hash = hash,
    });
}

/// PUT /api/webhooks/{webhook_id}/avatar
/// R1 - user must be logged (see the R-list above PutTask)
pub inline fn putHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    webhook_id: root.types.WebhookId,
) !PutTask.Task {
    _ = allocator;

    return try PutTask.task(request, response, webhook_id);
}

/// DELETE /api/webhooks/{webhook_id}/avatar
/// R1 - user must be logged (see the R-list above DeleteTask)
pub inline fn deleteHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    webhook_id: root.types.WebhookId,
) !DeleteTask.Task {
    _ = allocator;

    return try DeleteTask.task(request, response, webhook_id);
}
