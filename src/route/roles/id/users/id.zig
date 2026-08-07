// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../../../root.zig");

const SCOPE = std.log.scoped(.@"/api/roles/{role_id}/users/{user_id}");

/// R1 - user must be logged (401, bearer middleware)
/// R2 - the role exists (404 "Role not found")
/// R3 - the target user exists and is not soft-deleted (404 "User not found")
/// R4 - the role is not @everyone (400 "Cannot grant the @everyone role")
/// R5 - user must have grant_roles (403 "Missing permissions")
/// R6 - role hierarchy (403 "Missing permissions"): the role's position must
///      be strictly below the caller's highest role position, and the caller's
///      highest position must be strictly above the target's highest position
/// R7 - idempotency: granting a role the member already has is a no-op
/// R8 - success: the role is granted, emits `role_granted`
const PutTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        role_id: root.types.RoleId,
        user_id: root.types.UserId,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    get_role_task: ?root.repo.roles.Get.Lazy = null,
    check_user_alive_task: ?root.repo.users.CheckAlive.Lazy = null,
    check_user_guild_rights_task: ?root.repo.rights.CheckUserGuildRights.Lazy = null,
    get_highest_position_task: ?root.repo.users.GetHighestRolePosition.Lazy = null,
    is_higher_than_other_task: ?root.repo.users.IsHigherThanOther.Lazy = null,
    has_role_task: ?root.repo.users.HasRole.Lazy = null,
    add_role_task: ?root.repo.users.AddRole.Lazy = null,
    audit_log: ?root.repo.audit_log.Insert.Lazy = null,
    audit_entries: [1]root.repo.audit_log.Insert.Entry = undefined,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *PutTask = @ptrCast(@alignCast(ctx));

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
        // await this.check_user_alive_task
        {
            if (this.check_user_alive_task == null) {
                this.check_user_alive_task = .from(.init(this.db.?, .{
                    .user_id = this.payload.user_id,
                }));
            }

            while (this.check_user_alive_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.check_user_alive_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "User not found");
            }
        }

        // R4
        if (this.get_role_task.?.result.?.guild_id == this.payload.role_id) {
            return root.route.generic.responseErrorMessage(this.response, .bad_request, "Cannot grant the @everyone role");
        }

        // R5
        // await this.check_user_guild_rights_task
        {
            if (this.check_user_guild_rights_task == null) {
                this.check_user_guild_rights_task = .from(.init(this.db.?, .{
                    .guild_id = this.get_role_task.?.result.?.guild_id,
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .required = .{ .grant_roles = true },
                }));
            }

            while (this.check_user_guild_rights_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.check_user_guild_rights_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
            }
        }

        // R6
        // await this.get_highest_position_task
        {
            if (this.get_highest_position_task == null) {
                this.get_highest_position_task = .from(.init(this.db.?, .{
                    .guild_id = this.get_role_task.?.result.?.guild_id,
                    .user_id = this.bearer_middleware_task.?.result.?,
                }));
            }

            while (this.get_highest_position_task.?.await()) |res| {
                return res.discard();
            }

            // R6
            if (this.get_role_task.?.result.?.position >= this.get_highest_position_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
            }
        }

        // R6
        // await this.is_higher_than_other_task
        {
            if (this.is_higher_than_other_task == null) {
                this.is_higher_than_other_task = .from(.init(this.db.?, .{
                    .guild_id = this.get_role_task.?.result.?.guild_id,
                    .user_a_id = this.bearer_middleware_task.?.result.?,
                    .user_b_id = this.payload.user_id,
                }));
            }

            while (this.is_higher_than_other_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.is_higher_than_other_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
            }
        }

        // R7
        // await this.has_role_task
        {
            if (this.has_role_task == null) {
                this.has_role_task = .from(.init(this.db.?, .{
                    .guild_id = this.get_role_task.?.result.?.guild_id,
                    .role_id = this.payload.role_id,
                    .user_id = this.payload.user_id,
                }));
            }

            while (this.has_role_task.?.await()) |res| {
                return res.discard();
            }

            if (this.has_role_task.?.result) {
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
        }

        // R8
        // await this.add_role_task
        {
            if (this.add_role_task == null) {
                this.add_role_task = .from(.init(this.db.?, .{
                    .guild_id = this.get_role_task.?.result.?.guild_id,
                    .role_id = this.payload.role_id,
                    .user_id = this.payload.user_id,
                }));
            }

            while (!this.add_role_task.?.done) {
                if (this.add_role_task.?.await()) |res| {
                    return res.discard();
                }

                root.bus.raise(.{
                    .role_granted = .{
                        .id = this.payload.role_id,
                        .guild_id = this.get_role_task.?.result.?.guild_id,
                        .user_id = this.payload.user_id,
                    },
                });
            }
        }

        // await this.audit_log
        {
            if (this.audit_log == null) {
                this.audit_entries[0] = .{
                    .action = .role_grant,
                    .target_id = this.payload.role_id,
                    .target_user_id = this.payload.user_id,
                };

                this.audit_log = .from(root.repo.audit_log.Insert.init(this.db.?, this.response.allocator, .{
                    .guild_id = this.get_role_task.?.result.?.guild_id,
                    .actor_id = this.bearer_middleware_task.?.result.?,
                    .entries = this.audit_entries[0..1],
                }));
            }

            while (this.audit_log.?.await()) |res| {
                return res.discard();
            }
        }

        // R8
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
        const this: *PutTask = @ptrCast(@alignCast(ctx));

        if (this.bearer_middleware_task) |*t| {
            t.dispose();
            this.bearer_middleware_task = null;
        }

        if (this.get_role_task) |*t| {
            t.dispose();
            this.get_role_task = null;
        }

        if (this.check_user_alive_task) |*t| {
            t.dispose();
            this.check_user_alive_task = null;
        }

        if (this.check_user_guild_rights_task) |*t| {
            t.dispose();
            this.check_user_guild_rights_task = null;
        }

        if (this.get_highest_position_task) |*t| {
            t.dispose();
            this.get_highest_position_task = null;
        }

        if (this.is_higher_than_other_task) |*t| {
            t.dispose();
            this.is_higher_than_other_task = null;
        }

        if (this.has_role_task) |*t| {
            t.dispose();
            this.has_role_task = null;
        }

        if (this.add_role_task) |*t| {
            t.dispose();
            this.add_role_task = null;
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
        const this = try response.allocator.create(PutTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .request = request,
            .response = response,
            .payload = payload,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// PUT /api/roles/{role_id}/users/{user_id}
/// R1 - user must be logged (see the R-list above PutTask)
pub inline fn putHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    role_id: root.types.RoleId,
    user_id: root.types.UserId,
) !PutTask.Task {
    _ = allocator;

    return try PutTask.task(request, response, .{
        .role_id = role_id,
        .user_id = user_id,
    });
}

/// R1 - user must be logged (401, bearer middleware)
/// R2 - the role exists (404 "Role not found")
/// R3 - the target user exists and is not soft-deleted (404 "User not found")
/// R4 - the role is not @everyone (400 "Cannot revoke the @everyone role")
/// R5 - user must have revoke_roles (403 "Missing permissions")
/// R6 - role hierarchy (403 "Missing permissions"): the role's position must
///      be strictly below the caller's highest role position, and the caller's
///      highest position must be strictly above the target's highest position
/// R7 - idempotency: revoking a role the member does not have is a no-op
/// R8 - success: the role is revoked, emits `role_revoked`
const DeleteTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        role_id: root.types.RoleId,
        user_id: root.types.UserId,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    get_role_task: ?root.repo.roles.Get.Lazy = null,
    check_user_alive_task: ?root.repo.users.CheckAlive.Lazy = null,
    check_user_guild_rights_task: ?root.repo.rights.CheckUserGuildRights.Lazy = null,
    get_highest_position_task: ?root.repo.users.GetHighestRolePosition.Lazy = null,
    is_higher_than_other_task: ?root.repo.users.IsHigherThanOther.Lazy = null,
    has_role_task: ?root.repo.users.HasRole.Lazy = null,
    remove_role_task: ?root.repo.users.RemoveRole.Lazy = null,
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
        // await this.check_user_alive_task
        {
            if (this.check_user_alive_task == null) {
                this.check_user_alive_task = .from(.init(this.db.?, .{
                    .user_id = this.payload.user_id,
                }));
            }

            while (this.check_user_alive_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.check_user_alive_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "User not found");
            }
        }

        // R4
        if (this.get_role_task.?.result.?.guild_id == this.payload.role_id) {
            return root.route.generic.responseErrorMessage(this.response, .bad_request, "Cannot revoke the @everyone role");
        }

        // R5
        // await this.check_user_guild_rights_task
        {
            if (this.check_user_guild_rights_task == null) {
                this.check_user_guild_rights_task = .from(.init(this.db.?, .{
                    .guild_id = this.get_role_task.?.result.?.guild_id,
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .required = .{ .revoke_roles = true },
                }));
            }

            while (this.check_user_guild_rights_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.check_user_guild_rights_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
            }
        }

        // R6
        // await this.get_highest_position_task
        {
            if (this.get_highest_position_task == null) {
                this.get_highest_position_task = .from(.init(this.db.?, .{
                    .guild_id = this.get_role_task.?.result.?.guild_id,
                    .user_id = this.bearer_middleware_task.?.result.?,
                }));
            }

            while (this.get_highest_position_task.?.await()) |res| {
                return res.discard();
            }

            if (this.get_role_task.?.result.?.position >= this.get_highest_position_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
            }
        }

        // R6
        // await this.is_higher_than_other_task
        {
            if (this.is_higher_than_other_task == null) {
                this.is_higher_than_other_task = .from(.init(this.db.?, .{
                    .guild_id = this.get_role_task.?.result.?.guild_id,
                    .user_a_id = this.bearer_middleware_task.?.result.?,
                    .user_b_id = this.payload.user_id,
                }));
            }

            while (this.is_higher_than_other_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.is_higher_than_other_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
            }
        }

        // R7
        // await this.has_role_task
        {
            if (this.has_role_task == null) {
                this.has_role_task = .from(.init(this.db.?, .{
                    .guild_id = this.get_role_task.?.result.?.guild_id,
                    .role_id = this.payload.role_id,
                    .user_id = this.payload.user_id,
                }));
            }

            while (this.has_role_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.has_role_task.?.result) {
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
        }

        // R8
        // await this.remove_role_task
        {
            if (this.remove_role_task == null) {
                this.remove_role_task = .from(.init(this.db.?, .{
                    .guild_id = this.get_role_task.?.result.?.guild_id,
                    .user_id = this.payload.user_id,
                    .role_id = this.payload.role_id,
                }));
            }

            while (!this.remove_role_task.?.done) {
                if (this.remove_role_task.?.await()) |res| {
                    return res.discard();
                }

                root.bus.raise(.{
                    .role_revoked = .{
                        .id = this.payload.role_id,
                        .guild_id = this.get_role_task.?.result.?.guild_id,
                        .user_id = this.payload.user_id,
                    },
                });
            }
        }

        // await this.audit_log
        {
            if (this.audit_log == null) {
                this.audit_entries[0] = .{
                    .action = .role_revoke,
                    .target_id = this.payload.role_id,
                    .target_user_id = this.payload.user_id,
                };

                this.audit_log = .from(root.repo.audit_log.Insert.init(this.db.?, this.response.allocator, .{
                    .guild_id = this.get_role_task.?.result.?.guild_id,
                    .actor_id = this.bearer_middleware_task.?.result.?,
                    .entries = this.audit_entries[0..1],
                }));
            }

            while (this.audit_log.?.await()) |res| {
                return res.discard();
            }
        }

        // R8
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

        if (this.bearer_middleware_task) |*t| {
            t.dispose();
            this.bearer_middleware_task = null;
        }

        if (this.get_role_task) |*t| {
            t.dispose();
            this.get_role_task = null;
        }

        if (this.check_user_alive_task) |*t| {
            t.dispose();
            this.check_user_alive_task = null;
        }

        if (this.check_user_guild_rights_task) |*t| {
            t.dispose();
            this.check_user_guild_rights_task = null;
        }

        if (this.get_highest_position_task) |*t| {
            t.dispose();
            this.get_highest_position_task = null;
        }

        if (this.is_higher_than_other_task) |*t| {
            t.dispose();
            this.is_higher_than_other_task = null;
        }

        if (this.has_role_task) |*t| {
            t.dispose();
            this.has_role_task = null;
        }

        if (this.remove_role_task) |*t| {
            t.dispose();
            this.remove_role_task = null;
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

/// DELETE /api/roles/{role_id}/users/{user_id}
/// R1 - user must be logged (see the R-list above DeleteTask)
pub inline fn deleteHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    role_id: root.types.RoleId,
    user_id: root.types.UserId,
) !DeleteTask.Task {
    _ = allocator;

    return try DeleteTask.task(request, response, .{
        .role_id = role_id,
        .user_id = user_id,
    });
}
