// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const builtin = @import("builtin");

const JSON_OPTIONS: std.json.ParseOptions = .{
    .ignore_unknown_fields = true,
};

pub const Options = struct {
    pub const General = struct {
        worker_id: usize = 1,
        max_peers: usize = 1024,
        shutdown_timeout_s: usize = 5,
        io_timeout_us: usize = 16_000,
        watchdog_interval_s: ?usize = null,
    };

    pub const Socket = struct {
        pub const Bind = union(enum) {
            unix: [:0]const u8,
            inet: struct {
                host: [:0]const u8,
                port: [:0]const u8,
            },

            pub fn parse(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Bind {
                _ = options;

                if (source != .object) {
                    std.log.err("'socket.bind' is not an object", .{});

                    return error.BadConfig;
                }

                const type_value = try requiredField(source, "type", "socket.bind.type");

                if (type_value != .string) {
                    std.log.err("'socket.bind.type' is not a string", .{});

                    return error.BadConfig;
                }

                if (std.mem.eql(u8, type_value.string, "inet")) {
                    return .{
                        .inet = .{
                            .host = try parseRequiredString([:0]const u8, allocator, source, "host", "socket.bind.host"),
                            .port = try parseRequiredString([:0]const u8, allocator, source, "port", "socket.bind.port"),
                        },
                    };
                }

                if (std.mem.eql(u8, type_value.string, "unix")) {
                    return .{ .unix = try parseRequiredString([:0]const u8, allocator, source, "path", "socket.bind.path") };
                }

                std.log.err("'socket.bind.type': unknown type '{s}'", .{type_value.string});

                return error.BadConfig;
            }
        };

        bind: Bind = .{
            .inet = .{
                .host = "::1",
                .port = "8080",
            },
        },
        /// ~16 KB
        downlink_buf_size: usize = std.math.pow(usize, 2, 14),
        /// ~16 KB
        uplink_buf_size: usize = std.math.pow(usize, 2, 14),
        /// The grace period given to a closing/shutdown peer to flush its
        /// leftover data before it is forcibly freed.
        disconnect_timeout_ms: usize = 500,
    };

    pub const Http = struct {
        max_path_size: usize = 2048,
        max_headers: usize = 24,
        max_query_params: usize = 16,
        max_cookies: usize = 16,
        /// The maximum time to wait for the client to make progress on the
        /// request.
        read_timeout_ms: usize = 1000,
        /// The maximum time to wait for the client to accept the response.
        write_timeout_ms: usize = 1000,
        host: ?[]const u8 = null,
        arenas_reset_interval_s: ?usize = null,
    };

    pub const Db = struct {
        conninfo: [:0]const u8 = "",
        pool: usize = 10,
        /// Maximum runtime of a pooled SQL statement; zero disables the limit.
        statement_timeout_ms: usize = 5000,
    };

    pub const Api = struct {
        pub const Guilds = struct {
            max_name_codepoints: usize = 18,
            max_emojis: usize = 100,
        };

        pub const Messages = struct {
            max_messages_limit: usize = 100,
            max_codepoints: usize = 4000,
            max_reactions: usize = 20,
            max_reactions_users_limit: usize = 100,
            max_embeds: usize = 10,
            max_attachments: usize = 10,
            max_mention_users: usize = 100,
            max_mention_roles: usize = 100,
            max_allowed_mention_users: usize = 100,
            max_allowed_mention_roles: usize = 100,
        };

        pub const Search = struct {
            /// The `content` filter is ignored below this many codepoints and
            /// rejected above `max_content_codepoints`.
            min_content_codepoints: usize = 2,
            max_content_codepoints: usize = 100,
            /// Maximum number of ids accepted in one comma-separated filter
            /// list (`authors`, `channels`, `mentions`, `mention_roles`).
            max_filter_ids: usize = 50,
        };

        pub const Sync = struct {
            /// Maximum accepted age of a changed-since `since` cursor, in
            /// seconds. A `since` older than this is rejected (400) and the
            /// client clears the cursor and full-refetches the scope. It is
            /// also the window used when `since` is omitted.
            max_lookback_s: usize = 604_800,
        };

        pub const AuditLog = struct {
            /// Maximum `limit` accepted by `GET /guilds/{guild_id}/audit-log`.
            max_entries_limit: usize = 100,
        };

        pub const Embeds = struct {
            max_title_codepoints: usize = 256,
            max_description_codepoints: usize = 4096,
            max_fields: usize = 25,
            max_footer_codepoints: usize = 2048,
            max_author_name_codepoints: usize = 256,
            max_field_name_codepoints: usize = 256,
            max_field_value_codepoints: usize = 1024,
            max_url_codepoints: usize = 2048,
            max_total_codepoints: usize = 6000,
        };

        pub const Users = struct {
            max_users_limit: usize = 100,
            min_username_codepoints: usize = 2,
            max_username_codepoints: usize = 32,
            min_display_name_codepoints: usize = 1,
            max_display_name_codepoints: usize = 32,
            /// Hard cap on the userdata blob body, in bytes.
            max_userdata_bytes: usize = 524288,
        };

        pub const Roles = struct {
            max_name_codepoints: usize = 24,
        };

        pub const Channels = struct {
            max_name_codepoints: usize = 24,
            max_topic_codepoints: usize = 128,
        };

        pub const CustomEmojis = struct {
            max_emojis_limit: usize = 100,
            min_name_codepoints: usize = 2,
            max_name_codepoints: usize = 32,
        };

        pub const FileNames = struct {
            max_name_codepoints: usize = 256,
        };

        pub const PushLimits = struct {
            max_subscriptions_per_user: usize = 10,
            max_endpoint_bytes: usize = 2048,
        };

        pub const Webhooks = struct {
            max_webhooks_per_channel: usize = 10,
            max_name_codepoints: usize = 64,
        };

        /// Caps applied when rendering a GitHub webhook delivery into a
        /// message embed. These bound a server-to-server payload, not a
        /// client-supplied API field, so they are not exposed by
        /// `GET /api/limits`.
        pub const Github = struct {
            max_body_bytes: usize = 1_048_576,
            max_title_codepoints: usize = 70,
            max_push_title_codepoints: usize = 256,
            max_description_codepoints: usize = 350,
            max_commits: usize = 100,
        };

        guilds: Guilds = .{},
        messages: Messages = .{},
        search: Search = .{},
        sync: Sync = .{},
        audit_log: AuditLog = .{},
        embeds: Embeds = .{},
        users: Users = .{},
        roles: Roles = .{},
        channels: Channels = .{},
        emojis: CustomEmojis = .{},
        files: FileNames = .{},
        push: PushLimits = .{},
        webhooks: Webhooks = .{},
        github: Github = .{},
    };

    pub const Auth = struct {
        pub const Password = struct {
            iterations: u32 = 2,
            memory_kib: u32 = 19456,
            parallelism: u24 = 1,
            min_password_codepoints: usize = 8,
            max_password_codepoints: usize = 64,
            max_password_len: usize = 128,
        };

        password: Password = .{},
        /// Default: 15 min
        access_token_exp_s: u64 = 900,
        access_token_key: []const u8 = "CHANGE_ME",
        /// Default: 5 days
        refresh_token_exp_s: u64 = 432_000,
    };

    pub const System = struct {
        token: []const u8 = "CHANGE_ME",
    };

    pub const Services = struct {
        pub const PWHash = struct {
            max_jobs: usize = 16,
        };

        pub const MediaWorker = struct {
            max_jobs: usize = 4,
        };

        pub const FilesWorker = struct {
            max_jobs: usize = 4,
        };

        pub const NotificationsWorker = struct {
            /// Maximum in-flight transfers of the `curl_multi` push sender. The
            /// worker runs on a single thread but multiplexes up to this many
            /// concurrent requests; it is a memory/burst bound, not a thread
            /// count.
            max_concurrent: usize = 16,
            /// The in-memory queue between the message endpoint and the
            /// dispatcher. Overflow drops the notification (the message is
            /// still stored) so a push backlog never blocks messaging.
            queue_capacity: usize = 1024,
            /// Per-message safety cap on the number of recipients resolved and
            /// checked.
            max_recipients: usize = 1000,
        };

        pwhash: PWHash = .{},
        media: MediaWorker = .{},
        files: FilesWorker = .{},
        notifications: NotificationsWorker = .{},
    };

    pub const Push = struct {
        pub const Vapid = struct {
            /// `mailto:` or `https:` contact for the VAPID JWT `sub` claim.
            subject: []const u8 = "",
            /// base64url (no padding) uncompressed P-256 point (65 bytes).
            public_key: []const u8 = "",
            /// base64url (no padding) P-256 private scalar (32 bytes).
            private_key: []const u8 = "",
        };

        /// Generates a fresh VAPID key pair for `push.vapid`, base64url without
        /// padding, exactly as `parseConfig` expects. Generate once per server
        /// and paste the result into the config; the same public key is handed
        /// to clients as `push.vapid_public_key` from `GET /api/limits`.
        ///
        /// A ready-to-paste snippet is printed by:
        ///
        ///     zig build run -- --gen-vapid
        ///
        /// which emits:
        ///
        ///     "push": {
        ///       "enabled": true,
        ///       "vapid": {
        ///         "subject": "mailto:admin@example.com",
        ///         "public_key": "<65-byte point>",
        ///         "private_key": "<32-byte scalar>"
        ///       }
        ///     }
        ///
        /// Keep `private_key` secret; only `public_key` is public.
        pub fn generateVapid(io: std.Io, allocator: std.mem.Allocator) !Vapid {
            const key_pair = std.crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair.generate(io);

            const public_bytes = key_pair.public_key.toUncompressedSec1();
            const private_bytes = key_pair.secret_key.toBytes();

            const public_key = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(public_bytes.len));
            _ = std.base64.url_safe_no_pad.Encoder.encode(public_key, &public_bytes);

            const private_key = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(private_bytes.len));
            _ = std.base64.url_safe_no_pad.Encoder.encode(private_key, &private_bytes);

            return .{
                .public_key = public_key,
                .private_key = private_key,
            };
        }

        /// When false the subscription endpoints still work (rows are stored)
        /// but the dispatcher does not send, logging a single warning.
        enabled: bool = false,
        vapid: Vapid = .{},
        /// Web Push `TTL` header in seconds.
        ttl_s: usize = 86400,
        /// The notification body preview is truncated to this many codepoints.
        max_preview_codepoints: usize = 120,
    };

    pub const WebSocket = struct {
        auth_timeout_ms: u64 = 1000,
        min_heartbeat_ms: u64 = 40_000,
        max_heartbeat_ms: u64 = 45_000,
        heartbeat_threshold_ms: u64 = 3_000,
    };

    pub const Media = struct {
        pub const Limits = struct {
            max_dimensions: u16,
            lossless: bool,
            quality: usize,
            compression_level: usize,
            /// Hard cap on the uploaded body.
            max_input_bytes: usize,
            /// Hard cap on the re-encoded webp.
            max_output_bytes: usize,
            max_animation_frames: usize,
            max_animation_duration_ms: usize,
            min_animation_frame_delay_ms: usize,
            max_animation_frame_delay_ms: usize,

            inline fn validate(self: Limits, prefix: []const u8) !void {
                if (self.quality > 100) {
                    std.log.err("'{s}.quality' must be in range [0, 100]", .{prefix});

                    return error.BadConfig;
                }

                if (self.compression_level > 6) {
                    std.log.err("'{s}.compression_level' must be in range [0, 6]", .{prefix});

                    return error.BadConfig;
                }

                if (self.max_input_bytes == 0) {
                    std.log.err("'{s}.max_input_bytes' must be greater than zero", .{prefix});

                    return error.BadConfig;
                }

                if (self.max_output_bytes == 0) {
                    std.log.err("'{s}.max_output_bytes' must be greater than zero", .{prefix});

                    return error.BadConfig;
                }

                if (self.min_animation_frame_delay_ms == 0) {
                    std.log.err("'{s}.min_animation_frame_delay_ms' must be greater than zero", .{prefix});

                    return error.BadConfig;
                }

                if (self.max_animation_frame_delay_ms < self.min_animation_frame_delay_ms) {
                    std.log.err("'{s}.max_animation_frame_delay_ms' must be >= '{s}.min_animation_frame_delay_ms'", .{ prefix, prefix });

                    return error.BadConfig;
                }
            }
        };

        avatar: Limits = .{
            .max_dimensions = 512,
            .lossless = false,
            .quality = 75,
            .compression_level = 4,
            .max_input_bytes = std.math.pow(usize, 2, 21),
            .max_output_bytes = std.math.pow(usize, 2, 21),
            .max_animation_frames = 64,
            .max_animation_duration_ms = 10_000,
            .min_animation_frame_delay_ms = 20,
            .max_animation_frame_delay_ms = 2_000,
        },
        emoji: Limits = .{
            .max_dimensions = 64,
            .lossless = true,
            .quality = 75,
            .compression_level = 4,
            .max_input_bytes = std.math.pow(usize, 2, 20),
            .max_output_bytes = std.math.pow(usize, 2, 20),
            .max_animation_frames = 32,
            .max_animation_duration_ms = 5_000,
            .min_animation_frame_delay_ms = 20,
            .max_animation_frame_delay_ms = 1_000,
        },
        files: Limits = .{
            .max_dimensions = 2048,
            .lossless = false,
            .quality = 75,
            .compression_level = 4,
            .max_input_bytes = std.math.pow(usize, 2, 22),
            .max_output_bytes = std.math.pow(usize, 2, 22),
            .max_animation_frames = 256,
            .max_animation_duration_ms = 10_000,
            .min_animation_frame_delay_ms = 20,
            .max_animation_frame_delay_ms = 2_000,
        },
    };

    pub const Files = struct {
        pub const Storage = union(enum) {
            pub const S3 = struct {
                endpoint: []const u8,
                public_base_url: []const u8,
                region: []const u8,
                access_key: []const u8,
                secret_key: []const u8,
            };

            none: void,
            s3: S3,
        };

        pub const Gc = struct {
            /// How often the GC pass runs.
            interval_s: usize = 3600,
            /// A file must be unreferenced for at least this long before it is
            /// collected.
            grace_s: usize = 3600,
        };

        storage: Storage = .none,
        max_size: usize = 4194304,
        /// `null` = allow every type; empty = allow none; otherwise only the
        /// listed patterns. An exact `type/subtype` matches exactly; a
        /// `<type>/*` entry (e.g. `text/*`) matches any subtype of that type.
        /// Counted against the request's declared Content-Type.
        whitelist: ?[]const []const u8 = &.{
            "image/webp",
            "image/gif",
            "image/png",
            "image/jpeg",
            "image/jpg",
            "text/*",
            "audio/*",
            "application/zip",
            "application/x-zip-compressed",
            "application/x-7z-compressed",
            "application/x-rar-compressed",
            "application/x-tar",
            "application/gzip",
            "application/x-gzip",
            "application/x-bzip2",
            "application/x-xz",
            "application/octet-stream",
        },
        gc: Gc = .{},

        pub fn parse(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Files {
            _ = options;

            if (source != .object) {
                std.log.err("'files' is not an object", .{});

                return error.BadConfig;
            }

            const type_value = try requiredField(source, "type", "files.type");

            if (type_value != .string) {
                std.log.err("'files.type' is not a string", .{});

                return error.BadConfig;
            }

            var result = try parseStructOverlay(Files, allocator, source, .{}, "files");

            if (std.mem.eql(u8, type_value.string, "none")) {
                result.storage = .none;
            } else if (std.mem.eql(u8, type_value.string, "s3")) {
                const s3_value = try requiredField(source, "s3", "files.s3");

                if (s3_value != .object) {
                    std.log.err("'files.s3' is not an object", .{});

                    return error.BadConfig;
                }

                result.storage = .{
                    .s3 = .{
                        .endpoint = try parseRequiredString([]const u8, allocator, s3_value, "endpoint", "files.s3.endpoint"),
                        .public_base_url = try parseRequiredString([]const u8, allocator, s3_value, "public_base_url", "files.s3.public_base_url"),
                        .region = try parseRequiredString([]const u8, allocator, s3_value, "region", "files.s3.region"),
                        .access_key = try parseRequiredString([]const u8, allocator, s3_value, "access_key", "files.s3.access_key"),
                        .secret_key = try parseRequiredString([]const u8, allocator, s3_value, "secret_key", "files.s3.secret_key"),
                    },
                };
            } else {
                std.log.err("bad 'files.type' value: '{s}'", .{type_value.string});

                return error.BadConfig;
            }

            return result;
        }
    };

    general: General = .{},
    socket: Socket = .{},
    http: Http = .{},
    db: Db = .{},
    api: Api = .{},
    auth: Auth = .{},
    system: System = .{},
    services: Services = .{},
    websocket: WebSocket = .{},
    media: Media = .{},
    files: Files = .{},
    push: Push = .{},

    inline fn validate(self: Options) !void {
        try self.media.avatar.validate("media.avatar");
        try self.media.emoji.validate("media.emoji");
        try self.media.files.validate("media.files");

        if (self.api.users.max_userdata_bytes == 0) {
            std.log.err("'api.users.max_userdata_bytes' must be greater than zero", .{});

            return error.BadConfig;
        }

        if (self.files.max_size == 0) {
            std.log.err("'files.max_size' must be greater than zero", .{});

            return error.BadConfig;
        }

        if (self.files.gc.interval_s == 0) {
            std.log.err("'files.gc.interval_s' must be greater than zero", .{});

            return error.BadConfig;
        }

        if (self.socket.disconnect_timeout_ms == 0) {
            std.log.err("'socket.disconnect_timeout_ms' must be greater than zero", .{});

            return error.BadConfig;
        }

        if (self.http.read_timeout_ms == 0) {
            std.log.err("'http.read_timeout_ms' must be greater than zero", .{});

            return error.BadConfig;
        }

        if (self.http.write_timeout_ms == 0) {
            std.log.err("'http.write_timeout_ms' must be greater than zero", .{});

            return error.BadConfig;
        }

        if (self.websocket.auth_timeout_ms == 0) {
            std.log.err("'websocket.auth_timeout_ms' must be greater than zero", .{});

            return error.BadConfig;
        }

        if (self.services.media.max_jobs == 0) {
            std.log.err("'services.media.max_jobs' must be greater than zero", .{});

            return error.BadConfig;
        }

        if (self.services.files.max_jobs == 0) {
            std.log.err("'services.files.max_jobs' must be greater than zero", .{});

            return error.BadConfig;
        }

        if (self.services.notifications.max_concurrent == 0) {
            std.log.err("'services.notifications.max_concurrent' must be greater than zero", .{});

            return error.BadConfig;
        }

        if (self.services.notifications.queue_capacity == 0) {
            std.log.err("'services.notifications.queue_capacity' must be greater than zero", .{});

            return error.BadConfig;
        }

        if (self.services.notifications.max_recipients == 0) {
            std.log.err("'services.notifications.max_recipients' must be greater than zero", .{});

            return error.BadConfig;
        }

        // VAPID keys are only required when push is enabled; with push disabled the
        // subscription endpoints still work and the dispatcher does not send.
        if (self.push.enabled) {
            if (self.push.vapid.subject.len == 0) {
                std.log.err("'push.vapid.subject' is required when 'push.enabled' is true", .{});

                return error.BadConfig;
            }

            const public_key = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(self.push.vapid.public_key) catch {
                std.log.err("'push.vapid.public_key' is not valid base64url", .{});

                return error.BadConfig;
            };

            if (public_key != 65) {
                std.log.err("'push.vapid.public_key' must decode to 65 bytes", .{});

                return error.BadConfig;
            }

            const private_key = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(self.push.vapid.private_key) catch {
                std.log.err("'push.vapid.private_key' is not valid base64url", .{});

                return error.BadConfig;
            };

            if (private_key != 32) {
                std.log.err("'push.vapid.private_key' must decode to 32 bytes", .{});

                return error.BadConfig;
            }
        }
    }
};

