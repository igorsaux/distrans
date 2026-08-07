// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const builtin = @import("builtin");

const plat = @import("plat");

const SCOPE = std.log.scoped(.socket);

pub const Socket = extern struct {
    pub const Family = enum {
        unix,
        inet6,
    };

    pub const Address = struct {
        data: [@sizeOf(plat.sockaddr_storage)]u8,
        len: c_uint,

        pub inline fn format(this: *const Address, w: *std.Io.Writer) std.Io.Writer.Error!void {
            if (this.len <= @sizeOf(plat.sockaddr)) {
                return w.print("unnamed", .{});
            } else if (this.len == @sizeOf(plat.sockaddr_in6)) {
                const addr6: *align(1) const plat.sockaddr_in6 = std.mem.bytesAsValue(plat.sockaddr_in6, this.data[0..this.len]);

                const is_mapped = blk: {
                    const addr = std.mem.bytesAsSlice(u32, &std.mem.toBytes(addr6.sin6_addr));

                    break :blk addr[0] == 0 and addr[1] == 0 and addr[2] == plat.ntohl(0x0000ffff);
                };

                var buf: [plat.INET6_ADDRSTRLEN]u8 = undefined;

                if (is_mapped) {
                    var addr4: plat.in_addr = undefined;
                    @memcpy(std.mem.asBytes(&addr4), std.mem.asBytes(addr6)[@sizeOf(plat.sockaddr_in6) - 4 ..]);

                    _ = plat.inet_ntop(plat.AF_INET, &addr4, &buf, buf.len);
                } else {
                    _ = plat.inet_ntop(plat.AF_INET6, &addr6.sin6_addr, &buf, buf.len);
                }

                return w.print("{s}", .{std.mem.sliceTo(&buf, 0)});
            }
        }
    };

    pub const Error = error{
        IoError,
    };

    fd: c_int,

    pub inline fn new(domain: c_int, ty: c_int, proto: c_int) Error!Socket {
        const fd = plat.socket(domain, ty, proto);

        if (fd < 0) {
            return Error.IoError;
        }

        return .{ .fd = fd };
    }

    pub inline fn close(this: Socket) void {
        _ = plat.close(this.fd);
    }

    pub inline fn shutdown(this: Socket, how: c_int) Error!void {
        if (plat.shutdown(this.fd, how) < 0) {
            return Error.IoError;
        }
    }

    pub inline fn setopt(this: Socket, level: c_int, option: c_int, value: ?[]const u8) Error!void {
        if (value != null) {
            std.debug.assert(value.?.len <= std.math.maxInt(plat.socklen_t));
        }

        const ret = if (value == null)
            plat.setsockopt(this.fd, level, option, null, 0)
        else
            plat.setsockopt(this.fd, level, option, value.?.ptr, @intCast(value.?.len));

        if (ret < 0) {
            return Error.IoError;
        }
    }

    /// Builds a `sockaddr_un` for `path`, zero-filling the struct so the path
    /// is always NUL-terminated within `sun_path`.
    pub inline fn unixSockaddr(path: []const u8) Error!plat.sockaddr_un {
        var sockaddr: plat.sockaddr_un = std.mem.zeroes(plat.sockaddr_un);

        if (path.len + 1 > sockaddr.sun_path.len) {
            return Error.IoError;
        }

        switch (builtin.os.tag) {
            .macos, .freebsd => {
                sockaddr.sun_family = plat.AF_UNIX;
                sockaddr.sun_len = @sizeOf(plat.sockaddr_un);
            },
            .linux => {
                sockaddr.sun_family = plat.AF_UNIX;
            },
            else => @compileError("Not implemented"),
        }

        @memcpy(sockaddr.sun_path[0..path.len], path);

        return sockaddr;
    }

    pub inline fn bindUnix(this: Socket, path: []const u8) Error!void {
        var sockaddr = try unixSockaddr(path);

        if (plat.bind(this.fd, @ptrCast(&sockaddr), @sizeOf(plat.sockaddr_un)) < 0) {
            return Error.IoError;
        }
    }

    pub inline fn connectUnix(this: Socket, path: []const u8) Error!void {
        var sockaddr = try unixSockaddr(path);

        if (plat.connect(this.fd, @ptrCast(&sockaddr), @sizeOf(plat.sockaddr_un)) < 0) {
            return Error.IoError;
        }
    }

    pub inline fn connectInet(this: Socket, host: [:0]const u8, port: [:0]const u8) Error!void {
        var res: *plat.addrinfo = undefined;
        const hints: plat.addrinfo = .{
            .ai_family = plat.AF_INET6,
            .ai_socktype = plat.SOCK_STREAM,
        };

        if (plat.getaddrinfo(host, port, &hints, @ptrCast(&res)) != 0) {
            return Error.IoError;
        }

        defer plat.freeaddrinfo(res);

        if (plat.connect(this.fd, res.ai_addr, res.ai_addrlen) < 0) {
            return Error.IoError;
        }
    }

    /// Fills `addr` with the local address this socket is bound to. Useful to
    /// learn the kernel-assigned port when binding to port 0.
    pub inline fn getsockname(this: Socket, addr: *Address) Error!void {
        addr.len = addr.data.len;

        if (plat.getsockname(this.fd, @ptrCast(@alignCast(&addr.data)), &addr.len) < 0) {
            return Error.IoError;
        }
    }

    pub inline fn bind(this: Socket, addr: *plat.sockaddr, len: c_uint) Error!void {
        if (plat.bind(this.fd, addr, len) < 0) {
            return Error.IoError;
        }
    }

    pub inline fn listen(this: Socket, backlog: usize) Error!void {
        std.debug.assert(backlog <= std.math.maxInt(c_int));

        if (plat.listen(this.fd, @intCast(backlog)) < 0) {
            return Error.IoError;
        }
    }

    pub inline fn accept(this: Socket, sockaddr: *plat.sockaddr, socklen: *c_uint) Error!Socket {
        const fd = plat.accept(this.fd, sockaddr, socklen);

        if (fd < 0) {
            return Error.IoError;
        }

        return .{
            .fd = fd,
        };
    }

    pub inline fn read(this: Socket, buffer: []u8) Error![]u8 {
        const n = plat.read(this.fd, buffer.ptr, buffer.len);

        if (n < 0) {
            return Error.IoError;
        }

        return buffer[0..@intCast(n)];
    }

    pub inline fn write(this: Socket, content: []const u8) Error!usize {
        const n = plat.write(this.fd, content.ptr, content.len);

        if (n < 0) {
            return Error.IoError;
        }

        return @intCast(n);
    }

    pub inline fn writeAll(this: Socket, content: []const u8) Error!void {
        var i: usize = 0;

        while (i < content.len) {
            const n = try this.write(content[i..]);

            // A zero-length write makes no progress; bail out instead of
            // spinning forever.
            if (n == 0) {
                return Error.IoError;
            }

            i += n;
        }
    }

    pub inline fn setNonBlocking(this: Socket) Error!void {
        switch (builtin.os.tag) {
            .macos, .freebsd, .linux => {
                const flags = plat.fcntl(this.fd, plat.F_GETFL, @as(c_int, 0));

                if (flags < 0) {
                    return Error.IoError;
                }

                if (plat.fcntl(this.fd, plat.F_SETFL, flags | plat.O_NONBLOCK) < 0) {
                    return Error.IoError;
                }
            },
            else => @compileError("Not implemented"),
        }
    }
};
