// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const builtin = @import("builtin");

const plat = @import("plat");

const root = @import("../root.zig");

var stop_spam: std.atomic.Value(bool) = .init(false);

fn noopSignalHandler(signum: c_int) callconv(.c) void {
    _ = signum;
}

fn spamSignals() void {
    var i: usize = 0;

    while (i < 100 and !stop_spam.load(.acquire)) : (i += 1) {
        _ = plat.kill(plat.getpid(), plat.SIGUSR1);
        _ = plat.usleep(1_000);
    }
}

test "el: register and unregister keep events and data in sync" {
    const allocator = std.testing.allocator;

    var options: root.config.Options = .{};
    options.general.max_peers = 4;
    options.db.pool = 0;

    const prev_options = root.options;
    root.options = &options;
    defer root.options = prev_options;

    var loop = try root.el.EventLoop.init(allocator);
    defer loop.deinit(allocator);

    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), plat.socketpair(plat.AF_UNIX, plat.SOCK_STREAM, 0, &fds));

    const socket = root.net.Socket{ .fd = fds[0] };
    const other = root.net.Socket{ .fd = fds[1] };

    try std.testing.expect(loop.register(true, socket.fd, .read, .{ .socket = {} }));
    try std.testing.expectEqual(loop.events.items.len, loop.data.items.len);
    try std.testing.expectEqual(@as(usize, 1), loop.events.items.len);

    // A duplicate registration must never desynchronize the two arrays (on
    // Linux `epoll_ctl(ADD)` fails with EEXIST; on kqueue it succeeds).
    _ = loop.register(true, socket.fd, .read, .{ .socket = {} });
    try std.testing.expectEqual(loop.events.items.len, loop.data.items.len);

    loop.unregisterAll();
    try std.testing.expectEqual(@as(usize, 0), loop.events.items.len);
    try std.testing.expectEqual(@as(usize, 0), loop.data.items.len);

    socket.close();
    other.close();
}

test "el: reserveSlot/commitSlot keep parallel arrays in sync" {
    const allocator = std.testing.allocator;

    var events: std.ArrayList(u32) = .empty;
    defer events.deinit(allocator);

    var data: std.ArrayList(u64) = .empty;
    defer data.deinit(allocator);

    try events.ensureTotalCapacityPrecise(allocator, 2);
    try data.ensureTotalCapacityPrecise(allocator, 2);

    // Regression: an empty list has `items.len == 0` while `capacity == 2`;
    // reserving must return a writable spare slot, not index `items[0]`.
    const slot = root.el.reserveSlot(u64, &data).?;
    slot.* = 42;

    // Nothing is committed yet, so an abandoned (failed backend) reservation
    // leaves the length untouched.
    try std.testing.expectEqual(@as(usize, 0), data.items.len);

    // The same spare slot is handed out again.
    try std.testing.expectEqual(slot, root.el.reserveSlot(u64, &data).?);

    // Commit once, with the caller appending the matching event.
    root.el.commitSlot(u64, &data);
    events.appendAssumeCapacity(7);

    try std.testing.expectEqual(events.items.len, data.items.len);
    try std.testing.expectEqual(@as(u64, 42), data.items[0]);

    // One spare slot left: the next reserve succeeds, then the list is full.
    try std.testing.expect(root.el.reserveSlot(u64, &data) != null);
    root.el.commitSlot(u64, &data);
    events.appendAssumeCapacity(8);

    try std.testing.expect(root.el.reserveSlot(u64, &data) == null);
    try std.testing.expectEqual(events.items.len, data.items.len);
}

test "el: capacity covers the server socket, every peer and every db connection" {
    const allocator = std.testing.allocator;

    const max_peers = 4;
    const db_pool = 2;

    var options: root.config.Options = .{};
    options.general.max_peers = max_peers;
    options.db.pool = db_pool;

    const prev_options = root.options;
    root.options = &options;
    defer root.options = prev_options;

    var loop = try root.el.EventLoop.init(allocator);
    defer loop.deinit(allocator);

    // Worst case for a tick: the listening socket (read), `max_peers` peers
    // (read+write) and `db_pool` async connections (read+write).
    const total = 1 + max_peers + db_pool;

    var fds: [total * 2]c_int = undefined;

    var i: usize = 0;
    while (i < total) : (i += 1) {
        try std.testing.expectEqual(
            @as(c_int, 0),
            plat.socketpair(plat.AF_UNIX, plat.SOCK_STREAM, 0, fds[i * 2 ..][0..2]),
        );
    }

    defer {
        i = 0;
        while (i < total * 2) : (i += 1) {
            _ = plat.close(fds[i]);
        }
    }

    // The listening socket is read-only.
    try std.testing.expect(loop.register(true, fds[0], .read, .{ .socket = {} }));

    // Peers and database connections use read+write, which is two events per
    // socket on kqueue.
    i = 0;
    while (i < max_peers + db_pool) : (i += 1) {
        try std.testing.expect(loop.register(true, fds[(i + 1) * 2], .read_write, .{ .socket = {} }));
    }

    try std.testing.expectEqual(loop.events.items.len, loop.data.items.len);
}

test "el: a signal interrupts wait without surfacing an error" {
    const allocator = std.testing.allocator;

    var options: root.config.Options = .{};
    options.general.max_peers = 4;
    options.db.pool = 0;

    const prev_options = root.options;
    root.options = &options;
    defer root.options = prev_options;

    var loop = try root.el.EventLoop.init(allocator);
    defer loop.deinit(allocator);

    // Register a watch so `wait` actually blocks in the backend instead of
    // returning immediately on an empty event set.
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), plat.socketpair(plat.AF_UNIX, plat.SOCK_STREAM, 0, &fds));

    const socket = root.net.Socket{ .fd = fds[0] };
    const other = root.net.Socket{ .fd = fds[1] };

    defer {
        socket.close();
        other.close();
    }

    try std.testing.expect(loop.register(true, socket.fd, .read, .{ .socket = {} }));

    const handler: plat.struct_sigaction = if (builtin.os.tag == .macos or builtin.os.tag == .freebsd)
        .{ .__sigaction_u = .{ .__sa_handler = noopSignalHandler } }
    else if (builtin.os.tag == .linux)
        .{ .__sigaction_handler = .{ .sa_handler = noopSignalHandler } }
    else
        @compileError("Not implemented");

    var old: plat.struct_sigaction = undefined;
    _ = plat.sigaction(plat.SIGUSR1, &handler, &old);
    defer _ = plat.sigaction(plat.SIGUSR1, &old, null);

    const thread = try std.Thread.spawn(.{}, spamSignals, .{});
    defer {
        stop_spam.store(true, .release);
        thread.join();
    }

    // Every wait must return 0 (EINTR) rather than error.IoError.
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const n = try loop.wait(5_000);
        _ = n;
    }
}

test "el: waiting with no registered events reports none instead of failing" {
    const allocator = std.testing.allocator;

    var options: root.config.Options = .{};
    options.general.max_peers = 4;
    options.db.pool = 0;

    const prev_options = root.options;
    root.options = &options;
    defer root.options = prev_options;

    var loop = try root.el.EventLoop.init(allocator);
    defer loop.deinit(allocator);

    // Regression: `epoll_pwait2` rejects a zero `maxevents` with EINVAL while
    // `kevent` accepts an empty event list, so a backend-agnostic empty wait
    // must report no events rather than error.
    try std.testing.expectEqual(@as(usize, 0), try loop.wait(0));
    try std.testing.expectEqual(@as(usize, 0), try loop.wait(1_000));
}
