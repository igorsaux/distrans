// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const plat = @import("plat");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.epoll);

pub const Event = extern struct {
    ev: plat.epoll_event,

    pub inline fn read(
        edge_trigger: bool,
        userdata: ?*anyopaque,
    ) Event {
        const events = if (edge_trigger)
            plat.EPOLLIN | plat.EPOLLET
        else
            plat.EPOLLIN;

        return .{
            .ev = .{
                .events = events,
                .data = .{
                    .ptr = userdata,
                },
            },
        };
    }

    pub inline fn readWrite(
        edge_trigger: bool,
        userdata: ?*anyopaque,
    ) Event {
        const events = if (edge_trigger)
            plat.EPOLLOUT | plat.EPOLLIN | plat.EPOLLET
        else
            plat.EPOLLOUT | plat.EPOLLIN;

        return .{
            .ev = .{
                .events = events,
                .data = .{
                    .ptr = userdata,
                },
            },
        };
    }

    pub inline fn isError(this: Event) bool {
        return (this.ev.events & (plat.EPOLLERR | plat.EPOLLHUP)) != 0;
    }

    pub inline fn isRead(this: Event) bool {
        return (this.ev.events & plat.EPOLLIN) != 0;
    }

    pub inline fn isWrite(this: Event) bool {
        return (this.ev.events & plat.EPOLLOUT) != 0;
    }
};

pub const EPoll = extern struct {
    pub const Error = error{
        IoError,
    };

    fd: c_int,

    pub inline fn new() Error!EPoll {
        const fd = plat.epoll_create1(0);

        if (fd < 0) {
            return Error.IoError;
        }

        return .{
            .fd = fd,
        };
    }

    pub inline fn close(this: EPoll) void {
        _ = plat.close(this.fd);
    }

    /// Sleeps for `timeout_us` microseconds, tolerating interruption.
    fn sleepUs(timeout_us: usize) void {
        var remaining = timeout_us;

        while (remaining > 0) {
            // `usleep` only reliably accepts sub-second durations.
            const chunk = @min(remaining, 1_000_000);

            _ = plat.usleep(@intCast(chunk));

            remaining -= chunk;
        }
    }

    pub inline fn wait(this: EPoll, events: []Event, timeout_us: ?usize) Error!usize {
        // `epoll_pwait2` rejects `maxevents <= 0` with EINVAL, whereas `kevent`
        // accepts an empty event list. A loop with nothing registered (e.g. the
        // shutdown drain, after the listening socket is no longer watched) can
        // never be woken, so honor the timeout and report no events.
        if (events.len == 0) {
            if (timeout_us) |us| {
                sleepUs(us);
            }

            return 0;
        }

        const n = if (timeout_us == null)
            plat.epoll_pwait2(this.fd, @ptrCast(events.ptr), @intCast(events.len), null, null)
        else
            plat.epoll_pwait2(this.fd, @ptrCast(events.ptr), @intCast(events.len), &.{
                .tv_sec = @intCast(@divFloor(timeout_us.?, 1_000_000)),
                .tv_nsec = @intCast(@rem(timeout_us.?, 1_000_000) * 1_000),
            }, null);

        if (n < 0) {
            if (root.os.errno() == plat.EINTR) {
                return 0;
            }

            return Error.IoError;
        }

        return @intCast(n);
    }
};

pub const Loop = struct {
    pub const Error = error{
        IoError,
        OutOfMemory,
    };

    const Data = struct {
        fd: c_int,
        userdata: root.el.UserData,
    };

    epoll: EPoll,
    events: std.ArrayList(Event) = .empty,
    data: std.ArrayList(Data) = .empty,

    pub inline fn init(allocator: std.mem.Allocator) Error!Loop {
        // One event per registration: the listening socket, every peer, and
        // every async database connection. The `+ 1` is the server socket,
        // which is registered alongside `max_peers` peers.
        const total_events = 1 + root.options.general.max_peers + root.options.db.pool;

        var events = try std.ArrayList(Event).initCapacity(allocator, total_events);
        errdefer events.deinit(allocator);

        var data = try std.ArrayList(Data).initCapacity(allocator, total_events);
        errdefer data.deinit(allocator);

        const epoll = try EPoll.new();
        errdefer epoll.close();

        return .{
            .epoll = epoll,
            .events = events,
            .data = data,
        };
    }

    pub inline fn deinit(this: *Loop, allocator: std.mem.Allocator) void {
        this.events.deinit(allocator);
        this.data.deinit(allocator);
        this.epoll.close();
    }

    pub inline fn unregisterAll(this: *Loop) void {
        for (this.events.items, 0..) |_, i| {
            const data = &this.data.items[i];

            if (plat.epoll_ctl(this.epoll.fd, plat.EPOLL_CTL_DEL, data.fd, &this.events.items[i].ev) < 0) {
                const errno = root.os.errno();

                // The fd may have been closed or already removed.
                if (errno == plat.EBADF or errno == plat.ENOENT) {
                    continue;
                }

                SCOPE.warn("failed to unregister event: {}", .{errno});
            }
        }

        this.events.items.len = 0;
        this.data.items.len = 0;
    }

    pub inline fn register(
        this: *Loop,
        edge_trigger: bool,
        fd: c_int,
        ty: root.el.EventType,
        userdata: root.el.UserData,
    ) bool {
        std.debug.assert(this.events.items.len == this.data.items.len);

        if (this.events.items.len == this.events.capacity) {
            return false;
        }

        // Fill a reserved slot without committing it yet. If `epoll_ctl` fails
        // we must leave `events` and `data` in sync, otherwise a later
        // `appendAssumeCapacity` can write past the end of `data`.
        const data: *Data = root.el.reserveSlot(Data, &this.data) orelse return false;
        data.* = .{
            .fd = fd,
            .userdata = userdata,
        };

        var event: Event = switch (ty) {
            .read => .read(edge_trigger, &data.userdata),
            .read_write => .readWrite(edge_trigger, &data.userdata),
        };

        if (plat.epoll_ctl(this.epoll.fd, plat.EPOLL_CTL_ADD, fd, &event.ev) < 0) {
            // Callers log the failure in context (which peer/connection); keep
            // the errno at debug level so it is not reported twice.
            SCOPE.debug("failed to register event: {}", .{root.os.errno()});

            return false;
        }

        root.el.commitSlot(Data, &this.data);
        this.events.appendAssumeCapacity(event);

        return true;
    }

    pub inline fn wait(this: *const Loop, timeout_us: ?usize) !usize {
        return try this.epoll.wait(this.events.items, timeout_us);
    }
};
