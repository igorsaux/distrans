// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.@"/api/limits");

const Limits = struct {
    guilds: struct {
        max_name_codepoints: usize,
        max_emojis: usize,
    },
    channels: struct {
        max_name_codepoints: usize,
        max_topic_codepoints: usize,
    },
    messages: struct {
        max_messages_limit: usize,
        max_codepoints_per_message: usize,
        max_reactions: usize,
        max_reactions_users_limit: usize,
        max_embeds: usize,
        max_attachments: usize,
        max_mention_users: usize,
        max_mention_roles: usize,
        max_allowed_mention_users: usize,
        max_allowed_mention_roles: usize,
    },
    search: struct {
        min_content_codepoints: usize,
        max_content_codepoints: usize,
        max_filter_ids: usize,
    },
    sync: struct {
        max_lookback_s: usize,
    },
    audit_log: struct {
        max_entries_limit: usize,
    },
    embeds: struct {
        max_title_codepoints: usize,
        max_description_codepoints: usize,
        max_fields: usize,
        max_footer_codepoints: usize,
        max_author_name_codepoints: usize,
        max_field_name_codepoints: usize,
        max_field_value_codepoints: usize,
        max_url_codepoints: usize,
        max_total_codepoints: usize,
    },
    roles: struct {
        max_name_codepoints: usize,
    },
    emojis: struct {
        min_name_codepoints: usize,
        max_name_codepoints: usize,
    },
    users: struct {
        min_username_codepoints: usize,
        max_username_codepoints: usize,
        min_display_name_codepoints: usize,
        max_display_name_codepoints: usize,
        max_userdata_bytes: usize,
    },
    auth: struct {
        password: struct {
            min_codepoints: usize,
            max_codepoints: usize,
            max_bytes: usize,
        },
    },
    media: struct {
        avatar: struct {
            max_dimensions: u16,
            max_bytes: usize,
            max_animation_frames: usize,
            max_animation_duration_ms: usize,
        },
        emoji: struct {
            max_dimensions: u16,
            max_bytes: usize,
            max_animation_frames: usize,
            max_animation_duration_ms: usize,
        },
    },
    files: struct {
        max_name_codepoints: usize,
        max_size: usize,
        whitelist: ?[]const []const u8,
        public_base_urls: []const []const u8,
    },
    push: struct {
        enabled: bool,
        vapid_public_key: []const u8,
        max_subscriptions_per_user: usize,
    },
    webhooks: struct {
        max_webhooks_per_channel: usize,
        max_name_codepoints: usize,
    },
};

var body: ?[]const u8 = null;

