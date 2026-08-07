// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.http);

pub const Connection = struct {
    pub const Peer = struct {
        gen: usize,
        ref: *root.net.Peer,

        pub inline fn isEq(this: Peer, gen: usize) bool {
            return this.gen == gen;
        }
    };

    pub const Parsing = struct {
        pub const Error = error{
            HasBody,
            BadMethod,
            PathTooLong,
            TooManyQueryParameters,
            TooManyCookies,
            BadVersion,
            BadHeaders,
            TooManyHeaders,
            BadContentLength,
            Unsupported,
        };

        peer: Peer,
        method: ?root.http.Method = null,
        /// Header value
        host: ?[]const u8 = null,
        /// Header value
        authorization: ?[]const u8 = null,
        /// Header value
        content_type: ?[]const u8 = null,
        /// Header value
        content_length: ?usize = null,
        content_start: ?usize = null,
    };

    pub const Handling = struct {
        peer: Peer,
        method: root.http.Method,
        /// Header value
        host: []const u8,
        /// Header value
        authorization: ?[]const u8,
        /// Header value
        content_type: ?[]const u8,
        content_length: usize,
        content_start: usize,
    };

    pub const Closing = struct {
        pub const Error = error{};

        peer: Peer,
    };

    pub const State = union(enum) {
        empty: void,
        parsing: Parsing,
        handling: Handling,
        closing: Closing,
    };

    state: State = .empty,
    path: std.ArrayList(u8) = .empty,
    params: std.ArrayList(root.http.QueryParameter) = .empty,
    headers: std.ArrayList(root.http.Header) = .empty,
    cookies: std.ArrayList([]const u8) = .empty,
    arena: std.heap.ArenaAllocator,
    task: ?root.http.Task = null,
    is_ws: bool = false,

    pub inline fn init(
        allocator: std.mem.Allocator,
    ) error{OutOfMemory}!Connection {
        var path = try std.ArrayList(u8).initCapacity(allocator, root.options.http.max_path_size);
        errdefer path.deinit(allocator);

        var query_params = try std.ArrayList(root.http.QueryParameter).initCapacity(allocator, root.options.http.max_query_params);
        errdefer query_params.deinit(allocator);

        var headers = try std.ArrayList(root.http.Header).initCapacity(allocator, root.options.http.max_headers);
        errdefer headers.deinit(allocator);

        var cookies = try std.ArrayList([]const u8).initCapacity(allocator, root.options.http.max_cookies);
        errdefer cookies.deinit(allocator);

        return .{
            .path = path,
            .params = query_params,
            .headers = headers,
            .cookies = cookies,
            .arena = .init(allocator),
        };
    }

    pub inline fn deinit(this: *Connection, allocator: std.mem.Allocator) void {
        this.path.deinit(allocator);
        this.params.deinit(allocator);
        this.headers.deinit(allocator);
        this.cookies.deinit(allocator);

        if (this.task) |*t| {
            t.dispose();
        }

        this.arena.deinit();
    }

    pub inline fn toEmpty(this: *Connection) void {
        this.path.items.len = 0;
        this.params.items.len = 0;
        this.headers.items.len = 0;
        this.cookies.items.len = 0;
        this.state = .empty;
        this.is_ws = false;

        if (this.task) |*t| {
            t.dispose();
            this.task = null;
        }

        _ = this.arena.reset(.retain_capacity);
    }

    pub inline fn toParsing(this: *Connection, peer: Peer) void {
        std.debug.assert(this.state == .empty);

        const new_state: State = .{
            .parsing = .{
                .peer = peer,
            },
        };

        this.state = new_state;
    }

    pub inline fn toHandling(this: *Connection) void {
        std.debug.assert(this.state == .parsing);

        const p = &this.state.parsing;
        const new_state: State = .{
            .handling = .{
                .peer = p.peer,
                .method = p.method.?,
                .host = p.host.?,
                .authorization = p.authorization,
                .content_type = p.content_type,
                .content_length = p.content_length orelse 0,
                .content_start = p.content_start orelse 0,
            },
        };

        this.state = new_state;
    }

    pub inline fn toClosing(this: *Connection) void {
        std.debug.assert(this.state != .empty);

        const peer = this.getPeer().?;
        peer.ref.toClosing();

        if (this.task) |*t| {
            t.dispose();
            this.task = null;
        }

        _ = this.arena.reset(.retain_capacity);

        const new_state: State = .{
            .closing = .{
                .peer = peer,
            },
        };

        this.state = new_state;
    }

    pub inline fn toClosingWith(this: *Connection, code: root.http.ResponseCode) void {
        std.debug.assert(this.state != .empty);

        const peer = this.getPeer().?;

        var writer: std.Io.Writer = .fixed(peer.ref.uplink.unusedCapacitySlice());
        writer.print(root.http.HTTP_VERSION ++ " {s}\r\n", .{code.toFullString()}) catch {
            SCOPE.warn("not enough space for response", .{});
            peer.ref.toFree();

            return;
        };

        writer.writeAll("Connection: close\r\n") catch {
            SCOPE.warn("not enough space for response", .{});
            peer.ref.toFree();

            return;
        };

        writer.writeAll("\r\n") catch {
            SCOPE.warn("not enough space for response", .{});
            peer.ref.toFree();

            return;
        };

        peer.ref.uplink.items.len += writer.end;
        this.toClosing();
    }

    pub inline fn getPeer(this: *const Connection) ?Peer {
        return switch (this.state) {
            .empty => null,
            .parsing => |*p| p.peer,
            .handling => |*h| h.peer,
            .closing => |*c| c.peer,
        };
    }

    pub inline fn parse(this: *Connection) Parsing.Error!bool {
        std.debug.assert(this.state == .parsing);

        const peer = this.getPeer().?;
        const p = &this.state.parsing;

        if (peer.ref.downlink.items.len == 0) {
            return false;
        }

        const content_delim = std.mem.find(u8, peer.ref.downlink.items, "\r\n\r\n") orelse {
            return false;
        };

        const content_start = content_delim + 4;
        p.content_start = content_start;

        var reader: std.Io.Reader = .fixed(peer.ref.downlink.items[0 .. content_delim + 2]);

        const method_raw = root.utils.readerTakeDelimiterScalar(&reader, ' ') orelse {
            return false;
        };

        p.method = root.http.Method.fromStr(method_raw) orelse {
            return Parsing.Error.BadMethod;
        };

        const path = root.utils.readerTakeDelimiterScalar(&reader, ' ') orelse {
            return false;
        };

        if (path.len > this.path.capacity) {
            return Parsing.Error.PathTooLong;
        }

        std.debug.assert(this.path.items.len == 0);
        this.path.appendSliceAssumeCapacity(path);

        std.debug.assert(this.params.items.len == 0);

        if (std.mem.findScalar(u8, path, '?')) |query_delim| {
            var query_reader: std.Io.Reader = .fixed(path[query_delim + 1 ..]);

            while (true) {
                if (this.params.items.len == this.params.capacity) {
                    return Parsing.Error.TooManyQueryParameters;
                }

                var is_last: bool = false;

                const pair = blk: {
                    if (root.utils.readerTakeDelimiterScalar(&query_reader, '&')) |value| {
                        break :blk value;
                    } else {
                        is_last = true;

                        break :blk query_reader.buffer[query_reader.seek..];
                    }
                };

                if (std.mem.findScalar(u8, pair, '=')) |delim| {
                    this.params.appendAssumeCapacity(.{
                        .key = pair[0..delim],
                        .value = pair[delim + 1 ..],
                    });
                } else {
                    this.params.appendAssumeCapacity(.{
                        .key = pair,
                        .value = &.{},
                    });
                }

                if (is_last) {
                    break;
                }
            }

            // Percent-decode every key/value in place. `std.Uri` only handles
            // `%XX` (a literal `+` is left untouched); the buffer is mutable
            // and decoding only shrinks each component, so the aliasing
            // guarantee of `percentDecodeBackwards` holds.
            for (this.params.items) |*param| {
                param.key = std.Uri.percentDecodeInPlace(@constCast(param.key));
                param.value = std.Uri.percentDecodeInPlace(@constCast(param.value));
            }
        }

        const version = root.utils.readerTakeDelimiter(&reader, "\r\n") orelse {
            return false;
        };

        if (!std.mem.eql(u8, version, root.http.HTTP_VERSION)) {
            return Parsing.Error.BadVersion;
        }

        SCOPE.debug("{f} '{s}' from '{f}'", .{
            p.method.?,
            this.path.items,
            peer.ref,
        });

        std.debug.assert(this.headers.items.len == 0);
        var i: usize = 0;

        // parse headers
        while (reader.seek != reader.end) : (i += 1) {
            if (this.headers.items.len == this.headers.capacity) {
                return Parsing.Error.TooManyHeaders;
            }

            var key = root.utils.readerTakeDelimiterScalar(&reader, ':') orelse {
                return Parsing.Error.BadHeaders;
            };

            key = std.mem.trim(u8, key, &.{' '});

            var value = root.utils.readerTakeDelimiter(&reader, "\r\n") orelse {
                return Parsing.Error.BadHeaders;
            };

            value = std.mem.trim(u8, value, &.{' '});

            for (key) |chr| {
                if (!std.ascii.isPrint(chr)) {
                    return Parsing.Error.BadHeaders;
                }
            }

            if (std.ascii.eqlIgnoreCase(key, "content-length")) {
                if (p.content_length != null) {
                    return Parsing.Error.BadHeaders;
                }

                const content_length = std.fmt.parseInt(usize, value, 10) catch {
                    return Parsing.Error.BadContentLength;
                };

                if (content_length > 0 and !p.method.?.canHaveBody()) {
                    return Parsing.Error.HasBody;
                }

                p.content_length = content_length;
            } else if (std.ascii.eqlIgnoreCase(key, "content-type")) {
                if (!p.method.?.canHaveBody()) {
                    return Parsing.Error.HasBody;
                }

                if (p.content_type != null) {
                    return Parsing.Error.BadHeaders;
                }

                p.content_type = value;
            } else if (std.ascii.eqlIgnoreCase(key, "host")) {
                if (p.host != null) {
                    return Parsing.Error.BadHeaders;
                }

                if (root.options.http.host != null) {
                    if (!std.mem.eql(u8, p.host.?, root.options.http.host.?)) {
                        return Parsing.Error.BadHeaders;
                    }
                }

                p.host = value;
            } else if (std.ascii.eqlIgnoreCase(key, "transfer-encoding")) {
                return Parsing.Error.Unsupported;
            } else if (std.ascii.eqlIgnoreCase(key, "cookie")) {
                var cookie_iter = std.mem.splitScalar(u8, value, ';');

                while (cookie_iter.next()) |cookie| {
                    if (this.cookies.items.len >= this.cookies.capacity) {
                        return Parsing.Error.TooManyCookies;
                    }

                    const trimmed = std.mem.trim(u8, cookie, " \r\n");

                    this.cookies.appendAssumeCapacity(trimmed);
                }
            } else if (std.ascii.eqlIgnoreCase(key, "authorization")) {
                p.authorization = value;
            }

            const header: root.http.Header = .{
                .key = key,
                .value = value,
            };

            this.headers.appendAssumeCapacity(header);
        }

        if (reader.seek != reader.end) {
            return Parsing.Error.BadHeaders;
        }

        std.debug.assert(this.path.items.len != 0);

        if (p.host == null) {
            return Parsing.Error.BadHeaders;
        }

        return true;
    }
};
