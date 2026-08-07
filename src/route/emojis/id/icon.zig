// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../../root.zig");

/// R1 - the "hash" query parameter must be present and match the stored icon hash of
///      an existing emoji; otherwise 404 "Icon not found"
/// R2 - only the "hash" query parameter is accepted; anything else is
///      400 "Unknown parameter"
const GetTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        emoji_id: root.types.EmojiId,
        hash: ?[]const u8 = null,
    };

    response: *root.http.Response,
    payload: Payload,
    db: ?*root.db.Connection = null,
    get_emoji_icon_task: ?root.repo.emojis.GetIcon.Lazy = null,
    streamer: ?root.http.Response.Streamer = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *GetTask = @ptrCast(@alignCast(ctx));

        // R1
        const hash = this.payload.hash orelse {
            return root.route.generic.responseErrorMessage(this.response, .not_found, "Icon not found");
        };

        // R1
        if (hash.len == 0) {
            return root.route.generic.responseErrorMessage(this.response, .not_found, "Icon not found");
        }

        if (this.db == null) {
            this.db = root.db_pool.rent() orelse {
                return .{ .pending = .db };
            };
        }

        // R1
        // await this.get_emoji_icon_task
        {
            if (this.get_emoji_icon_task == null) {
                this.get_emoji_icon_task = .from(.init(this.response.allocator, this.db.?, .{
                    .id = this.payload.emoji_id,
                    .hash = hash,
                }));
            }

            while (this.get_emoji_icon_task.?.await()) |res| {
                return res.discard();
            }

            if (this.get_emoji_icon_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Icon not found");
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

            if (!writer.beginBody("image/webp", this.get_emoji_icon_task.?.result.?.len)) {
                return .{ .pending = .want_write };
            }

            writer.commit();
            this.streamer = this.response.getStreamer(this.get_emoji_icon_task.?.result.?);
        }

        return this.streamer.?.poll();
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetTask = @ptrCast(@alignCast(ctx));

        if (this.get_emoji_icon_task) |*t| {
            t.dispose();
            this.get_emoji_icon_task = null;
        }

        if (this.db) |db| {
            db.release();
            this.db = null;
        }
    }

    pub inline fn task(response: *root.http.Response, payload: Payload) !Task {
        const this = try response.allocator.create(GetTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .response = response,
            .payload = payload,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// GET /api/emojis/{emoji_id}/icon?hash={hash}
/// Public endpoint: no authentication required.
/// R1 - "hash" must be present and match the stored icon hash (see the R-list above GetTask)
/// R2 - only "hash" is accepted (see the R-list above GetTask)
pub inline fn getHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    emoji_id: root.types.EmojiId,
) !GetTask.Task {
    _ = allocator;

    var hash: ?[]const u8 = null;

    for (request.params) |kvp| {
        if (std.mem.eql(u8, kvp.key, "hash")) {
            hash = kvp.value;
        } else {
            // R2
            return try root.route.generic.badRequestReasonTask(response, "Unknown parameter");
        }
    }

    return try GetTask.task(response, .{
        .emoji_id = emoji_id,
        .hash = hash,
    });
}

/// R1 - user must be logged (bearer); deleted users are rejected
/// R2 - the body must be non-empty with a supported raster Content-Type
///      (WebP/GIF/PNG), and no query parameter is accepted; an empty body is
///      400 "Bad image", an unsupported type is 415, anything else is
///      400 "Unknown parameter" (all checked in putHandle)
/// R3 - the emoji must exist (404 "Emoji not found")
/// R4 - user must have modify_emoji rights (403 "Missing permissions")
/// R5 - the body must be a valid WebP/GIF/PNG within the media.emoji dimensions
///      and animation caps; the encoded body must not exceed
///      media.emoji.max_output_bytes (413 "Image is too large" for
///      media.emoji.max_input_bytes, 400 "Bad image" otherwise)
/// R6 - the re-encoded WebP is hashed (XXHash64, 16 lowercase hex chars), replaces the
///      emoji's icon and is returned as 200 {"icon_hash": "<hash>"}; a store raced
///      with a deletion is 404 "Emoji not found"; dispatches an emoji_updated
///      gateway event
const PutTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        emoji_id: root.types.EmojiId,
    };

    pub const Response = struct {
        icon_hash: []const u8,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    get_emoji_task: ?root.repo.emojis.Get.Lazy = null,
    check_user_guild_rights_task: ?root.repo.rights.CheckUserGuildRights.Lazy = null,
    body_task: ?root.route.generic.Body.Lazy = null,
    encode_task: ?root.services.media.Encode.Lazy = null,
    set_icon_task: ?root.repo.emojis.SetIcon.Lazy = null,
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

        // R3
        // await this.get_emoji_task
        {
            if (this.get_emoji_task == null) {
                this.get_emoji_task = .from(.init(this.db.?, .{
                    .id = this.payload.emoji_id,
                }));
            }

            while (this.get_emoji_task.?.await()) |res| {
                return res.discard();
            }

            if (this.get_emoji_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Emoji not found");
            }
        }

        // R4
        // await this.check_user_guild_rights_task
        {
            if (this.check_user_guild_rights_task == null) {
                this.check_user_guild_rights_task = .from(.init(this.db.?, .{
                    .guild_id = this.get_emoji_task.?.result.?.guild_id,
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .required = .{ .modify_emoji = true },
                }));
            }

            while (this.check_user_guild_rights_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.check_user_guild_rights_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
            }
        }

        // R5
        // await this.body_task
        {
            if (this.body_task == null) {
                this.body_task = .from(.init(
                    this.request,
                    this.response,
                    root.options.media.emoji.max_input_bytes,
                ));
            }

            while (this.body_task.?.await()) |res| {
                switch (res) {
                    .pending => |p| return .{ .pending = p },
                    .err => |err| {
                        if (err == error.BodyTooLarge) {
                            return root.route.generic.responseErrorMessage(this.response, .content_too_large, "Image is too large");
                        }

                        return .{ .err = err };
                    },
                    .ready => unreachable,
                }
            }
        }

        // R5
        // await this.encode_task
        {
            if (this.encode_task == null) {
                this.encode_task = .from(.init(.{
                    .data = this.body_task.?.result,
                    .mime_type = this.request.content_type orelse "",
                    .limits = .{
                        .max_input_bytes = root.options.media.emoji.max_input_bytes,
                        .max_output_bytes = root.options.media.emoji.max_output_bytes,
                        .max_dimensions = root.options.media.emoji.max_dimensions,
                        .max_animation_frames = root.options.media.emoji.max_animation_frames,
                        .min_animation_frame_delay_ms = root.options.media.emoji.min_animation_frame_delay_ms,
                        .max_animation_frame_delay_ms = root.options.media.emoji.max_animation_frame_delay_ms,
                        .max_animation_duration_ms = root.options.media.emoji.max_animation_duration_ms,
                    },
                    .options = .{
                        .lossless = root.options.media.emoji.lossless,
                        .quality = root.options.media.emoji.quality,
                        .compression_level = root.options.media.emoji.compression_level,
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

                        return .{ .err = err };
                    },
                    .ready => unreachable,
                }
            }
        }

        // R6
        // await this.set_icon_task
        {
            if (this.set_icon_task == null) {
                this.set_icon_task = .from(.init(this.db.?, .{
                    .id = this.payload.emoji_id,
                    .data = this.encode_task.?.result.data,
                    .hash = this.encode_task.?.result.hash[0..],
                }));
            }

            while (this.set_icon_task.?.await()) |res| {
                return res.discard();
            }

            if (this.set_icon_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Emoji not found");
            }
        }

        // R6
        if (!this.event_raised) {
            this.event_raised = true;

            root.bus.raise(.{
                .emoji_updated = .{
                    .id = this.payload.emoji_id,
                    .guild_id = this.get_emoji_task.?.result.?.guild_id,
                },
            });
        }

        // await this.audit_log
        {
            if (this.audit_log == null) {
                this.audit_entries[0] = .{
                    .action = .emoji_icon_update,
                    .target_id = this.payload.emoji_id,
                };

                this.audit_log = .from(root.repo.audit_log.Insert.init(this.db.?, this.response.allocator, .{
                    .guild_id = this.get_emoji_task.?.result.?.guild_id,
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
                .icon_hash = this.encode_task.?.result.hash[0..],
            };

            std.json.fmt(response, .{}).format(&writer.writer) catch |err| {
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

        if (this.get_emoji_task) |*t| {
            t.dispose();
            this.get_emoji_task = null;
        }

        if (this.check_user_guild_rights_task) |*t| {
            t.dispose();
            this.check_user_guild_rights_task = null;
        }

        if (this.body_task) |*t| {
            t.dispose();
            this.body_task = null;
        }

        if (this.encode_task) |*t| {
            t.dispose();
            this.encode_task = null;
        }

        if (this.set_icon_task) |*t| {
            t.dispose();
            this.set_icon_task = null;
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
        const this = try response.allocator.create(PutTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .request = request,
            .response = response,
            .payload = payload,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// PUT /api/emojis/{emoji_id}/icon
/// R2 - the body must be non-empty with a supported raster Content-Type
///      (WebP/GIF/PNG) and no query parameter may be present (see the R-list
///      above PutTask)
pub inline fn putHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    emoji_id: root.types.EmojiId,
) !PutTask.Task {
    _ = allocator;

    // R2
    if (request.getContentLength() == 0) {
        return try root.route.generic.badRequestReasonTask(response, "Bad image");
    }

    // R2
    if (!root.services.media.isSupportedMime(request.content_type)) {
        return try root.route.generic.unsupportedMediaTypeTask(response);
    }

    // R2
    for (request.params) |_| {
        return try root.route.generic.badRequestReasonTask(response, "Unknown parameter");
    }

    return try PutTask.task(request, response, .{
        .emoji_id = emoji_id,
    });
}
