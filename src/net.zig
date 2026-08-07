// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const peer = @import("net/peer.zig");
pub const Peer = peer.Peer;
const server = @import("net/server.zig");
pub const Server = server.Server;
const socket = @import("net/socket.zig");
pub const Socket = socket.Socket;

test {
    _ = @import("net/socket_test.zig");
    _ = @import("net/peer_test.zig");
    _ = @import("net/server_test.zig");
}
