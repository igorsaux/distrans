// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../root.zig");

/// R1 - user must be logged
/// R2 - `since`, when present, must be a non-negative epoch-ms integer within
///      the configured lookback window (400 "'since' is invalid" / "'since' is
///      too old")
///
/// Global (not per-guild). Returns only the ids of present users changed since
/// `since`. Users are soft-deleted, so a deleted user appears as changed and
/// the client drops it after fetching and observing `deleted_at`.
const GetTask = struct {
    const Task = root.http.Task;

    pub const Payload = struct {
        since_raw: ?[]const u8,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    since_ms: ?u64 = null,
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

        // await this.sync_task
        {
            if (this.sync_task == null) {
                this.sync_task = .from(root.repo.sync.Sync.init(this.response.allocator, this.db.?, .{
                    .scope = .users,
                    .since_ms = this.since_ms.?,
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

/// GET /api/users/sync
pub inline fn getHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
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
        .since_raw = since_raw,
    });
}
