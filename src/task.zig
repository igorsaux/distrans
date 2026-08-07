// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

pub const Pending = union(enum) {
    ws,
    job,
    db,
    want_read,
    want_write,
};

pub inline fn Poll(comptime T: type, comptime E: type) type {
    return union(enum) {
        const Self = @This();

        pending: Pending,
        ready: T,
        err: E,

        pub inline fn map(this: Self, comptime T2: type, value: T2) Poll(T2, E) {
            if (this != .ready) {
                return switch (this) {
                    .pending => .{ .pending = this.pending },
                    .err => .{ .err = this.err },
                    .ready => unreachable,
                };
            }

            return .{ .ready = value };
        }

        pub inline fn mapDiscard(this: Self, comptime T2: type) Poll(T2, E) {
            std.debug.assert(this != .ready);

            return switch (this) {
                .pending => .{ .pending = this.pending },
                .err => .{ .err = this.err },
                .ready => unreachable,
            };
        }

        pub inline fn discard(this: Self) Poll(void, E) {
            return this.map(void, {});
        }

        pub inline fn toStreamPoll(this: Self) PollStream(T, E) {
            return switch (this) {
                .pending => .{ .pending = this.pending },
                .err => .{ .err = this.err },
                .ready => .{ .yielded = this.ready },
            };
        }
    };
}

pub inline fn Task(comptime T: type, comptime E: type) type {
    return struct {
        const Self = @This();

        pub const PollT = Poll(T, E);

        const VTable = struct {
            poll: *const fn (ctx: *anyopaque) PollT,
            dispose: *const fn (ctx: *anyopaque) void,
        };

        ctx: *anyopaque,
        vtable: *const VTable,

        pub inline fn init(ctx: *anyopaque, vtable: *const VTable) Self {
            return .{
                .ctx = ctx,
                .vtable = vtable,
            };
        }

        pub inline fn poll(this: Self) PollT {
            return this.vtable.poll(this.ctx);
        }

        pub inline fn dispose(this: Self) void {
            this.vtable.dispose(this.ctx);
        }
    };
}

pub inline fn LazyTask(comptime C: type, comptime T: type, comptime E: type) type {
    return struct {
        const Self = @This();

        pub const TaskT = Task(T, E);
        pub const PollT = TaskT.PollT;

        ctx: C,
        result: T = undefined,
        done: bool = false,

        pub inline fn from(ctx: C) Self {
            return .{
                .ctx = ctx,
            };
        }

        pub inline fn task(this: *Self) TaskT {
            return this.ctx.task();
        }

        pub inline fn await(this: *Self) ?PollT {
            if (this.done) {
                return null;
            }

            const res = this
                .task()
                .poll();

            if (res == .ready) {
                this.done = true;
                this.result = res.ready;

                return null;
            }

            return res;
        }

        pub inline fn dispose(this: *Self) void {
            this
                .task()
                .dispose();
        }
    };
}

pub inline fn PollStream(comptime T: type, comptime E: type) type {
    return union(enum) {
        const Self = @This();

        pending: Pending,
        yielded: T,
        done,
        err: E,

        pub inline fn mapDiscard(this: Self, comptime T2: type) PollStream(T2, E) {
            std.debug.assert(this != .yielded);

            return switch (this) {
                .pending => .{ .pending = this.pending },
                .yielded => unreachable,
                .err => .{ .err = this.err },
                .done => .{ .pending = this.pending },
            };
        }

        pub inline fn toPoll(
            this: Self,
        ) Poll(T, E) {
            std.debug.assert(this != .done);

            return switch (this) {
                .pending => .{ .pending = this.pending },
                .yielded => .{ .ready = this.yielded },
                .err => .{ .err = this.err },
                .done => unreachable,
            };
        }
    };
}

pub inline fn Stream(comptime T: type, comptime E: type) type {
    return struct {
        const Self = @This();

        pub const PollT = PollStream(T, E);

        const VTable = struct {
            poll: *const fn (ctx: *anyopaque) PollT,
            dispose: *const fn (ctx: *anyopaque) void,
        };

        ctx: *anyopaque,
        vtable: *const VTable,

        pub inline fn init(ctx: *anyopaque, vtable: *const VTable) Self {
            return .{
                .ctx = ctx,
                .vtable = vtable,
            };
        }

        pub inline fn poll(this: Self) PollT {
            return this.vtable.poll(this.ctx);
        }

        pub inline fn dispose(this: Self) void {
            this.vtable.dispose(this.ctx);
        }
    };
}

pub inline fn LazyStream(comptime C: type, comptime T: type, comptime E: type) type {
    return struct {
        const Self = @This();

        pub const StreamT = Stream(T, E);
        pub const PollT = StreamT.PollT;

        ctx: C,
        done: bool = false,

        pub inline fn from(ctx: C) Self {
            return .{
                .ctx = ctx,
            };
        }

        pub inline fn stream(this: *Self) StreamT {
            return this.ctx.stream();
        }

        pub inline fn await(this: *Self) ?union(enum) { next: T, poll: Poll(T, E) } {
            if (this.done) {
                return null;
            }

            const res = this
                .stream()
                .poll();

            switch (res) {
                .done => {
                    this.done = true;

                    return null;
                },
                .yielded => |y| return .{ .next = y },
                else => return .{ .poll = res.toPoll() },
            }

            return res;
        }

        pub inline fn dispose(this: *Self) void {
            this
                .stream()
                .dispose();
        }
    };
}
