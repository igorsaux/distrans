// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../../root.zig");

const SCOPE = std.log.scoped(.@"/api/users/@me/userdata");

/// R1 - user must be logged (bearer); deleted users are rejected
/// R2 - responds 200 with `{ "data": <raw JSON>, "updated_at": <epoch_ms> }`;
///      with no stored row both fields are `null`
const GetTask = struct {
    pub const Task = root.http.Task;

    const Response = struct {
        data: ?std.json.Value,
        updated_at: ?u64,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    get_userdata_task: ?root.repo.userdata.Get.Lazy = null,
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

        // await this.get_userdata_task
        {
            if (this.get_userdata_task == null) {
                this.get_userdata_task = .from(.init(this.response.allocator, this.db.?, .{
                    .user_id = this.bearer_middleware_task.?.result.?,
                }));
            }

            while (this.get_userdata_task.?.await()) |res| {
                return res.discard();
            }
        }

        if (this.body == null) {
            // R2
            const response: Response = blk: {
                const row = this.get_userdata_task.?.result orelse {
                    break :blk .{
                        .data = null,
                        .updated_at = null,
                    };
                };

                // The stored text is a valid JSON value (validated on PUT); parse
                // it so `std.json.fmt` embeds it raw instead of as a string.
                const data = std.json.parseFromSliceLeaky(
                    std.json.Value,
                    this.response.allocator,
                    row.data,
                    .{},
                ) catch |err| {
                    SCOPE.err("GET failed to parse stored userdata: {t}", .{err});

                    return .{ .err = err };
                };

                break :blk .{
                    .data = data,
                    .updated_at = row.updated_at,
                };
            };

            var writer: std.Io.Writer.Allocating = .init(this.response.allocator);

            std.json.fmt(response, .{}).format(&writer.writer) catch |err| {
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

        if (this.get_userdata_task) |*t| {
            t.dispose();
            this.get_userdata_task = null;
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
        const this = try response.allocator.create(GetTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .request = request,
            .response = response,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// GET /api/users/@me/userdata
/// R1 - user must be logged (see the R-list above GetTask)
pub inline fn getHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
) !GetTask.Task {
    _ = allocator;

    return try GetTask.task(request, response);
}

/// R1 - content type must be application/json (415) and body non-empty (400)
/// R2 - request must be authenticated (bearer); deleted users rejected
/// R3 - body must not exceed api.users.max_userdata_bytes; otherwise
///      413 "Userdata is too large"
/// R4 - body must be a valid JSON value; otherwise 400 "Bad JSON"
/// R5 - the body is stored as the user's userdata (replacing any previous one)
///      and the request succeeds with 200 {"updated_at": <epoch_ms>}
const PutTask = struct {
    pub const Task = root.http.Task;

    const Response = struct {
        updated_at: u64,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    body_task: ?root.route.generic.Body.Lazy = null,
    upsert_task: ?root.repo.userdata.Upsert.Lazy = null,
    body: ?[]const u8 = null,
    streamer: ?root.http.Response.Streamer = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *PutTask = @ptrCast(@alignCast(ctx));

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
        // await this.body_task
        {
            if (this.body_task == null) {
                this.body_task = .from(.init(
                    this.request,
                    this.response,
                    root.options.api.users.max_userdata_bytes,
                ));
            }

            while (this.body_task.?.await()) |res| {
                switch (res) {
                    .pending => |p| return .{ .pending = p },
                    .err => |err| {
                        if (err == error.BodyTooLarge) {
                            return root.route.generic.responseErrorMessage(this.response, .content_too_large, "Userdata is too large");
                        }

                        SCOPE.err("PUT failed to buffer the body: {t}", .{err});

                        return .{ .err = err };
                    },
                    .ready => unreachable,
                }
            }
        }

        // R4
        _ = std.json.parseFromSliceLeaky(
            std.json.Value,
            this.response.allocator,
            this.body_task.?.result,
            .{},
        ) catch {
            return root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad JSON");
        };

        // R5
        // await this.upsert_task
        {
            if (this.upsert_task == null) {
                this.upsert_task = .from(.init(this.db.?, .{
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .data = this.body_task.?.result,
                }));
            }

            while (this.upsert_task.?.await()) |res| {
                return res.discard();
            }
        }

        if (this.body == null) {
            var writer: std.Io.Writer.Allocating = .init(this.response.allocator);

            const response: Response = .{
                .updated_at = this.upsert_task.?.result,
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

        if (this.body_task) |*t| {
            t.dispose();
            this.body_task = null;
        }

        if (this.upsert_task) |*t| {
            t.dispose();
            this.upsert_task = null;
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
        const this = try response.allocator.create(PutTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .request = request,
            .response = response,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// PUT /api/users/@me/userdata
/// R1 - content type must be application/json (415) and body non-empty (400)
///      (see the R-list above PutTask)
pub inline fn putHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
) !PutTask.Task {
    _ = allocator;

    // R1
    if (request.getContentLength() == 0) {
        return try root.route.generic.badRequestTask(response);
    }

    // R1
    if (!root.utils.startsWithMaybe(u8, request.content_type, "application/json")) {
        return try root.route.generic.unsupportedMediaTypeTask(response);
    }

    return try PutTask.task(request, response);
}
