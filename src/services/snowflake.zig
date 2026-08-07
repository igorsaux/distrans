// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const EPOCH: usize = 1420070400000;

pub const Generator = struct {
    io: std.Io,
    worker_id: usize,
    last_timestamp: u64 = 0,
    sequence: u64 = 0,

    pub inline fn init(io: std.Io, worker_id: usize) Generator {
        return .{
            .io = io,
            .worker_id = worker_id,
        };
    }

    pub inline fn generate(this: *Generator) u64 {
        var now_ms: u64 = @intCast(std.Io.Timestamp.now(this.io, .real).toMilliseconds());

        if (now_ms == this.last_timestamp) {
            this.sequence = (this.sequence + 1) & 4095;

            if (this.sequence == 0) {
                while (now_ms <= this.last_timestamp) {
                    now_ms = @intCast(std.Io.Timestamp.now(this.io, .real).toMilliseconds());
                }
            }
        } else {
            this.sequence = 0;
        }

        this.last_timestamp = now_ms;

        const timestamp_part: usize = (now_ms - EPOCH) << 22;
        const worker_part: usize = this.worker_id << 12;

        return timestamp_part | worker_part | this.sequence;
    }
};
