// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../../root.zig");

const SCOPE = std.log.scoped(.@"/api/system/guilds/roles");

/// R1 - request must carry a valid system token
/// R2 - the role must not be the @everyone role
/// R3 - the role must exist
const DeleteTask = struct {
    const Task = root.http.Task;

    pub const Payload = struct {
        guild_id: root.types.GuildId,
        role_id: root.types.RoleId,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    system_token_middleware_task: ?root.middleware.system_token.SystemTokenMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    delete_role_task: ?root.repo.roles.Delete.Lazy = null,

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

        // R2
        if (this.payload.role_id == this.payload.guild_id) {
            return root.route.generic.responseErrorMessage(this.response, .forbidden, "Cannot delete the @everyone role");
        }

        if (this.db == null) {
            this.db = root.db_pool.rent() orelse {
                return .{ .pending = .db };
            };
        }

        const db = this.db.?;

        // R3
        // await this.delete_role_task
        {
            if (this.delete_role_task == null) {
                this.delete_role_task = .from(.init(db, .{
                    .guild_id = this.payload.guild_id,
                    .role_id = this.payload.role_id,
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
                            .guild_id = this.payload.guild_id,
                        },
                    });
                }
            }

            if (this.delete_role_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Role not found");
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

        if (this.delete_role_task) |*t| {
            t.dispose();
            this.delete_role_task = null;
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

/// DELETE /api/system/guilds/{guild_id}/roles/{role_id}
/// R1 - request must carry a valid system token (see the R-list above DeleteTask)
pub inline fn deleteHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    guild_id: root.types.GuildId,
    role_id: root.types.RoleId,
) !root.http.Task {
    _ = allocator;

    return try DeleteTask.task(request, response, .{
        .guild_id = guild_id,
        .role_id = role_id,
    });
}