inline fn requiredField(source: std.json.Value, name: []const u8, path: []const u8) !std.json.Value {
    return source.object.get(name) orelse {
        std.log.err("'{s}' is missing", .{path});

        return error.BadConfig;
    };
}

inline fn parseRequiredString(
    comptime T: type,
    allocator: std.mem.Allocator,
    source: std.json.Value,
    name: []const u8,
    path: []const u8,
) !T {
    const value = try requiredField(source, name, path);

    if (value != .string) {
        std.log.err("'{s}' is not a string", .{path});

        return error.BadConfig;
    }

    return std.json.innerParseFromValue(T, allocator, value, JSON_OPTIONS) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadConfig,
    };
}

fn isInteger(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int => true,
        .optional => |optional| isInteger(optional.child),
        else => false,
    };
}

fn parseStructOverlay(
    comptime T: type,
    allocator: std.mem.Allocator,
    source: std.json.Value,
    default: T,
    path: []const u8,
) !T {
    if (source != .object) {
        std.log.err("'{s}' is not an object", .{path});

        return error.BadConfig;
    }

    var result = default;

    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (source.object.get(field.name)) |value| {
            const field_path = if (path.len == 0)
                field.name
            else
                try std.fmt.allocPrint(allocator, "{s}.{s}", .{ path, field.name });

            @field(result, field.name) = try parseOverlay(field.type, allocator, value, @field(default, field.name), field_path);
        }
    }

    return result;
}

