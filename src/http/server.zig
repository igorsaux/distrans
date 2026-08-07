// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.http);

pub const TaskFactory = fn (
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
) callconv(.@"inline") anyerror!root.http.Task;

pub const Server = struct {
    pub const Error = error{
        IoError,
    };

    socket: *root.net.Server,
    requests: []root.http.Connection,
    factory_arena: std.heap.ArenaAllocator,

    pub inline fn init(
        allocator: std.mem.Allocator,
        socket: *root.net.Server,
    ) error{OutOfMemory}!Server {
        const requests = try allocator.alloc(root.http.Connection, root.options.general.max_peers);
        errdefer allocator.free(requests);

        errdefer {
            for (requests) |*req| {
                req.deinit(allocator);
            }
        }

        for (requests) |*req| {
            req.* = try root.http.Connection.init(allocator);
        }

        return .{
            .socket = socket,
            .requests = requests,
            .factory_arena = .init(allocator),
        };
    }

    pub inline fn deinit(this: *Server, allocator: std.mem.Allocator) void {
        for (this.requests) |*req| {
            req.deinit(allocator);
        }

        allocator.free(this.requests);
        this.factory_arena.deinit();
    }

    pub inline fn allFree(this: *const Server) bool {
        for (this.requests) |*req| {
            if (req.state != .empty) {
                return false;
            }
        }

        return true;
    }

    pub fn tick(
        this: *Server,
        now_ms: usize,
        comptime factory_fn: *const TaskFactory,
    ) Error!?usize {
        @setEvalBranchQuota(std.math.maxInt(u32));

        var next_event_us: ?usize = null;

        for (this.socket.peers, 0..) |*peer, i| {
            const conn: *root.http.Connection = &this.requests[i];

            if (peer.state != .connected) {
                conn.toEmpty();

                if (root.options.http.arenas_reset_interval_s == null) {
                    continue;
                }

                if (now_ms - peer.stats.connected_at_ms < (root.options.http.arenas_reset_interval_s.? * 1000)) {
                    continue;
                }

                _ = conn.arena.reset(.free_all);

                continue;
            }

            if (!root.exit.isSet() and (conn.state == .empty or !conn.getPeer().?.isEq(peer.gen))) {
                SCOPE.debug("new request from '{f}'", .{peer});

                conn.toEmpty();
                conn.toParsing(.{ .gen = peer.gen, .ref = peer });
            }

            switch (conn.state) {
                .empty => unreachable,
                .parsing => {
                    const parsed = conn.parse() catch |err| {
                        SCOPE.debug("parsing failed: {t}", .{err});

                        switch (err) {
                            root.http.Connection.Parsing.Error.HasBody,
                            root.http.Connection.Parsing.Error.BadMethod,
                            root.http.Connection.Parsing.Error.BadContentLength,
                            root.http.Connection.Parsing.Error.BadHeaders,
                            root.http.Connection.Parsing.Error.Unsupported,
                            => conn.toClosingWith(.bad_request),
                            root.http.Connection.Parsing.Error.PathTooLong => conn.toClosingWith(.uri_too_long),
                            root.http.Connection.Parsing.Error.BadVersion => conn.toClosingWith(.http_version_not_supported),
                            root.http.Connection.Parsing.Error.TooManyHeaders,
                            root.http.Connection.Parsing.Error.TooManyQueryParameters,
                            root.http.Connection.Parsing.Error.TooManyCookies,
                            => conn.toClosingWith(.request_header_fields_too_large),
                        }

                        continue;
                    };

                    if (!parsed) {
                        if (now_ms - peer.stats.last_rx_at_ms > root.options.http.read_timeout_ms) {
                            SCOPE.debug("failed to parse the request from '{f}': timeout", .{peer});
                            peer.toFree();
                        }

                        continue;
                    }

                    conn.toHandling();
                    next_event_us = 0;
                },
                .handling => {
                    const h = &conn.state.handling;

                    var response: root.http.Response = .{
                        .allocator = conn.arena.allocator(),
                        .peer = peer,
                    };

                    const request: root.http.Request = .{
                        .path = conn.path.items,
                        .params = conn.params.items,
                        .host = h.host,
                        .authorization = h.authorization,
                        .method = h.method,
                        .cookies = conn.cookies.items,
                        .content_type = h.content_type,
                        .headers = conn.headers.items,
                        .conn = conn,
                        .peer = peer,
                    };

                    if (conn.task == null) {
                        _ = this.factory_arena.reset(.retain_capacity);

                        conn.task = factory_fn(
                            this.factory_arena.allocator(),
                            &request,
                            &response,
                        ) catch |err| {
                            SCOPE.warn("factory function for request {f} '{s}' from '{f}' failed: {t}", .{
                                request.method,
                                request.path,
                                peer,
                                err,
                            });

                            conn.toClosingWith(.internal_server_error);

                            continue;
                        };
                    }

                    switch (conn.task.?.poll()) {
                        .pending => |p| {
                            switch (p) {
                                .want_read => {
                                    if (now_ms - peer.stats.last_rx_at_ms > root.options.http.read_timeout_ms) {
                                        SCOPE.debug("failed to read the request from '{f}': timeout", .{peer});

                                        peer.toFree();
                                    }
                                },
                                .want_write => {
                                    if (now_ms - peer.stats.last_tx_at_ms > root.options.http.write_timeout_ms) {
                                        SCOPE.debug("failed to send the response to '{f}': timeout", .{peer});

                                        peer.toFree();
                                    }
                                },
                                .db => {
                                    // TODO: timeout check
                                },
                                .job => {
                                    // TODO: timeout check
                                    // TODO: something better?
                                    if (next_event_us == null) {
                                        next_event_us = root.options.general.io_timeout_us;
                                    } else {
                                        next_event_us = @min(next_event_us.?, root.options.general.io_timeout_us);
                                    }
                                },
                                .ws => {
                                    // just keep alive
                                    // the task controls peer.uplink and peer.downlink
                                    conn.is_ws = true;
                                },
                            }
                        },
                        .err => |err| {
                            SCOPE.warn("request from '{f}' failed: {t}", .{
                                peer,
                                err,
                            });

                            if (conn.is_ws) {
                                conn.toClosing();
                            } else {
                                conn.toClosingWith(.internal_server_error);
                            }
                        },
                        .ready => {
                            conn.toClosing();
                        },
                    }
                },
                .closing => {
                    if (now_ms - peer.stats.last_tx_at_ms > root.options.http.write_timeout_ms) {
                        SCOPE.debug("failed to send the response to '{f}': timeout", .{peer});
                        peer.toFree();
                    }
                },
            }
        }

        return next_event_us;
    }
};
