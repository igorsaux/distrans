// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const pq = @import("pq");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.repo_users);

pub const Exists = struct {
    pub const Result = bool;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Exists, Result, anyerror);

    pub const Payload = struct {
        user_id: root.types.UserId,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *Exists = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT id
                \\FROM app.users
                \\WHERE id = $1;
            , &.{&user_id_param}, &.{user_id_param.len}, &.{.binary}, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("UserExists failed to send: {s}", .{this.db.errorMessage()});

                    return .{ .err = err };
                },
                else => |res| return res.mapDiscard(Result),
            }
        }

        while (this.state == .waiting) {
            if (this.db.isBusy()) {
                return .{ .pending = .db };
            }

            if (this.db.getResult()) |res| {
                defer res.deinit();

                if (res.status() != pq.PGRES_TUPLES_OK) {
                    SCOPE.err("UserExists failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .{ .ready = res.ntuples() != 0 };
            }

            return .{ .ready = false };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *Exists = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) Exists {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *Exists) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const Get = struct {
    const Item = struct {
        username: []const u8,
        display_name: ?[]const u8,
        avatar_hash: ?[]const u8,
        is_bot: bool,

        pub inline fn dupe(allocator: std.mem.Allocator, res: root.db.Result) !Result {
            const username = try res.readSliceDupe(allocator, 0, 0);
            errdefer allocator.free(username);

            const display_name = try res.readSliceOptionalDupe(allocator, 0, 1);
            errdefer if (display_name != null) allocator.free(display_name.?);

            const avatar_hash = try res.readSliceOptionalDupe(allocator, 0, 2);
            errdefer if (avatar_hash != null) allocator.free(avatar_hash.?);

            return .{
                .username = username,
                .display_name = display_name,
                .avatar_hash = avatar_hash,
                .is_bot = res.readBool(0, 3),
            };
        }
    };

    pub const Result = ?Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Get, Result, anyerror);

    pub const Payload = struct {
        user_id: root.types.UserId,
    };

    const State = enum {
        start,
        waiting,
    };

    allocator: std.mem.Allocator,
    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *Get = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT username, display_name, avatar_hash, is_bot
                \\FROM app.users
                \\WHERE id = $1;
            , &.{&user_id_param}, &.{user_id_param.len}, &.{.binary}, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("GetUser failed to send query: {s}", .{this.db.errorMessage()});

                    return .{ .err = err };
                },
                else => |res| return res.mapDiscard(Result),
            }
        }

        while (this.state == .waiting) {
            if (this.db.isBusy()) {
                return .{ .pending = .db };
            }

            if (this.db.getResult()) |res| {
                defer res.deinit();

                if (res.status() != pq.PGRES_TUPLES_OK) {
                    SCOPE.err("GetUser failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                if (res.ntuples() == 0) {
                    return .{ .ready = null };
                }

                std.debug.assert(res.nfields() >= 4);

                const item = Item.dupe(this.allocator, res) catch |err| {
                    SCOPE.err("GetUser failed to dupe result: {t}", .{err});

                    return .{ .err = err };
                };

                return .{
                    .ready = item,
                };
            }

            return .{ .ready = null };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *Get = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(
        allocator: std.mem.Allocator,
        db: *root.db.Connection,
        payload: Payload,
    ) Get {
        db.acquire();

        return .{
            .allocator = allocator,
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *Get) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const GetAuth = struct {
    const Item = struct {
        id: root.types.UserId,
        password_hash: []const u8,

        pub inline fn dupe(allocator: std.mem.Allocator, res: root.db.Result) !Item {
            const password_hash = try res.readSliceDupe(allocator, 0, 1);
            errdefer allocator.free(password_hash);

            return .{
                .id = res.readInt(root.types.UserId, 0, 0),
                .password_hash = password_hash,
            };
        }
    };

    pub const Result = ?Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(GetAuth, Result, anyerror);

    pub const Payload = struct {
        username: []const u8,
    };

    const State = enum {
        start,
        waiting,
    };

    allocator: std.mem.Allocator,
    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *GetAuth = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            switch (this.db.sendQueryParams(
                \\SELECT id, password_hash
                \\FROM app.users
                \\WHERE username = $1
                \\  AND deleted_at IS NULL
                \\  AND password_hash IS NOT NULL;
            , &.{this.payload.username.ptr}, &.{@intCast(this.payload.username.len)}, &.{.binary}, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("GetUserAuth failed to send query: {s}", .{this.db.errorMessage()});

                    return .{ .err = err };
                },
                else => |res| return res.mapDiscard(Result),
            }
        }

        while (this.state == .waiting) {
            if (this.db.isBusy()) {
                return .{ .pending = .db };
            }

            if (this.db.getResult()) |res| {
                defer res.deinit();

                if (res.status() != pq.PGRES_TUPLES_OK) {
                    SCOPE.err("GetUserAuth failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                std.debug.assert(res.nfields() >= 2);

                if (res.ntuples() == 0) {
                    return .{ .ready = null };
                }

                std.debug.assert(res.ntuples() == 1);

                const item = Item.dupe(this.allocator, res) catch |err| {
                    SCOPE.err("GetUserAuth failed to dupe: {t}", .{err});

                    return .{ .err = err };
                };

                return .{ .ready = item };
            }

            return .{ .ready = null };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetAuth = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(allocator: std.mem.Allocator, db: *root.db.Connection, payload: Payload) GetAuth {
        db.acquire();

        return .{
            .allocator = allocator,
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *GetAuth) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const GetAuthById = struct {
    const Item = struct {
        password_hash: []const u8,

        pub inline fn dupe(allocator: std.mem.Allocator, res: root.db.Result) !Item {
            const password_hash = try res.readSliceDupe(allocator, 0, 0);
            errdefer allocator.free(password_hash);

            return .{
                .password_hash = password_hash,
            };
        }
    };

    pub const Result = ?Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(GetAuthById, Result, anyerror);

    pub const Payload = struct {
        user_id: root.types.UserId,
    };

    const State = enum {
        start,
        waiting,
    };

    allocator: std.mem.Allocator,
    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *GetAuthById = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT password_hash
                \\FROM app.users
                \\WHERE id = $1
                \\  AND deleted_at IS NULL
                \\  AND password_hash IS NOT NULL;
            , &.{&id_param}, &.{id_param.len}, &.{.binary}, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("GetAuthById failed to send: {s}", .{this.db.errorMessage()});

                    return .{ .err = err };
                },
                else => |res| return res.mapDiscard(Result),
            }
        }

        while (this.state == .waiting) {
            if (this.db.isBusy()) {
                return .{ .pending = .db };
            }

            if (this.db.getResult()) |res| {
                defer res.deinit();

                if (res.status() != pq.PGRES_TUPLES_OK) {
                    SCOPE.err("GetAuthById failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                if (res.ntuples() == 0) {
                    return .{ .ready = null };
                }

                std.debug.assert(res.nfields() >= 1);

                const item: Item = .{
                    .password_hash = res.readSliceDupe(this.allocator, 0, 0) catch |err| {
                        SCOPE.err("GetAuthById failed to dupe 'password_hash': {t}", .{err});

                        return .{ .err = err };
                    },
                };

                return .{ .ready = item };
            }

            return .{ .ready = null };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetAuthById = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(
        allocator: std.mem.Allocator,
        db: *root.db.Connection,
        payload: Payload,
    ) GetAuthById {
        db.acquire();

        return .{
            .allocator = allocator,
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *GetAuthById) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const Create = struct {
    /// `null` means the username or id is already taken (SQLSTATE 23505)
    pub const Result = ?void;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Create, Result, anyerror);

    pub const Payload = struct {
        id: root.types.UserId,
        username: []const u8,
        password_hash: ?[]const u8,
        is_bot: bool,
        display_name: ?[]const u8 = null,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *Create = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const id_param = root.utils.intToArray(root.types.UserId, this.payload.id, .big);
            const is_bot_param: [1]u8 = .{@intFromBool(this.payload.is_bot)};

            const password_hash = this.payload.password_hash orelse "";
            const display_name = this.payload.display_name orelse "";

            switch (this.db.sendQueryParams(
                \\INSERT INTO app.users (id, username, password_hash, is_bot, display_name)
                \\VALUES ($1::bigint, $2::text, NULLIF($3::text, ''), $4, NULLIF($5::text, ''));
            , &.{
                id_param[0..@sizeOf(root.types.UserId)],
                this.payload.username.ptr,
                password_hash.ptr,
                &is_bot_param,
                display_name.ptr,
            }, &.{
                id_param.len,
                @intCast(this.payload.username.len),
                @intCast(password_hash.len),
                is_bot_param.len,
                @intCast(display_name.len),
            }, &.{
                .binary,
                .binary,
                .binary,
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("CreateUser failed to send query: {s}", .{this.db.errorMessage()});

                    return .{ .err = err };
                },
                else => |res| return res.mapDiscard(Result),
            }
        }

        while (this.state == .waiting) {
            if (this.db.isBusy()) {
                return .{ .pending = .db };
            }

            if (this.db.getResult()) |res| {
                defer res.deinit();

                if (res.status() != pq.PGRES_COMMAND_OK) {
                    const sqlstate = res.errorSqlstate();

                    if (sqlstate != null and std.mem.eql(u8, std.mem.span(sqlstate), "23505")) {
                        return .{ .ready = null };
                    }

                    SCOPE.err("CreateUser failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }
            } else {
                return .{ .ready = {} };
            }
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *Create = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(
        db: *root.db.Connection,
        payload: Payload,
    ) Create {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *Create) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const Update = struct {
    /// `null` means the new username is already taken (SQLSTATE 23505)
    pub const Result = ?void;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Update, Result, anyerror);

    pub const Payload = struct {
        user_id: root.types.UserId,
        username: ?[]const u8,
        username_set: bool,
        display_name: ?[]const u8,
        display_name_set: bool,
        password_hash: ?[]const u8,
        password_hash_set: bool,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *Update = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const set_username_param = root.utils.intToArray(u8, @intFromBool(this.payload.username_set), .big);
            const set_display_name_param = root.utils.intToArray(u8, @intFromBool(this.payload.display_name_set), .big);
            const set_password_hash_param = root.utils.intToArray(u8, @intFromBool(this.payload.password_hash_set), .big);
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);

            switch (this.db.sendQueryParams(
                \\UPDATE app.users AS u
                \\SET username      = CASE WHEN $1 THEN $2 ELSE u.username      END,
                \\    display_name  = CASE WHEN $3 THEN $4 ELSE u.display_name  END,
                \\    password_hash = CASE WHEN $5 THEN $6 ELSE u.password_hash END
                \\WHERE u.id = $7
                \\  AND u.deleted_at IS NULL
                \\  AND ($1 OR $3 OR $5);
            , &.{
                &set_username_param,
                if (this.payload.username) |username| username.ptr else null,
                &set_display_name_param,
                if (this.payload.display_name) |display_name| display_name.ptr else null,
                &set_password_hash_param,
                if (this.payload.password_hash) |password_hash| password_hash.ptr else null,
                &user_id_param,
            }, &.{
                set_username_param.len,
                if (this.payload.username) |username| @intCast(username.len) else 0,
                set_display_name_param.len,
                if (this.payload.display_name) |display_name| @intCast(display_name.len) else 0,
                set_password_hash_param.len,
                if (this.payload.password_hash) |password_hash| @intCast(password_hash.len) else 0,
                user_id_param.len,
            }, &.{
                .binary,
                .binary,
                .binary,
                .binary,
                .binary,
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("Update failed to send: {s}", .{this.db.errorMessage()});

                    return .{ .err = err };
                },
                else => |res| return res.mapDiscard(Result),
            }
        }

        while (this.state == .waiting) {
            if (this.db.isBusy()) {
                return .{ .pending = .db };
            }

            if (this.db.getResult()) |res| {
                defer res.deinit();

                if (res.status() != pq.PGRES_COMMAND_OK) {
                    const sqlstate = res.errorSqlstate();

                    if (sqlstate != null and std.mem.eql(u8, std.mem.span(sqlstate), "23505")) {
                        return .{ .ready = null };
                    }

                    SCOPE.err("Update failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .{ .ready = {} };
            }

            return .{ .ready = {} };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *Update = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(
        db: *root.db.Connection,
        payload: Payload,
    ) Update {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *Update) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const GetUsers = struct {
    const Item = struct {
        id: root.types.UserId,
        username: []const u8,
        display_name: ?[]const u8,
        avatar_hash: ?[]const u8,
        is_bot: bool,
    };

    pub const Result = Item;

    pub const Stream = root.task.Stream(Result, anyerror);
    pub const Lazy = root.task.LazyStream(GetUsers, Result, anyerror);

    pub const Payload = struct {
        after: ?root.types.UserId,
        limit: usize,
    };

    const State = union(enum) {
        start,
        waiting,
        yielding: struct {
            pos: usize = 0,
            res: root.db.Result,
        },
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Stream.PollT {
        const this: *GetUsers = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const limit_param = root.utils.intToArray(usize, this.payload.limit, .big);

            const res = blk: {
                if (this.payload.after == null) {
                    break :blk this.db.sendQueryParams(
                        \\SELECT id, username, display_name, avatar_hash, is_bot
                        \\FROM app.users
                        \\ORDER BY id ASC
                        \\LIMIT $1;
                    , &.{&limit_param}, &.{limit_param.len}, &.{.binary}, .binary);
                }

                const after_param = root.utils.intToArray(root.types.UserId, this.payload.after.?, .big);

                break :blk this.db.sendQueryParams(
                    \\SELECT id, username, display_name, avatar_hash, is_bot
                    \\FROM app.users
                    \\WHERE id > $2
                    \\ORDER BY id ASC
                    \\LIMIT $1;
                , &.{
                    &limit_param,
                    &after_param,
                }, &.{
                    limit_param.len,
                    after_param.len,
                }, &.{
                    .binary,
                    .binary,
                }, .binary);
            };

            switch (res) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("GetUsers failed to send: {s}", .{this.db.errorMessage()});

                    return .{ .err = err };
                },
                else => |r| return r.toStreamPoll().mapDiscard(Result),
            }
        }

        while (this.state == .waiting or this.state == .yielding) {
            if (this.state == .waiting) {
                if (this.db.isBusy()) {
                    return .{ .pending = .db };
                }

                if (this.db.getResult()) |res| {
                    if (res.status() != pq.PGRES_TUPLES_OK) {
                        SCOPE.err("GetUsers failed: {s}", .{res.errorMessage()});
                        res.deinit();

                        return .{ .err = error.PGError };
                    }

                    this.state = .{
                        .yielding = .{
                            .res = res,
                        },
                    };
                } else {
                    return .done;
                }
            }

            if (this.state == .yielding) {
                const yield = &this.state.yielding;
                const res = yield.res;

                const total = res.ntuples();

                if (yield.pos >= total) {
                    res.deinit();
                    this.state = .waiting;

                    continue;
                }

                std.debug.assert(res.nfields() >= 5);

                const item: Item = .{
                    .id = res.readInt(root.types.UserId, yield.pos, 0),
                    .username = res.readString(yield.pos, 1),
                    .display_name = res.readStringOptional(yield.pos, 2),
                    .avatar_hash = res.readStringOptional(yield.pos, 3),
                    .is_bot = res.readBool(yield.pos, 4),
                };

                yield.pos += 1;

                return .{ .yielded = item };
            }
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetUsers = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) GetUsers {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn stream(this: *GetUsers) Stream {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const CheckAlive = struct {
    pub const Result = bool;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(CheckAlive, Result, anyerror);

    pub const Payload = struct {
        user_id: root.types.UserId,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *CheckAlive = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT 1
                \\FROM app.users
                \\WHERE id = $1
                \\  AND deleted_at IS NULL;
            , &.{&user_id_param}, &.{user_id_param.len}, &.{.binary}, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("CheckUserAlive failed to send: {s}", .{this.db.errorMessage()});

                    return .{ .err = err };
                },
                else => |res| return res.mapDiscard(Result),
            }
        }

        while (this.state == .waiting) {
            if (this.db.isBusy()) {
                return .{ .pending = .db };
            }

            if (this.db.getResult()) |res| {
                defer res.deinit();

                if (res.status() != pq.PGRES_TUPLES_OK) {
                    SCOPE.err("CheckUserAlive failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .{ .ready = res.ntuples() != 0 };
            }

            return .{ .ready = false };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *CheckAlive = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) CheckAlive {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *CheckAlive) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const CheckBotUser = struct {
    /// `null` = the user does not exist or is deleted; otherwise `is_bot`
    pub const Result = ?bool;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(CheckBotUser, Result, anyerror);

    pub const Payload = struct {
        user_id: root.types.UserId,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *CheckBotUser = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT is_bot
                \\FROM app.users
                \\WHERE id = $1
                \\  AND deleted_at IS NULL;
            , &.{&user_id_param}, &.{user_id_param.len}, &.{.binary}, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("CheckBotUser failed to send: {s}", .{this.db.errorMessage()});

                    return .{ .err = err };
                },
                else => |res| return res.mapDiscard(Result),
            }
        }

        while (this.state == .waiting) {
            if (this.db.isBusy()) {
                return .{ .pending = .db };
            }

            if (this.db.getResult()) |res| {
                defer res.deinit();

                if (res.status() != pq.PGRES_TUPLES_OK) {
                    SCOPE.err("CheckBotUser failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                if (res.ntuples() == 0) {
                    return .{ .ready = null };
                }

                std.debug.assert(res.nfields() >= 1);

                return .{ .ready = res.readBool(0, 0) };
            }

            return .{ .ready = null };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *CheckBotUser = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) CheckBotUser {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *CheckBotUser) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const SoftDelete = struct {
    /// `null` = the user did not exist or was already deleted
    pub const Item = struct {
        is_bot: bool,
    };

    pub const Result = ?Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(SoftDelete, Result, anyerror);

    pub const Payload = struct {
        id: root.types.UserId,
    };

    const State = enum {
        start,
        waiting,
        delete_refresh_tokens,
        delete_refresh_tokens_waiting,
        delete_bot_tokens,
        delete_bot_tokens_waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,
    result: Result = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *SoftDelete = @ptrCast(@alignCast(ctx));

        while (true) {
            switch (this.state) {
                .start => {
                    const id_param = root.utils.intToArray(root.types.UserId, this.payload.id, .big);

                    switch (this.db.sendQueryParams(
                        \\WITH deleted AS (
                        \\    UPDATE app.users
                        \\    SET deleted_at = now(),
                        \\        username = 'deleted-' || id::text,
                        \\        password_hash = NULL,
                        \\        display_name = NULL,
                        \\        avatar_data = NULL,
                        \\        avatar_hash = NULL
                        \\    WHERE id = $1
                        \\      AND deleted_at IS NULL
                        \\    RETURNING is_bot, id
                        \\),
                        \\removed_roles AS (
                        \\    DELETE FROM app.member_roles AS mr
                        \\    USING deleted AS d
                        \\    WHERE mr.user_id = d.id
                        \\    RETURNING mr.guild_id
                        \\),
                        \\revoked_tokens AS (
                        \\    DELETE FROM app.refresh_tokens
                        \\    WHERE user_id = (SELECT id FROM deleted)
                        \\),
                        \\removed_push_subscriptions AS (
                        \\    DELETE FROM app.push_subscriptions
                        \\    WHERE user_id = (SELECT id FROM deleted)
                        \\),
                        \\removed_userdata AS (
                        \\    DELETE FROM app.userdata
                        \\    WHERE user_id = (SELECT id FROM deleted)
                        \\)
                        \\SELECT d.is_bot,
                        \\       (SELECT count(*))::int AS roles_removed
                        \\FROM deleted AS d;
                    , &.{&id_param}, &.{id_param.len}, &.{.binary}, .binary)) {
                        .ready => this.state = .waiting,
                        .err => |err| {
                            SCOPE.err("DeleteUser failed to send query: {s}", .{this.db.errorMessage()});

                            return .{ .err = err };
                        },
                        else => |res| return res.mapDiscard(Result),
                    }
                },
                .waiting => {
                    if (this.db.isBusy()) {
                        return .{ .pending = .db };
                    }

                    if (this.db.getResult()) |res| {
                        defer res.deinit();

                        if (res.status() != pq.PGRES_TUPLES_OK) {
                            SCOPE.err("DeleteUser failed: {s}", .{res.errorMessage()});

                            return .{ .err = error.PGError };
                        }

                        if (res.ntuples() == 0) {
                            return .{ .ready = null };
                        }

                        this.result = .{
                            .is_bot = res.readBool(0, 0),
                        };

                        this.state = .delete_refresh_tokens;

                        continue;
                    }

                    return .{ .ready = null };
                },
                .delete_refresh_tokens => {
                    const id_param = root.utils.intToArray(root.types.UserId, this.payload.id, .big);

                    switch (this.db.sendQueryParams(
                        \\DELETE FROM app.refresh_tokens
                        \\WHERE user_id = $1;
                    , &.{&id_param}, &.{id_param.len}, &.{.binary}, .binary)) {
                        .ready => this.state = .delete_refresh_tokens_waiting,
                        .err => |err| {
                            SCOPE.err("DeleteUser failed to send refresh token cleanup: {s}", .{this.db.errorMessage()});

                            return .{ .err = err };
                        },
                        else => |res| return res.mapDiscard(Result),
                    }
                },
                .delete_refresh_tokens_waiting => {
                    if (this.db.isBusy()) {
                        return .{ .pending = .db };
                    }

                    if (this.db.getResult()) |res| {
                        defer res.deinit();

                        if (res.status() != pq.PGRES_COMMAND_OK) {
                            SCOPE.err("DeleteUser refresh token cleanup failed: {s}", .{res.errorMessage()});

                            return .{ .err = error.PGError };
                        }

                        this.state = .delete_bot_tokens;

                        continue;
                    }

                    return .{ .ready = this.result };
                },
                .delete_bot_tokens => {
                    const id_param = root.utils.intToArray(root.types.UserId, this.payload.id, .big);

                    switch (this.db.sendQueryParams(
                        \\DELETE FROM app.bot_tokens
                        \\WHERE user_id = $1;
                    , &.{&id_param}, &.{id_param.len}, &.{.binary}, .binary)) {
                        .ready => this.state = .delete_bot_tokens_waiting,
                        .err => |err| {
                            SCOPE.err("DeleteUser failed to send bot token cleanup: {s}", .{this.db.errorMessage()});

                            return .{ .err = err };
                        },
                        else => |res| return res.mapDiscard(Result),
                    }
                },
                .delete_bot_tokens_waiting => {
                    if (this.db.isBusy()) {
                        return .{ .pending = .db };
                    }

                    if (this.db.getResult()) |res| {
                        defer res.deinit();

                        if (res.status() != pq.PGRES_COMMAND_OK) {
                            SCOPE.err("DeleteUser bot token cleanup failed: {s}", .{res.errorMessage()});

                            return .{ .err = error.PGError };
                        }

                        return .{ .ready = this.result };
                    }

                    return .{ .ready = this.result };
                },
            }
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *SoftDelete = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) SoftDelete {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *SoftDelete) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const GetRoles = struct {
    const Item = root.types.RoleId;

    pub const Result = Item;

    pub const Stream = root.task.Stream(Result, anyerror);
    pub const Lazy = root.task.LazyStream(GetRoles, Result, anyerror);

    pub const Payload = struct {
        user_id: root.types.UserId,
        guild_id: root.types.GuildId,
    };

    const State = union(enum) {
        start,
        waiting,
        yielding: struct {
            pos: usize = 0,
            res: root.db.Result,
            reverse: bool = false,
        },
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Stream.PollT {
        const this: *GetRoles = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const guild_id_param = root.utils.intToArray(root.types.GuildId, this.payload.guild_id, .big);
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT r.id
                \\FROM app.roles AS r
                \\WHERE r.guild_id = $1
                \\  AND (r.id = $1 OR EXISTS(
                \\      SELECT 1 FROM app.member_roles AS mr
                \\      WHERE mr.guild_id = r.guild_id
                \\        AND mr.role_id  = r.id
                \\        AND mr.user_id  = $2
                \\  ))
                \\ORDER BY r.position DESC, r.id DESC;
            , &.{
                &guild_id_param,
                &user_id_param,
            }, &.{
                guild_id_param.len,
                user_id_param.len,
            }, &.{
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("GetRoles failed to send: {s}", .{this.db.errorMessage()});

                    return .{ .err = err };
                },
                else => |res| return res.toStreamPoll().mapDiscard(Result),
            }
        }

        while (this.state == .waiting or this.state == .yielding) {
            if (this.state == .waiting) {
                if (this.db.isBusy()) {
                    return .{ .pending = .db };
                }

                if (this.db.getResult()) |res| {
                    if (res.status() != pq.PGRES_TUPLES_OK) {
                        SCOPE.err("GetRoles failed: {s}", .{res.errorMessage()});
                        res.deinit();

                        return .{ .err = error.PGError };
                    }

                    this.state = .{
                        .yielding = .{
                            .res = res,
                        },
                    };
                } else {
                    return .done;
                }
            }

            if (this.state == .yielding) {
                const yield = &this.state.yielding;
                const res = yield.res;

                if (yield.pos >= res.ntuples()) {
                    res.deinit();
                    this.state = .waiting;

                    continue;
                }

                std.debug.assert(res.nfields() >= 1);

                const item = res.readInt(root.types.RoleId, yield.pos, 0);

                yield.pos += 1;

                return .{ .yielded = item };
            }
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetRoles = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(
        db: *root.db.Connection,
        payload: Payload,
    ) GetRoles {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn stream(this: *GetRoles) Stream {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// Highest role position of a user: MAX(position) over the user's member roles.
/// `@everyone` is never in `app.member_roles` and therefore contributes 0 (or nothing).
pub const GetHighestRolePosition = struct {
    const Item = root.types.Position;

    pub const Result = Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(GetHighestRolePosition, Result, anyerror);

    pub const Payload = struct {
        guild_id: root.types.GuildId,
        user_id: root.types.UserId,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *GetHighestRolePosition = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const guild_id_param = root.utils.intToArray(root.types.GuildId, this.payload.guild_id, .big);
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT COALESCE(MAX(r.position), 0)::smallint AS highest
                \\FROM app.roles AS r
                \\JOIN app.member_roles AS mr
                \\  ON mr.guild_id = r.guild_id AND mr.role_id = r.id
                \\WHERE r.guild_id = $1 AND mr.user_id = $2;
            , &.{
                &guild_id_param,
                &user_id_param,
            }, &.{
                guild_id_param.len,
                user_id_param.len,
            }, &.{
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("GetUserHighestRolePosition failed to send: {s}", .{this.db.errorMessage()});

                    return .{ .err = err };
                },
                else => |res| return res.mapDiscard(Result),
            }
        }

        while (this.state == .waiting) {
            if (this.db.isBusy()) {
                return .{ .pending = .db };
            }

            if (this.db.getResult()) |res| {
                defer res.deinit();

                if (res.status() != pq.PGRES_TUPLES_OK) {
                    SCOPE.err("GetUserHighestRolePosition failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                std.debug.assert(res.nfields() >= 1);

                if (res.ntuples() == 0) {
                    return .{ .ready = 0 };
                }

                return .{
                    .ready = res.readInt(root.types.Position, 0, 0),
                };
            }

            return .{ .ready = 0 };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetHighestRolePosition = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) GetHighestRolePosition {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *GetHighestRolePosition) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const IsHigherThanOther = struct {
    const Item = bool;

    pub const Result = Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(IsHigherThanOther, Result, anyerror);

    pub const Payload = struct {
        guild_id: root.types.GuildId,
        user_a_id: root.types.UserId,
        user_b_id: root.types.UserId,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *IsHigherThanOther = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const guild_id_param = root.utils.intToArray(root.types.GuildId, this.payload.guild_id, .big);
            const user_a_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_a_id, .big);
            const user_b_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_b_id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT COALESCE(MAX(r.position) FILTER (WHERE mr.user_id = $2), 0)
                \\     > COALESCE(MAX(r.position) FILTER (WHERE mr.user_id = $3), 0) AS a_above_b
                \\FROM app.member_roles AS mr
                \\JOIN app.roles AS r
                \\  ON r.guild_id = mr.guild_id AND r.id = mr.role_id
                \\WHERE mr.guild_id = $1
                \\  AND mr.user_id IN ($2, $3);
            , &.{
                &guild_id_param,
                &user_a_id_param,
                &user_b_id_param,
            }, &.{
                guild_id_param.len,
                user_a_id_param.len,
                user_b_id_param.len,
            }, &.{
                .binary,
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("IsHigherThanOther failed to send: {s}", .{this.db.errorMessage()});

                    return .{ .err = err };
                },
                else => |res| return res.mapDiscard(Result),
            }
        }

        while (this.state == .waiting) {
            if (this.db.isBusy()) {
                return .{ .pending = .db };
            }

            if (this.db.getResult()) |res| {
                defer res.deinit();

                if (res.status() != pq.PGRES_TUPLES_OK) {
                    SCOPE.err("IsHigherThanOther failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                if (res.ntuples() == 0) {
                    return .{ .ready = false };
                }

                std.debug.assert(res.ntuples() == 1);

                return .{
                    .ready = res.readBool(0, 0),
                };
            }

            return .{ .ready = false };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *IsHigherThanOther = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) IsHigherThanOther {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *IsHigherThanOther) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// Alive-check + hierarchy check for a member-overwrite target, in one
/// round trip. Returns `alive` (soft-deleted or missing -> false) and both
/// highest role positions (`@everyone`/role-less members contribute 0).
pub const CheckMemberTarget = struct {
    const Item = struct {
        alive: bool,
        caller_position: root.types.Position,
        target_position: root.types.Position,
    };

    pub const Result = Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(CheckMemberTarget, Result, anyerror);

    pub const Payload = struct {
        guild_id: root.types.GuildId,
        target_user_id: root.types.UserId,
        caller_user_id: root.types.UserId,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *CheckMemberTarget = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const guild_id_param = root.utils.intToArray(root.types.GuildId, this.payload.guild_id, .big);
            const target_user_id_param = root.utils.intToArray(root.types.UserId, this.payload.target_user_id, .big);
            const caller_user_id_param = root.utils.intToArray(root.types.UserId, this.payload.caller_user_id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT
                \\    COALESCE((SELECT u.deleted_at IS NULL FROM app.users u WHERE u.id = $2), false) AS alive,
                \\    COALESCE((SELECT MAX(r.position)::smallint
                \\              FROM app.member_roles mr
                \\              JOIN app.roles r ON r.guild_id = mr.guild_id AND r.id = mr.role_id
                \\              WHERE mr.guild_id = $1 AND mr.user_id = $3), 0::smallint) AS caller_pos,
                \\    COALESCE((SELECT MAX(r.position)::smallint
                \\              FROM app.member_roles mr
                \\              JOIN app.roles r ON r.guild_id = mr.guild_id AND r.id = mr.role_id
                \\              WHERE mr.guild_id = $1 AND mr.user_id = $2), 0::smallint) AS target_pos;
            , &.{
                &guild_id_param,
                &target_user_id_param,
                &caller_user_id_param,
            }, &.{
                guild_id_param.len,
                target_user_id_param.len,
                caller_user_id_param.len,
            }, &.{
                .binary,
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("CheckMemberTarget failed to send: {s}", .{this.db.errorMessage()});

                    return .{ .err = err };
                },
                else => |res| return res.mapDiscard(Result),
            }
        }

        while (this.state == .waiting) {
            if (this.db.isBusy()) {
                return .{ .pending = .db };
            }

            if (this.db.getResult()) |res| {
                defer res.deinit();

                if (res.status() != pq.PGRES_TUPLES_OK) {
                    SCOPE.err("CheckMemberTarget failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                if (res.ntuples() == 0) {
                    return .{
                        .ready = .{
                            .alive = false,
                            .caller_position = 0,
                            .target_position = 0,
                        },
                    };
                }

                std.debug.assert(res.ntuples() == 1);

                return .{
                    .ready = .{
                        .alive = res.readBool(0, 0),
                        .caller_position = res.readIntOptional(root.types.Position, 0, 1) orelse 0,
                        .target_position = res.readIntOptional(root.types.Position, 0, 2) orelse 0,
                    },
                };
            }

            return .{
                .ready = .{
                    .alive = false,
                    .caller_position = 0,
                    .target_position = 0,
                },
            };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *CheckMemberTarget = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) CheckMemberTarget {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *CheckMemberTarget) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const HasRole = struct {
    const Item = bool;

    pub const Result = Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(HasRole, Result, anyerror);

    pub const Payload = struct {
        guild_id: root.types.GuildId,
        user_id: root.types.UserId,
        role_id: root.types.RoleId,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *HasRole = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const guild_id_param = root.utils.intToArray(root.types.GuildId, this.payload.guild_id, .big);
            const role_id_param = root.utils.intToArray(root.types.RoleId, this.payload.role_id, .big);
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT
                \\    (
                \\        $2::bigint = $1::bigint
                \\        OR EXISTS (
                \\            SELECT 1
                \\            FROM app.member_roles AS mr
                \\            WHERE mr.guild_id = $1
                \\              AND mr.user_id  = $3
                \\              AND mr.role_id  = $2
                \\        )
                \\    )
                \\    AND EXISTS (
                \\        SELECT 1
                \\        FROM app.users AS u
                \\        WHERE u.id = $3
                \\          AND u.deleted_at IS NULL
                \\    ) AS has_role;
            , &.{
                &guild_id_param,
                &role_id_param,
                &user_id_param,
            }, &.{
                guild_id_param.len,
                role_id_param.len,
                user_id_param.len,
            }, &.{
                .binary,
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("HasRole failed to send: {s}", .{this.db.errorMessage()});

                    return .{ .err = err };
                },
                else => |res| return res.mapDiscard(Result),
            }
        }

        while (this.state == .waiting) {
            if (this.db.isBusy()) {
                return .{ .pending = .db };
            }

            if (this.db.getResult()) |res| {
                defer res.deinit();

                if (res.status() != pq.PGRES_TUPLES_OK) {
                    SCOPE.err("HasRole failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                std.debug.assert(res.ntuples() == 1);

                return .{
                    .ready = res.readBool(0, 0),
                };
            }

            return .{ .ready = false };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *HasRole = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) HasRole {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *HasRole) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const AddRole = struct {
    pub const Result = void;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(AddRole, Result, anyerror);

    pub const Payload = struct {
        guild_id: root.types.GuildId,
        role_id: root.types.RoleId,
        user_id: root.types.UserId,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *AddRole = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const guild_id_param = root.utils.intToArray(root.types.GuildId, this.payload.guild_id, .big);
            const role_id_param = root.utils.intToArray(root.types.RoleId, this.payload.role_id, .big);
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);

            switch (this.db.sendQueryParams(
                \\INSERT INTO app.member_roles (guild_id, role_id, user_id)
                \\VALUES ($1, $2, $3);
            , &.{
                &guild_id_param,
                &role_id_param,
                &user_id_param,
            }, &.{
                guild_id_param.len,
                role_id_param.len,
                user_id_param.len,
            }, &.{
                .binary,
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("AddRole failed to send: {s}", .{this.db.errorMessage()});

                    return .{ .err = err };
                },
                else => |res| return res.mapDiscard(Result),
            }
        }

        while (this.state == .waiting) {
            if (this.db.isBusy()) {
                return .{ .pending = .db };
            }

            if (this.db.getResult()) |res| {
                defer res.deinit();

                if (res.status() != pq.PGRES_COMMAND_OK) {
                    SCOPE.err("AddRole failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .ready;
            }

            return .ready;
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *AddRole = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) AddRole {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *AddRole) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const RemoveRole = struct {
    pub const Result = void;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(RemoveRole, Result, anyerror);

    pub const Payload = struct {
        guild_id: root.types.GuildId,
        role_id: root.types.RoleId,
        user_id: root.types.UserId,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *RemoveRole = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const guild_id_param = root.utils.intToArray(root.types.GuildId, this.payload.guild_id, .big);
            const role_id_param = root.utils.intToArray(root.types.RoleId, this.payload.role_id, .big);
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);

            switch (this.db.sendQueryParams(
                \\DELETE FROM app.member_roles
                \\WHERE guild_id = $1 AND role_id = $2 AND user_id = $3;
            , &.{
                &guild_id_param,
                &role_id_param,
                &user_id_param,
            }, &.{
                guild_id_param.len,
                role_id_param.len,
                user_id_param.len,
            }, &.{
                .binary,
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("RemoveRole failed to send: {s}", .{this.db.errorMessage()});

                    return .{ .err = err };
                },
                else => |res| return res.mapDiscard(Result),
            }
        }

        while (this.state == .waiting) {
            if (this.db.isBusy()) {
                return .{ .pending = .db };
            }

            if (this.db.getResult()) |res| {
                defer res.deinit();

                if (res.status() != pq.PGRES_COMMAND_OK) {
                    SCOPE.err("AddRole failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .ready;
            }

            return .ready;
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *RemoveRole = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) RemoveRole {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *RemoveRole) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// Stores the encoded avatar bytes and their hash for a user.
/// `null` = the user does not exist or is deleted.
pub const SetAvatar = struct {
    pub const Result = ?void;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(SetAvatar, Result, anyerror);

    pub const Payload = struct {
        user_id: root.types.UserId,
        data: []const u8,
        hash: []const u8,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *SetAvatar = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);

            switch (this.db.sendQueryParams(
                \\UPDATE app.users
                \\SET avatar_data = $2, avatar_hash = $3
                \\WHERE id = $1
                \\  AND deleted_at IS NULL
                \\RETURNING id;
            , &.{
                &user_id_param,
                this.payload.data.ptr,
                this.payload.hash.ptr,
            }, &.{
                user_id_param.len,
                @intCast(this.payload.data.len),
                @intCast(this.payload.hash.len),
            }, &.{
                .binary,
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("SetAvatar failed to send: {s}", .{this.db.errorMessage()});

                    return .{ .err = err };
                },
                else => |res| return res.mapDiscard(Result),
            }
        }

        while (this.state == .waiting) {
            if (this.db.isBusy()) {
                return .{ .pending = .db };
            }

            if (this.db.getResult()) |res| {
                defer res.deinit();

                if (res.status() != pq.PGRES_TUPLES_OK) {
                    SCOPE.err("SetAvatar failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .{ .ready = if (res.ntuples() == 0) null else {} };
            }

            return .{ .ready = null };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *SetAvatar = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) SetAvatar {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *SetAvatar) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// Removes the avatar bytes and hash of a user.
/// `null` = the user does not exist or is deleted.
pub const ClearAvatar = struct {
    pub const Result = ?void;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(ClearAvatar, Result, anyerror);

    pub const Payload = struct {
        user_id: root.types.UserId,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *ClearAvatar = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);

            switch (this.db.sendQueryParams(
                \\UPDATE app.users
                \\SET avatar_data = NULL, avatar_hash = NULL
                \\WHERE id = $1
                \\  AND deleted_at IS NULL
                \\RETURNING id;
            , &.{&user_id_param}, &.{user_id_param.len}, &.{.binary}, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("ClearAvatar failed to send: {s}", .{this.db.errorMessage()});

                    return .{ .err = err };
                },
                else => |res| return res.mapDiscard(Result),
            }
        }

        while (this.state == .waiting) {
            if (this.db.isBusy()) {
                return .{ .pending = .db };
            }

            if (this.db.getResult()) |res| {
                defer res.deinit();

                if (res.status() != pq.PGRES_TUPLES_OK) {
                    SCOPE.err("ClearAvatar failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .{ .ready = if (res.ntuples() == 0) null else {} };
            }

            return .{ .ready = null };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *ClearAvatar = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) ClearAvatar {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *ClearAvatar) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// Reads the stored avatar bytes of a user, but only when the stored hash
/// matches `payload.hash`. `null` = no user/avatar or a hash mismatch.
pub const GetAvatar = struct {
    pub const Result = ?[]const u8;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(GetAvatar, Result, anyerror);

    pub const Payload = struct {
        user_id: root.types.UserId,
        hash: []const u8,
    };

    const State = enum {
        start,
        waiting,
    };

    allocator: std.mem.Allocator,
    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *GetAvatar = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT avatar_data
                \\FROM app.users
                \\WHERE id = $1
                \\  AND avatar_hash = $2
                \\  AND avatar_data IS NOT NULL
                \\  AND deleted_at IS NULL;
            , &.{
                &user_id_param,
                this.payload.hash.ptr,
            }, &.{
                user_id_param.len,
                @intCast(this.payload.hash.len),
            }, &.{
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("GetAvatar failed to send: {s}", .{this.db.errorMessage()});

                    return .{ .err = err };
                },
                else => |res| return res.mapDiscard(Result),
            }
        }

        while (this.state == .waiting) {
            if (this.db.isBusy()) {
                return .{ .pending = .db };
            }

            if (this.db.getResult()) |res| {
                defer res.deinit();

                if (res.status() != pq.PGRES_TUPLES_OK) {
                    SCOPE.err("GetAvatar failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                if (res.ntuples() == 0) {
                    return .{ .ready = null };
                }

                std.debug.assert(res.nfields() >= 1);

                const data = res.readSliceDupe(this.allocator, 0, 0) catch |err| {
                    SCOPE.err("GetAvatar failed to dupe 'avatar_data': {t}", .{err});

                    return .{ .err = err };
                };

                return .{ .ready = data };
            }

            return .{ .ready = null };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetAvatar = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(
        allocator: std.mem.Allocator,
        db: *root.db.Connection,
        payload: Payload,
    ) GetAvatar {
        db.acquire();

        return .{
            .allocator = allocator,
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *GetAvatar) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};
