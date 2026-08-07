// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../root.zig");
pub const id = @import("users/id.zig");
pub const me = @import("users/me.zig");
pub const sync = @import("users/sync.zig");

const SCOPE = std.log.scoped(.@"/api/users");

/// R2 - user must be logged
const GetTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        limit: usize,
        after: ?root.types.UserId,
    };

    pub const ResponseItem = struct {
        id: []const u8,
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
    get_users_task: ?root.repo.users.GetUsers.Lazy = null,
    get_users_result: std.ArrayList(ResponseItem) = .empty,
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

        // await this.get_users
        {
            if (this.get_users_task == null) {
                this.get_users_task = .from(.init(this.db.?, .{
                    .limit = this.payload.limit,
                    .after = this.payload.after,
                }));
            }

            while (this.get_users_task.?.await()) |res| {
                switch (res) {
                    .poll => |p| return p.discard(),
                    .next => |n| {
                        const user: ResponseItem = .{
                            .id = std.fmt.allocPrint(this.response.allocator, "{}", .{n.id}) catch |err| {
                                SCOPE.err("GET failed to stringify 'id': {t}", .{err});

                                return .{ .err = err };
                            },
                            .username = this.response.allocator.dupe(u8, n.username) catch |err| {
                                SCOPE.err("GET failed to dupe 'username': {t}", .{err});

                                return .{ .err = err };
                            },
                            .display_name = if (n.display_name == null)
                                null
                            else
                                this.response.allocator.dupe(u8, n.display_name.?) catch |err| {
                                    SCOPE.err("GET failed to dupe 'display_name': {t}", .{err});

                                    return .{ .err = err };
                                },
                            .avatar_hash = if (n.avatar_hash == null)
                                null
                            else
                                this.response.allocator.dupe(u8, n.avatar_hash.?) catch |err| {
                                    SCOPE.err("GET failed to dupe 'avatar_hash': {t}", .{err});

                                    return .{ .err = err };
                                },
                            .is_bot = n.is_bot,
                        };

                        this.get_users_result.append(this.response.allocator, user) catch |err| {
                            SCOPE.err("GET failed to append a user: {t}", .{err});

                            return .{ .err = err };
                        };
                    },
                }
            }
        }

        if (this.body == null) {
            var writer: std.Io.Writer.Allocating = .init(this.response.allocator);

            std.json.fmt(this.get_users_result.items, .{}).format(&writer.writer) catch |err| {
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

        if (this.bearer_middleware_task) |*bm| {
            bm.dispose();
            this.bearer_middleware_task = null;
        }

        if (this.db) |db| {
            db.release();
            this.db = null;
        }

        if (this.get_users_task) |*s| {
            s.dispose();
            this.get_users_task = null;
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

/// GET /api/users
/// R1 - limit > 0 and limit <= root.options.api.users.max_users_limit
pub inline fn getHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
) !GetTask.Task {
    _ = allocator;

    var limit: ?usize = null;
    var after: ?root.types.UserId = null;

    for (request.params) |kvp| {
        if (std.mem.eql(u8, kvp.key, "limit")) {
            limit = std.fmt.parseInt(usize, kvp.value, 10) catch {
                return try root.route.generic.badRequestReasonTask(response, "Bad 'limit' parameter");
            };

            // R1
            if (limit.? == 0 or limit.? > root.options.api.users.max_users_limit) {
                return try root.route.generic.badRequestReasonTask(response, "Bad 'limit' parameter");
            }
        } else if (std.mem.eql(u8, kvp.key, "after")) {
            after = std.fmt.parseInt(root.types.UserId, kvp.value, 10) catch {
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
    });
}
