// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../root.zig");

/// Handles `/api/users/...` (the "users" segment is already consumed).
pub inline fn handle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    path: std.mem.SplitIterator(u8, .scalar),
) anyerror!root.http.Task {
    var it = path;
    var part = it.next();

    if (part == null) {
        // /api/users

        part = it.next();

        if (part == null) {
            // /api/users

            switch (request.method) {
                .get => return try root.route.users.getHandle(allocator, request, response),
                else => return try root.route.generic.methodNotAllowedTask(response, "GET"),
            }
        }
    } else if (root.utils.eqlMaybe(u8, part, "@me")) {
        // /api/users/@me

        part = it.next();

        if (part == null) {
            // /api/users/@me

            switch (request.method) {
                .get => return try root.route.users.me.getHandle(allocator, request, response),
                .patch => return try root.route.users.me.patchHandle(allocator, request, response),
                else => return try root.route.generic.methodNotAllowedTask(response, "GET, PATCH"),
            }
        } else if (root.utils.eqlMaybe(u8, part, "avatar")) {
            // /api/users/@me/avatar

            part = it.next();

            if (part == null) {
                // /api/users/@me/avatar

                switch (request.method) {
                    .put => return try root.route.users.me.avatar.putHandle(allocator, request, response),
                    .delete => return try root.route.users.me.avatar.deleteHandle(allocator, request, response),
                    else => return try root.route.generic.methodNotAllowedTask(response, "PUT, DELETE"),
                }
            }
        } else if (root.utils.eqlMaybe(u8, part, "userdata")) {
            // /api/users/@me/userdata

            part = it.next();

            if (part == null) {
                // /api/users/@me/userdata

                switch (request.method) {
                    .get => return try root.route.users.me.userdata.getHandle(allocator, request, response),
                    .put => return try root.route.users.me.userdata.putHandle(allocator, request, response),
                    else => return try root.route.generic.methodNotAllowedTask(response, "GET, PUT"),
                }
            }
        } else if (root.utils.eqlMaybe(u8, part, "push-subscriptions")) {
            // /api/users/@me/push-subscriptions[/{subscription_id}]

            part = it.next();

            if (part == null) {
                // /api/users/@me/push-subscriptions

                switch (request.method) {
                    .get => return try root.route.users.me.push_subscriptions.getHandle(allocator, request, response),
                    .post => return try root.route.users.me.push_subscriptions.postHandle(allocator, request, response),
                    else => return try root.route.generic.methodNotAllowedTask(response, "GET, POST"),
                }
            } else {
                // /api/users/@me/push-subscriptions/{subscription_id}

                const subscription_id = std.fmt.parseInt(root.types.PushSubscriptionId, part.?, 10) catch {
                    return try root.route.generic.badRequestTask(response);
                };

                part = it.next();

                if (part == null) {
                    // /api/users/@me/push-subscriptions/{subscription_id}

                    switch (request.method) {
                        .delete => return try root.route.users.me.push_subscriptions.id.deleteHandle(allocator, request, response, subscription_id),
                        else => return try root.route.generic.methodNotAllowedTask(response, "DELETE"),
                    }
                }
            }
        } else if (root.utils.eqlMaybe(u8, part, "guilds")) {
            // /api/users/@me/guilds/{guild_id}/notifications

            const guild_id_raw = it.next() orelse {
                return try root.route.generic.notFoundTask(response);
            };

            const guild_id = std.fmt.parseInt(root.types.GuildId, guild_id_raw, 10) catch {
                return try root.route.generic.badRequestTask(response);
            };

            part = it.next();

            if (root.utils.eqlMaybe(u8, part, "notifications")) {
                part = it.next();

                if (part == null) {
                    // /api/users/@me/guilds/{guild_id}/notifications

                    switch (request.method) {
                        .get => return try root.route.users.me.guilds.id.notifications.getHandle(allocator, request, response, guild_id),
                        .patch => return try root.route.users.me.guilds.id.notifications.patchHandle(allocator, request, response, guild_id),
                        else => return try root.route.generic.methodNotAllowedTask(response, "GET, PATCH"),
                    }
                }
            }
        } else if (root.utils.eqlMaybe(u8, part, "channels")) {
            // /api/users/@me/channels/{channel_id}/notifications

            const channel_id_raw = it.next() orelse {
                return try root.route.generic.notFoundTask(response);
            };

            const channel_id = std.fmt.parseInt(root.types.ChannelId, channel_id_raw, 10) catch {
                return try root.route.generic.badRequestTask(response);
            };

            part = it.next();

            if (root.utils.eqlMaybe(u8, part, "notifications")) {
                part = it.next();

                if (part == null) {
                    // /api/users/@me/channels/{channel_id}/notifications

                    switch (request.method) {
                        .get => return try root.route.users.me.channels.id.notifications.getHandle(allocator, request, response, channel_id),
                        .patch => return try root.route.users.me.channels.id.notifications.patchHandle(allocator, request, response, channel_id),
                        else => return try root.route.generic.methodNotAllowedTask(response, "GET, PATCH"),
                    }
                }
            }
        }
    } else if (root.utils.eqlMaybe(u8, part, "sync")) {
        // /api/users/sync

        part = it.next();

        if (part == null) {
            switch (request.method) {
                .get => return try root.route.users.sync.getHandle(allocator, request, response),
                else => return try root.route.generic.methodNotAllowedTask(response, "GET"),
            }
        }
    } else {
        // /api/users/{user_id}

        const user_id_raw = part orelse {
            return try root.route.generic.notFoundTask(response);
        };

        const user_id = std.fmt.parseInt(root.types.UserId, user_id_raw, 10) catch {
            return try root.route.generic.badRequestTask(response);
        };

        part = it.next();

        if (part == null) {
            // /api/users/{user_id}

            switch (request.method) {
                .get => return try root.route.users.id.getHandle(allocator, request, response, user_id),
                else => return try root.route.generic.methodNotAllowedTask(response, "GET"),
            }
        } else if (root.utils.eqlMaybe(u8, part, "avatar")) {
            // /api/users/{user_id}/avatar

            part = it.next();

            if (part == null) {
                // /api/users/{user_id}/avatar

                switch (request.method) {
                    .get => return try root.route.users.id.avatar.getHandle(allocator, request, response, user_id),
                    else => return try root.route.generic.methodNotAllowedTask(response, "GET"),
                }
            }
        }
    }

    return try root.route.generic.notFoundTask(response);
}
