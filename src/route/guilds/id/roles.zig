// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../../root.zig");

pub const order = @import("roles/order.zig");

const SCOPE = std.log.scoped(.@"/api/guilds/{guild_id}/roles");

/// R1 - user must be logged
const GetTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        guild_id: root.types.GuildId,
    };

    pub const ResponseItem = struct {
        id: []const u8,
        name: []const u8,
        position: root.types.Position,
        permissions: []const u8,
        color: ?root.types.Color,
        mentionable: bool,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    guild_exists_task: ?root.repo.guilds.Exists.Lazy = null,
    get_guild_roles_stream: ?root.repo.guilds.GetRoles.Lazy = null,
    get_guild_roles_stream_result: std.ArrayList(ResponseItem) = .empty,
    body: ?[]const u8 = null,
    streamer: ?root.http.Response.Streamer = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *GetTask = @ptrCast(@alignCast(ctx));

        if (this.db == null) {
            this.db = root.db_pool.rent() orelse {
                return .{ .pending = .db };
            };
        }

        // await this.bearer_middleware_task
        // R1
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

        {
            if (this.get_guild_roles_stream == null) {
                this.get_guild_roles_stream = .from(.init(this.db.?, .{
                    .guild_id = this.payload.guild_id,
                }));
            }

            while (this.get_guild_roles_stream.?.await()) |res| {
                switch (res) {
                    .next => |n| {
                        this.get_guild_roles_stream_result.append(this.response.allocator, .{
                            .id = std.fmt.allocPrint(this.response.allocator, "{}", .{n.id}) catch |err| {
                                SCOPE.err("GET failed to stringify 'id': {t}", .{err});

                                return .{ .err = err };
                            },
                            .name = this.response.allocator.dupe(u8, n.name) catch |err| {
                                SCOPE.err("GET failed to dupe 'name': {t}", .{err});

                                return .{ .err = err };
                            },
                            .position = n.position,
                            .permissions = std.fmt.allocPrint(this.response.allocator, "{}", .{@as(root.types.Permissions.Int, @bitCast(n.permissions))}) catch |err| {
                                SCOPE.err("GET failed to stringify 'permissions': {t}", .{err});

                                return .{ .err = err };
                            },
                            .color = n.color,
                            .mentionable = n.mentionable,
                        }) catch |err| {
                            SCOPE.err("GET failed to append a result item: {t}", .{err});

                            return .{ .err = err };
                        };
                    },
                    .poll => |p| return p.discard(),
                }
            }
        }

        if (this.body == null) {
            var writer: std.Io.Writer.Allocating = .init(this.response.allocator);

            std.json.fmt(this.get_guild_roles_stream_result.items, .{}).format(&writer.writer) catch |err| {
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

        if (this.get_guild_roles_stream) |*s| {
            s.dispose();
            this.get_guild_roles_stream = null;
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
    ) !GetTask.Task {
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

/// GET /api/guilds/{guild_id}/roles
/// R1 - user must be logged (see the R-list above GetTask)
pub inline fn getHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    guild_id: root.types.GuildId,
) !GetTask.Task {
    _ = allocator;

    return try GetTask.task(request, response, .{
        .guild_id = guild_id,
    });
}

/// R2 - user must be logged
/// R3 - the guild exists
/// R4 - body must be valid JSON and an object
/// R5 - "name" must be present, a string, not too long and contain no forbidden codepoints (400 "'name' is missing" / "'name' is not a string" / "'name' is too long" / "'name' is invalid")
/// R6 - "permissions" must be present, a string parseable as a 128-bit decimal mask with no reserved bits
/// R7 - optional "color" must be an integer in [0, 16777215] (or null)
/// R8 - optional "mentionable" must be a boolean (or null → default true)
/// R9 - user must have create_roles and may only grant permissions one already has: required = requested ∪ {create_roles}, base ⊇ required
/// R10 - role hierarchy: the caller must have at least one non-@everyone role (highest position >= 1); the new role is inserted at the bottom
const PostTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        guild_id: root.types.GuildId,
    };

    pub const Response = struct {
        id: []const u8,
    };

    const Content = struct {
        name: []const u8,
        permissions: root.types.Permissions,
        color: ?root.types.Color,
        mentionable: bool,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    content: ?Content = null,
    role_id: ?root.types.RoleId = null,
    db: ?*root.db.Connection = null,
    guild_exists_task: ?root.repo.guilds.Exists.Lazy = null,
    check_user_guild_rights_task: ?root.repo.rights.CheckUserGuildRights.Lazy = null,
    highest_position_task: ?root.repo.users.GetHighestRolePosition.Lazy = null,
    create_guild_role_task: ?root.repo.roles.Create.Lazy = null,
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

        // R4, R5, R6, R7, R8
        if (this.content == null) {
            if (!this.request.contentIsAvailable()) {
                return .{ .pending = .want_read };
            }

            // R4
            const root_value = std.json.parseFromSliceLeaky(std.json.Value, this.response.allocator, this.request.getContent(), .{}) catch {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad JSON");

                return .ready;
            };

            // R4
            if (root_value != .object) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Expected an object");

                return .ready;
            }

            // R5
            const name_value = root_value.object.get("name") orelse {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is missing");

                return .ready;
            };

            // R5
            if (name_value != .string) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is not a string");

                return .ready;
            }

            // R5
            const name = root.unicode.normalize(this.response.allocator, name_value.string) catch |err| switch (err) {
                error.InvalidUtf8 => return root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is invalid"),
                error.OutOfMemory => return .{ .err = error.OutOfMemory },
            };

            if (std.unicode.utf8CountCodepoints(name) catch unreachable > root.options.api.roles.max_name_codepoints) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is too long");

                return .ready;
            }

            // R5
            if ((root.unicode.findForbiddenCodepoint(.name, name) catch null) != null) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is invalid");

                return .ready;
            }

            // R6
            const permissions_value = root_value.object.get("permissions") orelse {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'permissions' is missing");

                return .ready;
            };

            // R6
            if (permissions_value != .string) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'permissions' is not a string");

                return .ready;
            }

            // R6
            const permissions = root.utils.parsePackedStruct(root.types.Permissions, permissions_value.string, 10) catch {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad 'permissions'");

                return .ready;
            };

            // R6
            if (permissions._reserved != 0) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad 'permissions'");

                return .ready;
            }

            var color: ?root.types.Color = null;

            if (root_value.object.get("color")) |color_value| {
                if (color_value != .null) {
                    // R7
                    if (color_value != .integer) {
                        _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'color' is not an integer");

                        return .ready;
                    }

                    // R7
                    if (color_value.integer < 0 or color_value.integer > std.math.maxInt(root.types.Color)) {
                        _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad 'color'");

                        return .ready;
                    }

                    color = @intCast(color_value.integer);
                }
            }

            // R8
            var mentionable: bool = true;

            if (root_value.object.get("mentionable")) |mentionable_value| {
                if (mentionable_value != .null) {
                    if (mentionable_value != .bool) {
                        _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'mentionable' is not a boolean");

                        return .ready;
                    }

                    mentionable = mentionable_value.bool;
                }
            }

            this.content = .{
                .name = name,
                .permissions = permissions,
                .color = color,
                .mentionable = mentionable,
            };
        }

        if (this.role_id == null) {
            this.role_id = root.sf_generator.generate();
        }

        if (this.db == null) {
            this.db = root.db_pool.rent();

            if (this.db == null) {
                return .{ .pending = .db };
            }
        }

        // R9
        // await this.check_user_guild_rights_task
        {
            if (this.check_user_guild_rights_task == null) {
                this.check_user_guild_rights_task = .from(.init(this.db.?, .{
                    .guild_id = this.payload.guild_id,
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .required = this.content.?.permissions.combineOr(.{ .create_roles = true }),
                }));
            }

            while (this.check_user_guild_rights_task.?.await()) |res| {
                return res.discard();
            }

            // R9
            if (!this.check_user_guild_rights_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
            }
        }

        // R10
        // await this.highest_position_task
        {
            if (this.highest_position_task == null) {
                this.highest_position_task = .from(.init(this.db.?, .{
                    .guild_id = this.payload.guild_id,
                    .user_id = this.bearer_middleware_task.?.result.?,
                }));
            }

            while (this.highest_position_task.?.await()) |res| {
                return res.discard();
            }

            // R10 - the caller must sit above @everyone (highest >= 1) so a
            // role-less caller cannot create a role at all.
            if (this.highest_position_task.?.result < 1) {
                return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
            }
        }

        // await this.create_guild_role_task
        {
            if (this.create_guild_role_task == null) {
                this.create_guild_role_task = .from(.init(this.db.?, .{
                    .guild_id = this.payload.guild_id,
                    .role_id = this.role_id.?,
                    .name = this.content.?.name,
                    .permissions = this.content.?.permissions,
                    .color = this.content.?.color,
                    .mentionable = this.content.?.mentionable,
                }));
            }

            while (!this.create_guild_role_task.?.done) {
                if (this.create_guild_role_task.?.await()) |res| {
                    return res.discard();
                }

                if (this.create_guild_role_task.?.result) {
                    root.bus.raise(.{
                        .role_created = .{
                            .id = this.role_id.?,
                            .guild_id = this.payload.guild_id,
                        },
                    });
                }
            }
        }

        // await this.audit_log
        {
            if (this.audit_log == null) {
                this.audit_entries[0] = .{
                    .action = .role_create,
                    .target_id = this.role_id.?,
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

            const item: Response = .{
                .id = std.fmt.allocPrint(this.response.allocator, "{}", .{this.role_id.?}) catch |err| {
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

        if (this.highest_position_task) |*t| {
            t.dispose();
            this.highest_position_task = null;
        }

        if (this.create_guild_role_task) |*t| {
            t.dispose();
            this.create_guild_role_task = null;
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
        errdefer this.response.allocator.destroy(this);

        this.* = .{
            .request = request,
            .response = response,
            .payload = payload,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// POST /api/guilds/{guild_id}/roles
/// R1 - content type must be application/json (415) and body non-empty (400) (see the R-list above PostTask)
pub inline fn postHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    guild_id: root.types.GuildId,
) !PostTask.Task {
    _ = allocator;

    // R1
    if (request.getContentLength() == 0) {
        return try root.route.generic.badRequestTask(response);
    }

    // R1
    if (!root.utils.startsWithMaybe(u8, request.content_type, "application/json")) {
        return try root.route.generic.unsupportedMediaTypeTask(response);
    }

    return try PostTask.task(request, response, .{
        .guild_id = guild_id,
    });
}
