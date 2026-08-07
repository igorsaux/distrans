const std = @import("std");
const builtin = @import("builtin");

pub const systemd = @import("watchdog/systemd.zig");

pub const Watchdog = if (builtin.target.os.tag == .linux)
    systemd.Systemd
else
    None;

const None = struct {
    pub inline fn init() None {
        return .{};
    }

    pub inline fn deinit(this: *None) void {
        _ = this;
    }

    pub inline fn onTick(this: *None) void {
        _ = this;
    }
};
