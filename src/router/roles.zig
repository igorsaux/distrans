// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../root.zig");

/// Handles `/api/roles/...` (the "roles" segment is already consumed).
pub inline fn handle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    path: std.mem.SplitIterator(u8, .scalar),
) anyerror!root.http.Task {
    var it = path;
    var part = it.next();

    const role_id_raw = part orelse {
        return try root.route.generic.notFoundTask(response);
    };

    const role_id = std.fmt.parseInt(root.types.RoleId, role_id_raw, 10) catch {
        return try root.route.generic.badRequestTask(response);
    };

    part = it.next();

    if (part == null) {
        // /api/roles/{role_id}

        switch (request.method) {
            .get => return try root.route.roles.id.getHandle(allocator, request, response, role_id),
            .patch => return try root.route.roles.id.patchHandle(allocator, request, response, role_id),
            .delete => return try root.route.roles.id.deleteHandle(allocator, request, response, role_id),
            else => return try root.route.generic.methodNotAllowedTask(response, "GET, PATCH, DELETE"),
        }
    } else if (root.utils.eqlMaybe(u8, part, "users")) {
        // /api/roles/{role_id}/users

        part = it.next();

        const user_id_raw = part orelse {
            return try root.route.generic.notFoundTask(response);
        };

        const user_id = std.fmt.parseInt(root.types.UserId, user_id_raw, 10) catch {
            return try root.route.generic.badRequestTask(response);
        };

        part = it.next();

        if (part == null) {
            // /api/roles/{role_id}/users/{user_id}

            switch (request.method) {
                .put => return try root.route.roles.id.users.id.putHandle(allocator, request, response, role_id, user_id),
                .delete => return try root.route.roles.id.users.id.deleteHandle(allocator, request, response, role_id, user_id),
                else => return try root.route.generic.methodNotAllowedTask(response, "PUT, DELETE"),
            }
        }
    }

    return try root.route.generic.notFoundTask(response);
}
