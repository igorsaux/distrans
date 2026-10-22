// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.messages);

/// R1 - content type must be application/json (415) and body non-empty (400)
///
/// Shared guard for every endpoint that consumes a message JSON body
/// (`POST /api/channels/{channel_id}/messages` and webhook execute). Returns a
/// response task when the request is rejected, `null` otherwise.
pub inline fn ensureJsonBody(
    request: *const root.http.Request,
    response: *root.http.Response,
) !?root.http.Task {
    // R1
    if (request.getContentLength() == 0) {
        return try root.route.generic.badRequestTask(response);
    }

    // R1
    if (!root.utils.startsWithMaybe(u8, request.content_type, "application/json")) {
        return try root.route.generic.unsupportedMediaTypeTask(response);
    }

    return null;
}

pub const ContentError = error{
    InvalidUtf8,
    Empty,
    TooLong,
    OutOfMemory,
};

/// Sanitizes message text and enforces the configured codepoint limit. Unlike
/// `validateContent`, an empty result is returned to the caller so a message
/// may carry only embeds.
pub inline fn sanitizeContent(
    allocator: std.mem.Allocator,
    content: []const u8,
    max_codepoints: usize,
) ContentError![]u8 {
    const sanitized = try root.unicode.sanitizeMessageText(allocator, content);

    if ((std.unicode.utf8CountCodepoints(sanitized) catch unreachable) > max_codepoints) {
        allocator.free(sanitized);

        return error.TooLong;
    }

    return sanitized;
}

/// Sanitizes message text and requires a non-empty result. Used by message
/// creation when no embeds are supplied.
pub inline fn validateContent(
    allocator: std.mem.Allocator,
    content: []const u8,
    max_codepoints: usize,
) ContentError![]u8 {
    const sanitized = try sanitizeContent(allocator, content, max_codepoints);

    if (sanitized.len == 0) {
        allocator.free(sanitized);

        return error.Empty;
    }

    return sanitized;
}

