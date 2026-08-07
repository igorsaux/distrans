// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../../root.zig");

const SCOPE = std.log.scoped(.@"/api/users/@me/push-subscriptions");

pub const id = @import("push_subscriptions/id.zig");

inline fn decodeFixed(comptime N: usize, encoded: []const u8) ?[N]u8 {
    const size = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded) catch {
        return null;
    };

    if (size != N) {
        return null;
    }

    var out: [N]u8 = undefined;

    std.base64.url_safe_no_pad.Decoder.decode(&out, encoded) catch {
        return null;
    };

    return out;
}

inline fn isValidEndpoint(endpoint: []const u8) bool {
    if (endpoint.len == 0 or endpoint.len > root.options.api.push.max_endpoint_bytes) {
        return false;
    }

    const rest = if (std.mem.startsWith(u8, endpoint, "https://"))
        endpoint["https://".len..]
    else if (std.mem.startsWith(u8, endpoint, "http://"))
        endpoint["http://".len..]
    else
        return false;

    const authority_end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;

    return authority_end != 0;
}

/// R1 - user must be logged (bearer); deleted users are rejected
/// R2 - responds 200 with the caller's subscriptions as an array of
///      `{ id, endpoint, created_at }`; `p256dh` and `auth` are secrets and are
///      never returned
const ListTask = struct {
    pub const Task = root.http.Task;

    const ResponseItem = struct {
        id: []const u8,
        endpoint: []const u8,
        created_at: u64,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    list_task: ?root.repo.push_subscriptions.ListOwn.Lazy = null,
    items: std.ArrayList(ResponseItem) = .empty,
    body: ?[]const u8 = null,
    streamer: ?root.http.Response.Streamer = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *ListTask = @ptrCast(@alignCast(ctx));

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

        // await this.list_task
        {
            if (this.list_task == null) {
                this.list_task = .from(.init(this.response.allocator, this.db.?, .{
                    .user_id = this.bearer_middleware_task.?.result.?,
                }));
            }

            while (this.list_task.?.await()) |res| {
                return res.discard();
            }
        }

        if (this.body == null) {
            // R2
            for (this.list_task.?.result) |row| {
                const id_str = std.fmt.allocPrint(this.response.allocator, "{d}", .{row.id}) catch |err| {
                    SCOPE.err("GET failed to stringify 'id': {t}", .{err});

                    return .{ .err = err };
                };

                this.items.append(this.response.allocator, .{
                    .id = id_str,
                    .endpoint = row.endpoint,
                    .created_at = row.created_at,
                }) catch |err| {
                    SCOPE.err("GET failed to append a subscription: {t}", .{err});

                    return .{ .err = err };
                };
            }

            var writer: std.Io.Writer.Allocating = .init(this.response.allocator);

            std.json.fmt(this.items.items, .{}).format(&writer.writer) catch |err| {
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
        const this: *ListTask = @ptrCast(@alignCast(ctx));

        if (this.bearer_middleware_task) |*t| {
            t.dispose();
            this.bearer_middleware_task = null;
        }

        if (this.list_task) |*t| {
            t.dispose();
            this.list_task = null;
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
        const this = try response.allocator.create(ListTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .request = request,
            .response = response,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// GET /api/users/@me/push-subscriptions
/// R1 - user must be logged (see the R-list above ListTask)
pub inline fn getHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
) !ListTask.Task {
    _ = allocator;

    return try ListTask.task(request, response);
}

/// R1 - content type must be application/json (415) and body non-empty (400)
/// R2 - user must be logged (bearer); deleted users are rejected
/// R3 - the body must be an object with `endpoint`, `p256dh` and `auth` strings;
///      otherwise 400 "'<field>' is not a string"
/// R4 - `endpoint` must be an absolute http(s) URL within `max_endpoint_bytes`
///      (400 "'endpoint' is invalid"); `p256dh` must decode to 65 bytes
///      (400 "'p256dh' is invalid"); `auth` to 16 bytes (400 "'auth' is
///      invalid")
/// R5 - at most `api.push.max_subscriptions_per_user` endpoints per user; at
///      the cap re-posting an endpoint the caller already owns stays allowed,
///      but taking over an endpoint owned by another account is 400
///      "'subscriptions' is too many" (it would put the caller at cap+1)
/// R6 - `endpoint_hash` is globally unique: the subscription is upserted by
///      `endpoint` and, when another account owned that endpoint, it is
///      reassigned to the caller (one browser profile, one account). Responds
///      201 when the caller did not own the endpoint before (fresh insert or
///      takeover) and 200 with the object when the caller already owned it
const CreateTask = struct {
    pub const Task = root.http.Task;

    const Response = struct {
        id: []const u8,
        endpoint: []const u8,
        created_at: u64,
    };

    const Input = struct {
        endpoint: []const u8,
        endpoint_hash: [32]u8,
        p256dh: [65]u8,
        auth: [16]u8,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    input: ?Input = null,
    count_task: ?root.repo.push_subscriptions.CountOwn.Lazy = null,
    exists_task: ?root.repo.push_subscriptions.ExistsEndpoint.Lazy = null,
    create_task: ?root.repo.push_subscriptions.Create.Lazy = null,
    body: ?[]const u8 = null,
    streamer: ?root.http.Response.Streamer = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *CreateTask = @ptrCast(@alignCast(ctx));

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
                // response handled in the middleware
                return .ready;
            }
        }

        // R3, R4
        if (this.input == null) {
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

            const endpoint_value = root_value.object.get("endpoint") orelse {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'endpoint' is not a string");

                return .ready;
            };

            if (endpoint_value != .string) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'endpoint' is not a string");

                return .ready;
            }

            if (!isValidEndpoint(endpoint_value.string)) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'endpoint' is invalid");

                return .ready;
            }

            const p256dh_value = root_value.object.get("p256dh") orelse {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'p256dh' is not a string");

                return .ready;
            };

            if (p256dh_value != .string) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'p256dh' is not a string");

                return .ready;
            }

            const auth_value = root_value.object.get("auth") orelse {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'auth' is not a string");

                return .ready;
            };

            if (auth_value != .string) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'auth' is not a string");

                return .ready;
            }

            const p256dh = decodeFixed(65, p256dh_value.string) orelse {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'p256dh' is invalid");

                return .ready;
            };

            if (!root.services.notifications.isValidP256dh(&p256dh)) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'p256dh' is invalid");

                return .ready;
            }

            const auth = decodeFixed(16, auth_value.string) orelse {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'auth' is invalid");

                return .ready;
            };

            this.input = .{
                .endpoint = endpoint_value.string,
                .endpoint_hash = root.services.notifications.endpointHash(endpoint_value.string),
                .p256dh = p256dh,
                .auth = auth,
            };
        }

        // R5
        // await this.count_task
        {
            if (this.count_task == null) {
                this.count_task = .from(.init(this.db.?, .{
                    .user_id = this.bearer_middleware_task.?.result.?,
                }));
            }

            while (this.count_task.?.await()) |res| {
                return res.discard();
            }
        }

        if (this.count_task.?.result >= root.options.api.push.max_subscriptions_per_user) {
            if (this.exists_task == null) {
                this.exists_task = .from(.init(this.db.?, .{
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .endpoint_hash = this.input.?.endpoint_hash,
                }));
            }

            while (this.exists_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.exists_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .bad_request, "'subscriptions' is too many");
            }
        }

        // R6
        // await this.create_task
        {
            if (this.create_task == null) {
                this.create_task = .from(.init(this.db.?, .{
                    .id = root.sf_generator.generate(),
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .endpoint = this.input.?.endpoint,
                    .endpoint_hash = this.input.?.endpoint_hash,
                    .p256dh = this.input.?.p256dh,
                    .auth = this.input.?.auth,
                }));
            }

            while (this.create_task.?.await()) |res| {
                return res.discard();
            }
        }

        const created = this.create_task.?.result.created;

        if (this.body == null) {
            var writer: std.Io.Writer.Allocating = .init(this.response.allocator);

            const response: Response = .{
                .id = std.fmt.allocPrint(this.response.allocator, "{d}", .{this.create_task.?.result.id}) catch |err| {
                    SCOPE.err("POST failed to stringify 'id': {t}", .{err});

                    return .{ .err = err };
                },
                .endpoint = this.input.?.endpoint,
                .created_at = this.create_task.?.result.created_at,
            };

            std.json.fmt(response, .{}).format(&writer.writer) catch |err| {
                SCOPE.err("POST failed to serialize the response: {t}", .{err});

                return .{ .err = err };
            };

            this.body = writer.written();
        }

        if (this.streamer == null) {
            var writer = this.response.getWriter();

            if (!writer.writeCode(if (created) .created else .ok)) {
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
        const this: *CreateTask = @ptrCast(@alignCast(ctx));

        if (this.bearer_middleware_task) |*t| {
            t.dispose();
            this.bearer_middleware_task = null;
        }

        if (this.count_task) |*t| {
            t.dispose();
            this.count_task = null;
        }

        if (this.exists_task) |*t| {
            t.dispose();
            this.exists_task = null;
        }

        if (this.create_task) |*t| {
            t.dispose();
            this.create_task = null;
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
        const this = try response.allocator.create(CreateTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .request = request,
            .response = response,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// POST /api/users/@me/push-subscriptions
/// R1 - content type must be application/json (415) and body non-empty (400)
///      (see the R-list above CreateTask)
pub inline fn postHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
) !CreateTask.Task {
    _ = allocator;

    // R1
    if (request.getContentLength() == 0) {
        return try root.route.generic.badRequestTask(response);
    }

    // R1
    if (!root.utils.startsWithMaybe(u8, request.content_type, "application/json")) {
        return try root.route.generic.unsupportedMediaTypeTask(response);
    }

    return try CreateTask.task(request, response);
}