/// GET /api/limits
pub inline fn getHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
) !root.http.Task {
    _ = allocator;
    _ = request;

    if (body == null) {
        const item: Limits = .{
            .guilds = .{
                .max_name_codepoints = root.options.api.guilds.max_name_codepoints,
                .max_emojis = root.options.api.guilds.max_emojis,
            },
            .channels = .{
                .max_name_codepoints = root.options.api.channels.max_name_codepoints,
                .max_topic_codepoints = root.options.api.channels.max_topic_codepoints,
            },
            .messages = .{
                .max_messages_limit = root.options.api.messages.max_messages_limit,
                .max_codepoints_per_message = root.options.api.messages.max_codepoints,
                .max_reactions = root.options.api.messages.max_reactions,
                .max_reactions_users_limit = root.options.api.messages.max_reactions_users_limit,
                .max_embeds = root.options.api.messages.max_embeds,
                .max_attachments = root.options.api.messages.max_attachments,
                .max_mention_users = root.options.api.messages.max_mention_users,
                .max_mention_roles = root.options.api.messages.max_mention_roles,
                .max_allowed_mention_users = root.options.api.messages.max_allowed_mention_users,
                .max_allowed_mention_roles = root.options.api.messages.max_allowed_mention_roles,
            },
            .search = .{
                .min_content_codepoints = root.options.api.search.min_content_codepoints,
                .max_content_codepoints = root.options.api.search.max_content_codepoints,
                .max_filter_ids = root.options.api.search.max_filter_ids,
            },
            .sync = .{
                .max_lookback_s = root.options.api.sync.max_lookback_s,
            },
            .audit_log = .{
                .max_entries_limit = root.options.api.audit_log.max_entries_limit,
            },
            .embeds = .{
                .max_title_codepoints = root.options.api.embeds.max_title_codepoints,
                .max_description_codepoints = root.options.api.embeds.max_description_codepoints,
                .max_fields = root.options.api.embeds.max_fields,
                .max_footer_codepoints = root.options.api.embeds.max_footer_codepoints,
                .max_author_name_codepoints = root.options.api.embeds.max_author_name_codepoints,
                .max_field_name_codepoints = root.options.api.embeds.max_field_name_codepoints,
                .max_field_value_codepoints = root.options.api.embeds.max_field_value_codepoints,
                .max_url_codepoints = root.options.api.embeds.max_url_codepoints,
                .max_total_codepoints = root.options.api.embeds.max_total_codepoints,
            },
            .roles = .{
                .max_name_codepoints = root.options.api.roles.max_name_codepoints,
            },
            .emojis = .{
                .min_name_codepoints = root.options.api.emojis.min_name_codepoints,
                .max_name_codepoints = root.options.api.emojis.max_name_codepoints,
            },
            .users = .{
                .min_username_codepoints = root.options.api.users.min_username_codepoints,
                .max_username_codepoints = root.options.api.users.max_username_codepoints,
                .min_display_name_codepoints = root.options.api.users.min_display_name_codepoints,
                .max_display_name_codepoints = root.options.api.users.max_display_name_codepoints,
                .max_userdata_bytes = root.options.api.users.max_userdata_bytes,
            },
            .auth = .{
                .password = .{
                    .min_codepoints = root.options.auth.password.min_password_codepoints,
                    .max_codepoints = root.options.auth.password.max_password_codepoints,
                    .max_bytes = root.options.auth.password.max_password_len,
                },
            },
            .media = .{
                .avatar = .{
                    .max_dimensions = root.options.media.avatar.max_dimensions,
                    .max_bytes = root.options.media.avatar.max_input_bytes,
                    .max_animation_frames = root.options.media.avatar.max_animation_frames,
                    .max_animation_duration_ms = root.options.media.avatar.max_animation_duration_ms,
                },
                .emoji = .{
                    .max_dimensions = root.options.media.emoji.max_dimensions,
                    .max_bytes = root.options.media.emoji.max_input_bytes,
                    .max_animation_frames = root.options.media.emoji.max_animation_frames,
                    .max_animation_duration_ms = root.options.media.emoji.max_animation_duration_ms,
                },
            },
            .files = .{
                .max_name_codepoints = root.options.api.files.max_name_codepoints,
                .max_size = root.options.files.max_size,
                .whitelist = root.options.files.whitelist,
                .public_base_urls = switch (root.options.files.storage) {
                    .s3 => |s3| &.{s3.public_base_url},
                    else => &.{},
                },
            },
            .push = .{
                .enabled = root.options.push.enabled,
                .vapid_public_key = root.options.push.vapid.public_key,
                .max_subscriptions_per_user = root.options.api.push.max_subscriptions_per_user,
            },
            .webhooks = .{
                .max_webhooks_per_channel = root.options.api.webhooks.max_webhooks_per_channel,
                .max_name_codepoints = root.options.api.webhooks.max_name_codepoints,
            },
        };

        var writer: std.Io.Writer.Allocating = .init(root.arena.allocator());

        std.json.fmt(item, .{}).format(&writer.writer) catch |err| {
            SCOPE.err("GET failed to serialize the response: {t}", .{err});

            return err;
        };

        body = writer.written();
    }

    return try root.route.generic.CodeBodyResponse.task(
        response,
        .ok,
        "application/json",
        body.?,
        null,
    );
}
