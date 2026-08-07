// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const builtin = @import("builtin");

const plat = @import("plat");

const epoll = @import("el/epoll.zig");
const kqueue = @import("el/kqueue.zig");
const root = @import("root.zig");

const SCOPE = std.log.scoped(.el);

pub const Event = if (builtin.os.tag == .macos or builtin.os.tag == .freebsd)
    kqueue.Event
else if (builtin.os.tag == .linux)
    epoll.Event
else
    @compileError("Not implemented");

const Queue = if (builtin.os.tag == .macos or builtin.os.tag == .freebsd)
    kqueue.Queue
else if (builtin.os.tag == .linux)
    epoll.EPoll
else
    @compileError("Not implemented");

pub const UserData = union(enum) {
    socket: void,
    peer: *root.net.Peer,
    db_conn: *root.db.Connection,
};

pub const EventType = enum {
    read,
    read_write,
};

pub const EventLoop = if (builtin.os.tag == .macos or builtin.os.tag == .freebsd)
    kqueue.Loop
else if (builtin.os.tag == .linux)
    epoll.Loop
else
    @compileError("Not implemented");

/// Reserves one slot in `list`'s spare capacity *without* committing it (the
/// length is left unchanged).
///
/// A backend that must fill the userdata before it knows whether the kernel
/// call succeeds (epoll) writes into the returned slot and then calls
/// `commitSlot` only on success. On failure the slot is abandoned, so a
/// parallel array's length can never drift out of step.
///
/// Returns null when the list is already at capacity.
///
/// Note: `list.items` is a slice of length `items.len`, so the spare slot must
/// be reached through `unusedCapacitySlice`; indexing `items[items.len]` is
/// out of bounds.
pub fn reserveSlot(comptime T: type, list: *std.ArrayList(T)) ?*T {
    if (list.items.len == list.capacity) {
        return null;
    }

    return &list.unusedCapacitySlice()[0];
}

/// Commits a slot previously returned by `reserveSlot`.
pub fn commitSlot(comptime T: type, list: *std.ArrayList(T)) void {
    list.items.len += 1;
}

test {
    _ = @import("el/loop_test.zig");
}
