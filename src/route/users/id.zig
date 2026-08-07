// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../root.zig");
pub const avatar = @import("id/avatar.zig");

const SCOPE = std.log.scoped(.@"/api/users/{user_id}");

/// R1 - user must be logged
/// R2 - the user exists
const GetTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        user_id: root.types.UserId,
    };

    pub const Response = struct {
        username: []const u8,
        display_name: ?[]const u8,
        avatar_hash: ?[]const u8,
        is_bot: bool,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    get_user_public_task: ?root.repo.users.Get.Lazy = null,
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

        const db = this.db.?;

        // R2
        // await this.get_user_public_task
        {
            if (this.get_user_public_task == null) {
                this.get_user_public_task = .from(.init(this.response.allocator, db, .{
                    .user_id = this.payload.user_id,
                }));
            }

            while (this.get_user_public_task.?.await()) |res| {
                return res.discard();
            }

            if (this.get_user_public_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "User not found");
            }
        }

        if (this.body == null) {
            const response: Response = .{
                .username = this.get_user_public_task.?.result.?.username,
                .display_name = this.get_user_public_task.?.result.?.display_name,
                .avatar_hash = this.get_user_public_task.?.result.?.avatar_hash,
                .is_bot = this.get_user_public_task.?.result.?.is_bot,
            };

            var writer: std.Io.Writer.Allocating = .init(this.response.allocator);

            std.json.fmt(response, .{}).format(&writer.writer) catch |err| {
                SCOPE.err("failed to serialize the response: {t}", .{err});

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

        if (this.get_user_public_task) |*t| {
            t.dispose();
            this.get_user_public_task = null;
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

/// GET /api/users/{user_id}
/// R1 - user must be logged (see the R-list above GetTask)
pub inline fn getHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    user_id: root.types.UserId,
) !GetTask.Task {
    _ = allocator;

    return try GetTask.task(request, response, .{
        .user_id = user_id,
    });
}
