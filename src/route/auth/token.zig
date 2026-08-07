// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../root.zig");
pub const logout = @import("token/logout.zig");
pub const refresh = @import("token/refresh.zig");

const SCOPE = std.log.scoped(.@"/api/auth/token");

/// R1 - content type must be application/json (415) and body non-empty (400)
/// R2 - "grant_type" must be present, a string and "password"
/// R3 - "username" must be present and a string
/// R4 - "password" must be present and a string
/// R5 - len("password") <= max_password_len
/// R6 - the user must exist
/// R7 - the password must be verified
const PostTask = struct {
    const Task = root.http.Task;

    const Grant = union(enum) {
        pub const Password = struct {
            username: []const u8,
            password: []const u8,
            get_user_auth_task: ?root.repo.users.GetAuth.Lazy = null,
            verify_password_task: ?root.services.pwhash.VerifyPassword.Lazy = null,
            access_token: ?[]const u8 = null,
            refresh_token: ?[]const u8 = null,
            insert_refresh_token_task: ?root.repo.tokens.Insert.Lazy = null,
            body: ?[]const u8 = null,
            streamer: ?root.http.Response.Streamer = null,
        };

        password: Password,
    };

    pub const Response = struct {
        access_token: []const u8,
        expires_in: u64,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    grant_type: ?Grant = null,
    db: ?*root.db.Connection = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *PostTask = @ptrCast(@alignCast(ctx));

        if (this.grant_type == null) {
            if (!this.request.contentIsAvailable()) {
                return .{ .pending = .want_read };
            }

            const body = std.json.parseFromSliceLeaky(std.json.Value, this.response.allocator, this.request.getContent(), .{}) catch {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad JSON");

                return .ready;
            };

            if (body != .object) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Expected an object");

                return .ready;
            }

            const grant_type_value = body.object.get("grant_type") orelse {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'grant_type' is missing");

                return .ready;
            };

            if (grant_type_value != .string) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'grant_type' is not a string");

                return .ready;
            }

            var grant: Grant = undefined;

            // R2
            if (std.mem.eql(u8, grant_type_value.string, "password")) {
                var password_grant: Grant.Password = undefined;

                // R3
                const username_value = body.object.get("username") orelse {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'username' is missing");

                    return .ready;
                };

                // R3
                if (username_value != .string) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'username' is not a string");

                    return .ready;
                }

                // R4
                const password_value = body.object.get("password") orelse {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'password' is missing");

                    return .ready;
                };

                // R4
                if (password_value != .string) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'password' is not a string");

                    return .ready;
                }

                // R5
                if (password_value.string.len > root.options.auth.password.max_password_len) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'password' is too long");

                    return .ready;
                }

                password_grant = .{
                    .username = username_value.string,
                    .password = password_value.string,
                };

                grant = .{ .password = password_grant };
            } else {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad 'grant_type'");

                return .ready;
            }

            this.grant_type = grant;
        }

        if (this.db == null) {
            this.db = root.db_pool.rent() orelse {
                return .{ .pending = .db };
            };
        }

        const db = this.db.?;

        switch (this.grant_type.?) {
            .password => |*p| {
                // R6
                // await p.get_user_auth
                {
                    if (p.get_user_auth_task == null) {
                        p.get_user_auth_task = .from(.init(this.response.allocator, db, .{
                            .username = p.username,
                        }));
                    }

                    while (p.get_user_auth_task.?.await()) |res| {
                        return res.discard();
                    }

                    if (p.get_user_auth_task.?.result == null) {
                        return root.route.generic.responseErrorMessage(this.response, .unauthorized, "Bad password or username");
                    }
                }

                // R7
                // await this.verify_password_task
                {
                    if (p.verify_password_task == null) {
                        p.verify_password_task = .from(.init(.{
                            .hash = p.get_user_auth_task.?.result.?.password_hash,
                            .password = p.password,
                        }));
                    }

                    while (p.verify_password_task.?.await()) |res| {
                        return res.discard();
                    }

                    if (!p.verify_password_task.?.result) {
                        return root.route.generic.responseErrorMessage(this.response, .unauthorized, "Bad password or username");
                    }
                }

                if (p.access_token == null) {
                    p.access_token = root.services.tokens.generateAccessToken(this.response.allocator, p.get_user_auth_task.?.result.?.id) catch |err| {
                        SCOPE.err("POST failed to generate access token: {t}", .{err});

                        return .{ .err = err };
                    };
                }

                // await p.insert_refresh_token
                {
                    if (p.refresh_token == null) {
                        p.refresh_token = root.services.tokens.generateRefreshToken(this.response.allocator) catch |err| {
                            SCOPE.err("POST failed to generate refresh token: {t}", .{err});

                            return .{ .err = err };
                        };
                    }

                    if (p.insert_refresh_token_task == null) {
                        var token_hash: [32]u8 = undefined;
                        std.crypto.hash.sha2.Sha256.hash(p.refresh_token.?, &token_hash, .{});

                        const now_s: u64 = @intCast(std.Io.Timestamp.now(root.io, .real).toSeconds());

                        p.insert_refresh_token_task = .from(.init(db, .{
                            .user_id = p.get_user_auth_task.?.result.?.id,
                            .token_hash = token_hash,
                            .expires_at_us = (now_s + root.options.auth.refresh_token_exp_s) * std.time.us_per_s,
                        }));
                    }

                    while (p.insert_refresh_token_task.?.await()) |res| {
                        return res.discard();
                    }
                }

                if (p.body == null) {
                    const response: Response = .{
                        .access_token = p.access_token.?,
                        .expires_in = root.options.auth.access_token_exp_s,
                    };

                    var writer: std.Io.Writer.Allocating = .init(this.response.allocator);

                    std.json.fmt(response, .{}).format(&writer.writer) catch |err| {
                        SCOPE.err("POST failed to serialize the response: {t}", .{err});

                        return .{ .err = err };
                    };

                    p.body = writer.written();
                }

                if (p.streamer == null) {
                    var writer = this.response.getWriter();

                    if (!writer.writeCode(.ok)) {
                        return .{ .pending = .want_write };
                    }

                    if (!writer.writeHeader(
                        "Set-Cookie",
                        root.services.tokens.REFRESH_COOKIE_NAME ++ "={s}; Path=" ++ root.services.tokens.REFRESH_COOKIE_PATH ++ "; Max-Age={}; HttpOnly; Secure; SameSite=Strict",
                        .{ p.refresh_token.?, root.options.auth.refresh_token_exp_s },
                    )) {
                        return .{ .pending = .want_write };
                    }

                    if (!writer.beginJSON(p.body.?.len)) {
                        return .{ .pending = .want_write };
                    }

                    writer.commit();
                    p.streamer = this.response.getStreamer(p.body.?);
                }

                return p.streamer.?.poll();
            },
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *PostTask = @ptrCast(@alignCast(ctx));

        if (this.grant_type) |*g| {
            switch (g.*) {
                .password => |*p| {
                    if (p.get_user_auth_task) |*t| {
                        t.dispose();
                        p.get_user_auth_task = null;
                    }

                    if (p.verify_password_task) |*t| {
                        t.dispose();
                        p.verify_password_task = null;
                    }

                    if (p.insert_refresh_token_task) |*t| {
                        t.dispose();
                        p.insert_refresh_token_task = null;
                    }
                },
            }
        }

        if (this.db) |db| {
            db.release();
            this.db = null;
        }
    }

    pub inline fn task(request: *const root.http.Request, response: *root.http.Response) !Task {
        const this = try response.allocator.create(PostTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .request = request,
            .response = response,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// POST /api/auth/token
/// R1 - content type must be application/json (415) and body non-empty (400)
pub inline fn postHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
) !root.http.Task {
    _ = allocator;

    // R1
    if (request.getContentLength() == 0) {
        return try root.route.generic.badRequestTask(response);
    }

    // R1
    if (!root.utils.startsWithMaybe(u8, request.content_type, "application/json")) {
        return try root.route.generic.unsupportedMediaTypeTask(response);
    }

    return try PostTask.task(request, response);
}
