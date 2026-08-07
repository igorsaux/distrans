// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../root.zig");

/// Handles `/api/terms` (the "terms" segment is already consumed).
/// R1 - method must be GET
pub fn terms(
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
        // R1
        .get => return try root.route.legal.termsGetHandle(allocator, request, response),
        else => return try root.route.generic.methodNotAllowedTask(response, "GET"),
    }
}

/// Handles `/api/privacy` (the "privacy" segment is already consumed).
/// R1 - method must be GET
pub fn privacy(
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
        // R1
        .get => return try root.route.legal.privacyGetHandle(allocator, request, response),
        else => return try root.route.generic.methodNotAllowedTask(response, "GET"),
    }
}