fn parseOverlay(comptime T: type, allocator: std.mem.Allocator, source: std.json.Value, default: T, path: []const u8) !T {
    if (comptime isInteger(T)) {
        if (source != .integer and source != .null) {
            std.log.err("'{s}' is not an integer", .{path});

            return error.BadConfig;
        }
    }

    if (T == Options.Socket.Bind) {
        return Options.Socket.Bind.parse(allocator, source, JSON_OPTIONS);
    }

    if (T == Options.Files) {
        return Options.Files.parse(allocator, source, JSON_OPTIONS);
    }

    if (@typeInfo(T) == .@"struct") {
        return parseStructOverlay(T, allocator, source, default, path);
    }

    return std.json.innerParseFromValue(T, allocator, source, JSON_OPTIONS) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => {
            std.log.err("invalid value for '{s}': {t}", .{ path, err });

            return error.BadConfig;
        },
    };
}

fn parseConfigText(arena: std.mem.Allocator, content: []const u8, path: []const u8) !Options {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, content, .{}) catch |err| {
        std.log.err("failed to parse the config file '{s}': {t}", .{ path, err });

        return err;
    };

    if (root != .object) {
        std.log.err("expected an object", .{});

        return error.BadConfig;
    }

    const options = try parseOverlay(Options, arena, root, .{}, "");
    try options.validate();

    return options;
}

