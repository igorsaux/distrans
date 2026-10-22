// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../root.zig");
pub const messages = @import("id/messages.zig");
pub const pins = @import("id/pins.zig");

const SCOPE = std.log.scoped(.@"/api/channels/{channel_id}");

/// R1 - user must be logged
/// R2 - the channel exists
const GetTask = struct {
    const Task = root.http.Task;

    pub const Response = struct {
        id: []const u8,
        guild_id: []const u8,
        parent_id: ?[]const u8,
        kind: root.types.ChannelKind,
        name: []const u8,
        topic: ?[]const u8,
        position: root.types.Position,
        last_message_id: ?[]const u8,
        permissions: []const u8,
        overwrites: []const root.route.types.Overwrite,
    };

    pub const Payload = struct {
        channel_id: root.types.ChannelId,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    channel_exists_task: ?root.repo.channels.IsExists.Lazy = null,
    get_user_channel_permissions_task: ?root.repo.rights.GetUserChannelPermissions.Lazy = null,
    get_channel_task: ?root.repo.channels.Get.Lazy = null,
    get_channel_overwrites_stream: ?root.repo.channels.GetOverwrites.Lazy = null,
    overwrites: std.ArrayList(root.route.types.Overwrite) = .empty,
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

        // await this.get_user_channel_permissions_task
        {
            if (this.get_user_channel_permissions_task == null) {
                this.get_user_channel_permissions_task = .from(.init(db, .{
                    .guild_id = this.channel_exists_task.?.result.?.guild_id,
                    .channel_id = this.payload.channel_id,
                    .user_id = this.bearer_middleware_task.?.result.?,
                }));
            }

            while (this.get_user_channel_permissions_task.?.await()) |res| {
                return res.discard();
            }
        }

        // await this.get_channel_task
        {
            if (this.get_channel_task == null) {
                this.get_channel_task = .from(.init(this.response.allocator, db, .{
                    .channel_id = this.payload.channel_id,
                }));
            }

            while (this.get_channel_task.?.await()) |res| {
                return res.discard();
            }

            if (this.get_channel_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Channel not found");
            }
        }

        const channel = this.get_channel_task.?.result.?;

        // await this.get_channel_overwrites_stream
        {
            if (this.get_channel_overwrites_stream == null) {
                this.get_channel_overwrites_stream = .from(.init(db, .{
                    .channel_id = this.payload.channel_id,
                }));
            }

            while (this.get_channel_overwrites_stream.?.await()) |res| {
                switch (res) {
                    .next => |n| {
                        const wire = root.route.types.Overwrite.fromRepo(this.response.allocator, n) catch |err| {
                            SCOPE.err("GET failed to convert an overwrite: {t}", .{err});

                            return .{ .err = err };
                        };

                        this.overwrites.append(this.response.allocator, wire) catch |err| {
                            SCOPE.err("GET failed to append an overwrite: {t}", .{err});

                            return .{ .err = err };
                        };
                    },
                    .poll => |p| return p.discard(),
                }
            }
        }

        if (this.body == null) {
            var writer: std.Io.Writer.Allocating = .init(this.response.allocator);

            const item: Response = .{
                .id = std.fmt.allocPrint(this.response.allocator, "{}", .{this.payload.channel_id}) catch |err| {
                    SCOPE.err("GET failed to stringify 'id': {t}", .{err});

                    return .{ .err = err };
                },
                .guild_id = std.fmt.allocPrint(this.response.allocator, "{}", .{channel.guild_id}) catch |err| {
                    SCOPE.err("GET failed to stringify 'guild_id': {t}", .{err});

                    return .{ .err = err };
                },
                .parent_id = if (channel.parent_id) |parent_id|
                    std.fmt.allocPrint(this.response.allocator, "{}", .{parent_id}) catch |err| {
                        SCOPE.err("GET failed to stringify 'parent_id': {t}", .{err});

                        return .{ .err = err };
                    }
                else
                    null,
                .kind = channel.kind,
                .name = channel.name,
                .topic = channel.topic,
                .position = channel.position,
                .last_message_id = if (channel.last_message_id) |last_message_id|
                    std.fmt.allocPrint(this.response.allocator, "{}", .{last_message_id}) catch |err| {
                        SCOPE.err("GET failed to stringify 'last_message_id': {t}", .{err});

                        return .{ .err = err };
                    }
                else
                    null,
                .permissions = std.fmt.allocPrint(
                    this.response.allocator,
                    "{}",
                    .{(this.get_user_channel_permissions_task.?.result orelse root.types.Permissions{}).raw()},
                ) catch |err| {
                    SCOPE.err("GET failed to stringify 'permissions': {t}", .{err});

                    return .{ .err = err };
                },
                .overwrites = this.overwrites.items,
            };

            std.json.fmt(item, .{}).format(&writer.writer) catch |err| {
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

        if (this.channel_exists_task) |*t| {
            t.dispose();
            this.channel_exists_task = null;
        }

        if (this.get_user_channel_permissions_task) |*t| {
            t.dispose();
            this.get_user_channel_permissions_task = null;
        }

        if (this.get_channel_task) |*t| {
            t.dispose();
            this.get_channel_task = null;
        }

        if (this.get_channel_overwrites_stream) |*s| {
            s.dispose();
            this.get_channel_overwrites_stream = null;
        }

        this.overwrites.deinit(this.response.allocator);

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

/// GET /api/channels/{channel_id}
/// R1 - user must be logged (see the R-list above GetTask)
pub inline fn getHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    channel_id: root.types.ChannelId,
) !GetTask.Task {
    _ = allocator;

    return try GetTask.task(request, response, .{
        .channel_id = channel_id,
    });
}

/// R2 - user must be logged
/// R3 - the channel exists
/// R4 - user has rights to modify channels
/// R5 - the body must contain at least one of "name" / "topic" / "parent_id"
/// R6 - "name" must be a string and not too long
/// R7 - "topic" must be a string (or null) and not too long
/// R8 - kind = category => "topic" must be absent
/// R9 - "parent_id" must be null or a string parseable as a channel id
/// R10 - kind = category => "parent_id" must be absent or null
/// R11 - the new parent channel must not be the channel itself
/// R12 - the new parent channel must exist
/// R13 - the new parent channel must belong to the same guild
/// R14 - the new parent channel must be a category
const PatchTask = struct {
    const Task = root.http.Task;

    pub const Payload = struct {
        channel_id: root.types.ChannelId,
    };

    const Content = struct {
        name: ?[]const u8 = null,
        topic: ?[]const u8 = null,
        topic_set: bool = false,
        parent_id: ?root.types.ChannelId = null,
        parent_set: bool = false,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    channel_exists_task: ?root.repo.channels.IsExists.Lazy = null,
    check_user_channel_rights_task: ?root.repo.rights.CheckUserChannelRights.Lazy = null,
    content: ?Content = null,
    parent_exists_task: ?root.repo.channels.IsExists.Lazy = null,
    update_channel_meta_task: ?root.repo.channels.Update.Lazy = null,
    move_channel_task: ?root.repo.channels.Move.Lazy = null,
    audit_log: ?root.repo.audit_log.Insert.Lazy = null,
    audit_entries: [3]root.repo.audit_log.Insert.Entry = undefined,

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

        // R4
        // await this.check_user_channel_rights_task
        {
            if (this.check_user_channel_rights_task == null) {
                this.check_user_channel_rights_task = .from(.init(db, .{
                    .guild_id = this.channel_exists_task.?.result.?.guild_id,
                    .channel_id = this.payload.channel_id,
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .required = .{ .modify_channels = true },
                }));
            }

            while (this.check_user_channel_rights_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.check_user_channel_rights_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
            }
        }

        // R5, R6, R7, R8, R9, R10
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

            var content: Content = .{};

            // R6
            if (body.object.get("name")) |name_value| {
                if (name_value != .string) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is not a string");

                    return .ready;
                }

                const name = root.unicode.normalize(this.response.allocator, name_value.string) catch |err| switch (err) {
                    error.InvalidUtf8 => return root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is invalid"),
                    error.OutOfMemory => return .{ .err = error.OutOfMemory },
                };

                if (std.unicode.utf8CountCodepoints(name) catch unreachable >
                    root.options.api.channels.max_name_codepoints)
                {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is too long");

                    return .ready;
                }

                if ((root.unicode.findForbiddenCodepoint(.name, name) catch null) != null) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is invalid");

                    return .ready;
                }

                content.name = name;
            }

            // R7
            if (body.object.get("topic")) |topic_value| {
                content.topic_set = true;

                if (topic_value == .null) {
                    content.topic = "";
                } else if (topic_value == .string) {
                    const topic = root.unicode.normalize(this.response.allocator, topic_value.string) catch |err| switch (err) {
                        error.InvalidUtf8 => return root.route.generic.responseErrorMessage(this.response, .bad_request, "'topic' is invalid"),
                        error.OutOfMemory => return .{ .err = error.OutOfMemory },
                    };

                    if (std.unicode.utf8CountCodepoints(topic) catch unreachable >
                        root.options.api.channels.max_topic_codepoints)
                    {
                        _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'topic' is too long");

                        return .ready;
                    }

                    if ((root.unicode.findForbiddenCodepoint(.name, topic) catch null) != null) {
                        _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'topic' is invalid");

                        return .ready;
                    }

                    content.topic = topic;
                } else {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'topic' is not a string");

                    return .ready;
                }
            }

            // R9
            if (body.object.get("parent_id")) |parent_id_value| {
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

            // R5
            if (content.name == null and !content.topic_set and !content.parent_set) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Nothing to update");

                return .ready;
            }

            // R8
            if (this.channel_exists_task.?.result.?.kind == .category and content.topic_set) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'topic' must be null");

                return .ready;
            }

            // R10 - a category can only have a null/absent parent_id
            if (this.channel_exists_task.?.result.?.kind == .category and content.parent_set and content.parent_id != null) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'parent_id' must be null");

                return .ready;
            }

            this.content = content;
        }

        // R11, R12, R13, R14
        if (this.content.?.parent_set and this.content.?.parent_id != null) {
            const parent_id = this.content.?.parent_id.?;

            // R11
            if (parent_id == this.payload.channel_id) {
                return root.route.generic.responseErrorMessage(this.response, .bad_request, "'parent_id' must not be the channel itself");
            }

            // await this.parent_exists_task
            {
                if (this.parent_exists_task == null) {
                    this.parent_exists_task = .from(.init(db, .{
                        .channel_id = parent_id,
                    }));
                }

                while (this.parent_exists_task.?.await()) |res| {
                    return res.discard();
                }

                // R12
                if (this.parent_exists_task.?.result == null) {
                    return root.route.generic.responseErrorMessage(this.response, .not_found, "Parent channel not found");
                }

                // R13
                if (this.parent_exists_task.?.result.?.guild_id != this.channel_exists_task.?.result.?.guild_id) {
                    return root.route.generic.responseErrorMessage(this.response, .bad_request, "Parent channel belongs to another guild");
                }

                // R14
                if (this.parent_exists_task.?.result.?.kind != .category) {
                    return root.route.generic.responseErrorMessage(this.response, .bad_request, "Parent channel must be a category");
                }
            }
        }

        if (this.content.?.name != null or this.content.?.topic_set) {
            // await this.update_channel_meta_task
            // R3 (raced with deletion)
            {
                if (this.update_channel_meta_task == null) {
                    this.update_channel_meta_task = .from(.init(db, .{
                        .channel_id = this.payload.channel_id,
                        .name = this.content.?.name orelse "",
                        .topic_mode = if (this.content.?.topic_set) .set else .keep,
                        .topic = this.content.?.topic orelse "",
                    }));
                }

                while (this.update_channel_meta_task.?.await()) |res| {
                    return res.discard();
                }

                if (!this.update_channel_meta_task.?.result) {
                    return root.route.generic.responseErrorMessage(this.response, .not_found, "Channel not found");
                }
            }

            root.bus.raise(.{
                .channel_updated = .{
                    .id = this.payload.channel_id,
                    .guild_id = this.channel_exists_task.?.result.?.guild_id,
                },
            });
        }

        if (this.content.?.parent_set) {
            // await this.move_channel_task
            // R3 (raced with deletion)
            {
                if (this.move_channel_task == null) {
                    this.move_channel_task = .from(.init(db, .{
                        .channel_id = this.payload.channel_id,
                        .parent_mode = if (this.content.?.parent_id == null)
                            .move_to_root
                        else
                            .set_parent,
                        .parent_id = this.content.?.parent_id orelse 0,
                    }));
                }

                while (this.move_channel_task.?.await()) |res| {
                    return res.discard();
                }

                if (!this.move_channel_task.?.result) {
                    return root.route.generic.responseErrorMessage(this.response, .not_found, "Channel not found");
                }
            }

            root.bus.raise(.{
                .channel_updated = .{
                    .id = this.payload.channel_id,
                    .guild_id = this.channel_exists_task.?.result.?.guild_id,
                },
            });
        }

        // await this.audit_log
        {
            if (this.audit_log == null) {
                var len: usize = 0;

                if (this.content.?.name != null) {
                    this.audit_entries[len] = .{
                        .action = .channel_name_update,
                        .channel_id = this.payload.channel_id,
                    };
                    len += 1;
                }

                if (this.content.?.topic_set) {
                    this.audit_entries[len] = .{
                        .action = .channel_topic_update,
                        .channel_id = this.payload.channel_id,
                    };
                    len += 1;
                }

                if (this.content.?.parent_set) {
                    this.audit_entries[len] = .{
                        .action = .channel_parent_update,
                        .channel_id = this.payload.channel_id,
                    };
                    len += 1;
                }

                this.audit_log = .from(root.repo.audit_log.Insert.init(this.db.?, this.response.allocator, .{
                    .guild_id = this.channel_exists_task.?.result.?.guild_id,
                    .actor_id = this.bearer_middleware_task.?.result.?,
                    .entries = this.audit_entries[0..len],
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

        if (this.channel_exists_task) |*t| {
            t.dispose();
            this.channel_exists_task = null;
        }

        if (this.check_user_channel_rights_task) |*t| {
            t.dispose();
            this.check_user_channel_rights_task = null;
        }

        if (this.parent_exists_task) |*t| {
            t.dispose();
            this.parent_exists_task = null;
        }

        if (this.update_channel_meta_task) |*t| {
            t.dispose();
            this.update_channel_meta_task = null;
        }

        if (this.move_channel_task) |*t| {
            t.dispose();
            this.move_channel_task = null;
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

/// PATCH /api/channels/{channel_id}
/// R1 - content type must be application/json (415) and body non-empty (400)
pub inline fn patchHandle(
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

    return try PatchTask.task(request, response, .{
        .channel_id = channel_id,
    });
}

/// R1 - user must be logged
/// R2 - the channel exists
/// R3 - user has rights to delete channels
const DeleteTask = struct {
    const Task = root.http.Task;

    pub const Payload = struct {
        channel_id: root.types.ChannelId,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    channel_exists_task: ?root.repo.channels.IsExists.Lazy = null,
    check_user_channel_rights_task: ?root.repo.rights.CheckUserChannelRights.Lazy = null,
    delete_channel_task: ?root.repo.channels.Delete.Lazy = null,
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

        const db = this.db.?;

        // R2
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

        // R3
        // await this.check_user_channel_rights_task
        {
            if (this.check_user_channel_rights_task == null) {
                this.check_user_channel_rights_task = .from(.init(db, .{
                    .guild_id = this.channel_exists_task.?.result.?.guild_id,
                    .channel_id = this.payload.channel_id,
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .required = .{ .delete_channels = true },
                }));
            }

            while (this.check_user_channel_rights_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.check_user_channel_rights_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
            }
        }

        // await this.delete_channel_task
        {
            if (this.delete_channel_task == null) {
                this.delete_channel_task = .from(.init(db, .{
                    .channel_id = this.payload.channel_id,
                }));
            }

            while (!this.delete_channel_task.?.done) {
                if (this.delete_channel_task.?.await()) |res| {
                    return res.discard();
                }

                if (this.delete_channel_task.?.result) {
                    root.bus.raise(.{
                        .channel_deleted = .{
                            .id = this.payload.channel_id,
                            .guild_id = this.channel_exists_task.?.result.?.guild_id,
                        },
                    });
                }
            }

            // R2 (raced with deletion)
            if (!this.delete_channel_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Channel not found");
            }
        }

        // await this.audit_log
        {
            if (this.audit_log == null) {
                this.audit_entries[0] = .{
                    .action = .channel_delete,
                    .channel_id = this.payload.channel_id,
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
        const this: *DeleteTask = @ptrCast(@alignCast(ctx));

        if (this.bearer_middleware_task) |*t| {
            t.dispose();
            this.bearer_middleware_task = null;
        }

        if (this.channel_exists_task) |*t| {
            t.dispose();
            this.channel_exists_task = null;
        }

        if (this.check_user_channel_rights_task) |*t| {
            t.dispose();
            this.check_user_channel_rights_task = null;
        }

        if (this.delete_channel_task) |*t| {
            t.dispose();
            this.delete_channel_task = null;
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

/// DELETE /api/channels/{channel_id}
/// R1 - user must be logged (see the R-list above DeleteTask)
pub inline fn deleteHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    channel_id: root.types.ChannelId,
) !root.http.Task {
    _ = allocator;

    return try DeleteTask.task(request, response, .{
        .channel_id = channel_id,
    });
}
