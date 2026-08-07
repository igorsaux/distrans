// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../root.zig");

/// Handles `/api/gateway` (the "gateway" segment is already consumed).
pub fn gateway(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    path: std.mem.SplitIterator(u8, .scalar),
) anyerror!root.http.Task {
    var it = path;

    if (it.next() != null) {
        return try root.route.generic.notFoundTask(response);
    }

    switch (request.method) {
        .get => return try root.route.gateway.getHandle(allocator, request, response),
        else => return try root.route.generic.methodNotAllowedTask(response, "GET"),
    }
}

/// Handles `/api/limits` (the "limits" segment is already consumed).
pub fn limits(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    path: std.mem.SplitIterator(u8, .scalar),
) anyerror!root.http.Task {
    var it = path;

    if (it.next() != null) {
        return try root.route.generic.notFoundTask(response);
    }

    switch (request.method) {
        .get => return try root.route.limits.getHandle(allocator, request, response),
        else => return try root.route.generic.methodNotAllowedTask(response, "GET"),
    }
}
