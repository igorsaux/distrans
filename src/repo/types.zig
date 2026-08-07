// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../root.zig");

// Conversion-source row types shared between the repository layer and the wire
// DTOs in `route/types.zig`. They live here (rather than in the concrete repo
// task that reads them) so a wire `fromRepo` can name them without importing a
// repo task.

/// One permission-overwrite row. Shared by the per-channel `GetOverwrites` and
/// the per-guild `GetAllOverwrites`. `channel_id` is only used by the guild
/// stream to group rows.
pub const Overwrite = struct {
    channel_id: root.types.ChannelId,
    target: root.types.Overwrites.Target,
    overwrites: root.types.Overwrites,
};

/// One webhook row. `name` / `avatar_hash` are owned by the allocator the read
/// was given and freed in `deinit`; `read` duplicates them out of a result row.
pub const Webhook = struct {
    id: root.types.WebhookId,
    guild_id: root.types.GuildId,
    channel_id: root.types.ChannelId,
    name: []const u8,
    avatar_hash: ?[]const u8,
    created_at: u64,
    deleted_at: ?u64,

    pub inline fn read(allocator: std.mem.Allocator, res: root.db.Result, row: usize) !Webhook {
        const name = try res.readSliceDupe(allocator, row, 3);
        errdefer allocator.free(name);

        const avatar_hash = try res.readSliceOptionalDupe(allocator, row, 4);
        errdefer if (avatar_hash) |value| {
            allocator.free(value);
        };

        const deleted_at = if (res.readIntOptional(u64, row, 6)) |deleted_at|
            @divFloor(deleted_at + 946684800000000, 1000)
        else
            null;

        return .{
            .id = res.readInt(root.types.WebhookId, row, 0),
            .guild_id = res.readInt(root.types.GuildId, row, 1),
            .channel_id = res.readInt(root.types.ChannelId, row, 2),
            .name = name,
            .avatar_hash = avatar_hash,
            .created_at = @divFloor(res.readInt(u64, row, 5) + 946684800000000, 1000),
            .deleted_at = deleted_at,
        };
    }

    pub inline fn deinit(this: Webhook, allocator: std.mem.Allocator) void {
        allocator.free(this.name);

        if (this.avatar_hash) |avatar_hash| {
            allocator.free(avatar_hash);
        }
    }
};

/// One message row read by `repo.channels.GetMessages` / `repo.search.Search`.
pub const Message = struct {
    id: root.types.MessageId,
    channel_id: root.types.ChannelId,
    author_id: ?root.types.UserId,
    webhook_id: ?root.types.WebhookId,
    content: []const u8,
    created_at: usize,
    reply_to_id: ?root.types.MessageId,
    edited_at: ?u64,
    embeds: ?[]const u8,
    /// Ordered JSON array of attachment objects; null when none.
    attachments: ?[]const u8,
    /// JSON array of mentioned user ids (decimal strings), in mention
    /// order; null when none.
    mention_user_ids: ?[]const u8,
    /// JSON array of mentioned role ids (decimal strings), in mention
    /// order; null when none.
    mention_role_ids: ?[]const u8,
    mention_everyone: bool,
    pinned: bool,
    /// JSON array of aggregated reactions (caller-specific `me`); null when
    /// the message has none.
    reactions: ?[]const u8,

    pub inline fn read(allocator: std.mem.Allocator, res: root.db.Result, row: usize) !Message {
        const content = try res.readSliceDupe(allocator, row, 2);
        errdefer allocator.free(content);

        const embeds = try res.readSliceOptionalDupe(allocator, row, 6);
        errdefer if (embeds) |value| allocator.free(value);

        const attachments = try res.readSliceOptionalDupe(allocator, row, 7);
        errdefer if (attachments) |value| allocator.free(value);

        const mention_user_ids = try res.readSliceOptionalDupe(allocator, row, 8);
        errdefer if (mention_user_ids) |value| allocator.free(value);

        const mention_role_ids = try res.readSliceOptionalDupe(allocator, row, 9);
        errdefer if (mention_role_ids) |value| allocator.free(value);

        const reactions = try res.readSliceOptionalDupe(allocator, row, 14);
        errdefer if (reactions) |value| allocator.free(value);

        const edited_at = if (res.readIntOptional(u64, row, 5)) |edited_at|
            @divFloor(edited_at + 946684800000000, 1000)
        else
            null;

        return .{
            .id = res.readInt(root.types.MessageId, row, 0),
            .channel_id = res.readInt(root.types.ChannelId, row, 13),
            .author_id = res.readIntOptional(root.types.UserId, row, 1),
            .webhook_id = res.readIntOptional(root.types.WebhookId, row, 12),
            .content = content,
            .created_at = @divFloor(res.readInt(u64, row, 3) + 946684800000000, 1000),
            .reply_to_id = res.readIntOptional(root.types.MessageId, row, 4),
            .edited_at = edited_at,
            .embeds = embeds,
            .attachments = attachments,
            .mention_user_ids = mention_user_ids,
            .mention_role_ids = mention_role_ids,
            .mention_everyone = res.readBool(row, 10),
            .pinned = res.readBool(row, 11),
            .reactions = reactions,
        };
    }
};
