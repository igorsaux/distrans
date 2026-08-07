// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const plat = @import("plat");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.socket);

pub const Peer = struct {
    pub const Error = error{
        IoError,
    };

    pub const Connected = struct {
        socket: root.net.Socket,
        address: root.net.Socket.Address,
    };

    pub const Closing = struct {
        socket: root.net.Socket,
        address: root.net.Socket.Address,
        at_ms: u64,
    };

    pub const Shutdown = struct {
        socket: root.net.Socket,
        address: root.net.Socket.Address,
        at_ms: u64,
    };

    pub const State = union(enum) {
        free: void,
        connected: Connected,
        closing: Closing,
        shutdown: Shutdown,
    };

    pub const Stats = struct {
        connected_at_ms: u64 = 0,
        /// The last time when a socket received a data.
        last_rx_at_ms: u64 = 0,
        /// The last time when a socket send a data.
        last_tx_at_ms: u64 = 0,
    };

    /// Every new connection increments this counter.
    gen: usize = 0,
    downlink: std.ArrayList(u8) = .empty,
    uplink: std.ArrayList(u8) = .empty,
    state: State = .free,
    stats: Stats = .{},

    pub inline fn init(
        allocator: std.mem.Allocator,
    ) error{OutOfMemory}!Peer {
        var downlink = try std.ArrayList(u8).initCapacity(
            allocator,
            root.options.socket.downlink_buf_size,
        );
        errdefer downlink.deinit(allocator);

        var uplink = try std.ArrayList(u8).initCapacity(
            allocator,
            root.options.socket.uplink_buf_size,
        );
        errdefer uplink.deinit(allocator);

        return .{
            .downlink = downlink,
            .uplink = uplink,
        };
    }

    pub inline fn deinit(this: *Peer, allocator: std.mem.Allocator) void {
        this.toFree();
        this.downlink.deinit(allocator);
        this.uplink.deinit(allocator);
    }

    /// Closing the socket, so it may be used for another connection.
    pub inline fn toFree(this: *Peer) void {
        if (this.getSocket()) |s| {
            s.close();
        }

        this.state = .free;
    }

    /// The socket will be open for receiving and transmitting any data, and
    /// will be closed when the peer closes his socket.
    pub inline fn toConnected(
        this: *Peer,
        socket: root.net.Socket,
        address: root.net.Socket.Address,
    ) void {
        std.debug.assert(this.state == .free);

        this.gen +%= 1;
        this.downlink.items.len = 0;
        this.uplink.items.len = 0;

        const new_state: State = .{
            .connected = .{
                .socket = socket,
                .address = address,
            },
        };

        this.state = new_state;
    }

    /// A state for the socket to be closed. The socket will transmit all
    /// leftover data and will not transmit any data. The socket will be
    /// closed when the peer closes his socket.
    pub inline fn toClosing(this: *Peer) void {
        std.debug.assert(this.state == .connected);

        const conn = &this.state.connected;
        const now_ms: u64 = @intCast(std.Io.Timestamp.now(root.io, .real).toMilliseconds());

        this.stats.last_tx_at_ms = now_ms;

        const new_state: State = .{
            .closing = .{
                .socket = conn.socket,
                .address = conn.address,
                .at_ms = now_ms,
            },
        };

        this.state = new_state;
    }

    pub inline fn toShutdown(this: *Peer) Error!void {
        std.debug.assert(this.state == .closing);

        const closing = &this.state.closing;

        try closing.socket.shutdown(plat.SHUT_WR);

        const new_state: State = .{
            .shutdown = .{
                .socket = closing.socket,
                .address = closing.address,
                .at_ms = @intCast(std.Io.Timestamp.now(root.io, .real).toMilliseconds()),
            },
        };

        this.state = new_state;
    }

    pub inline fn getSocket(this: *const Peer) ?root.net.Socket {
        return switch (this.state) {
            .free => null,
            .connected => |*s| s.socket,
            .closing => |*s| s.socket,
            .shutdown => |*s| s.socket,
        };
    }

    pub inline fn updateConnectedAt(this: *Peer, connected_at_ms: usize) void {
        this.stats.connected_at_ms = connected_at_ms;
        this.stats.last_rx_at_ms = connected_at_ms;
        this.stats.last_tx_at_ms = connected_at_ms;
    }

    pub inline fn format(this: *const Peer, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (this.state) {
            .free => {
                try w.writeAll("free");
                return w.print(" ({})", .{this.gen});
            },
            .connected => |*s| {
                try s.address.format(w);
                return w.print(" ({})", .{this.gen});
            },
            .closing => |*s| {
                try s.address.format(w);
                return w.print(" ({})", .{this.gen});
            },
            .shutdown => |*s| {
                try s.address.format(w);
                return w.print(" ({})", .{this.gen});
            },
        }
    }

    /// Discards all the data until `start`.
    pub inline fn discardDownlink(this: *Peer, start: usize) void {
        std.debug.assert(start <= this.downlink.items.len);

        const remains = this.downlink.items.len - start;

        if (remains == 0) {
            this.downlink.items.len = 0;

            return;
        }

        @memmove(this.downlink.items[0..remains], this.downlink.items[start..]);
        this.downlink.items.len = remains;
    }

    /// Discards all the data until `start`.
    pub inline fn discardUplink(this: *Peer, start: usize) void {
        std.debug.assert(start <= this.uplink.items.len);

        const remains = this.uplink.items.len - start;

        if (remains == 0) {
            this.uplink.items.len = 0;

            return;
        }

        @memmove(this.uplink.items[0..remains], this.uplink.items[start..]);
        this.uplink.items.len = remains;
    }

    pub inline fn isConnected(this: *const Peer) bool {
        return this.state == .connected;
    }
};
