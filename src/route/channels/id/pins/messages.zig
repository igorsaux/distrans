// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../../../root.zig");

const SCOPE = std.log.scoped(.@"/api/channels/{channel_id}/pins/messages");

/// R1 - user must be logged
/// R2 - the channel exists
/// R3 - user has rights to view messages
/// R4 - the response is the list of pinned messages (objects, ascending),
///      keyset-paginated with "before"/"after"/"limit"; deleted and unpinned
///      messages are excluded
const GetTask = struct {
    const Task = root.http.Task;

    pub const Payload = struct {
        channel_id: root.types.ChannelId,
        limit: usize,
        mode: root.repo.pins.GetPinnedMessages.Mode,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    channel_exists_task: ?root.repo.channels.IsExists.Lazy = null,
    check_user_channel_rights_task: ?root.repo.rights.CheckUserChannelRights.Lazy = null,
    get_pinned_messages_stream: ?root.repo.pins.GetPinnedMessages.Lazy = null,
    result: std.ArrayList(root.route.types.Message) = .empty,
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
        // await this.get_pinned_messages_stream
        {
            if (this.get_pinned_messages_stream == null) {
                this.get_pinned_messages_stream = .from(.init(db, .{
                    .channel_id = this.payload.channel_id,
                    .limit = this.payload.limit,
                    .mode = this.payload.mode,
                    .user_id = this.bearer_middleware_task.?.result.?,
                }));
            }

            while (this.get_pinned_messages_stream.?.await()) |res| {
                switch (res) {
                    .next => |row| {
                        const message = root.route.types.Message.fromRepo(this.response.allocator, row) catch |err| {
                            return .{ .err = err };
                        };

                        this.result.append(this.response.allocator, message) catch |err| {
                            SCOPE.err("GET failed to append a message: {t}", .{err});

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

        if (this.get_pinned_messages_stream) |*s| {
            s.dispose();
            this.get_pinned_messages_stream = null;
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

/// GET /api/channels/{channel_id}/pins/messages
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
