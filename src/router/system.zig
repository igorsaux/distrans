// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../root.zig");

/// Handles `/api/system/...` (the "system" segment is already consumed).
pub inline fn handle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    path: std.mem.SplitIterator(u8, .scalar),
) anyerror!root.http.Task {
    var it = path;
    var part = it.next();

    if (root.utils.eqlMaybe(u8, part, "users")) {
        // /api/system/users

        part = it.next();

        if (part == null) {
            // /api/system/users

            switch (request.method) {
                .post => return try root.route.system.users.postHandle(allocator, request, response),
                else => return try root.route.generic.methodNotAllowedTask(response, "POST"),
            }
        }

        const system_user_id_raw = part orelse {
            return try root.route.generic.notFoundTask(response);
        };

        const system_user_id = std.fmt.parseInt(root.types.UserId, system_user_id_raw, 10) catch {
            return try root.route.generic.badRequestTask(response);
        };

        part = it.next();

        if (part == null) {
            // /api/system/users/{user_id}

            switch (request.method) {
                .patch => return try root.route.system.users.id.patchHandle(allocator, request, response, system_user_id),
                .put => return try root.route.system.users.id.putHandle(allocator, request, response, system_user_id),
                .delete => return try root.route.system.users.id.deleteHandle(allocator, request, response, system_user_id),
                else => return try root.route.generic.methodNotAllowedTask(response, "PATCH, PUT, DELETE"),
            }
        }
    } else if (root.utils.eqlMaybe(u8, part, "superuser")) {
        // /api/system/superuser

        part = it.next();

        if (part == null) {
            // /api/system/superuser

            switch (request.method) {
                .post => return try root.route.system.superuser.postHandle(allocator, request, response),
                else => return try root.route.generic.methodNotAllowedTask(response, "POST"),
            }
        }
    } else if (root.utils.eqlMaybe(u8, part, "guilds")) {
        // /api/system/guilds

        part = it.next();

        if (part == null) {
            // /api/system/guilds

            switch (request.method) {
                .post => return try root.route.system.guilds.postHandle(allocator, request, response),
                else => return try root.route.generic.methodNotAllowedTask(response, "POST"),
            }
        }

        const guild_id_raw = part orelse {
            return try root.route.generic.notFoundTask(response);
        };

        const guild_id = std.fmt.parseInt(root.types.GuildId, guild_id_raw, 10) catch {
            return try root.route.generic.badRequestTask(response);
        };

        part = it.next();

        if (part == null) {
            // /api/system/guilds/{guild_id}

            switch (request.method) {
                .delete => return try root.route.system.guilds.deleteHandle(allocator, request, response, guild_id),
                else => return try root.route.generic.methodNotAllowedTask(response, "DELETE"),
            }
        }

        if (root.utils.eqlMaybe(u8, part, "roles")) {
            // /api/system/guilds/{guild_id}/roles/{role_id}

            const role_id_raw = it.next() orelse {
                return try root.route.generic.notFoundTask(response);
            };

            const role_id = std.fmt.parseInt(root.types.RoleId, role_id_raw, 10) catch {
                return try root.route.generic.badRequestTask(response);
            };

            part = it.next();

            if (part == null) {
                // /api/system/guilds/{guild_id}/roles/{role_id}

                switch (request.method) {
                    .delete => return try root.route.system.guilds.roles.deleteHandle(allocator, request, response, guild_id, role_id),
                    else => return try root.route.generic.methodNotAllowedTask(response, "DELETE"),
                }
            }
        }
    }

    return try root.route.generic.notFoundTask(response);
}
