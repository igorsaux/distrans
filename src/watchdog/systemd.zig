// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const builtin = @import("builtin");

const systemd = @import("systemd");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.systemd);

pub const Systemd = struct {
    arena: std.heap.ArenaAllocator,
    last_notify_ts: std.Io.Timestamp = .zero,

    pub inline fn init() Systemd {
        _ = systemd.sd_notify(0, "READY=1");

        return .{
            .arena = .init(root.gpa),
        };
    }

    pub inline fn deinit(this: *Systemd) void {
        _ = systemd.sd_notify(0, "STOPPING=1");

        this.arena.deinit();
    }

    pub inline fn onTick(this: *Systemd) void {
        if (root.options.general.watchdog_interval_s == null) {
            return;
        }

        const now_ts = std.Io.Timestamp.now(root.io, .awake);

        if (now_ts.toSeconds() - this.last_notify_ts.toSeconds() > root.options.general.watchdog_interval_s.?) {
            _ = this.arena.reset(.retain_capacity);

            SCOPE.debug("watchdog notify", .{});

            this.last_notify_ts = now_ts;
            _ = systemd.sd_notify(0, "WATCHDOG=1");

            var connected_peers: usize = 0;

            for (root.socket_server.peers) |*p| {
                if (p.state == .connected) {
                    connected_peers += 1;
                }
            }

            const status_str = std.fmt.allocPrintSentinel(
                this.arena.allocator(),
                "STATUS=Clients: {}",
                .{connected_peers},
                0,
            ) catch @panic("OOM");

            _ = systemd.sd_notify(0, status_str);
        }
    }
};
