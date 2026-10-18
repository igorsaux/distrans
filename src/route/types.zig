// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.route_types);

/// Wire shape of one channel permission overwrite, embedded in every `Channel`
/// object and used by the settings editor. `target_id`, `allow` and `deny` are
/// decimal strings (the permission masks are 128-bit and must not pass through
/// a JSON number); `type` is the target kind. Built by
/// `route.types.Overwrite.fromRepo`.
pub const Overwrite = struct {
    target_id: []const u8,
    type: root.types.Overwrites.Type,
    allow: []const u8,
    deny: []const u8,

    /// Builds the wire object from a repo row. `target_id`, `allow` and `deny`
    /// are allocated with `allocator`.
    pub inline fn fromRepo(allocator: std.mem.Allocator, item: root.repo.types.Overwrite) !Overwrite {
        return .{
            .target_id = switch (item.target) {
                .role => |role_id| try std.fmt.allocPrint(allocator, "{}", .{role_id}),
                .member => |user_id| try std.fmt.allocPrint(allocator, "{}", .{user_id}),
            },
            .type = item.target.ty(),
            .allow = try std.fmt.allocPrint(allocator, "{}", .{@as(u128, @bitCast(item.overwrites.allow))}),
            .deny = try std.fmt.allocPrint(allocator, "{}", .{@as(u128, @bitCast(item.overwrites.deny))}),
        };
    }
};

/// The webhook wire object returned by the channel webhook list and the public
/// attribution read (`GET /api/webhooks/{webhook_id}`). It never carries the
/// execute token. The decimal-string ids are allocated with the `allocator`
/// given to `route.types.Webhook.fromRepo`, which also borrows `name`/
/// `avatar_hash` from the row.
pub const Webhook = struct {
    id: []const u8,
    guild_id: []const u8,
    channel_id: []const u8,
    name: []const u8,
    avatar_hash: ?[]const u8,
    created_at: u64,
    deleted_at: ?u64,

    /// Builds the wire object. The decimal-string ids are allocated with
    /// `allocator`; `name` / `avatar_hash` stay borrowed from the repo row and
    /// must outlive the response serialization.
    pub inline fn fromRepo(allocator: std.mem.Allocator, item: root.repo.types.Webhook) !Webhook {
        return .{
            .id = try std.fmt.allocPrint(allocator, "{}", .{item.id}),
            .guild_id = try std.fmt.allocPrint(allocator, "{}", .{item.guild_id}),
            .channel_id = try std.fmt.allocPrint(allocator, "{}", .{item.channel_id}),
            .name = item.name,
            .avatar_hash = item.avatar_hash,
            .created_at = item.created_at,
            .deleted_at = item.deleted_at,
        };
    }
};

/// Aggregated reaction of a message: exactly one of `emoji_id` /
/// `unicode_emoji` is set, `count` is the number of non-deleted users who
/// reacted with that emoji and `me` whether the requesting user did.
pub const Reaction = struct {
    emoji_id: ?[]const u8,
    unicode_emoji: ?[]const u8,
    count: u64,
    me: bool,
};

