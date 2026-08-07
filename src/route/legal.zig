// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../root.zig");

const TERMS: []const u8 = @embedFile("legal/terms.md");
const PRIVACY: []const u8 = @embedFile("legal/privacy.md");

const CONTENT_TYPE = "text/markdown; charset=utf-8";

/// GET /api/terms - public, returns the embedded Terms of Service markdown.
pub inline fn termsGetHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
) !root.http.Task {
    _ = allocator;
    _ = request;

    return try root.route.generic.CodeBodyResponse.task(response, .ok, CONTENT_TYPE, TERMS, null);
}

/// GET /api/privacy - public, returns the embedded Privacy Policy markdown.
pub inline fn privacyGetHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
) !root.http.Task {
    _ = allocator;
    _ = request;

    return try root.route.generic.CodeBodyResponse.task(response, .ok, CONTENT_TYPE, PRIVACY, null);
}
