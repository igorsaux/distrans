// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../../../root.zig");

const SCOPE = std.log.scoped(.@"/api/guilds/{guild_id}/roles/order");

/// R2 - user must be logged
/// R3 - the guild exists (404 "Guild not found")
/// R4 - user must have modify_roles (403 "Missing permissions")
/// R5 - body must be a JSON object with "roles", an array of decimal id strings (400 "Bad 'roles'")
/// R6 - "roles" must list every non-@everyone role of the guild exactly once; @everyone (role id = guild id) must be absent, and no id may be duplicated or foreign (400 "Bad 'roles'")
/// R7 - role hierarchy: every role the caller cannot move (current position >= the caller's highest position) must keep its exact index; otherwise 403 "Missing permissions"
/// R8 - apply: assign dense positions 1..N in the given order; 204
const PutTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        guild_id: root.types.GuildId,
    };

    const RoleEntry = struct {
        id: root.types.RoleId,
        position: root.types.Position,
    };

    const Content = struct {
        ids: std.ArrayList(root.types.RoleId),
        csv: []const u8,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    guild_exists_task: ?root.repo.guilds.Exists.Lazy = null,
    check_user_guild_rights_task: ?root.repo.rights.CheckUserGuildRights.Lazy = null,
    content: ?Content = null,
    get_roles_stream: ?root.repo.guilds.GetRoles.Lazy = null,
    roles_list: std.ArrayList(RoleEntry) = .empty,
    highest_position_task: ?root.repo.users.GetHighestRolePosition.Lazy = null,
    reorder_task: ?root.repo.roles.Reorder.Lazy = null,
    event_raised: bool = false,
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
                    .guild_id = this.payload.guild_id,
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .required = .{ .modify_roles = true },
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

            // R5
            const roles_value = root_value.object.get("roles") orelse {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad 'roles'");

                return .ready;
            };

            // R5
            if (roles_value != .array) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad 'roles'");

                return .ready;
            }

            var ids: std.ArrayList(root.types.RoleId) = .empty;
            var csv: std.ArrayList(u8) = .empty;

            for (roles_value.array.items) |item| {
                // R5
                if (item != .string) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad 'roles'");

                    return .ready;
                }

                const id = std.fmt.parseInt(root.types.RoleId, item.string, 10) catch {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad 'roles'");

                    return .ready;
                };

                if (ids.items.len != 0) {
                    csv.append(this.response.allocator, ',') catch |err| {
                        SCOPE.err("PUT failed to build 'roles': {t}", .{err});

                        return .{ .err = err };
                    };
                }

                var buf: [20]u8 = undefined;
                const id_raw = std.fmt.bufPrint(&buf, "{}", .{id}) catch unreachable;

                csv.appendSlice(this.response.allocator, id_raw) catch |err| {
                    SCOPE.err("PUT failed to build 'roles': {t}", .{err});

                    return .{ .err = err };
                };

                ids.append(this.response.allocator, id) catch |err| {
                    SCOPE.err("PUT failed to append 'roles': {t}", .{err});

                    return .{ .err = err };
                };
            }

            this.content = .{
                .ids = ids,
                .csv = csv.items,
            };
        }

        // R6
        // await this.get_roles_stream
        {
            if (this.get_roles_stream == null) {
                this.get_roles_stream = .from(.init(this.db.?, .{
                    .guild_id = this.payload.guild_id,
                }));
            }

            while (this.get_roles_stream.?.await()) |res| {
                switch (res) {
                    .next => |n| {
                        // @everyone (id = guild id) is always position 0 and is
                        // never part of the reorder list.
                        if (n.id == this.payload.guild_id) {
                            continue;
                        }

                        this.roles_list.append(this.response.allocator, .{
                            .id = n.id,
                            .position = n.position,
                        }) catch |err| {
                            SCOPE.err("PUT failed to append a role: {t}", .{err});

                            return .{ .err = err };
                        };
                    },
                    .poll => |p| return p.discard(),
                }
            }
        }

        // R7
        // await this.highest_position_task
        {
            if (this.highest_position_task == null) {
                this.highest_position_task = .from(.init(this.db.?, .{
                    .guild_id = this.payload.guild_id,
                    .user_id = this.bearer_middleware_task.?.result.?,
                }));
            }

            while (this.highest_position_task.?.await()) |res| {
                return res.discard();
            }
        }

        const highest = this.highest_position_task.?.result;

        // R6
        // rejected as "not found".)
        {
            var seen = std.AutoHashMap(root.types.RoleId, usize).init(this.response.allocator);

            for (this.content.?.ids.items, 0..) |id, i| {
                if (id == this.payload.guild_id) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad 'roles'");

                    return .ready;
                }

                if (seen.contains(id)) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad 'roles'");

                    return .ready;
                }

                seen.put(id, i) catch |err| {
                    SCOPE.err("PUT failed to track 'roles': {t}", .{err});

                    return .{ .err = err };
                };
            }

            if (seen.count() != this.roles_list.items.len) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad 'roles'");

                return .ready;
            }

            // R7
            for (this.content.?.ids.items, 0..) |id, i| {
                const current_index = for (this.roles_list.items, 0..) |e, j| {
                    if (e.id == id) break j;
                } else {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad 'roles'");

                    return .ready;
                };

                const entry = this.roles_list.items[current_index];
                const immovable = entry.position >= highest;

                if (immovable and current_index != i) {
                    return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
                }
            }
        }

        // R8
        if (this.content.?.ids.items.len != 0) {
            // await this.reorder_task
            {
                if (this.reorder_task == null) {
                    this.reorder_task = .from(.init(this.db.?, .{
                        .guild_id = this.payload.guild_id,
                        .ids_csv = this.content.?.csv,
                    }));
                }

                while (!this.reorder_task.?.done) {
                    if (this.reorder_task.?.await()) |res| {
                        return res.discard();
                    }
                }
            }

            if (!this.event_raised) {
                this.event_raised = true;

                root.bus.raise(.{
                    .role_reordered = .{
                        .guild_id = this.payload.guild_id,
                    },
                });
            }

            // await this.audit_log
            {
                if (this.audit_log == null) {
                    this.audit_entries[0] = .{
                        .action = .role_reorder,
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

        if (this.guild_exists_task) |*t| {
            t.dispose();
            this.guild_exists_task = null;
        }

        if (this.check_user_guild_rights_task) |*t| {
            t.dispose();
            this.check_user_guild_rights_task = null;
        }

        if (this.get_roles_stream) |*s| {
            s.dispose();
            this.get_roles_stream = null;
        }

        if (this.highest_position_task) |*t| {
            t.dispose();
            this.highest_position_task = null;
        }

        if (this.reorder_task) |*t| {
            t.dispose();
            this.reorder_task = null;
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

/// PUT /api/guilds/{guild_id}/roles/order
/// R1 - content type must be application/json (415) and body non-empty (400) (see the R-list above PutTask)
pub inline fn putHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    guild_id: root.types.GuildId,
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
        .guild_id = guild_id,
    });
}