pub fn parseConfig(io: std.Io, arena: std.mem.Allocator, path: []const u8) !Options {
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |err| {
        std.log.err("failed to read the config file '{s}': {t}", .{ path, err });

        return err;
    };

    return parseConfigText(arena, content, path);
}

test "empty and partial configs preserve defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqualDeep(Options{}, try parseConfigText(allocator, "{}", "test"));

    const options = try parseConfigText(allocator,
        \\{
        \\  "unknown": true,
        \\  "api": {
        \\    "unknown": true,
        \\    "messages": { "max_codepoints": 42 }
        \\  },
        \\  "media": {
        \\    "avatar": { "quality": 10 },
        \\    "emoji": { "quality": 20 },
        \\    "files": { "quality": 30 }
        \\  }
        \\}
    , "test");

    try std.testing.expectEqual(42, options.api.messages.max_codepoints);
    try std.testing.expectEqual(20, options.api.messages.max_reactions);
    try std.testing.expectEqual(18, options.api.guilds.max_name_codepoints);
    try std.testing.expectEqual(10, options.media.avatar.quality);
    try std.testing.expectEqual(512, options.media.avatar.max_dimensions);
    try std.testing.expectEqual(20, options.media.emoji.quality);
    try std.testing.expectEqual(64, options.media.emoji.max_dimensions);
    try std.testing.expectEqual(30, options.media.files.quality);
    try std.testing.expectEqual(2048, options.media.files.max_dimensions);
}

