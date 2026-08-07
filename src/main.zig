// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const builtin = @import("builtin");

const distrans = @import("distrans");
const plat = @import("plat");

var io: std.Io = .failing;
var exit: std.Io.Event = .unset;

fn signalHandler(signum: c_int) callconv(.c) void {
    _ = signum;

    exit.set(io);
}

fn ignoreSignalHandler(signum: c_int) callconv(.c) void {
    _ = signum;
}

pub fn main(init: std.process.Init) !void {
    io = init.io;

    {
        const sa: plat.struct_sigaction = if (builtin.os.tag == .macos or builtin.os.tag == .freebsd)
            .{
                .__sigaction_u = .{ .__sa_handler = signalHandler },
            }
        else if (builtin.os.tag == .linux)
            .{
                .__sigaction_handler = .{ .sa_handler = signalHandler },
            }
        else
            @compileError("Not implemented");

        _ = plat.sigaction(plat.SIGINT, &sa, null);
        _ = plat.sigaction(plat.SIGTERM, &sa, null);
        _ = plat.sigaction(plat.SIGQUIT, &sa, null);
    }

    {
        // Never let a write to a peer that closed its socket kill the process;
        // with a handler installed `write` returns EPIPE instead.
        const ignore: plat.struct_sigaction = if (builtin.os.tag == .macos or builtin.os.tag == .freebsd)
            .{
                .__sigaction_u = .{ .__sa_handler = ignoreSignalHandler },
            }
        else if (builtin.os.tag == .linux)
            .{
                .__sigaction_handler = .{ .sa_handler = ignoreSignalHandler },
            }
        else
            @compileError("Not implemented");

        _ = plat.sigaction(plat.SIGPIPE, &ignore, null);
    }

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    // Generate a fresh VAPID key pair and print a config snippet to paste into
    // the `push` block of the config file.
    if (args.len >= 2 and std.mem.eql(u8, args[1], "--gen-vapid")) {
        const keys = try distrans.config.Options.Push.generateVapid(init.io, init.arena.allocator());

        var stdout_buffer: [1024]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
        const stdout = &stdout_writer.interface;

        try stdout.print(
            \\"push": {{
            \\  "enabled": true,
            \\  "vapid": {{
            \\    "subject": "mailto:admin@example.com",
            \\    "public_key": "{s}",
            \\    "private_key": "{s}"
            \\  }}
            \\}}
            \\
        , .{ keys.public_key, keys.private_key });

        try stdout.flush();

        return;
    }

    const config = if (args.len == 1)
        try distrans.config.parseConfig(init.io, init.arena.allocator(), "config.json")
    else
        try distrans.config.parseConfig(init.io, init.arena.allocator(), args[1]);

    try distrans.run(init.arena, init.gpa, init.io, &exit, &config);
}
