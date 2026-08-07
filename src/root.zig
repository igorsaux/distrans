// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const builtin = @import("builtin");

pub const config = @import("config.zig");
pub const db = @import("db.zig");
pub const el = @import("el.zig");
pub const http = @import("http.zig");
pub const middleware = @import("middleware.zig");
pub const net = @import("net.zig");
pub const os = @import("os.zig");
pub const repo = @import("repo.zig");
pub const route = @import("route.zig");
pub const router = @import("router.zig");
pub const services = @import("services.zig");
pub const task = @import("task.zig");
pub const types = @import("types.zig");
pub const unicode = @import("unicode.zig");
pub const utils = @import("utils.zig");
pub const watchdog = @import("watchdog.zig");
pub const worker = @import("worker.zig");
pub const ws = @import("ws.zig");

const SCOPE = std.log.scoped(.app);

pub var arena: *std.heap.ArenaAllocator = undefined;
pub var gpa: std.mem.Allocator = .failing;
pub var io: std.Io = .failing;
pub var options: *const config.Options = undefined;
pub var pwhash_worker: services.pwhash.Worker = undefined;
pub var media_worker: services.media.Worker = undefined;
pub var files_worker: services.files.Worker = undefined;
pub var files_gc: services.files.Gc = undefined;
pub var notifications_worker: services.notifications.Sender = undefined;
pub var notifications_dispatcher: services.notifications.Dispatcher = undefined;
pub var presence: services.presence.Registry = undefined;
pub var sf_generator: services.snowflake.Generator = undefined;
pub var event_loop: el.EventLoop = undefined;
pub var db_pool: db.Pool = undefined;
pub var socket_server: net.Server = undefined;
pub var http_server: http.Server = undefined;
pub var bus: services.events.Bus = undefined;
pub var exit: *std.Io.Event = undefined;
pub var wd: watchdog.Watchdog = undefined;

test {
    _ = @import("services/notifications.zig");
    _ = @import("unicode.zig");
    _ = @import("utils.zig");
    _ = @import("net.zig");
    _ = @import("el.zig");
}

inline fn tick(next_event_us: ?usize) !?usize {
    wd.onTick();

    event_loop.unregisterAll();
    _ = socket_server.registerEvents(&event_loop, !exit.isSet());
    _ = db_pool.registerEvents(&event_loop);

    const effective_wait_us: usize = if (exit.isSet())
        0
    else if (next_event_us == null)
        options.general.io_timeout_us
    else
        next_event_us.?;

    const n_ev = try event_loop.wait(effective_wait_us);
    const now_ms: u64 = @intCast(std.Io.Timestamp.now(io, .real).toMilliseconds());
    var has_orphan: bool = false;

    for (event_loop.events.items[0..n_ev]) |ev| {
        const handle: *const el.UserData = switch (builtin.os.tag) {
            .macos, .freebsd => @ptrCast(@alignCast(ev.ev.udata)),
            .linux => @ptrCast(@alignCast(ev.ev.data.ptr)),
            else => @compileError("Not implemented"),
        };

        switch (handle.*) {
            .socket, .peer => try socket_server.handleEvent(now_ms, ev, handle, false),
            .db_conn => {
                if (db_pool.handleEvent(ev, handle)) {
                    has_orphan = true;
                }
            },
        }
    }

    if (has_orphan) {
        db_pool.handleOrphans();
    }

    files_gc.tick(now_ms);
    notifications_dispatcher.tick(now_ms);

    return try http_server.tick(now_ms, router.httpFactory);
}

fn runInner() void {
    var next_event_us: ?usize = null;
    var events_cursor: usize = 0;

    while (!exit.isSet()) {
        next_event_us = tick(next_event_us) catch |err| {
            std.log.err("server error: {t}", .{err});

            break;
        };

        if (bus.cursor != events_cursor) {
            next_event_us = null;
            events_cursor = bus.cursor;
        }
    }

    std.log.info("shutdown", .{});
    next_event_us = null;
    const shutdown_started_s: u64 = @intCast(std.Io.Timestamp.now(io, .real).toSeconds());

    while (true) {
        next_event_us = tick(next_event_us) catch |err| {
            std.log.err("failed to shutdown: {t}", .{err});

            break;
        };

        if (socket_server.allFree() and http_server.allFree() and db_pool.allFree()) {
            break;
        }

        if (bus.cursor != events_cursor) {
            next_event_us = null;
            events_cursor = bus.cursor;
        }

        const now_s: u64 = @intCast(std.Io.Timestamp.now(io, .real).toSeconds());

        if (now_s - shutdown_started_s > options.general.shutdown_timeout_s) {
            SCOPE.warn("shutdown timeout: forcing", .{});

            break;
        }
    }

    // Stats
    {
        var http_arena_used_mem: usize = 0;

        for (http_server.requests) |*req| {
            http_arena_used_mem += req.arena.queryCapacity();
        }

        std.log.info("HTTP arenas memory consumed: {} bytes", .{http_arena_used_mem});
    }

    std.log.info("done", .{});
}

pub inline fn run(
    _arena: *std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    _io: std.Io,
    _exit: *std.Io.Event,
    _options: *const config.Options,
) !void {
    if (builtin.single_threaded) {
        @compileError("Single threaded is not supported");
    }

    arena = _arena;
    gpa = allocator;
    io = _io;
    exit = _exit;
    options = _options;

    wd = .init();
    defer wd.deinit();

    sf_generator = .init(io, options.general.worker_id);

    db.applyMigrations(gpa, io) catch |err| {
        SCOPE.err("failed to apply migrations: {t}", .{err});

        return err;
    };

    // Create the workers before the http server and deinitializer after
    // the server.

    pwhash_worker = try services.pwhash.Worker.init(options.services.pwhash.max_jobs);
    defer pwhash_worker.deinit();

    try pwhash_worker.run();
    defer pwhash_worker.stop();

    media_worker = try services.media.Worker.init(options.services.media.max_jobs);
    defer media_worker.deinit();

    try media_worker.run();
    defer media_worker.stop();

    files_worker = try services.files.Worker.init(options.services.files.max_jobs);
    defer files_worker.deinit();

    try files_worker.run();
    defer files_worker.stop();

    files_gc = .init(gpa);
    defer files_gc.deinit();

    notifications_worker = try services.notifications.Sender.init(options.services.notifications.max_concurrent);
    defer notifications_worker.deinit();

    try notifications_worker.run();
    defer notifications_worker.stop();

    notifications_dispatcher = try services.notifications.Dispatcher.init(gpa, options.services.notifications.queue_capacity);
    defer notifications_dispatcher.deinit();

    presence = .init();
    defer presence.deinit();

    event_loop = try .init(gpa);
    defer event_loop.deinit(gpa);

    db_pool = try .init(gpa);
    defer db_pool.deinit(gpa);

    socket_server = try net.Server.init(gpa, io);
    defer socket_server.deinit(gpa);

    http_server = try http.Server.init(gpa, &socket_server);
    defer http_server.deinit(gpa);

    bus = .init();

    switch (options.socket.bind) {
        .unix => |path| SCOPE.info("server is running on '{s}'", .{path}),
        .inet => |inet| SCOPE.info("server is running on 'http://{s}:{s}'", .{ inet.host, inet.port }),
    }

    runInner();
}
