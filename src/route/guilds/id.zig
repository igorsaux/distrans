// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../root.zig");
pub const audit_log = @import("id/audit_log.zig");
pub const avatar = @import("id/avatar.zig");
pub const channels = @import("id/channels.zig");
pub const emojis = @import("id/emojis.zig");
pub const members = @import("id/members.zig");
pub const messages = @import("id/messages.zig");
pub const roles = @import("id/roles.zig");
pub const sync = @import("id/sync.zig");

/// R1 - content type must be application/json (415) and body non-empty (400)
/// R2 - user must be logged (bearer); deleted users are rejected
/// R3 - the guild must exist (404 "Guild not found")
/// R4 - user must have guild_modify rights (403 "Missing permissions")
/// R5 - the body must be a JSON object with at least one recognized field ("name");
///      otherwise 400 "Nothing to update"
/// R6 - "name" must be a string, not too long and contain no forbidden codepoints
///      (400 "'name' is not a string" / "'name' is too long" / "'name' is invalid")
const PatchTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        guild_id: root.types.GuildId,
    };

    const Content = struct {
        name: ?[]const u8 = null,
        name_set: bool = false,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    guild_exists_task: ?root.repo.guilds.Exists.Lazy = null,
    check_user_guild_rights_task: ?root.repo.rights.CheckUserGuildRights.Lazy = null,
    content: ?Content = null,
    guild_update_task: ?root.repo.guilds.Update.Lazy = null,
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
        // await this.guild_exists_task
        {
            if (this.guild_exists_task == null) {
                this.guild_exists_task = .from(.init(this.db.?, .{
                    .id = this.payload.guild_id,
                }));
            }

            while (this.guild_exists_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.guild_exists_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Guild not found");
            }
        }

        // R4
        // await this.check_user_guild_rights_task
        {
            if (this.check_user_guild_rights_task == null) {
                this.check_user_guild_rights_task = .from(.init(this.db.?, .{
                    .required = .{
                        .guild_modify = true,
                    },
                    .guild_id = this.payload.guild_id,
                    .user_id = this.bearer_middleware_task.?.result.?,
                }));
            }

            while (this.check_user_guild_rights_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.check_user_guild_rights_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
            }
        }

        // R5, R6
        if (this.content == null) {
            if (!this.request.contentIsAvailable()) {
                return .{ .pending = .want_read };
            }

            const root_value = std.json.parseFromSliceLeaky(std.json.Value, this.response.allocator, this.request.getContent(), .{}) catch {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad JSON");

                return .ready;
            };

            if (root_value != .object) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Expected an object");

                return .ready;
            }

            var content: Content = .{};

            // R6
            if (root_value.object.get("name")) |name_value| {
                if (name_value != .string) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is not a string");

                    return .ready;
                }

                // R6
                const name = root.unicode.normalize(this.response.allocator, name_value.string) catch |err| switch (err) {
                    error.InvalidUtf8 => return root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is invalid"),
                    error.OutOfMemory => return .{ .err = error.OutOfMemory },
                };

                if (std.unicode.utf8CountCodepoints(name) catch unreachable >
                    root.options.api.guilds.max_name_codepoints)
                {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is too long");

                    return .ready;
                }

                // R6
                if ((root.unicode.findForbiddenCodepoint(.name, name) catch null) != null) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is invalid");

                    return .ready;
                }

                content.name = name;
                content.name_set = true;
            }

            // R5
            if (!content.name_set) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Nothing to update");

                return .ready;
            }

            this.content = content;
        }

        // await this.guild_update_task
        {
            if (this.guild_update_task == null) {
                this.guild_update_task = .from(.init(this.db.?, .{
                    .guild_id = this.payload.guild_id,
                    .name = this.content.?.name,
                    .name_set = this.content.?.name_set,
                }));
            }

            while (this.guild_update_task.?.await()) |res| {
                return res.discard();
            }

            if (this.guild_update_task.?.result == null) {
                // R3 (raced with deletion)
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Guild not found");
            }
        }

        if (!this.event_raised) {
            this.event_raised = true;

            root.bus.raise(.{
                .guild_updated = .{
                    .id = this.payload.guild_id,
                },
            });
        }

        // await this.audit_log
        {
            if (this.audit_log == null) {
                this.audit_entries[0] = .{
                    .action = .guild_name_update,
                };

                this.audit_log = .from(root.repo.audit_log.Insert.init(this.db.?, this.response.allocator, .{
                    .guild_id = this.payload.guild_id,
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

        if (this.guild_exists_task) |*t| {
            t.dispose();
            this.guild_exists_task = null;
        }

        if (this.check_user_guild_rights_task) |*t| {
            t.dispose();
            this.check_user_guild_rights_task = null;
        }

        if (this.guild_update_task) |*t| {
            t.dispose();
            this.guild_update_task = null;
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

/// PATCH /api/guilds/{guild_id}
/// R1 - content type must be application/json (415) and body non-empty (400) (see the R-list above PatchTask)
pub inline fn patchHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    guild_id: root.types.GuildId,
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
        .guild_id = guild_id,
    });
}
