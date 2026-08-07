// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../root.zig");

/// Handles `/api/emojis/...` (the "emojis" segment is already consumed).
pub inline fn handle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    path: std.mem.SplitIterator(u8, .scalar),
) anyerror!root.http.Task {
    var it = path;
    var part = it.next();

    if (part == null) {
        // /api/emojis

        return try root.route.generic.notFoundTask(response);
    }

    const emoji_id_raw = part orelse {
        return try root.route.generic.notFoundTask(response);
    };

    const emoji_id = std.fmt.parseInt(root.types.EmojiId, emoji_id_raw, 10) catch {
        return try root.route.generic.badRequestTask(response);
    };

    part = it.next();

    if (part == null) {
        // /api/emojis/{emoji_id}

        return switch (request.method) {
            .patch => root.route.emojis.id.patchHandle(allocator, request, response, emoji_id),
            .delete => root.route.emojis.id.deleteHandle(allocator, request, response, emoji_id),
            else => return try root.route.generic.methodNotAllowedTask(response, "PATCH, DELETE"),
        };
    } else if (root.utils.eqlMaybe(u8, part, "icon")) {
        // /api/emojis/{emoji_id}/icon

        part = it.next();

        if (part == null) {
            // /api/emojis/{emoji_id}/icon

            return switch (request.method) {
                .get => root.route.emojis.id.icon.getHandle(allocator, request, response, emoji_id),
                .put => root.route.emojis.id.icon.putHandle(allocator, request, response, emoji_id),
                else => return try root.route.generic.methodNotAllowedTask(response, "GET, PUT"),
            };
        }
    }

    return try root.route.generic.notFoundTask(response);
}
