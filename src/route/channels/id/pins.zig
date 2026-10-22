// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../../root.zig");
pub const messages = @import("pins/messages.zig");

const SCOPE = std.log.scoped(.@"/api/channels/{channel_id}/pins");

/// R1 - user must be logged
/// R2 - the channel exists
/// R3 - user has rights to view messages
/// R4 - the response is the list of pinned message ids (decimal strings,
///      ascending), keyset-paginated with "before"/"after"/"limit"
const GetTask = struct {
    const Task = root.http.Task;

    pub const Payload = root.repo.pins.GetPins.Payload;

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    channel_exists_task: ?root.repo.channels.IsExists.Lazy = null,
    check_user_channel_rights_task: ?root.repo.rights.CheckUserChannelRights.Lazy = null,
    get_pins_stream: ?root.repo.pins.GetPins.Lazy = null,
    result: std.ArrayList([]const u8) = .empty,
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

        const db = this.db.?;

        // R2
        // await this.channel_exists_task
        {
            if (this.channel_exists_task == null) {
                this.channel_exists_task = .from(.init(db, .{
                    .channel_id = this.payload.channel_id,
                }));
            }

            while (this.channel_exists_task.?.await()) |res| {
                return res.discard();
            }

            if (this.channel_exists_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Channel not found");
            }
        }

        // R3
        // await this.check_user_channel_rights_task
        {
            if (this.check_user_channel_rights_task == null) {
                this.check_user_channel_rights_task = .from(.init(db, .{
                    .guild_id = this.channel_exists_task.?.result.?.guild_id,
                    .channel_id = this.payload.channel_id,
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .required = .{ .read_messages = true },
                }));
            }

            while (this.check_user_channel_rights_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.check_user_channel_rights_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
            }
        }

        // R4
        // await this.get_pins_stream
        {
            if (this.get_pins_stream == null) {
                this.get_pins_stream = .from(.init(db, this.payload));
            }

            while (this.get_pins_stream.?.await()) |res| {
                switch (res) {
                    .next => |id| {
                        const formatted = std.fmt.allocPrint(this.response.allocator, "{}", .{id}) catch |err| {
                            SCOPE.err("GET failed to stringify 'id': {t}", .{err});

                            return .{ .err = err };
                        };

                        this.result.append(this.response.allocator, formatted) catch |err| {
                            SCOPE.err("GET failed to append an item: {t}", .{err});

                            return .{ .err = err };
                        };
                    },
                    .poll => |p| return p.discard(),
                }
            }
        }

        if (this.body == null) {
            var writer: std.Io.Writer.Allocating = .init(this.response.allocator);

            std.json.fmt(this.result.items, .{}).format(&writer.writer) catch |err| {
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

        if (this.channel_exists_task) |*t| {
            t.dispose();
            this.channel_exists_task = null;
        }

        if (this.check_user_channel_rights_task) |*t| {
            t.dispose();
            this.check_user_channel_rights_task = null;
        }

        if (this.get_pins_stream) |*s| {
            s.dispose();
            this.get_pins_stream = null;
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
        const this = try response.allocator.create(GetTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .request = request,
            .response = response,
            .payload = payload,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// GET /api/channels/{channel_id}/pins
/// R1 - limit > 0 and limit <= root.options.api.messages.max_messages_limit
/// R2 - 'before' and 'after' are mutually exclusive
pub inline fn getHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    channel_id: root.types.ChannelId,
) !root.http.Task {
    _ = allocator;

    var limit: ?usize = null;
    var anchors: usize = 0;
    var before: ?usize = null;
    var after: ?usize = null;

    for (request.params) |kvp| {
        if (std.mem.eql(u8, kvp.key, "limit")) {
            limit = std.fmt.parseInt(usize, kvp.value, 10) catch {
                return try root.route.generic.badRequestReasonTask(response, "Bad 'limit' parameter");
            };

            // R1
            if (limit.? == 0 or limit.? > root.options.api.messages.max_messages_limit) {
                return try root.route.generic.badRequestReasonTask(response, "Bad 'limit' parameter");
            }
        } else if (std.mem.eql(u8, kvp.key, "before")) {
            before = std.fmt.parseInt(usize, kvp.value, 10) catch {
                return try root.route.generic.badRequestReasonTask(response, "Bad 'before' parameter");
            };

            anchors += 1;
        } else if (std.mem.eql(u8, kvp.key, "after")) {
            after = std.fmt.parseInt(usize, kvp.value, 10) catch {
                return try root.route.generic.badRequestReasonTask(response, "Bad 'after' parameter");
            };

            anchors += 1;
        } else {
            return try root.route.generic.badRequestReasonTask(response, "Unknown parameter");
        }
    }

    // R2
    if (anchors > 1) {
        return try root.route.generic.badRequestReasonTask(
            response,
            "Parameters 'before' and 'after' are mutually exclusive",
        );
    }

    return try GetTask.task(request, response, .{
        .channel_id = channel_id,
        .limit = limit orelse 50,
        .mode = if (before != null)
            .{ .before = before.? }
        else if (after != null)
            .{ .after = after.? }
        else
            .last,
    });
}

/// R1 - user must be logged
/// R2 - the channel exists
/// R3 - user has rights to view messages and add pins
/// R4 - the message exists, belongs to the channel and is not deleted
///      (else 404 "Message not found")
/// R5 - the message is pinned (idempotent); a real transition dispatches a
///      message_pinned gateway event and the request succeeds with 204
const PutTask = struct {
    const Task = root.http.Task;

    pub const Payload = struct {
        channel_id: root.types.ChannelId,
        message_id: root.types.MessageId,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    channel_exists_task: ?root.repo.channels.IsExists.Lazy = null,
    check_user_channel_rights_task: ?root.repo.rights.CheckUserChannelRights.Lazy = null,
    message_exists_task: ?root.repo.messages.IsExists.Lazy = null,
    pin_task: ?root.repo.pins.Pin.Lazy = null,
    audit_log: ?root.repo.audit_log.Insert.Lazy = null,
    audit_entries: [1]root.repo.audit_log.Insert.Entry = undefined,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *PutTask = @ptrCast(@alignCast(ctx));

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

        const db = this.db.?;

        // R2
        // await this.channel_exists_task
        {
            if (this.channel_exists_task == null) {
                this.channel_exists_task = .from(.init(db, .{
                    .channel_id = this.payload.channel_id,
                }));
            }

            while (this.channel_exists_task.?.await()) |res| {
                return res.discard();
            }

            if (this.channel_exists_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Channel not found");
            }
        }

        // R3
        // await this.check_user_channel_rights_task
        {
            if (this.check_user_channel_rights_task == null) {
                this.check_user_channel_rights_task = .from(.init(db, .{
                    .guild_id = this.channel_exists_task.?.result.?.guild_id,
                    .channel_id = this.payload.channel_id,
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .required = .{ .read_messages = true, .add_pins = true },
                }));
            }

            while (this.check_user_channel_rights_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.check_user_channel_rights_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
            }
        }

        // R4
        // await this.message_exists_task
        {
            if (this.message_exists_task == null) {
                this.message_exists_task = .from(.init(db, .{
                    .id = this.payload.message_id,
                }));
            }

            while (this.message_exists_task.?.await()) |res| {
                return res.discard();
            }

            if (this.message_exists_task.?.result == null or
                this.message_exists_task.?.result.?.channel_id != this.payload.channel_id)
            {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Message not found");
            }
        }

        // R5
        // await this.pin_task
        {
            if (this.pin_task == null) {
                this.pin_task = .from(.init(db, .{
                    .channel_id = this.payload.channel_id,
                    .message_id = this.payload.message_id,
                }));
            }

            while (!this.pin_task.?.done) {
                if (this.pin_task.?.await()) |res| {
                    return res.discard();
                }

                if (this.pin_task.?.result) {
                    root.bus.raise(.{
                        .message_pinned = .{
                            .id = this.payload.message_id,
                            .channel_id = this.payload.channel_id,
                            .guild_id = this.channel_exists_task.?.result.?.guild_id,
                        },
                    });
                }
            }
        }

        if (this.pin_task.?.result) {
            // await this.audit_log
            {
                if (this.audit_log == null) {
                    this.audit_entries[0] = .{
                        .action = .message_pin,
                        .target_id = this.payload.message_id,
                        .channel_id = this.payload.channel_id,
                    };

                    this.audit_log = .from(root.repo.audit_log.Insert.init(this.db.?, this.response.allocator, .{
                        .guild_id = this.channel_exists_task.?.result.?.guild_id,
                        .actor_id = this.bearer_middleware_task.?.result.?,
                        .entries = this.audit_entries[0..1],
                    }));
                }

                while (this.audit_log.?.await()) |res| {
                    return res.discard();
                }
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
        const this: *PutTask = @ptrCast(@alignCast(ctx));

        if (this.bearer_middleware_task) |*t| {
            t.dispose();
            this.bearer_middleware_task = null;
        }

        if (this.channel_exists_task) |*t| {
            t.dispose();
            this.channel_exists_task = null;
        }

        if (this.check_user_channel_rights_task) |*t| {
            t.dispose();
            this.check_user_channel_rights_task = null;
        }

        if (this.message_exists_task) |*t| {
            t.dispose();
            this.message_exists_task = null;
        }

        if (this.pin_task) |*t| {
            t.dispose();
            this.pin_task = null;
        }

        if (this.audit_log) |*a| {
            a.dispose();
            this.audit_log = null;
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

/// PUT /api/channels/{channel_id}/pins/{message_id}
/// R1 - user must be logged (see the R-list above PutTask)
pub inline fn putHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    channel_id: root.types.ChannelId,
    message_id: root.types.MessageId,
) !root.http.Task {
    _ = allocator;

    return try PutTask.task(request, response, .{
        .channel_id = channel_id,
        .message_id = message_id,
    });
}

/// R1 - user must be logged
/// R2 - the channel exists
/// R3 - user has rights to view messages and delete pins
/// R4 - the message exists, belongs to the channel and is not deleted
///      (else 404 "Message not found")
/// R5 - the message is unpinned (idempotent); a real transition dispatches a
///      message_unpinned gateway event and the request succeeds with 204
const DeleteTask = struct {
    const Task = root.http.Task;

    pub const Payload = struct {
        channel_id: root.types.ChannelId,
        message_id: root.types.MessageId,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    channel_exists_task: ?root.repo.channels.IsExists.Lazy = null,
    check_user_channel_rights_task: ?root.repo.rights.CheckUserChannelRights.Lazy = null,
    message_exists_task: ?root.repo.messages.IsExists.Lazy = null,
    unpin_task: ?root.repo.pins.Unpin.Lazy = null,
    audit_log: ?root.repo.audit_log.Insert.Lazy = null,
    audit_entries: [1]root.repo.audit_log.Insert.Entry = undefined,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *DeleteTask = @ptrCast(@alignCast(ctx));

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

        const db = this.db.?;

        // R2
        // await this.channel_exists_task
        {
            if (this.channel_exists_task == null) {
                this.channel_exists_task = .from(.init(db, .{
                    .channel_id = this.payload.channel_id,
                }));
            }

            while (this.channel_exists_task.?.await()) |res| {
                return res.discard();
            }

            if (this.channel_exists_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Channel not found");
            }
        }

        // R3
        // await this.check_user_channel_rights_task
        {
            if (this.check_user_channel_rights_task == null) {
                this.check_user_channel_rights_task = .from(.init(db, .{
                    .guild_id = this.channel_exists_task.?.result.?.guild_id,
                    .channel_id = this.payload.channel_id,
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .required = .{ .read_messages = true, .delete_pins = true },
                }));
            }

            while (this.check_user_channel_rights_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.check_user_channel_rights_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
            }
        }

        // R4
        // await this.message_exists_task
        {
            if (this.message_exists_task == null) {
                this.message_exists_task = .from(.init(db, .{
                    .id = this.payload.message_id,
                }));
            }

            while (this.message_exists_task.?.await()) |res| {
                return res.discard();
            }

            if (this.message_exists_task.?.result == null or
                this.message_exists_task.?.result.?.channel_id != this.payload.channel_id)
            {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Message not found");
            }
        }

        // R5
        // await this.unpin_task
        {
            if (this.unpin_task == null) {
                this.unpin_task = .from(.init(db, .{
                    .channel_id = this.payload.channel_id,
                    .message_id = this.payload.message_id,
                }));
            }

            while (!this.unpin_task.?.done) {
                if (this.unpin_task.?.await()) |res| {
                    return res.discard();
                }

                if (this.unpin_task.?.result) {
                    root.bus.raise(.{
                        .message_unpinned = .{
                            .id = this.payload.message_id,
                            .channel_id = this.payload.channel_id,
                            .guild_id = this.channel_exists_task.?.result.?.guild_id,
                        },
                    });
                }
            }
        }

        if (this.unpin_task.?.result) {
            // await this.audit_log
            {
                if (this.audit_log == null) {
                    this.audit_entries[0] = .{
                        .action = .message_unpin,
                        .target_id = this.payload.message_id,
                        .channel_id = this.payload.channel_id,
                    };

                    this.audit_log = .from(root.repo.audit_log.Insert.init(this.db.?, this.response.allocator, .{
                        .guild_id = this.channel_exists_task.?.result.?.guild_id,
                        .actor_id = this.bearer_middleware_task.?.result.?,
                        .entries = this.audit_entries[0..1],
                    }));
                }

                while (this.audit_log.?.await()) |res| {
                    return res.discard();
                }
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

        if (this.bearer_middleware_task) |*t| {
            t.dispose();
            this.bearer_middleware_task = null;
        }

        if (this.channel_exists_task) |*t| {
            t.dispose();
            this.channel_exists_task = null;
        }

        if (this.check_user_channel_rights_task) |*t| {
            t.dispose();
            this.check_user_channel_rights_task = null;
        }

        if (this.message_exists_task) |*t| {
            t.dispose();
            this.message_exists_task = null;
        }

        if (this.unpin_task) |*t| {
            t.dispose();
            this.unpin_task = null;
        }

        if (this.audit_log) |*a| {
            a.dispose();
            this.audit_log = null;
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

/// DELETE /api/channels/{channel_id}/pins/{message_id}
/// R1 - user must be logged (see the R-list above DeleteTask)
pub inline fn deleteHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    channel_id: root.types.ChannelId,
    message_id: root.types.MessageId,
) !root.http.Task {
    _ = allocator;

    return try DeleteTask.task(request, response, .{
        .channel_id = channel_id,
        .message_id = message_id,
    });
}
