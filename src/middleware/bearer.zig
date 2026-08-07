// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.bearer_middleware);

pub const BearerMiddleware = struct {
    pub const Result = ?root.types.UserId;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(BearerMiddleware, Result, anyerror);

    request: *const root.http.Request,
    response: *root.http.Response,
    db: *root.db.Connection,
    verified: bool = false,
    user_id: ?root.types.UserId = null,
    is_bot_token: bool = false,
    bot_token_hash: ?[32]u8 = null,
    check_user_alive: ?root.repo.users.CheckAlive.Lazy = null,
    get_bot_token_task: ?root.repo.tokens.GetBotTokenUser.Lazy = null,

    const Extraction = struct {
        token: []const u8,
    };

    inline fn extractToken(this: *BearerMiddleware) ?Extraction {
        if (this.request.authorization == null) {
            return null;
        }

        const header = this.request.authorization.?;

        const token_delim = std.mem.findScalar(u8, header, ' ') orelse {
            return null;
        };

        if (token_delim + 1 >= header.len) {
            return null;
        }

        const bearer = header[0..token_delim];

        if (!std.mem.eql(u8, std.mem.trim(u8, bearer, " "), "Bearer")) {
            return null;
        }

        const token = std.mem.trim(u8, header[token_delim + 1 ..], " ");

        if (token.len == 0) {
            return null;
        }

        return .{ .token = token };
    }

    inline fn verify(this: *BearerMiddleware, token: []const u8) !?root.types.UserId {
        const token_parts = root.services.tokens.AccessTokenParts.split(token) orelse {
            return null;
        };

        if (!token_parts.verify()) {
            return null;
        }

        const payload = token_parts.parsePayload(this.response.allocator) catch {
            return null;
        };

        const now_s: u64 = @intCast(std.Io.Timestamp.now(root.io, .real).toSeconds());

        if (now_s >= payload.exp) {
            return null;
        }

        return std.fmt.parseInt(root.types.UserId, payload.sub, 10) catch {
            return null;
        };
    }

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *BearerMiddleware = @ptrCast(@alignCast(ctx));

        if (!this.verified) {
            this.verified = true;

            const extraction = this.extractToken() orelse {
                return root.route.generic
                    .responseErrorMessage(this.response, .unauthorized, "Bad token")
                    .map(Result, null);
            };

            if (root.services.tokens.isBotToken(extraction.token)) {
                this.is_bot_token = true;
                this.bot_token_hash = root.services.tokens.botTokenHash(extraction.token);
            } else {
                this.user_id = this.verify(extraction.token) catch |err| {
                    SCOPE.err("failed to verify a token: {t}", .{err});

                    return .{ .err = err };
                };

                if (this.user_id == null) {
                    return root.route.generic
                        .responseErrorMessage(this.response, .unauthorized, "Bad token")
                        .map(Result, null);
                }
            }
        }

        // Bot tokens are resolved by their hash in the DB; the lookup already
        // rejects deleted users, so no separate alive check is needed.
        if (this.is_bot_token and this.user_id == null) {
            // await this.get_bot_token_user
            {
                if (this.get_bot_token_task == null) {
                    this.get_bot_token_task = .from(.init(this.db, .{ .token_hash = this.bot_token_hash.? }));
                }

                while (this.get_bot_token_task.?.await()) |res| {
                    return res.mapDiscard(Result);
                }

                if (this.get_bot_token_task.?.result == null) {
                    return root.route.generic
                        .responseErrorMessage(this.response, .unauthorized, "Bad token")
                        .map(Result, null);
                }

                this.user_id = this.get_bot_token_task.?.result;
            }
        }

        if (this.is_bot_token) {
            return .{ .ready = this.user_id.? };
        }

        // The token is valid, but the user may have been deleted since it was
        // issued: reject requests on behalf of deleted accounts.
        // await this.check_user_alive
        {
            if (this.check_user_alive == null) {
                this.check_user_alive = .from(.init(this.db, .{
                    .user_id = this.user_id.?,
                }));
            }

            while (this.check_user_alive.?.await()) |res| {
                return res.mapDiscard(Result);
            }

            if (!this.check_user_alive.?.result) {
                this.user_id = null;

                return root.route.generic
                    .responseErrorMessage(this.response, .unauthorized, "Bad token")
                    .map(Result, null);
            }
        }

        return .{ .ready = this.user_id.? };
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *BearerMiddleware = @ptrCast(@alignCast(ctx));

        if (this.check_user_alive) |*t| {
            t.dispose();
            this.check_user_alive = null;
        }

        if (this.get_bot_token_task) |*t| {
            t.dispose();
            this.get_bot_token_task = null;
        }
    }

    pub inline fn init(
        request: *const root.http.Request,
        response: *root.http.Response,
        db: *root.db.Connection,
    ) BearerMiddleware {
        return .{
            .request = request,
            .response = response,
            .db = db,
        };
    }

    pub inline fn task(this: *BearerMiddleware) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};
