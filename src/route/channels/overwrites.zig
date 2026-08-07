// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../root.zig");

const SCOPE = std.log.scoped(.@"/api/channels/{channel_id}/overwrites");

/// R1 - content type must be application/json (415) and body non-empty (400)
/// R2 - user must be logged (401, bearer middleware)
/// R3 - the channel exists (404 "Channel not found")
/// R4 - user has manage_overwrites on the channel (403 "Missing permissions")
/// R5 - body is an object with "target_id" (decimal string), "type"
///      ("role"|"member"), "allow"/"deny" (decimal strings, no reserved
///      bits); 400 "'<field>' is missing" / "'<field>' is not a string" /
///      "'<field>' is invalid"
/// R6 - the target exists: role → 404 "Role not found", member (incl.
///      soft-deleted) → 404 "User not found"
/// R7 - idempotent no-op: identical allow+deny → 204 without changes
///      (checked before hierarchy)
/// R8 - target hierarchy (403 "Missing permissions"): member target must be
///      strictly below the caller's highest position, self-overwrites are
///      always allowed (even with no roles); role target position strictly
///      below the caller's highest position; positions are re-read on every
///      operation
/// R9 - changed-bits subset rule (403 "Missing permissions"): every bit
///      flipped by the request (XOR of old/new allow and deny; all set
///      allow|deny bits when creating) must be present in the caller's
///      channel permissions
/// R10 - apply: allow=0 && deny=0 → remove the row, otherwise upsert; 204
const PutTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        channel_id: root.types.ChannelId,
    };

    pub const Content = struct {
        target: root.types.Overwrites.Target,
        overwrites: root.types.Overwrites,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    channel_exists_task: ?root.repo.channels.IsExists.Lazy = null,
    get_user_channel_permissions_task: ?root.repo.rights.GetUserChannelPermissions.Lazy = null,
    content: ?Content = null,
    get_channel_overwrite_task: ?root.repo.channels.GetOverwrite.Lazy = null,
    check_member_target_task: ?root.repo.users.CheckMemberTarget.Lazy = null,
    get_role_and_caller_position_task: ?root.repo.roles.GetRoleAndCallerPosition.Lazy = null,
    remove_overwrite_task: ?root.repo.channels.RemoveOverwrite.Lazy = null,
    set_overwrite_task: ?root.repo.channels.SetOverwrite.Lazy = null,
    audit_log: ?root.repo.audit_log.Insert.Lazy = null,
    audit_entries: [1]root.repo.audit_log.Insert.Entry = undefined,

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

        const db = this.db.?;

        // R3
        // await this.channel_exists_task
        {
            if (this.channel_exists_task == null) {
                this.channel_exists_task = .from(.init(db, .{
                    .channel_id = this.payload.channel_id,
                }));
            }

            while (this.channel_exists_task.?.await()) |res| {
                return res.discard();
            }

            if (this.channel_exists_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Channel not found");
            }
        }

        const guild_id = this.channel_exists_task.?.result.?.guild_id;

        // R4
        // await this.get_user_channel_permissions_task
        {
            if (this.get_user_channel_permissions_task == null) {
                this.get_user_channel_permissions_task = .from(.init(db, .{
                    .guild_id = guild_id,
                    .channel_id = this.payload.channel_id,
                    .user_id = this.bearer_middleware_task.?.result.?,
                }));
            }

            while (this.get_user_channel_permissions_task.?.await()) |res| {
                return res.discard();
            }

            // R4 (the guild and the caller are known to exist at this point,
            // so a missing mask can only mean "no permissions")
            if (this.get_user_channel_permissions_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
            }
        }

        const my_perms = this.get_user_channel_permissions_task.?.result.?;

        // R4
        if (!my_perms.manage_overwrites) {
            return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
        }

        // R5
        if (this.content == null) {
            if (!this.request.contentIsAvailable()) {
                return .{ .pending = .want_read };
            }

            const root_value = std.json.parseFromSliceLeaky(std.json.Value, this.response.allocator, this.request.getContent(), .{}) catch {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad JSON");

                return .ready;
            };

            // R5
            if (root_value != .object) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Expected an object");

                return .ready;
            }

            // R5
            const target_id_value = root_value.object.get("target_id") orelse {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'target_id' is missing");

                return .ready;
            };

            // R5
            if (target_id_value != .string) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'target_id' is not a string");

                return .ready;
            }

            // R5
            const type_value = root_value.object.get("type") orelse {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'type' is missing");

                return .ready;
            };

            // R5
            if (type_value != .string) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'type' is not a string");

                return .ready;
            }

            // R5
            const allow_value = root_value.object.get("allow") orelse {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'allow' is missing");

                return .ready;
            };

            // R5
            if (allow_value != .string) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'allow' is not a string");

                return .ready;
            }

            // R5
            const deny_value = root_value.object.get("deny") orelse {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'deny' is missing");

                return .ready;
            };

            // R5
            if (deny_value != .string) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'deny' is not a string");

                return .ready;
            }

            // R5
            const allow = root.utils.parsePackedStruct(root.types.Permissions, allow_value.string, 10) catch {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'allow' is invalid");

                return .ready;
            };

            // R5
            if (allow._reserved != 0) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'allow' is invalid");

                return .ready;
            }

            // R5
            const deny = root.utils.parsePackedStruct(root.types.Permissions, deny_value.string, 10) catch {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'deny' is invalid");

                return .ready;
            };

            // R5
            if (deny._reserved != 0) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'deny' is invalid");

                return .ready;
            }

            // R5
            const target: root.types.Overwrites.Target = blk: {
                if (std.mem.eql(u8, type_value.string, @tagName(root.types.Overwrites.Type.role))) {
                    const role_id = std.fmt.parseInt(root.types.RoleId, target_id_value.string, 10) catch {
                        _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'target_id' is invalid");

                        return .ready;
                    };

                    break :blk .{ .role = role_id };
                }

                if (std.mem.eql(u8, type_value.string, @tagName(root.types.Overwrites.Type.member))) {
                    const user_id = std.fmt.parseInt(root.types.UserId, target_id_value.string, 10) catch {
                        _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'target_id' is invalid");

                        return .ready;
                    };

                    break :blk .{ .member = user_id };
                }

                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'type' is invalid");

                return .ready;
            };

            this.content = .{
                .target = target,
                .overwrites = .{ .allow = allow, .deny = deny },
            };
        }

        // R7
        // await this.get_channel_overwrite_task
        {
            if (this.get_channel_overwrite_task == null) {
                this.get_channel_overwrite_task = .from(.init(db, .{
                    .channel_id = this.payload.channel_id,
                    .target = this.content.?.target,
                }));
            }

            while (this.get_channel_overwrite_task.?.await()) |res| {
                return res.discard();
            }
        }

        const new_overwrites = this.content.?.overwrites;

        // R7
        if (this.get_channel_overwrite_task.?.result) |old| {
            if (old.overwrites.allow == new_overwrites.allow and
                old.overwrites.deny == new_overwrites.deny)
            {
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
        }

        // R6, R8
        switch (this.content.?.target) {
            .member => |user_id| {
                // R8
                if (user_id != this.bearer_middleware_task.?.result) {
                    // R6, R8
                    // await this.check_member_target_task
                    {
                        if (this.check_member_target_task == null) {
                            this.check_member_target_task = .from(.init(db, .{
                                .guild_id = guild_id,
                                .target_user_id = user_id,
                                .caller_user_id = this.bearer_middleware_task.?.result.?,
                            }));
                        }

                        while (this.check_member_target_task.?.await()) |res| {
                            return res.discard();
                        }

                        // R6
                        if (!this.check_member_target_task.?.result.alive) {
                            return root.route.generic.responseErrorMessage(this.response, .not_found, "User not found");
                        }

                        // R8
                        if (this.check_member_target_task.?.result.caller_position <= this.check_member_target_task.?.result.target_position) {
                            return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
                        }
                    }
                }
            },
            .role => |role_id| {
                // R6, R8
                // await this.get_role_and_caller_position_task
                {
                    if (this.get_role_and_caller_position_task == null) {
                        this.get_role_and_caller_position_task = .from(.init(db, .{
                            .role_id = role_id,
                            .guild_id = guild_id,
                            .caller_user_id = this.bearer_middleware_task.?.result.?,
                        }));
                    }

                    while (this.get_role_and_caller_position_task.?.await()) |res| {
                        return res.discard();
                    }

                    // R6
                    if (this.get_role_and_caller_position_task.?.result == null) {
                        return root.route.generic.responseErrorMessage(this.response, .not_found, "Role not found");
                    }

                    // R8
                    if (this.get_role_and_caller_position_task.?.result.?.position >= this.get_role_and_caller_position_task.?.result.?.caller_position) {
                        return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
                    }
                }
            },
        }

        // R9
        {
            const changed_raw: root.types.Permissions.Int = if (this.get_channel_overwrite_task.?.result) |old|
                (old.overwrites.allow.raw() ^ new_overwrites.allow.raw()) |
                    (old.overwrites.deny.raw() ^ new_overwrites.deny.raw())
            else
                new_overwrites.allow.raw() | new_overwrites.deny.raw();

            if ((changed_raw & ~my_perms.raw()) != 0) {
                return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
            }
        }

        // R10
        if (new_overwrites.allow.raw() == 0 and new_overwrites.deny.raw() == 0) {
            // await this.remove_overwrite_task
            {
                if (this.remove_overwrite_task == null) {
                    this.remove_overwrite_task = .from(.init(db, .{
                        .channel_id = this.payload.channel_id,
                        .target = this.content.?.target,
                    }));
                }

                while (!this.remove_overwrite_task.?.done) {
                    if (this.remove_overwrite_task.?.await()) |res| {
                        return res.discard();
                    }

                    root.bus.raise(.{
                        .overwrite_updated = .{
                            .guild_id = this.channel_exists_task.?.result.?.guild_id,
                            .channel_id = this.payload.channel_id,
                        },
                    });
                }
            }
        } else {
            // R10
            // await this.set_overwrite_task
            {
                if (this.set_overwrite_task == null) {
                    this.set_overwrite_task = .from(.init(db, .{
                        .channel_id = this.payload.channel_id,
                        .target = this.content.?.target,
                        .overwrites = new_overwrites,
                    }));
                }

                while (!this.set_overwrite_task.?.done) {
                    if (this.set_overwrite_task.?.await()) |res| {
                        return res;
                    }

                    root.bus.raise(.{
                        .overwrite_updated = .{
                            .guild_id = this.channel_exists_task.?.result.?.guild_id,
                            .channel_id = this.payload.channel_id,
                        },
                    });
                }
            }
        }

        // await this.audit_log
        {
            if (this.audit_log == null) {
                this.audit_entries[0] = switch (this.content.?.target) {
                    .role => |role_id| .{
                        .action = .role_overwrite_update,
                        .target_id = role_id,
                        .channel_id = this.payload.channel_id,
                    },
                    .member => |user_id| .{
                        .action = .member_overwrite_update,
                        .target_user_id = user_id,
                        .channel_id = this.payload.channel_id,
                    },
                };

                this.audit_log = .from(root.repo.audit_log.Insert.init(this.db.?, this.response.allocator, .{
                    .guild_id = this.channel_exists_task.?.result.?.guild_id,
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
        const this: *PutTask = @ptrCast(@alignCast(ctx));

        if (this.bearer_middleware_task) |*t| {
            t.dispose();
            this.bearer_middleware_task = null;
        }

        if (this.channel_exists_task) |*t| {
            t.dispose();
            this.channel_exists_task = null;
        }

        if (this.get_user_channel_permissions_task) |*t| {
            t.dispose();
            this.get_user_channel_permissions_task = null;
        }

        if (this.get_channel_overwrite_task) |*t| {
            t.dispose();
            this.get_channel_overwrite_task = null;
        }

        if (this.check_member_target_task) |*t| {
            t.dispose();
            this.check_member_target_task = null;
        }

        if (this.get_role_and_caller_position_task) |*t| {
            t.dispose();
            this.get_role_and_caller_position_task = null;
        }

        if (this.remove_overwrite_task) |*t| {
            t.dispose();
            this.remove_overwrite_task = null;
        }

        if (this.set_overwrite_task) |*t| {
            t.dispose();
            this.set_overwrite_task = null;
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

/// PUT /api/channels/{channel_id}/overwrites
/// R1 - content type must be application/json (415) and body non-empty (400) (see the R-list above PutTask)
pub inline fn putHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    channel_id: root.types.ChannelId,
) !root.http.Task {
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
        .channel_id = channel_id,
    });
}
