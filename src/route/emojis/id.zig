// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../root.zig");

pub const icon = @import("id/icon.zig");

const SCOPE = std.log.scoped(.@"/api/emojis/{emoji_id}");

/// R1 - content type must be application/json (415) and body non-empty (400) (see patchHandle)
/// R2 - user must be logged (bearer); deleted users are rejected
/// R3 - the emoji must exist (404 "Emoji not found")
/// R4 - body must be valid JSON and an object ("Bad JSON" / "Expected an object")
/// R5 - "name" must be present, a string, NFKC-normalize to the emoji name
///      allowlist (`a-z`, `0-9`, `_`) and be within
///      api.emojis.min_name_codepoints .. api.emojis.max_name_codepoints codepoints;
///      the normalized form is stored (400 "Nothing to update" / "'name' is not a
///      string" / "'name' is too short" / "'name' is invalid" / "'name' is too long");
///      an explicit null is a type error because the name is not nullable
/// R6 - user must have modify_emoji rights (403 "Missing permissions")
/// R7 - the emoji is renamed and the request succeeds with 204 No Content;
///      a duplicate (guild, name) is 409 "Emoji name is already used";
///      a rename raced with a deletion is 404 "Emoji not found";
///      dispatches an emoji_updated gateway event
const PatchTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        emoji_id: root.types.EmojiId,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    get_emoji_task: ?root.repo.emojis.Get.Lazy = null,
    name: ?[]const u8 = null,
    check_user_guild_rights_task: ?root.repo.rights.CheckUserGuildRights.Lazy = null,
    rename_emoji_task: ?root.repo.emojis.Rename.Lazy = null,
    event_raised: bool = false,
    audit_log: ?root.repo.audit_log.Insert.Lazy = null,
    audit_entries: [1]root.repo.audit_log.Insert.Entry = undefined,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *PatchTask = @ptrCast(@alignCast(ctx));

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
        // await this.get_emoji_task
        {
            if (this.get_emoji_task == null) {
                this.get_emoji_task = .from(.init(this.db.?, .{
                    .id = this.payload.emoji_id,
                }));
            }

            while (this.get_emoji_task.?.await()) |res| {
                return res.discard();
            }

            if (this.get_emoji_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Emoji not found");
            }
        }

        // R4, R5
        if (this.name == null) {
            if (!this.request.contentIsAvailable()) {
                return .{ .pending = .want_read };
            }

            // R4
            const root_value = std.json.parseFromSliceLeaky(std.json.Value, this.response.allocator, this.request.getContent(), .{}) catch {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad JSON");

                return .ready;
            };

            // R4
            if (root_value != .object) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Expected an object");

                return .ready;
            }

            // R5
            const name_value = root_value.object.get("name") orelse {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Nothing to update");

                return .ready;
            };

            // R5
            if (name_value != .string) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is not a string");

                return .ready;
            }

            // R5
            const name = root.unicode.normalize(this.response.allocator, name_value.string) catch |err| switch (err) {
                error.InvalidUtf8 => return root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is invalid"),
                error.OutOfMemory => return .{ .err = error.OutOfMemory },
            };

            const codepoints = std.unicode.utf8CountCodepoints(name) catch unreachable;

            // R5
            if (codepoints < root.options.api.emojis.min_name_codepoints) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is too short");

                return .ready;
            }

            // R5
            if (!root.utils.isAsciiEmojiNameFormat(name)) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is invalid");

                return .ready;
            }

            // R5
            if (codepoints > root.options.api.emojis.max_name_codepoints) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is too long");

                return .ready;
            }

            this.name = name;
        }

        // R6
        // await this.check_user_guild_rights_task
        {
            if (this.check_user_guild_rights_task == null) {
                this.check_user_guild_rights_task = .from(.init(this.db.?, .{
                    .guild_id = this.get_emoji_task.?.result.?.guild_id,
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .required = .{ .modify_emoji = true },
                }));
            }

            while (this.check_user_guild_rights_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.check_user_guild_rights_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
            }
        }

        // R7
        // await this.rename_emoji_task
        {
            if (this.rename_emoji_task == null) {
                this.rename_emoji_task = .from(.init(this.db.?, .{
                    .id = this.payload.emoji_id,
                    .name = this.name.?,
                }));
            }

            while (this.rename_emoji_task.?.await()) |res| {
                return res.discard();
            }

            switch (this.rename_emoji_task.?.result) {
                .ok => {},
                .not_found => return root.route.generic.responseErrorMessage(this.response, .not_found, "Emoji not found"),
                .name_taken => return root.route.generic.responseErrorMessage(this.response, .conflict, "Emoji name is already used"),
            }
        }

        if (!this.event_raised) {
            this.event_raised = true;

            root.bus.raise(.{
                .emoji_updated = .{
                    .id = this.payload.emoji_id,
                    .guild_id = this.get_emoji_task.?.result.?.guild_id,
                },
            });
        }

        // await this.audit_log
        {
            if (this.audit_log == null) {
                this.audit_entries[0] = .{
                    .action = .emoji_name_update,
                    .target_id = this.payload.emoji_id,
                };

                this.audit_log = .from(root.repo.audit_log.Insert.init(this.db.?, this.response.allocator, .{
                    .guild_id = this.get_emoji_task.?.result.?.guild_id,
                    .actor_id = this.bearer_middleware_task.?.result.?,
                    .entries = this.audit_entries[0..1],
                }));
            }

            while (this.audit_log.?.await()) |res| {
                return res.discard();
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
        const this: *PatchTask = @ptrCast(@alignCast(ctx));

        if (this.bearer_middleware_task) |*t| {
            t.dispose();
            this.bearer_middleware_task = null;
        }

        if (this.get_emoji_task) |*t| {
            t.dispose();
            this.get_emoji_task = null;
        }

        if (this.check_user_guild_rights_task) |*t| {
            t.dispose();
            this.check_user_guild_rights_task = null;
        }

        if (this.rename_emoji_task) |*t| {
            t.dispose();
            this.rename_emoji_task = null;
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

/// PATCH /api/emojis/{emoji_id}
/// R1 - content type must be application/json (415) and body non-empty (400) (see the R-list above PatchTask)
pub inline fn patchHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    emoji_id: root.types.EmojiId,
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
        .emoji_id = emoji_id,
    });
}

