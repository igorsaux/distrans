// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.presence);

/// Tracks which users currently have at least one active gateway (WebSocket)
/// connection. Used by the notification dispatcher to skip delivering a push
/// to a user who is already connected.
///
/// Everything here runs on the single event-loop thread: HTTP/WS tasks and the
/// dispatcher all execute inside `root.tick`, and the notification worker
/// threads never touch presence. No mutex is therefore required.
pub const Registry = struct {
    counts: std.AutoHashMapUnmanaged(root.types.UserId, usize) = .empty,

    pub inline fn init() Registry {
        return .{};
    }

    pub inline fn deinit(this: *Registry) void {
        this.counts.deinit(root.gpa);
    }

    pub inline fn add(this: *Registry, user_id: root.types.UserId) void {
        const entry = this.counts.getOrPut(root.gpa, user_id) catch |err| {
            // Presence is best-effort: a failure only means the user is not
            // tracked and may receive a push while online.
            SCOPE.warn("failed to track '{d}': {t}", .{ user_id, err });

            return;
        };

        if (entry.found_existing) {
            entry.value_ptr.* += 1;
        } else {
            entry.value_ptr.* = 1;
        }
    }

    pub inline fn remove(this: *Registry, user_id: root.types.UserId) void {
        if (this.counts.getPtr(user_id)) |count| {
            if (count.* <= 1) {
                _ = this.counts.remove(user_id);
            } else {
                count.* -= 1;
            }
        }
    }

    pub inline fn isOnline(this: *const Registry, user_id: root.types.UserId) bool {
        return (this.counts.get(user_id) orelse 0) != 0;
    }
};
