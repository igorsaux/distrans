// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../../root.zig");

const SCOPE = std.log.scoped(.@"/api/system/users/{user_id}");

/// R1 - request must carry a valid system token
/// R2 - the user must exist and not be deleted already
const DeleteTask = struct {
    const Task = root.http.Task;

    pub const Payload = struct {
        user_id: root.types.UserId,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    system_token_middleware_task: ?root.middleware.system_token.SystemTokenMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    delete_user_task: ?root.repo.users.SoftDelete.Lazy = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *DeleteTask = @ptrCast(@alignCast(ctx));

        // R1
        // await this.system_token_middleware_task
        {
            if (this.system_token_middleware_task == null) {
                this.system_token_middleware_task = .from(.init(
                    this.request,
                    this.response,
                ));
            }

            while (this.system_token_middleware_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.system_token_middleware_task.?.result) {
                // response handled in the middleware
                return .ready;
            }
        }

        if (this.db == null) {
            this.db = root.db_pool.rent() orelse {
                return .{ .pending = .db };
            };
        }

        const db = this.db.?;

        // R2
        // await this.delete_user_task
        {
            if (this.delete_user_task == null) {
                this.delete_user_task = .from(.init(db, .{
                    .id = this.payload.user_id,
                }));
            }

            while (!this.delete_user_task.?.done) {
                if (this.delete_user_task.?.await()) |res| {
                    return res.discard();
                }

                if (this.delete_user_task.?.result != null) {
                    root.bus.raise(.{
                        .user_deleted = .{
                            .id = this.payload.user_id,
                        },
                    });
                }
            }

            if (this.delete_user_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "User not found");
            }
        }

        var writer = this.response.getWriter();

        if (!writer.writeCode(.no_content)) {
            return .{ .pending = .want_write };
        }

        if (!writer.emptyBody()) {
            return .{ .pending = .want_write };
        }

        writer.commit();

        return .ready;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *DeleteTask = @ptrCast(@alignCast(ctx));

        if (this.system_token_middleware_task) |*t| {
            t.dispose();
            this.system_token_middleware_task = null;
        }

        if (this.delete_user_task) |*t| {
            t.dispose();
            this.delete_user_task = null;
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
        const this = try response.allocator.create(DeleteTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .request = request,
            .response = response,
            .payload = payload,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// DELETE /api/system/users/{user_id}
/// R1 - request must carry a valid system token (see the R-list above DeleteTask)
pub inline fn deleteHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    user_id: root.types.UserId,
) !root.http.Task {
    _ = allocator;

    return try DeleteTask.task(request, response, .{
        .user_id = user_id,
    });
}

/// R1 - request must carry a valid system token
/// R2 - the user must exist, not be deleted and be a bot: otherwise
///      404 "User not found" (missing or deleted) or 409 "User is not a bot"
/// R3 - a new static bot token is generated and stored (hash only); the
///      previous token is revoked and nothing is raised on the bus
const PutTask = struct {
    const Task = root.http.Task;

    pub const Response = struct {
        token: []const u8,
    };

    pub const Payload = struct {
        user_id: root.types.UserId,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    system_token_middleware_task: ?root.middleware.system_token.SystemTokenMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    check_bot_user_task: ?root.repo.users.CheckBotUser.Lazy = null,
    replace_bot_token_task: ?root.repo.tokens.ReplaceBotToken.Lazy = null,
    token: ?[]const u8 = null,
    body: ?[]const u8 = null,
    streamer: ?root.http.Response.Streamer = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *PutTask = @ptrCast(@alignCast(ctx));

        // R1
        // await this.system_token_middleware_task
        {
            if (this.system_token_middleware_task == null) {
                this.system_token_middleware_task = .from(.init(
                    this.request,
                    this.response,
                ));
            }

            while (this.system_token_middleware_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.system_token_middleware_task.?.result) {
                // response handled in the middleware
                return .ready;
            }
        }

        if (this.db == null) {
            this.db = root.db_pool.rent() orelse {
                return .{ .pending = .db };
            };
        }

        const db = this.db.?;

        // R2
        // await this.lookup_task
        {
            if (this.check_bot_user_task == null) {
                this.check_bot_user_task = .from(.init(db, .{
                    .user_id = this.payload.user_id,
                }));
            }

            while (this.check_bot_user_task.?.await()) |res| {
                return res.discard();
            }

            if (this.check_bot_user_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "User not found");
            }

            if (!this.check_bot_user_task.?.result.?) {
                return root.route.generic.responseErrorMessage(this.response, .conflict, "User is not a bot");
            }
        }

        // R3
        if (this.token == null) {
            this.token = root.services.tokens.generateBotToken(this.response.allocator) catch |err| {
                SCOPE.err("PUT failed to generate a bot token: {t}", .{err});

                return .{ .err = err };
            };
        }

        // R3
        // await this.replace_task
        {
            if (this.replace_bot_token_task == null) {
                this.replace_bot_token_task = .from(.init(db, .{
                    .user_id = this.payload.user_id,
                    .token_hash = root.services.tokens.botTokenHash(this.token.?),
                }));
            }

            while (this.replace_bot_token_task.?.await()) |res| {
                return res.discard();
            }
        }

        if (this.body == null) {
            var writer: std.Io.Writer.Allocating = .init(this.response.allocator);

            const item: Response = .{
                .token = this.token.?,
            };

            std.json.fmt(item, .{}).format(&writer.writer) catch |err| {
                SCOPE.err("PUT failed to serialize the response: {t}", .{err});

                return .{ .err = err };
            };

            this.body = writer.written();
        }

        if (this.streamer == null) {
            var writer = this.response.getWriter();

            if (!writer.writeCode(.ok)) {
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
        const this: *PutTask = @ptrCast(@alignCast(ctx));

        if (this.system_token_middleware_task) |*t| {
            t.dispose();
            this.system_token_middleware_task = null;
        }

        if (this.check_bot_user_task) |*t| {
            t.dispose();
            this.check_bot_user_task = null;
        }

        if (this.replace_bot_token_task) |*t| {
            t.dispose();
            this.replace_bot_token_task = null;
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
        const this = try response.allocator.create(PutTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .request = request,
            .response = response,
            .payload = payload,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// PUT /api/system/users/{user_id}
/// R1 - request must carry a valid system token (see the R-list above PutTask)
pub inline fn putHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    user_id: root.types.UserId,
) !root.http.Task {
    _ = allocator;

    return try PutTask.task(request, response, .{
        .user_id = user_id,
    });
}

/// R1 - content type must be application/json (415) and body non-empty (400)
/// R2 - request must carry a valid system token
/// R3 - optional "username": absent = unchanged; a string must be long enough,
///      a valid username, not too long and not reserved; other JSON values
///      (including null) are rejected with 400 "'username' is not a string"
/// R4 - optional "display_name": absent = unchanged, null = clear; a string must
///      be long enough, contain no forbidden codepoints and not be too long
/// R5 - optional "password": absent = unchanged, null = clear (the account
///      becomes passwordless); a string must be within the codepoint and byte
///      limits; other JSON values are rejected with 400
/// R6 - the user must exist and not be deleted (404 "User not found")
/// R7 - a password string is not allowed for bots (400)
/// R8 - the new username must not be taken (409 "Username is already used")
/// R9 - when "password" is present (a string or null) all refresh tokens of the
///      user are revoked and all of the user's push subscriptions are removed
const PatchTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        user_id: root.types.UserId,
    };

    const Content = struct {
        username: ?[]const u8 = null,
        username_set: bool = false,
        display_name: ?[]const u8 = null,
        display_name_set: bool = false,
        password: ?[]const u8 = null,
        password_set: bool = false,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    system_token_middleware_task: ?root.middleware.system_token.SystemTokenMiddleware.Lazy = null,
    content: ?Content = null,
    db: ?*root.db.Connection = null,
    check_bot_user_task: ?root.repo.users.CheckBotUser.Lazy = null,
    hash_password_task: ?root.services.pwhash.HashPassword.Lazy = null,
    update_task: ?root.repo.users.Update.Lazy = null,
    delete_all_task: ?root.repo.tokens.DeleteAll.Lazy = null,
    delete_push_subscriptions_task: ?root.repo.push_subscriptions.DeleteAllForUser.Lazy = null,
    event_raised: bool = false,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *PatchTask = @ptrCast(@alignCast(ctx));

        // R2
        // await this.system_token_middleware_task
        {
            if (this.system_token_middleware_task == null) {
                this.system_token_middleware_task = .from(.init(
                    this.request,
                    this.response,
                ));
            }

            while (this.system_token_middleware_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.system_token_middleware_task.?.result) {
                // response handled in the middleware
                return .ready;
            }
        }

        if (this.content == null) {
            if (!this.request.contentIsAvailable()) {
                return .{ .pending = .want_read };
            }

            const root_value = std.json.parseFromSliceLeaky(std.json.Value, this.response.allocator, this.request.getContent(), .{}) catch {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad JSON");

                return .ready;
            };

            if (root_value != .object) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Expected an object");

                return .ready;
            }

            this.content = .{};

            // R3
            if (root_value.object.get("username")) |username_value| {
                if (username_value != .string) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'username' is not a string");

                    return .ready;
                }

                const username = root.unicode.normalize(this.response.allocator, username_value.string) catch |err| switch (err) {
                    error.InvalidUtf8 => return root.route.generic.responseErrorMessage(this.response, .bad_request, "'username' is invalid"),
                    error.OutOfMemory => return .{ .err = error.OutOfMemory },
                };

                // R3
                if (std.unicode.utf8CountCodepoints(username) catch unreachable <
                    root.options.api.users.min_username_codepoints)
                {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'username' is too short");

                    return .ready;
                }

                // R3
                if (!root.utils.isAsciiUsernameFormat(username)) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'username' is invalid");

                    return .ready;
                }

                // R3
                if (std.unicode.utf8CountCodepoints(username) catch unreachable >
                    root.options.api.users.max_username_codepoints)
                {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'username' is too long");

                    return .ready;
                }

                // R3
                if (root.utils.isReservedUsername(username)) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'username' is reserved");

                    return .ready;
                }

                this.content.?.username = username;
                this.content.?.username_set = true;
            }

            // R4
            if (root_value.object.get("display_name")) |display_name_value| {
                if (display_name_value == .null) {
                    this.content.?.display_name_set = true;
                } else if (display_name_value == .string) {
                    const display_name = root.unicode.normalize(this.response.allocator, display_name_value.string) catch |err| switch (err) {
                        error.InvalidUtf8 => return root.route.generic.responseErrorMessage(this.response, .bad_request, "'display_name' is invalid"),
                        error.OutOfMemory => return .{ .err = error.OutOfMemory },
                    };

                    // R4
                    if (std.unicode.utf8CountCodepoints(display_name) catch unreachable <
                        root.options.api.users.min_display_name_codepoints)
                    {
                        _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'display_name' is too short");

                        return .ready;
                    }

                    // R4
                    if ((root.unicode.findForbiddenCodepoint(.name, display_name) catch null) != null) {
                        _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'display_name' is invalid");

                        return .ready;
                    }

                    // R4
                    if (std.unicode.utf8CountCodepoints(display_name) catch unreachable >
                        root.options.api.users.max_display_name_codepoints)
                    {
                        _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'display_name' is too long");

                        return .ready;
                    }

                    this.content.?.display_name = display_name;
                    this.content.?.display_name_set = true;
                } else {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'display_name' is not a string");

                    return .ready;
                }
            }

            // R5
            if (root_value.object.get("password")) |password_value| {
                if (password_value == .null) {
                    this.content.?.password_set = true;
                } else if (password_value == .string) {
                    if (password_value.string.len > root.options.auth.password.max_password_len) {
                        _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'password' is too long");

                        return .ready;
                    }

                    const password_codepoints = std.unicode.utf8CountCodepoints(password_value.string) catch unreachable;

                    if (password_codepoints < root.options.auth.password.min_password_codepoints) {
                        _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'password' is too short");

                        return .ready;
                    }

                    if (password_codepoints > root.options.auth.password.max_password_codepoints) {
                        _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'password' is too long");

                        return .ready;
                    }

                    this.content.?.password = password_value.string;
                    this.content.?.password_set = true;
                } else {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'password' is not a string");

                    return .ready;
                }
            }
        }

        if (this.db == null) {
            this.db = root.db_pool.rent();

            if (this.db == null) {
                return .{ .pending = .db };
            }
        }

        const db = this.db.?;

        // R6, R7
        // await this.check_bot_user_task
        {
            if (this.check_bot_user_task == null) {
                this.check_bot_user_task = .from(.init(db, .{
                    .user_id = this.payload.user_id,
                }));
            }

            while (this.check_bot_user_task.?.await()) |res| {
                return res.discard();
            }

            if (this.check_bot_user_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "User not found");
            }

            if (this.content.?.password != null and this.check_bot_user_task.?.result.?) {
                return root.route.generic.responseErrorMessage(this.response, .bad_request, "'password' is not allowed for bots");
            }
        }

        // R5
        if (this.content.?.password != null) {
            // await this.hash_password_task
            {
                if (this.hash_password_task == null) {
                    this.hash_password_task = .from(.init(.{
                        .password = this.content.?.password.?,
                    }));
                }

                while (this.hash_password_task.?.await()) |res| {
                    return res.discard();
                }
            }
        }

        // await this.update_task
        {
            if (this.update_task == null) {
                const password_hash = if (this.hash_password_task) |t|
                    t.result
                else
                    null;

                this.update_task = .from(.init(db, .{
                    .user_id = this.payload.user_id,
                    .username = this.content.?.username,
                    .username_set = this.content.?.username_set,
                    .display_name = this.content.?.display_name,
                    .display_name_set = this.content.?.display_name_set,
                    .password_hash = password_hash,
                    .password_hash_set = this.content.?.password_set,
                }));
            }

            while (this.update_task.?.await()) |res| {
                return res.discard();
            }

            // R8
            if (this.update_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .conflict, "Username is already used");
            }
        }

        // R9
        if (this.content.?.password_set) {
            // await this.delete_all_task
            {
                if (this.delete_all_task == null) {
                    this.delete_all_task = .from(.init(db, .{
                        .user_id = this.payload.user_id,
                    }));
                }

                while (this.delete_all_task.?.await()) |res| {
                    return res.discard();
                }
            }

            // await this.delete_push_subscriptions_task
            {
                if (this.delete_push_subscriptions_task == null) {
                    this.delete_push_subscriptions_task = .from(.init(db, .{
                        .user_id = this.payload.user_id,
                    }));
                }

                while (this.delete_push_subscriptions_task.?.await()) |res| {
                    return res.discard();
                }
            }
        }

        if (!this.event_raised and (this.content.?.username_set or
            this.content.?.display_name_set or
            this.content.?.password_set))
        {
            this.event_raised = true;

            root.bus.raise(.{
                .user_updated = .{
                    .id = this.payload.user_id,
                },
            });
        }

        var writer = this.response.getWriter();

        if (!writer.writeCode(.no_content)) {
            return .{ .pending = .want_write };
        }

        if (!writer.emptyBody()) {
            return .{ .pending = .want_write };
        }

        writer.commit();

        return .ready;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *PatchTask = @ptrCast(@alignCast(ctx));

        if (this.system_token_middleware_task) |*t| {
            t.dispose();
            this.system_token_middleware_task = null;
        }

        if (this.check_bot_user_task) |*t| {
            t.dispose();
            this.check_bot_user_task = null;
        }

        if (this.hash_password_task) |*t| {
            t.dispose();
            this.hash_password_task = null;
        }

        if (this.update_task) |*t| {
            t.dispose();
            this.update_task = null;
        }

        if (this.delete_all_task) |*t| {
            t.dispose();
            this.delete_all_task = null;
        }

        if (this.delete_push_subscriptions_task) |*t| {
            t.dispose();
            this.delete_push_subscriptions_task = null;
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
        const this = try response.allocator.create(PatchTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .request = request,
            .response = response,
            .payload = payload,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// PATCH /api/system/users/{user_id}
/// R1 - content type must be application/json (415) and body non-empty (400)
pub inline fn patchHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    user_id: root.types.UserId,
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

    return try PatchTask.task(request, response, .{
        .user_id = user_id,
    });
}
