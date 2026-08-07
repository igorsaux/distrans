// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../root.zig");

pub const CodeBodyResponse = struct {
    const Task = root.task.Task(void, anyerror);

    response: *root.http.Response,
    code: root.http.ResponseCode,
    content_type: []const u8,
    body: []const u8,
    allow: ?[]const u8 = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *CodeBodyResponse = @ptrCast(@alignCast(ctx));

        var writer = this.response.getWriter();

        if (!writer.writeCode(this.code)) {
            return .{ .pending = .want_write };
        }

        if (this.allow) |allow| {
            if (!writer.writeHeader("Allow", "{s}", .{allow})) {
                return .{ .pending = .want_write };
            }
        }

        if (!writer.writeBody(this.content_type, this.body)) {
            return .{ .pending = .want_write };
        }

        writer.commit();

        return .ready;
    }

    fn dispose(ctx: *anyopaque) void {
        _ = ctx;
    }

    pub inline fn task(
        response: *root.http.Response,
        code: root.http.ResponseCode,
        content_type: []const u8,
        body: []const u8,
        allow: ?[]const u8,
    ) !Task {
        const this = try response.allocator.create(CodeBodyResponse);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .code = code,
            .response = response,
            .content_type = content_type,
            .body = body,
            .allow = allow,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub inline fn badRequestTask(response: *root.http.Response) !CodeBodyResponse.Task {
    return CodeBodyResponse.task(response, .bad_request, "application/json",
        \\{ "message": "Bad Request" }
    , null);
}

pub inline fn badRequestReasonTask(response: *root.http.Response, comptime reason: []const u8) !CodeBodyResponse.Task {
    return CodeBodyResponse.task(
        response,
        .bad_request,
        "application/json",
        "{ \"message\": \"" ++ reason ++ "\" }",
        null,
    );
}

pub inline fn unsupportedMediaTypeTask(response: *root.http.Response) !CodeBodyResponse.Task {
    return CodeBodyResponse.task(response, .unsupported_media_type, "application/json",
        \\{ "message": "Unsupported Media Type" }
    , null);
}

pub inline fn notFoundTask(response: *root.http.Response) !CodeBodyResponse.Task {
    return CodeBodyResponse.task(response, .not_found, "application/json",
        \\{ "message": "Not Found" }
    , null);
}

/// 405 with the `Allow` header listing the methods the path accepts.
pub inline fn methodNotAllowedTask(response: *root.http.Response, comptime allow: []const u8) !CodeBodyResponse.Task {
    return CodeBodyResponse.task(response, .method_not_allowed, "application/json",
        \\{ "message": "Method Not Allowed" }
    , allow);
}

/// Poll-based task that buffers the whole request body into one slice. The body
/// is consumed as it arrives, so the socket buffer is not a hard limit on the
/// upload size; `max_bytes` is enforced while buffering (`error.BodyTooLarge`).
/// The returned slice lives in `response.allocator`.
pub const Body = struct {
    pub const Result = []const u8;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Body, Result, anyerror);

    request: *const root.http.Request,
    response: *root.http.Response,
    max_bytes: usize,
    body: std.ArrayList(u8) = .empty,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *Body = @ptrCast(@alignCast(ctx));

        const available = this.request.getContent();

        if (available.len > 0) {
            if (this.body.items.len + available.len > this.max_bytes) {
                return .{ .err = error.BodyTooLarge };
            }

            this.body.appendSlice(this.response.allocator, available) catch |err| {
                return .{ .err = err };
            };

            this.request.consumeContent(available.len);
        }

        if (this.request.getContentLength() != 0) {
            return .{ .pending = .want_read };
        }

        return .{ .ready = this.body.items };
    }

    fn dispose(ctx: *anyopaque) void {
        _ = ctx;
    }

    pub inline fn init(
        request: *const root.http.Request,
        response: *root.http.Response,
        max_bytes: usize,
    ) Body {
        return .{
            .request = request,
            .response = response,
            .max_bytes = max_bytes,
        };
    }

    pub inline fn task(this: *Body) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub inline fn responseErrorMessage(
    response: *root.http.Response,
    comptime code: root.http.ResponseCode,
    comptime err: []const u8,
) root.http.Task.PollT {
    var writer = response.getWriter();

    if (!writer.writeCode(code)) {
        return .{ .pending = .want_write };
    }

    if (!writer.writeJSON("{ \"message\": \"" ++ err ++ "\"}")) {
        return .{ .pending = .want_write };
    }

    writer.commit();

    return .ready;
}

/// A changed-since `since` was syntactically bad (non-numeric/negative) or
/// implausibly in the future.
pub const SinceError = error{ Invalid, TooOld };

/// Clock-skew tolerance for a `since` that is (slightly) ahead of the app
/// clock. The cursor is produced by the database, so app/database clock skew is
/// expected; this only rejects obviously bogus values.
pub const SINCE_FUTURE_SKEW_MS: i64 = 300_000;

/// Parses a changed-since `since` (epoch milliseconds). `null` means omitted
/// and defaults to the start of the configured lookback window.
///
/// A `since` older than the window is `TooOld` (the caller answers 400 and the
/// client clears the cursor and full-refetches). A future `since` beyond the
/// skew tolerance is `Invalid`; the client would otherwise get an empty page.
pub inline fn parseSince(
    raw: ?[]const u8,
    now_ms: i64,
    max_lookback_s: usize,
) SinceError!u64 {
    const lookback_ms: i64 = @intCast(@min(max_lookback_s, 1_000_000_000) * 1000);
    const min_ms: i64 = @max(now_ms - lookback_ms, 0);

    if (raw) |value| {
        const parsed = std.fmt.parseInt(i64, value, 10) catch {
            return SinceError.Invalid;
        };

        if (parsed < 0 or parsed > now_ms + SINCE_FUTURE_SKEW_MS) {
            return SinceError.Invalid;
        }

        if (parsed < min_ms) {
            return SinceError.TooOld;
        }

        return @intCast(parsed);
    }

    return @intCast(min_ms);
}
