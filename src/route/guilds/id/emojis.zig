// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../../root.zig");

const SCOPE = std.log.scoped(.@"/api/guilds/{guild_id}/emojis");

/// GET /api/guilds/{guild_id}/emojis
/// R1 - limit > 0 and limit <= root.options.api.emojis.max_emojis_limit; the unknown
///      and malformed parameters are rejected in getHandle
/// R2 - user must be logged (bearer); deleted users are rejected
/// R3 - the guild must exist (404 "Guild not found")
const GetTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        guild_id: root.types.GuildId,
        limit: usize,
        after: ?root.types.EmojiId,
    };

    pub const ResponseItem = struct {
        id: []const u8,
        name: []const u8,
        icon_hash: []const u8,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    guild_exists_task: ?root.repo.guilds.Exists.Lazy = null,
    get_emojis_task: ?root.repo.guilds.GetCustomEmojis.Lazy = null,
    get_emojis_result: std.ArrayList(ResponseItem) = .empty,
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

        // await this.get_emojis_task
        {
            if (this.get_emojis_task == null) {
                this.get_emojis_task = .from(.init(this.db.?, .{
                    .guild_id = this.payload.guild_id,
                    .after = this.payload.after,
                    .limit = this.payload.limit,
                }));
            }

            while (this.get_emojis_task.?.await()) |res| {
                switch (res) {
                    .poll => |p| return p.discard(),
                    .next => |n| {
                        const item: ResponseItem = .{
                            .id = std.fmt.allocPrint(this.response.allocator, "{}", .{n.id}) catch |err| {
                                SCOPE.err("GET failed to stringify 'id': {t}", .{err});

                                return .{ .err = err };
                            },
                            .name = this.response.allocator.dupe(u8, n.name) catch |err| {
                                SCOPE.err("GET failed to dupe 'name': {t}", .{err});

                                return .{ .err = err };
                            },
                            .icon_hash = this.response.allocator.dupe(u8, n.icon_hash) catch |err| {
                                SCOPE.err("GET failed to dupe 'icon_hash': {t}", .{err});

                                return .{ .err = err };
                            },
                        };

                        this.get_emojis_result.append(this.response.allocator, item) catch |err| {
                            SCOPE.err("GET failed to append an item: {t}", .{err});

                            return .{ .err = err };
                        };
                    },
                }
            }
        }

        if (this.body == null) {
            var writer: std.Io.Writer.Allocating = .init(this.response.allocator);

            std.json.fmt(this.get_emojis_result.items, .{}).format(&writer.writer) catch |err| {
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

        if (this.get_emojis_task) |*t| {
            t.dispose();
            this.get_emojis_task = null;
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

/// GET /api/guilds/{guild_id}/emojis
/// R1 - limit > 0 and limit <= root.options.api.emojis.max_emojis_limit
pub inline fn getHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    guild_id: root.types.GuildId,
) !GetTask.Task {
    _ = allocator;

    var limit: ?usize = null;
    var after: ?root.types.EmojiId = null;

    for (request.params) |kvp| {
        if (std.mem.eql(u8, kvp.key, "limit")) {
            limit = std.fmt.parseInt(usize, kvp.value, 10) catch {
                return try root.route.generic.badRequestReasonTask(response, "Bad 'limit' parameter");
            };

            // R1
            if (limit.? == 0 or limit.? > root.options.api.emojis.max_emojis_limit) {
                return try root.route.generic.badRequestReasonTask(response, "Bad 'limit' parameter");
            }
        } else if (std.mem.eql(u8, kvp.key, "after")) {
            after = std.fmt.parseInt(root.types.EmojiId, kvp.value, 10) catch {
                return try root.route.generic.badRequestReasonTask(response, "Bad 'after' parameter");
            };
        } else {
            return try root.route.generic.badRequestReasonTask(response, "Unknown parameter");
        }
    }

    if (limit == null) {
        limit = 50;
    }

    return try GetTask.task(request, response, .{
        .limit = limit.?,
        .after = after,
        .guild_id = guild_id,
    });
}

/// R1 - user must be logged (bearer); deleted users are rejected
/// R2 - the body must be non-empty with a supported raster Content-Type
///      (WebP/GIF/PNG); an empty body is 400 "Bad image", an unsupported type
///      is 415 (see postHandle)
/// R3 - the guild must exist (404 "Guild not found")
/// R4 - user must have create_emoji rights (403 "Missing permissions")
/// R5 - "name" is the only accepted query parameter and it is required
///      (400 "Unknown parameter" / "'name' is missing"); both are checked in postHandle
/// R6 - "name" must NFKC-normalize to the emoji name allowlist (`a-z`, `0-9`, `_`)
///      and be within api.emojis.min_name_codepoints ..
///      api.emojis.max_name_codepoints codepoints; the normalized form is stored
///      (400 "'name' is too short" / "'name' is invalid" / "'name' is too long")
/// R7 - the guild must hold fewer than api.guilds.max_emojis emojis
///      (400 "Too many emojis")
/// R8 - the body must be a valid WebP/GIF/PNG within the media.emoji dimensions
///      and animation caps; the encoded body must not exceed
///      media.emoji.max_output_bytes (413 "Image is too large" for
///      media.emoji.max_input_bytes, 400 "Bad image" otherwise)
/// R9 - the re-encoded WebP is hashed (XXHash64, 16 lowercase hex chars) and stored
///      as a new emoji; a duplicate (guild, name) is 409 "Emoji name is already used"
/// R10 - dispatches emoji_created and returns 201 {"id", "name", "icon_hash"}
const PostTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        guild_id: root.types.GuildId,
        raw_name: []const u8,
    };

    pub const Response = struct {
        id: []const u8,
        name: []const u8,
        icon_hash: []const u8,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    guild_exists_task: ?root.repo.guilds.Exists.Lazy = null,
    check_user_guild_rights_task: ?root.repo.rights.CheckUserGuildRights.Lazy = null,
    name: ?[]const u8 = null,
    emoji_id: ?root.types.EmojiId = null,
    count_emojis_task: ?root.repo.emojis.CountByGuild.Lazy = null,
    body_task: ?root.route.generic.Body.Lazy = null,
    encode_task: ?root.services.media.Encode.Lazy = null,
    create_emoji_task: ?root.repo.emojis.Create.Lazy = null,
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

        // R4
        // await this.check_user_guild_rights_task
        {
            if (this.check_user_guild_rights_task == null) {
                this.check_user_guild_rights_task = .from(.init(this.db.?, .{
                    .guild_id = this.payload.guild_id,
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .required = .{ .create_emoji = true },
                }));
            }

            while (this.check_user_guild_rights_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.check_user_guild_rights_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
            }
        }

        // R6
        if (this.name == null) {
            const name = root.unicode.normalize(this.response.allocator, this.payload.raw_name) catch |err| switch (err) {
                error.InvalidUtf8 => return root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is invalid"),
                error.OutOfMemory => return .{ .err = error.OutOfMemory },
            };

            const codepoints = std.unicode.utf8CountCodepoints(name) catch unreachable;

            if (codepoints < root.options.api.emojis.min_name_codepoints) {
                return root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is too short");
            }

            if (!root.utils.isAsciiEmojiNameFormat(name)) {
                return root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is invalid");
            }

            if (codepoints > root.options.api.emojis.max_name_codepoints) {
                return root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is too long");
            }

            this.name = name;
        }

        // R7
        // await this.count_emojis_task
        {
            if (this.count_emojis_task == null) {
                this.count_emojis_task = .from(.init(this.db.?, .{
                    .guild_id = this.payload.guild_id,
                }));
            }

            while (this.count_emojis_task.?.await()) |res| {
                return res.discard();
            }

            if (this.count_emojis_task.?.result >= @as(u64, root.options.api.guilds.max_emojis)) {
                return root.route.generic.responseErrorMessage(this.response, .bad_request, "Too many emojis");
            }
        }

        // R8
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

                        SCOPE.err("POST failed to buffer the body: {t}", .{err});

                        return .{ .err = err };
                    },
                    .ready => unreachable,
                }
            }
        }

        // R8
        // await this.encode_task
        {
            if (this.encode_task == null) {
                this.encode_task = .from(root.services.media.Encode.init(.{
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
                            SCOPE.debug("POST bad image", .{});

                            return root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad image");
                        }

                        SCOPE.err("POST failed to encode an emoji: {t}", .{err});

                        return .{ .err = err };
                    },
                    .ready => unreachable,
                }
            }
        }

        if (this.emoji_id == null) {
            this.emoji_id = root.sf_generator.generate();
        }

        // R9
        // await this.create_emoji_task
        {
            if (this.create_emoji_task == null) {
                this.create_emoji_task = .from(.init(this.db.?, .{
                    .id = this.emoji_id.?,
                    .guild_id = this.payload.guild_id,
                    .name = this.name.?,
                    .icon_data = this.encode_task.?.result.data,
                    .icon_hash = this.encode_task.?.result.hash[0..],
                }));
            }

            while (this.create_emoji_task.?.await()) |res| {
                return res.discard();
            }

            if (this.create_emoji_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .conflict, "Emoji name is already used");
            }
        }

        // R10
        if (!this.event_raised) {
            this.event_raised = true;

            root.bus.raise(.{
                .emoji_created = .{
                    .id = this.emoji_id.?,
                    .guild_id = this.payload.guild_id,
                },
            });
        }

        // await this.audit_log
        {
            if (this.audit_log == null) {
                this.audit_entries[0] = .{
                    .action = .emoji_create,
                    .target_id = this.emoji_id.?,
                };

                this.audit_log = .from(root.repo.audit_log.Insert.init(this.db.?, this.response.allocator, .{
                    .guild_id = this.payload.guild_id,
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
                .id = std.fmt.allocPrint(this.response.allocator, "{}", .{this.emoji_id.?}) catch |err| {
                    SCOPE.err("POST failed to stringify 'id': {t}", .{err});

                    return .{ .err = err };
                },
                .name = this.name.?,
                .icon_hash = this.encode_task.?.result.hash[0..],
            };

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

        if (this.guild_exists_task) |*t| {
            t.dispose();
            this.guild_exists_task = null;
        }

        if (this.check_user_guild_rights_task) |*t| {
            t.dispose();
            this.check_user_guild_rights_task = null;
        }

        if (this.count_emojis_task) |*t| {
            t.dispose();
            this.count_emojis_task = null;
        }

        if (this.body_task) |*t| {
            t.dispose();
            this.body_task = null;
        }

        if (this.encode_task) |*t| {
            t.dispose();
            this.encode_task = null;
        }

        if (this.create_emoji_task) |*t| {
            t.dispose();
            this.create_emoji_task = null;
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

/// POST /api/guilds/{guild_id}/emojis?name={name}
/// R2 - the body must be non-empty with a supported raster Content-Type
///      (WebP/GIF/PNG) (see the R-list above PostTask)
/// R5 - only the "name" query parameter is accepted and it is required; anything
///      else is 400 "Unknown parameter" / "'name' is missing"
pub inline fn postHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    guild_id: root.types.GuildId,
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

    var raw_name: ?[]const u8 = null;

    for (request.params) |kvp| {
        // R5
        if (std.mem.eql(u8, kvp.key, "name")) {
            raw_name = kvp.value;
        } else {
            return try root.route.generic.badRequestReasonTask(response, "Unknown parameter");
        }
    }

    // R5
    const raw_name_value = raw_name orelse {
        return try root.route.generic.badRequestReasonTask(response, "'name' is missing");
    };

    return try PostTask.task(request, response, .{
        .guild_id = guild_id,
        .raw_name = raw_name_value,
    });
}
