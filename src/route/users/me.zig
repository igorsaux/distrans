// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../root.zig");
pub const avatar = @import("me/avatar.zig");
pub const channels = @import("me/channels.zig");
pub const guilds = @import("me/guilds.zig");
pub const push_subscriptions = @import("me/push_subscriptions.zig");
pub const userdata = @import("me/userdata.zig");

const SCOPE = std.log.scoped(.@"/api/users/@me");

/// R1 - user must be logged
const GetTask = struct {
    pub const Task = root.http.Task;

    pub const Response = struct {
        id: []const u8,
        username: []const u8,
        display_name: ?[]const u8,
        avatar_hash: ?[]const u8,
        is_bot: bool,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    get_user_task: ?root.repo.users.Get.Lazy = null,
    body: ?[]const u8 = null,
    streamer: ?root.http.Response.Streamer = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *GetTask = @ptrCast(@alignCast(ctx));

        if (this.db == null) {
            this.db = root.db_pool.rent() orelse {
                return .{ .pending = .db };
            };
        }

        // R1
        // await this.bearer_middleware_task
        {
            if (this.bearer_middleware_task == null) {
                this.bearer_middleware_task = .from(.init(this.request, this.response, this.db.?));
            }

            while (this.bearer_middleware_task.?.await()) |res| {
                return res.discard();
            }

            if (this.bearer_middleware_task.?.result == null) {
                // response handled in the middleware
                return .ready;
            }
        }

        // await this.get_user_task
        {
            if (this.get_user_task == null) {
                this.get_user_task = .from(.init(this.response.allocator, this.db.?, .{
                    .user_id = this.bearer_middleware_task.?.result.?,
                }));
            }

            while (this.get_user_task.?.await()) |res| {
                return res.discard();
            }

            if (this.get_user_task.?.result == null) {
                SCOPE.err("GET user '{}' does not exist", .{this.bearer_middleware_task.?.result.?});

                return root.route.generic.responseErrorMessage(this.response, .internal_server_error, "User not found");
            }
        }

        if (this.body == null) {
            var writer: std.Io.Writer.Allocating = .init(this.response.allocator);

            const response: Response = .{
                .id = std.fmt.allocPrint(this.response.allocator, "{}", .{this.bearer_middleware_task.?.result.?}) catch |err| {
                    SCOPE.err("GET failed to stringify 'id': {t}", .{err});

                    return .{ .err = err };
                },
                .username = this.get_user_task.?.result.?.username,
                .display_name = this.get_user_task.?.result.?.display_name,
                .avatar_hash = this.get_user_task.?.result.?.avatar_hash,
                .is_bot = this.get_user_task.?.result.?.is_bot,
            };

            std.json.fmt(response, .{}).format(&writer.writer) catch |err| {
                SCOPE.err("GET failed to serialize the response: {t}", .{err});

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
        const this: *GetTask = @ptrCast(@alignCast(ctx));

        if (this.bearer_middleware_task) |*t| {
            t.dispose();
            this.bearer_middleware_task = null;
        }

        if (this.get_user_task) |*t| {
            t.dispose();
            this.get_user_task = null;
        }

        if (this.db) |db| {
            db.release();
            this.db = null;
        }
    }

    pub inline fn task(
        request: *const root.http.Request,
        response: *root.http.Response,
    ) !Task {
        const this = try response.allocator.create(GetTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .request = request,
            .response = response,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// GET /api/users/@me
/// R1 - user must be logged (see the R-list above GetTask)
pub inline fn getHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
) !GetTask.Task {
    _ = allocator;

    return try GetTask.task(request, response);
}

/// R1 - content type must be application/json (415) and body non-empty (400)
/// R2 - request must be authenticated (bearer); deleted users rejected
/// R3 - body must be a JSON object
/// R4 - optional "username": absent = unchanged; must be a string (null → 400 "not a string"),
///      long enough, a valid username format, not too long and not reserved
/// R5 - optional "display_name": absent = unchanged, null = clear; a string must be long enough,
///      contain no forbidden codepoints and not be too long
/// R6 - "current_password" is required for every PATCH and must be a string within the byte cap
///      (auth.password.max_password_len); optional "password" (the new password) must be a
///      string within length limits
/// R7 - the account must have a password; bot and passwordless accounts are rejected with
///      400 "User has no password"
/// R8 - when "password" is present it must differ from "current_password"
///      (400 "'password' must be different from the current password")
/// R9 - "current_password" must match the stored hash (401 "Bad password")
/// R10 - the new "username" must not be taken (409 "Username is already used", SQLSTATE 23505)
/// R11 - on a password change all refresh tokens of the user are revoked except the one in the
///      optional "refresh_token" cookie; without the cookie every refresh token is revoked.
///      Every push subscription of the user is removed as well (the credential changed),
///      so the client must re-register the current device after a successful change.
const PatchTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        refresh_token_hash: ?[32]u8,
    };

    const Content = struct {
        username: ?[]const u8 = null,
        username_set: bool = false,
        display_name: ?[]const u8 = null,
        display_name_set: bool = false,
        current_password: ?[]const u8 = null,
        password: ?[]const u8 = null,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    content: ?Content = null,
    db: ?*root.db.Connection = null,
    verify_password_task: ?root.services.pwhash.VerifyPassword.Lazy = null,
    get_auth_task: ?root.repo.users.GetAuthById.Lazy = null,
    hash_password_task: ?root.services.pwhash.HashPassword.Lazy = null,
    update_task: ?root.repo.users.Update.Lazy = null,
    delete_except_task: ?root.repo.tokens.DeleteExcept.Lazy = null,
    delete_all_task: ?root.repo.tokens.DeleteAll.Lazy = null,
    delete_push_subscriptions_task: ?root.repo.push_subscriptions.DeleteAllForUser.Lazy = null,
    event_raised: bool = false,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *PatchTask = @ptrCast(@alignCast(ctx));

        if (this.db == null) {
            this.db = root.db_pool.rent() orelse {
                return .{ .pending = .db };
            };
        }

        // R2
        // await this.bearer_middleware_task
        {
            if (this.bearer_middleware_task == null) {
                this.bearer_middleware_task = .from(.init(this.request, this.response, this.db.?));
            }

            while (this.bearer_middleware_task.?.await()) |res| {
                return res.discard();
            }

            if (this.bearer_middleware_task.?.result == null) {
                // response handled by middleware
                return .ready;
            }
        }

        if (this.content == null) {
            // R3
            if (!this.request.contentIsAvailable()) {
                return .{ .pending = .want_read };
            }

            const root_value = std.json.parseFromSliceLeaky(std.json.Value, this.response.allocator, this.request.getContent(), .{}) catch {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad JSON");

                return .ready;
            };

            // R3
            if (root_value != .object) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Expected an object");

                return .ready;
            }

            this.content = .{};

            // R4
            if (root_value.object.get("username")) |username_value| {
                if (username_value != .string) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'username' is not a string");

                    return .ready;
                }

                const username = root.unicode.normalize(this.response.allocator, username_value.string) catch |err| switch (err) {
                    error.InvalidUtf8 => return root.route.generic.responseErrorMessage(this.response, .bad_request, "'username' is invalid"),
                    error.OutOfMemory => return .{ .err = error.OutOfMemory },
                };

                // R4
                if (std.unicode.utf8CountCodepoints(username) catch unreachable <
                    root.options.api.users.min_username_codepoints)
                {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'username' is too short");

                    return .ready;
                }

                // R4
                if (!root.utils.isAsciiUsernameFormat(username)) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'username' is invalid");

                    return .ready;
                }

                // R4
                if (std.unicode.utf8CountCodepoints(username) catch unreachable >
                    root.options.api.users.max_username_codepoints)
                {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'username' is too long");

                    return .ready;
                }

                // R4
                if (root.utils.isReservedUsername(username)) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'username' is reserved");

                    return .ready;
                }

                this.content.?.username = username;
                this.content.?.username_set = true;
            }

            // R5
            if (root_value.object.get("display_name")) |display_name_value| {
                if (display_name_value == .null) {
                    this.content.?.display_name_set = true;
                } else if (display_name_value == .string) {
                    const display_name = root.unicode.normalize(this.response.allocator, display_name_value.string) catch |err| switch (err) {
                        error.InvalidUtf8 => return root.route.generic.responseErrorMessage(this.response, .bad_request, "'display_name' is invalid"),
                        error.OutOfMemory => return .{ .err = error.OutOfMemory },
                    };

                    // R5
                    if (std.unicode.utf8CountCodepoints(display_name) catch unreachable <
                        root.options.api.users.min_display_name_codepoints)
                    {
                        _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'display_name' is too short");

                        return .ready;
                    }

                    // R5
                    if ((root.unicode.findForbiddenCodepoint(.name, display_name) catch null) != null) {
                        _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'display_name' is invalid");

                        return .ready;
                    }

                    // R5
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

            // R6
            if (root_value.object.get("password")) |password_value| {
                if (password_value != .string) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'password' is not a string");

                    return .ready;
                }

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
            }

            // R6
            const current_password_value = root_value.object.get("current_password") orelse {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'current_password' is missing");

                return .ready;
            };

            // R6
            if (current_password_value != .string) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'current_password' is not a string");

                return .ready;
            }

            // R6
            if (current_password_value.string.len > root.options.auth.password.max_password_len) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'current_password' is too long");

                return .ready;
            }

            this.content.?.current_password = current_password_value.string;
        }

        // R7
        // await this.get_auth_task
        {
            if (this.get_auth_task == null) {
                this.get_auth_task = .from(.init(this.response.allocator, this.db.?, .{
                    .user_id = this.bearer_middleware_task.?.result.?,
                }));
            }

            while (this.get_auth_task.?.await()) |res| {
                return res.discard();
            }

            if (this.get_auth_task.?.result == null) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "User has no password");

                return .ready;
            }
        }

        // R8
        if (this.content.?.password) |new_password| {
            if (std.mem.eql(u8, new_password, this.content.?.current_password.?)) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'password' must be different from the current password");

                return .ready;
            }
        }

        // R9
        // await this.verify_password_task
        {
            if (this.verify_password_task == null) {
                this.verify_password_task = .from(.init(.{
                    .hash = this.get_auth_task.?.result.?.password_hash,
                    .password = this.content.?.current_password.?,
                }));
            }

            while (this.verify_password_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.verify_password_task.?.result) {
                _ = root.route.generic.responseErrorMessage(this.response, .unauthorized, "Bad password");

                return .ready;
            }
        }

        // R11 - on a password change store the new hash and revoke refresh tokens
        if (this.content.?.password) |new_password| {
            // await this.hash_password_task
            {
                if (this.hash_password_task == null) {
                    this.hash_password_task = .from(.init(.{
                        .password = new_password,
                    }));
                }

                while (this.hash_password_task.?.await()) |res| {
                    return res.discard();
                }
            }
        }

        // R10
        // await this.update_task
        {
            if (this.update_task == null) {
                const password_hash = if (this.hash_password_task) |t|
                    t.result
                else
                    null;

                this.update_task = .from(.init(this.db.?, .{
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .username = this.content.?.username,
                    .username_set = this.content.?.username_set,
                    .display_name = this.content.?.display_name,
                    .display_name_set = this.content.?.display_name_set,
                    .password_hash = password_hash,
                    .password_hash_set = password_hash != null,
                }));
            }

            while (this.update_task.?.await()) |res| {
                return res.discard();
            }

            if (this.update_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .conflict, "Username is already used");
            }
        }

        // R11
        if (this.content.?.password) |_| {
            if (this.payload.refresh_token_hash) |refresh_token_hash| {
                // R11
                // await this.delete_except_task
                {
                    if (this.delete_except_task == null) {
                        this.delete_except_task = .from(.init(this.db.?, .{
                            .user_id = this.bearer_middleware_task.?.result.?,
                            .except_refresh_token_hash = refresh_token_hash,
                        }));
                    }

                    while (this.delete_except_task.?.await()) |res| {
                        return res.discard();
                    }
                }
            } else {
                // R11
                // await this.delete_all_task
                {
                    if (this.delete_all_task == null) {
                        this.delete_all_task = .from(.init(this.db.?, .{
                            .user_id = this.bearer_middleware_task.?.result.?,
                        }));
                    }

                    while (this.delete_all_task.?.await()) |res| {
                        return res.discard();
                    }
                }
            }

            // R11 - a password change invalidates the credential the browser
            // subscriptions were created under, so every push subscription is
            // removed (the client must re-register the current device).
            // await this.delete_push_subscriptions_task
            {
                if (this.delete_push_subscriptions_task == null) {
                    this.delete_push_subscriptions_task = .from(.init(this.db.?, .{
                        .user_id = this.bearer_middleware_task.?.result.?,
                    }));
                }

                while (this.delete_push_subscriptions_task.?.await()) |res| {
                    return res.discard();
                }
            }
        }

        if (!this.event_raised) {
            this.event_raised = true;

            root.bus.raise(.{
                .user_updated = .{
                    .id = this.bearer_middleware_task.?.result.?,
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

        if (this.bearer_middleware_task) |*t| {
            t.dispose();
            this.bearer_middleware_task = null;
        }

        if (this.verify_password_task) |*t| {
            t.dispose();
            this.verify_password_task = null;
        }

        if (this.get_auth_task) |*t| {
            t.dispose();
            this.get_auth_task = null;
        }

        if (this.hash_password_task) |*t| {
            t.dispose();
            this.hash_password_task = null;
        }

        if (this.delete_except_task) |*t| {
            t.dispose();
            this.delete_except_task = null;
        }

        if (this.delete_all_task) |*t| {
            t.dispose();
            this.delete_all_task = null;
        }

        if (this.delete_push_subscriptions_task) |*t| {
            t.dispose();
            this.delete_push_subscriptions_task = null;
        }

        if (this.update_task) |*t| {
            t.dispose();
            this.update_task = null;
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

/// PATCH /api/users/@me
/// R1 - content type must be application/json (415) and body non-empty (400) (see the R-list above PatchTask)
pub inline fn patchHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
) !PatchTask.Task {
    _ = allocator;

    // R1
    if (request.getContentLength() == 0) {
        return try root.route.generic.badRequestTask(response);
    }

    // R1
    if (!root.utils.startsWithMaybe(u8, request.content_type, "application/json")) {
        return try root.route.generic.unsupportedMediaTypeTask(response);
    }

    // R11 - the optional refresh_token cookie scopes the revocation: present → all tokens except
    // it are revoked; absent → every refresh token of the user is revoked
    const refresh_token_hash: ?[32]u8 = root.services.tokens.extractRefreshTokenHash(request.cookies);

    return try PatchTask.task(request, response, .{
        .refresh_token_hash = refresh_token_hash,
    });
}
