// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../root.zig");

/// Handles `/api/files/...` (the "files" segment is already consumed).
pub inline fn handle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    path: std.mem.SplitIterator(u8, .scalar),
) anyerror!root.http.Task {
    var it = path;

    if (it.next() != null) {
        return try root.route.generic.notFoundTask(response);
    }

    // /api/files

    switch (request.method) {
        .post => return try root.route.files.postHandle(allocator, request, response),
        else => return try root.route.generic.methodNotAllowedTask(response, "POST"),
    }
}
