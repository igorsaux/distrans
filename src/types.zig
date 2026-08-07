// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

pub const GuildId = u64;
pub const UserId = u64;
pub const ChannelId = u64;
pub const MessageId = u64;
pub const RoleId = u64;
pub const EmojiId = u64;
pub const FileId = u64;
pub const PushSubscriptionId = u64;
pub const WebhookId = u64;
pub const AuditLogId = u64;
/// Upper bound on the UTF-8 byte length of a single fully-qualified RGI emoji
/// sequence accepted as a unicode reaction; the longest current sequence is
/// far below this.
pub const MAX_UNICODE_EMOJI_BYTES: usize = 64;
pub const Position = u16;
/// Upper bound of `app.roles.position` / `app.channels.position` (SMALLINT).
/// `@everyone` stays at 0; a guild can therefore hold at most this many
/// positioned entries. Role positions are unique per guild and dense
/// (`1..N`).
pub const MAX_POSITION: Position = 32767;
pub const Color = u24;
pub const ChannelKind = enum(u16) {
    channel = 0,
    category = 1,
};

/// The action recorded in `app.audit_log.action`. Wire values are the field
/// names (`@tagName`). One action per changed field / operation: a multi-field
/// PATCH writes one entry per present field. The numeric values are persisted
/// in `app.audit_log.action`; change them only together with that data.
pub const AuditAction = enum(u16) {
    guild_name_update = 0,
    guild_avatar_update = 1,
    guild_avatar_delete = 2,
    channel_create = 3,
    channel_name_update = 4,
    channel_topic_update = 5,
    channel_parent_update = 6,
    channel_delete = 7,
    channel_reorder = 8,
    role_overwrite_update = 9,
    member_overwrite_update = 10,
    role_create = 11,
    role_name_update = 12,
    role_permissions_update = 13,
    role_color_update = 14,
    role_mentionable_update = 15,
    role_delete = 16,
    role_reorder = 17,
    role_grant = 18,
    role_revoke = 19,
    emoji_create = 20,
    emoji_name_update = 21,
    emoji_icon_update = 22,
    emoji_delete = 23,
    webhook_create = 24,
    webhook_name_update = 25,
    webhook_avatar_update = 26,
    webhook_avatar_delete = 27,
    webhook_delete = 28,
    message_delete = 29,
    message_pin = 30,
    message_unpin = 31,
};

/// The guild tier of a user's notification settings
/// (app.guild_notification_settings.level). Wire values are the field names.
pub const GuildNotificationLevel = enum(u16) {
    all_messages = 0,
    only_mentions = 1,
    nothing = 2,

    pub const default: GuildNotificationLevel = .all_messages;
};

/// The channel tier of a user's notification settings
/// (app.channel_notification_settings.level). `inherit` falls back to the
/// parent category (text channels) and then the guild. Wire values are the
/// field names.
pub const ChannelNotificationLevel = enum(u16) {
    inherit = 0,
    all_messages = 1,
    only_mentions = 2,
    nothing = 3,

    pub const default: ChannelNotificationLevel = .inherit;
};

pub const Permissions = packed struct(u128) {
    pub const Int = @typeInfo(Permissions).@"struct".backing_integer.?;

    read_messages: bool = false,
    send_messages: bool = false,
    delete_messages: bool = false,
    create_channels: bool = false,
    modify_channels: bool = false,
    delete_channels: bool = false,
    create_roles: bool = false,
    modify_roles: bool = false,
    delete_roles: bool = false,
    grant_roles: bool = false,
    revoke_roles: bool = false,
    manage_overwrites: bool = false,
    skip_allows: bool = false,
    skip_denies: bool = false,
    guild_modify: bool = false,
    add_reactions: bool = false,
    delete_reactions: bool = false,
    create_emoji: bool = false,
    modify_emoji: bool = false,
    delete_emoji: bool = false,
    mention_everyone: bool = false,
    add_pins: bool = false,
    delete_pins: bool = false,
    create_webhooks: bool = false,
    modify_webhooks: bool = false,
    delete_webhooks: bool = false,
    view_audit_log: bool = false,
    _reserved: u101 = 0,

    pub inline fn defaultEveryone() Permissions {
        return .{
            .read_messages = true,
            .send_messages = true,
            .add_reactions = true,
        };
    }

    pub inline fn allBits() Permissions {
        return @bitCast(@as(Int, std.math.maxInt(Int)));
    }

    pub inline fn raw(this: Permissions) Int {
        return @bitCast(this);
    }

    pub inline fn from(value: Int) Permissions {
        return @bitCast(value);
    }

    pub inline fn combineOr(a: Permissions, b: Permissions) Permissions {
        return @bitCast(@as(Int, @bitCast(a)) | @as(Int, @bitCast(b)));
    }

    pub inline fn hasRightsTo(this: Permissions, required: Permissions) bool {
        return (this.raw() & required.raw()) == required.raw();
    }

    pub const defaultEveryoneSqlDefault = std.fmt.comptimePrint(
        "\\x{x:0>32}",
        .{@as(Int, @bitCast(defaultEveryone()))},
    );
};

pub const Overwrites = struct {
    pub const Type = enum(u16) {
        role = 0,
        member = 1,
    };

    pub const Target = union(enum) {
        role: RoleId,
        member: UserId,

        pub inline fn ty(this: Target) Type {
            return switch (this) {
                .role => .role,
                .member => .member,
            };
        }
    };

    allow: Permissions = .{},
    deny: Permissions = .{},

    pub inline fn combineOr(a: Overwrites, b: Overwrites) Overwrites {
        return .{
            .allow = a.allow.combineOr(b.allow),
            .deny = a.deny.combineOr(b.deny),
        };
    }

    pub inline fn fold(this: Overwrites, perms: Permissions) Permissions {
        return Permissions.from((perms.raw() & ~this.deny.raw()) | this.allow.raw());
    }

    /// Folds the overwrites into `perms`, zeroing the deny mask (`skip_denies`)
    /// and/or the allow mask (`skip_allows`) first. Used by the rights
    /// computation: the caller's base permissions decide which overwrite
    /// masks apply at all.
    pub inline fn foldGated(this: Overwrites, perms: Permissions, skip_denies: bool, skip_allows: bool) Permissions {
        var deny = this.deny;
        var allow = this.allow;

        if (skip_denies) {
            deny = .{};
        }

        if (skip_allows) {
            allow = .{};
        }

        return Permissions.from((perms.raw() & ~deny.raw()) | allow.raw());
    }
};

pub const Embed = struct {
    pub const Type = enum {
        rich,
    };

    pub const Footer = struct {
        text: ?[]const u8 = null,
        icon_url: ?[]const u8 = null,
    };

    pub const Image = struct {
        url: []const u8,
    };

    pub const Thumbnail = struct {
        url: []const u8,
    };

    pub const Video = struct {
        url: []const u8,
    };

    pub const Author = struct {
        name: ?[]const u8 = null,
        url: ?[]const u8 = null,
        icon_url: ?[]const u8 = null,
    };

    pub const Field = struct {
        name: ?[]const u8 = null,
        value: ?[]const u8 = null,
        @"inline": bool = false,
    };

    type: Type = .rich,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    url: ?[]const u8 = null,
    /// Unix epoch, milliseconds.
    timestamp: ?u64 = null,
    color: ?Color = null,
    footer: ?Footer = null,
    image: ?Image = null,
    thumbnail: ?Thumbnail = null,
    video: ?Video = null,
    author: ?Author = null,
    fields: []const Field = &.{},
};
