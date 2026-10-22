// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../../root.zig");

const SCOPE = std.log.scoped(.@"/api/messages/{message_id}/reactions");

const MAX_UNICODE_EMOJI_BYTES = root.types.MAX_UNICODE_EMOJI_BYTES;

inline fn fillUnicode(buf: *[MAX_UNICODE_EMOJI_BYTES]u8, text: ?[]const u8) u8 {
    const t = text orelse return 0;

    const n = @min(t.len, buf.len);
    @memcpy(buf[0..n], t[0..n]);

    return @intCast(n);
}

/// Returns the canonical form of a reaction target, or `null` when it is not
/// exactly one emoji sequence. A unicode target is normalized to its
/// fully-qualified RGI sequence (`root.unicode.canonicalReactionEmoji`), so a
/// bare heart, a heart with U+FE0F and any other qualification form are stored
/// and looked up as one reaction; a lone regional indicator is kept as-is. A
/// custom target is canonical by definition (the caller checks guild
/// membership).
inline fn canonicalizeEmoji(
    emoji: root.repo.reactions.Emoji,
) ?root.repo.reactions.Emoji {
    switch (emoji) {
        .unicode => |text| {
            if (text.len > MAX_UNICODE_EMOJI_BYTES) {
                return null;
            }

            return .{ .unicode = root.unicode.canonicalReactionEmoji(text) orelse return null };
        },
        .custom => return emoji,
    }
}