/// The shared parse -> validate -> insert -> event -> push pipeline behind
/// `POST /api/channels/{channel_id}/messages` and webhook execute.
///
/// Requirements (the same numbers as the user message endpoint):
/// R5 - "content" is optional but, when present, must be a string and valid
///      UTF-8; forbidden codepoints are stripped and the codepoint limit
///      applies. At least one of non-empty "content" or non-empty "embeds" is
///      required; content-only messages must not be empty after stripping.
/// R6 - optional "reply_to_id" must be a string parseable as a message id
/// R7 - the reply target must exist (not deleted) and belong to the same channel
/// R8 - optional "embeds" must be null or an array of at most
///      api.messages.max_embeds valid rich embeds; embed text is sanitized like
///      message content and the api.embeds.* limits apply (see utils.parseEmbed)
/// R9 - attachments are derived from the sanitized content: every
///      `attachment://<fileId>` reference yields a file id, deduplicated in
///      first-appearance order; at most api.messages.max_attachments unique ids,
///      each of which must exist
/// R10 - mentions are parsed from the sanitized content (`<@id>`, `<@!id>`,
///       `<@&id>`, `@everyone`, `@here`); at most api.messages.max_mention_users
///       / max_mention_roles; ids of missing/deleted users and roles outside the
///       guild are dropped; `<#id>` and other forms are left as plain text
/// R11 - optional "allowed_mentions" filters which parsed mentions are kept (it
///       does not rewrite the content and never rejects the message); `parse` is
///       mutually exclusive with `users`/`roles`; absent = allow all
///
/// The result is `true` when the message was inserted (the caller serializes
/// the `201 {"id"}`), `false` when an error response was already written by
/// this task (the caller must not write anything else).
pub const Create = struct {
    const Task = root.task.Task(bool, anyerror);
    pub const Lazy = root.task.LazyTask(Create, bool, anyerror);

    pub const Payload = struct {
        id: root.types.MessageId,
        channel_id: root.types.ChannelId,
        guild_id: root.types.GuildId,
        author_id: ?root.types.UserId,
        webhook_id: ?root.types.WebhookId,
        /// Pre-built content (e.g. a rendered GitHub embed). When set, the
        /// request body is not parsed as a message; the caller has already
        /// produced the content and owns no request-body shape.
        preset: ?Content = null,
    };

    pub const Content = struct {
        content: []const u8,
        reply_to_id: ?root.types.MessageId,
        embeds: ?[]const u8,
        attachments: []const root.types.FileId,
        /// Set from the parsed content after `allowed_mentions` and DB
        /// validation (only ids of existing, non-deleted users land here).
        mention_everyone: bool = false,
        mention_user_ids: []const root.types.UserId = &.{},
        mention_role_ids: []const root.types.RoleId = &.{},
        allowed_mentions: root.utils.AllowedMentions = .{},
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    db: *root.db.Connection,
    content: ?Content = null,
    /// True once `content.attachments` has been derived from `content.content`.
    attachments_parsed: bool = false,
    reply_target_task: ?root.repo.messages.IsExists.Lazy = null,
    count_attachments_task: ?root.repo.files.CountExisting.Lazy = null,
    filter_mention_users_task: ?root.repo.mentions.FilterValidUsers.Lazy = null,
    filter_mention_roles_task: ?root.repo.mentions.FilterValidRoles.Lazy = null,
    create_channel_message_task: ?root.repo.channels.InsertMessage.Lazy = null,
    get_message_task: ?root.repo.messages.GetOne.Lazy = null,
    /// The stored message, read back after the insert so the caller can return
    /// the canonical object (with resolved attachments) to the client.
    message: ?root.repo.types.Message = null,
    mentions: root.utils.Mentions = .{},

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *Create = @ptrCast(@alignCast(ctx));

        // R5, R6
        if (this.content == null) {
            if (!this.request.contentIsAvailable()) {
                return .{ .pending = .want_read };
            }

            const root_value = std.json.parseFromSliceLeaky(std.json.Value, this.response.allocator, this.request.getContent(), .{}) catch {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad JSON");

                return .{ .ready = false };
            };

            if (root_value != .object) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Expected an object");

                return .{ .ready = false };
            }

            // R5
            const content_value = root_value.object.get("content");

            // R5
            if (content_value != null and content_value.? != .string) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'content' is not a string");

                return .{ .ready = false };
            }

            var content: []const u8 = "";

            if (content_value) |value| {
                if (value.string.len != 0) {
                    content = sanitizeContent(this.response.allocator, value.string, root.options.api.messages.max_codepoints) catch |err| switch (err) {
                        error.InvalidUtf8 => {
                            _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'content' is invalid");

                            return .{ .ready = false };
                        },
                        error.TooLong => {
                            _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'content' is too long");

                            return .{ .ready = false };
                        },
                        error.Empty => unreachable,
                        error.OutOfMemory => return .{ .err = error.OutOfMemory },
                    };
                }
            }

            // R6
            const reply_to_id_value = root_value.object.get("reply_to_id");

            // R6
            if (reply_to_id_value != null and reply_to_id_value.? != .null and reply_to_id_value.? != .string) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'reply_to_id' is not a string");

                return .{ .ready = false };
            }

            // R6
            const reply_to_id: ?root.types.MessageId = if (reply_to_id_value == null or reply_to_id_value.? == .null)
                null
            else
                std.fmt.parseInt(root.types.MessageId, reply_to_id_value.?.string, 10) catch {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'reply_to_id' is invalid");

                    return .{ .ready = false };
                };

            // R8
            var embeds: ?[]const u8 = null;

            if (root_value.object.get("embeds")) |embeds_value| {
                if (embeds_value != .null) {
                    const parsed = root.utils.parseEmbeds(this.response, embeds_value) catch |err| {
                        SCOPE.err("failed to parse the embeds: {t}", .{err});

                        return .{ .err = err };
                    } orelse {
                        // response handled in the parser
                        return .{ .ready = false };
                    };

                    if (parsed.items.len != 0) {
                        embeds = root.utils.serializeEmbeds(this.response.allocator, parsed.items) catch |err| {
                            SCOPE.err("failed to serialize the embeds: {t}", .{err});

                            return .{ .err = err };
                        };
                    }
                }
            }

            // R5
            if (content.len == 0 and embeds == null) {
                if (content_value == null) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'content' or 'embeds' is required");
                } else {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'content' is empty");
                }

                return .{ .ready = false };
            }

            // R10
            this.mentions = root.utils.parseMentions(this.response.allocator, content) catch |err| {
                SCOPE.err("failed to parse the mentions: {t}", .{err});

                return .{ .err = err };
            };

            // R10
            if (this.mentions.user_ids.items.len > root.options.api.messages.max_mention_users) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'mentions' is too long");

                return .{ .ready = false };
            }

            // R10
            if (this.mentions.role_ids.items.len > root.options.api.messages.max_mention_roles) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'mentions' is too long");

                return .{ .ready = false };
            }

            // R11
            var allowed_mentions: root.utils.AllowedMentions = .{};

            if (root_value.object.get("allowed_mentions")) |allowed_value| {
                if (allowed_value != .null) {
                    allowed_mentions = root.utils.parseAllowedMentions(this.response, allowed_value) catch |err| {
                        SCOPE.err("failed to parse 'allowed_mentions': {t}", .{err});

                        return .{ .err = err };
                    } orelse {
                        // response handled in the parser
                        return .{ .ready = false };
                    };
                }
            }

            this.content = .{
                .content = content,
                .reply_to_id = reply_to_id,
                .embeds = embeds,
                .attachments = &.{},
                .allowed_mentions = allowed_mentions,
            };
        }

        // R9
        if (!this.attachments_parsed) {
            const ids = root.utils.parseAttachmentIds(this.response.allocator, this.content.?.content) catch |err| {
                SCOPE.err("failed to parse the attachment ids: {t}", .{err});

                return .{ .err = err };
            };

            // R9
            if (ids.len > root.options.api.messages.max_attachments) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'attachments' is too long");

                return .{ .ready = false };
            }

            this.content.?.attachments = ids;
            this.attachments_parsed = true;
        }

        // R10
        if (this.mentions.user_ids.items.len != 0) {
            var kept: std.ArrayList(root.types.UserId) = .empty;

            for (this.mentions.user_ids.items) |id| {
                if (this.content.?.allowed_mentions.allows(this.content.?.allowed_mentions.users, id)) {
                    kept.append(this.response.allocator, id) catch |err| {
                        SCOPE.err("failed to filter the mentions: {t}", .{err});

                        return .{ .err = err };
                    };
                }
            }

            this.content.?.mention_user_ids = kept.items;
        }

        if (this.mentions.role_ids.items.len != 0) {
            var kept: std.ArrayList(root.types.RoleId) = .empty;

            for (this.mentions.role_ids.items) |id| {
                if (this.content.?.allowed_mentions.allows(this.content.?.allowed_mentions.roles, id)) {
                    kept.append(this.response.allocator, id) catch |err| {
                        SCOPE.err("failed to filter the mentions: {t}", .{err});

                        return .{ .err = err };
                    };
                }
            }

            this.content.?.mention_role_ids = kept.items;
        }

        this.content.?.mention_everyone = this.mentions.everyone and this.content.?.allowed_mentions.everyone;

        // R10
        if (this.content.?.mention_user_ids.len != 0) {
            // await this.filter_mention_users_task
            {
                if (this.filter_mention_users_task == null) {
                    this.filter_mention_users_task = .from(.init(this.response.allocator, this.db, .{
                        .ids = this.content.?.mention_user_ids,
                    }));
                }

                while (this.filter_mention_users_task.?.await()) |res| {
                    return res.map(bool, false);
                }

                this.content.?.mention_user_ids = this.filter_mention_users_task.?.result;
            }
        }

        // R10
        if (this.content.?.mention_role_ids.len != 0) {
            // await this.filter_mention_roles_task
            {
                if (this.filter_mention_roles_task == null) {
                    this.filter_mention_roles_task = .from(.init(this.response.allocator, this.db, .{
                        .guild_id = this.payload.guild_id,
                        .ids = this.content.?.mention_role_ids,
                    }));
                }

                while (this.filter_mention_roles_task.?.await()) |res| {
                    return res.map(bool, false);
                }

                this.content.?.mention_role_ids = this.filter_mention_roles_task.?.result;
            }
        }

        // R9
        if (this.content.?.attachments.len != 0) {
            // await this.count_attachments_task
            {
                if (this.count_attachments_task == null) {
                    this.count_attachments_task = .from(.init(this.response.allocator, this.db, .{
                        .ids = this.content.?.attachments,
                    }));
                }

                while (this.count_attachments_task.?.await()) |res| {
                    return res.map(bool, false);
                }

                if (this.count_attachments_task.?.result != this.content.?.attachments.len) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'attachments' is invalid");

                    return .{ .ready = false };
                }
            }
        }

        // R7
        // await this.reply_target_task
        if (this.content.?.reply_to_id != null) {
            if (this.reply_target_task == null) {
                this.reply_target_task = .from(.init(this.db, .{
                    .id = this.content.?.reply_to_id.?,
                }));
            }

            while (this.reply_target_task.?.await()) |res| {
                return res.map(bool, false);
            }

            // R7
            if (this.reply_target_task.?.result == null or
                this.reply_target_task.?.result.?.channel_id != this.payload.channel_id)
            {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'reply_to_id' is invalid");

                return .{ .ready = false };
            }
        }

        // await this.create_channel_message_task
        {
            if (this.create_channel_message_task == null) {
                this.create_channel_message_task = .from(.init(
                    this.response.allocator,
                    this.db,
                    .{
                        .id = this.payload.id,
                        .channel_id = this.payload.channel_id,
                        .author_id = this.payload.author_id,
                        .webhook_id = this.payload.webhook_id,
                        .content = this.content.?.content,
                        .reply_to_id = this.content.?.reply_to_id,
                        .embeds = this.content.?.embeds,
                        .attachments = this.content.?.attachments,
                        .mention_everyone = this.content.?.mention_everyone,
                        .mention_user_ids = this.content.?.mention_user_ids,
                        .mention_role_ids = this.content.?.mention_role_ids,
                    },
                ));
            }

            while (this.create_channel_message_task.?.await()) |res| {
                return res.map(bool, false);
            }

            if (!this.create_channel_message_task.?.result) {
                _ = root.route.generic.responseErrorMessage(this.response, .not_found, "Channel not found");

                return .{ .ready = false };
            }
        }

        if (this.message == null) {
            if (this.get_message_task == null) {
                this.get_message_task = .from(.init(
                    this.response.allocator,
                    this.db,
                    .{
                        .id = this.payload.id,
                        .me_user_id = this.payload.author_id orelse 0,
                    },
                ));
            }

            while (this.get_message_task.?.await()) |res| {
                return res.map(bool, false);
            }

            this.message = this.get_message_task.?.result;
        }

        root.bus.raise(.{
            .message_created = .{
                .id = this.payload.id,
                .channel_id = this.payload.channel_id,
                .guild_id = this.payload.guild_id,
            },
        });

        root.notifications_dispatcher.enqueue(
            this.payload.id,
            this.payload.channel_id,
            this.payload.guild_id,
            this.payload.author_id,
            this.payload.webhook_id,
            this.content.?.mention_everyone,
            this.content.?.mention_user_ids,
            this.content.?.mention_role_ids,
        );

        return .{ .ready = true };
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *Create = @ptrCast(@alignCast(ctx));

        if (this.reply_target_task) |*t| {
            t.dispose();
            this.reply_target_task = null;
        }

        if (this.count_attachments_task) |*t| {
            t.dispose();
            this.count_attachments_task = null;
        }

        if (this.filter_mention_users_task) |*t| {
            t.dispose();
            this.filter_mention_users_task = null;
        }

        if (this.filter_mention_roles_task) |*t| {
            t.dispose();
            this.filter_mention_roles_task = null;
        }

        if (this.create_channel_message_task) |*t| {
            t.dispose();
            this.create_channel_message_task = null;
        }

        if (this.get_message_task) |*t| {
            t.dispose();
            this.get_message_task = null;
        }

        this.mentions.deinit(this.response.allocator);

        this.db.release();
    }

    pub inline fn init(
        response: *root.http.Response,
        request: *const root.http.Request,
        db: *root.db.Connection,
        payload: Payload,
    ) Create {
        db.acquire();

        return .{
            .request = request,
            .response = response,
            .payload = payload,
            .db = db,
            .content = payload.preset,
        };
    }

    pub inline fn task(this: *Create) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }

    pub inline fn lazy(
        response: *root.http.Response,
        request: *const root.http.Request,
        db: *root.db.Connection,
        payload: Payload,
    ) Lazy {
        return .from(init(response, request, db, payload));
    }
};

