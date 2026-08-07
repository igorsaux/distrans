// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../../root.zig");

/// R1 - the "hash" query parameter must be present and match the stored hash of an existing
///      (not deleted) user's avatar; otherwise 404 "Avatar not found"
const GetTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        user_id: root.types.UserId,
        hash: ?[]const u8,
    };

    response: *root.http.Response,
    payload: Payload,
    db: ?*root.db.Connection = null,
    get_avatar_task: ?root.repo.users.GetAvatar.Lazy = null,
    streamer: ?root.http.Response.Streamer = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *GetTask = @ptrCast(@alignCast(ctx));

        // R1
        const hash = this.payload.hash orelse {
            return root.route.generic.responseErrorMessage(this.response, .not_found, "Avatar not found");
        };

        if (hash.len == 0) {
            return root.route.generic.responseErrorMessage(this.response, .not_found, "Avatar not found");
        }

        if (this.db == null) {
            this.db = root.db_pool.rent() orelse {
                return .{ .pending = .db };
            };
        }

        // R1
        // await this.get_avatar_task
        {
            if (this.get_avatar_task == null) {
                this.get_avatar_task = .from(.init(this.response.allocator, this.db.?, .{
                    .user_id = this.payload.user_id,
                    .hash = hash,
                }));
            }

            while (this.get_avatar_task.?.await()) |res| {
                return res.discard();
            }

            if (this.get_avatar_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Avatar not found");
            }
        }

        if (this.streamer == null) {
            var writer = this.response.getWriter();

            if (!writer.writeCode(.ok)) {
                return .{ .pending = .want_write };
            }

            if (!writer.writeHeader("Cache-Control", "{s}", .{"private, max-age=31536000, immutable"})) {
                return .{ .pending = .want_write };
            }

            if (!writer.beginBody("image/webp", this.get_avatar_task.?.result.?.len)) {
                return .{ .pending = .want_write };
            }

            writer.commit();
            this.streamer = this.response.getStreamer(this.get_avatar_task.?.result.?);
        }

        return this.streamer.?.poll();
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetTask = @ptrCast(@alignCast(ctx));

        if (this.get_avatar_task) |*t| {
            t.dispose();
            this.get_avatar_task = null;
        }

        if (this.db) |db| {
            db.release();
            this.db = null;
        }
    }

    pub inline fn task(
        response: *root.http.Response,
        payload: Payload,
    ) !Task {
        const this = try response.allocator.create(GetTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .response = response,
            .payload = payload,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// GET /api/users/{user_id}/avatar?hash={hash}
/// Public endpoint: no authentication required.
/// R1 - the "hash" query parameter must match (see the R-list above GetTask)
pub inline fn getHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    user_id: root.types.UserId,
) !GetTask.Task {
    _ = allocator;

    var hash: ?[]const u8 = null;

    for (request.params) |kvp| {
        if (std.mem.eql(u8, kvp.key, "hash")) {
            hash = kvp.value;
        } else {
            return try root.route.generic.badRequestReasonTask(response, "Unknown parameter");
        }
    }

    return try GetTask.task(response, .{
        .user_id = user_id,
        .hash = hash,
    });
}
