// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../../root.zig");

const SCOPE = std.log.scoped(.@"/api/auth/token/logout");

/// R1 - request must carry a "refresh_token" cookie
/// R2 - the refresh token must exist and be unexpired
const PostTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        refresh_token_hash: [32]u8,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    db: ?*root.db.Connection = null,
    delete_token_task: ?root.repo.tokens.Delete.Lazy = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *PostTask = @ptrCast(@alignCast(ctx));

        if (this.db == null) {
            this.db = root.db_pool.rent() orelse {
                return .{ .pending = .db };
            };
        }

        // R2
        // await this.delete_token
        {
            if (this.delete_token_task == null) {
                this.delete_token_task = .from(.init(this.db.?, .{
                    .refresh_token_hash = this.payload.refresh_token_hash,
                }));
            }

            while (this.delete_token_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.delete_token_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .unauthorized, "Bad refresh token");
            }
        }

        var writer = this.response.getWriter();

        if (!writer.writeCode(.ok)) {
            return .{ .pending = .want_write };
        }

        if (!writer.writeHeader(
            "Set-Cookie",
            root.services.tokens.REFRESH_COOKIE_NAME ++ "=; Path=" ++ root.services.tokens.REFRESH_COOKIE_PATH ++ "; Max-Age=0; HttpOnly; Secure; SameSite=Strict",
            .{},
        )) {
            return .{ .pending = .want_write };
        }

        if (!writer.emptyBody()) {
            return .{ .pending = .want_write };
        }

        writer.commit();

        return .ready;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *PostTask = @ptrCast(@alignCast(ctx));

        if (this.delete_token_task) |*t| {
            t.dispose();
            this.delete_token_task = null;
        }

        if (this.db) |db| {
            db.release();
            this.db = null;
        }
    }

    pub inline fn task(
        request: *const root.http.Request,
        response: *root.http.Response,
        payload: Payload,
    ) !Task {
        const this = try response.allocator.create(PostTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .request = request,
            .response = response,
            .payload = payload,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// POST /api/auth/token/logout
/// R1 - request must carry a "refresh_token" cookie
pub inline fn postHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
) !PostTask.Task {
    _ = allocator;

    // R1
    if (request.cookies.len == 0) {
        return try root.route.generic.badRequestTask(response);
    }

    // R1
    const refresh_token_hash: [32]u8 = root.services.tokens.extractRefreshTokenHash(request.cookies) orelse {
        return try root.route.generic.badRequestTask(response);
    };

    return try PostTask.task(request, response, .{
        .refresh_token_hash = refresh_token_hash,
    });
}
