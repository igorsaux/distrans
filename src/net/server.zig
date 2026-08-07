// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const builtin = @import("builtin");

const plat = @import("plat");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.socket);

pub const Server = struct {
    pub const Error = error{
        IoError,
        OutOfMemory,
        Locked,
    };

    /// The maximum number of connections accepted per tick, so that a connect
    /// flood cannot monopolize the event loop forever.
    pub const max_accepts_per_tick: usize = 64;

    pub const AcceptAction = enum {
        /// Stop accepting for this tick; nothing more is pending.
        stop,
        /// The accept was interrupted by a signal; retry.
        retry,
        /// This connection could not be accepted; drop it and keep accepting.
        close_and_continue,
    };

    /// Classifies the `errno` left by a failed `accept`. Pure, so it can be
    /// tested without a real fd.
    pub fn classifyAcceptError(errno: c_int) AcceptAction {
        if (errno == plat.EAGAIN or errno == plat.EWOULDBLOCK) {
            return .stop;
        }

        if (errno == plat.EINTR) {
            return .retry;
        }

        // Resource exhaustion: retrying now would busyloop without progress.
        if (errno == plat.EMFILE or errno == plat.ENFILE or
            errno == plat.ENOBUFS or errno == plat.ENOMEM)
        {
            return .stop;
        }

        return .close_and_continue;
    }

    io: std.Io,
    socket: root.net.Socket,
    peers: []root.net.Peer = &.{},
    /// Held for the lifetime of a unix-bound server; guards the bind path.
    lock_fd: ?c_int = null,

    pub inline fn init(allocator: std.mem.Allocator, io: std.Io) Error!Server {
        var peers: []root.net.Peer = try allocator.alloc(root.net.Peer, root.options.general.max_peers);
        errdefer allocator.free(peers);

        errdefer {
            for (peers) |*conn| {
                conn.deinit(allocator);
            }
        }

        {
            var i: usize = 0;

            while (i < peers.len) : (i += 1) {
                peers[i] = try root.net.Peer.init(allocator);
            }
        }

        var lock_fd: ?c_int = null;
        errdefer if (lock_fd) |fd| {
            _ = plat.close(fd);
        };

        const socket = blk: {
            if (root.options.socket.bind == .unix) {
                const path = root.options.socket.bind.unix;

                lock_fd = try lockUnixPath(allocator, path);

                const socket = try root.net.Socket.new(plat.PF_UNIX, plat.SOCK_STREAM, 0);
                errdefer socket.close();

                socket.setNonBlocking() catch |err| {
                    SCOPE.err("failed to switch the server socket to nonblocking mode: {}", .{root.os.errno()});

                    return err;
                };

                _ = plat.unlink(path);
                socket.bindUnix(path) catch |err| {
                    SCOPE.err("failed to bind the socket to '{s}': {}\n", .{ path, root.os.errno() });

                    return err;
                };

                break :blk socket;
            }

            var res: *plat.addrinfo = undefined;
            var hints: plat.addrinfo = .{
                .ai_family = plat.AF_INET6,
                .ai_socktype = plat.SOCK_STREAM,
            };

            if (plat.getaddrinfo(
                root.options.socket.bind.inet.host,
                root.options.socket.bind.inet.port,
                &hints,
                @ptrCast(&res),
            ) != 0) {
                SCOPE.err(
                    "failed to resolve the address '{s}:{s}': {}",
                    .{ root.options.socket.bind.inet.host, root.options.socket.bind.inet.port, root.os.errno() },
                );

                return Error.IoError;
            }

            defer plat.freeaddrinfo(res);

            const socket = try root.net.Socket.new(res.ai_family, res.ai_socktype, res.ai_protocol);
            errdefer socket.close();

            socket.setopt(plat.SOL_SOCKET, plat.SO_REUSEADDR, &std.mem.toBytes(@as(c_int, 1))) catch |err| {
                SCOPE.err("failed to set SO_REUSEADDR: {}", .{root.os.errno()});

                return err;
            };

            if (builtin.os.tag == .macos) {
                socket.setopt(plat.IPPROTO_IPV6, plat.IPV6_V6ONLY, &std.mem.toBytes(@as(c_int, 0))) catch |err| {
                    SCOPE.err("failed to set IPV6_V6ONLY: {}", .{root.os.errno()});

                    return err;
                };
            }

            socket.setNonBlocking() catch |err| {
                SCOPE.err("failed to switch the server socket to nonblocking mode: {}", .{root.os.errno()});

                return err;
            };

            socket.bind(res.ai_addr, res.ai_addrlen) catch |err| {
                SCOPE.err("failed to bind: {}", .{root.os.errno()});

                return err;
            };

            break :blk socket;
        };

        errdefer socket.close();

        try socket.listen(plat.SOMAXCONN);

        return .{
            .io = io,
            .socket = socket,
            .peers = peers,
            .lock_fd = lock_fd,
        };
    }

    pub inline fn deinit(this: *Server, allocator: std.mem.Allocator) void {
        if (root.options.socket.bind == .unix) {
            _ = plat.unlink(root.options.socket.bind.unix);
        }

        if (this.lock_fd) |fd| {
            _ = plat.close(fd);
            this.lock_fd = null;
        }

        this.socket.close();

        for (this.peers) |*conn| {
            conn.deinit(allocator);
        }

        allocator.free(this.peers);
    }

    /// Opens (or creates) `<path>.lock` and takes an exclusive, non-blocking
    /// lock on it. The returned fd must be kept open for as long as this
    /// process owns `path`; the kernel releases the lock on exit.
    fn lockUnixPath(allocator: std.mem.Allocator, path: []const u8) Error!c_int {
        const lock_path = std.fmt.allocPrintSentinel(allocator, "{s}.lock", .{path}, 0) catch {
            return Error.OutOfMemory;
        };
        defer allocator.free(lock_path);

        const fd = plat.open(lock_path, plat.O_CREAT | plat.O_RDWR, @as(c_uint, 0o644));

        if (fd < 0) {
            SCOPE.err("failed to open the lock file '{s}': {}", .{ lock_path, root.os.errno() });

            return Error.IoError;
        }

        if (plat.flock(fd, plat.LOCK_EX | plat.LOCK_NB) < 0) {
            const errno = root.os.errno();

            _ = plat.close(fd);

            if (errno == plat.EWOULDBLOCK) {
                // Expected when a second instance is started; not a failure of
                // this process.
                SCOPE.warn("another instance already owns '{s}'", .{path});

                return Error.Locked;
            }

            SCOPE.err("failed to lock '{s}': {}", .{ lock_path, errno });

            return Error.IoError;
        }

        return fd;
    }

    pub inline fn allFree(this: *const Server) bool {
        for (this.peers) |*peer| {
            if (peer.state != .free) {
                return false;
            }
        }

        return true;
    }

    inline fn findFreePeer(this: *const Server) ?*root.net.Peer {
        for (this.peers) |*peer| {
            if (peer.state == .free) {
                return peer;
            }
        }

        return null;
    }

    pub inline fn registerEvents(
        this: *const Server,
        loop: *root.el.EventLoop,
        accept: bool,
    ) void {
        const now_ms: u64 = @intCast(std.Io.Timestamp.now(root.io, .real).toMilliseconds());

        if (accept) {
            if (!loop.register(true, this.socket.fd, .read, .{ .socket = {} })) {
                SCOPE.err("failed to register a read event for server socket", .{});
            }
        }

        for (this.peers) |*p| {
            if (p.state == .free) {
                continue;
            } else if (p.state == .closing) {
                if (now_ms - p.state.closing.at_ms > root.options.socket.disconnect_timeout_ms) {
                    SCOPE.debug("closing socket '{f}' by timeout", .{p});
                    p.toFree();

                    continue;
                }
            } else if (p.state == .shutdown) {
                if (now_ms - p.state.shutdown.at_ms > root.options.socket.disconnect_timeout_ms) {
                    SCOPE.debug("closing socket '{f}' by timeout", .{p});
                    p.toFree();

                    continue;
                }
            }

            const ty: root.el.EventType = if (p.uplink.items.len > 0)
                .read_write
            else
                .read;

            if (!loop.register(true, p.getSocket().?.fd, ty, .{ .peer = p })) {
                // Best effort: skip this peer instead of leaving the remaining
                // peers unregistered for the tick.
                SCOPE.err("failed to register an event for the peer '{f}'", .{p});
            }
        }
    }

    pub fn handleEvent(
        this: *Server,
        now_ms: usize,
        ev: root.el.Event,
        handle: *const root.el.UserData,
        discard: bool,
    ) Error!void {
        std.debug.assert(handle.* != .db_conn);

        switch (handle.*) {
            .socket => try this.acceptPeers(now_ms),
            .peer => {
                if (handle.peer.state == .free) {
                    return;
                }

                if (ev.isError()) {
                    handle.peer.toFree();

                    return;
                }

                if (ev.isRead()) {
                    try fillDownlink(now_ms, handle.peer, discard);

                    // A single epoll event can report readiness for both
                    // reading and writing, and `fillDownlink` frees the peer on
                    // disconnect. Stop before handing the freed peer to
                    // `drainUplink`, whose socket would already be gone.
                    if (handle.peer.state == .free) {
                        return;
                    }
                }

                if (ev.isWrite()) {
                    try drainUplink(now_ms, handle.peer);
                }
            },
            .db_conn => unreachable,
        }
    }

    inline fn acceptPeers(this: *Server, now_ms: usize) Error!void {
        var accepted: usize = 0;

        while (accepted < max_accepts_per_tick) {
            var addr: root.net.Socket.Address = undefined;
            addr.len = addr.data.len;

            const socket = this.socket.accept(
                @ptrCast(@alignCast(&addr.data)),
                &addr.len,
            ) catch {
                const errno = root.os.errno();

                switch (classifyAcceptError(errno)) {
                    .stop => break,
                    .retry => continue,
                    .close_and_continue => {
                        // A connection aborted before we got to it is normal.
                        if (errno != plat.ECONNABORTED) {
                            SCOPE.err("failed to accept: {}", .{errno});
                        }

                        continue;
                    },
                }
            };

            accepted += 1;

            socket.setNonBlocking() catch {
                SCOPE.err(
                    "failed to switch the client socket to nonblocking mode: {}, dropping the connection",
                    .{root.os.errno()},
                );

                socket.close();

                continue;
            };

            if (builtin.os.tag == .macos) {
                socket.setopt(plat.SOL_SOCKET, plat.SO_NOSIGPIPE, std.mem.asBytes(&@as(c_int, 1))) catch {
                    SCOPE.err("failed to setopt SO_NOSIGPIPE on a new peer '{f}': {}", .{ &addr, root.os.errno() });
                    socket.close();

                    continue;
                };
            }

            if (this.findFreePeer()) |peer| {
                peer.toConnected(socket, addr);
                peer.updateConnectedAt(@intCast(now_ms));

                SCOPE.debug("a new peer '{f}' accepted", .{peer});

                continue;
            }

            SCOPE.debug("no more space for new peers", .{});
            socket.close();
        }
    }

    inline fn fillDownlink(
        now_ms: usize,
        peer: *root.net.Peer,
        discard: bool,
    ) Error!void {
        const socket = peer.getSocket().?;

        while (peer.downlink.items.len < peer.downlink.capacity) {
            if (discard) {
                peer.downlink.items.len = 0;
            }

            const free = peer.downlink.unusedCapacitySlice();
            const data = socket.read(free) catch {
                const errno = root.os.errno();

                if (errno == plat.EWOULDBLOCK or errno == plat.EAGAIN) {
                    break;
                }

                if (errno == plat.EINTR) {
                    continue;
                }

                SCOPE.err("failed to read from the peer '{f}': {}", .{ peer, root.os.errno() });
                peer.toFree();

                break;
            };

            if (data.len == 0) {
                SCOPE.debug("peer '{f}' was disconnected", .{peer});
                peer.toFree();

                return;
            }

            peer.downlink.items.len += data.len;
            peer.stats.last_rx_at_ms = now_ms;
        }
    }

    inline fn drainUplink(now_ms: usize, peer: *root.net.Peer) Error!void {
        const socket = peer.getSocket().?;

        while (peer.uplink.items.len > 0) {
            const write_n = socket.write(peer.uplink.items) catch {
                const errno = root.os.errno();

                if (errno == plat.EAGAIN or errno == plat.EWOULDBLOCK) {
                    break;
                }

                if (errno == plat.EINTR) {
                    continue;
                }

                SCOPE.err("failed to write to the peer '{f}': {}", .{ peer, errno });
                peer.toFree();

                break;
            };

            // A zero-length write makes no progress; stop instead of spinning.
            if (write_n == 0) {
                break;
            }

            peer.discardUplink(write_n);
            peer.stats.last_tx_at_ms = now_ms;
        }

        if (peer.state == .closing and peer.uplink.items.len == 0) {
            SCOPE.debug("disconnecting the peer '{f}'", .{peer});

            peer.toShutdown() catch {
                SCOPE.warn("shutdown failed, terminating", .{});
                peer.toFree();
            };
        }
    }
};
