// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../../../root.zig");

const SCOPE = std.log.scoped(.@"/api/guilds/{guild_id}/channels/order");

/// R2 - user must be logged
/// R3 - the guild exists (404 "Guild not found")
/// R4 - body must be a JSON object with optional "parent_id" (null or a decimal string) and "channels", an array of decimal id strings (400 "Bad 'channels'")
/// R5 - when "parent_id" is set it must exist (404 "Parent channel not found"), belong to this guild and be a category (400)
/// R6 - "channels" must list exactly the children of that scope (the category's children, or the root channels/categories for a null parent), each exactly once (400 "Bad 'channels'")
/// R7 - a channel whose index changes must be modifiable by the caller (modify_channels computed on the channel), otherwise 403 "Missing permissions"
/// R8 - apply: assign dense positions 0..K-1 in the given order; 204
const PutTask = struct {
    pub const Task = root.http.Task;

    pub const Payload = struct {
        guild_id: root.types.GuildId,
    };

    const ScopeEntry = struct {
        id: root.types.ChannelId,
    };

    const Content = struct {
        parent_set: bool = false,
        parent_id: ?root.types.ChannelId = null,
        ids: std.ArrayList(root.types.ChannelId),
        csv: []const u8,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    guild_exists_task: ?root.repo.guilds.Exists.Lazy = null,
    content: ?Content = null,
    parent_exists_task: ?root.repo.channels.IsExists.Lazy = null,
    get_channels_stream: ?root.repo.guilds.GetChannels.Lazy = null,
    scope_list: std.ArrayList(ScopeEntry) = .empty,
    channel_rights_task: ?root.repo.rights.CheckUserChannelRights.Lazy = null,
    rights_index: usize = 0,
    reorder_task: ?root.repo.channels.Reorder.Lazy = null,
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

            var content: Content = undefined;
            content.parent_set = false;
            content.parent_id = null;
            content.ids = .empty;
            content.csv = "";

            if (root_value.object.get("parent_id")) |parent_id_value| {
                content.parent_set = true;

                if (parent_id_value == .null) {
                    content.parent_id = null;
                } else if (parent_id_value == .string) {
                    content.parent_id = std.fmt.parseInt(root.types.ChannelId, parent_id_value.string, 10) catch {
                        _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad 'parent_id'");

                        return .ready;
                    };
                } else {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'parent_id' is not a string");

                    return .ready;
                }
            }

            // R4
            const channels_value = root_value.object.get("channels") orelse {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad 'channels'");

                return .ready;
            };

            if (channels_value != .array) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad 'channels'");

                return .ready;
            }

            var ids: std.ArrayList(root.types.ChannelId) = .empty;
            var csv: std.ArrayList(u8) = .empty;

            for (channels_value.array.items) |item| {
                if (item != .string) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad 'channels'");

                    return .ready;
                }

                const id = std.fmt.parseInt(root.types.ChannelId, item.string, 10) catch {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad 'channels'");

                    return .ready;
                };

                if (ids.items.len != 0) {
                    csv.append(this.response.allocator, ',') catch |err| {
                        SCOPE.err("PUT failed to build 'channels': {t}", .{err});

                        return .{ .err = err };
                    };
                }

                var buf: [20]u8 = undefined;
                const id_raw = std.fmt.bufPrint(&buf, "{}", .{id}) catch unreachable;

                csv.appendSlice(this.response.allocator, id_raw) catch |err| {
                    SCOPE.err("PUT failed to build 'channels': {t}", .{err});

                    return .{ .err = err };
                };

                ids.append(this.response.allocator, id) catch |err| {
                    SCOPE.err("PUT failed to append 'channels': {t}", .{err});

                    return .{ .err = err };
                };
            }

            content.ids = ids;
            content.csv = csv.items;

            this.content = content;
        }

        // R5
        if (this.content.?.parent_id) |parent_id| {
            // await this.parent_exists_task
            {
                if (this.parent_exists_task == null) {
                    this.parent_exists_task = .from(.init(this.db.?, .{
                        .channel_id = parent_id,
                    }));
                }

                while (this.parent_exists_task.?.await()) |res| {
                    return res.discard();
                }

                if (this.parent_exists_task.?.result == null) {
                    return root.route.generic.responseErrorMessage(this.response, .not_found, "Parent channel not found");
                }

                if (this.parent_exists_task.?.result.?.guild_id != this.payload.guild_id) {
                    return root.route.generic.responseErrorMessage(this.response, .bad_request, "Parent channel belongs to another guild");
                }

                if (this.parent_exists_task.?.result.?.kind != .category) {
                    return root.route.generic.responseErrorMessage(this.response, .bad_request, "Parent channel must be a category");
                }
            }
        }

        // R6
        // await this.get_channels_stream
        {
            if (this.get_channels_stream == null) {
                this.get_channels_stream = .from(.init(this.db.?, .{
                    .id = this.payload.guild_id,
                }));
            }

            while (this.get_channels_stream.?.await()) |res| {
                switch (res) {
                    .next => |n| {
                        if (n.parent_id == this.content.?.parent_id) {
                            this.scope_list.append(this.response.allocator, .{
                                .id = n.id,
                            }) catch |err| {
                                SCOPE.err("PUT failed to append a channel: {t}", .{err});

                                return .{ .err = err };
                            };
                        }
                    },
                    .poll => |p| return p.discard(),
                }
            }
        }

        // R6
        {
            var seen = std.AutoHashMap(root.types.ChannelId, void).init(this.response.allocator);

            for (this.content.?.ids.items) |id| {
                if (seen.contains(id)) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad 'channels'");

                    return .ready;
                }

                seen.put(id, {}) catch |err| {
                    SCOPE.err("PUT failed to track 'channels': {t}", .{err});

                    return .{ .err = err };
                };
            }

            if (seen.count() != this.scope_list.items.len) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad 'channels'");

                return .ready;
            }

            for (this.scope_list.items) |entry| {
                if (!seen.contains(entry.id)) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad 'channels'");

                    return .ready;
                }
            }
        }

        // R7
        while (this.rights_index < this.content.?.ids.items.len) {
            const id = this.content.?.ids.items[this.rights_index];

            const current_index = for (this.scope_list.items, 0..) |entry, i| {
                if (entry.id == id) break i;
            } else unreachable;

            if (current_index == this.rights_index) {
                this.rights_index += 1;

                continue;
            }

            if (this.channel_rights_task == null) {
                this.channel_rights_task = .from(.init(this.db.?, .{
                    .guild_id = this.payload.guild_id,
                    .channel_id = id,
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .required = .{ .modify_channels = true },
                }));
            }

            while (this.channel_rights_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.channel_rights_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
            }

            this.channel_rights_task.?.dispose();
            this.channel_rights_task = null;

            this.rights_index += 1;
        }

        // R8
        if (this.content.?.ids.items.len != 0) {
            // await this.reorder_task
            {
                if (this.reorder_task == null) {
                    this.reorder_task = .from(.init(this.db.?, .{
                        .guild_id = this.payload.guild_id,
                        .parent_id = this.content.?.parent_id,
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
                    .channel_reordered = .{
                        .guild_id = this.payload.guild_id,
                    },
                });
            }

            // await this.audit_log
            {
                if (this.audit_log == null) {
                    this.audit_entries[0] = .{
                        .action = .channel_reorder,
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

        if (this.parent_exists_task) |*t| {
            t.dispose();
            this.parent_exists_task = null;
        }

        if (this.get_channels_stream) |*s| {
            s.dispose();
            this.get_channels_stream = null;
        }

        if (this.channel_rights_task) |*t| {
            t.dispose();
            this.channel_rights_task = null;
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

/// PUT /api/guilds/{guild_id}/channels/order
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
