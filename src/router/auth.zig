// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../root.zig");

/// Handles `/api/auth/...` (the "auth" segment is already consumed).
pub inline fn handle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    path: std.mem.SplitIterator(u8, .scalar),
) anyerror!root.http.Task {
    var it = path;
    var part = it.next();

    if (root.utils.eqlMaybe(u8, part, "token")) {
        // /api/auth/token

        part = it.next();

        if (part == null) {
            // /api/auth/token

            switch (request.method) {
                .post => return try root.route.auth.token.postHandle(allocator, request, response),
                else => return try root.route.generic.methodNotAllowedTask(response, "POST"),
            }
        }

        if (root.utils.eqlMaybe(u8, part, "refresh")) {
            switch (request.method) {
                .post => return try root.route.auth.token.refresh.postHandle(allocator, request, response),
                else => return try root.route.generic.methodNotAllowedTask(response, "POST"),
            }
        } else if (root.utils.eqlMaybe(u8, part, "logout")) {
            switch (request.method) {
                .post => return try root.route.auth.token.logout.postHandle(allocator, request, response),
                else => return try root.route.generic.methodNotAllowedTask(response, "POST"),
            }
        }
    }

    return try root.route.generic.notFoundTask(response);
}