test "socket bind supports inet and unix formats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const inet = try parseConfigText(allocator,
        \\{ "socket": { "bind": { "type": "inet", "host": "127.0.0.1", "port": "9000" } } }
    , "test");
    try std.testing.expectEqualStrings("127.0.0.1", inet.socket.bind.inet.host);
    try std.testing.expectEqualStrings("9000", inet.socket.bind.inet.port);
    try std.testing.expectEqual(0, inet.socket.bind.inet.host[inet.socket.bind.inet.host.len]);

    const unix = try parseConfigText(allocator,
        \\{ "socket": { "bind": { "type": "unix", "path": "/tmp/distrans.sock" } } }
    , "test");
    try std.testing.expectEqualStrings("/tmp/distrans.sock", unix.socket.bind.unix);
    try std.testing.expectEqual(0, unix.socket.bind.unix[unix.socket.bind.unix.len]);
}

test "files storage and whitelist preserve their semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const defaults = try parseConfigText(allocator, "{}", "test");
    try std.testing.expectEqual(Options.Files.Storage.none, defaults.files.storage);
    try std.testing.expect(defaults.files.whitelist != null);

    const none = try parseConfigText(allocator,
        \\{ "files": { "type": "none", "whitelist": null, "gc": { "grace_s": 12 } } }
    , "test");
    try std.testing.expectEqual(Options.Files.Storage.none, none.files.storage);
    try std.testing.expectEqual(@as(?[]const []const u8, null), none.files.whitelist);
    try std.testing.expectEqual(3600, none.files.gc.interval_s);
    try std.testing.expectEqual(12, none.files.gc.grace_s);

    const empty = try parseConfigText(allocator, "{ \"files\": { \"type\": \"none\", \"whitelist\": [] } }", "test");
    try std.testing.expectEqual(0, empty.files.whitelist.?.len);

    const s3 = try parseConfigText(allocator,
        \\{
        \\  "files": {
        \\    "type": "s3",
        \\    "whitelist": ["image/webp"],
        \\    "s3": {
        \\      "endpoint": "https://s3.local",
        \\      "public_base_url": "https://cdn.local",
        \\      "region": "ru-6",
        \\      "access_key": "access",
        \\      "secret_key": "secret"
        \\    }
        \\  }
        \\}
    , "test");
    try std.testing.expectEqualStrings("https://s3.local", s3.files.storage.s3.endpoint);
    try std.testing.expectEqualStrings("image/webp", s3.files.whitelist.?[0]);
}

test "push accepts valid VAPID keys and disabled push without keys" {
    const valid =
        \\{
        \\  "push": {
        \\    "enabled": true,
        \\    "vapid": {
        \\      "subject": "mailto:admin@example.com",
        \\      "public_key": "BFZL1NxURQWZmVqe1T4W4kPLuJtD7CP9n0MLk6Axe3benudi0bhXdyJHFf04nYat4AGghgKlqgU3EoZmIBnPAIM",
        \\      "private_key": "dbNzyEr7ABXVXMcCIiD9dhc3Zyl8mYau-R8mMDu7o4U"
        \\    }
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try parseConfigText(arena.allocator(), valid, "test");
    _ = try parseConfigText(arena.allocator(), "{ \"push\": { \"enabled\": false } }", "test");
}

test "example and development configs parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    _ = try parseConfig(std.testing.io, arena.allocator(), "config.example.json");
    _ = try parseConfig(std.testing.io, arena.allocator(), "config.dev.json");
}
