// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../../../root.zig");

const SCOPE = std.log.scoped(.@"/api/guilds/{guild_id}/members/{user_id}/roles");

/// R1 - user must be logged
const GetTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        guild_id: root.types.GuildId,
        user_id: root.types.UserId,
    };

    pub const ResponseItem = []const u8;

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    guild_exists_task: ?root.repo.guilds.Exists.Lazy = null,
    user_exists_task: ?root.repo.users.Exists.Lazy = null,
    get_user_roles_stream: ?root.repo.users.GetRoles.Lazy = null,
    get_user_roles_stream_result: std.ArrayList(ResponseItem) = .empty,
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

        // await this.user_exists_task
        {
            if (this.user_exists_task == null) {
                this.user_exists_task = .from(.init(this.db.?, .{
                    .user_id = this.payload.user_id,
                }));
            }

            while (this.user_exists_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.user_exists_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "User not found");
            }
        }

        // await this.get_user_roles_stream
        {
            if (this.get_user_roles_stream == null) {
                this.get_user_roles_stream = .from(.init(this.db.?, .{
                    .guild_id = this.payload.guild_id,
                    .user_id = this.payload.user_id,
                }));
            }

            while (this.get_user_roles_stream.?.await()) |res| {
                switch (res) {
                    .next => |n| {
                        const role_id = std.fmt.allocPrint(this.response.allocator, "{}", .{n}) catch |err| {
                            SCOPE.err("GET failed to stringify 'role_id': {t}", .{err});

                            return .{ .err = err };
                        };

                        this.get_user_roles_stream_result.append(this.response.allocator, role_id) catch |err| {
                            SCOPE.err("GET failed to append result: {t}", .{err});

                            return .{ .err = err };
                        };
                    },
                    .poll => |p| return p.discard(),
                }
            }
        }

        if (this.body == null) {
            var writer: std.Io.Writer.Allocating = .init(this.response.allocator);

            std.json.fmt(this.get_user_roles_stream_result.items, .{}).format(&writer.writer) catch |err| {
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

        if (this.user_exists_task) |*t| {
            t.dispose();
            this.user_exists_task = null;
        }

        if (this.get_user_roles_stream) |*s| {
            s.dispose();
            this.get_user_roles_stream = null;
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

/// GET /api/guilds/{guild_id}/members/{user_id}/roles
/// R1 - user must be logged (see the R-list above GetTask)
pub inline fn getHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    guild_id: root.types.GuildId,
    user_id: root.types.UserId,
) !GetTask.Task {
    _ = allocator;

    return try GetTask.task(request, response, .{
        .guild_id = guild_id,
        .user_id = user_id,
    });
}
