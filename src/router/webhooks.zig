// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../root.zig");

/// Handles `/api/webhooks/...` (the "webhooks" segment is already consumed).
pub inline fn handle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    path: std.mem.SplitIterator(u8, .scalar),
) anyerror!root.http.Task {
    var it = path;
    const webhook_id_raw = it.next() orelse {
        return try root.route.generic.notFoundTask(response);
    };

    const webhook_id = std.fmt.parseInt(root.types.WebhookId, webhook_id_raw, 10) catch {
        return try root.route.generic.badRequestTask(response);
    };

    var part = it.next();

    if (part == null) {
        // /api/webhooks/{webhook_id}

        switch (request.method) {
            .get => return try root.route.webhooks.id.getHandle(allocator, request, response, webhook_id),
            .patch => return try root.route.webhooks.id.patchHandle(allocator, request, response, webhook_id),
            .delete => return try root.route.webhooks.id.deleteHandle(allocator, request, response, webhook_id),
            else => return try root.route.generic.methodNotAllowedTask(response, "GET, PATCH, DELETE"),
        }
    } else if (root.utils.eqlMaybe(u8, part, "avatar")) {
        // /api/webhooks/{webhook_id}/avatar

        part = it.next();

        if (part == null) {
            // /api/webhooks/{webhook_id}/avatar

            switch (request.method) {
                .get => return try root.route.webhooks.id.avatar.getHandle(allocator, request, response, webhook_id),
                .put => return try root.route.webhooks.id.avatar.putHandle(allocator, request, response, webhook_id),
                .delete => return try root.route.webhooks.id.avatar.deleteHandle(allocator, request, response, webhook_id),
                else => return try root.route.generic.methodNotAllowedTask(response, "GET, PUT, DELETE"),
            }
        }
    } else {
        // /api/webhooks/{webhook_id}/{token}[/github]

        const token = part.?;

        part = it.next();

        if (part == null) {
            // /api/webhooks/{webhook_id}/{token}

            switch (request.method) {
                .post => return try root.route.webhooks.id.token.executeHandle(allocator, request, response, webhook_id, token),
                else => return try root.route.generic.methodNotAllowedTask(response, "POST"),
            }
        } else if (root.utils.eqlMaybe(u8, part, "messages")) {
            // /api/webhooks/{webhook_id}/{token}/messages/{message_id}

            const message_id_raw = it.next() orelse {
                return try root.route.generic.notFoundTask(response);
            };

            const message_id = std.fmt.parseInt(root.types.MessageId, message_id_raw, 10) catch {
                return try root.route.generic.badRequestTask(response);
            };

            if (it.next() != null) {
                return try root.route.generic.notFoundTask(response);
            }

            switch (request.method) {
                .get => return try root.route.webhooks.id.messages.getHandle(allocator, request, response, webhook_id, token, message_id),
                .patch => return try root.route.webhooks.id.messages.patchHandle(allocator, request, response, webhook_id, token, message_id),
                .delete => return try root.route.webhooks.id.messages.deleteHandle(allocator, request, response, webhook_id, token, message_id),
                else => return try root.route.generic.methodNotAllowedTask(response, "GET, PATCH, DELETE"),
            }
        } else if (root.utils.eqlMaybe(u8, part, "github")) {
            // /api/webhooks/{webhook_id}/{token}/github

            part = it.next();

            if (part == null) {
                // /api/webhooks/{webhook_id}/{token}/github

                switch (request.method) {
                    .post => return try root.route.webhooks.id.github.executeHandle(allocator, request, response, webhook_id, token),
                    else => return try root.route.generic.methodNotAllowedTask(response, "POST"),
                }
            }
        }
    }

    return try root.route.generic.notFoundTask(response);
}
