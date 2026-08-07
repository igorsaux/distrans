// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../root.zig");

pub const Method = enum {
    get,
    post,
    put,
    patch,
    delete,

    pub inline fn canHaveBody(this: Method) bool {
        if (this == .get or this == .delete) {
            return false;
        }

        return true;
    }

    pub inline fn fromStr(str: []const u8) ?Method {
        if (std.mem.eql(u8, str, "GET")) {
            return .get;
        } else if (std.mem.eql(u8, str, "POST")) {
            return .post;
        } else if (std.mem.eql(u8, str, "PUT")) {
            return .put;
        } else if (std.mem.eql(u8, str, "PATCH")) {
            return .patch;
        } else if (std.mem.eql(u8, str, "DELETE")) {
            return .delete;
        }

        return null;
    }

    pub inline fn toStr(this: Method) []const u8 {
        return switch (this) {
            .get => "GET",
            .post => "POST",
            .put => "PUT",
            .patch => "PATCH",
            .delete => "DELETE",
        };
    }

    pub inline fn format(this: Method, w: *std.Io.Writer) std.Io.Writer.Error!void {
        return w.writeAll(this.toStr());
    }
};

pub const QueryParameter = struct {
    key: []const u8,
    value: []const u8,
};

pub const Header = struct {
    key: []const u8,
    value: []const u8,
};

pub const Request = struct {
    path: []const u8,
    params: []QueryParameter,
    method: Method,
    /// Header value
    host: []const u8,
    /// Header value
    authorization: ?[]const u8,
    /// Header value
    cookies: [][]const u8,
    /// Header value
    content_type: ?[]const u8,
    headers: []Header,
    conn: *root.http.Connection,
    peer: *root.net.Peer,

    pub inline fn isBodyEmpty(this: *const Request) bool {
        return this.content_length == 0 and this.content_type == null;
    }

    pub inline fn findHeader(this: *const Request, name: []const u8) ?[]const u8 {
        for (this.headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.key, name)) {
                return header.value;
            }
        }

        return null;
    }

    pub inline fn contentIsAvailable(this: *const Request) bool {
        return this.getContent().len == this.getContentLength();
    }

    pub inline fn getContent(this: *const Request) []const u8 {
        std.debug.assert(this.conn.state == .handling);

        const downlink = this.peer.downlink.items;
        const content_start = this.conn.state.handling.content_start;
        const content = downlink[content_start..];

        return content[0..@min(this.getContentLength(), content.len)];
    }

    pub inline fn getContentLength(this: *const Request) usize {
        std.debug.assert(this.conn.state == .handling);

        return this.conn.state.handling.content_length;
    }

    pub inline fn consumeContent(this: *const Request, count: usize) void {
        std.debug.assert(this.conn.state == .handling);
        std.debug.assert(count <= this.conn.state.handling.content_length);

        this.conn.state.handling.content_length -= count;

        if (count == 0) {
            return;
        }

        const content_start = this.conn.state.handling.content_start;
        const content = this.peer.downlink.items[content_start..];

        std.debug.assert(count <= content.len);

        @memmove(content[0..(content.len - count)], content[count..]);
        this.peer.downlink.items.len -= count;
    }
};
