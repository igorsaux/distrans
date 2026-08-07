// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.@"/api/files");

/// R1 - user must be logged (bearer)
/// R2 - storage must be configured (files.storage != .none); else 503
///      "File uploading is unavailable"
/// R3 - body must be non-empty; else 400 "Bad file"
/// R4 - Content-Type must be allowed by files.whitelist; else 415
///      "Unsupported Media Type"
/// R5 - body must not exceed files.max_size; else 413 "File is too large"
/// R6 - "name" query parameter must be present, non-empty and sanitize to a
///      non-empty string within api.files.max_name_codepoints; unknown
///      parameters are rejected
/// R7 - when media.isSupportedMime(Content-Type) (WebP/GIF/PNG/JPEG): the body
///      must not exceed media.files.max_input_bytes (413 "File is too large")
///      and it is re-encoded to WebP (400 "Bad file" on failure); still JPEG
///      frames are rotated per their EXIF orientation. The stored bytes are the
///      re-encoded ones with Content-Type image/webp. Otherwise the body is
///      stored as-is with the request Content-Type. Stored objects get
///      Cache-Control immutable; non-media types get Content-Disposition:
///      attachment.
/// R8 - the final bytes are hashed (SHA-256); a new row is inserted (or an
///      existing row with the same hash is reused) and, for a new file, the
///      bytes are uploaded to S3 as `files/<hash>`; responds 201 or 200 with
///      {"id","name","size","content_type","hash","public_url"}
const PostTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        name: []const u8,
        content_type: []const u8,
    };

    const Response = struct {
        id: []const u8,
        name: []const u8,
        size: u64,
        content_type: []const u8,
        hash: []const u8,
        public_url: []const u8,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    body_task: ?root.route.generic.Body.Lazy = null,
    encode_task: ?root.services.media.Encode.Lazy = null,
    final_content: ?[]const u8 = null,
    final_content_type: ?[]const u8 = null,
    id: ?root.types.FileId = null,
    hash: ?[root.services.files.Hash.digest_length]u8 = null,
    hash_hex: ?[root.services.files.Hash.digest_length * 2]u8 = null,
    create_task: ?root.repo.files.Create.Lazy = null,
    get_by_hash_task: ?root.repo.files.GetByHash.Lazy = null,
    upload_task: ?root.services.files.Upload.Lazy = null,
    created: bool = false,
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

        // R2
        if (root.options.files.storage == .none) {
            return root.route.generic.responseErrorMessage(this.response, .service_unavailable, "File uploading is unavailable");
        }

        // R5
        // await this.body_task
        {
            if (this.body_task == null) {
                this.body_task = .from(.init(
                    this.request,
                    this.response,
                    root.options.files.max_size,
                ));
            }

            while (this.body_task.?.await()) |res| {
                switch (res) {
                    .pending => |p| return .{ .pending = p },
                    .err => |err| {
                        if (err == error.BodyTooLarge) {
                            return root.route.generic.responseErrorMessage(this.response, .content_too_large, "File is too large");
                        }

                        SCOPE.err("POST failed to buffer the body: {t}", .{err});

                        return .{ .err = err };
                    },
                    .ready => unreachable,
                }
            }
        }

        // R7
        if (root.services.media.isSupportedMime(this.payload.content_type)) {
            if (this.body_task.?.result.len > root.options.media.files.max_input_bytes) {
                return root.route.generic.responseErrorMessage(this.response, .content_too_large, "File is too large");
            }

            // await this.encode_task
            {
                if (this.encode_task == null) {
                    this.encode_task = .from(.init(.{
                        .data = this.body_task.?.result,
                        .mime_type = this.payload.content_type,
                        .limits = .{
                            .max_input_bytes = root.options.media.files.max_input_bytes,
                            .max_output_bytes = root.options.media.files.max_output_bytes,
                            .max_dimensions = root.options.media.files.max_dimensions,
                            .max_animation_frames = root.options.media.files.max_animation_frames,
                            .min_animation_frame_delay_ms = root.options.media.files.min_animation_frame_delay_ms,
                            .max_animation_frame_delay_ms = root.options.media.files.max_animation_frame_delay_ms,
                            .max_animation_duration_ms = root.options.media.files.max_animation_duration_ms,
                        },
                        .options = .{
                            .lossless = root.options.media.files.lossless,
                            .quality = root.options.media.files.quality,
                            .compression_level = root.options.media.files.compression_level,
                        },
                    }));
                }

                while (this.encode_task.?.await()) |res| {
                    switch (res) {
                        .pending => |p| return .{ .pending = p },
                        .err => |err| {
                            if (err == root.services.media.Error.BadImage or
                                err == root.services.media.Error.BodyTooLarge)
                            {
                                SCOPE.debug("POST bad file", .{});

                                return root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad file");
                            }

                            SCOPE.err("POST failed to encode a file: {t}", .{err});

                            return .{ .err = err };
                        },
                        .ready => unreachable,
                    }
                }
            }

            this.final_content = this.encode_task.?.result.data;
            this.final_content_type = root.services.media.OUTPUT_IMAGE_MIME_TYPE;
        } else {
            this.final_content = this.body_task.?.result;
            this.final_content_type = this.payload.content_type;
        }

        const content = this.final_content.?;
        const content_type = this.final_content_type.?;

        // R8
        if (this.hash_hex == null) {
            this.hash = std.mem.zeroes([root.services.files.Hash.digest_length]u8);
            root.services.files.Hash.hash(content, &this.hash.?, .{});

            this.hash_hex = root.services.files.hexDigest(&this.hash.?);
        }

        const hash_hex = this.hash_hex.?;

        if (this.id == null) {
            this.id = root.sf_generator.generate();
        }

        // R8
        // await this.create_task
        {
            if (this.create_task == null) {
                this.create_task = .from(.init(this.db.?, .{
                    .id = this.id.?,
                    .name = this.payload.name,
                    .hash = &hash_hex,
                    .size = content.len,
                    .content_type = content_type,
                }));
            }

            while (this.create_task.?.await()) |res| {
                return res.discard();
            }
        }

        this.created = this.create_task.?.result;

        if (this.create_task.?.result) {
            const key = std.fmt.allocPrint(this.response.allocator, "files/{s}", .{hash_hex}) catch |err| {
                SCOPE.err("POST failed to build the object key: {t}", .{err});

                return .{ .err = err };
            };

            // R8
            // await this.upload_task
            {
                if (this.upload_task == null) {
                    this.upload_task = .from(.init(.{
                        .content = content,
                        .key = key,
                        .content_type = content_type,
                        .name = this.payload.name,
                    }));
                }

                while (this.upload_task.?.await()) |res| {
                    return res.discard();
                }
            }

            if (!this.upload_task.?.result) {
                SCOPE.err("POST failed to upload the file", .{});

                return root.route.generic.responseErrorMessage(this.response, .internal_server_error, "Failed to upload the file");
            }
        } else {
            // R8 - a row with this hash already exists, reuse its id and
            // metadata.
            // await this.get_by_hash_task
            {
                if (this.get_by_hash_task == null) {
                    this.get_by_hash_task = .from(.init(this.response.allocator, this.db.?, .{
                        .hash = hash_hex[0..],
                    }));
                }

                while (this.get_by_hash_task.?.await()) |res| {
                    return res.discard();
                }

                if (this.get_by_hash_task.?.result == null) {
                    SCOPE.err("POST failed to find the existing file", .{});

                    return .{ .err = error.FileNotFound };
                }

                this.id = this.get_by_hash_task.?.result.?.id;
            }
        }

        if (this.body == null) {
            const storage = switch (root.options.files.storage) {
                .s3 => |s3| s3,
                else => return root.route.generic.responseErrorMessage(this.response, .service_unavailable, "File uploading is unavailable"),
            };

            const existing = if (this.created)
                null
            else
                this.get_by_hash_task.?.result;

            const name = if (this.created)
                this.payload.name
            else
                existing.?.name;
            const size = if (this.created)
                content.len
            else
                existing.?.size;
            const stored_content_type = if (this.created)
                content_type
            else
                existing.?.content_type;

            const public_url = std.fmt.allocPrint(this.response.allocator, "{s}/files/{s}", .{
                storage.public_base_url,
                hash_hex,
            }) catch |err| {
                SCOPE.err("POST failed to build the public URL: {t}", .{err});

                return .{ .err = err };
            };

            const response: Response = .{
                .id = std.fmt.allocPrint(this.response.allocator, "{}", .{this.id.?}) catch |err| {
                    SCOPE.err("POST failed to stringify 'id': {t}", .{err});

                    return .{ .err = err };
                },
                .name = name,
                .size = size,
                .content_type = stored_content_type,
                .hash = &hash_hex,
                .public_url = public_url,
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

            if (!writer.writeCode(if (this.created) .created else .ok)) {
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

        if (this.create_task) |*t| {
            t.dispose();
            this.create_task = null;
        }

        if (this.get_by_hash_task) |*t| {
            t.dispose();
            this.get_by_hash_task = null;
        }

        if (this.upload_task) |*t| {
            t.dispose();
            this.upload_task = null;
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

/// POST /api/files
/// R3 - body must be non-empty (see the R-list above PostTask)
/// R4 - Content-Type must be allowed by files.whitelist
/// R5 - body must not exceed files.max_size
/// R6 - "name" query parameter must be present and valid
pub inline fn postHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
) !PostTask.Task {
    _ = allocator;

    // R3
    if (request.getContentLength() == 0) {
        return try root.route.generic.badRequestReasonTask(response, "Bad file");
    }

    // R4
    if (!root.utils.mimeAllowed(root.options.files.whitelist, request.content_type)) {
        return try root.route.generic.unsupportedMediaTypeTask(response);
    }

    // R5
    if (request.getContentLength() > root.options.files.max_size) {
        return try root.route.generic.CodeBodyResponse.task(response, .content_too_large, "application/json",
            \\{ "message": "File is too large" }
        , null);
    }

    // R6
    var name: ?[]const u8 = null;

    for (request.params) |kvp| {
        if (std.mem.eql(u8, kvp.key, "name")) {
            if (kvp.value.len == 0) {
                return try root.route.generic.badRequestReasonTask(response, "Bad 'name' parameter");
            }

            const normalized = root.unicode.normalize(response.allocator, kvp.value) catch {
                return try root.route.generic.badRequestReasonTask(response, "Bad 'name' parameter");
            };

            if (normalized.len == 0 or
                (root.unicode.findForbiddenCodepoint(.name, normalized) catch null) != null)
            {
                return try root.route.generic.badRequestReasonTask(response, "Bad 'name' parameter");
            }

            if (std.unicode.utf8CountCodepoints(normalized) catch unreachable >
                root.options.api.files.max_name_codepoints)
            {
                return try root.route.generic.badRequestReasonTask(response, "Bad 'name' parameter");
            }

            name = normalized;
        } else {
            return try root.route.generic.badRequestReasonTask(response, "Unknown parameter");
        }
    }

    if (name == null) {
        return try root.route.generic.badRequestReasonTask(response, "Missing 'name' parameter");
    }

    const content_type = request.content_type orelse {
        return try root.route.generic.unsupportedMediaTypeTask(response);
    };

    return try PostTask.task(request, response, .{
        .name = name.?,
        .content_type = content_type,
    });
}
