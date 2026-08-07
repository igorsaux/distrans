// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../root.zig");
pub const id = @import("users/id.zig");

const SCOPE = std.log.scoped(.@"/api/system/users");

/// R2 - request must carry a valid system token
/// R3 - "username" must be present, a string, long enough, a valid username,
///      not too long and not reserved
/// R4 - "password" must be optional: if present, a string, long enough (in
///      codepoints) and not too long (in codepoints and in bytes)
/// R5 - optional "display_name" must be a string, long enough, contain no
///      forbidden codepoints and not be too long
/// R6 - optional "id" must be a string parseable as a user id
/// R7 - the user must not already exist (username or id in use)
/// R8 - optional "is_bot" must be a boolean; a bot must not have a password
const PostTask = struct {
    const Task = root.http.Task;

    pub const Response = struct {
        id: []const u8,
    };

    const Content = struct {
        id: ?root.types.UserId,
        username: []const u8,
        password: ?[]const u8,
        is_bot: bool = false,
        display_name: ?[]const u8,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    system_token_middleware_task: ?root.middleware.system_token.SystemTokenMiddleware.Lazy = null,
    content: ?Content = null,
    db: ?*root.db.Connection = null,
    hash_password_task: ?root.services.pwhash.HashPassword.Lazy = null,
    user_id: ?root.types.UserId = null,
    create_user_task: ?root.repo.users.Create.Lazy = null,
    body: ?[]const u8 = null,
    streamer: ?root.http.Response.Streamer = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *PostTask = @ptrCast(@alignCast(ctx));

        // R2
        // await this.system_token_middleware
        {
            if (this.system_token_middleware_task == null) {
                this.system_token_middleware_task = .from(.init(this.request, this.response));
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

            const body = std.json.parseFromSliceLeaky(std.json.Value, this.response.allocator, this.request.getContent(), .{}) catch {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad JSON");

                return .ready;
            };

            if (body != .object) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Expected an object");

                return .ready;
            }

            // R3
            const username_value = body.object.get("username") orelse {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'username' is missing");

                return .ready;
            };

            if (username_value != .string) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'username' is not a string");

                return .ready;
            }

            // R3
            const username = root.unicode.normalize(this.response.allocator, username_value.string) catch |err| switch (err) {
                error.InvalidUtf8 => return root.route.generic.responseErrorMessage(this.response, .bad_request, "'username' is invalid"),
                error.OutOfMemory => return .{ .err = error.OutOfMemory },
            };

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

            // R8
            const is_bot_value = body.object.get("is_bot");

            // R8
            if (is_bot_value != null and is_bot_value.? != .bool) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'is_bot' is not a boolean");

                return .ready;
            }

            const is_bot = if (is_bot_value != null)
                is_bot_value.?.bool
            else
                false;

            // R4
            const password_value = body.object.get("password");

            // R4
            if (password_value != null and password_value.? != .string) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'password' is not a string");

                return .ready;
            }

            // R8
            if (is_bot and password_value != null) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'password' is not allowed for bots");

                return .ready;
            }

            // R4
            if (password_value != null) {
                const password_codepoints = std.unicode.utf8CountCodepoints(password_value.?.string) catch unreachable;

                // R4
                if (password_codepoints < root.options.auth.password.min_password_codepoints) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'password' is too short");

                    return .ready;
                }

                // R4
                if (password_codepoints > root.options.auth.password.max_password_codepoints or
                    password_value.?.string.len > root.options.auth.password.max_password_len)
                {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'password' is too long");

                    return .ready;
                }
            }

            // R5
            const display_name = body.object.get("display_name");

            if (display_name != null and display_name.? != .string) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'display_name' is not a string");

                return .ready;
            }

            const display_name_text: ?[]const u8 = if (display_name) |value|
                root.unicode.normalize(this.response.allocator, value.string) catch |err| switch (err) {
                    error.InvalidUtf8 => return root.route.generic.responseErrorMessage(this.response, .bad_request, "'display_name' is invalid"),
                    error.OutOfMemory => return .{ .err = error.OutOfMemory },
                }
            else
                null;

            // R5
            if (display_name_text != null and std.unicode.utf8CountCodepoints(display_name_text.?) catch unreachable <
                root.options.api.users.min_display_name_codepoints)
            {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'display_name' is too short");

                return .ready;
            }

            // R5
            if (display_name_text != null and (root.unicode.findForbiddenCodepoint(.name, display_name_text.?) catch null) != null) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'display_name' is invalid");

                return .ready;
            }

            // R5
            if (display_name_text != null and std.unicode.utf8CountCodepoints(display_name_text.?) catch unreachable >
                root.options.api.users.max_display_name_codepoints)
            {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'display_name' is too long");

                return .ready;
            }

            // R6
            const id_value = body.object.get("id");

            // R6
            if (id_value != null and id_value.? != .string) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'id' is not a string");

                return .ready;
            }

            // R6
            const custom_id = if (id_value == null)
                null
            else
                std.fmt.parseInt(root.types.UserId, id_value.?.string, 10) catch {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad 'id'");

                    return .ready;
                };

            this.content = .{
                .id = custom_id,
                .username = username,
                .password = if (password_value != null)
                    password_value.?.string
                else
                    null,
                .is_bot = is_bot,
                .display_name = display_name_text,
            };
        }

        if (this.db == null) {
            this.db = root.db_pool.rent();

            if (this.db == null) {
                return .{ .pending = .db };
            }
        }

        const db = this.db.?;

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

        if (this.user_id == null) {
            if (this.content.?.id) |custom_id| {
                this.user_id = custom_id;
            } else {
                this.user_id = root.sf_generator.generate();
            }
        }

        // await this.create_user_task
        {
            if (this.create_user_task == null) {
                const password_hash = if (this.hash_password_task) |t|
                    t.result
                else
                    null;

                this.create_user_task = .from(.init(db, .{
                    .id = this.user_id.?,
                    .username = this.content.?.username,
                    .password_hash = password_hash,
                    .is_bot = this.content.?.is_bot,
                    .display_name = this.content.?.display_name,
                }));
            }

            while (!this.create_user_task.?.done) {
                if (this.create_user_task.?.await()) |res| {
                    return res.discard();
                }

                if (this.create_user_task.?.result != null) {
                    root.bus.raise(.{
                        .user_created = .{
                            .id = this.user_id.?,
                        },
                    });
                }
            }

            // R7
            if (this.create_user_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .conflict, "Username or id is already used");
            }
        }

        if (this.body == null) {
            var writer: std.Io.Writer.Allocating = .init(this.response.allocator);

            const item: Response = .{
                .id = std.fmt.allocPrint(this.response.allocator, "{}", .{this.user_id.?}) catch |err| {
                    SCOPE.err("POST failed to stringify 'id': {t}", .{err});

                    return .{ .err = err };
                },
            };

            std.json.fmt(item, .{}).format(&writer.writer) catch |err| {
                SCOPE.err("POST failed to serialize the response: {t}", .{err});

                return .{ .err = err };
            };

            this.body = writer.written();
        }

        if (this.streamer == null) {
            var writer = this.response.getWriter();

            if (!writer.writeCode(.created)) {
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

        if (this.system_token_middleware_task) |*t| {
            t.dispose();
            this.system_token_middleware_task = null;
        }

        if (this.hash_password_task) |*t| {
            t.dispose();
            this.hash_password_task = null;
        }

        if (this.create_user_task) |*t| {
            t.dispose();
            this.create_user_task = null;
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

/// POST /api/system/users
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
