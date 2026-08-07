// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const plat = @import("plat");

const root = @import("../root.zig");

pub const Event = extern struct {
    ev: plat.struct_kevent,

    pub inline fn read(
        edge_trigger: bool,
        fd: c_int,
        userdata: ?*anyopaque,
    ) Event {
        const flags = if (edge_trigger)
            plat.EV_ADD | plat.EV_ENABLE | plat.EV_CLEAR
        else
            plat.EV_ADD | plat.EV_ENABLE;

        return .{
            .ev = .{
                .ident = @intCast(fd),
                .filter = plat.EVFILT_READ,
                .flags = flags,
                .fflags = 0,
                .data = 0,
                .udata = userdata,
            },
        };
    }

    pub inline fn write(
        edge_trigger: bool,
        fd: c_int,
        userdata: ?*anyopaque,
    ) Event {
        const flags = if (edge_trigger)
            plat.EV_ADD | plat.EV_ENABLE | plat.EV_CLEAR
        else
            plat.EV_ADD | plat.EV_ENABLE;

        return .{
            .ev = .{
                .ident = @intCast(fd),
                .filter = plat.EVFILT_WRITE,
                .flags = flags,
                .fflags = 0,
                .data = 0,
                .udata = userdata,
            },
        };
    }

    pub inline fn isError(this: Event) bool {
        return (this.ev.flags & plat.EV_ERROR) != 0;
    }

    pub inline fn isRead(this: Event) bool {
        return this.ev.filter == plat.EVFILT_READ;
    }

    pub inline fn isWrite(this: Event) bool {
        return this.ev.filter == plat.EVFILT_WRITE;
    }
};

const Queue = extern struct {
    pub const Error = error{
        IoError,
    };

    fd: c_int,

    pub inline fn new() Error!Queue {
        const fd = plat.kqueue();

        if (fd < 0) {
            return Error.IoError;
        }

        return .{
            .fd = fd,
        };
    }

    pub inline fn close(this: Queue) void {
        _ = plat.close(this.fd);
    }

    pub inline fn event(
        this: Queue,
        changelist: []const Event,
        eventlist: []Event,
        timeout_us: ?usize,
    ) Error!usize {
        std.debug.assert(changelist.len < std.math.maxInt(c_int));
        std.debug.assert(eventlist.len < std.math.maxInt(c_int));

        const changelist_ptr: ?*const plat.struct_kevent = if (changelist.len == 0)
            null
        else
            @ptrCast(changelist.ptr);

        const eventlist_ptr: ?*plat.struct_kevent = if (eventlist.len == 0)
            null
        else
            @ptrCast(eventlist.ptr);

        const n = blk: {
            if (timeout_us == null) {
                break :blk plat.kevent(
                    this.fd,
                    changelist_ptr,
                    @intCast(changelist.len),
                    eventlist_ptr,
                    @intCast(eventlist.len),
                    null,
                );
            } else {
                break :blk plat.kevent(
                    this.fd,
                    changelist_ptr,
                    @intCast(changelist.len),
                    eventlist_ptr,
                    @intCast(eventlist.len),
                    &.{
                        .tv_sec = @intCast(@divFloor(timeout_us.?, 1_000_000)),
                        .tv_nsec = @intCast(@rem(timeout_us.?, 1_000_000) * 1_000),
                    },
                );
            }
        };

        if (n < 0) {
            if (root.os.errno() == plat.EINTR) {
                return 0;
            }

            return Error.IoError;
        }

        return @intCast(n);
    }
};

pub const EventType = enum {
    read,
    write,
};

pub const Loop = struct {
    pub const Error = error{
        IoError,
        OutOfMemory,
    };

    queue: Queue,
    events: std.ArrayList(Event) = .empty,
    data: std.ArrayList(root.el.UserData) = .empty,

    pub inline fn init(allocator: std.mem.Allocator) Error!Loop {
        // Peers and async database connections register both a read and a
        // write filter, so they need two events each. The `+ 1` is the
        // listening socket (read only) which is registered alongside them.
        const total_events = (1 + root.options.general.max_peers + root.options.db.pool) * 2;

        var events = try std.ArrayList(Event).initCapacity(allocator, total_events);
        errdefer events.deinit(allocator);

        var data = try std.ArrayList(root.el.UserData).initCapacity(allocator, total_events);
        errdefer data.deinit(allocator);

        const queue = try Queue.new();
        errdefer queue.close();

        return .{
            .queue = queue,
            .events = events,
            .data = data,
        };
    }

    pub inline fn deinit(this: *Loop, allocator: std.mem.Allocator) void {
        this.events.deinit(allocator);
        this.data.deinit(allocator);
        this.queue.close();
    }

    pub inline fn unregisterAll(this: *Loop) void {
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
        switch (ty) {
            .read => return this.registerInner(edge_trigger, fd, .read, userdata),
            .read_write => return this.registerInner(edge_trigger, fd, .read, userdata) and this.registerInner(edge_trigger, fd, .write, userdata),
        }
    }

    inline fn registerInner(
        this: *Loop,
        edge_trigger: bool,
        fd: c_int,
        ty: EventType,
        userdata: root.el.UserData,
    ) bool {
        std.debug.assert(this.events.items.len == this.data.items.len);

        if (this.events.items.len == this.events.capacity) {
            return false;
        }

        this.data.appendAssumeCapacity(userdata);

        const data = &this.data.items[this.data.items.len - 1];
        const event: Event = switch (ty) {
            .read => .read(edge_trigger, fd, data),
            .write => .write(edge_trigger, fd, data),
        };

        this.events.appendAssumeCapacity(event);

        return true;
    }

    pub inline fn wait(this: *const Loop, timeout_us: ?usize) !usize {
        return try this.queue.event(this.events.items, this.events.items, timeout_us);
    }
};
