// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.system_token_middleware);

pub const SystemTokenMiddleware = struct {
    pub const Result = bool;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(SystemTokenMiddleware, Result, anyerror);

    request: *const root.http.Request,
    response: *root.http.Response,
    result: ?bool = null,

    inline fn verify(this: *SystemTokenMiddleware) bool {
        const expected = root.options.system.token;

        const header = this.request.authorization orelse {
            return false;
        };

        const token_delim = std.mem.findScalar(u8, header, ' ') orelse {
            return false;
        };

        if (token_delim + 1 >= header.len) {
            return false;
        }

        const bearer = header[0..token_delim];

        if (!std.mem.eql(u8, std.mem.trim(u8, bearer, " "), "Bearer")) {
            return false;
        }

        const token = std.mem.trim(u8, header[token_delim + 1 ..], " ");

        if (token.len != expected.len) {
            return false;
        }

        // constant-time comparison
        var acc: u8 = 0;

        for (token, expected) |a, b| {
            acc |= a ^ b;
        }

        if (acc != 0) {
            return false;
        }

        return true;
    }

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *SystemTokenMiddleware = @ptrCast(@alignCast(ctx));

        if (this.result == null) {
            this.result = this.verify();
        }

        if (this.result.?) {
            return .{ .ready = true };
        }

        return root.route.generic
            .responseErrorMessage(this.response, .unauthorized, "Bad system token")
            .map(Result, false);
    }

    fn dispose(ctx: *anyopaque) void {
        _ = ctx;
    }

    pub inline fn init(request: *const root.http.Request, response: *root.http.Response) SystemTokenMiddleware {
        return .{
            .request = request,
            .response = response,
        };
    }

    pub inline fn task(this: *SystemTokenMiddleware) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};
