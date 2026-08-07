// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const plat = @import("plat");

const root = @import("../root.zig");

/// `sun_path` capacity, derived from the struct layout.
const sun_path_len = @sizeOf(plat.sockaddr_un) - @offsetOf(plat.sockaddr_un, "sun_path");

test "socket: unixSockaddr accepts a path at the boundary and rejects one byte more" {
    var buffer: [256]u8 = undefined;

    // The longest bindable path is `sun_path_len - 1` bytes plus its NUL.
    const len = sun_path_len - 1;
    @memset(buffer[0..len], 'a');

    const path = buffer[0..len];

    const sockaddr = try root.net.Socket.unixSockaddr(path);

    try std.testing.expectEqual(@as(c_int, plat.AF_UNIX), @as(c_int, sockaddr.sun_family));
    try std.testing.expectEqual(@as(u8, 0), sockaddr.sun_path[len]);
    try std.testing.expectEqualSlices(u8, path, sockaddr.sun_path[0..len]);

    // One byte more must be rejected, not overflow `sun_path`.
    try std.testing.expectError(error.IoError, root.net.Socket.unixSockaddr(buffer[0 .. len + 1]));
}

test "socket: new rejects an invalid domain and type" {
    try std.testing.expectError(error.IoError, root.net.Socket.new(9999, plat.SOCK_STREAM, 0));
    try std.testing.expectError(error.IoError, root.net.Socket.new(plat.AF_INET6, 9999, 0));
}

test "socket: setNonBlocking is idempotent and fails on a closed fd" {
    const socket = try root.net.Socket.new(plat.AF_INET6, plat.SOCK_STREAM, 0);

    try socket.setNonBlocking();
    try socket.setNonBlocking();

    socket.close();

    try std.testing.expectError(error.IoError, socket.setNonBlocking());
}

test "socket: writing to a closed peer fails instead of crashing" {
    var fds: [2]c_int = undefined;

    try std.testing.expectEqual(@as(c_int, 0), plat.socketpair(plat.AF_UNIX, plat.SOCK_STREAM, 0, &fds));

    const peer = root.net.Socket{ .fd = fds[0] };
    const writer = root.net.Socket{ .fd = fds[1] };

    peer.close();

    try std.testing.expectError(error.IoError, writer.writeAll("hello"));

    writer.close();
}

test "socket: reading from a peer that closed returns EOF" {
    var fds: [2]c_int = undefined;

    try std.testing.expectEqual(@as(c_int, 0), plat.socketpair(plat.AF_UNIX, plat.SOCK_STREAM, 0, &fds));

    const peer = root.net.Socket{ .fd = fds[0] };
    const reader = root.net.Socket{ .fd = fds[1] };

    peer.close();

    var buf: [16]u8 = undefined;
    const data = try reader.read(&buf);

    try std.testing.expectEqual(@as(usize, 0), data.len);

    reader.close();
}
