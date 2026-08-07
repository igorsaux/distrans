// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const pq = @import("pq");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.repo_rights);

/// Computes guild-level (base) permissions for a user: OR-fold of `@everyone`
/// permissions and all roles the user has in `app.member_roles`.
pub const CheckUserGuildRights = struct {
    pub const Result = bool;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(CheckUserGuildRights, Result, anyerror);

    pub const Payload = struct {
        required: root.types.Permissions,
        guild_id: root.types.GuildId,
        user_id: root.types.UserId,
    };

    db: *root.db.Connection,
    payload: Payload,
    get_guild_base_permissions_task: ?root.repo.guilds.GetBasePermissions.Lazy = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *CheckUserGuildRights = @ptrCast(@alignCast(ctx));

        // await this.get_guild_base_permissions_task
        {
            if (this.get_guild_base_permissions_task == null) {
                this.get_guild_base_permissions_task = .from(.init(this.db, .{
                    .guild_id = this.payload.guild_id,
                    .user_id = this.payload.user_id,
                }));
            }

            while (this.get_guild_base_permissions_task.?.await()) |res| {
                return res.mapDiscard(Result);
            }

            if (this.get_guild_base_permissions_task.?.result == null) {
                SCOPE.err("CheckUserGuildRights failed: 'guild_id' or 'user_id' does not exist", .{});

                return .{ .ready = false };
            }
        }

        return .{
            .ready = this.get_guild_base_permissions_task.?.result.?.hasRightsTo(this.payload.required),
        };
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *CheckUserGuildRights = @ptrCast(@alignCast(ctx));

        this.db.release();

        if (this.get_guild_base_permissions_task) |*t| {
            t.dispose();
            this.get_guild_base_permissions_task = null;
        }
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) CheckUserGuildRights {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *CheckUserGuildRights) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// Folds channel overwrites into the base guild permissions, in the fixed tier
/// order `@everyone` → roles → member. `skip_denies`/`skip_allows` are read
/// from `base` only and zero the deny/allow masks of all three tiers before
/// folding. This is the single source of truth for the channel permission
/// formula shared by `CheckUserChannelRights`, `GetUserChannelPermissions` and
/// `GetGuildChannelPermissions`; the tier order must never be reordered here or
/// in the callers.
pub inline fn foldChannelPermissions(
    base: root.types.Permissions,
    everyone: root.types.Overwrites,
    roles: root.types.Overwrites,
    member: root.types.Overwrites,
) root.types.Permissions {
    const skip_denies = base.skip_denies;
    const skip_allows = base.skip_allows;

    var result_perms = base;

    result_perms = everyone.foldGated(result_perms, skip_denies, skip_allows);
    result_perms = roles.foldGated(result_perms, skip_denies, skip_allows);
    result_perms = member.foldGated(result_perms, skip_denies, skip_allows);

    return result_perms;
}

