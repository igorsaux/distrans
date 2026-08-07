// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("root.zig");

const SCOPE = std.log.scoped(.worker);

pub fn Worker(comptime Spec: type) type {
    return struct {
        const Self = @This();

        pub const Payload = Spec.Payload;
        pub const Result = Spec.Result;

        pub const JobResult = union(enum) {
            ok: Result,
            err: anyerror,
        };

        pub const Job = struct {
            const State = union(enum) {
                free,
                working: Payload,
                done: Result,
                err: anyerror,
            };

            mutex: std.Io.Mutex = .init,
            state: State = .free,
            cancelled: std.atomic.Value(bool) = .init(false),

            /// The result is owned by the job.
            pub inline fn check(this: *Job) ?JobResult {
                if (!this.mutex.tryLock()) {
                    return null;
                }
                defer this.mutex.unlock(root.io);

                switch (this.state) {
                    .err => |err| return .{ .err = err },
                    .done => |result| return .{ .ok = result },
                    else => return null,
                }
            }

            pub inline fn cancel(this: *Job) void {
                this.cancelled.store(true, .monotonic);
            }

            pub inline fn release(this: *Job) void {
                if (this.mutex.tryLock()) {
                    defer this.mutex.unlock(root.io);

                    this.toFree();

                    return;
                }

                this.cancel();
            }

            inline fn toWorking(this: *Job, payload: Payload) !void {
                std.debug.assert(this.state != .working);

                this.toFree();

                const result_payload = payload.dupe() catch |err| {
                    SCOPE.err("failed to dupe a payload: {t}", .{err});

                    return err;
                };

                this.cancelled = .init(false);
                this.state = .{
                    .working = result_payload,
                };
            }

            inline fn toFree(this: *Job) void {
                switch (this.state) {
                    .working => |payload| payload.deinit(),
                    .done => |result| result.deinit(),
                    else => {},
                }

                this.state = .free;
                this.cancelled = .init(false);
            }
        };

        jobs: []Job,
        scratch: std.heap.ArenaAllocator,
        exiting: std.atomic.Value(bool) = .init(false),
        new_event: std.Io.Event = .unset,
        thread: ?std.Thread = null,

        pub inline fn init(max_jobs: usize) !Self {
            try Spec.onInit();

            const jobs = try root.gpa.alloc(Job, max_jobs);
            errdefer root.gpa.free(jobs);

            @memset(jobs, .{});

            return .{
                .jobs = jobs,
                .scratch = .init(root.gpa),
            };
        }

        pub inline fn deinit(this: *Self) void {
            // The worker thread is already joined, so the locks are uncontended.
            // Any slot still holding data is freed here.
            for (this.jobs) |*job| {
                job.mutex.lock(root.io) catch @panic("failed to lock mutex");
                job.toFree();
                job.mutex.unlock(root.io);
            }

            this.scratch.deinit();
            root.gpa.free(this.jobs);
        }

        pub inline fn run(this: *Self) !void {
            std.debug.assert(this.thread == null);

            this.thread = try std.Thread.spawn(.{
                .allocator = root.gpa,
            }, workerThread, .{this});
        }

        pub inline fn stop(this: *Self) void {
            std.debug.assert(this.thread != null);

            this.exiting.store(true, .monotonic);
            this.awake();
            this.thread.?.join();
        }

        /// Wakes the worker so it runs another pass. Called both when a job is
        /// queued and when a job is cancelled after the worker's last
        /// `cancelled` check, since the flag alone would not be observed.
        pub inline fn awake(this: *Self) void {
            this.new_event.set(root.io);
        }

        /// Returns null when every slot is busy.
        pub inline fn spawn(this: *Self, payload: Payload) !?*Job {
            for (this.jobs) |*job| {
                if (!job.mutex.tryLock()) {
                    continue;
                }
                defer job.mutex.unlock(root.io);

                if (job.state == .working) {
                    continue;
                }

                if (job.state != .free) {
                    if (job.cancelled.load(.monotonic)) {
                        job.toFree();
                    } else {
                        continue;
                    }
                }

                try job.toWorking(payload);
                this.awake();

                return job;
            }

            return null;
        }

        inline fn doJobs(this: *Self) void {
            _ = this.scratch.reset(.retain_capacity);

            const scratch = this.scratch.allocator();

            for (this.jobs) |*job| {
                // Worker thread: blocking is fine here, and waiting (instead of
                // skipping) means one pass observes every slot.
                job.mutex.lock(root.io) catch @panic("failed to lock mutex");
                defer job.mutex.unlock(root.io);

                if (job.cancelled.load(.monotonic)) {
                    job.toFree();

                    continue;
                }

                if (job.state != .working) {
                    continue;
                }

                const work = &job.state.working;

                if (Spec.run(scratch, work)) |result| {
                    job.state.working.deinit();
                    job.state = .{ .done = result };
                } else |err| {
                    job.state.working.deinit();
                    job.state = .{ .err = err };
                }

                if (job.cancelled.load(.monotonic)) {
                    job.toFree();
                }
            }
        }

        fn workerThread(this: *Self) void {
            while (true) {
                this.new_event.wait(root.io) catch @panic("failed to wait for an event");
                this.new_event.reset();

                if (this.exiting.load(.monotonic)) {
                    return;
                }

                this.doJobs();
            }
        }
    };
}