/// R1 - user must be logged (bearer); deleted users are rejected
/// R2 - the emoji must exist; a deletion raced with another request is also 404
///      "Emoji not found"
/// R3 - user must have delete_emoji rights (403 "Missing permissions")
/// R4 - the emoji is deleted and the request succeeds with 204 No Content;
///      dispatches an emoji_deleted gateway event
const DeleteTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        emoji_id: root.types.EmojiId,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    get_emoji_task: ?root.repo.emojis.Get.Lazy = null,
    check_user_guild_rights_task: ?root.repo.rights.CheckUserGuildRights.Lazy = null,
    delete_emoji_task: ?root.repo.emojis.Delete.Lazy = null,
    event_raised: bool = false,
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
        // await this.get_emoji_task
        {
            if (this.get_emoji_task == null) {
                this.get_emoji_task = .from(.init(this.db.?, .{
                    .id = this.payload.emoji_id,
                }));
            }

            while (this.get_emoji_task.?.await()) |res| {
                return res.discard();
            }

            if (this.get_emoji_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Emoji not found");
            }
        }

        // R3
        // await this.check_user_guild_rights_task
        {
            if (this.check_user_guild_rights_task == null) {
                this.check_user_guild_rights_task = .from(.init(this.db.?, .{
                    .guild_id = this.get_emoji_task.?.result.?.guild_id,
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .required = .{
                        .delete_emoji = true,
                    },
                }));
            }

            while (this.check_user_guild_rights_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.check_user_guild_rights_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
            }
        }

        // await this.delete_emoji_task
        {
            if (this.delete_emoji_task == null) {
                this.delete_emoji_task = .from(.init(this.db.?, .{
                    .id = this.payload.emoji_id,
                }));
            }

            while (this.delete_emoji_task.?.await()) |res| {
                return res.discard();
            }

            // R2 (raced with deletion)
            if (this.delete_emoji_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Emoji not found");
            }
        }

        // R4
        if (!this.event_raised) {
            this.event_raised = true;

            root.bus.raise(.{
                .emoji_deleted = .{
                    .id = this.payload.emoji_id,
                    .guild_id = this.get_emoji_task.?.result.?.guild_id,
                },
            });
        }

        // await this.audit_log
        {
            if (this.audit_log == null) {
                this.audit_entries[0] = .{
                    .action = .emoji_delete,
                    .target_id = this.payload.emoji_id,
                };

                this.audit_log = .from(root.repo.audit_log.Insert.init(this.db.?, this.response.allocator, .{
                    .guild_id = this.get_emoji_task.?.result.?.guild_id,
                    .actor_id = this.bearer_middleware_task.?.result.?,
                    .entries = this.audit_entries[0..1],
                }));
            }

            while (this.audit_log.?.await()) |res| {
                return res.discard();
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

        if (this.get_emoji_task) |*t| {
            t.dispose();
            this.get_emoji_task = null;
        }

        if (this.check_user_guild_rights_task) |*t| {
            t.dispose();
            this.check_user_guild_rights_task = null;
        }

        if (this.delete_emoji_task) |*t| {
            t.dispose();
            this.delete_emoji_task = null;
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

/// DELETE /api/emojis/{emoji_id}
/// R1 - user must be logged (see the R-list above DeleteTask)
pub inline fn deleteHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    emoji_id: root.types.EmojiId,
) !DeleteTask.Task {
    _ = allocator;

    return try DeleteTask.task(request, response, .{
        .emoji_id = emoji_id,
    });
}
