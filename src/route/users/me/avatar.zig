// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../../root.zig");

const SCOPE = std.log.scoped(.@"/api/users/@me/avatar");

/// R1 - user must be logged (bearer); deleted users are rejected
/// R2 - the body must be non-empty and its Content-Type must be a supported
///      raster type (image/webp, image/gif, image/png); an empty body is 400
///      "Bad image", an unsupported type is 415 (see putHandle)
/// R3 - the body must not exceed media.avatar.max_input_bytes; otherwise
///      413 "Image is too large"
/// R4 - the body must be a valid WebP/GIF/PNG within the media.avatar dimensions
///      and animation caps; otherwise 400 "Bad image"
/// R5 - images are re-encoded to WebP (animations to animated WebP), hashed
///      (XXHash64, 16 lowercase hex chars), stored as the user's avatar and returned
///      as 200 {"avatar_hash": "<hash>"}; a store failure is 500
const PostTask = struct {
    pub const Task = root.http.Task;

    pub const Response = struct {
        avatar_hash: []const u8,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    body_task: ?root.route.generic.Body.Lazy = null,
    encode_task: ?root.services.media.Encode.Lazy = null,
    set_avatar_task: ?root.repo.users.SetAvatar.Lazy = null,
    event_raised: bool = false,
    body: ?[]const u8 = null,
    streamer: ?root.http.Response.Streamer = null,

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

        // R3
        // await this.body_task
        {
            if (this.body_task == null) {
                this.body_task = .from(.init(
                    this.request,
                    this.response,
                    root.options.media.avatar.max_input_bytes,
                ));
            }

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

        // R4
        // R5
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
                            SCOPE.debug("PUT bad image", .{});

                            return root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad image");
                        }

                        SCOPE.err("PUT failed to encode an avatar: {t}", .{err});

                        return .{ .err = err };
                    },
                    .ready => unreachable,
                }
            }
        }

        // await this.set_avatar_task
        {
            if (this.set_avatar_task == null) {
                this.set_avatar_task = .from(.init(this.db.?, .{
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .data = this.encode_task.?.result.data,
                    .hash = this.encode_task.?.result.hash[0..],
                }));
            }

            while (this.set_avatar_task.?.await()) |res| {
                return res.discard();
            }

            if (this.set_avatar_task.?.result == null) {
                SCOPE.err("PUT failed to store the avatar of '{}'", .{this.bearer_middleware_task.?.result.?});

                return root.route.generic.responseErrorMessage(this.response, .internal_server_error, "Failed to store an avatar");
            }
        }

        if (!this.event_raised) {
            this.event_raised = true;

            root.bus.raise(.{
                .user_updated = .{
                    .id = this.bearer_middleware_task.?.result.?,
                },
            });
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
        const this: *PostTask = @ptrCast(@alignCast(ctx));

        if (this.bearer_middleware_task) |*t| {
            t.dispose();
            this.bearer_middleware_task = null;
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

        if (this.db) |db| {
            db.release();
            this.db = null;
        }
    }

    pub inline fn task(
        request: *const root.http.Request,
        response: *root.http.Response,
    ) !Task {
        const this = try response.allocator.create(PostTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .request = request,
            .response = response,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// PUT /api/users/@me/avatar
/// R1 - user must be logged
/// R2 - the body must be non-empty with a supported raster Content-Type
///      (WebP/GIF/PNG); otherwise 400 "Bad image" / 415 (see the R-list above
///      PostTask)
pub inline fn putHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
) !PostTask.Task {
    _ = allocator;

    // R2
    if (request.getContentLength() == 0) {
        return try root.route.generic.badRequestReasonTask(response, "Bad image");
    }

    // R2
    if (!root.services.media.isSupportedMime(request.content_type)) {
        return try root.route.generic.unsupportedMediaTypeTask(response);
    }

    return try PostTask.task(request, response);
}

/// R1 - user must be logged (bearer); deleted users are rejected
/// R2 - the avatar is cleared and the request succeeds with 204 No Content; clearing is
///      idempotent (a user without an avatar is still 204)
const DeleteTask = struct {
    pub const Task = root.http.Task;

    request: *const root.http.Request,
    response: *root.http.Response,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    clear_avatar_task: ?root.repo.users.ClearAvatar.Lazy = null,
    event_raised: bool = false,

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
        // await this.clear_avatar_task
        {
            if (this.clear_avatar_task == null) {
                this.clear_avatar_task = .from(.init(this.db.?, .{
                    .user_id = this.bearer_middleware_task.?.result.?,
                }));
            }

            while (this.clear_avatar_task.?.await()) |res| {
                return res.discard();
            }

            if (this.clear_avatar_task.?.result == null) {
                SCOPE.err("DELETE failed to clear the avatar of '{}'", .{this.bearer_middleware_task.?.result.?});

                return root.route.generic.responseErrorMessage(this.response, .internal_server_error, "Failed to clear an avatar");
            }
        }

        if (!this.event_raised) {
            this.event_raised = true;

            root.bus.raise(.{
                .user_updated = .{
                    .id = this.bearer_middleware_task.?.result.?,
                },
            });
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

        if (this.clear_avatar_task) |*t| {
            t.dispose();
            this.clear_avatar_task = null;
        }

        if (this.db) |db| {
            db.release();
            this.db = null;
        }
    }

    pub inline fn task(
        request: *const root.http.Request,
        response: *root.http.Response,
    ) !Task {
        const this = try response.allocator.create(DeleteTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .request = request,
            .response = response,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// DELETE /api/users/@me/avatar
/// R1 - user must be logged (see the R-list above DeleteTask)
pub inline fn deleteHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
) !DeleteTask.Task {
    _ = allocator;

    return try DeleteTask.task(request, response);
}
