// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../root.zig");
pub const users = @import("id/users.zig");

const SCOPE = std.log.scoped(.@"/api/roles/{role_id}");

/// R1 - user must be logged
/// R2 - the role exists (404 "Role not found")
const GetTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        role_id: root.types.RoleId,
    };

    pub const Response = struct {
        guild_id: []const u8,
        name: []const u8,
        position: root.types.Position,
        permissions: []const u8,
        color: ?root.types.Color,
        mentionable: bool,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_token_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    get_role_task: ?root.repo.roles.Get.Lazy = null,
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
        // await this.bearer_middleware_token_task
        {
            if (this.bearer_middleware_token_task == null) {
                this.bearer_middleware_token_task = .from(.init(this.request, this.response, this.db.?));
            }

            while (this.bearer_middleware_token_task.?.await()) |res| {
                return res.discard();
            }

            if (this.bearer_middleware_token_task.?.result == null) {
                // response handled in the middleware
                return .ready;
            }
        }

        // R2
        // await this.get_role_task
        {
            if (this.get_role_task == null) {
                this.get_role_task = .from(.init(this.response.allocator, this.db.?, .{
                    .role_id = this.payload.role_id,
                }));
            }

            while (this.get_role_task.?.await()) |res| {
                return res.discard();
            }

            if (this.get_role_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Role not found");
            }
        }

        if (this.body == null) {
            var writer: std.Io.Writer.Allocating = .init(this.response.allocator);

            const item: Response = .{
                .guild_id = std.fmt.allocPrint(this.response.allocator, "{}", .{this.get_role_task.?.result.?.guild_id}) catch |err| {
                    SCOPE.err("GET failed to stringify 'guild_id': {t}", .{err});

                    return .{ .err = err };
                },
                .name = this.get_role_task.?.result.?.name,
                .position = this.get_role_task.?.result.?.position,
                .permissions = std.fmt.allocPrint(
                    this.response.allocator,
                    "{}",
                    .{@as(root.types.Permissions.Int, @bitCast(this.get_role_task.?.result.?.permissions))},
                ) catch |err| {
                    SCOPE.err("GET failed to stringify 'permissions': {t}", .{err});

                    return .{ .err = err };
                },
                .color = this.get_role_task.?.result.?.color,
                .mentionable = this.get_role_task.?.result.?.mentionable,
            };

            std.json.fmt(item, .{}).format(&writer.writer) catch |err| {
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

        if (this.bearer_middleware_token_task) |*t| {
            t.dispose();
            this.bearer_middleware_token_task = null;
        }

        if (this.get_role_task) |*t| {
            t.dispose();
            this.get_role_task = null;
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

/// GET /api/roles/{role_id}
/// R1 - user must be logged (see the R-list above GetTask)
pub inline fn getHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    role_id: root.types.RoleId,
) !GetTask.Task {
    _ = allocator;

    return try GetTask.task(request, response, .{
        .role_id = role_id,
    });
}

/// R2  - user must be logged
/// R3  - the role exists (404 "Role not found")
/// R4  - body must be valid JSON and an object
/// R5  - at least one of "name"/"permissions"/"color"/"mentionable" present ("Nothing to update"; "color": null counts as present)
/// R6  - @everyone role (role_id == fetched guild_id): only "permissions" may be changed (400 "Only 'permissions' can be changed on the @everyone role")
/// R7  - optional "name": string, ≤ api.roles.max_name_codepoints, no forbidden codepoints (400 "'name' is not a string" / "'name' is too long" / "'name' is invalid"); explicit null → 400 "'name' is not a string"
/// R8  - optional "permissions": string, parseable 128-bit decimal mask, no reserved bits (400 "Bad 'permissions'"); explicit null → 400 "'permissions' is not a string"
/// R9  - optional "color": integer in [0, 16777215]; explicit null clears the color
/// R10 - optional "mentionable": boolean (400 "'mentionable' is not a boolean"); absent = unchanged
/// R11 - rights: required = modify_roles ∪ (new permissions when present); 403 "Missing permissions" (subset rule included)
/// R12 - role hierarchy: role's current position must be strictly < user's highest role position; 403 "Missing permissions"
const PatchTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        role_id: root.types.RoleId,
    };

    pub const Content = struct {
        name: ?[]const u8 = null,
        permissions: ?root.types.Permissions = null,
        color: ?root.types.Color = null,
        color_set: bool = false,
        mentionable: bool = true,
        mentionable_set: bool = false,
        any_set: bool = false,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_token_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    content: ?Content = null,
    db: ?*root.db.Connection = null,
    check_user_guild_rights_task: ?root.repo.rights.CheckUserGuildRights.Lazy = null,
    get_role_task: ?root.repo.roles.Get.Lazy = null,
    highest_position_task: ?root.repo.users.GetHighestRolePosition.Lazy = null,
    update_role_task: ?root.repo.roles.Update.Lazy = null,
    audit_log: ?root.repo.audit_log.Insert.Lazy = null,
    audit_entries: [4]root.repo.audit_log.Insert.Entry = undefined,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *PatchTask = @ptrCast(@alignCast(ctx));

        if (this.db == null) {
            this.db = root.db_pool.rent() orelse {
                return .{ .pending = .db };
            };
        }

        // R2
        // await this.bearer_middleware_token_task
        {
            if (this.bearer_middleware_token_task == null) {
                this.bearer_middleware_token_task = .from(.init(this.request, this.response, this.db.?));
            }

            while (this.bearer_middleware_token_task.?.await()) |res| {
                return res.discard();
            }

            if (this.bearer_middleware_token_task.?.result == null) {
                // response handled in the middleware
                return .ready;
            }
        }

        // R3
        // await this.get_role_task
        {
            if (this.get_role_task == null) {
                this.get_role_task = .from(.init(this.response.allocator, this.db.?, .{
                    .role_id = this.payload.role_id,
                }));
            }

            while (this.get_role_task.?.await()) |res| {
                return res.discard();
            }

            if (this.get_role_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Role not found");
            }
        }

        // R4, R5, R6, R7, R8, R9, R10
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

            var content: Content = .{};

            // R7
            if (root_value.object.get("name")) |name_value| {
                if (name_value != .string) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is not a string");

                    return .ready;
                }

                const name = root.unicode.normalize(this.response.allocator, name_value.string) catch |err| switch (err) {
                    error.InvalidUtf8 => return root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is invalid"),
                    error.OutOfMemory => return .{ .err = error.OutOfMemory },
                };

                if (std.unicode.utf8CountCodepoints(name) catch unreachable > root.options.api.roles.max_name_codepoints) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is too long");

                    return .ready;
                }

                // R7
                if ((root.unicode.findForbiddenCodepoint(.name, name) catch null) != null) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is invalid");

                    return .ready;
                }

                content.name = name;
                content.any_set = true;
            }

            // R8
            if (root_value.object.get("permissions")) |permissions_value| {
                if (permissions_value != .string) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'permissions' is not a string");

                    return .ready;
                }

                const permissions = root.utils.parsePackedStruct(root.types.Permissions, permissions_value.string, 10) catch {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad 'permissions'");

                    return .ready;
                };

                if (permissions._reserved != 0) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad 'permissions'");

                    return .ready;
                }

                content.permissions = permissions;
                content.any_set = true;
            }

            // R9
            if (root_value.object.get("color")) |color_value| {
                if (color_value == .null) {
                    content.color = null;
                    content.color_set = true;
                    content.any_set = true;
                } else {
                    if (color_value != .integer) {
                        _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'color' is not an integer");

                        return .ready;
                    }

                    if (color_value.integer < 0 or color_value.integer > std.math.maxInt(root.types.Color)) {
                        _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad 'color'");

                        return .ready;
                    }

                    content.color = @intCast(color_value.integer);
                    content.color_set = true;
                    content.any_set = true;
                }
            }

            // R10
            if (root_value.object.get("mentionable")) |mentionable_value| {
                if (mentionable_value != .bool) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'mentionable' is not a boolean");

                    return .ready;
                }

                content.mentionable = mentionable_value.bool;
                content.mentionable_set = true;
                content.any_set = true;
            }

            // R5
            if (!content.any_set) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Nothing to update");

                return .ready;
            }

            // R6
            if (this.get_role_task.?.result.?.guild_id == this.payload.role_id) {
                if (content.name != null or content.color_set or content.mentionable_set) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Only 'permissions' can be changed on the @everyone role");

                    return .ready;
                }
            }

            this.content = content;
        }

        // R11
        // await this.check_user_guild_rights_task
        {
            if (this.check_user_guild_rights_task == null) {
                const required: root.types.Permissions = if (this.content.?.permissions) |permissions|
                    permissions.combineOr(.{ .modify_roles = true })
                else
                    .{ .modify_roles = true };

                this.check_user_guild_rights_task = .from(.init(this.db.?, .{
                    .guild_id = this.get_role_task.?.result.?.guild_id,
                    .user_id = this.bearer_middleware_token_task.?.result.?,
                    .required = required,
                }));
            }

            while (this.check_user_guild_rights_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.check_user_guild_rights_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
            }
        }

        // R12
        // await this.highest_position_task
        {
            if (this.highest_position_task == null) {
                this.highest_position_task = .from(.init(this.db.?, .{
                    .guild_id = this.get_role_task.?.result.?.guild_id,
                    .user_id = this.bearer_middleware_token_task.?.result.?,
                }));
            }

            while (this.highest_position_task.?.await()) |ret| {
                return ret.discard();
            }

            const highest = this.highest_position_task.?.result;

            if (this.get_role_task.?.result.?.position >= highest) {
                return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
            }
        }

        // await this.update_role_task
        {
            if (this.update_role_task == null) {
                this.update_role_task = .from(.init(this.db.?, .{
                    .role_id = this.payload.role_id,
                    .name = this.content.?.name,
                    .permissions = this.content.?.permissions,
                    .color_mode = if (this.content.?.color_set) .set else .keep,
                    .color = this.content.?.color,
                    .mentionable_mode = if (this.content.?.mentionable_set) .set else .keep,
                    .mentionable = this.content.?.mentionable,
                }));
            }

            while (!this.update_role_task.?.done) {
                if (this.update_role_task.?.await()) |res| {
                    return res.discard();
                }

                if (this.update_role_task.?.result) {
                    root.bus.raise(.{
                        .role_updated = .{
                            .id = this.payload.role_id,
                            .guild_id = this.get_role_task.?.result.?.guild_id,
                        },
                    });
                }
            }

            // R3 (raced with deletion)
            if (!this.update_role_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Role not found");
            }
        }

        // await this.audit_log
        {
            if (this.audit_log == null) {
                var len: usize = 0;

                if (this.content.?.name != null) {
                    this.audit_entries[len] = .{
                        .action = .role_name_update,
                        .target_id = this.payload.role_id,
                    };
                    len += 1;
                }

                if (this.content.?.permissions != null) {
                    this.audit_entries[len] = .{
                        .action = .role_permissions_update,
                        .target_id = this.payload.role_id,
                    };
                    len += 1;
                }

                if (this.content.?.color_set) {
                    this.audit_entries[len] = .{
                        .action = .role_color_update,
                        .target_id = this.payload.role_id,
                    };
                    len += 1;
                }

                if (this.content.?.mentionable_set) {
                    this.audit_entries[len] = .{
                        .action = .role_mentionable_update,
                        .target_id = this.payload.role_id,
                    };
                    len += 1;
                }

                this.audit_log = .from(root.repo.audit_log.Insert.init(this.db.?, this.response.allocator, .{
                    .guild_id = this.get_role_task.?.result.?.guild_id,
                    .actor_id = this.bearer_middleware_token_task.?.result.?,
                    .entries = this.audit_entries[0..len],
                }));
            }

            while (this.audit_log.?.await()) |res| {
                return res.discard();
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
        const this: *PatchTask = @ptrCast(@alignCast(ctx));

        if (this.bearer_middleware_token_task) |*t| {
            t.dispose();
            this.bearer_middleware_token_task = null;
        }

        if (this.check_user_guild_rights_task) |*t| {
            t.dispose();
            this.check_user_guild_rights_task = null;
        }

        if (this.get_role_task) |*t| {
            t.dispose();
            this.get_role_task = null;
        }

        if (this.highest_position_task) |*t| {
            t.dispose();
            this.highest_position_task = null;
        }

        if (this.update_role_task) |*t| {
            t.dispose();
            this.update_role_task = null;
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
        const this = try response.allocator.create(PatchTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .request = request,
            .response = response,
            .payload = payload,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// PATCH /api/roles/{role_id}
/// R1 - content type must be application/json (415) and body non-empty (400) (see the R-list above PatchTask)
pub inline fn patchHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    role_id: root.types.RoleId,
) !PatchTask.Task {
    _ = allocator;

    // R1
    if (request.getContentLength() == 0) {
        return try root.route.generic.badRequestTask(response);
    }

    // R1
    if (!root.utils.startsWithMaybe(u8, request.content_type, "application/json")) {
        return try root.route.generic.unsupportedMediaTypeTask(response);
    }

    return try PatchTask.task(request, response, .{
        .role_id = role_id,
    });
}

/// R1 - user must be logged
/// R2 - the role exists (404 "Role not found")
/// R3 - cannot delete the @everyone role (403 "Cannot delete the @everyone role")
/// R4 - user must have delete_roles (403 "Missing permissions")
/// R5 - role hierarchy: role position strictly < user's highest role position (403 "Missing permissions")
const DeleteTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        role_id: root.types.RoleId,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_token_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    check_user_guild_rights_task: ?root.repo.rights.CheckUserGuildRights.Lazy = null,
    get_role_task: ?root.repo.roles.Get.Lazy = null,
    highest_position_task: ?root.repo.users.GetHighestRolePosition.Lazy = null,
    delete_role_task: ?root.repo.roles.Delete.Lazy = null,
    audit_log: ?root.repo.audit_log.Insert.Lazy = null,
    audit_entries: [1]root.repo.audit_log.Insert.Entry = undefined,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *DeleteTask = @ptrCast(@alignCast(ctx));

        if (this.db == null) {
            this.db = root.db_pool.rent() orelse {
                return .{ .pending = .db };
            };
        }

        // R1
        // await this.bearer_middleware_token_task
        {
            if (this.bearer_middleware_token_task == null) {
                this.bearer_middleware_token_task = .from(.init(this.request, this.response, this.db.?));
            }

            while (this.bearer_middleware_token_task.?.await()) |res| {
                return res.discard();
            }

            if (this.bearer_middleware_token_task.?.result == null) {
                // response handled in the middleware
                return .ready;
            }
        }

        // R2
        // await this.get_role_task
        {
            if (this.get_role_task == null) {
                this.get_role_task = .from(.init(this.response.allocator, this.db.?, .{
                    .role_id = this.payload.role_id,
                }));
            }

            while (this.get_role_task.?.await()) |res| {
                return res.discard();
            }

            if (this.get_role_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Role not found");
            }
        }

        // R3
        if (this.get_role_task.?.result.?.guild_id == this.payload.role_id) {
            return root.route.generic.responseErrorMessage(this.response, .forbidden, "Cannot delete the @everyone role");
        }

        // R4
        // await this.check_user_guild_rights_task
        {
            if (this.check_user_guild_rights_task == null) {
                this.check_user_guild_rights_task = .from(.init(this.db.?, .{
                    .guild_id = this.get_role_task.?.result.?.guild_id,
                    .user_id = this.bearer_middleware_token_task.?.result.?,
                    .required = .{ .delete_roles = true },
                }));
            }

            while (this.check_user_guild_rights_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.check_user_guild_rights_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
            }
        }

        // R5
        // await this.highest_position_task
        {
            if (this.highest_position_task == null) {
                this.highest_position_task = .from(.init(this.db.?, .{
                    .guild_id = this.get_role_task.?.result.?.guild_id,
                    .user_id = this.bearer_middleware_token_task.?.result.?,
                }));
            }

            while (this.highest_position_task.?.await()) |res| {
                return res.discard();
            }

            if (this.get_role_task.?.result.?.position >= this.highest_position_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
            }
        }

        // await this.delete_role_task
        {
            if (this.delete_role_task == null) {
                this.delete_role_task = .from(.init(this.db.?, .{
                    .role_id = this.payload.role_id,
                    .guild_id = this.get_role_task.?.result.?.guild_id,
                }));
            }

            while (!this.delete_role_task.?.done) {
                if (this.delete_role_task.?.await()) |res| {
                    return res.discard();
                }

                if (this.delete_role_task.?.result != null) {
                    root.bus.raise(.{
                        .role_deleted = .{
                            .id = this.payload.role_id,
                            .guild_id = this.get_role_task.?.result.?.guild_id,
                        },
                    });
                }
            }

            // R2 (raced with deletion)
            if (this.delete_role_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Role not found");
            }
        }

        // await this.audit_log
        {
            if (this.audit_log == null) {
                this.audit_entries[0] = .{
                    .action = .role_delete,
                    .target_id = this.payload.role_id,
                };

                this.audit_log = .from(root.repo.audit_log.Insert.init(this.db.?, this.response.allocator, .{
                    .guild_id = this.get_role_task.?.result.?.guild_id,
                    .actor_id = this.bearer_middleware_token_task.?.result.?,
                    .entries = this.audit_entries[0..1],
                }));
            }

            while (this.audit_log.?.await()) |res| {
                return res.discard();
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

        if (this.bearer_middleware_token_task) |*t| {
            t.dispose();
            this.bearer_middleware_token_task = null;
        }

        if (this.check_user_guild_rights_task) |*t| {
            t.dispose();
            this.check_user_guild_rights_task = null;
        }

        if (this.get_role_task) |*t| {
            t.dispose();
            this.get_role_task = null;
        }

        if (this.highest_position_task) |*t| {
            t.dispose();
            this.highest_position_task = null;
        }

        if (this.delete_role_task) |*t| {
            t.dispose();
            this.delete_role_task = null;
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

/// DELETE /api/roles/{role_id}
/// R1 - user must be logged (see the R-list above DeleteTask)
pub inline fn deleteHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    role_id: root.types.RoleId,
) !DeleteTask.Task {
    _ = allocator;

    return try DeleteTask.task(request, response, .{
        .role_id = role_id,
    });
}
