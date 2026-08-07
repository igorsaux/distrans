// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../root.zig");

/// Handles `/api/messages/...` (the "messages" segment is already consumed).
pub inline fn handle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    path: std.mem.SplitIterator(u8, .scalar),
) anyerror!root.http.Task {
    var it = path;
    const message_id_raw = it.next() orelse {
        return try root.route.generic.notFoundTask(response);
    };

    const message_id = std.fmt.parseInt(root.types.MessageId, message_id_raw, 10) catch {
        return try root.route.generic.badRequestTask(response);
    };

    var part = it.next();

    if (part == null) {
        // /api/messages/{message_id}

        switch (request.method) {
            .get => return try root.route.messages.id.getHandle(allocator, request, response, message_id),
            .patch => return try root.route.messages.id.patchHandle(allocator, request, response, message_id),
            .delete => return try root.route.messages.id.deleteHandle(allocator, request, response, message_id),
            else => return try root.route.generic.methodNotAllowedTask(response, "GET, PATCH, DELETE"),
        }
    } else if (root.utils.eqlMaybe(u8, part, "reactions")) {
        // /api/messages/{message_id}/reactions

        part = it.next();

        if (part == null) {
            // /api/messages/{message_id}/reactions

            switch (request.method) {
                .put => return try root.route.messages.id.reactions.putHandle(allocator, request, response, message_id),
                .delete => return try root.route.messages.id.reactions.deleteHandle(allocator, request, response, message_id),
                else => return try root.route.generic.methodNotAllowedTask(response, "PUT, DELETE"),
            }
        } else if (root.utils.eqlMaybe(u8, part, "users")) {
            // /api/messages/{message_id}/reactions/users

            part = it.next();

            if (part == null) {
                // /api/messages/{message_id}/reactions/users

                switch (request.method) {
                    .get => return try root.route.messages.id.reactions.usersGetHandle(allocator, request, response, message_id),
                    else => return try root.route.generic.methodNotAllowedTask(response, "GET"),
                }
            }
        }
    }

    return try root.route.generic.notFoundTask(response);
}
