// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../root.zig");
const frames = @import("frames.zig");

const SCOPE = std.log.scoped(.@"gateway/events");

/// Builds the dispatch frame body for a bus event, serialized into `arena`.
/// Returns null for empty events (`.none`).
pub inline fn buildDispatchBody(
    arena: std.mem.Allocator,
    event: root.services.events.Event,
    seq: u32,
) ![]const u8 {
    std.debug.assert(event.data != .none);

    switch (event.data) {
        .none => unreachable,
        .message_created => |ev| {
            const ResponsePayload = frames.Frame.Payload(frames.Frame.MessageCreatedEventData);

            const payload: ResponsePayload = .{
                .op = .dispatch,
                .d = .{
                    .id = try std.fmt.allocPrint(arena, "{}", .{ev.id}),
                    .channel_id = try std.fmt.allocPrint(arena, "{}", .{ev.channel_id}),
                    .guild_id = try std.fmt.allocPrint(arena, "{}", .{ev.guild_id}),
                },
                .s = seq,
                .t = .message_created,
            };

            return try serialize(arena, payload);
        },
        .message_updated => |ev| {
            const ResponsePayload = frames.Frame.Payload(frames.Frame.MessageUpdatedEventData);

            const payload: ResponsePayload = .{
                .op = .dispatch,
                .d = .{
                    .id = try std.fmt.allocPrint(arena, "{}", .{ev.id}),
                    .channel_id = try std.fmt.allocPrint(arena, "{}", .{ev.channel_id}),
                    .guild_id = try std.fmt.allocPrint(arena, "{}", .{ev.guild_id}),
                },
                .s = seq,
                .t = .message_updated,
            };

            return try serialize(arena, payload);
        },
        .message_deleted => |ev| {
            const ResponsePayload = frames.Frame.Payload(frames.Frame.MessageDeletedEventData);

            const payload: ResponsePayload = .{
                .op = .dispatch,
                .d = .{
                    .id = try std.fmt.allocPrint(arena, "{}", .{ev.id}),
                    .channel_id = try std.fmt.allocPrint(arena, "{}", .{ev.channel_id}),
                    .guild_id = try std.fmt.allocPrint(arena, "{}", .{ev.guild_id}),
                },
                .s = seq,
                .t = .message_deleted,
            };

            return try serialize(arena, payload);
        },
        .message_pinned => |ev| {
            const ResponsePayload = frames.Frame.Payload(frames.Frame.MessagePinnedEventData);

            const payload: ResponsePayload = .{
                .op = .dispatch,
                .d = .{
                    .id = try std.fmt.allocPrint(arena, "{}", .{ev.id}),
                    .channel_id = try std.fmt.allocPrint(arena, "{}", .{ev.channel_id}),
                    .guild_id = try std.fmt.allocPrint(arena, "{}", .{ev.guild_id}),
                },
                .s = seq,
                .t = .message_pinned,
            };

            return try serialize(arena, payload);
        },
        .message_unpinned => |ev| {
            const ResponsePayload = frames.Frame.Payload(frames.Frame.MessageUnpinnedEventData);

            const payload: ResponsePayload = .{
                .op = .dispatch,
                .d = .{
                    .id = try std.fmt.allocPrint(arena, "{}", .{ev.id}),
                    .channel_id = try std.fmt.allocPrint(arena, "{}", .{ev.channel_id}),
                    .guild_id = try std.fmt.allocPrint(arena, "{}", .{ev.guild_id}),
                },
                .s = seq,
                .t = .message_unpinned,
            };

            return try serialize(arena, payload);
        },
        .overwrite_updated => |ev| {
            const ResponsePayload = frames.Frame.Payload(frames.Frame.OverwriteUpdatedEventData);

            const payload: ResponsePayload = .{
                .op = .dispatch,
                .d = .{
                    .guild_id = try std.fmt.allocPrint(arena, "{}", .{ev.guild_id}),
                    .channel_id = try std.fmt.allocPrint(arena, "{}", .{ev.channel_id}),
                },
                .s = seq,
                .t = .overwrite_updated,
            };

            return try serialize(arena, payload);
        },
        .user_created => |ev| {
            const ResponsePayload = frames.Frame.Payload(frames.Frame.UserCreatedEventData);

            const payload: ResponsePayload = .{
                .op = .dispatch,
                .d = .{
                    .id = try std.fmt.allocPrint(arena, "{}", .{ev.id}),
                },
                .s = seq,
                .t = .user_created,
            };

            return try serialize(arena, payload);
        },
        .user_updated => |ev| {
            const ResponsePayload = frames.Frame.Payload(frames.Frame.UserUpdatedEventData);

            const payload: ResponsePayload = .{
                .op = .dispatch,
                .d = .{
                    .id = try std.fmt.allocPrint(arena, "{}", .{ev.id}),
                },
                .s = seq,
                .t = .user_updated,
            };

            return try serialize(arena, payload);
        },
        .user_deleted => |ev| {
            const ResponsePayload = frames.Frame.Payload(frames.Frame.UserDeletedEventData);

            const payload: ResponsePayload = .{
                .op = .dispatch,
                .d = .{
                    .id = try std.fmt.allocPrint(arena, "{}", .{ev.id}),
                },
                .s = seq,
                .t = .user_deleted,
            };

            return try serialize(arena, payload);
        },
        .guild_created => |ev| {
            const ResponsePayload = frames.Frame.Payload(frames.Frame.GuildCreatedEventData);

            const payload: ResponsePayload = .{
                .op = .dispatch,
                .d = .{
                    .id = try std.fmt.allocPrint(arena, "{}", .{ev.id}),
                },
                .s = seq,
                .t = .guild_created,
            };

            return try serialize(arena, payload);
        },
        .guild_updated => |ev| {
            const ResponsePayload = frames.Frame.Payload(frames.Frame.GuildUpdatedEventData);

            const payload: ResponsePayload = .{
                .op = .dispatch,
                .d = .{
                    .id = try std.fmt.allocPrint(arena, "{}", .{ev.id}),
                },
                .s = seq,
                .t = .guild_updated,
            };

            return try serialize(arena, payload);
        },
        .guild_deleted => |ev| {
            const ResponsePayload = frames.Frame.Payload(frames.Frame.GuildDeletedEventData);

            const payload: ResponsePayload = .{
                .op = .dispatch,
                .d = .{
                    .id = try std.fmt.allocPrint(arena, "{}", .{ev.id}),
                },
                .s = seq,
                .t = .guild_deleted,
            };

            return try serialize(arena, payload);
        },
        .channel_created => |ev| {
            const ResponsePayload = frames.Frame.Payload(frames.Frame.ChannelCreatedEventData);

            const payload: ResponsePayload = .{
                .op = .dispatch,
                .d = .{
                    .id = try std.fmt.allocPrint(arena, "{}", .{ev.id}),
                    .guild_id = try std.fmt.allocPrint(arena, "{}", .{ev.guild_id}),
                },
                .s = seq,
                .t = .channel_created,
            };

            return try serialize(arena, payload);
        },
        .channel_updated => |ev| {
            const ResponsePayload = frames.Frame.Payload(frames.Frame.ChannelUpdatedEventData);

            const payload: ResponsePayload = .{
                .op = .dispatch,
                .d = .{
                    .id = try std.fmt.allocPrint(arena, "{}", .{ev.id}),
                    .guild_id = try std.fmt.allocPrint(arena, "{}", .{ev.guild_id}),
                },
                .s = seq,
                .t = .channel_updated,
            };

            return try serialize(arena, payload);
        },
        .channel_deleted => |ev| {
            const ResponsePayload = frames.Frame.Payload(frames.Frame.ChannelDeletedEventData);

            const payload: ResponsePayload = .{
                .op = .dispatch,
                .d = .{
                    .id = try std.fmt.allocPrint(arena, "{}", .{ev.id}),
                    .guild_id = try std.fmt.allocPrint(arena, "{}", .{ev.guild_id}),
                },
                .s = seq,
                .t = .channel_deleted,
            };

            return try serialize(arena, payload);
        },
        .channel_reordered => |ev| {
            const ResponsePayload = frames.Frame.Payload(frames.Frame.ChannelsReorderedEventData);

            const payload: ResponsePayload = .{
                .op = .dispatch,
                .d = .{
                    .guild_id = try std.fmt.allocPrint(arena, "{}", .{ev.guild_id}),
                },
                .s = seq,
                .t = .channels_reordered,
            };

            return try serialize(arena, payload);
        },
        .role_created => |ev| {
            const ResponsePayload = frames.Frame.Payload(frames.Frame.RoleCreatedEventData);

            const payload: ResponsePayload = .{
                .op = .dispatch,
                .d = .{
                    .id = try std.fmt.allocPrint(arena, "{}", .{ev.id}),
                    .guild_id = try std.fmt.allocPrint(arena, "{}", .{ev.guild_id}),
                },
                .s = seq,
                .t = .role_created,
            };

            return try serialize(arena, payload);
        },
        .role_updated => |ev| {
            const ResponsePayload = frames.Frame.Payload(frames.Frame.RoleUpdatedEventData);

            const payload: ResponsePayload = .{
                .op = .dispatch,
                .d = .{
                    .id = try std.fmt.allocPrint(arena, "{}", .{ev.id}),
                    .guild_id = try std.fmt.allocPrint(arena, "{}", .{ev.guild_id}),
                },
                .s = seq,
                .t = .role_updated,
            };

            return try serialize(arena, payload);
        },
        .role_deleted => |ev| {
            const ResponsePayload = frames.Frame.Payload(frames.Frame.RoleDeletedEventData);

            const payload: ResponsePayload = .{
                .op = .dispatch,
                .d = .{
                    .id = try std.fmt.allocPrint(arena, "{}", .{ev.id}),
                    .guild_id = try std.fmt.allocPrint(arena, "{}", .{ev.guild_id}),
                },
                .s = seq,
                .t = .role_deleted,
            };

            return try serialize(arena, payload);
        },
        .role_granted => |ev| {
            const ResponsePayload = frames.Frame.Payload(frames.Frame.RoleGrantedEventData);

            const payload: ResponsePayload = .{
                .op = .dispatch,
                .d = .{
                    .id = try std.fmt.allocPrint(arena, "{}", .{ev.id}),
                    .guild_id = try std.fmt.allocPrint(arena, "{}", .{ev.guild_id}),
                    .user_id = try std.fmt.allocPrint(arena, "{}", .{ev.user_id}),
                },
                .s = seq,
                .t = .role_granted,
            };

            return try serialize(arena, payload);
        },
        .role_revoked => |ev| {
            const ResponsePayload = frames.Frame.Payload(frames.Frame.RoleRevokedEventData);

            const payload: ResponsePayload = .{
                .op = .dispatch,
                .d = .{
                    .id = try std.fmt.allocPrint(arena, "{}", .{ev.id}),
                    .guild_id = try std.fmt.allocPrint(arena, "{}", .{ev.guild_id}),
                    .user_id = try std.fmt.allocPrint(arena, "{}", .{ev.user_id}),
                },
                .s = seq,
                .t = .role_revoked,
            };

            return try serialize(arena, payload);
        },
        .role_reordered => |ev| {
            const ResponsePayload = frames.Frame.Payload(frames.Frame.RolesReorderedEventData);

            const payload: ResponsePayload = .{
                .op = .dispatch,
                .d = .{
                    .guild_id = try std.fmt.allocPrint(arena, "{}", .{ev.guild_id}),
                },
                .s = seq,
                .t = .roles_reordered,
            };

            return try serialize(arena, payload);
        },
        .emoji_created => |ev| {
            const ResponsePayload = frames.Frame.Payload(frames.Frame.EmojiCreatedEventData);

            const payload: ResponsePayload = .{
                .op = .dispatch,
                .d = .{
                    .id = try std.fmt.allocPrint(arena, "{}", .{ev.id}),
                    .guild_id = try std.fmt.allocPrint(arena, "{}", .{ev.guild_id}),
                },
                .s = seq,
                .t = .emoji_created,
            };

            return try serialize(arena, payload);
        },
        .emoji_updated => |ev| {
            const ResponsePayload = frames.Frame.Payload(frames.Frame.EmojiUpdatedEventData);

            const payload: ResponsePayload = .{
                .op = .dispatch,
                .d = .{
                    .id = try std.fmt.allocPrint(arena, "{}", .{ev.id}),
                    .guild_id = try std.fmt.allocPrint(arena, "{}", .{ev.guild_id}),
                },
                .s = seq,
                .t = .emoji_updated,
            };

            return try serialize(arena, payload);
        },
        .emoji_deleted => |ev| {
            const ResponsePayload = frames.Frame.Payload(frames.Frame.EmojiDeletedEventData);

            const payload: ResponsePayload = .{
                .op = .dispatch,
                .d = .{
                    .id = try std.fmt.allocPrint(arena, "{}", .{ev.id}),
                    .guild_id = try std.fmt.allocPrint(arena, "{}", .{ev.guild_id}),
                },
                .s = seq,
                .t = .emoji_deleted,
            };

            return try serialize(arena, payload);
        },
        .reaction_added => |ev| {
            const ResponsePayload = frames.Frame.Payload(frames.Frame.ReactionAddedEventData);

            const payload: ResponsePayload = .{
                .op = .dispatch,
                .d = .{
                    .id = try std.fmt.allocPrint(arena, "{}", .{ev.message_id}),
                    .channel_id = try std.fmt.allocPrint(arena, "{}", .{ev.channel_id}),
                    .guild_id = try std.fmt.allocPrint(arena, "{}", .{ev.guild_id}),
                    .user_id = try std.fmt.allocPrint(arena, "{}", .{ev.user_id}),
                    .emoji_id = if (ev.emoji_id) |emoji_id|
                        try std.fmt.allocPrint(arena, "{}", .{emoji_id})
                    else
                        null,
                    .unicode_emoji = ev.unicodeSlice(),
                },
                .s = seq,
                .t = .reaction_added,
            };

            return try serialize(arena, payload);
        },
        .reaction_removed => |ev| {
            const ResponsePayload = frames.Frame.Payload(frames.Frame.ReactionRemovedEventData);

            const payload: ResponsePayload = .{
                .op = .dispatch,
                .d = .{
                    .id = try std.fmt.allocPrint(arena, "{}", .{ev.message_id}),
                    .channel_id = try std.fmt.allocPrint(arena, "{}", .{ev.channel_id}),
                    .guild_id = try std.fmt.allocPrint(arena, "{}", .{ev.guild_id}),
                    .user_id = try std.fmt.allocPrint(arena, "{}", .{ev.user_id}),
                    .emoji_id = if (ev.emoji_id) |emoji_id|
                        try std.fmt.allocPrint(arena, "{}", .{emoji_id})
                    else
                        null,
                    .unicode_emoji = ev.unicodeSlice(),
                },
                .s = seq,
                .t = .reaction_removed,
            };

            return try serialize(arena, payload);
        },
        .webhook_created => |ev| {
            const ResponsePayload = frames.Frame.Payload(frames.Frame.WebhookCreatedEventData);

            const payload: ResponsePayload = .{
                .op = .dispatch,
                .d = .{
                    .id = try std.fmt.allocPrint(arena, "{}", .{ev.id}),
                    .guild_id = try std.fmt.allocPrint(arena, "{}", .{ev.guild_id}),
                    .channel_id = try std.fmt.allocPrint(arena, "{}", .{ev.channel_id}),
                },
                .s = seq,
                .t = .webhook_created,
            };

            return try serialize(arena, payload);
        },
        .webhook_updated => |ev| {
            const ResponsePayload = frames.Frame.Payload(frames.Frame.WebhookUpdatedEventData);

            const payload: ResponsePayload = .{
                .op = .dispatch,
                .d = .{
                    .id = try std.fmt.allocPrint(arena, "{}", .{ev.id}),
                    .guild_id = try std.fmt.allocPrint(arena, "{}", .{ev.guild_id}),
                    .channel_id = try std.fmt.allocPrint(arena, "{}", .{ev.channel_id}),
                },
                .s = seq,
                .t = .webhook_updated,
            };

            return try serialize(arena, payload);
        },
        .webhook_deleted => |ev| {
            const ResponsePayload = frames.Frame.Payload(frames.Frame.WebhookDeletedEventData);

            const payload: ResponsePayload = .{
                .op = .dispatch,
                .d = .{
                    .id = try std.fmt.allocPrint(arena, "{}", .{ev.id}),
                    .guild_id = try std.fmt.allocPrint(arena, "{}", .{ev.guild_id}),
                    .channel_id = try std.fmt.allocPrint(arena, "{}", .{ev.channel_id}),
                },
                .s = seq,
                .t = .webhook_deleted,
            };

            return try serialize(arena, payload);
        },
    }
}

inline fn serialize(arena: std.mem.Allocator, payload: anytype) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(arena);

    std.json.fmt(payload, .{}).format(&writer.writer) catch |err| {
        SCOPE.err("failed to serialize the dispatch payload: {t}", .{err});

        return err;
    };

    return writer.written();
}
