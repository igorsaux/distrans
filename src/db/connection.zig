// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const pq = @import("pq");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.db);

pub const Connection = struct {
    pub const Error = error{
        PGError,
    };

    pub const State = enum {
        ready,
        pending,
    };

    pub const Kind = enum {
        sync,
        async,
    };

    pub const Format = enum(c_int) {
        text = 0,
        binary = 1,

        pub inline fn toRaw(this: Format) c_int {
            return switch (this) {
                .text => 0,
                .binary => 1,
            };
        }
    };

    conn: ?*pq.PGconn = null,
    state: State = .ready,
    mode: Kind = .sync,
    pooled: bool = false,

    pub inline fn init() Error!Connection {
        const conn = pq.PQconnectdb(root.options.db.conninfo).?;
        errdefer pq.PQfinish(conn);

        if (pq.PQstatus(conn) != pq.CONNECTION_OK) {
            SCOPE.err("failed to connect to the DB: {s}", .{pq.PQerrorMessage(conn)});

            return Error.PGError;
        }

        if (pq.PQsetClientEncoding(conn, "UTF8") < 0) {
            SCOPE.err("failed to set the client encoding 'UTF8': {s}", .{pq.PQerrorMessage(conn)});

            return Error.PGError;
        }

        return .{
            .conn = conn,
        };
    }

    pub inline fn deinit(this: *Connection) void {
        if (this.conn != null) {
            pq.PQfinish(this.conn.?);
            this.conn = null;
        }
    }

    pub inline fn socket(this: *const Connection) c_int {
        return pq.PQsocket(this.conn);
    }

    pub inline fn flush(this: *const Connection) !bool {
        std.debug.assert(this.mode == .async);

        return switch (pq.PQflush(this.conn)) {
            0 => true,
            1 => false,
            else => Error.PGError,
        };
    }

    /// True while libpq still has buffered output for the server. Write
    /// interest must be requested only when there is something to flush: a
    /// connected socket with an empty send buffer is always writable, so
    /// registering it for EPOLLOUT makes `epoll_wait` return immediately on
    /// every tick and spins the event loop.
    pub inline fn needsWrite(this: *const Connection) bool {
        std.debug.assert(this.mode == .async);

        return pq.PQflush(this.conn) == 1;
    }

    pub inline fn consumeInput(this: *const Connection) !void {
        std.debug.assert(this.mode == .async);

        if (pq.PQconsumeInput(this.conn) != 1) {
            return Error.PGError;
        }
    }

    pub inline fn isBusy(this: *const Connection) bool {
        std.debug.assert(this.mode == .async);

        if (pq.PQisBusy(this.conn) == 1) {
            return true;
        }

        return false;
    }

    pub inline fn getResult(this: *Connection) ?root.db.Result {
        std.debug.assert(this.mode == .async);

        if (pq.PQgetResult(this.conn)) |res| {
            return .{ .res = res };
        }

        this.state = .ready;

        return null;
    }

    pub inline fn exec(this: *const Connection, query: [:0]const u8) Error!root.db.Result {
        std.debug.assert(this.mode == .sync);

        if (pq.PQexec(this.conn.?, query.ptr)) |res| {
            return .{ .res = res };
        }

        return Error.PGError;
    }

    pub inline fn execExpect(
        this: *const Connection,
        query: [:0]const u8,
        expected: usize,
    ) struct { ?root.db.Result, ?[*c]const u8 } {
        std.debug.assert(this.mode == .sync);

        const res = this.exec(query) catch {
            return .{ null, this.errorMessage() };
        };

        if (res.status() != expected) {
            return .{ res, res.errorMessage() };
        }

        return .{ res, null };
    }

    pub inline fn execDiscard(this: *const Connection, query: [:0]const u8) void {
        std.debug.assert(this.mode == .sync);

        const res = this.exec(query) catch {
            return;
        };
        res.deinit();
    }

    pub inline fn execParams(this: *const Connection, query: [:0]const u8, params: [][*:0]const u8) Error!root.db.Result {
        std.debug.assert(this.mode == .sync);
        std.debug.assert(params.len <= std.math.maxInt(c_int));

        if (pq.PQexecParams(this.conn.?, query, @intCast(params.len), null, params.ptr, null, null, 0)) |res| {
            return .{ .res = res };
        }

        return Error.PGError;
    }

    pub inline fn execParamsExpect(
        this: *const Connection,
        query: [:0]const u8,
        params: [][*:0]const u8,
        expected: usize,
    ) struct { ?root.db.Result, ?[*c]const u8 } {
        std.debug.assert(this.mode == .sync);
        std.debug.assert(params.len <= std.math.maxInt(c_int));

        const res = this.execParams(query, params) catch {
            return .{ null, this.errorMessage() };
        };

        if (res.status() != expected) {
            return .{ res, res.errorMessage() };
        }

        return .{ res, null };
    }

    pub inline fn makeSync(this: *Connection) Error!void {
        std.debug.assert(this.mode == .async);
        std.debug.assert(!this.pooled);

        if (pq.PQsetnonblocking(this.conn, 0) != 0) {
            return Error.PGError;
        }

        this.mode = .sync;
    }

    pub inline fn makeAsync(this: *Connection) Error!void {
        std.debug.assert(this.mode == .sync);
        std.debug.assert(this.pooled);

        if (pq.PQsetnonblocking(this.conn, 1) != 0) {
            return Error.PGError;
        }

        this.mode = .async;
    }

    pub inline fn sendQueryParams(
        this: *Connection,
        query: [:0]const u8,
        params: []const ?[*]const u8,
        params_length: []const c_int,
        params_fmt: []const Format,
        result_fmt: Format,
    ) root.task.Poll(void, anyerror) {
        std.debug.assert(this.mode == .async);

        std.debug.assert(params.len <= std.math.maxInt(c_int));
        std.debug.assert(params.len == params_length.len);
        std.debug.assert(params.len == params_fmt.len);

        switch (this.waitReady()) {
            .ready => {},
            else => |res| return res,
        }

        std.debug.assert(this.state == .ready);

        if (pq.PQsendQueryParams(
            this.conn.?,
            query,
            @intCast(params.len),
            null,
            params.ptr,
            params_length.ptr,
            @ptrCast(params_fmt.ptr),
            result_fmt.toRaw(),
        ) != 1) {
            return .{ .err = Error.PGError };
        }

        this.state = .pending;

        return .ready;
    }

    pub inline fn errorMessage(this: *const Connection) [*c]const u8 {
        return pq.PQerrorMessage(this.conn.?);
    }

    /// Discards any result the owner did not consume. A query task normally
    /// returns as soon as it reads its first row and leaves the trailing NULL
    /// result unread, which keeps `state == .pending`. `rent()` only accepts
    /// `.ready` connections, so without this the pool would leak the connection
    /// permanently and eventually run out.
    pub inline fn drainResults(this: *Connection) void {
        std.debug.assert(this.mode == .async);

        _ = this.waitReady();
    }

    pub inline fn release(this: *Connection) void {
        std.debug.assert(this.pooled == true);

        const entry: *root.db.Pool.Entry = @fieldParentPtr("conn", this);

        std.debug.assert(entry.acquired > 0);

        // Drain only when the last reference is dropped, i.e. when the
        // connection is actually going back to the pool. While the refcount is
        // still positive another owner may be reading a result, and draining
        // would discard it from under them. The final owner leaves the trailing
        // NULL result unread, which keeps `state == .pending` and stops
        // `rent()` from handing the connection out again.
        if (entry.acquired == 1) {
            this.drainResults();
        }

        entry.acquired -= 1;
    }

    pub inline fn acquire(this: *Connection) void {
        std.debug.assert(this.pooled == true);

        this.getEntry().?.acquired += 1;
    }

    pub inline fn transactionStatus(this: *const Connection) c_uint {
        return pq.PQtransactionStatus(this.conn);
    }

    inline fn waitReady(this: *Connection) root.task.Poll(void, anyerror) {
        if (this.state == .ready) {
            return .ready;
        }

        while (!this.isBusy()) {
            if (this.getResult()) |res| {
                res.deinit();

                continue;
            }

            break;
        }

        if (this.state == .ready) {
            return .ready;
        }

        return .{ .pending = .db };
    }

    pub inline fn getEntry(this: *Connection) ?*root.db.Pool.Entry {
        if (this.pooled) {
            return @fieldParentPtr("conn", this);
        }

        return null;
    }
};
