// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.db);

pub const Pool = struct {
    pub const Error = error{
        PGError,
        IoError,
    };

    pub const Entry = struct {
        pub const State = enum {
            released,
            acquired,
        };

        conn: root.db.Connection = .{},
        acquired: usize = 0,

        pub inline fn init() Error!Entry {
            var conn = root.db.Connection.init() catch |err| {
                SCOPE.err("failed to create a pooled connection", .{});

                return err;
            };
            errdefer conn.deinit();

            conn.pooled = true;

            conn.makeAsync() catch |err| {
                SCOPE.err("failed to make the connection be async: {s}", .{conn.errorMessage()});

                return err;
            };

            return .{
                .conn = conn,
            };
        }

        pub inline fn deinit(this: *Entry) void {
            this.conn.deinit();
        }
    };

    entries: []Entry,

    pub inline fn init(allocator: std.mem.Allocator) !Pool {
        const pool = try allocator.alloc(Entry, root.options.db.pool);
        errdefer allocator.free(pool);

        @memset(pool, Entry{});

        errdefer {
            for (pool) |*conn| {
                conn.deinit();
            }
        }

        for (pool) |*entry| {
            entry.* = try Entry.init();
        }

        return .{
            .entries = pool,
        };
    }

    pub inline fn deinit(this: *Pool, allocator: std.mem.Allocator) void {
        for (this.entries) |*entry| {
            entry.deinit();
        }

        allocator.free(this.entries);
    }

    pub inline fn registerEvents(this: *const Pool, loop: *root.el.EventLoop) void {
        for (this.entries) |*entry| {
            if (entry.conn.mode != .async or entry.conn.state != .pending) {
                continue;
            }

            const fd = entry.conn.socket();

            // Only ask for write interest while libpq has output to flush.
            // `PQflush` also drives the flush, so a socket that becomes
            // writable is drained here and re-registered read-only next tick.
            const ty: root.el.EventType = if (entry.conn.needsWrite())
                .read_write
            else
                .read;

            if (!loop.register(true, fd, ty, .{ .db_conn = &entry.conn })) {
                // Best effort: one unwatched connection must not leave the
                // rest unregistered for the tick.
                SCOPE.err("failed to register an event for a database connection", .{});
            }
        }
    }

    pub inline fn allFree(this: *const Pool) bool {
        for (this.entries) |*entry| {
            if (entry.conn.mode == .sync) {
                continue;
            }

            if (entry.conn.state != .ready) {
                return false;
            }
        }

        return true;
    }

    pub inline fn rent(this: *const Pool) ?*root.db.Connection {
        for (this.entries) |*entry| {
            if (entry.acquired != 0) {
                continue;
            }

            if (entry.conn.mode != .async) {
                continue;
            }

            if (entry.conn.state != .ready) {
                continue;
            }

            entry.acquired += 1;

            return &entry.conn;
        }

        return null;
    }

    pub fn handleEvent(
        this: *Pool,
        ev: root.el.Event,
        handle: *const root.el.UserData,
    ) bool {
        _ = this;

        if (ev.isError()) {
            // TODO:
            @panic("DB socket error");
        }

        if (ev.isRead()) {
            readConnection(handle.db_conn);
        }

        if (ev.isWrite()) {
            writeConnection(handle.db_conn);
        }

        if (handle.db_conn.getEntry()) |entry| {
            return entry.acquired == 0;
        }

        return false;
    }

    /// Reclaims any unacquired connection an abandoned request left pending,
    /// whether it is idle or still in a transaction. Draining is required even
    /// when the transaction is idle: a fully processed statement still has its
    /// terminating NULL result pending, and that alone keeps the connection out
    /// of `rent()`.
    pub inline fn handleOrphans(this: *Pool) void {
        for (this.entries) |*entry| {
            if (entry.acquired > 0) {
                continue;
            }

            const conn = &entry.conn;

            if (conn.mode == .sync) {
                continue;
            }

            if (conn.state != .pending) {
                continue;
            }

            conn.drainResults();

            if (conn.state == .ready) {
                SCOPE.debug("reclaimed an orphaned connection", .{});
            }
        }
    }

    inline fn readConnection(conn: *root.db.Connection) void {
        conn.consumeInput() catch {
            SCOPE.err("failed to consume input: {s}", .{conn.errorMessage()});
        };
    }

    inline fn writeConnection(conn: *root.db.Connection) void {
        _ = conn.flush() catch {};
    }
};
