// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../../../root.zig");

pub const order = @import("channels/order.zig");

const SCOPE = std.log.scoped(.@"/api/guilds/{guild_id}/channels");

/// R1 - user must be logged
const GetTask = struct {
    const Task = root.http.Task;

    pub const ResponseItem = struct {
        id: []const u8,
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
        guild_id: root.types.GuildId,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    guild_exists_task: ?root.repo.guilds.Exists.Lazy = null,
    get_guild_channel_permissions_task: ?root.repo.rights.GetGuildChannelPermissions.Lazy = null,
    channel_permissions: ?std.AutoHashMap(root.types.ChannelId, root.types.Permissions) = null,
    base_permissions: root.types.Permissions = .{},
    get_guild_overwrites_stream: ?root.repo.channels.GetAllOverwrites.Lazy = null,
    overwrites_by_channel: ?std.AutoHashMap(root.types.ChannelId, std.ArrayList(root.route.types.Overwrite)) = null,
    get_guild_channels_stream: ?root.repo.guilds.GetChannels.Lazy = null,
    get_guild_channels_stream_result: std.ArrayList(ResponseItem) = .empty,
    body: ?[]u8 = null,
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

        // await this.guild_exists_task
        {
            if (this.guild_exists_task == null) {
                this.guild_exists_task = .from(.init(db, .{
                    .id = this.payload.guild_id,
                }));
            }

            while (this.guild_exists_task.?.await()) |res| {
                return res.discard();
            }

            if (this.guild_exists_task.?.result == false) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Guild not found");
            }
        }

        // await this.get_guild_channel_permissions_task
        {
            if (this.get_guild_channel_permissions_task == null) {
                this.get_guild_channel_permissions_task = .from(.init(this.response.allocator, db, .{
                    .guild_id = this.payload.guild_id,
                    .user_id = this.bearer_middleware_task.?.result.?,
                }));
            }

            while (this.get_guild_channel_permissions_task.?.await()) |res| {
                return res.discard();
            }

            if (this.channel_permissions == null) {
                const result = this.get_guild_channel_permissions_task.?.result;

                this.base_permissions = result.base;

                var map = std.AutoHashMap(root.types.ChannelId, root.types.Permissions).init(this.response.allocator);

                for (result.channels) |c| {
                    map.put(c.channel_id, c.permissions) catch |err| {
                        SCOPE.err("GET failed to index channel permissions: {t}", .{err});

                        return .{ .err = err };
                    };
                }

                this.channel_permissions = map;
            }
        }

        // await this.get_guild_overwrites_stream
        {
            if (this.overwrites_by_channel == null) {
                var map = std.AutoHashMap(root.types.ChannelId, std.ArrayList(root.route.types.Overwrite)).init(this.response.allocator);

                if (this.get_guild_overwrites_stream == null) {
                    this.get_guild_overwrites_stream = .from(.init(db, .{
                        .guild_id = this.payload.guild_id,
                    }));
                }

                while (this.get_guild_overwrites_stream.?.await()) |res| {
                    switch (res) {
                        .next => |n| {
                            const entry = map.getOrPut(n.channel_id) catch |err| {
                                SCOPE.err("GET failed to index overwrites: {t}", .{err});

                                return .{ .err = err };
                            };

                            if (!entry.found_existing) {
                                entry.value_ptr.* = .empty;
                            }

                            const wire = root.route.types.Overwrite.fromRepo(this.response.allocator, n) catch |err| {
                                SCOPE.err("GET failed to convert an overwrite: {t}", .{err});

                                return .{ .err = err };
                            };

                            entry.value_ptr.append(this.response.allocator, wire) catch |err| {
                                SCOPE.err("GET failed to append an overwrite: {t}", .{err});

                                return .{ .err = err };
                            };
                        },
                        .poll => |p| return p.discard(),
                    }
                }

                this.overwrites_by_channel = map;
            }
        }

        // await this.get_guild_channels_stream
        {
            if (this.get_guild_channels_stream == null) {
                this.get_guild_channels_stream = .from(.init(db, .{
                    .id = this.payload.guild_id,
                }));
            }

            while (this.get_guild_channels_stream.?.await()) |res| {
                switch (res) {
                    .next => |n| {
                        const channel: ResponseItem = .{
                            .id = std.fmt.allocPrint(this.response.allocator, "{}", .{n.id}) catch |err| {
                                SCOPE.err("GET failed to stringify 'id': {t}", .{err});

                                return .{ .err = err };
                            },
                            .parent_id = if (n.parent_id == null)
                                null
                            else
                                std.fmt.allocPrint(this.response.allocator, "{}", .{n.parent_id.?}) catch |err| {
                                    SCOPE.err("GET failed to stringify 'parent_id': {t}", .{err});

                                    return .{ .err = err };
                                },
                            .kind = n.kind,
                            .name = this.response.allocator.dupe(u8, n.name) catch |err| {
                                SCOPE.err("GET failed to dupe 'name': {t}", .{err});

                                return .{ .err = err };
                            },
                            .topic = if (n.topic == null)
                                null
                            else
                                this.response.allocator.dupe(u8, n.topic.?) catch |err| {
                                    SCOPE.err("GET failed to dupe 'topic': {t}", .{err});

                                    return .{ .err = err };
                                },
                            .position = n.position,
                            .last_message_id = if (n.last_message_id == null)
                                null
                            else
                                std.fmt.allocPrint(this.response.allocator, "{}", .{n.last_message_id.?}) catch |err| {
                                    SCOPE.err("GET failed to stringify 'last_message_id': {t}", .{err});

                                    return .{ .err = err };
                                },
                            .permissions = std.fmt.allocPrint(
                                this.response.allocator,
                                "{}",
                                .{(this.channel_permissions.?.get(n.id) orelse this.base_permissions).raw()},
                            ) catch |err| {
                                SCOPE.err("GET failed to stringify 'permissions': {t}", .{err});

                                return .{ .err = err };
                            },
                            .overwrites = if (this.overwrites_by_channel.?.get(n.id)) |list|
                                list.items
                            else
                                &.{},
                        };

                        this.get_guild_channels_stream_result.append(this.response.allocator, channel) catch |err| {
                            SCOPE.err("GET failed to append a channel: {t}", .{err});

                            return .{ .err = err };
                        };
                    },
                    .poll => |p| return p.discard(),
                }
            }
        }

        if (this.body == null) {
            var writer: std.Io.Writer.Allocating = .init(this.response.allocator);

            std.json.fmt(this.get_guild_channels_stream_result.items, .{}).format(&writer.writer) catch |err| {
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

        if (this.guild_exists_task) |*t| {
            t.dispose();
            this.guild_exists_task = null;
        }

        if (this.get_guild_channel_permissions_task) |*t| {
            t.dispose();
            this.get_guild_channel_permissions_task = null;
        }

        if (this.channel_permissions) |*map| {
            map.deinit();
            this.channel_permissions = null;
        }

        if (this.overwrites_by_channel) |*map| {
            var it = map.valueIterator();
            while (it.next()) |list| {
                list.deinit(this.response.allocator);
            }

            map.deinit();
            this.overwrites_by_channel = null;
        }

        if (this.get_guild_overwrites_stream) |*s| {
            s.dispose();
            this.get_guild_overwrites_stream = null;
        }

        if (this.get_guild_channels_stream) |*s| {
            s.dispose();
            this.get_guild_channels_stream = null;
        }

        if (this.db) |conn| {
            conn.release();
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

/// GET /api/guilds/{guild_id}/channels
/// R1 - user must be logged (see the R-list above GetTask)
pub inline fn getHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    guild_id: root.types.GuildId,
) !GetTask.Task {
    _ = allocator;

    return try GetTask.task(request, response, .{
        .guild_id = guild_id,
    });
}

/// R2 - user must be logged
/// R3 - the guild exists
/// R4 - user has rights to create channels
/// R5 - "name" must be present, a string, not too long and must not contain
///      forbidden codepoints
/// R6 - optional "topic" must be a string, not too long and must not contain
///      forbidden codepoints
/// R7 - "kind" must be present, a string and a valid ChannelKind
/// R8 - optional "parent_id" must be a string parseable as a channel id
/// R9 - kind = category => "parent_id" and "topic" must be absent
/// R10 - the parent channel must exist
/// R11 - the parent channel must belong to the same guild
/// R12 - the parent channel must be a category
const PostTask = struct {
    const Task = root.http.Task;

    pub const Response = struct {
        id: []const u8,
    };

    pub const Payload = struct {
        guild_id: root.types.GuildId,
    };

    const Content = struct {
        name: []const u8,
        topic: ?[]const u8,
        kind: root.types.ChannelKind,
        parent_id: ?root.types.ChannelId,
    };

    request: *const root.http.Request,
    response: *root.http.Response,
    payload: Payload,
    bearer_middleware_task: ?root.middleware.bearer.BearerMiddleware.Lazy = null,
    db: ?*root.db.Connection = null,
    guild_exists_task: ?root.repo.guilds.Exists.Lazy = null,
    check_user_guild_rights_task: ?root.repo.rights.CheckUserGuildRights.Lazy = null,
    content: ?Content = null,
    parent_exists_task: ?root.repo.channels.IsExists.Lazy = null,
    channel_id: ?root.types.ChannelId = null,
    create_channel_task: ?root.repo.channels.Create.Lazy = null,
    body: ?[]const u8 = null,
    streamer: ?root.http.Response.Streamer = null,
    audit_log: ?root.repo.audit_log.Insert.Lazy = null,
    audit_entries: [1]root.repo.audit_log.Insert.Entry = undefined,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *PostTask = @ptrCast(@alignCast(ctx));

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
        // await this.guild_exists_task
        {
            if (this.guild_exists_task == null) {
                this.guild_exists_task = .from(.init(db, .{
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
                this.check_user_guild_rights_task = .from(.init(db, .{
                    .guild_id = this.payload.guild_id,
                    .user_id = this.bearer_middleware_task.?.result.?,
                    .required = .{ .create_channels = true },
                }));
            }

            while (this.check_user_guild_rights_task.?.await()) |res| {
                return res.discard();
            }

            if (!this.check_user_guild_rights_task.?.result) {
                return root.route.generic.responseErrorMessage(this.response, .forbidden, "Missing permissions");
            }
        }

        // R5, R6, R7, R8, R9
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

            // R5
            const name_value = body.object.get("name") orelse {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is missing");

                return .ready;
            };

            if (name_value != .string) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is not a string");

                return .ready;
            }

            // R5
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

            // R5
            if ((root.unicode.findForbiddenCodepoint(.name, name) catch null) != null) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'name' is invalid");

                return .ready;
            }

            // R6
            const topic_value = body.object.get("topic");

            if (topic_value != null and topic_value.? != .string) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'topic' is not a string");

                return .ready;
            }

            const topic = if (topic_value) |value|
                root.unicode.normalize(this.response.allocator, value.string) catch |err| switch (err) {
                    error.InvalidUtf8 => return root.route.generic.responseErrorMessage(this.response, .bad_request, "'topic' is invalid"),
                    error.OutOfMemory => return .{ .err = error.OutOfMemory },
                }
            else
                null;

            // R6
            if (topic != null and std.unicode.utf8CountCodepoints(topic.?) catch unreachable >
                root.options.api.channels.max_topic_codepoints)
            {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'topic' is too long");

                return .ready;
            }

            // R6
            if (topic != null and (root.unicode.findForbiddenCodepoint(.name, topic.?) catch null) != null) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'topic' is invalid");

                return .ready;
            }

            // R7
            const kind_value = body.object.get("kind") orelse {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'kind' is missing");

                return .ready;
            };

            // R7
            if (kind_value != .string) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'kind' is not a string");

                return .ready;
            }

            const kind = root.utils.enumFromString(root.types.ChannelKind, kind_value.string) orelse {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad 'kind'");

                return .ready;
            };

            // R8
            const parent_id_value = body.object.get("parent_id");

            // R8
            if (parent_id_value != null and parent_id_value.? != .string) {
                _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'parent_id' is not a string");

                return .ready;
            }

            // R8
            const parent_id = if (parent_id_value == null)
                null
            else
                std.fmt.parseInt(root.types.ChannelId, parent_id_value.?.string, 10) catch {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "Bad 'parent_id'");

                    return .ready;
                };

            // R9
            if (kind == .category) {
                // R9
                if (parent_id_value != null) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'parent_id' must be null");

                    return .ready;
                }

                // R9
                if (topic_value != null) {
                    _ = root.route.generic.responseErrorMessage(this.response, .bad_request, "'topic' must be null");

                    return .ready;
                }
            }

            this.content = .{
                .name = name,
                .topic = topic,
                .kind = kind,
                .parent_id = parent_id,
            };
        }

        // R10, R11, R12
        // await this.parent_exists_task
        if (this.content.?.parent_id) |parent_id| {
            if (this.parent_exists_task == null) {
                this.parent_exists_task = .from(.init(db, .{
                    .channel_id = parent_id,
                }));
            }

            while (this.parent_exists_task.?.await()) |res| {
                return res.discard();
            }

            // R10
            if (this.parent_exists_task.?.result == null) {
                return root.route.generic.responseErrorMessage(this.response, .not_found, "Parent channel not found");
            }

            // R11
            if (this.parent_exists_task.?.result.?.guild_id != this.payload.guild_id) {
                return root.route.generic.responseErrorMessage(this.response, .bad_request, "Parent channel belongs to another guild");
            }

            // R12
            if (this.parent_exists_task.?.result.?.kind != .category) {
                return root.route.generic.responseErrorMessage(this.response, .bad_request, "Parent channel must be a category");
            }
        }

        if (this.channel_id == null) {
            this.channel_id = root.sf_generator.generate();
        }

        // await this.create_channel_task
        {
            if (this.create_channel_task == null) {
                this.create_channel_task = .from(.init(db, .{
                    .id = this.channel_id.?,
                    .guild_id = this.payload.guild_id,
                    .name = this.content.?.name,
                    .topic = this.content.?.topic,
                    .kind = this.content.?.kind,
                    .parent_id = this.content.?.parent_id,
                }));
            }

            while (!this.create_channel_task.?.done) {
                if (this.create_channel_task.?.await()) |res| {
                    return res.discard();
                }

                root.bus.raise(.{
                    .channel_created = .{
                        .id = this.channel_id.?,
                        .guild_id = this.payload.guild_id,
                    },
                });
            }
        }

        // await this.audit_log
        {
            if (this.audit_log == null) {
                this.audit_entries[0] = .{
                    .action = .channel_create,
                    .channel_id = this.channel_id.?,
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

        if (this.body == null) {
            var writer: std.Io.Writer.Allocating = .init(this.response.allocator);

            const item: Response = .{
                .id = std.fmt.allocPrint(this.response.allocator, "{}", .{this.channel_id.?}) catch |err| {
                    SCOPE.err("POST failed to stringify 'id': {t}", .{err});

                    return .{ .err = err };
                },
            };

            std.json.fmt(item, .{}).format(&writer.writer) catch |err| {
                SCOPE.err("POST failed to stringify the response: {t}", .{err});

                return .{ .err = err };
            };

            this.body = writer.written();
        }

        if (this.streamer == null) {
            var writer = this.response.getWriter();

            if (!writer.writeCode(.created)) {
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
        const this: *PostTask = @ptrCast(@alignCast(ctx));

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

        if (this.parent_exists_task) |*t| {
            t.dispose();
            this.parent_exists_task = null;
        }

        if (this.create_channel_task) |*t| {
            t.dispose();
            this.create_channel_task = null;
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
        const this = try response.allocator.create(PostTask);
        errdefer response.allocator.destroy(this);

        this.* = .{
            .request = request,
            .response = response,
            .payload = payload,
        };

        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// POST /api/guilds/{guild_id}/channels
/// R1 - content type must be application/json (415) and body non-empty (400)
pub inline fn postHandle(
    allocator: std.mem.Allocator,
    request: *const root.http.Request,
    response: *root.http.Response,
    guild_id: root.types.GuildId,
) !PostTask.Task {
    _ = allocator;

    // R1
    if (request.getContentLength() == 0) {
        return try root.route.generic.badRequestTask(response);
    }

    // R1
    if (!root.utils.startsWithMaybe(u8, request.content_type, "application/json")) {
        return try root.route.generic.unsupportedMediaTypeTask(response);
    }

    return try PostTask.task(request, response, .{
        .guild_id = guild_id,
    });
}
