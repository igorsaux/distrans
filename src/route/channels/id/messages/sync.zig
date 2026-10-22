// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../../../root.zig");

/// R1 - user must be logged
/// R2 - `since`, when present, must be a non-negative epoch-ms integer within
///      the configured lookback window (400 "'since' is invalid" / "'since' is
///      too old")
/// R3 - the channel exists (404 "Channel not found")
/// R4 - user has `read_messages` on the channel (403 "Missing permissions")
///
/// Returns only the ids of present messages changed since `since`. A
/// soft-deleted message keeps its row, so it appears as changed and the client
/// drops it after fetching and observing `deleted_at`.
const GetTask = struct {
    const Task = root.http.Task;

    pub const Payload = struct {
        channel_id: root.types.ChannelId,
        since_raw: ?[]const u8,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    since_ms: ?u64 = null,
    channel_exists_task: ?root.repo.channels.IsExists.Lazy = null,
    check_user_channel_rights_task: ?root.repo.rights.CheckUserChannelRights.Lazy = null,
    sync_task: ?root.repo.sync.Sync.Lazy = null,
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

        // R2
        if (this.since_ms == null) {
            this.since_ms = root.route.generic.parseSince(
                this.payload.since_raw,
                std.Io.Timestamp.now(root.io, .real).toMilliseconds(),
                root.options.api.sync.max_lookback_s,
            ) catch |err| switch (err) {
                error.Invalid => return root.route.generic.responseErrorMessage(this.response, .bad_request, "'since' is invalid"),
                error.TooOld => return root.route.generic.responseErrorMessage(this.response, .bad_request, "'since' is too old"),
            };
        }

        const db = this.db.?;

        // R3
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

        // R4
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

        // await this.sync_task
        {
            if (this.sync_task == null) {
                this.sync_task = .from(root.repo.sync.Sync.init(this.response.allocator, db, .{
                    .scope = .messages,
                    .since_ms = this.since_ms.?,
                    .channel_id = this.payload.channel_id,
                }));
            }

            while (this.sync_task.?.await()) |res| {
                return res.discard();
            }

            this.body = this.sync_task.?.result;
        }

        // Headers once, then drain the body through the streamer: the id array
        // can exceed the uplink buffer, which `writeJSON` would fail to send.
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

        if (this.sync_task) |*t| {
            t.dispose();
            this.sync_task = null;
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

/// GET /api/channels/{channel_id}/messages/sync
pub inline fn getHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    channel_id: root.types.ChannelId,
) !root.http.Task {
    _ = allocator;

    var since_raw: ?[]const u8 = null;

    for (request.params) |kvp| {
        if (std.mem.eql(u8, kvp.key, "since")) {
            if (since_raw != null) {
                return try root.route.generic.badRequestReasonTask(response, "Bad 'since' parameter");
            }

            since_raw = kvp.value;
        } else {
            return try root.route.generic.badRequestReasonTask(response, "Unknown parameter");
        }
    }

    return try GetTask.task(request, response, .{
        .channel_id = channel_id,
        .since_raw = since_raw,
    });
}
