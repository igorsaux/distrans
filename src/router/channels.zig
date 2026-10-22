// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../root.zig");

/// Handles `/api/channels/...` (the "channels" segment is already consumed).
pub inline fn handle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    path: std.mem.SplitIterator(u8, .scalar),
) anyerror!root.http.Task {
    var it = path;
    const channel_id_raw = it.next() orelse {
        return try root.route.generic.notFoundTask(response);
    };

    const channel_id = std.fmt.parseInt(root.types.ChannelId, channel_id_raw, 10) catch {
        return try root.route.generic.badRequestTask(response);
    };

    var part = it.next();

    if (part == null) {
        // /api/channels/{channel_id}

        switch (request.method) {
            .get => return try root.route.channels.id.getHandle(allocator, request, response, channel_id),
            .patch => return try root.route.channels.id.patchHandle(allocator, request, response, channel_id),
            .delete => return try root.route.channels.id.deleteHandle(allocator, request, response, channel_id),
            else => return try root.route.generic.methodNotAllowedTask(response, "GET, PATCH, DELETE"),
        }
    }

    if (root.utils.eqlMaybe(u8, part, "messages")) {
        // /api/channels/{channel_id}/messages

        part = it.next();

        if (part == null) {
            // /api/channels/{channel_id}/messages

            switch (request.method) {
                .get => return try root.route.channels.id.messages.getHandle(allocator, request, response, channel_id),
                .post => return try root.route.channels.id.messages.postHandle(allocator, request, response, channel_id),
                else => return try root.route.generic.methodNotAllowedTask(response, "GET, POST"),
            }
        } else if (root.utils.eqlMaybe(u8, part, "sync")) {
            // /api/channels/{channel_id}/messages/sync

            part = it.next();

            if (part == null) {
                return switch (request.method) {
                    .get => try root.route.channels.id.messages.sync.getHandle(allocator, request, response, channel_id),
                    else => try root.route.generic.methodNotAllowedTask(response, "GET"),
                };
            }
        }
    } else if (root.utils.eqlMaybe(u8, part, "overwrites")) {
        // /api/channels/{channel_id}/overwrites

        part = it.next();

        if (part == null) {
            // /api/channels/{channel_id}/overwrites

            switch (request.method) {
                .put => return try root.route.channels.overwrites.putHandle(allocator, request, response, channel_id),
                else => return try root.route.generic.methodNotAllowedTask(response, "PUT"),
            }
        }
    } else if (root.utils.eqlMaybe(u8, part, "pins")) {
        // /api/channels/{channel_id}/pins

        part = it.next();

        if (part == null) {
            // /api/channels/{channel_id}/pins

            switch (request.method) {
                .get => return try root.route.channels.id.pins.getHandle(allocator, request, response, channel_id),
                else => return try root.route.generic.methodNotAllowedTask(response, "GET"),
            }
        }

        if (root.utils.eqlMaybe(u8, part, "messages")) {
            // /api/channels/{channel_id}/pins/messages

            if (it.next() != null) {
                return try root.route.generic.notFoundTask(response);
            }

            return switch (request.method) {
                .get => try root.route.channels.id.pins.messages.getHandle(allocator, request, response, channel_id),
                else => try root.route.generic.methodNotAllowedTask(response, "GET"),
            };
        }

        // /api/channels/{channel_id}/pins/{message_id}

        if (it.next() != null) {
            return try root.route.generic.notFoundTask(response);
        }

        const message_id = std.fmt.parseInt(root.types.MessageId, part.?, 10) catch {
            return try root.route.generic.badRequestTask(response);
        };

        switch (request.method) {
            .put => return try root.route.channels.id.pins.putHandle(allocator, request, response, channel_id, message_id),
            .delete => return try root.route.channels.id.pins.deleteHandle(allocator, request, response, channel_id, message_id),
            else => return try root.route.generic.methodNotAllowedTask(response, "PUT, DELETE"),
        }
    } else if (root.utils.eqlMaybe(u8, part, "webhooks")) {
        // /api/channels/{channel_id}/webhooks

        part = it.next();

        if (part == null) {
            // /api/channels/{channel_id}/webhooks

            switch (request.method) {
                .get => return try root.route.channels.webhooks.getHandle(allocator, request, response, channel_id),
                .post => return try root.route.channels.webhooks.postHandle(allocator, request, response, channel_id),
                else => return try root.route.generic.methodNotAllowedTask(response, "GET, POST"),
            }
        }
    }

    return try root.route.generic.notFoundTask(response);
}
