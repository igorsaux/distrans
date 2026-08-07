// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../root.zig");

const SCOPE = std.log.scoped(.@"/api/system/superuser");

/// R2 - request must carry a valid system token
/// R3 - "guild_id" must be present, a string and parseable as a guild id
/// R4 - "user_id" must be present, a string and parseable as a user id
/// R5 - the guild and the user must exist
const PostTask = struct {
    const Task = root.http.Task;

    pub const Response = struct {
        id: []const u8,
    };

    const Content = struct {
        guild_id: root.types.GuildId,
        user_id: root.types.UserId,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    system_token_middleware_task: ?root.middleware.system_token.SystemTokenMiddleware.Lazy = null,
    content: ?Content = null,
    db: ?*root.db.Connection = null,
    role_id: ?root.types.RoleId = null,
    create_superuser_role_task: ?root.repo.roles.CreateSuperuser.Lazy = null,
    body: ?[]const u8 = null,
    streamer: ?root.http.Response.Streamer = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *PostTask = @ptrCast(@alignCast(ctx));

        // R2
        // await this.system_token_middleware_task
        {
            if (this.system_token_middleware_task == null) {
                this.system_token_middleware_task = .from(.init(
                    this.request,
                    this.response,
                ));
            }

            while (this.system_token_middleware_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.system_token_middleware_task.?.result) {
                // response handled in the middleware
                return .ready;
            }
        }

        if (this.content == null) {
            if (!this.request.contentIsAvailable()) {
                return .{ .pending = .want_read };
            }

            const body = std.json.parseFromSliceLeaky(std.json.Value, this.response.allocator, this.request.getContent(), .{}) catch {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad JSON");

                return .ready;
            };

            if (body != .object) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Expected an object");

                return .ready;
            }

            // R3
            const guild_id_value = body.object.get("guild_id") orelse {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'guild_id' is missing");

                return .ready;
            };

            if (guild_id_value != .string) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'guild_id' is not a string");

                return .ready;
            }

            const guild_id = std.fmt.parseInt(root.types.GuildId, guild_id_value.string, 10) catch {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad 'guild_id'");

                return .ready;
            };

            // R4
            const user_id_value = body.object.get("user_id") orelse {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'user_id' is missing");

                return .ready;
            };

            if (user_id_value != .string) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'user_id' is not a string");

                return .ready;
            }

            const user_id = std.fmt.parseInt(root.types.UserId, user_id_value.string, 10) catch {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad 'user_id'");

                return .ready;
            };

            this.content = .{
                .guild_id = guild_id,
                .user_id = user_id,
            };
        }

        if (this.db == null) {
            this.db = root.db_pool.rent();

            if (this.db == null) {
                return .{ .pending = .db };
            }
        }

        const db = this.db.?;

        if (this.role_id == null) {
            this.role_id = root.sf_generator.generate();
        }

        // R5
        // await this.create_superuser_role_task
        {
            if (this.create_superuser_role_task == null) {
                this.create_superuser_role_task = .from(.init(db, .{
                    .guild_id = this.content.?.guild_id,
                    .user_id = this.content.?.user_id,
                    .role_id = this.role_id.?,
                }));
            }

            while (!this.create_superuser_role_task.?.done) {
                if (this.create_superuser_role_task.?.await()) |res| {
                    return res.discard();
                }

                if (this.create_superuser_role_task.?.result != null) {
                    root.bus.raise(.{
                        .role_created = .{
                            .id = this.create_superuser_role_task.?.result.?.role_id,
                            .guild_id = this.content.?.guild_id,
                        },
                    });
                }
            }

            // R5
            if (this.create_superuser_role_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Guild or user not found");
            }
        }

        if (this.body == null) {
            var writer: std.Io.Writer.Allocating = .init(this.response.allocator);

            const item: Response = .{
                .id = std.fmt.allocPrint(this.response.allocator, "{}", .{this.create_superuser_role_task.?.result.?.role_id}) catch |err| {
                    SCOPE.err("POST failed to stringify 'id': {t}", .{err});

                    return .{ .err = err };
                },
            };

            std.json.fmt(item, .{}).format(&writer.writer) catch |err| {
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

        if (this.system_token_middleware_task) |*t| {
            t.dispose();
            this.system_token_middleware_task = null;
        }

        if (this.create_superuser_role_task) |*t| {
            t.dispose();
            this.create_superuser_role_task = null;
        }

        if (this.db) |db| {
            db.release();
            this.db = null;
        }
    }

    pub inline fn task(request: *const root.http.Request, response: *root.http.Response) !Task {
        const this = try response.allocator.create(PostTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .request = request,
            .response = response,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// POST /api/system/superuser
/// R1 - content type must be application/json (415) and body non-empty (400)
pub inline fn postHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
) !root.http.Task {
    _ = allocator;

    // R1
    if (request.getContentLength() == 0) {
        return try root.route.generic.badRequestTask(response);
    }

    // R1
    if (!root.utils.startsWithMaybe(u8, request.content_type, "application/json")) {
        return try root.route.generic.unsupportedMediaTypeTask(response);
    }

    return try PostTask.task(request, response);
}