/// Wire shape of a message, shared by every endpoint that returns message
/// content (`GET /channels/{channel_id}/messages`,
/// `GET /guilds/{guild_id}/messages/search`). Mirrors the fields of
/// `repo.types.Message`, stringifying ids and parsing the JSON columns.
/// `channel_id` is always present so a client can locate the message without
/// knowing which endpoint produced it.
pub const Message = struct {
    id: []const u8,
    channel_id: []const u8,
    author_id: ?[]const u8,
    webhook_id: ?[]const u8,
    content: []const u8,
    created_at: u64,
    reply_to_id: ?[]const u8,
    edited_at: ?u64,
    embeds: ?[]const root.types.Embed,
    attachments: []const Attachment,
    mention_everyone: bool,
    mentions: []const []const u8,
    mention_roles: []const []const u8,
    pinned: bool,
    /// Inline reaction summary of the message; null when it has none. The
    /// aggregate is caller-specific (`me`), so the same message renders
    /// differently for different users.
    reactions: ?[]const Reaction,

    /// Renders one query row into the wire shape. All returned slices live in
    /// `allocator`.
    pub inline fn fromRepo(
        allocator: std.mem.Allocator,
        item: root.repo.types.Message,
    ) !Message {
        return .{
            .id = std.fmt.allocPrint(allocator, "{}", .{item.id}) catch |err| {
                SCOPE.err("failed to format 'id' to string: {t}", .{err});

                return err;
            },
            .channel_id = std.fmt.allocPrint(allocator, "{}", .{item.channel_id}) catch |err| {
                SCOPE.err("failed to format 'channel_id' to string: {t}", .{err});

                return err;
            },
            .author_id = if (item.author_id) |author_id|
                std.fmt.allocPrint(allocator, "{}", .{author_id}) catch |err| {
                    SCOPE.err("failed to format 'author_id' to string: {t}", .{err});

                    return err;
                }
            else
                null,
            .webhook_id = if (item.webhook_id) |webhook_id|
                std.fmt.allocPrint(allocator, "{}", .{webhook_id}) catch |err| {
                    SCOPE.err("failed to format 'webhook_id' to string: {t}", .{err});

                    return err;
                }
            else
                null,
            .content = allocator.dupe(u8, item.content) catch |err| {
                SCOPE.err("failed to dupe 'content': {t}", .{err});

                return err;
            },
            .created_at = item.created_at,
            .reply_to_id = if (item.reply_to_id) |reply_to_id|
                std.fmt.allocPrint(allocator, "{}", .{reply_to_id}) catch |err| {
                    SCOPE.err("failed to format 'reply_to_id' to string: {t}", .{err});

                    return err;
                }
            else
                null,
            .edited_at = item.edited_at,
            .embeds = blk: {
                if (item.embeds) |embeds| {
                    const embeds_parsed = std.json.parseFromSliceLeaky([]const root.types.Embed, allocator, embeds, .{ .allocate = .alloc_always }) catch |err| {
                        SCOPE.err("bad embeds in DB: {t}", .{err});

                        return err;
                    };

                    break :blk embeds_parsed;
                } else {
                    break :blk null;
                }
            },
            .attachments = parseAttachments(allocator, item.attachments) catch |err| {
                SCOPE.err("failed to parse 'attachments': {t}", .{err});

                return err;
            },
            .mention_everyone = item.mention_everyone,
            .mentions = parseMentionIds(allocator, item.mention_user_ids) catch |err| {
                SCOPE.err("failed to parse 'mentions': {t}", .{err});

                return err;
            },
            .mention_roles = parseMentionIds(allocator, item.mention_role_ids) catch |err| {
                SCOPE.err("failed to parse 'mention_roles': {t}", .{err});

                return err;
            },
            .pinned = item.pinned,
            .reactions = blk: {
                if (item.reactions) |reactions| {
                    const parsed = std.json.parseFromSliceLeaky([]const Reaction, allocator, reactions, .{ .allocate = .alloc_always }) catch |err| {
                        SCOPE.err("bad reactions in DB: {t}", .{err});

                        return err;
                    };

                    break :blk parsed;
                } else {
                    break :blk null;
                }
            },
        };
    }
};

/// One file attachment as exposed inline on message reads.
pub const Attachment = struct {
    id: []const u8,
    name: []const u8,
    size: u64,
    content_type: []const u8,
    hash: []const u8,
    public_url: ?[]const u8 = null,
};

/// Parses the JSON attachment array produced by the message queries (see
/// `repo.channels.GetMessages` / `repo.messages.Get`) and resolves each
/// `public_url` from the configured S3 public base URL. An empty / null input
/// yields an empty slice.
pub inline fn parseAttachments(
    allocator: std.mem.Allocator,
    json: ?[]const u8,
) ![]const Attachment {
    const text = json orelse return &.{};

    if (text.len == 0) {
        return &.{};
    }

    const attachments = std.json.parseFromSliceLeaky([]Attachment, allocator, text, .{ .allocate = .alloc_always }) catch |err| {
        SCOPE.err("failed to parse attachments from DB: {t}", .{err});

        return err;
    };

    const public_base_url: ?[]const u8 = switch (root.options.files.storage) {
        .s3 => |s3| s3.public_base_url,
        else => null,
    };

    for (attachments) |*attachment| {
        if (public_base_url == null) {
            attachment.public_url = null;

            continue;
        }

        attachment.public_url = std.fmt.allocPrint(allocator, "{s}/files/{s}", .{
            public_base_url.?,
            attachment.hash,
        }) catch |err| {
            SCOPE.err("failed to build an attachment public URL: {t}", .{err});

            return err;
        };
    }

    return attachments;
}

/// Parses the JSON array of decimal-string mention ids emitted by the message
/// queries (`repo.channels.GetMessages` / `repo.messages.Get`) into a slice of
/// strings. A null/empty input yields an empty slice.
inline fn parseMentionIds(
    allocator: std.mem.Allocator,
    json: ?[]const u8,
) ![]const []const u8 {
    const text = json orelse return &.{};

    if (text.len == 0) {
        return &.{};
    }

    return std.json.parseFromSliceLeaky([]const []const u8, allocator, text, .{ .allocate = .alloc_always }) catch |err| {
        SCOPE.err("failed to parse mention ids from DB: {t}", .{err});

        return err;
    };
}
