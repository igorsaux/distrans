// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("root.zig");
const auth = @import("router/auth.zig");
const channels = @import("router/channels.zig");
const emojis = @import("router/emojis.zig");
const files = @import("router/files.zig");
const guilds = @import("router/guilds.zig");
const legal = @import("router/legal.zig");
const messages = @import("router/messages.zig");
const misc = @import("router/misc.zig");
const roles = @import("router/roles.zig");
const system = @import("router/system.zig");
const users = @import("router/users.zig");
const webhooks = @import("router/webhooks.zig");

pub inline fn httpFactory(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
) anyerror!root.http.Task {
    const path = if (std.mem.findScalar(u8, request.path, '?')) |query_delim|
        request.path[0..query_delim]
    else
        request.path;

    var path_iter = std.mem.splitScalar(u8, path, '/');

    if (path_iter.next() == null) {
        return try root.route.generic.notFoundTask(response);
    }

    if (!root.utils.eqlMaybe(u8, path_iter.next(), "api")) {
        return try root.route.generic.notFoundTask(response);
    }

    // /api

    const part = path_iter.next() orelse {
        return try root.route.generic.notFoundTask(response);
    };

    if (root.utils.eqlMaybe(u8, part, "guilds")) {
        // /api/guilds/...
        return try guilds.handle(allocator, request, response, path_iter);
    } else if (root.utils.eqlMaybe(u8, part, "channels")) {
        // /api/channels/...
        return try channels.handle(allocator, request, response, path_iter);
    } else if (root.utils.eqlMaybe(u8, part, "auth")) {
        // /api/auth/...
        return try auth.handle(allocator, request, response, path_iter);
    } else if (root.utils.eqlMaybe(u8, part, "users")) {
        // /api/users/...
        return try users.handle(allocator, request, response, path_iter);
    } else if (root.utils.eqlMaybe(u8, part, "system")) {
        // /api/system/...
        return try system.handle(allocator, request, response, path_iter);
    } else if (root.utils.eqlMaybe(u8, part, "gateway")) {
        // /api/gateway
        return try misc.gateway(allocator, request, response, path_iter);
    } else if (root.utils.eqlMaybe(u8, part, "limits")) {
        // /api/limits
        return try misc.limits(allocator, request, response, path_iter);
    } else if (root.utils.eqlMaybe(u8, part, "terms")) {
        // /api/terms
        return try legal.terms(allocator, request, response, path_iter);
    } else if (root.utils.eqlMaybe(u8, part, "privacy")) {
        // /api/privacy
        return try legal.privacy(allocator, request, response, path_iter);
    } else if (root.utils.eqlMaybe(u8, part, "roles")) {
        // /api/roles
        return try roles.handle(allocator, request, response, path_iter);
    } else if (root.utils.eqlMaybe(u8, part, "messages")) {
        // /api/messages
        return try messages.handle(allocator, request, response, path_iter);
    } else if (root.utils.eqlMaybe(u8, part, "emojis")) {
        // /api/emojis
        return try emojis.handle(allocator, request, response, path_iter);
    } else if (root.utils.eqlMaybe(u8, part, "files")) {
        // /api/files
        return try files.handle(allocator, request, response, path_iter);
    } else if (root.utils.eqlMaybe(u8, part, "webhooks")) {
        // /api/webhooks
        return try webhooks.handle(allocator, request, response, path_iter);
    }

    return try root.route.generic.notFoundTask(response);
}
