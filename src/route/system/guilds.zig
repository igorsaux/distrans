// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../root.zig");
pub const roles = @import("guilds/role.zig");

const SCOPE = std.log.scoped(.@"/api/system/guilds");

/// R2 - request must carry a valid system token
/// R3 - "name" must be present, a string, not too long and must not contain
///      forbidden codepoints
/// R4 - optional "id" must be a string parseable as a guild id
/// R5 - the guild must not already exist (id in use)
const PostTask = struct {
    const Task = root.http.Task;

    pub const Response = struct {
        id: []const u8,
    };

    const Content = struct {
        id: ?root.types.GuildId,
        name: []const u8,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    system_token_middleware_task: ?root.middleware.system_token.SystemTokenMiddleware.Lazy = null,
    content: ?Content = null,
    db: ?*root.db.Connection = null,
    guild_id: ?root.types.GuildId = null,
    create_guild_task: ?root.repo.guilds.Create.Lazy = null,
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
            const name_value = body.object.get("name") orelse {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is missing");

                return .ready;
            };

            if (name_value != .string) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is not a string");

                return .ready;
            }

            // R3
            const name = root.unicode.normalize(this.response.allocator, name_value.string) catch |err| switch (err) {
                error.InvalidUtf8 => return root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is invalid"),
                error.OutOfMemory => return .{ .err = error.OutOfMemory },
            };

            if (std.unicode.utf8CountCodepoints(name) catch unreachable >
                root.options.api.guilds.max_name_codepoints)
            {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is too long");

                return .ready;
            }

            // R3
            if ((root.unicode.findForbiddenCodepoint(.name, name) catch null) != null) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is invalid");

                return .ready;
            }

            // R4
            const id_value = body.object.get("id");

            // R4
            if (id_value != null and id_value.? != .string) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'id' is not a string");

                return .ready;
            }

            // R4
            const id = if (id_value == null)
                null
            else
                std.fmt.parseInt(root.types.GuildId, id_value.?.string, 10) catch {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad 'id'");

                    return .ready;
                };

            this.content = .{
                .id = id,
                .name = name,
            };
        }

        if (this.db == null) {
            this.db = root.db_pool.rent() orelse {
                return .{ .pending = .db };
            };
        }

        const db = this.db.?;

        if (this.guild_id == null) {
            if (this.content.?.id) |id| {
                this.guild_id = id;
            } else {
                this.guild_id = root.sf_generator.generate();
            }
        }

        // await this.create_guild_task
        {
            if (this.create_guild_task == null) {
                this.create_guild_task = .from(.init(db, .{
                    .id = this.guild_id.?,
                    .name = this.content.?.name,
                }));
            }

            while (!this.create_guild_task.?.done) {
                if (this.create_guild_task.?.await()) |res| {
                    return res.discard();
                }

                if (this.create_guild_task.?.result != null) {
                    root.bus.raise(.{
                        .guild_created = .{
                            .id = this.guild_id.?,
                        },
                    });
                }
            }

            // R5
            if (this.create_guild_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .conflict, "Guild id is already used");
            }
        }

        if (this.body == null) {
            var writer: std.Io.Writer.Allocating = .init(this.response.allocator);

            const item: Response = .{
                .id = std.fmt.allocPrint(this.response.allocator, "{}", .{this.guild_id.?}) catch |err| {
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

        if (this.create_guild_task) |*t| {
            t.dispose();
            this.create_guild_task = null;
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

/// POST /api/system/guilds
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

/// R1 - request must carry a valid system token
/// R2 - the guild must exist
const DeleteTask = struct {
    const Task = root.http.Task;

    pub const Payload = struct {
        guild_id: root.types.GuildId,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    system_token_middleware_task: ?root.middleware.system_token.SystemTokenMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    delete_guild_task: ?root.repo.guilds.Delete.Lazy = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *DeleteTask = @ptrCast(@alignCast(ctx));

        // R1
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

        if (this.db == null) {
            this.db = root.db_pool.rent() orelse {
                return .{ .pending = .db };
            };
        }

        const db = this.db.?;

        // R2
        // await this.delete_guild_task
        {
            if (this.delete_guild_task == null) {
                this.delete_guild_task = .from(.init(db, .{
                    .id = this.payload.guild_id,
                }));
            }

            while (!this.delete_guild_task.?.done) {
                if (this.delete_guild_task.?.await()) |res| {
                    return res.discard();
                }

                if (this.delete_guild_task.?.result) {
                    root.bus.raise(.{
                        .guild_deleted = .{
                            .id = this.payload.guild_id,
                        },
                    });
                }
            }

            if (!this.delete_guild_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Guild not found");
            }
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

        if (this.system_token_middleware_task) |*t| {
            t.dispose();
            this.system_token_middleware_task = null;
        }

        if (this.delete_guild_task) |*t| {
            t.dispose();
            this.delete_guild_task = null;
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
        const this = try response.allocator.create(DeleteTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .request = request,
            .response = response,
            .payload = payload,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// DELETE /api/system/guilds/{guild_id}
/// R1 - request must carry a valid system token (see the R-list above DeleteTask)
pub inline fn deleteHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    guild_id: root.types.GuildId,
) !root.http.Task {
    _ = allocator;

    return try DeleteTask.task(request, response, .{
        .guild_id = guild_id,
    });
}