/// Computes channel permissions for a user: base guild permissions folded
/// with the channel overwrites (everyone, then all roles, then the member).
/// The base's `skip_denies`/`skip_allows` bits zero the deny/allow masks of
/// all three overwrite tiers before folding.
pub const CheckUserChannelRights = struct {
    pub const Result = bool;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(CheckUserChannelRights, Result, anyerror);

    pub const Payload = struct {
        required: root.types.Permissions,
        guild_id: root.types.GuildId,
        channel_id: root.types.ChannelId,
        user_id: root.types.UserId,
    };

    db: *root.db.Connection,
    payload: Payload,
    get_guild_base_permissions_task: ?root.repo.guilds.GetBasePermissions.Lazy = null,
    get_channel_overwrites_stream: ?root.repo.roles.GetChannelOverwrites.Lazy = null,
    everyone_overwrites: root.types.Overwrites = .{},
    roles_overwrites: root.types.Overwrites = .{},
    member_overwrites: root.types.Overwrites = .{},

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *CheckUserChannelRights = @ptrCast(@alignCast(ctx));

        // await this.get_guild_base_permissions_task
        {
            if (this.get_guild_base_permissions_task == null) {
                this.get_guild_base_permissions_task = .from(.init(this.db, .{
                    .guild_id = this.payload.guild_id,
                    .user_id = this.payload.user_id,
                }));
            }

            while (this.get_guild_base_permissions_task.?.await()) |res| {
                return res.mapDiscard(Result);
            }

            if (this.get_guild_base_permissions_task.?.result == null) {
                SCOPE.err("CheckUserChannelRights failed: 'guild_id' or 'user_id' does not exist", .{});

                return .{ .ready = false };
            }
        }

        // await this.get_channel_overwrites_stream
        {
            if (this.get_channel_overwrites_stream == null) {
                this.get_channel_overwrites_stream = .from(.init(this.db, .{
                    .guild_id = this.payload.guild_id,
                    .channel_id = this.payload.channel_id,
                    .user_id = this.payload.user_id,
                }));
            }

            while (this.get_channel_overwrites_stream.?.await()) |res| {
                switch (res) {
                    .next => |n| {
                        if (n.role_id == null) {
                            // member overwrite
                            this.member_overwrites = this.member_overwrites.combineOr(n.overwrites);
                        } else if (n.role_id.? == this.payload.guild_id) {
                            // @everyone overwrite
                            this.everyone_overwrites = this.everyone_overwrites.combineOr(n.overwrites);
                        } else {
                            // role overwrite
                            this.roles_overwrites = this.roles_overwrites.combineOr(n.overwrites);
                        }
                    },
                    .poll => |p| return p.mapDiscard(Result),
                }
            }
        }

        const result_perms = foldChannelPermissions(
            this.get_guild_base_permissions_task.?.result.?,
            this.everyone_overwrites,
            this.roles_overwrites,
            this.member_overwrites,
        );

        return .{
            .ready = result_perms.hasRightsTo(this.payload.required),
        };
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *CheckUserChannelRights = @ptrCast(@alignCast(ctx));

        this.db.release();

        if (this.get_guild_base_permissions_task) |*t| {
            t.dispose();
            this.get_guild_base_permissions_task = null;
        }

        if (this.get_channel_overwrites_stream) |*s| {
            s.dispose();
            this.get_channel_overwrites_stream = null;
        }
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) CheckUserChannelRights {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *CheckUserChannelRights) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// Computes channel permissions for a user and returns the resulting mask
/// (`null` = the guild or the user does not exist). Mirrors
/// `CheckUserChannelRights` (base guild permissions folded with the channel
/// overwrites: everyone, then all roles, then the member; the base's
/// `skip_denies`/`skip_allows` bits zero the deny/allow masks of all tiers).
pub const GetUserChannelPermissions = struct {
    pub const Result = ?root.types.Permissions;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(GetUserChannelPermissions, Result, anyerror);

    pub const Payload = struct {
        guild_id: root.types.GuildId,
        channel_id: root.types.ChannelId,
        user_id: root.types.UserId,
    };

    db: *root.db.Connection,
    payload: Payload,
    get_guild_base_permissions_task: ?root.repo.guilds.GetBasePermissions.Lazy = null,
    get_channel_overwrites_stream: ?root.repo.roles.GetChannelOverwrites.Lazy = null,
    everyone_overwrites: root.types.Overwrites = .{},
    roles_overwrites: root.types.Overwrites = .{},
    member_overwrites: root.types.Overwrites = .{},

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *GetUserChannelPermissions = @ptrCast(@alignCast(ctx));

        // await this.get_guild_base_permissions_task
        {
            if (this.get_guild_base_permissions_task == null) {
                this.get_guild_base_permissions_task = .from(.init(this.db, .{
                    .guild_id = this.payload.guild_id,
                    .user_id = this.payload.user_id,
                }));
            }

            while (this.get_guild_base_permissions_task.?.await()) |res| {
                return res.mapDiscard(Result);
            }

            if (this.get_guild_base_permissions_task.?.result == null) {
                return .{ .ready = null };
            }
        }

        // await this.get_channel_overwrites_stream
        {
            if (this.get_channel_overwrites_stream == null) {
                this.get_channel_overwrites_stream = .from(.init(this.db, .{
                    .guild_id = this.payload.guild_id,
                    .channel_id = this.payload.channel_id,
                    .user_id = this.payload.user_id,
                }));
            }

            while (this.get_channel_overwrites_stream.?.await()) |res| {
                switch (res) {
                    .next => |n| {
                        if (n.role_id == null) {
                            // member overwrite
                            this.member_overwrites = this.member_overwrites.combineOr(n.overwrites);
                        } else if (n.role_id.? == this.payload.guild_id) {
                            // @everyone overwrite
                            this.everyone_overwrites = this.everyone_overwrites.combineOr(n.overwrites);
                        } else {
                            // role overwrite
                            this.roles_overwrites = this.roles_overwrites.combineOr(n.overwrites);
                        }
                    },
                    .poll => |p| return p.mapDiscard(Result),
                }
            }
        }

        const result_perms = foldChannelPermissions(
            this.get_guild_base_permissions_task.?.result.?,
            this.everyone_overwrites,
            this.roles_overwrites,
            this.member_overwrites,
        );

        return .{ .ready = result_perms };
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetUserChannelPermissions = @ptrCast(@alignCast(ctx));

        this.db.release();

        if (this.get_guild_base_permissions_task) |*t| {
            t.dispose();
            this.get_guild_base_permissions_task = null;
        }

        if (this.get_channel_overwrites_stream) |*s| {
            s.dispose();
            this.get_channel_overwrites_stream = null;
        }
    }

    pub inline fn init(db: *root.db.Connection, payload: Payload) GetUserChannelPermissions {
        db.acquire();

        return .{
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *GetUserChannelPermissions) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// Computes the effective channel permissions of one user over every channel of
/// a guild they have a relevant overwrite on, in a single pass: one query for
/// the base (guild-level) permissions plus one query for all the guild's
/// overwrites that apply to the user (`@everyone`, their roles, their member
/// overwrite). Channels without any relevant overwrite are not returned — the
/// caller falls back to `base` for them. Mirrors
/// `GetUserChannelPermissions`/`CheckUserChannelRights` through the shared
/// `foldChannelPermissions` helper, so the returned masks are bit-for-bit the
/// same values those tasks would compute per channel.
pub const GetGuildChannelPermissions = struct {
    pub const Tiers = struct {
        everyone: root.types.Overwrites = .{},
        roles: root.types.Overwrites = .{},
        member: root.types.Overwrites = .{},
    };

    pub const Item = struct {
        channel_id: root.types.ChannelId,
        permissions: root.types.Permissions,
    };

    pub const Result = struct {
        /// Base (guild-level) permissions of the user; also the effective
        /// permissions of every channel absent from `channels`.
        base: root.types.Permissions,
        /// Channels with at least one relevant overwrite, with their folded
        /// effective permissions.
        channels: []const Item,
    };

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(GetGuildChannelPermissions, Result, anyerror);

    pub const Payload = struct {
        guild_id: root.types.GuildId,
        user_id: root.types.UserId,
    };

    allocator: std.mem.Allocator,
    db: *root.db.Connection,
    payload: Payload,
    base: root.types.Permissions = .{},
    tiers: std.AutoHashMap(root.types.ChannelId, Tiers),
    get_guild_base_permissions_task: ?root.repo.guilds.GetBasePermissions.Lazy = null,
    get_guild_overwrites_stream: ?root.repo.roles.GetGuildOverwrites.Lazy = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *GetGuildChannelPermissions = @ptrCast(@alignCast(ctx));

        // await this.get_guild_base_permissions_task
        {
            if (this.get_guild_base_permissions_task == null) {
                this.get_guild_base_permissions_task = .from(.init(this.db, .{
                    .guild_id = this.payload.guild_id,
                    .user_id = this.payload.user_id,
                }));
            }

            while (this.get_guild_base_permissions_task.?.await()) |res| {
                return res.mapDiscard(Result);
            }

            if (this.get_guild_base_permissions_task.?.result) |base| {
                this.base = base;
            }
        }

        // await this.get_guild_overwrites_stream
        {
            if (this.get_guild_overwrites_stream == null) {
                this.get_guild_overwrites_stream = .from(.init(this.db, .{
                    .guild_id = this.payload.guild_id,
                    .user_id = this.payload.user_id,
                }));
            }

            while (this.get_guild_overwrites_stream.?.await()) |res| {
                switch (res) {
                    .next => |n| {
                        const entry = this.tiers.getOrPut(n.channel_id) catch |err| {
                            SCOPE.err("GetGuildChannelPermissions failed to grow the map: {t}", .{err});

                            return .{ .err = err };
                        };

                        if (!entry.found_existing) {
                            entry.value_ptr.* = .{};
                        }

                        if (n.role_id == null) {
                            // member overwrite
                            entry.value_ptr.member = entry.value_ptr.member.combineOr(n.overwrites);
                        } else if (n.role_id.? == this.payload.guild_id) {
                            // @everyone overwrite
                            entry.value_ptr.everyone = entry.value_ptr.everyone.combineOr(n.overwrites);
                        } else {
                            // role overwrite
                            entry.value_ptr.roles = entry.value_ptr.roles.combineOr(n.overwrites);
                        }
                    },
                    .poll => |p| return p.mapDiscard(Result),
                }
            }
        }

        var channels: std.ArrayList(Item) = .empty;

        var it = this.tiers.iterator();
        while (it.next()) |entry| {
            channels.append(this.allocator, .{
                .channel_id = entry.key_ptr.*,
                .permissions = foldChannelPermissions(
                    this.base,
                    entry.value_ptr.everyone,
                    entry.value_ptr.roles,
                    entry.value_ptr.member,
                ),
            }) catch |err| {
                SCOPE.err("GetGuildChannelPermissions failed to grow the list: {t}", .{err});

                return .{ .err = err };
            };
        }

        return .{ .ready = .{
            .base = this.base,
            .channels = channels.items,
        } };
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetGuildChannelPermissions = @ptrCast(@alignCast(ctx));

        if (this.get_guild_base_permissions_task) |*t| {
            t.dispose();
            this.get_guild_base_permissions_task = null;
        }

        if (this.get_guild_overwrites_stream) |*s| {
            s.dispose();
            this.get_guild_overwrites_stream = null;
        }

        this.tiers.deinit();

        this.db.release();
    }

    pub inline fn init(
        allocator: std.mem.Allocator,
        db: *root.db.Connection,
        payload: Payload,
    ) GetGuildChannelPermissions {
        db.acquire();

        return .{
            .allocator = allocator,
            .db = db,
            .payload = payload,
            .tiers = std.AutoHashMap(root.types.ChannelId, Tiers).init(allocator),
        };
    }

    pub inline fn task(this: *GetGuildChannelPermissions) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};