/// The shared parse -> validate -> edit -> event pipeline behind
/// `PATCH /api/messages/{message_id}` and the webhook message edit endpoint.
///
/// Requirements:
/// R4 - the body must be a JSON object containing "content" and/or "embeds";
///      an absent field keeps the stored value, and explicit `null`/`[]`
///      clears embeds
/// R5 - "content", when present, must be a string, valid UTF-8; forbidden
///      codepoints are stripped and the codepoint limit applies
/// R6 - the resulting message must have non-empty content or non-empty embeds
/// R7 - attachments and mentions are recomputed from the effective content;
///      at most api.messages.max_attachments unique references, each of which
///      must exist, and the mention limits apply
///
/// The result is `true` when the response was written; `false` means an error
/// response was already written.
pub const Edit = struct {
    const Task = root.task.Task(bool, anyerror);
    pub const Lazy = root.task.LazyTask(Edit, bool, anyerror);

    pub const Payload = struct {
        id: root.types.MessageId,
        guild_id: root.types.GuildId,
        channel_id: root.types.ChannelId,
        /// Caller whose per-reaction `me` flag is computed; 0 for webhook
        /// messages.
        me_user_id: root.types.UserId,
    };

    const Content = struct {
        content: []const u8,
        embeds_mode: root.repo.messages.Edit.Payload.EmbedsMode = .keep,
        embeds: ?[]const u8 = null,
        /// Derived from `content`.
        attachments: []const root.types.FileId = &.{},
        mention_everyone: bool = false,
        mention_user_ids: []const root.types.UserId = &.{},
        mention_role_ids: []const root.types.RoleId = &.{},
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    db: *root.db.Connection,
    current_loaded: bool = false,
    current_message: ?root.repo.types.Message = null,
    get_current_task: ?root.repo.messages.GetOne.Lazy = null,
    content: ?Content = null,
    attachments_parsed: bool = false,
    mentions_parsed: bool = false,
    count_attachments_task: ?root.repo.files.CountExisting.Lazy = null,
    filter_mention_users_task: ?root.repo.mentions.FilterValidUsers.Lazy = null,
    filter_mention_roles_task: ?root.repo.mentions.FilterValidRoles.Lazy = null,
    edit_task: ?root.repo.messages.Edit.Lazy = null,
    get_message_task: ?root.repo.messages.GetOne.Lazy = null,
    message: ?root.repo.types.Message = null,
    mentions: root.utils.Mentions = .{},
    body: ?[]const u8 = null,
    streamer: ?root.http.Response.Streamer = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *Edit = @ptrCast(@alignCast(ctx));

        // R4-R7
        // await this.get_current_task
        if (!this.current_loaded) {
            if (this.get_current_task == null) {
                this.get_current_task = .from(.init(
                    this.response.allocator,
                    this.db,
                    .{
                        .id = this.payload.id,
                        .me_user_id = this.payload.me_user_id,
                    },
                ));
            }

            while (this.get_current_task.?.await()) |res| {
                return res.map(bool, false);
            }

            this.current_message = this.get_current_task.?.result;
            this.current_loaded = true;

            if (this.current_message == null) {
                _ = root.route.generic.responseErrorMessage(this.response, .not_found, "Message not found");

                return .{ .ready = false };
            }
        }

        const current = this.current_message.?;

        // R4-R6
        if (this.content == null) {
            if (!this.request.contentIsAvailable()) {
                return .{ .pending = .want_read };
            }

            const root_value = std.json.parseFromSliceLeaky(std.json.Value, this.response.allocator, this.request.getContent(), .{}) catch {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad JSON");

                return .{ .ready = false };
            };

            if (root_value != .object) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Expected an object");

                return .{ .ready = false };
            }

            const content_value = root_value.object.get("content");
            const embeds_value = root_value.object.get("embeds");

            // R4
            if (content_value == null and embeds_value == null) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'content' or 'embeds' is required");

                return .{ .ready = false };
            }

            // R5
            var content: []const u8 = current.content;

            if (content_value) |value| {
                if (value != .string) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'content' is not a string");

                    return .{ .ready = false };
                }

                content = if (value.string.len == 0)
                    ""
                else
                    sanitizeContent(this.response.allocator, value.string, root.options.api.messages.max_codepoints) catch |err| switch (err) {
                        error.InvalidUtf8 => {
                            _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'content' is invalid");

                            return .{ .ready = false };
                        },
                        error.TooLong => {
                            _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'content' is too long");

                            return .{ .ready = false };
                        },
                        error.Empty => unreachable,
                        error.OutOfMemory => return .{ .err = error.OutOfMemory },
                    };
            }

            // R4
            var embeds_mode: root.repo.messages.Edit.Payload.EmbedsMode = .keep;
            var embeds: ?[]const u8 = null;

            if (embeds_value) |value| {
                embeds_mode = .set;

                if (value != .null) {
                    const parsed = root.utils.parseEmbeds(this.response, value) catch |err| {
                        SCOPE.err("edit failed to parse the embeds: {t}", .{err});

                        return .{ .err = err };
                    } orelse {
                        // response handled in the parser
                        return .{ .ready = false };
                    };

                    if (parsed.items.len != 0) {
                        embeds = root.utils.serializeEmbeds(this.response.allocator, parsed.items) catch |err| {
                            SCOPE.err("edit failed to serialize the embeds: {t}", .{err});

                            return .{ .err = err };
                        };
                    }
                }
            }

            // R6
            const has_embeds = switch (embeds_mode) {
                .set => embeds != null,
                .keep => current.embeds != null,
            };

            if (content.len == 0 and !has_embeds) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'content' is empty");

                return .{ .ready = false };
            }

            this.content = .{
                .content = content,
                .embeds_mode = embeds_mode,
                .embeds = embeds,
            };
        }

        // R7
        if (!this.attachments_parsed) {
            const ids = root.utils.parseAttachmentIds(this.response.allocator, this.content.?.content) catch |err| {
                SCOPE.err("edit failed to parse the attachment ids: {t}", .{err});

                return .{ .err = err };
            };

            // R7
            if (ids.len > root.options.api.messages.max_attachments) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'attachments' is too long");

                return .{ .ready = false };
            }

            this.content.?.attachments = ids;
            this.attachments_parsed = true;
        }

        // R7
        if (!this.mentions_parsed) {
            this.mentions = root.utils.parseMentions(this.response.allocator, this.content.?.content) catch |err| {
                SCOPE.err("edit failed to parse the mentions: {t}", .{err});

                return .{ .err = err };
            };

            // R7
            if (this.mentions.user_ids.items.len > root.options.api.messages.max_mention_users or
                this.mentions.role_ids.items.len > root.options.api.messages.max_mention_roles)
            {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'mentions' is too long");

                return .{ .ready = false };
            }

            this.content.?.mention_user_ids = this.mentions.user_ids.items;
            this.content.?.mention_role_ids = this.mentions.role_ids.items;
            this.content.?.mention_everyone = this.mentions.everyone;
            this.mentions_parsed = true;
        }

        // R7
        if (this.content.?.mention_user_ids.len != 0) {
            // await this.filter_mention_users_task
            if (this.filter_mention_users_task == null) {
                this.filter_mention_users_task = .from(.init(this.response.allocator, this.db, .{
                    .ids = this.content.?.mention_user_ids,
                }));
            }

            while (this.filter_mention_users_task.?.await()) |res| {
                return res.map(bool, false);
            }

            this.content.?.mention_user_ids = this.filter_mention_users_task.?.result;
        }

        // R7
        if (this.content.?.mention_role_ids.len != 0) {
            // await this.filter_mention_roles_task
            if (this.filter_mention_roles_task == null) {
                this.filter_mention_roles_task = .from(.init(this.response.allocator, this.db, .{
                    .guild_id = this.payload.guild_id,
                    .ids = this.content.?.mention_role_ids,
                }));
            }

            while (this.filter_mention_roles_task.?.await()) |res| {
                return res.map(bool, false);
            }

            this.content.?.mention_role_ids = this.filter_mention_roles_task.?.result;
        }

        // R7
        if (this.content.?.attachments.len != 0) {
            // await this.count_attachments_task
            if (this.count_attachments_task == null) {
                this.count_attachments_task = .from(.init(this.response.allocator, this.db, .{
                    .ids = this.content.?.attachments,
                }));
            }

            while (this.count_attachments_task.?.await()) |res| {
                return res.map(bool, false);
            }

            if (this.count_attachments_task.?.result != this.content.?.attachments.len) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'attachments' is invalid");

                return .{ .ready = false };
            }
        }

        // R4-R7
        // await this.edit_task
        {
            if (this.edit_task == null) {
                this.edit_task = .from(.init(this.response.allocator, this.db, .{
                    .id = this.payload.id,
                    .content = this.content.?.content,
                    .embeds_mode = this.content.?.embeds_mode,
                    .embeds = this.content.?.embeds,
                    .attachments = this.content.?.attachments,
                    .mention_everyone = this.content.?.mention_everyone,
                    .mention_user_ids = this.content.?.mention_user_ids,
                    .mention_role_ids = this.content.?.mention_role_ids,
                }));
            }

            while (!this.edit_task.?.done) {
                if (this.edit_task.?.await()) |res| {
                    return res.map(bool, false);
                }

                root.bus.raise(.{
                    .message_updated = .{
                        .id = this.payload.id,
                        .channel_id = this.payload.channel_id,
                        .guild_id = this.payload.guild_id,
                    },
                });
            }
        }

        if (this.message == null) {
            // await this.get_message_task
            if (this.get_message_task == null) {
                this.get_message_task = .from(.init(
                    this.response.allocator,
                    this.db,
                    .{
                        .id = this.payload.id,
                        .me_user_id = this.payload.me_user_id,
                    },
                ));
            }

            while (this.get_message_task.?.await()) |res| {
                return res.map(bool, false);
            }

            this.message = this.get_message_task.?.result;
        }

        if (this.body == null) {
            const message = this.message orelse {
                SCOPE.err("edit task returned no message", .{});

                return .{ .err = error.Unexpected };
            };

            const response = root.route.types.Message.fromRepo(this.response.allocator, message) catch |err| {
                SCOPE.err("edit failed to build the response message: {t}", .{err});

                return .{ .err = err };
            };

            var writer: std.Io.Writer.Allocating = .init(this.response.allocator);

            std.json.fmt(response, .{}).format(&writer.writer) catch |err| {
                SCOPE.err("edit failed to serialize the response: {t}", .{err});

                return .{ .err = err };
            };

            this.body = writer.written();
        }

        if (this.streamer == null) {
            var writer = this.response.getWriter();

            if (!writer.writeCode(.ok)) {
                return .{ .pending = .want_write };
            }

            if (!writer.beginJSON(this.body.?.len)) {
                return .{ .pending = .want_write };
            }

            writer.commit();
            this.streamer = this.response.getStreamer(this.body.?);
        }

        return this.streamer.?.poll().map(bool, false);
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *Edit = @ptrCast(@alignCast(ctx));

        if (this.get_current_task) |*t| {
            t.dispose();
            this.get_current_task = null;
        }

        if (this.count_attachments_task) |*t| {
            t.dispose();
            this.count_attachments_task = null;
        }

        if (this.filter_mention_users_task) |*t| {
            t.dispose();
            this.filter_mention_users_task = null;
        }

        if (this.filter_mention_roles_task) |*t| {
            t.dispose();
            this.filter_mention_roles_task = null;
        }

        if (this.edit_task) |*t| {
            t.dispose();
            this.edit_task = null;
        }

        if (this.get_message_task) |*t| {
            t.dispose();
            this.get_message_task = null;
        }

        this.mentions.deinit(this.response.allocator);

        this.db.release();
    }

    pub inline fn init(
        response: *root.http.Response,
        request: *const root.http.Request,
        db: *root.db.Connection,
        payload: Payload,
    ) Edit {
        db.acquire();

        return .{
            .request = request,
            .response = response,
            .db = db,
            .payload = payload,
        };
    }

    pub inline fn task(this: *Edit) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }

    pub inline fn lazy(
        response: *root.http.Response,
        request: *const root.http.Request,
        db: *root.db.Connection,
        payload: Payload,
    ) Lazy {
        return .from(init(response, request, db, payload));
    }
};
