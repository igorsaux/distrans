// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../root.zig");

pub const reactions = @import("id/reactions.zig");

const SCOPE = std.log.scoped(.@"/api/messages/{message_id}");

/// R1 - user must be logged
/// R2 - the channel exists
/// R3 - user has rights to view messages
/// R4 - the response includes the message "channel_id" and its "attachments"
///      (objects, ordered)
/// R5 - the response includes the message mentions: "mention_everyone",
///      "mentions" (user ids) and "mention_roles" (role ids)
const GetTask = struct {
    const Task = root.http.Task;

    pub const Payload = struct {
        message_id: root.types.MessageId,
    };

    pub const Response = struct {
        channel_id: []const u8,
        author_id: ?[]const u8,
        webhook_id: ?[]const u8,
        content: []const u8,
        created_at: u64,
        reply_to_id: ?[]const u8,
        edited_at: ?u64,
        embeds: ?[]const root.types.Embed,
        attachments: []const root.route.types.Attachment,
        mention_everyone: bool,
        mentions: []const []const u8,
        mention_roles: []const []const u8,
        pinned: bool,
        reactions: ?[]const root.route.types.Reaction,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    get_message_task: ?root.repo.messages.Get.Lazy = null,
    check_user_channel_rights_task: ?root.repo.rights.CheckUserChannelRights.Lazy = null,
    body: ?[]const u8 = null,
    streamer: ?root.http.Response.Streamer = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *GetTask = @ptrCast(@alignCast(ctx));

        if (this.db == null) {
            this.db = root.db_pool.rent() orelse {
                return .{ .pending = .db };
            };
        }

        // R1
        // await this.bearer_middleware_task
        {
            if (this.bearer_middleware_task == null) {
                this.bearer_middleware_task = .from(.init(this.request, this.response, this.db.?));
            }

            while (this.bearer_middleware_task.?.await()) |res| {
                return res.discard();
            }

            if (this.bearer_middleware_task.?.result == null) {
                // response handled in the middleware
                return .ready;
            }
        }

        const db = this.db.?;

        // R2
        // await this.get_message_task
        {
            if (this.get_message_task == null) {
                this.get_message_task = .from(.init(
                    this.response.allocator,
                    db,
                    .{
                        .id = this.payload.message_id,
                        .me_user_id = this.bearer_middleware_task.?.result.?,
                    },
                ));
            }

            while (this.get_message_task.?.await()) |res| {
                return res.discard();
            }

            if (this.get_message_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Message not found");
            }
        }

        // R3
        // await this.check_user_channel_rights_task
        {
            if (this.check_user_channel_rights_task == null) {
                this.check_user_channel_rights_task = .from(.init(this.db.?, .{
                    .guild_id = this.get_message_task.?.result.?.guild_id,
                    .channel_id = this.get_message_task.?.result.?.channel_id,
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .required = .{ .read_messages = true },
                }));
            }

            while (this.check_user_channel_rights_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.check_user_channel_rights_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
            }
        }

        if (this.body == null) {
            const response: Response = .{
                .channel_id = std.fmt.allocPrint(this.response.allocator, "{}", .{this.get_message_task.?.result.?.channel_id}) catch |err| {
                    SCOPE.err("GET failed to stringify 'channel_id': {t}", .{err});

                    return .{ .err = err };
                },
                .author_id = if (this.get_message_task.?.result.?.author_id) |author_id|
                    std.fmt.allocPrint(this.response.allocator, "{}", .{author_id}) catch |err| {
                        SCOPE.err("GET failed to stringify 'author_id': {t}", .{err});

                        return .{ .err = err };
                    }
                else
                    null,
                .webhook_id = if (this.get_message_task.?.result.?.webhook_id) |webhook_id|
                    std.fmt.allocPrint(this.response.allocator, "{}", .{webhook_id}) catch |err| {
                        SCOPE.err("GET failed to stringify 'webhook_id': {t}", .{err});

                        return .{ .err = err };
                    }
                else
                    null,
                .content = this.get_message_task.?.result.?.content,
                .created_at = this.get_message_task.?.result.?.created_at,
                .reply_to_id = if (this.get_message_task.?.result.?.reply_to_id) |reply_to_id|
                    std.fmt.allocPrint(this.response.allocator, "{}", .{reply_to_id}) catch |err| {
                        SCOPE.err("GET failed to stringify 'reply_to_id': {t}", .{err});

                        return .{ .err = err };
                    }
                else
                    null,
                .edited_at = this.get_message_task.?.result.?.edited_at,
                .embeds = blk: {
                    if (this.get_message_task.?.result.?.embeds) |embeds| {
                        const embeds_parsed = std.json.parseFromSliceLeaky([]const root.types.Embed, this.response.allocator, embeds, .{ .allocate = .alloc_always }) catch |err| {
                            SCOPE.err("GET bad embeds in DB: {t}", .{err});

                            return .{ .err = err };
                        };

                        break :blk embeds_parsed;
                    } else {
                        break :blk null;
                    }
                },
                .attachments = root.route.types.parseAttachments(this.response.allocator, this.get_message_task.?.result.?.attachments) catch |err| {
                    SCOPE.err("GET failed to parse 'attachments': {t}", .{err});

                    return .{ .err = err };
                },
                .mention_everyone = this.get_message_task.?.result.?.mention_everyone,
                .mentions = root.utils.parseMentionIds(this.response.allocator, this.get_message_task.?.result.?.mention_user_ids) catch |err| {
                    SCOPE.err("GET failed to parse 'mentions': {t}", .{err});

                    return .{ .err = err };
                },
                .mention_roles = root.utils.parseMentionIds(this.response.allocator, this.get_message_task.?.result.?.mention_role_ids) catch |err| {
                    SCOPE.err("GET failed to parse 'mention_roles': {t}", .{err});

                    return .{ .err = err };
                },
                .pinned = this.get_message_task.?.result.?.pinned,
                .reactions = blk: {
                    if (this.get_message_task.?.result.?.reactions) |reactions_json| {
                        const parsed = std.json.parseFromSliceLeaky([]const root.route.types.Reaction, this.response.allocator, reactions_json, .{ .allocate = .alloc_always }) catch |err| {
                            SCOPE.err("GET bad reactions in DB: {t}", .{err});

                            return .{ .err = err };
                        };

                        break :blk parsed;
                    } else {
                        break :blk null;
                    }
                },
            };

            var writer: std.Io.Writer.Allocating = .init(this.response.allocator);

            std.json.fmt(response, .{}).format(&writer.writer) catch |err| {
                SCOPE.err("GET failed to serialize the response: {t}", .{err});

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

        return this.streamer.?.poll();
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *GetTask = @ptrCast(@alignCast(ctx));

        if (this.bearer_middleware_task) |*t| {
            t.dispose();
            this.bearer_middleware_task = null;
        }

        if (this.check_user_channel_rights_task) |*t| {
            t.dispose();
            this.check_user_channel_rights_task = null;
        }

        if (this.get_message_task) |*t| {
            t.dispose();
            this.get_message_task = null;
        }

        if (this.db) |db| {
            db.release();
            this.db = null;
        }
    }

    pub inline fn task(
        request: *const root.http.Request,
        response: *root.http.Response,
        payload: Payload,
    ) !Task {
        const this = try response.allocator.create(GetTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .request = request,
            .response = response,
            .payload = payload,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// GET /api/messages/{message_id}
/// R1 - user must be logged (see the R-list above GetTask)
pub inline fn getHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    message_id: root.types.MessageId,
) !GetTask.Task {
    _ = allocator;

    return try GetTask.task(request, response, .{
        .message_id = message_id,
    });
}

/// R1 - user must be logged
/// R2 - the message exists
/// R3 - user must have read_messages on the message's channel
/// R4 - the author may delete the own message without any further permissions;
///      a non-author needs delete_messages
/// R5 - a non-author must be strictly higher than the author
const DeleteTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        message_id: root.types.MessageId,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    message_is_exists_task: ?root.repo.messages.IsExists.Lazy = null,
    check_user_channel_rights_task: ?root.repo.rights.CheckUserChannelRights.Lazy = null,
    is_higher_than_other_task: ?root.repo.users.IsHigherThanOther.Lazy = null,
    delete_task: ?root.repo.messages.SoftDelete.Lazy = null,
    audit_log: ?root.repo.audit_log.Insert.Lazy = null,
    audit_entries: [1]root.repo.audit_log.Insert.Entry = undefined,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *DeleteTask = @ptrCast(@alignCast(ctx));

        if (this.db == null) {
            this.db = root.db_pool.rent() orelse {
                return .{ .pending = .db };
            };
        }

        // R1
        // await this.bearer_middleware_task
        {
            if (this.bearer_middleware_task == null) {
                this.bearer_middleware_task = .from(.init(this.request, this.response, this.db.?));
            }

            while (this.bearer_middleware_task.?.await()) |res| {
                return res.discard();
            }

            if (this.bearer_middleware_task.?.result == null) {
                // response handled in the middleware
                return .ready;
            }
        }

        // R2
        // await this.message_is_exists_task
        {
            if (this.message_is_exists_task == null) {
                this.message_is_exists_task = .from(.init(this.db.?, .{
                    .id = this.payload.message_id,
                }));
            }

            while (this.message_is_exists_task.?.await()) |res| {
                return res.discard();
            }

            if (this.message_is_exists_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Message not found");
            }
        }

        // R3, R4
        // A webhook message has no author, so it is never "own"; deleting it
        // needs `delete_messages` and has no author to outrank.
        const caller_id = this.bearer_middleware_task.?.result.?;
        const delete_author_id = this.message_is_exists_task.?.result.?.author_id;
        const is_author = delete_author_id != null and delete_author_id.? == caller_id;

        var required: root.types.Permissions = .{ .read_messages = true };

        if (!is_author) {
            required.delete_messages = true;
        }

        // R3, R4
        // await this.check_user_channel_rights_task
        {
            if (this.check_user_channel_rights_task == null) {
                this.check_user_channel_rights_task = .from(.init(this.db.?, .{
                    .guild_id = this.message_is_exists_task.?.result.?.guild_id,
                    .channel_id = this.message_is_exists_task.?.result.?.channel_id,
                    .user_id = caller_id,
                    .required = required,
                }));
            }

            while (this.check_user_channel_rights_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.check_user_channel_rights_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
            }
        }

        // R5
        if (!is_author) {
            if (delete_author_id) |delete_author| {
                // await this.is_higher_than_other_task
                {
                    if (this.is_higher_than_other_task == null) {
                        this.is_higher_than_other_task = .from(.init(this.db.?, .{
                            .guild_id = this.message_is_exists_task.?.result.?.guild_id,
                            .user_a_id = caller_id,
                            .user_b_id = delete_author,
                        }));
                    }

                    while (this.is_higher_than_other_task.?.await()) |res| {
                        return res.discard();
                    }

                    if (!this.is_higher_than_other_task.?.result) {
                        return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
                    }
                }
            }
        }

        // await this.delete_task
        {
            if (this.delete_task == null) {
                this.delete_task = .from(.init(this.db.?, .{
                    .id = this.payload.message_id,
                }));
            }

            while (!this.delete_task.?.done) {
                if (this.delete_task.?.await()) |res| {
                    return res.discard();
                }

                root.bus.raise(.{
                    .message_deleted = .{
                        .guild_id = this.message_is_exists_task.?.result.?.guild_id,
                        .channel_id = this.message_is_exists_task.?.result.?.channel_id,
                        .id = this.payload.message_id,
                    },
                });
            }
        }

        // A self-delete is not a moderation action and is not audited; any
        // other delete (including a webhook message, which has no author) is.
        if (!is_author) {
            // await this.audit_log
            {
                if (this.audit_log == null) {
                    this.audit_entries[0] = .{
                        .action = .message_delete,
                        .target_id = this.payload.message_id,
                        .channel_id = this.message_is_exists_task.?.result.?.channel_id,
                    };

                    this.audit_log = .from(root.repo.audit_log.Insert.init(this.db.?, this.response.allocator, .{
                        .guild_id = this.message_is_exists_task.?.result.?.guild_id,
                        .actor_id = this.bearer_middleware_task.?.result.?,
                        .entries = this.audit_entries[0..1],
                    }));
                }

                while (this.audit_log.?.await()) |res| {
                    return res.discard();
                }
            }
        }

        var writer = this.response.getWriter();

        if (!writer.writeCode(.no_content)) {
            return .{ .pending = .want_write };
        }

        if (!writer.emptyBody()) {
            return .{ .pending = .want_write };
        }

        writer.commit();

        return .ready;
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *DeleteTask = @ptrCast(@alignCast(ctx));

        if (this.bearer_middleware_task) |*t| {
            t.dispose();
            this.bearer_middleware_task = null;
        }

        if (this.message_is_exists_task) |*t| {
            t.dispose();
            this.message_is_exists_task = null;
        }

        if (this.check_user_channel_rights_task) |*t| {
            t.dispose();
            this.check_user_channel_rights_task = null;
        }

        if (this.is_higher_than_other_task) |*t| {
            t.dispose();
            this.is_higher_than_other_task = null;
        }

        if (this.delete_task) |*t| {
            t.dispose();
            this.delete_task = null;
        }

        if (this.audit_log) |*a| {
            a.dispose();
            this.audit_log = null;
        }

        if (this.db) |db| {
            db.release();
            this.db = null;
        }
    }

    pub inline fn task(
        request: *const root.http.Request,
        response: *root.http.Response,
        payload: Payload,
    ) !Task {
        const this = try response.allocator.create(DeleteTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .request = request,
            .response = response,
            .payload = payload,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// DELETE /api/messages/{message_id}
/// R1 - user must be logged (see the R-list above DeleteTask)
pub inline fn deleteHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    message_id: root.types.MessageId,
) !DeleteTask.Task {
    _ = allocator;

    return try DeleteTask.task(request, response, .{
        .message_id = message_id,
    });
}

/// R1 - user must be logged
/// R2 - the message exists
/// R3 - user must have read_messages on the message's channel and be the author
/// R4 - "content" must be present, a string, valid UTF-8; forbidden codepoints
///      are stripped; after stripping the content is not empty and not too long
/// R5 - optional "embeds" replaces the message embeds; explicit null or an empty
///      array clears them; a non-empty array is validated like POST R8
/// R6 - attachments are derived from the new content (same grammar and limit as
///      POST R9): at most api.messages.max_attachments unique `attachment://`
///      references, each of which must exist
/// R7 - mentions are recomputed from the new sanitized content (same syntax and
///      limits as POST R10); "allowed_mentions" is not accepted on edit because
///      edits never notify
pub const PatchTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        message_id: root.types.MessageId,
    };

    const Content = struct {
        content: []const u8,
        embeds_mode: root.repo.messages.Edit.Payload.EmbedsMode = .keep,
        embeds: ?[]const u8 = null,
        /// Derived from `content`.
        attachments: []const root.types.FileId = &.{},
        /// Recomputed from the new content on every edit (default parse = all).
        mention_everyone: bool = false,
        mention_user_ids: []const root.types.UserId = &.{},
        mention_role_ids: []const root.types.RoleId = &.{},
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    message_is_exists_task: ?root.repo.messages.IsExists.Lazy = null,
    check_user_channel_rights_task: ?root.repo.rights.CheckUserChannelRights.Lazy = null,
    content: ?Content = null,
    count_attachments_task: ?root.repo.files.CountExisting.Lazy = null,
    filter_mention_users_task: ?root.repo.mentions.FilterValidUsers.Lazy = null,
    filter_mention_roles_task: ?root.repo.mentions.FilterValidRoles.Lazy = null,
    edit_task: ?root.repo.messages.Edit.Lazy = null,
    get_message_task: ?root.repo.messages.GetOne.Lazy = null,
    /// The stored message, read back after the edit so the caller can return the
    /// canonical object (with resolved attachments) to the client.
    message: ?root.repo.types.Message = null,
    mentions: root.utils.Mentions = .{},
    body: ?[]const u8 = null,
    streamer: ?root.http.Response.Streamer = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *PatchTask = @ptrCast(@alignCast(ctx));

        if (this.db == null) {
            this.db = root.db_pool.rent() orelse {
                return .{ .pending = .db };
            };
        }

        // R1
        // await this.bearer_middleware_task
        {
            if (this.bearer_middleware_task == null) {
                this.bearer_middleware_task = .from(.init(this.request, this.response, this.db.?));
            }

            while (this.bearer_middleware_task.?.await()) |res| {
                return res.discard();
            }

            if (this.bearer_middleware_task.?.result == null) {
                // response handled in the middleware
                return .ready;
            }
        }

        // R2
        // await this.message_is_exists_task
        {
            if (this.message_is_exists_task == null) {
                this.message_is_exists_task = .from(.init(this.db.?, .{
                    .id = this.payload.message_id,
                }));
            }

            while (this.message_is_exists_task.?.await()) |res| {
                return res.discard();
            }

            if (this.message_is_exists_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Message not found");
            }
        }

        // R3
        // await this.check_user_channel_rights_task
        {
            if (this.check_user_channel_rights_task == null) {
                this.check_user_channel_rights_task = .from(.init(this.db.?, .{
                    .guild_id = this.message_is_exists_task.?.result.?.guild_id,
                    .channel_id = this.message_is_exists_task.?.result.?.channel_id,
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .required = .{ .read_messages = true },
                }));
            }

            while (this.check_user_channel_rights_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.check_user_channel_rights_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
            }
        }

        // R3
        const patch_author_id = this.message_is_exists_task.?.result.?.author_id;

        if (patch_author_id == null or patch_author_id.? != this.bearer_middleware_task.?.result.?) {
            return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
        }

        // R4
        if (this.content == null) {
            if (!this.request.contentIsAvailable()) {
                return .{ .pending = .want_read };
            }

            const body = std.json.parseFromSliceLeaky(std.json.Value, this.response.allocator, this.request.getContent(), .{}) catch {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad JSON");

                return .ready;
            };

            if (body != .object) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Expected an object");

                return .ready;
            }

            // R4
            const content_value = body.object.get("content") orelse {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'content' is missing");

                return .ready;
            };

            // R4
            if (content_value != .string) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'content' is not a string");

                return .ready;
            }

            const sanitized = root.unicode.sanitizeMessageText(this.response.allocator, content_value.string) catch |err| switch (err) {
                error.InvalidUtf8 => return root.route.generic.responseErrorMessage(this.response, .bad_request, "'content' is invalid"),
                error.OutOfMemory => return .{ .err = error.OutOfMemory },
            };

            // R4
            if (sanitized.len == 0) {
                this.response.allocator.free(sanitized);

                return root.route.generic.responseErrorMessage(this.response, .bad_request, "'content' is empty");
            }

            // R4
            if (std.unicode.utf8CountCodepoints(sanitized) catch unreachable >
                root.options.api.messages.max_codepoints)
            {
                this.response.allocator.free(sanitized);

                return root.route.generic.responseErrorMessage(this.response, .bad_request, "'content' is too long");
            }

            // R5
            var embeds_mode: root.repo.messages.Edit.Payload.EmbedsMode = .keep;
            var embeds: ?[]const u8 = null;

            if (body.object.get("embeds")) |embeds_value| {
                embeds_mode = .set;

                if (embeds_value != .null) {
                    const parsed = root.utils.parseEmbeds(this.response, embeds_value) catch |err| {
                        SCOPE.err("PATCH failed to parse the embeds: {t}", .{err});

                        return .{ .err = err };
                    } orelse {
                        // response handled in the parser
                        return .ready;
                    };

                    if (parsed.items.len != 0) {
                        embeds = root.utils.serializeEmbeds(this.response.allocator, parsed.items) catch |err| {
                            SCOPE.err("PATCH failed to serialize the embeds: {t}", .{err});

                            return .{ .err = err };
                        };
                    }
                }
            }

            // R6
            const attachment_ids = root.utils.parseAttachmentIds(this.response.allocator, sanitized) catch |err| {
                SCOPE.err("PATCH failed to parse the attachment ids: {t}", .{err});

                return .{ .err = err };
            };

            // R6
            if (attachment_ids.len > root.options.api.messages.max_attachments) {
                return root.route.generic.responseErrorMessage(this.response, .bad_request, "'attachments' is too long");
            }

            // R7
            this.mentions = root.utils.parseMentions(this.response.allocator, sanitized) catch |err| {
                SCOPE.err("PATCH failed to parse the mentions: {t}", .{err});

                return .{ .err = err };
            };

            if (this.mentions.user_ids.items.len > root.options.api.messages.max_mention_users or
                this.mentions.role_ids.items.len > root.options.api.messages.max_mention_roles)
            {
                return root.route.generic.responseErrorMessage(this.response, .bad_request, "'mentions' is too long");
            }

            this.content = .{
                .content = sanitized,
                .embeds_mode = embeds_mode,
                .embeds = embeds,
                .attachments = attachment_ids,
                .mention_user_ids = this.mentions.user_ids.items,
                .mention_role_ids = this.mentions.role_ids.items,
                .mention_everyone = this.mentions.everyone,
            };
        }

        // R7
        if (this.content.?.mention_user_ids.len != 0) {
            // await this.filter_mention_users_task
            {
                if (this.filter_mention_users_task == null) {
                    this.filter_mention_users_task = .from(.init(this.response.allocator, this.db.?, .{
                        .ids = this.content.?.mention_user_ids,
                    }));
                }

                while (this.filter_mention_users_task.?.await()) |res| {
                    return res.discard();
                }

                this.content.?.mention_user_ids = this.filter_mention_users_task.?.result;
            }
        }

        if (this.content.?.mention_role_ids.len != 0) {
            // await this.filter_mention_roles_task
            {
                if (this.filter_mention_roles_task == null) {
                    this.filter_mention_roles_task = .from(.init(this.response.allocator, this.db.?, .{
                        .guild_id = this.message_is_exists_task.?.result.?.guild_id,
                        .ids = this.content.?.mention_role_ids,
                    }));
                }

                while (this.filter_mention_roles_task.?.await()) |res| {
                    return res.discard();
                }

                this.content.?.mention_role_ids = this.filter_mention_roles_task.?.result;
            }
        }

        // R6
        if (this.content.?.attachments.len != 0) {
            // await this.count_attachments_task
            {
                if (this.count_attachments_task == null) {
                    this.count_attachments_task = .from(.init(this.response.allocator, this.db.?, .{
                        .ids = this.content.?.attachments,
                    }));
                }

                while (this.count_attachments_task.?.await()) |res| {
                    return res.discard();
                }

                if (this.count_attachments_task.?.result != this.content.?.attachments.len) {
                    return root.route.generic.responseErrorMessage(this.response, .bad_request, "'attachments' is invalid");
                }
            }
        }

        // await this.edit_task
        {
            if (this.edit_task == null) {
                this.edit_task = .from(.init(this.response.allocator, this.db.?, .{
                    .id = this.payload.message_id,
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
                    return res.discard();
                }

                root.bus.raise(.{
                    .message_updated = .{
                        .id = this.payload.message_id,
                        .channel_id = this.message_is_exists_task.?.result.?.channel_id,
                        .guild_id = this.message_is_exists_task.?.result.?.guild_id,
                    },
                });
            }
        }

        // Read the edited message back so the caller gets the canonical object
        // (with resolved attachments); computed with the author as reaction `me`.
        if (this.message == null) {
            if (this.get_message_task == null) {
                this.get_message_task = .from(.init(
                    this.response.allocator,
                    this.db.?,
                    .{
                        .id = this.payload.message_id,
                        .me_user_id = this.bearer_middleware_task.?.result.?,
                    },
                ));
            }

            while (this.get_message_task.?.await()) |res| {
                return res.discard();
            }

            this.message = this.get_message_task.?.result;
        }

        if (this.body == null) {
            const message = this.message orelse {
                SCOPE.err("PATCH edit task returned no message", .{});

                return .{ .err = error.Unexpected };
            };

            const response = root.route.types.Message.fromRepo(this.response.allocator, message) catch |err| {
                SCOPE.err("PATCH failed to build the response message: {t}", .{err});

                return .{ .err = err };
            };

            var writer: std.Io.Writer.Allocating = .init(this.response.allocator);

            std.json.fmt(response, .{}).format(&writer.writer) catch |err| {
                SCOPE.err("PATCH failed to serialize the response: {t}", .{err});

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

        return this.streamer.?.poll();
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *PatchTask = @ptrCast(@alignCast(ctx));

        if (this.bearer_middleware_task) |*t| {
            t.dispose();
            this.bearer_middleware_task = null;
        }

        if (this.message_is_exists_task) |*t| {
            t.dispose();
            this.message_is_exists_task = null;
        }

        if (this.check_user_channel_rights_task) |*t| {
            t.dispose();
            this.check_user_channel_rights_task = null;
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

        if (this.db) |db| {
            db.release();
            this.db = null;
        }
    }

    pub inline fn task(
        request: *const root.http.Request,
        response: *root.http.Response,
        payload: Payload,
    ) !Task {
        const this = try response.allocator.create(PatchTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .request = request,
            .response = response,
            .payload = payload,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// PATCH /api/messages/{message_id}
/// R1 - content type must be application/json (415) and body non-empty (400)
pub inline fn patchHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    message_id: root.types.MessageId,
) !PatchTask.Task {
    _ = allocator;

    // R1
    if (request.getContentLength() == 0) {
        return try root.route.generic.badRequestTask(response);
    }

    // R1
    if (!root.utils.startsWithMaybe(u8, request.content_type, "application/json")) {
        return try root.route.generic.unsupportedMediaTypeTask(response);
    }

    return try PatchTask.task(request, response, .{
        .message_id = message_id,
    });
}
