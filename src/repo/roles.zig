// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const pq = @import("pq");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.repo_roles);

/// Role existence + position, and the caller's highest role position in the
/// same guild, in one round trip. `null` result = the role does not exist
/// (or belongs to another guild).
pub const GetRoleAndCallerPosition = struct {
    const Item = struct {
        position: root.types.Position,
        caller_position: root.types.Position,
    };

    /// `null` = the role does not exist
    pub const Result = ?Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(GetRoleAndCallerPosition, Result, anyerror);

    pub const Payload = struct {
        role_id: root.types.RoleId,
        guild_id: root.types.GuildId,
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
        const this: *GetRoleAndCallerPosition = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const role_id_param = root.utils.intToArray(root.types.RoleId, this.payload.role_id, .big);
            const guild_id_param = root.utils.intToArray(root.types.GuildId, this.payload.guild_id, .big);
            const caller_user_id_param = root.utils.intToArray(root.types.UserId, this.payload.caller_user_id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT r.position,
                \\       (SELECT COALESCE(MAX(cr.position), 0)::smallint
                \\        FROM app.member_roles cmr
                \\        JOIN app.roles cr ON cr.guild_id = cmr.guild_id AND cr.id = cmr.role_id
                \\        WHERE cmr.guild_id = r.guild_id AND cmr.user_id = $3) AS caller_pos
                \\FROM app.roles r
                \\WHERE r.id = $1 AND r.guild_id = $2;
            , &.{
                &role_id_param,
                &guild_id_param,
                &caller_user_id_param,
            }, &.{
                role_id_param.len,
                guild_id_param.len,
                caller_user_id_param.len,
            }, &.{
                .binary,
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("GetRoleAndCallerPosition failed to send: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("GetRoleAndCallerPosition failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                if (res.ntuples() == 0) {
                    return .{ .ready = null };
                }

                std.debug.assert(res.nfields() >= 2);
                std.debug.assert(res.ntuples() == 1);

                const item: Item = .{
                    .position = res.readInt(root.types.Position, 0, 0),
                    .caller_position = res.readIntOptional(root.types.Position, 0, 1) orelse 0,
                };

                return .{ .ready = item };
            }

            return .{ .ready = null };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetRoleAndCallerPosition = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(
        db: *root.db.Connection,
        payload: Payload,
    ) GetRoleAndCallerPosition {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *GetRoleAndCallerPosition) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const Create = struct {
    const Item = bool;

    pub const Result = Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Create, Result, anyerror);

    pub const Payload = struct {
        guild_id: root.types.GuildId,
        role_id: root.types.RoleId,
        name: []const u8,
        permissions: root.types.Permissions,
        color: ?root.types.Color,
        mentionable: bool = true,
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
            const role_id_param = root.utils.intToArray(root.types.RoleId, this.payload.role_id, .big);
            const guild_id_param = root.utils.intToArray(root.types.GuildId, this.payload.guild_id, .big);
            const permissions_param = root.utils.packedStructToArray(root.types.Permissions, this.payload.permissions, .big);
            const color_param = if (this.payload.color) |color|
                root.utils.intToArray(u32, color, .big)
            else
                null;
            const mentionable_param = root.utils.intToArray(u8, if (this.payload.mentionable) 1 else 0, .big);

            // Insert the new role at the bottom (position 1) and shift every
            // other non-@everyone role up by one. The position unique
            // constraint is DEFERRABLE, so the transient ordering is only
            // checked at the end of the (implicit) transaction.
            switch (this.db.sendQueryParams(
                \\WITH shifted AS (
                \\    UPDATE app.roles
                \\    SET position = position + 1
                \\    WHERE guild_id = $2::bigint AND id <> guild_id
                \\)
                \\INSERT INTO app.roles (id, guild_id, name, position, permissions, color, mentionable)
                \\VALUES ($1, $2, $3, 1, $4, $5, $6::boolean);
            , &.{
                &role_id_param,
                &guild_id_param,
                this.payload.name.ptr,
                &permissions_param,
                if (color_param != null) &color_param.? else null,
                &mentionable_param,
            }, &.{
                role_id_param.len,
                guild_id_param.len,
                @intCast(this.payload.name.len),
                permissions_param.len,
                if (color_param != null) color_param.?.len else 0,
                mentionable_param.len,
            }, &.{
                .binary,
                .binary,
                .binary,
                .binary,
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("CreateGuildRole failed to send: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("CreateGuildRole failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .{ .ready = true };
            } else {
                return .{ .ready = false };
            }
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *Create = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) Create {
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

pub const Get = struct {
    const Item = struct {
        guild_id: root.types.GuildId,
        name: []const u8,
        position: root.types.Position,
        permissions: root.types.Permissions,
        color: ?root.types.Color,
        mentionable: bool,
    };

    pub const Result = ?Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Get, Result, anyerror);

    pub const Payload = struct {
        role_id: root.types.RoleId,
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
            const role_id_param = root.utils.intToArray(root.types.RoleId, this.payload.role_id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT r.guild_id, r.name, r.position, r.permissions, r.color, r.mentionable
                \\FROM app.roles r WHERE r.id = $1;
            , &.{
                &role_id_param,
            }, &.{
                role_id_param.len,
            }, &.{
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("GetRole failed to send: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("GetRole failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                if (res.ntuples() == 0) {
                    return .{ .ready = null };
                }

                std.debug.assert(res.ntuples() == 1);
                std.debug.assert(res.nfields() >= 6);

                const item: Item = .{
                    .guild_id = res.readInt(root.types.GuildId, 0, 0),
                    .name = res.readSliceDupe(this.allocator, 0, 1) catch |err| {
                        SCOPE.err("GetRole failed to dupe 'name': {t}", .{err});

                        return .{ .err = err };
                    },
                    .position = res.readInt(root.types.Position, 0, 2),
                    .permissions = res.readPackedStruct(root.types.Permissions, 0, 3),
                    .color = if (res.readIntOptional(u32, 0, 4)) |color|
                        @as(root.types.Color, @truncate(color))
                    else
                        null,
                    .mentionable = res.readBool(0, 5),
                };

                return .{ .ready = item };
            }

            return .{ .ready = null };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *Get = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(allocator: std.mem.Allocator, db: *root.db.Connection, payload: Payload) Get {
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

pub const Delete = struct {
    /// `null` = the role does not exist (or it is the @everyone role)
    pub const Result = ?void;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Delete, Result, anyerror);

    pub const Payload = struct {
        guild_id: root.types.GuildId,
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
        const this: *Delete = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const guild_id_param = root.utils.intToArray(root.types.GuildId, this.payload.guild_id, .big);
            const role_id_param = root.utils.intToArray(root.types.RoleId, this.payload.role_id, .big);

            switch (this.db.sendQueryParams(
                \\DELETE FROM app.roles
                \\WHERE id = $2 AND guild_id = $1 AND id <> guild_id
                \\RETURNING id;
            , &.{
                &guild_id_param,
                &role_id_param,
            }, &.{
                guild_id_param.len,
                role_id_param.len,
            }, &.{
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("Delete failed to send query: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("Delete failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                if (res.ntuples() == 0) {
                    return .{ .ready = null };
                }

                return .{ .ready = {} };
            }

            return .{ .ready = null };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *Delete = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) Delete {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *Delete) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const Update = struct {
    /// `false` = the role does not exist
    pub const Result = bool;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Update, Result, anyerror);

    pub const Payload = struct {
        pub const ColorMode = enum(u16) {
            keep,
            /// `null` color clears the color
            set,
        };

        pub const MentionableMode = enum(u16) {
            keep,
            set,
        };

        role_id: root.types.RoleId,
        name: ?[]const u8,
        permissions: ?root.types.Permissions,
        color_mode: ColorMode,
        color: ?root.types.Color,
        mentionable_mode: MentionableMode = .keep,
        mentionable: bool = true,
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
            const role_id_param = root.utils.intToArray(root.types.RoleId, this.payload.role_id, .big);
            const permissions_param = if (this.payload.permissions) |permissions|
                root.utils.packedStructToArray(root.types.Permissions, permissions, .big)
            else
                null;
            const color_mode_param = root.utils.intToArray(u16, @intFromEnum(this.payload.color_mode), .big);
            const color_param = if (this.payload.color) |color|
                root.utils.intToArray(u32, color, .big)
            else
                null;
            const mentionable_mode_param = root.utils.intToArray(u16, @intFromEnum(this.payload.mentionable_mode), .big);
            const mentionable_param = root.utils.intToArray(u8, if (this.payload.mentionable) 1 else 0, .big);

            switch (this.db.sendQueryParams(
                \\UPDATE app.roles
                \\SET name = COALESCE($2::text, name),
                \\    permissions = COALESCE($3::bytea, permissions),
                \\    color = CASE $4::smallint WHEN 0 THEN color ELSE $5::integer END,
                \\    mentionable = CASE $6::smallint WHEN 0 THEN mentionable ELSE $7::boolean END
                \\WHERE id = $1
                \\RETURNING id;
            , &.{
                &role_id_param,
                if (this.payload.name) |name| name.ptr else null,
                if (permissions_param != null) &permissions_param.? else null,
                &color_mode_param,
                if (color_param != null) &color_param.? else null,
                &mentionable_mode_param,
                &mentionable_param,
            }, &.{
                role_id_param.len,
                if (this.payload.name) |name| @intCast(name.len) else 0,
                if (permissions_param != null) permissions_param.?.len else 0,
                color_mode_param.len,
                if (color_param != null) color_param.?.len else 0,
                mentionable_mode_param.len,
                mentionable_param.len,
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
                    SCOPE.err("UpdateRole failed to send: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("UpdateRole failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .{ .ready = res.ntuples() != 0 };
            }

            return .{ .ready = false };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *Update = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) Update {
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

pub const CreateSuperuser = struct {
    /// `null` = the guild or the user does not exist
    pub const Result = ?struct {
        role_id: root.types.RoleId,
    };

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(CreateSuperuser, Result, anyerror);

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
        const this: *CreateSuperuser = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const guild_id_param = root.utils.intToArray(root.types.GuildId, this.payload.guild_id, .big);
            const role_id_param = root.utils.intToArray(root.types.RoleId, this.payload.role_id, .big);
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);
            const permissions_param = root.utils.intToArray(
                root.types.Permissions.Int,
                root.types.Permissions.allBits().raw(),
                .big,
            );

            // The superuser role sits on top (MAX(position) + 1) rather than
            // being pinned to the SMALLINT maximum; unique positions keep
            // multiple superusers distinct.
            switch (this.db.sendQueryParams(
                \\WITH max_pos AS (
                \\    SELECT (COALESCE(MAX(position), 0) + 1)::smallint AS pos
                \\    FROM app.roles
                \\    WHERE guild_id = $1::bigint
                \\),
                \\new_role AS (
                \\    INSERT INTO app.roles (id, guild_id, name, position, permissions)
                \\    SELECT $2::bigint, $1::bigint, 'superuser', max_pos.pos, $4::bytea
                \\    FROM max_pos
                \\    WHERE EXISTS (SELECT 1 FROM app.guilds WHERE id = $1)
                \\      AND EXISTS (SELECT 1 FROM app.users  WHERE id = $3)
                \\    RETURNING id
                \\),
                \\assigned AS (
                \\    INSERT INTO app.member_roles (guild_id, role_id, user_id)
                \\    SELECT $1::bigint, id, $3::bigint FROM new_role
                \\)
                \\SELECT id FROM new_role;
            , &.{
                &guild_id_param,
                &role_id_param,
                &user_id_param,
                &permissions_param,
            }, &.{
                guild_id_param.len,
                role_id_param.len,
                user_id_param.len,
                permissions_param.len,
            }, &.{
                .binary,
                .binary,
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("CreateSuperuserRole failed to send query: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("CreateSuperuserRole failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                if (res.ntuples() == 0) {
                    return .{ .ready = null };
                }

                std.debug.assert(res.nfields() >= 1);

                return .{
                    .ready = .{
                        .role_id = res.readInt(root.types.RoleId, 0, 0),
                    },
                };
            }

            return .{ .ready = null };
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *CreateSuperuser = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) CreateSuperuser {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *CreateSuperuser) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// Assign dense positions 1..N to the guild's non-`@everyone` roles following
/// the given order. `ids_csv` is a comma-separated list of decimal role ids in
/// the target order (validated by the caller). The `position` unique
/// constraint is DEFERRABLE, so the whole permutation is checked once at the
/// end of the (implicit) transaction.
pub const Reorder = struct {
    pub const Result = void;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Reorder, Result, anyerror);

    pub const Payload = struct {
        guild_id: root.types.GuildId,
        ids_csv: []const u8,
    };

    const State = enum {
        start,
        waiting,
    };

    db: *root.db.Connection,
    payload: Payload,
    state: State = .start,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *Reorder = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const guild_id_param = root.utils.intToArray(root.types.GuildId, this.payload.guild_id, .big);

            switch (this.db.sendQueryParams(
                \\UPDATE app.roles AS r
                \\SET position = t.ord::smallint
                \\FROM unnest(string_to_array($2::text, ',')) WITH ORDINALITY AS t(id, ord)
                \\WHERE r.guild_id = $1::bigint AND r.id = t.id::bigint;
            , &.{
                &guild_id_param,
                this.payload.ids_csv.ptr,
            }, &.{
                guild_id_param.len,
                @intCast(this.payload.ids_csv.len),
            }, &.{
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("Reorder failed to send: {s}", .{this.db.errorMessage()});

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
                    SCOPE.err("Reorder failed: {s}", .{res.errorMessage()});

                    return .{ .err = error.PGError };
                }

                return .ready;
            }

            return .ready;
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *Reorder = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) Reorder {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *Reorder) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

pub const GetChannelOverwrites = struct {
    const Item = struct {
        role_id: ?root.types.RoleId,
        overwrites: root.types.Overwrites,
    };

    pub const Result = Item;

    pub const Stream = root.task.Stream(Result, anyerror);
    pub const Lazy = root.task.LazyStream(GetChannelOverwrites, Result, anyerror);

    pub const Payload = struct {
        guild_id: root.types.GuildId,
        channel_id: root.types.ChannelId,
        user_id: root.types.UserId,
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
        const this: *GetChannelOverwrites = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const channel_id_param = root.utils.intToArray(root.types.ChannelId, this.payload.channel_id, .big);
            const guild_id_param = root.utils.intToArray(root.types.GuildId, this.payload.guild_id, .big);
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT role_id, allow, deny
                \\FROM app.overwrites
                \\WHERE channel_id = $1
                \\  AND (
                \\        (target_type = 0 AND role_id = $2)
                \\     OR (target_type = 0 AND EXISTS (
                \\            SELECT 1 FROM app.member_roles AS mr
                \\            WHERE mr.guild_id = $2
                \\              AND mr.role_id  = app.overwrites.role_id
                \\              AND mr.user_id  = $3
                \\        ))
                \\     OR (target_type = 1 AND user_id = $3)
                \\  );
            , &.{
                &channel_id_param,
                &guild_id_param,
                &user_id_param,
            }, &.{
                channel_id_param.len,
                guild_id_param.len,
                user_id_param.len,
            }, &.{
                .binary,
                .binary,
                .binary,
            }, .binary)) {
                .ready => this.state = .waiting,
                .err => |err| {
                    SCOPE.err("GetChannelOverwrites failed to send: {s}", .{this.db.errorMessage()});

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
                        SCOPE.err("GetChannelOverwrites failed: {s}", .{res.errorMessage()});
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

                std.debug.assert(res.nfields() >= 3);

                const result: Result = .{
                    .role_id = res.readIntOptional(root.types.RoleId, yield.pos, 0),
                    .overwrites = .{
                        .allow = res.readPackedStruct(root.types.Permissions, yield.pos, 1),
                        .deny = res.readPackedStruct(root.types.Permissions, yield.pos, 2),
                    },
                };

                yield.pos += 1;

                return .{ .yielded = result };
            }
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetChannelOverwrites = @ptrCast(@alignCast(ctx));

        this.db.release();
    }

    pub inline fn init(
        db: *root.db.Connection,
        payload: Payload,
    ) GetChannelOverwrites {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn stream(this: *GetChannelOverwrites) Stream {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// Streams every overwrite of a guild that applies to one user: the `@everyone`
/// overwrite, the overwrites of the roles the user holds, and the user's member
/// overwrite. Same relevance filter as `GetChannelOverwrites`, but scoped to the
/// whole guild (one row per channel/target) so the caller can fold all channels
/// at once.
pub const GetGuildOverwrites = struct {
    const Item = struct {
        channel_id: root.types.ChannelId,
        role_id: ?root.types.RoleId,
        overwrites: root.types.Overwrites,
    };

    pub const Result = Item;

    pub const Stream = root.task.Stream(Result, anyerror);
    pub const Lazy = root.task.LazyStream(GetGuildOverwrites, Result, anyerror);

    pub const Payload = struct {
        guild_id: root.types.GuildId,
        user_id: root.types.UserId,
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
        const this: *GetGuildOverwrites = @ptrCast(@alignCast(ctx));

        if (this.state == .start) {
            const guild_id_param = root.utils.intToArray(root.types.GuildId, this.payload.guild_id, .big);
            const user_id_param = root.utils.intToArray(root.types.UserId, this.payload.user_id, .big);

            switch (this.db.sendQueryParams(
                \\SELECT channel_id, role_id, allow, deny
                \\FROM app.overwrites
                \\WHERE guild_id = $1
                \\  AND (
                \\        (target_type = 0 AND role_id = $1)
                \\     OR (target_type = 0 AND EXISTS (
                \\            SELECT 1 FROM app.member_roles AS mr
                \\            WHERE mr.guild_id = $1
                \\              AND mr.role_id  = app.overwrites.role_id
                \\              AND mr.user_id  = $2
                \\        ))
                \\     OR (target_type = 1 AND user_id = $2)
                \\  );
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
                    SCOPE.err("GetGuildOverwrites failed to send: {s}", .{this.db.errorMessage()});

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
                        SCOPE.err("GetGuildOverwrites failed: {s}", .{res.errorMessage()});
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

                std.debug.assert(res.nfields() >= 4);

                const result: Result = .{
                    .channel_id = res.readInt(root.types.ChannelId, yield.pos, 0),
                    .role_id = res.readIntOptional(root.types.RoleId, yield.pos, 1),
                    .overwrites = .{
                        .allow = res.readPackedStruct(root.types.Permissions, yield.pos, 2),
                        .deny = res.readPackedStruct(root.types.Permissions, yield.pos, 3),
                    },
                };

                yield.pos += 1;

                return .{ .yielded = result };
            }
        }

        unreachable;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetGuildOverwrites = @ptrCast(@alignCast(ctx));

        if (this.state == .yielding) {
            this.state.yielding.res.deinit();
        }

        this.db.release();
    }

    pub inline fn init(
        db: *root.db.Connection,
        payload: Payload,
    ) GetGuildOverwrites {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn stream(this: *GetGuildOverwrites) Stream {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};