/// GET /api/messages/{message_id}/reactions/users
/// R1 - user must be logged (bearer); deleted users are rejected
/// R2 - the message must exist (404 "Message not found")
/// R3 - user must have read_messages on the message's channel
/// R4 - a custom "emoji_id" must name an existing emoji of the message's guild
///      (400 "'emoji_id' is invalid")
/// R5 - responds 200 with the ids (decimal strings, ascending) of the
///      non-deleted users who reacted with the requested emoji, at most `limit`
///      of them and strictly greater than `after`; an empty array when nobody did
const GetUsersTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        message_id: root.types.MessageId,
        emoji: root.repo.reactions.Emoji,
        after: ?root.types.UserId,
        limit: usize,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    message_is_exists_task: ?root.repo.messages.IsExists.Lazy = null,
    check_user_channel_rights_task: ?root.repo.rights.CheckUserChannelRights.Lazy = null,
    get_emoji_task: ?root.repo.emojis.Get.Lazy = null,
    get_users_task: ?root.repo.reactions.GetUsers.Lazy = null,
    result: std.ArrayList([]const u8) = .empty,
    body: ?[]const u8 = null,
    streamer: ?root.http.Response.Streamer = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *GetUsersTask = @ptrCast(@alignCast(ctx));

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

        // R4 (custom: the emoji must exist and belong to the message's guild)
        if (this.payload.emoji == .custom) {
            // await this.get_emoji_task
            {
                if (this.get_emoji_task == null) {
                    this.get_emoji_task = .from(.init(this.db.?, .{
                        .id = this.payload.emoji.custom,
                    }));
                }

                while (this.get_emoji_task.?.await()) |res| {
                    return res.discard();
                }

                if (this.get_emoji_task.?.result == null or
                    this.get_emoji_task.?.result.?.guild_id != this.message_is_exists_task.?.result.?.guild_id)
                {
                    return root.route.generic.responseErrorMessage(this.response, .bad_request, "'emoji_id' is invalid");
                }
            }
        }

        // R5
        // await this.get_users_task
        {
            if (this.get_users_task == null) {
                this.get_users_task = .from(.init(this.response.allocator, this.db.?, .{
                    .message_id = this.payload.message_id,
                    .emoji = this.payload.emoji,
                    .after = this.payload.after,
                    .limit = this.payload.limit,
                }));
            }

            while (!this.get_users_task.?.done) {
                if (this.get_users_task.?.await()) |res| {
                    return res.discard();
                }

                for (this.get_users_task.?.result) |user_id| {
                    const id = std.fmt.allocPrint(this.response.allocator, "{}", .{user_id}) catch |err| {
                        SCOPE.err("GET users failed to stringify 'id': {t}", .{err});

                        return .{ .err = err };
                    };

                    this.result.append(this.response.allocator, id) catch |err| {
                        SCOPE.err("GET users failed to append an item: {t}", .{err});

                        return .{ .err = err };
                    };
                }
            }
        }

        if (this.body == null) {
            var writer: std.Io.Writer.Allocating = .init(this.response.allocator);

            std.json.fmt(this.result.items, .{}).format(&writer.writer) catch |err| {
                SCOPE.err("GET users failed to serialize the response: {t}", .{err});

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
        const this: *GetUsersTask = @ptrCast(@alignCast(ctx));

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

        if (this.get_emoji_task) |*t| {
            t.dispose();
            this.get_emoji_task = null;
        }

        if (this.get_users_task) |*t| {
            t.dispose();
            this.get_users_task = null;
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
        const this = try response.allocator.create(GetUsersTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .request = request,
            .response = response,
            .payload = payload,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// GET /api/messages/{message_id}/reactions/users
/// R5 - the emoji target is supplied by query params: exactly one of "emoji_id"
///      or "unicode_emoji" must be present and "limit" (optional, default 50)
///      must be > 0 and <= root.options.api.messages.max_reactions_users_limit
///      (400 "Unknown parameter" / "Bad 'limit' parameter" /
///      "Bad 'after' parameter" /
///      "Specify exactly one of 'emoji_id' or 'unicode_emoji'" /
///      "'emoji_id' is invalid" / "'unicode_emoji' is invalid"). A unicode
///      target is canonicalized to its fully-qualified RGI sequence before
///      matching, so every qualification form addresses the same reaction.
pub inline fn usersGetHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    message_id: root.types.MessageId,
) !root.http.Task {
    _ = allocator;

    var emoji_id: ?root.types.EmojiId = null;
    var unicode: ?[]const u8 = null;
    var after: ?root.types.UserId = null;
    var limit: ?usize = null;

    for (request.params) |kvp| {
        if (std.mem.eql(u8, kvp.key, "emoji_id")) {
            emoji_id = std.fmt.parseInt(root.types.EmojiId, kvp.value, 10) catch {
                return try root.route.generic.badRequestReasonTask(response, "'emoji_id' is invalid");
            };
        } else if (std.mem.eql(u8, kvp.key, "unicode_emoji")) {
            unicode = kvp.value;
        } else if (std.mem.eql(u8, kvp.key, "after")) {
            after = std.fmt.parseInt(root.types.UserId, kvp.value, 10) catch {
                return try root.route.generic.badRequestReasonTask(response, "Bad 'after' parameter");
            };
        } else if (std.mem.eql(u8, kvp.key, "limit")) {
            limit = std.fmt.parseInt(usize, kvp.value, 10) catch {
                return try root.route.generic.badRequestReasonTask(response, "Bad 'limit' parameter");
            };

            // R5
            if (limit.? == 0 or limit.? > root.options.api.messages.max_reactions_users_limit) {
                return try root.route.generic.badRequestReasonTask(response, "Bad 'limit' parameter");
            }
        } else {
            return try root.route.generic.badRequestReasonTask(response, "Unknown parameter");
        }
    }

    if ((emoji_id == null) == (unicode == null)) {
        return try root.route.generic.badRequestReasonTask(response, "Specify exactly one of 'emoji_id' or 'unicode_emoji'");
    }

    const emoji: root.repo.reactions.Emoji = if (emoji_id) |id|
        .{ .custom = id }
    else
        canonicalizeEmoji(.{ .unicode = unicode.? }) orelse
            return try root.route.generic.badRequestReasonTask(response, "'unicode_emoji' is invalid");

    return try GetUsersTask.task(request, response, .{
        .message_id = message_id,
        .emoji = emoji,
        .after = after,
        .limit = limit orelse 50,
    });
}

/// PUT /api/messages/{message_id}/reactions
/// R1 - content type must be application/json (415) and body non-empty (400) (see putHandle)
/// R2 - user must be logged (bearer); deleted users are rejected
/// R3 - the message must exist (404 "Message not found")
/// R4 - user must have read_messages and add_reactions on the message's channel
/// R5 - the body must be valid JSON and an object ("Bad JSON" / "Expected an object")
/// R6 - exactly one of "emoji_id" / "unicode_emoji" must be present and a string
///      (400 "Specify exactly one of 'emoji_id' or 'unicode_emoji'" /
///      "'emoji_id' is not a string" / "'unicode_emoji' is not a string")
/// R7 - a custom "emoji_id" must parse as a snowflake and name an existing
///      emoji of the message's guild (400 "'emoji_id' is invalid")
/// R8 - a "unicode_emoji" must be exactly one emoji sequence in any
///      qualification form (fully-qualified, minimally-qualified, unqualified)
///      or one regional indicator symbol, encoded in at most
///      root.types.MAX_UNICODE_EMOJI_BYTES bytes; it is stored in its
///      canonical fully-qualified form
///      (400 "'unicode_emoji' is invalid")
/// R9 - adding a new distinct emoji is rejected once the message already holds
///      api.messages.max_reactions distinct emoji (400 "Too many reactions")
/// R10 - the reaction is added (idempotent) and the request succeeds with
///       204 No Content; a newly inserted reaction dispatches a
///       reaction_added gateway event
const PutTask = struct {
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
    emoji: ?root.repo.reactions.Emoji = null,
    get_emoji_task: ?root.repo.emojis.Get.Lazy = null,
    get_stats_task: ?root.repo.reactions.GetStats.Lazy = null,
    add_task: ?root.repo.reactions.Add.Lazy = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *PutTask = @ptrCast(@alignCast(ctx));

        if (this.db == null) {
            this.db = root.db_pool.rent() orelse {
                return .{ .pending = .db };
            };
        }

        // R2
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

        // R3
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

        // R4
        // await this.check_user_channel_rights_task
        {
            if (this.check_user_channel_rights_task == null) {
                this.check_user_channel_rights_task = .from(.init(this.db.?, .{
                    .guild_id = this.message_is_exists_task.?.result.?.guild_id,
                    .channel_id = this.message_is_exists_task.?.result.?.channel_id,
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .required = .{ .read_messages = true, .add_reactions = true },
                }));
            }

            while (this.check_user_channel_rights_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.check_user_channel_rights_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
            }
        }

        // R5, R6, R7, R8
        if (this.emoji == null) {
            if (!this.request.contentIsAvailable()) {
                return .{ .pending = .want_read };
            }

            // R5
            const root_value = std.json.parseFromSliceLeaky(std.json.Value, this.response.allocator, this.request.getContent(), .{}) catch {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad JSON");

                return .ready;
            };

            // R5
            if (root_value != .object) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Expected an object");

                return .ready;
            }

            const emoji_id_value = root_value.object.get("emoji_id");
            const unicode_value = root_value.object.get("unicode_emoji");

            // R6
            if ((emoji_id_value == null) == (unicode_value == null)) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Specify exactly one of 'emoji_id' or 'unicode_emoji'");

                return .ready;
            }

            if (emoji_id_value) |value| {
                // R6
                if (value != .string) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'emoji_id' is not a string");

                    return .ready;
                }

                // R7
                const emoji_id = std.fmt.parseInt(root.types.EmojiId, value.string, 10) catch {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'emoji_id' is invalid");

                    return .ready;
                };

                this.emoji = .{ .custom = emoji_id };
            } else {
                const value = unicode_value.?;

                // R6
                if (value != .string) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'unicode_emoji' is not a string");

                    return .ready;
                }

                // R8
                this.emoji = canonicalizeEmoji(.{ .unicode = value.string }) orelse {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'unicode_emoji' is invalid");

                    return .ready;
                };
            }
        }

        // R7 (custom)
        if (this.emoji != null and this.emoji.? == .custom) {
            // await this.get_emoji_task
            {
                if (this.get_emoji_task == null) {
                    this.get_emoji_task = .from(.init(this.db.?, .{
                        .id = this.emoji.?.custom,
                    }));
                }

                while (this.get_emoji_task.?.await()) |res| {
                    return res.discard();
                }

                if (this.get_emoji_task.?.result == null or
                    this.get_emoji_task.?.result.?.guild_id != this.message_is_exists_task.?.result.?.guild_id)
                {
                    return root.route.generic.responseErrorMessage(this.response, .bad_request, "'emoji_id' is invalid");
                }
            }
        }

        // R9
        // await this.get_stats_task
        {
            if (this.get_stats_task == null) {
                this.get_stats_task = .from(.init(this.db.?, .{
                    .message_id = this.payload.message_id,
                    .emoji = this.emoji.?,
                }));
            }

            while (this.get_stats_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.get_stats_task.?.result.present and
                this.get_stats_task.?.result.distinct >= root.options.api.messages.max_reactions)
            {
                return root.route.generic.responseErrorMessage(this.response, .bad_request, "Too many reactions");
            }
        }

        // R10
        // await this.add_task
        {
            if (this.add_task == null) {
                this.add_task = .from(.init(this.db.?, .{
                    .message_id = this.payload.message_id,
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .emoji = this.emoji.?,
                }));
            }

            while (!this.add_task.?.done) {
                if (this.add_task.?.await()) |res| {
                    return res.discard();
                }

                if (this.add_task.?.result) {
                    const emoji = this.emoji.?;

                    var unicode_buf: [MAX_UNICODE_EMOJI_BYTES]u8 = undefined;
                    const unicode_len = fillUnicode(&unicode_buf, if (emoji == .unicode) emoji.unicode else null);

                    root.bus.raise(.{
                        .reaction_added = .{
                            .message_id = this.payload.message_id,
                            .channel_id = this.message_is_exists_task.?.result.?.channel_id,
                            .guild_id = this.message_is_exists_task.?.result.?.guild_id,
                            .user_id = this.bearer_middleware_task.?.result.?,
                            .emoji_kind = root.repo.reactions.emojiKind(emoji),
                            .emoji_id = if (emoji == .custom) emoji.custom else null,
                            .unicode_emoji = unicode_buf,
                            .unicode_emoji_len = unicode_len,
                        },
                    });
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
        const this: *PutTask = @ptrCast(@alignCast(ctx));

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

        if (this.get_emoji_task) |*t| {
            t.dispose();
            this.get_emoji_task = null;
        }

        if (this.get_stats_task) |*t| {
            t.dispose();
            this.get_stats_task = null;
        }

        if (this.add_task) |*t| {
            t.dispose();
            this.add_task = null;
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
        const this = try response.allocator.create(PutTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .request = request,
            .response = response,
            .payload = payload,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// PUT /api/messages/{message_id}/reactions
/// R1 - content type must be application/json (415) and body non-empty (400) (see the R-list above PutTask)
pub inline fn putHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    message_id: root.types.MessageId,
) !PutTask.Task {
    _ = allocator;

    // R1
    if (request.getContentLength() == 0) {
        return try root.route.generic.badRequestTask(response);
    }

    // R1
    if (!root.utils.startsWithMaybe(u8, request.content_type, "application/json")) {
        return try root.route.generic.unsupportedMediaTypeTask(response);
    }

    return try PutTask.task(request, response, .{
        .message_id = message_id,
    });
}

/// DELETE /api/messages/{message_id}/reactions
/// R1 - user must be logged (bearer); deleted users are rejected
/// R2 - the message must exist (404 "Message not found")
/// R3 - the emoji target is supplied by query params: "emoji_id" XOR
///      "unicode_emoji"; neither means removing all of the caller's reactions.
///      `emoji_id` must parse as a snowflake and name an existing emoji of the
///      message's guild (400 "'emoji_id' is invalid"); a `unicode_emoji` must
///      be exactly one emoji sequence in any qualification form or one regional
///      indicator symbol, canonicalized to its fully-qualified form before
///      matching (400 "'unicode_emoji' is invalid"). Unknown parameters are
///      rejected
///      (400 "Unknown parameter") and both emoji params together are rejected
///      (400 "Specify exactly one of 'emoji_id' or 'unicode_emoji'").
/// R4 - user must have read_messages on the message's channel (403 "Missing
///      permissions"). An optional "user_id" target must parse (400 "Bad
///      'user_id' parameter"); removing someone else's reaction additionally
///      requires delete_reactions on the channel and being strictly higher than
///      the target (403 "Missing permissions").
/// R5 - the reaction(s) are removed (idempotent) and the request succeeds with
///      204 No Content; each removed reaction dispatches a reaction_removed
///      gateway event
const DeleteTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        message_id: root.types.MessageId,
        emoji: ?root.repo.reactions.Emoji,
        target_user_id: ?root.types.UserId,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    message_is_exists_task: ?root.repo.messages.IsExists.Lazy = null,
    get_emoji_task: ?root.repo.emojis.Get.Lazy = null,
    check_user_channel_rights_task: ?root.repo.rights.CheckUserChannelRights.Lazy = null,
    is_higher_than_other_task: ?root.repo.users.IsHigherThanOther.Lazy = null,
    remove_task: ?root.repo.reactions.Remove.Lazy = null,

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

        // R3 (custom: the emoji must exist and belong to the message's guild)
        if (this.payload.emoji != null and this.payload.emoji.? == .custom) {
            // await this.get_emoji_task
            {
                if (this.get_emoji_task == null) {
                    this.get_emoji_task = .from(.init(this.db.?, .{
                        .id = this.payload.emoji.?.custom,
                    }));
                }

                while (this.get_emoji_task.?.await()) |res| {
                    return res.discard();
                }

                if (this.get_emoji_task.?.result == null or
                    this.get_emoji_task.?.result.?.guild_id != this.message_is_exists_task.?.result.?.guild_id)
                {
                    return root.route.generic.responseErrorMessage(this.response, .bad_request, "'emoji_id' is invalid");
                }
            }
        }

        const caller_id = this.bearer_middleware_task.?.result.?;
        const target_user_id = this.payload.target_user_id orelse caller_id;

        // R4
        var required: root.types.Permissions = .{ .read_messages = true };
        if (target_user_id != caller_id) {
            required.delete_reactions = true;
        }

        // R4
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

        // R4
        if (target_user_id != caller_id) {
            // await this.is_higher_than_other_task
            {
                if (this.is_higher_than_other_task == null) {
                    this.is_higher_than_other_task = .from(.init(this.db.?, .{
                        .guild_id = this.message_is_exists_task.?.result.?.guild_id,
                        .user_a_id = caller_id,
                        .user_b_id = target_user_id,
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

        // R5
        // await this.remove_task
        {
            if (this.remove_task == null) {
                this.remove_task = .from(.init(this.response.allocator, this.db.?, .{
                    .message_id = this.payload.message_id,
                    .user_id = target_user_id,
                    .emoji = this.payload.emoji,
                }));
            }

            while (!this.remove_task.?.done) {
                if (this.remove_task.?.await()) |res| {
                    return res.discard();
                }

                for (this.remove_task.?.result) |item| {
                    var unicode_buf: [MAX_UNICODE_EMOJI_BYTES]u8 = undefined;
                    const unicode_len = fillUnicode(&unicode_buf, item.unicode_emoji);

                    root.bus.raise(.{
                        .reaction_removed = .{
                            .message_id = this.payload.message_id,
                            .channel_id = this.message_is_exists_task.?.result.?.channel_id,
                            .guild_id = this.message_is_exists_task.?.result.?.guild_id,
                            .user_id = target_user_id,
                            .emoji_kind = item.emoji_kind,
                            .emoji_id = item.emoji_id,
                            .unicode_emoji = unicode_buf,
                            .unicode_emoji_len = unicode_len,
                        },
                    });
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

        if (this.get_emoji_task) |*t| {
            t.dispose();
            this.get_emoji_task = null;
        }

        if (this.check_user_channel_rights_task) |*t| {
            t.dispose();
            this.check_user_channel_rights_task = null;
        }

        if (this.is_higher_than_other_task) |*t| {
            t.dispose();
            this.is_higher_than_other_task = null;
        }

        if (this.remove_task) |*t| {
            t.dispose();
            this.remove_task = null;
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

/// DELETE /api/messages/{message_id}/reactions
/// R3 - only "emoji_id", "unicode_emoji" and "user_id" are accepted; at most
///      one of the emoji params may be present (400 "Unknown parameter" /
///      "Specify exactly one of 'emoji_id' or 'unicode_emoji'" /
///      "Bad 'user_id' parameter" / "'emoji_id' is invalid" /
///      "'unicode_emoji' is invalid")
pub inline fn deleteHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    message_id: root.types.MessageId,
) !root.http.Task {
    _ = allocator;

    var emoji_id: ?root.types.EmojiId = null;
    var unicode: ?[]const u8 = null;
    var target_user_id: ?root.types.UserId = null;

    for (request.params) |kvp| {
        if (std.mem.eql(u8, kvp.key, "emoji_id")) {
            emoji_id = std.fmt.parseInt(root.types.EmojiId, kvp.value, 10) catch {
                return try root.route.generic.badRequestReasonTask(response, "'emoji_id' is invalid");
            };
        } else if (std.mem.eql(u8, kvp.key, "unicode_emoji")) {
            unicode = kvp.value;
        } else if (std.mem.eql(u8, kvp.key, "user_id")) {
            target_user_id = std.fmt.parseInt(root.types.UserId, kvp.value, 10) catch {
                return try root.route.generic.badRequestReasonTask(response, "Bad 'user_id' parameter");
            };
        } else {
            return try root.route.generic.badRequestReasonTask(response, "Unknown parameter");
        }
    }

    // R3
    if (emoji_id != null and unicode != null) {
        return try root.route.generic.badRequestReasonTask(response, "Specify exactly one of 'emoji_id' or 'unicode_emoji'");
    }

    const emoji: ?root.repo.reactions.Emoji = if (emoji_id) |id|
        .{ .custom = id }
    else if (unicode) |text|
        // R3
        canonicalizeEmoji(.{ .unicode = text }) orelse
            return try root.route.generic.badRequestReasonTask(response, "'unicode_emoji' is invalid")
    else
        null;

    return try DeleteTask.task(request, response, .{
        .message_id = message_id,
        .emoji = emoji,
        .target_user_id = target_user_id,
    });
}
