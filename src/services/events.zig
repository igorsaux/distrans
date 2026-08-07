// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../root.zig");

pub const Event = struct {
    pub const Data = union(enum) {
        pub const MessageCreated = struct {
            id: root.types.MessageId,
            channel_id: root.types.ChannelId,
            guild_id: root.types.GuildId,
        };

        pub const MessageUpdated = struct {
            id: root.types.MessageId,
            channel_id: root.types.ChannelId,
            guild_id: root.types.GuildId,
        };

        pub const MessageDeleted = struct {
            id: root.types.MessageId,
            channel_id: root.types.ChannelId,
            guild_id: root.types.GuildId,
        };

        pub const MessagePinned = struct {
            id: root.types.MessageId,
            channel_id: root.types.ChannelId,
            guild_id: root.types.GuildId,
        };

        pub const MessageUnpinned = struct {
            id: root.types.MessageId,
            channel_id: root.types.ChannelId,
            guild_id: root.types.GuildId,
        };

        pub const OverwriteUpdated = struct {
            guild_id: root.types.GuildId,
            channel_id: root.types.ChannelId,
        };

        pub const UserCreated = struct {
            id: root.types.UserId,
        };

        pub const UserUpdated = struct {
            id: root.types.UserId,
        };

        pub const UserDeleted = struct {
            id: root.types.UserId,
        };

        pub const ChannelCreated = struct {
            id: root.types.ChannelId,
            guild_id: root.types.GuildId,
        };

        pub const ChannelUpdated = struct {
            id: root.types.ChannelId,
            guild_id: root.types.GuildId,
        };

        pub const ChannelDeleted = struct {
            id: root.types.ChannelId,
            guild_id: root.types.GuildId,
        };

        /// One or more channels of a guild changed their order. Carries only
        /// the guild id: the bus stores events by value in a fixed ring and
        /// the request arena does not outlive the request, so an id list does
        /// not fit; clients refetch the canonical collection.
        pub const ChannelReordered = struct {
            guild_id: root.types.GuildId,
        };

        pub const GuildCreated = struct {
            id: root.types.GuildId,
        };

        pub const GuildUpdated = struct {
            id: root.types.GuildId,
        };

        pub const GuildDeleted = struct {
            id: root.types.GuildId,
        };

        pub const RoleCreated = struct {
            id: root.types.RoleId,
            guild_id: root.types.GuildId,
        };

        pub const RoleUpdated = struct {
            id: root.types.RoleId,
            guild_id: root.types.GuildId,
        };

        pub const RoleDeleted = struct {
            id: root.types.RoleId,
            guild_id: root.types.GuildId,
        };

        pub const RoleGranted = struct {
            id: root.types.RoleId,
            guild_id: root.types.GuildId,
            user_id: root.types.UserId,
        };

        pub const RoleRevoked = struct {
            id: root.types.RoleId,
            guild_id: root.types.GuildId,
            user_id: root.types.UserId,
        };

        /// One or more roles of a guild changed their order. See
        /// `ChannelReordered` for why only the guild id is carried.
        pub const RoleReordered = struct {
            guild_id: root.types.GuildId,
        };

        pub const EmojiCreated = struct {
            id: root.types.EmojiId,
            guild_id: root.types.GuildId,
        };

        pub const EmojiUpdated = struct {
            id: root.types.EmojiId,
            guild_id: root.types.GuildId,
        };

        pub const EmojiDeleted = struct {
            id: root.types.EmojiId,
            guild_id: root.types.GuildId,
        };

        /// `emoji_kind` is 0 for a unicode reaction, 1 for a custom one (see
        /// migrations/5_reactions_and_emojis.sql). The unicode sequence is
        /// copied into an inline buffer because the bus stores events by value
        /// and the request arena does not outlive the request.
        pub const ReactionAdded = struct {
            message_id: root.types.MessageId,
            channel_id: root.types.ChannelId,
            guild_id: root.types.GuildId,
            user_id: root.types.UserId,
            emoji_kind: u16,
            emoji_id: ?root.types.EmojiId,
            unicode_emoji: [root.types.MAX_UNICODE_EMOJI_BYTES]u8,
            unicode_emoji_len: u8,

            pub inline fn unicodeSlice(this: *const ReactionAdded) ?[]const u8 {
                if (this.emoji_kind != 0) {
                    return null;
                }

                return this.unicode_emoji[0..this.unicode_emoji_len];
            }
        };

        pub const ReactionRemoved = struct {
            message_id: root.types.MessageId,
            channel_id: root.types.ChannelId,
            guild_id: root.types.GuildId,
            user_id: root.types.UserId,
            emoji_kind: u16,
            emoji_id: ?root.types.EmojiId,
            unicode_emoji: [root.types.MAX_UNICODE_EMOJI_BYTES]u8,
            unicode_emoji_len: u8,

            pub inline fn unicodeSlice(this: *const ReactionRemoved) ?[]const u8 {
                if (this.emoji_kind != 0) {
                    return null;
                }

                return this.unicode_emoji[0..this.unicode_emoji_len];
            }
        };

        pub const WebhookCreated = struct {
            id: root.types.WebhookId,
            guild_id: root.types.GuildId,
            channel_id: root.types.ChannelId,
        };

        pub const WebhookUpdated = struct {
            id: root.types.WebhookId,
            guild_id: root.types.GuildId,
            channel_id: root.types.ChannelId,
        };

        pub const WebhookDeleted = struct {
            id: root.types.WebhookId,
            guild_id: root.types.GuildId,
            channel_id: root.types.ChannelId,
        };

        none: void,
        message_created: MessageCreated,
        message_updated: MessageUpdated,
        message_deleted: MessageDeleted,
        message_pinned: MessagePinned,
        message_unpinned: MessageUnpinned,
        overwrite_updated: OverwriteUpdated,
        user_created: UserCreated,
        user_updated: UserUpdated,
        user_deleted: UserDeleted,
        channel_created: ChannelCreated,
        channel_updated: ChannelUpdated,
        channel_deleted: ChannelDeleted,
        channel_reordered: ChannelReordered,
        guild_created: GuildCreated,
        guild_updated: GuildUpdated,
        guild_deleted: GuildDeleted,
        role_created: RoleCreated,
        role_updated: RoleUpdated,
        role_deleted: RoleDeleted,
        role_granted: RoleGranted,
        role_revoked: RoleRevoked,
        role_reordered: RoleReordered,
        emoji_created: EmojiCreated,
        emoji_updated: EmojiUpdated,
        emoji_deleted: EmojiDeleted,
        reaction_added: ReactionAdded,
        reaction_removed: ReactionRemoved,
        webhook_created: WebhookCreated,
        webhook_updated: WebhookUpdated,
        webhook_deleted: WebhookDeleted,
    };

    id: usize = 0,
    data: Data = .none,
};

pub const Bus = struct {
    events: [128]Event,
    cursor: usize = 0,
    next_id: usize = 0,

    pub inline fn init() Bus {
        var events: [128]Event = undefined;
        @memset(&events, Event{});

        return .{
            .events = events,
        };
    }

    pub inline fn raise(this: *Bus, data: Event.Data) void {
        const event = &this.events[this.cursor];

        event.id +%= 1;
        event.data = data;

        this.cursor = (this.cursor + 1) % this.events.len;
    }

    pub inline fn getNext(this: *const Bus, cursor: *usize) ?Event {
        while (cursor.* != this.cursor) {
            const ev = this.events[cursor.*];
            cursor.* = (cursor.* + 1) % this.events.len;

            if (ev.data == .none) {
                continue;
            }

            return ev;
        }

        return null;
    }
};
