// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../root.zig");

/// Handles `/api/guilds/...` (the "guilds" segment is already consumed).
pub inline fn handle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    path: std.mem.SplitIterator(u8, .scalar),
) anyerror!root.http.Task {
    var it = path;
    var part = it.next();

    if (part == null) {
        // /api/guilds

        return switch (request.method) {
            .get => try root.route.guilds.getHandle(allocator, request, response),
            else => return try root.route.generic.methodNotAllowedTask(response, "GET"),
        };
    }

    const guild_id_raw = part orelse {
        return try root.route.generic.notFoundTask(response);
    };

    const guild_id = std.fmt.parseInt(root.types.GuildId, guild_id_raw, 10) catch {
        return try root.route.generic.badRequestTask(response);
    };

    part = it.next();

    if (part == null) {
        // /api/guilds/{guild_id}

        return switch (request.method) {
            .patch => try root.route.guilds.id.patchHandle(allocator, request, response, guild_id),
            else => try root.route.generic.methodNotAllowedTask(response, "PATCH"),
        };
    } else if (root.utils.eqlMaybe(u8, part, "avatar")) {
        // /api/guilds/{guild_id}/avatar

        part = it.next();

        if (part == null) {
            // /api/guilds/{guild_id}/avatar

            return switch (request.method) {
                .get => try root.route.guilds.id.avatar.getHandle(allocator, request, response, guild_id),
                .put => try root.route.guilds.id.avatar.putHandle(allocator, request, response, guild_id),
                .delete => try root.route.guilds.id.avatar.deleteHandle(allocator, request, response, guild_id),
                else => try root.route.generic.methodNotAllowedTask(response, "GET, PUT, DELETE"),
            };
        }
    } else if (root.utils.eqlMaybe(u8, part, "channels")) {
        // /api/guilds/{guild_id}/channels

        part = it.next();

        if (part == null) {
            // /api/guilds/{guild_id}/channels

            return switch (request.method) {
                .get => try root.route.guilds.id.channels.getHandle(allocator, request, response, guild_id),
                .post => try root.route.guilds.id.channels.postHandle(allocator, request, response, guild_id),
                else => try root.route.generic.methodNotAllowedTask(response, "GET, POST"),
            };
        } else if (root.utils.eqlMaybe(u8, part, "order")) {
            // /api/guilds/{guild_id}/channels/order

            part = it.next();

            if (part == null) {
                return switch (request.method) {
                    .put => try root.route.guilds.id.channels.order.putHandle(allocator, request, response, guild_id),
                    else => try root.route.generic.methodNotAllowedTask(response, "PUT"),
                };
            }
        }
    } else if (root.utils.eqlMaybe(u8, part, "roles")) {
        // /api/guilds/{guild_id}/roles

        part = it.next();

        if (part == null) {
            // /api/guilds/{guild_id}/roles

            return switch (request.method) {
                .get => try root.route.guilds.id.roles.getHandle(allocator, request, response, guild_id),
                .post => try root.route.guilds.id.roles.postHandle(allocator, request, response, guild_id),
                else => try root.route.generic.methodNotAllowedTask(response, "GET, POST"),
            };
        } else if (root.utils.eqlMaybe(u8, part, "order")) {
            // /api/guilds/{guild_id}/roles/order

            part = it.next();

            if (part == null) {
                return switch (request.method) {
                    .put => try root.route.guilds.id.roles.order.putHandle(allocator, request, response, guild_id),
                    else => try root.route.generic.methodNotAllowedTask(response, "PUT"),
                };
            }
        }
    } else if (root.utils.eqlMaybe(u8, part, "members")) {
        // /api/guilds/{guild_id}/members

        const user_id_raw = it.next() orelse {
            return try root.route.generic.notFoundTask(response);
        };

        const user_id = std.fmt.parseInt(root.types.UserId, user_id_raw, 10) catch {
            return try root.route.generic.badRequestTask(response);
        };

        part = it.next();

        if (root.utils.eqlMaybe(u8, part, "roles")) {
            // /api/guilds/{guild_id}/members/{user_id}/roles

            return switch (request.method) {
                .get => try root.route.guilds.id.members.roles.getHandle(allocator, request, response, guild_id, user_id),
                else => try root.route.generic.methodNotAllowedTask(response, "GET"),
            };
        }
    } else if (root.utils.eqlMaybe(u8, part, "messages")) {
        // /api/guilds/{guild_id}/messages/search

        const sub = it.next() orelse {
            return try root.route.generic.notFoundTask(response);
        };

        if (!root.utils.eqlMaybe(u8, sub, "search") or it.next() != null) {
            return try root.route.generic.notFoundTask(response);
        }

        return switch (request.method) {
            .get => try root.route.guilds.id.messages.searchHandle(allocator, request, response, guild_id),
            else => try root.route.generic.methodNotAllowedTask(response, "GET"),
        };
    } else if (root.utils.eqlMaybe(u8, part, "audit-log")) {
        // /api/guilds/{guild_id}/audit-log

        part = it.next();

        if (part == null) {
            return switch (request.method) {
                .get => try root.route.guilds.id.audit_log.getHandle(allocator, request, response, guild_id),
                else => try root.route.generic.methodNotAllowedTask(response, "GET"),
            };
        }
    } else if (root.utils.eqlMaybe(u8, part, "sync")) {
        // /api/guilds/{guild_id}/sync

        part = it.next();

        if (part == null) {
            return switch (request.method) {
                .get => try root.route.guilds.id.sync.getHandle(allocator, request, response, guild_id),
                else => try root.route.generic.methodNotAllowedTask(response, "GET"),
            };
        }
    } else if (root.utils.eqlMaybe(u8, part, "emojis")) {
        // /api/guilds/{guild_id}/emojis

        part = it.next();

        if (part == null) {
            // /api/guilds/{guild_id}/emojis

            return switch (request.method) {
                .get => try root.route.guilds.id.emojis.getHandle(allocator, request, response, guild_id),
                .post => try root.route.guilds.id.emojis.postHandle(allocator, request, response, guild_id),
                else => try root.route.generic.methodNotAllowedTask(response, "GET, POST"),
            };
        }
    }

    return try root.route.generic.notFoundTask(response);
}
