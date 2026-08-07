// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.pwhash_worker);

pub const VerifyPassword = struct {
    pub const Item = bool;

    pub const Result = Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(VerifyPassword, Result, anyerror);

    pub const Payload = struct {
        hash: []const u8,
        password: []const u8,
    };

    const State = enum {
        start,
        waiting,
        ready,
    };

    payload: Payload,
    job: ?*Worker.Job = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *VerifyPassword = @ptrCast(@alignCast(ctx));

        if (this.job == null) {
            this.job = root.pwhash_worker.spawn(.{
                .verify = .{
                    .hash = this.payload.hash,
                    .password = this.payload.password,
                },
            }) catch |err| {
                SCOPE.err("VerifyPassword failed to spawn a job: {t}", .{err});

                return .{ .err = err };
            } orelse {
                return .{ .pending = .job };
            };
        }

        if (this.job.?.check()) |res| {
            switch (res) {
                .ok => |ok| return .{ .ready = ok.verify },
                .err => |err| return .{ .err = err },
            }
        }

        return .{ .pending = .job };
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *VerifyPassword = @ptrCast(@alignCast(ctx));

        if (this.job) |j| {
            j.release();
            this.job = null;
        }
    }

    pub inline fn init(payload: Payload) VerifyPassword {
        return .{
            .payload = payload,
        };
    }

    pub inline fn task(this: *VerifyPassword) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const HashPassword = struct {
    pub const Item = []const u8;

    pub const Result = Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(HashPassword, Result, anyerror);

    pub const Payload = struct {
        password: []const u8,
    };

    payload: Payload,
    job: ?*Worker.Job = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *HashPassword = @ptrCast(@alignCast(ctx));

        if (this.job == null) {
            this.job = root.pwhash_worker.spawn(.{
                .hash = .{
                    .password = this.payload.password,
                },
            }) catch |err| {
                SCOPE.err("HashPassword failed to spawn a job: {t}", .{err});

                return .{ .err = err };
            } orelse {
                return .{ .pending = .job };
            };
        }

        if (this.job.?.check()) |res| {
            switch (res) {
                .ok => |ok| return .{ .ready = ok.hash },
                .err => |err| return .{ .err = err },
            }
        } else {
            return .{ .pending = .job };
        }
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *HashPassword = @ptrCast(@alignCast(ctx));

        if (this.job) |j| {
            j.release();
            this.job = null;
        }
    }

    pub inline fn init(payload: Payload) HashPassword {
        return .{
            .payload = payload,
        };
    }

    pub inline fn task(this: *HashPassword) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

const Spec = struct {
    const Self = @This();

    pub const Payload = union(enum) {
        verify: struct {
            hash: []const u8,
            password: []const u8,
        },
        hash: struct {
            password: []const u8,
        },

        pub inline fn dupe(this: Payload) !Payload {
            switch (this) {
                .verify => |v| {
                    const hash = try root.gpa.dupe(u8, v.hash);
                    errdefer root.gpa.free(hash);

                    const password = try root.gpa.dupe(u8, v.password);
                    errdefer root.gpa.free(password);

                    return .{
                        .verify = .{
                            .hash = hash,
                            .password = password,
                        },
                    };
                },
                .hash => |h| {
                    const password = try root.gpa.dupe(u8, h.password);
                    errdefer root.gpa.free(password);

                    return .{
                        .hash = .{
                            .password = password,
                        },
                    };
                },
            }
        }

        pub inline fn deinit(this: Payload) void {
            switch (this) {
                .verify => |v| {
                    root.gpa.free(v.hash);
                    root.gpa.free(v.password);
                },
                .hash => |h| {
                    root.gpa.free(h.password);
                },
            }
        }
    };

    pub const Result = union(enum) {
        verify: bool,
        hash: []u8,

        pub inline fn deinit(this: Result) void {
            switch (this) {
                .verify => {},
                .hash => |hash| root.gpa.free(hash),
            }
        }
    };

    pub inline fn onInit() !void {}

    pub inline fn run(
        scratch: std.mem.Allocator,
        payload: *Payload,
    ) anyerror!Result {
        switch (payload.*) {
            .verify => |v| {
                std.crypto.pwhash.argon2.strVerify(v.hash, v.password, .{
                    .allocator = scratch,
                }, root.io) catch {
                    return .{ .verify = false };
                };

                return .{ .verify = true };
            },
            .hash => |h| {
                var buf: [256]u8 = undefined;

                // `strHash` writes the encoding into `buf` and returns a slice of
                // it, so the result must be copied out of the per-pass scratch.
                const encoded = try std.crypto.pwhash.argon2.strHash(h.password, .{
                    .allocator = scratch,
                    .params = .{
                        .t = root.options.auth.password.iterations,
                        .m = root.options.auth.password.memory_kib,
                        .p = root.options.auth.password.parallelism,
                    },
                }, &buf, root.io);

                return .{
                    .hash = try root.gpa.dupe(u8, encoded),
                };
            },
        }
    }
};

pub const Worker = root.worker.Worker(Spec);
