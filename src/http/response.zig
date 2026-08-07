// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../root.zig");

pub const Task = root.task.Task(void, anyerror);

pub const HTTP_VERSION = "HTTP/1.1";

pub const ResponseCode = enum {
    /// 101
    switching_protocols,
    /// 200
    ok,
    /// 201
    created,
    /// 204
    no_content,
    /// 302
    found,
    /// 400
    bad_request,
    /// 401
    unauthorized,
    /// 403
    forbidden,
    /// 404
    not_found,
    /// 405
    method_not_allowed,
    /// 409
    conflict,
    /// 413
    content_too_large,
    /// 414,
    uri_too_long,
    /// 415
    unsupported_media_type,
    /// 431
    request_header_fields_too_large,
    /// 500
    internal_server_error,
    /// 503
    service_unavailable,
    /// 505
    http_version_not_supported,

    pub inline fn toFullString(this: ResponseCode) []const u8 {
        return switch (this) {
            .switching_protocols => "101 Switching Protocols",
            .ok => "200 OK",
            .created => "201 Created",
            .no_content => "204 No Content",
            .found => "302 Found",
            .bad_request => "400 Bad Request",
            .unauthorized => "401 Unauthorized",
            .forbidden => "403 Forbidden",
            .not_found => "404 Not Found",
            .method_not_allowed => "405 Method Not Allowed",
            .conflict => "409 Conflict",
            .content_too_large => "413 Content Too Large",
            .uri_too_long => "414 URI Too Long",
            .unsupported_media_type => "415 Unsupported Media Type",
            .request_header_fields_too_large => "431 Request Header Fields Too Large",
            .internal_server_error => "500 Internal Server Error",
            .service_unavailable => "503 Service Unavailable",
            .http_version_not_supported => "505 HTTP Version Not Supported",
        };
    }

    pub inline fn toCode(this: ResponseCode) []const u8 {
        return switch (this) {
            .switching_protocols => "101",
            .ok => "200",
            .created => "201",
            .no_content => "204",
            .found => "302",
            .bad_request => "400",
            .unauthorized => "401",
            .forbidden => "403",
            .not_found => "404",
            .method_not_allowed => "405",
            .conflict => "409",
            .content_too_large => "413",
            .uri_too_long => "414",
            .unsupported_media_type => "415",
            .request_header_fields_too_large => "431",
            .internal_server_error => "500",
            .service_unavailable => "503",
            .http_version_not_supported => "505",
        };
    }
};

pub const Response = struct {
    pub const Writer = struct {
        peer: *root.net.Peer,
        writer: std.Io.Writer,
        auto_close: bool = true,
        wrote_code: bool = false,
        wrote_headers: bool = false,

        pub inline fn withoutAutoClose(this: Writer) Writer {
            var copy = this;
            copy.auto_close = false;

            return copy;
        }

        pub inline fn afterHeaders(this: Writer) Writer {
            var copy = this;
            copy.wrote_code = true;
            copy.wrote_headers = true;

            return copy;
        }

        pub inline fn writeCode(this: *Writer, code: ResponseCode) bool {
            std.debug.assert(this.wrote_code == false);
            std.debug.assert(this.wrote_headers == false);

            this.writer.print(HTTP_VERSION ++ " {s}\r\n", .{code.toFullString()}) catch {
                return false;
            };

            if (this.auto_close) {
                this.writer.writeAll("Connection: Close\r\n") catch {
                    return false;
                };
            }

            this.wrote_code = true;

            return true;
        }

        pub inline fn writeHeader(
            this: *Writer,
            name: []const u8,
            comptime fmt: []const u8,
            args: anytype,
        ) bool {
            std.debug.assert(this.wrote_code == true);
            std.debug.assert(this.wrote_headers == false);

            this.writer.print("{s}: " ++ fmt ++ "\r\n", .{name} ++ args) catch {
                return false;
            };

            return true;
        }

        pub inline fn beginBody(this: *Writer, content_type: []const u8, body_len: usize) bool {
            std.debug.assert(this.wrote_code == true);
            std.debug.assert(this.wrote_headers == false);

            if (!this.writeHeader("Content-Type", "{s}", .{content_type})) {
                return false;
            }

            if (!this.writeHeader("Content-Length", "{}", .{body_len})) {
                return false;
            }

            this.writer.writeAll("\r\n") catch {
                return false;
            };

            this.wrote_headers = true;

            return true;
        }

        pub inline fn beginJSON(this: *Writer, body_len: usize) bool {
            return this.beginBody("application/json", body_len);
        }

        pub inline fn writeBody(this: *Writer, content_type: []const u8, body: []const u8) bool {
            if (!this.beginBody(content_type, body.len)) {
                return false;
            }

            this.writer.writeAll(body) catch {
                return false;
            };

            return true;
        }

        pub inline fn writeJSON(this: *Writer, content: []const u8) bool {
            return this.writeBody("application/json", content);
        }

        pub inline fn emptyBody(this: *Writer) bool {
            std.debug.assert(this.wrote_code == true);
            std.debug.assert(this.wrote_headers == false);

            this.writer.writeAll("\r\n") catch {
                return false;
            };

            this.wrote_headers = true;

            return true;
        }

        pub inline fn commit(this: *const Writer) void {
            std.debug.assert(this.wrote_code == true);
            std.debug.assert(this.wrote_headers == true);

            this.peer.uplink.items.len += this.writer.end;
            std.debug.assert(this.peer.uplink.items.len <= this.peer.uplink.capacity);
        }
    };

    pub const Streamer = struct {
        content: []const u8,
        peer: *root.net.Peer,
        streamed: usize = 0,

        pub inline fn poll(this: *Streamer) Task.PollT {
            var writer: Writer = .{
                .peer = this.peer,
                .writer = .fixed(this.peer.uplink.unusedCapacitySlice()),
                .wrote_code = true,
                .wrote_headers = true,
            };
            defer writer.commit();

            while (this.streamed < this.content.len) {
                const available = writer.writer.buffer.len - writer.writer.end;

                if (available == 0) {
                    return .{ .pending = .want_write };
                }

                const chunk_len = @min(available, this.content.len - this.streamed);

                writer.writer.writeAll(this.content[this.streamed..][0..chunk_len]) catch {
                    return .{ .pending = .want_write };
                };

                this.streamed += chunk_len;
            }

            return .ready;
        }
    };

    allocator: std.mem.Allocator,
    peer: *root.net.Peer,

    pub inline fn getWriter(this: Response) Writer {
        return .{
            .peer = this.peer,
            .writer = .fixed(this.peer.uplink.unusedCapacitySlice()),
        };
    }

    pub inline fn getStreamer(this: Response, content: []const u8) Streamer {
        return .{
            .content = content,
            .peer = this.peer,
        };
    }
};
