// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../root.zig");

pub const Frame = struct {
    payload: []const u8,
    writer: *std.Io.Writer,

    pub inline fn respondText(this: Frame, content: []const u8) bool {
        return root.ws.writeFrame(this.writer, .text, content);
    }

    pub const Opcode = enum {
        dispatch,
        identify,
        hello,
        ack,
    };

    pub const EventType = enum {
        message_created,
        message_updated,
        message_deleted,
        message_pinned,
        message_unpinned,
        overwrite_updated,
        user_created,
        user_updated,
        user_deleted,
        guild_created,
        guild_updated,
        guild_deleted,
        channel_created,
        channel_updated,
        channel_deleted,
        channels_reordered,
        role_created,
        role_updated,
        role_deleted,
        role_granted,
        role_revoked,
        roles_reordered,
        emoji_created,
        emoji_updated,
        emoji_deleted,
        reaction_added,
        reaction_removed,
        webhook_created,
        webhook_updated,
        webhook_deleted,
    };

    pub const MessageCreatedEventData = struct {
        id: []const u8,
        channel_id: []const u8,
        guild_id: []const u8,
    };

    pub const MessageUpdatedEventData = struct {
        id: []const u8,
        channel_id: []const u8,
        guild_id: []const u8,
    };

    pub const MessageDeletedEventData = struct {
        id: []const u8,
        channel_id: []const u8,
        guild_id: []const u8,
    };

    pub const MessagePinnedEventData = struct {
        id: []const u8,
        channel_id: []const u8,
        guild_id: []const u8,
    };

    pub const MessageUnpinnedEventData = struct {
        id: []const u8,
        channel_id: []const u8,
        guild_id: []const u8,
    };

    pub const OverwriteUpdatedEventData = struct {
        guild_id: []const u8,
        channel_id: []const u8,
    };

    pub const UserCreatedEventData = struct {
        id: []const u8,
    };

    pub const UserUpdatedEventData = struct {
        id: []const u8,
    };

    pub const UserDeletedEventData = struct {
        id: []const u8,
    };

    pub const ChannelCreatedEventData = struct {
        id: []const u8,
        guild_id: []const u8,
    };

    pub const ChannelUpdatedEventData = struct {
        id: []const u8,
        guild_id: []const u8,
    };

    pub const ChannelDeletedEventData = struct {
        id: []const u8,
        guild_id: []const u8,
    };

    pub const ChannelsReorderedEventData = struct {
        guild_id: []const u8,
    };

    pub const GuildCreatedEventData = struct {
        id: []const u8,
    };

    pub const GuildUpdatedEventData = struct {
        id: []const u8,
    };

    pub const GuildDeletedEventData = struct {
        id: []const u8,
    };

    pub const RoleCreatedEventData = struct {
        id: []const u8,
        guild_id: []const u8,
    };

    pub const RoleUpdatedEventData = struct {
        id: []const u8,
        guild_id: []const u8,
    };

    pub const RoleDeletedEventData = struct {
        id: []const u8,
        guild_id: []const u8,
    };

    pub const RoleGrantedEventData = struct {
        id: []const u8,
        guild_id: []const u8,
        user_id: []const u8,
    };

    pub const RoleRevokedEventData = struct {
        id: []const u8,
        guild_id: []const u8,
        user_id: []const u8,
    };

    pub const RolesReorderedEventData = struct {
        guild_id: []const u8,
    };

    pub const EmojiCreatedEventData = struct {
        id: []const u8,
        guild_id: []const u8,
    };

    pub const EmojiUpdatedEventData = struct {
        id: []const u8,
        guild_id: []const u8,
    };

    pub const EmojiDeletedEventData = struct {
        id: []const u8,
        guild_id: []const u8,
    };

    pub const ReactionAddedEventData = struct {
        id: []const u8,
        channel_id: []const u8,
        guild_id: []const u8,
        user_id: []const u8,
        emoji_id: ?[]const u8,
        unicode_emoji: ?[]const u8,
    };

    pub const ReactionRemovedEventData = struct {
        id: []const u8,
        channel_id: []const u8,
        guild_id: []const u8,
        user_id: []const u8,
        emoji_id: ?[]const u8,
        unicode_emoji: ?[]const u8,
    };

    pub const HelloData = struct {
        heartbeat_interval: u64,
    };

    pub const WebhookCreatedEventData = struct {
        id: []const u8,
        guild_id: []const u8,
        channel_id: []const u8,
    };

    pub const WebhookUpdatedEventData = struct {
        id: []const u8,
        guild_id: []const u8,
        channel_id: []const u8,
    };

    pub const WebhookDeletedEventData = struct {
        id: []const u8,
        guild_id: []const u8,
        channel_id: []const u8,
    };

    pub inline fn Payload(data: anytype) type {
        return struct {
            op: Opcode,
            d: data,
            s: ?u32 = null,
            t: ?EventType = null,
        };
    }
};
