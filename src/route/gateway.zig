// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../root.zig");
const events = @import("gateway/events.zig");
const frames = @import("gateway/frames.zig");

const SCOPE = std.log.scoped(.@"/api/gateway");

const Request = struct {
    payload: []const u8,
    total_len: usize,
};

// Do not use .want_read here!!! Use heartbeat-based timeouts instead.
/// R1 - events only to authorized users.
const GetTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        websocket_key: []const u8,
    };

    const State = union(enum) {
        pub const SendingEvent = struct {
            event: root.services.events.Event,
            body: ?[]const u8 = null,
        };

        start,
        waiting,
        handling: Request,
        dispatching: SendingEvent,
    };

    const Stats = struct {
        connected_at_ms: u64 = 0,
        last_heartbeat_at_ms: u64 = 0,
    };

    arena: std.heap.ArenaAllocator,
    peer: *root.net.Peer,
    response: *root.http.Response,
    payload: Payload,
    heart_beat_rate_ms: u64,
    state: State = .start,
    stats: Stats = .{},
    user_id: ?root.types.UserId = null,
    event_cursor: usize = 0,
    seq: u32 = 1,
    auth_db: ?*root.db.Connection = null,
    bot_lookup: ?root.repo.tokens.GetBotTokenUser = null,
    bot_lookup_done: bool = false,
    bot_token_hash: ?[32]u8 = null,
    user_alive: ?root.repo.users.CheckAlive = null,
    candidate_user_id: ?root.types.UserId = null,
    candidate_expiry_s: ?u64 = null,
    pending_auth: ?Request = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *GetTask = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            var token_buffer: [root.ws.TokenBufferSize]u8 = undefined;
            const token = root.ws.makeToken(this.payload.websocket_key, &token_buffer);

            var writer = this.response.getWriter()
                .withoutAutoClose();

            if (!writer.writeCode(.switching_protocols)) {
                return .{ .pending = .want_write };
            }

            if (!writer.writeHeader("Upgrade", "{s}", .{"websocket"})) {
                return .{ .pending = .want_write };
            }

            if (!writer.writeHeader("Connection", "{s}", .{"upgrade"})) {
                return .{ .pending = .want_write };
            }

            if (!writer.writeHeader("Sec-WebSocket-Accept", "{s}", .{token})) {
                return .{ .pending = .want_write };
            }

            if (!writer.emptyBody()) {
                return .{ .pending = .want_write };
            }

            writer.commit();

            // discard the request data
            this.peer.downlink.items.len = 0;
            this.state = .waiting;
            this.event_cursor = root.bus.cursor;

            const now_ms: u64 = @intCast(std.Io.Timestamp.now(root.io, .real).toMilliseconds());

            this.stats = .{
                .connected_at_ms = now_ms,
                .last_heartbeat_at_ms = now_ms,
            };
        }

        if (root.exit.isSet()) {
            this.forcedClose();

            return .ready;
        }

        std.debug.assert(this.peer.state == .connected);

        var writer: std.Io.Writer = .fixed(this.peer.uplink.unusedCapacitySlice());
        const now_ms: u64 = @intCast(std.Io.Timestamp.now(root.io, .real).toMilliseconds());

        // R1
        if (this.user_id == null) {
            const awaiting_identify = this.pending_auth == null and
                this.bot_token_hash == null and this.candidate_user_id == null;

            // Read whatever is already buffered before enforcing the deadline,
            // so an `identify` that arrives near it is still honored.
            if (awaiting_identify and this.peer.downlink.items.len > 0) {
                const res = this.acceptPoll();

                if (res != .ready) {
                    return res.discard();
                }

                if (res.ready == null) {
                    this.forcedClose();

                    return .ready;
                }

                this.pending_auth = res.ready;
            }

            // The auth deadline only covers waiting for `identify`. Once the
            // frame is received, the (asynchronous) bot-token lookup must not
            // be bounded by it, otherwise a slow DB closes valid sessions.
            if (this.pending_auth == null and this.bot_token_hash == null and
                this.candidate_user_id == null)
            {
                if (now_ms - this.stats.connected_at_ms > root.options.websocket.auth_timeout_ms) {
                    SCOPE.debug("WS auth timeout", .{});
                    this.forcedClose();

                    return .ready;
                }

                return .{ .pending = .ws };
            }

            if (this.bot_token_hash == null and this.pending_auth != null) {
                switch (this.handleAuthFrame(this.arena.allocator(), .{
                    .payload = this.pending_auth.?.payload,
                    .writer = &writer,
                })) {
                    .invalid => {
                        this.forcedClose();

                        return .ready;
                    },
                    .user => {
                        this.peer.discardDownlink(this.pending_auth.?.total_len);
                        this.pending_auth = null;
                    },
                    .bot => {},
                }
            }
        }

        // R1
        if (this.user_id == null and this.bot_token_hash != null) {
            if (this.auth_db == null) {
                this.auth_db = root.db_pool.rent();

                if (this.auth_db == null) {
                    return .{ .pending = .db };
                }
            }

            if (this.bot_lookup == null) {
                this.bot_lookup = root.repo.tokens.GetBotTokenUser.init(this.auth_db.?, .{
                    .token_hash = this.bot_token_hash.?,
                });
            }

            if (!this.bot_lookup_done) {
                const res = this.bot_lookup.?.task().poll();

                if (res == .err) {
                    this.releaseAuthDb();
                    this.forcedClose();

                    return .ready;
                }

                if (res != .ready) {
                    return res.discard();
                }

                this.bot_lookup_done = true;

                // The lookup is over: hand the connection back to the pool now
                // instead of holding it for the whole WebSocket session.
                const maybe_user_id = res.ready;
                this.releaseAuthDb();

                // Unknown hash or the bot is deleted.
                if (maybe_user_id == null) {
                    this.forcedClose();

                    return .ready;
                }

                this.user_id = maybe_user_id.?;
                root.presence.add(this.user_id.?);

                if (!this.sendHello(this.arena.allocator(), &writer)) {
                    this.forcedClose();

                    return .ready;
                }

                this.peer.uplink.items.len += writer.end;
                this.peer.discardDownlink(this.pending_auth.?.total_len);
                this.pending_auth = null;
                this.bot_token_hash = null;
            }
        }

        // R1
        if (this.user_id == null and this.candidate_user_id != null) {
            const now_s: u64 = @intCast(std.Io.Timestamp.now(root.io, .real).toSeconds());

            if (this.candidate_expiry_s.? <= now_s) {
                this.releaseAuthDb();
                this.candidate_user_id = null;
                this.candidate_expiry_s = null;
                this.forcedClose();

                return .ready;
            }

            if (this.auth_db == null) {
                this.auth_db = root.db_pool.rent();

                if (this.auth_db == null) {
                    return .{ .pending = .db };
                }
            }

            if (this.user_alive == null) {
                this.user_alive = root.repo.users.CheckAlive.init(this.auth_db.?, .{
                    .user_id = this.candidate_user_id.?,
                });
            }

            const res = this.user_alive.?.task().poll();

            if (res == .err) {
                this.releaseAuthDb();
                this.forcedClose();

                return .ready;
            }

            if (res != .ready) {
                return res.discard();
            }

            const alive = res.ready;
            this.releaseAuthDb();
            const verified_at_s: u64 = @intCast(std.Io.Timestamp.now(root.io, .real).toSeconds());

            if (verified_at_s >= this.candidate_expiry_s.?) {
                this.candidate_user_id = null;
                this.candidate_expiry_s = null;
                this.forcedClose();

                return .ready;
            }

            if (!alive) {
                this.candidate_user_id = null;
                this.candidate_expiry_s = null;
                this.forcedClose();

                return .ready;
            }

            this.user_id = this.candidate_user_id;
            this.candidate_user_id = null;
            this.candidate_expiry_s = null;
            root.presence.add(this.user_id.?);

            if (!this.sendHello(this.arena.allocator(), &writer)) {
                this.forcedClose();

                return .ready;
            }

            this.peer.uplink.items.len += writer.end;
        }

        while (this.state == .waiting or this.state == .handling or this.state == .dispatching) {
            const heartbeat_interval_ms = now_ms - this.stats.last_heartbeat_at_ms;

            if (heartbeat_interval_ms -| root.options.websocket.heartbeat_threshold_ms > this.heart_beat_rate_ms) {
                SCOPE.debug("WS heartbeat miss", .{});
                this.forcedClose();

                return .ready;
            }

            if (this.state == .waiting) {
                _ = this.arena.reset(.retain_capacity);

                if (root.bus.getNext(&this.event_cursor)) |event| {
                    this.state = .{
                        .dispatching = .{
                            .event = event,
                        },
                    };
                } else if (this.peer.downlink.items.len > 0) {
                    const res = this.acceptPoll();

                    if (res != .ready) {
                        return res.discard();
                    }

                    if (res.ready == null) {
                        this.forcedClose();

                        return .ready;
                    }

                    this.state = .{ .handling = res.ready.? };
                } else {
                    return .{ .pending = .ws };
                }
            }

            switch (this.state) {
                .handling => |p| {
                    if (!this.handleTextFrame(this.arena.allocator(), .{
                        .payload = p.payload,
                        .writer = &writer,
                    }, now_ms)) {
                        this.forcedClose();

                        return .ready;
                    }

                    this.peer.uplink.items.len += writer.end;
                    this.peer.discardDownlink(p.total_len);
                    this.state = .waiting;
                },
                .dispatching => {
                    const res = this.sendEventPoll(this.arena.allocator(), &writer);

                    switch (res) {
                        .ready => {
                            this.state = .waiting;
                            this.peer.uplink.items.len += writer.end;

                            continue;
                        },
                        .err => return .{ .err = res.err },
                        .pending => {
                            std.debug.assert(res.pending != .ws);

                            return .{ .pending = res.pending };
                        },
                    }
                },
                else => unreachable,
            }
        }

        unreachable;
    }

    inline fn releaseAuthDb(this: *GetTask) void {
        if (this.bot_lookup) |*t| {
            t.task().dispose();
            this.bot_lookup = null;
        }

        if (this.user_alive) |*t| {
            t.task().dispose();
            this.user_alive = null;
        }

        if (this.auth_db) |db| {
            db.release();
            this.auth_db = null;
        }
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetTask = @ptrCast(@alignCast(ctx));

        if (this.user_id) |user_id| {
            root.presence.remove(user_id);
            this.user_id = null;
        }

        this.releaseAuthDb();

        this.arena.deinit();
    }

    /// Reads the next client frame. Returns null when the connection must be
    /// closed (close frame, binary frame, invalid frame or a non-fin frame).
    inline fn acceptPoll(this: *GetTask) root.task.Poll(?Request, anyerror) {
        const frame = root.ws.parseFrame(this.peer.downlink.items) catch |err| switch (err) {
            error.Incomplete => return .{ .pending = .ws },
            error.ProtocolError => return .{ .ready = null },
        };

        switch (frame.opcode) {
            .close => return .{ .ready = null },
            else => {},
        }

        if (!frame.fin) {
            SCOPE.warn("WS non-fin frames are not supported", .{});

            return .{ .ready = null };
        }

        switch (frame.opcode) {
            .text => {
                return .{
                    .ready = .{
                        .payload = frame.payload,
                        .total_len = frame.total_len,
                    },
                };
            },
            .binary => {
                var writer: std.Io.Writer = .fixed(this.peer.uplink.unusedCapacitySlice());

                _ = root.ws.writeFrame(&writer, .close, &.{});
                this.peer.uplink.items.len += writer.end;

                return .{ .ready = null };
            },
            .ping => {
                var writer: std.Io.Writer = .fixed(this.peer.uplink.unusedCapacitySlice());

                if (!root.ws.writeFrame(&writer, .pong, frame.payload)) {
                    return .{ .pending = .want_write };
                }

                this.peer.uplink.items.len += writer.end;

                return .{ .pending = .ws };
            },
            .pong => return .{ .pending = .ws },
            else => return .{ .ready = null },
        }
    }

    const AuthOutcome = enum {
        invalid,
        user,
        bot,
    };

    inline fn sendHello(this: *GetTask, arena: std.mem.Allocator, writer: *std.Io.Writer) bool {
        const ResponsePayload = frames.Frame.Payload(frames.Frame.HelloData);

        const payload: ResponsePayload = .{
            .op = .hello,
            .d = .{
                .heartbeat_interval = this.heart_beat_rate_ms,
            },
        };

        var json_writer: std.Io.Writer.Allocating = .init(arena);

        std.json.fmt(payload, .{}).format(&json_writer.writer) catch |err| {
            SCOPE.err("WS failed to serialize 'hello' response: {t}", .{err});

            return false;
        };

        return root.ws.writeFrame(writer, .text, json_writer.written());
    }

    /// Parses an auth frame. User JWTs and bot tokens are authorized asynchronously.
    inline fn handleAuthFrame(
        this: *GetTask,
        arena: std.mem.Allocator,
        frame: frames.Frame,
    ) AuthOutcome {
        const payload_value = std.json.parseFromSliceLeaky(
            std.json.Value,
            arena,
            frame.payload,
            .{},
        ) catch {
            return .invalid;
        };

        if (payload_value != .object) {
            return .invalid;
        }

        const op_value = payload_value.object.get("op") orelse {
            return .invalid;
        };

        if (op_value != .string) {
            return .invalid;
        }

        if (!std.mem.eql(u8, op_value.string, "identify")) {
            return .invalid;
        }

        if (this.user_id != null or this.candidate_user_id != null or this.bot_token_hash != null) {
            return .invalid;
        }

        const d_value = payload_value.object.get("d") orelse {
            return .invalid;
        };

        if (d_value != .object) {
            return .invalid;
        }

        const token_value = d_value.object.get("token") orelse {
            return .invalid;
        };

        if (token_value != .string) {
            return .invalid;
        }

        if (root.services.tokens.isBotToken(token_value.string)) {
            this.bot_token_hash = root.services.tokens.botTokenHash(token_value.string);

            return .bot;
        }

        const token_parts = root.services.tokens.AccessTokenParts.split(token_value.string) orelse {
            return .invalid;
        };

        if (!token_parts.verify()) {
            return .invalid;
        }

        const token_payload = token_parts.parsePayload(arena) catch {
            return .invalid;
        };

        const now_s: u64 = @intCast(std.Io.Timestamp.now(root.io, .real).toSeconds());

        if (now_s >= token_payload.exp) {
            return .invalid;
        }

        this.candidate_user_id = std.fmt.parseInt(root.types.UserId, token_payload.sub, 10) catch {
            return .invalid;
        };
        this.candidate_expiry_s = token_payload.exp;

        return .user;
    }

    inline fn handleTextFrame(
        this: *GetTask,
        arena: std.mem.Allocator,
        frame: frames.Frame,
        now_ms: u64,
    ) bool {
        const payload_value = std.json.parseFromSliceLeaky(
            std.json.Value,
            arena,
            frame.payload,
            .{},
        ) catch {
            return false;
        };

        if (payload_value != .object) {
            return false;
        }

        const op_value = payload_value.object.get("op") orelse {
            return false;
        };

        if (op_value != .string) {
            return false;
        }

        if (std.mem.eql(u8, op_value.string, "ack")) {
            if (this.user_id == null) {
                return false;
            }

            const interval_ms = now_ms - this.stats.last_heartbeat_at_ms;
            SCOPE.debug("WS heartbeat after {} ms", .{interval_ms});

            if (interval_ms < this.heart_beat_rate_ms -| root.options.websocket.heartbeat_threshold_ms) {
                SCOPE.warn("too early", .{});
                return false;
            }

            this.stats.last_heartbeat_at_ms = now_ms;

            return true;
        }

        return false;
    }

    inline fn sendEventPoll(
        this: *GetTask,
        arena: std.mem.Allocator,
        writer: *std.Io.Writer,
    ) Task.PollT {
        if (this.state.dispatching.body == null) {
            // The main loop never dispatches empty events.
            std.debug.assert(this.state.dispatching.event.data != .none);

            this.state.dispatching.body = events.buildDispatchBody(
                arena,
                this.state.dispatching.event,
                this.seq,
            ) catch |err| {
                return .{ .err = err };
            };
        }

        if (!root.ws.writeFrame(writer, .text, this.state.dispatching.body.?)) {
            return .{ .pending = .want_write };
        }

        this.seq +%= 1;

        return .ready;
    }

    pub inline fn task(
        peer: *root.net.Peer,
        response: *root.http.Response,
        payload: Payload,
    ) !Task {
        const this = try response.allocator.create(GetTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .arena = .init(response.allocator),
            .peer = peer,
            .response = response,
            .payload = payload,
            .heart_beat_rate_ms = 0,
        };

        var rnd: std.Random.DefaultPrng = .init(
            @bitCast(std.Io.Timestamp.now(root.io, .real).toMilliseconds()),
        );

        this.heart_beat_rate_ms = rnd.random().intRangeAtMost(
            u64,
            root.options.websocket.min_heartbeat_ms,
            root.options.websocket.max_heartbeat_ms,
        );

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }

    inline fn forcedClose(this: *GetTask) void {
        var writer: std.Io.Writer = .fixed(this.peer.uplink.unusedCapacitySlice());

        _ = root.ws.writeFrame(&writer, .close, &.{});
        this.peer.uplink.items.len += writer.end;
    }
};

/// GET /api/gateway
pub inline fn getHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
) !GetTask.Task {
    _ = allocator;

    const upgrade_header = request.findHeader("upgrade") orelse {
        return try root.route.generic.badRequestTask(response);
    };

    if (!std.ascii.eqlIgnoreCase(upgrade_header, "websocket")) {
        return try root.route.generic.badRequestTask(response);
    }

    const connection_header = request.findHeader("connection") orelse {
        return try root.route.generic.badRequestTask(response);
    };

    if (!std.ascii.eqlIgnoreCase(connection_header, "Upgrade")) {
        return try root.route.generic.badRequestTask(response);
    }

    const websocket_key_header = request.findHeader("sec-websocket-key") orelse {
        return try root.route.generic.badRequestTask(response);
    };

    const websocket_version_header = request.findHeader("sec-websocket-version") orelse {
        return try root.route.generic.badRequestTask(response);
    };

    if (!std.mem.eql(u8, websocket_version_header, "13")) {
        return try root.route.generic.badRequestTask(response);
    }

    return try GetTask.task(request.peer, response, .{
        .websocket_key = websocket_key_header,
    });
}
