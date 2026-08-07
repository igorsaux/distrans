// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../../../root.zig");

/// R1 - user must be logged (bearer); deleted users are rejected
/// R2 - the subscription must exist and belong to the caller; otherwise
///      404 "Subscription not found"
/// R3 - the subscription is deleted and the response is 204 No Content
const DeleteTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        id: root.types.PushSubscriptionId,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    delete_task: ?root.repo.push_subscriptions.DeleteOwn.Lazy = null,

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

        // R2, R3
        // await this.delete_task
        {
            if (this.delete_task == null) {
                this.delete_task = .from(.init(this.db.?, .{
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .id = this.payload.id,
                }));
            }

            while (this.delete_task.?.await()) |res| {
                return res.discard();
            }
        }

        // R2
        if (!this.delete_task.?.result) {
            return root.route.generic.responseErrorMessage(this.response, .not_found, "Subscription not found");
        }

        // R3
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

        if (this.delete_task) |*t| {
            t.dispose();
            this.delete_task = null;
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

/// DELETE /api/users/@me/push-subscriptions/{subscription_id}
/// R1 - user must be logged (see the R-list above DeleteTask)
pub inline fn deleteHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    subscription_id: root.types.PushSubscriptionId,
) !DeleteTask.Task {
    _ = allocator;

    return try DeleteTask.task(request, response, .{
        .id = subscription_id,
    });
}
