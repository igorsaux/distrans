// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../root.zig");
pub const id = @import("guilds/id.zig");

const SCOPE = std.log.scoped(.@"/api/guilds/");

/// R1 - user must be logged
pub const GetTask = struct {
    const Task = root.http.Task;

    pub const ResponseItem = struct {
        id: []const u8,
        name: []const u8,
        avatar_hash: ?[]const u8,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    get_guilds_task: ?root.repo.guilds.GetGuilds.Lazy = null,
    get_guilds_result: std.ArrayList(ResponseItem) = .empty,
    body: ?[]u8 = null,
    streamer: ?root.http.Response.Streamer = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *GetTask = @ptrCast(@alignCast(ctx));

        if (this.db == null) {
            this.db = root.db_pool.rent() orelse {
                return .{ .pending = .db };
            };
        }

        // R1
        // await this.bearer_middleware
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

        // await this.get_guilds_stream
        {
            if (this.get_guilds_task == null) {
                this.get_guilds_task = .from(.init(db));
            }

            while (this.get_guilds_task.?.await()) |res| {
                switch (res) {
                    .next => |n| {
                        const guild: ResponseItem = .{
                            .id = std.fmt.allocPrint(this.response.allocator, "{}", .{n.id}) catch |err| {
                                SCOPE.err("GET failed to stringify 'id': {t}", .{err});

                                return .{ .err = err };
                            },
                            .name = this.response.allocator.dupe(u8, n.name) catch |err| {
                                SCOPE.err("GET failed to dupe 'name': {t}", .{err});

                                return .{ .err = err };
                            },
                            .avatar_hash = if (n.avatar_hash == null)
                                null
                            else
                                this.response.allocator.dupe(u8, n.avatar_hash.?) catch |err| {
                                    SCOPE.err("GET failed to dupe 'avatar_hash': {t}", .{err});

                                    return .{ .err = err };
                                },
                        };

                        this.get_guilds_result.append(this.response.allocator, guild) catch |err| {
                            SCOPE.err("GET failed to append a guild: {t}", .{err});

                            return .{ .err = err };
                        };
                    },
                    .poll => |p| return p.discard(),
                }
            }
        }

        if (this.body == null) {
            var writer: std.Io.Writer.Allocating = .init(this.response.allocator);

            std.json.fmt(this.get_guilds_result.items, .{}).format(&writer.writer) catch {
                SCOPE.err("GET failed to JSON format the response", .{});

                return .{ .err = error.OutOfMemory };
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

        if (this.get_guilds_task) |*s| {
            s.dispose();
            this.get_guilds_task = null;
        }

        if (this.db) |db| {
            db.release();
            this.db = null;
        }
    }

    pub inline fn task(request: *const root.http.Request, response: *root.http.Response) !Task {
        const this = try response.allocator.create(GetTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .request = request,
            .response = response,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// GET /api/guilds
/// R1 - user must be logged (see the R-list above GetTask)
pub inline fn getHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
) !GetTask.Task {
    _ = allocator;

    return try GetTask.task(request, response);
}
