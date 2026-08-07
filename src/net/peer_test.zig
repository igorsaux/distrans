// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const plat = @import("plat");

const root = @import("../root.zig");
const Peer = root.net.Peer;

/// Swaps in a minimal `root.options`/`root.io` for the duration of a test.
/// `Peer.init` sizes its buffers from the options, and `toClosing`/`toShutdown`
/// read the clock through `root.io`.
const TestEnv = struct {
    options: root.config.Options,
    prev_options: *const root.config.Options,
    prev_io: std.Io,

    fn init(this: *TestEnv) void {
        this.options = .{};
        this.options.socket.downlink_buf_size = 64;
        this.options.socket.uplink_buf_size = 64;
        this.options.db.pool = 0;

        this.prev_options = root.options;
        this.prev_io = root.io;

        root.options = &this.options;
        root.io = std.testing.io;
    }

    fn deinit(this: *TestEnv) void {
        root.options = this.prev_options;
        root.io = this.prev_io;
    }
};

/// A bare, unconnected fd; the peer only ever closes or shuts it down.
fn freshSocket() !root.net.Socket {
    return root.net.Socket.new(plat.AF_INET6, plat.SOCK_STREAM, 0);
}

fn zeroAddress() root.net.Socket.Address {
    return std.mem.zeroes(root.net.Socket.Address);
}

test "peer: toFree is idempotent and gen increments per connection" {
    var env: TestEnv = undefined;
    env.init();
    defer env.deinit();

    var peer = try Peer.init(std.testing.allocator);
    defer peer.deinit(std.testing.allocator);

    try std.testing.expect(peer.getSocket() == null);
    try std.testing.expectEqual(@as(usize, 0), peer.gen);

    peer.toConnected(try freshSocket(), zeroAddress());
    try std.testing.expectEqual(@as(usize, 1), peer.gen);
    try std.testing.expect(peer.isConnected());

    peer.toFree();
    try std.testing.expect(peer.getSocket() == null);
    try std.testing.expect(!peer.isConnected());

    // Freeing twice must not close a bogus fd.
    peer.toFree();
    try std.testing.expect(peer.getSocket() == null);

    peer.toConnected(try freshSocket(), zeroAddress());
    try std.testing.expectEqual(@as(usize, 2), peer.gen);

    peer.toFree();
}

test "peer: buffers and stats reset on a new connection" {
    var env: TestEnv = undefined;
    env.init();
    defer env.deinit();

    const allocator = std.testing.allocator;

    var peer = try Peer.init(allocator);
    defer peer.deinit(allocator);

    peer.toConnected(try freshSocket(), zeroAddress());
    try peer.downlink.appendSlice(allocator, "stale");
    try peer.uplink.appendSlice(allocator, "stale");
    peer.stats.last_rx_at_ms = 123;
    peer.stats.last_tx_at_ms = 456;

    peer.toFree();
    peer.toConnected(try freshSocket(), zeroAddress());

    try std.testing.expectEqual(@as(usize, 0), peer.downlink.items.len);
    try std.testing.expectEqual(@as(usize, 0), peer.uplink.items.len);

    peer.updateConnectedAt(7);
    try std.testing.expectEqual(@as(u64, 7), peer.stats.connected_at_ms);
    try std.testing.expectEqual(@as(u64, 7), peer.stats.last_rx_at_ms);
    try std.testing.expectEqual(@as(u64, 7), peer.stats.last_tx_at_ms);

    peer.toFree();
}

test "peer: toClosing refreshes last_tx_at_ms so teardown starts now" {
    var env: TestEnv = undefined;
    env.init();
    defer env.deinit();

    var peer = try Peer.init(std.testing.allocator);
    defer peer.deinit(std.testing.allocator);

    peer.toConnected(try freshSocket(), zeroAddress());
    peer.stats.last_tx_at_ms = 0;

    peer.toClosing();

    try std.testing.expect(peer.state == .closing);
    try std.testing.expect(peer.stats.last_tx_at_ms != 0);
    try std.testing.expectEqual(peer.state.closing.at_ms, peer.stats.last_tx_at_ms);

    peer.toFree();
}

test "peer: toShutdown moves closing -> shutdown and keeps the socket" {
    var env: TestEnv = undefined;
    env.init();
    defer env.deinit();

    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), plat.socketpair(plat.AF_UNIX, plat.SOCK_STREAM, 0, &fds));

    const other = root.net.Socket{ .fd = fds[1] };
    defer other.close();

    var peer = try Peer.init(std.testing.allocator);
    defer peer.deinit(std.testing.allocator);

    peer.toConnected(root.net.Socket{ .fd = fds[0] }, zeroAddress());
    peer.toClosing();
    try peer.toShutdown();

    try std.testing.expect(peer.state == .shutdown);
    try std.testing.expect(peer.getSocket() != null);

    peer.toFree();
}

test "peer: discardDownlink shifts and trims correctly" {
    var env: TestEnv = undefined;
    env.init();
    defer env.deinit();

    const allocator = std.testing.allocator;

    var peer = try Peer.init(allocator);
    defer peer.deinit(allocator);

    try peer.downlink.appendSlice(allocator, "abcdef");

    // Discarding nothing keeps everything.
    peer.discardDownlink(0);
    try std.testing.expectEqualStrings("abcdef", peer.downlink.items);

    // Discarding a prefix keeps the tail.
    peer.discardDownlink(3);
    try std.testing.expectEqualStrings("def", peer.downlink.items);

    // Discarding everything empties the buffer.
    peer.discardDownlink(peer.downlink.items.len);
    try std.testing.expectEqual(@as(usize, 0), peer.downlink.items.len);
}

test "peer: discardUplink shifts and trims correctly" {
    var env: TestEnv = undefined;
    env.init();
    defer env.deinit();

    const allocator = std.testing.allocator;

    var peer = try Peer.init(allocator);
    defer peer.deinit(allocator);

    try peer.uplink.appendSlice(allocator, "0123456789");

    peer.discardUplink(4);
    try std.testing.expectEqualStrings("456789", peer.uplink.items);

    peer.discardUplink(0);
    try std.testing.expectEqualStrings("456789", peer.uplink.items);

    peer.discardUplink(peer.uplink.items.len);
    try std.testing.expectEqual(@as(usize, 0), peer.uplink.items.len);
}

test "peer: getSocket reports the fd in every non-free state" {
    var env: TestEnv = undefined;
    env.init();
    defer env.deinit();

    var peer = try Peer.init(std.testing.allocator);
    defer peer.deinit(std.testing.allocator);

    try std.testing.expect(peer.getSocket() == null);

    peer.toConnected(try freshSocket(), zeroAddress());
    try std.testing.expect(peer.getSocket() != null);

    peer.toClosing();
    try std.testing.expect(peer.getSocket() != null);

    peer.toFree();
}
