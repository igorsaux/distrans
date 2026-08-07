// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const builtin = @import("builtin");

const plat = @import("plat");

const root = @import("../root.zig");

test "server: accept errno classification" {
    try std.testing.expectEqual(root.net.Server.AcceptAction.stop, root.net.Server.classifyAcceptError(plat.EAGAIN));
    try std.testing.expectEqual(root.net.Server.AcceptAction.stop, root.net.Server.classifyAcceptError(plat.EWOULDBLOCK));
    try std.testing.expectEqual(root.net.Server.AcceptAction.retry, root.net.Server.classifyAcceptError(plat.EINTR));
    try std.testing.expectEqual(root.net.Server.AcceptAction.stop, root.net.Server.classifyAcceptError(plat.EMFILE));
    try std.testing.expectEqual(root.net.Server.AcceptAction.stop, root.net.Server.classifyAcceptError(plat.ENFILE));
    try std.testing.expectEqual(root.net.Server.AcceptAction.stop, root.net.Server.classifyAcceptError(plat.ENOBUFS));
    try std.testing.expectEqual(root.net.Server.AcceptAction.stop, root.net.Server.classifyAcceptError(plat.ENOMEM));
    try std.testing.expectEqual(root.net.Server.AcceptAction.close_and_continue, root.net.Server.classifyAcceptError(plat.ECONNABORTED));
    try std.testing.expectEqual(root.net.Server.AcceptAction.close_and_continue, root.net.Server.classifyAcceptError(plat.EINVAL));
}

test "server: a read that frees the peer does not fall through to drainUplink" {
    // epoll can report readiness for reading and writing in a single event;
    // kqueue reports them as separate filters, so this only reproduces on
    // Linux. A disconnected peer is freed during the read phase, and the write
    // phase must not touch the already-closed socket.
    if (comptime builtin.os.tag == .linux) {
        const allocator = std.testing.allocator;

        var options: root.config.Options = .{};
        options.socket.downlink_buf_size = 64;
        options.socket.uplink_buf_size = 64;
        options.db.pool = 0;

        const prev_options = root.options;
        root.options = &options;
        defer root.options = prev_options;

        var peers = try allocator.alloc(root.net.Peer, 1);
        defer allocator.free(peers);

        peers[0] = try root.net.Peer.init(allocator);
        defer peers[0].deinit(allocator);

        var fds: [2]c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), plat.socketpair(plat.AF_UNIX, plat.SOCK_STREAM, 0, &fds));

        // Close the remote end so the next read reports EOF (a disconnect).
        _ = plat.close(fds[1]);

        peers[0].toConnected(.{ .fd = fds[0] }, std.mem.zeroes(root.net.Socket.Address));

        var server: root.net.Server = .{
            .io = undefined,
            .socket = .{ .fd = -1 },
            .peers = peers,
        };

        const ev: root.el.Event = .{ .ev = .{
            .events = plat.EPOLLIN | plat.EPOLLOUT,
            .data = .{ .ptr = null },
        } };

        const handle: root.el.UserData = .{ .peer = &peers[0] };

        try server.handleEvent(0, ev, &handle, false);

        try std.testing.expect(peers[0].state == .free);
        try std.testing.expect(peers[0].getSocket() == null);
    } else {
        return error.SkipZigTest;
    }
}
