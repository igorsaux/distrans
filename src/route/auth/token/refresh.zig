// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../../root.zig");

const SCOPE = std.log.scoped(.@"/api/auth/token/refresh");

/// R1 - request must carry a "refresh_token" cookie
/// R2 - the old refresh token must exist and be unexpired
const PostTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        refresh_token_hash: [32]u8,
    };

    pub const Response = struct {
        access_token: []const u8,
        expires_in: u64,
    };

    response: *root.http.Response,
    payload: Payload,
    db: ?*root.db.Connection = null,
    new_refresh_token: ?[]const u8 = null,
    replace_refresh_token_task: ?root.repo.tokens.Replace.Lazy = null,
    access_token: ?[]const u8 = null,
    body: ?[]const u8 = null,
    streamer: ?root.http.Response.Streamer = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *PostTask = @ptrCast(@alignCast(ctx));

        if (this.db == null) {
            this.db = root.db_pool.rent() orelse {
                return .{ .pending = .db };
            };
        }

        const db = this.db.?;

        if (this.new_refresh_token == null) {
            this.new_refresh_token = root.services.tokens.generateRefreshToken(this.response.allocator) catch |err| {
                SCOPE.err("POST failed to generate refresh token: {t}", .{err});

                return .{ .err = err };
            };
        }

        // R2
        // await this.replace_refresh_token
        {
            if (this.replace_refresh_token_task == null) {
                var new_refresh_token_hash: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(this.new_refresh_token.?, &new_refresh_token_hash, .{});

                const now_s: u64 = @intCast(std.Io.Timestamp.now(root.io, .real).toSeconds());

                this.replace_refresh_token_task = .from(.init(db, .{
                    .old_refresh_token_hash = this.payload.refresh_token_hash,
                    .new_refresh_token_hash = new_refresh_token_hash,
                    .expires_at_us = (now_s + root.options.auth.refresh_token_exp_s) * std.time.us_per_s,
                }));
            }

            while (this.replace_refresh_token_task.?.await()) |res| {
                return res.discard();
            }

            if (this.replace_refresh_token_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .unauthorized, "Bad refresh token");
            }
        }

        if (this.access_token == null) {
            this.access_token = root.services.tokens.generateAccessToken(this.response.allocator, this.replace_refresh_token_task.?.result.?) catch |err| {
                SCOPE.err("POST failed to create access token: {t}", .{err});

                return .{ .err = err };
            };
        }

        if (this.body == null) {
            const response: Response = .{
                .access_token = this.access_token.?,
                .expires_in = root.options.auth.access_token_exp_s,
            };
            var writer: std.Io.Writer.Allocating = .init(this.response.allocator);

            std.json.fmt(response, .{}).format(&writer.writer) catch |err| {
                SCOPE.err("POST failed to serialize the response: {t}", .{err});

                return .{ .err = err };
            };

            this.body = writer.written();
        }

        if (this.streamer == null) {
            var writer = this.response.getWriter();

            if (!writer.writeCode(.ok)) {
                return .{ .pending = .want_write };
            }

            if (!writer.writeHeader(
                "Set-Cookie",
                root.services.tokens.REFRESH_COOKIE_NAME ++ "={s}; Path=" ++ root.services.tokens.REFRESH_COOKIE_PATH ++ "; Max-Age={}; HttpOnly; Secure; SameSite=Strict",
                .{ this.new_refresh_token.?, root.options.auth.refresh_token_exp_s },
            )) {
                return .{ .pending = .want_write };
            }

            if (!writer.beginJSON(this.body.?.len)) {
                return .{ .pending = .want_write };
            }

            writer.commit();
            this.streamer = this.response.getStreamer(this.body.?);
        }

        return this.streamer.?.poll();
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *PostTask = @ptrCast(@alignCast(ctx));

        if (this.replace_refresh_token_task) |*t| {
            t.dispose();
            this.replace_refresh_token_task = null;
        }

        if (this.db) |db| {
            db.release();
            this.db = null;
        }
    }

    pub inline fn task(response: *root.http.Response, payload: Payload) !Task {
        const this = try response.allocator.create(PostTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .response = response,
            .payload = payload,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// POST /api/auth/token/refresh
/// R1 - request must carry a "refresh_token" cookie
pub inline fn postHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
) !PostTask.Task {
    _ = allocator;

    // R1
    const refresh_token_hash: [32]u8 = root.services.tokens.extractRefreshTokenHash(request.cookies) orelse {
        return try root.route.generic.badRequestTask(response);
    };

    return try PostTask.task(response, .{
        .refresh_token_hash = refresh_token_hash,
    });
}
