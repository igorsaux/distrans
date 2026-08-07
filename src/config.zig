// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

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

            pub inline fn parse(prefix: []const u8, root_value: std.json.Value, default: Limits) !Limits {
                var limits = default;

                if (root_value.object.get("max_dimensions")) |max_dimensions_value| {
                    if (max_dimensions_value != .integer) {
                        std.log.err("'{s}.max_dimensions' is not an integer", .{prefix});

                        return error.BadConfig;
                    }

                    limits.max_dimensions = @intCast(max_dimensions_value.integer);
                }

                if (root_value.object.get("lossless")) |lossless_value| {
                    if (lossless_value != .bool) {
                        std.log.err("'{s}.lossless' is not an bool", .{prefix});

                        return error.BadConfig;
                    }

                    limits.lossless = lossless_value.bool;
                }

                if (root_value.object.get("quality")) |quality_value| {
                    if (quality_value != .integer) {
                        std.log.err("'{s}.quality' is not an integer", .{prefix});

                        return error.BadConfig;
                    }

                    if (quality_value.integer > 100) {
                        std.log.err("'{s}.quality' must be in range [0, 100]", .{prefix});

                        return error.BadConfig;
                    }

                    limits.quality = @intCast(quality_value.integer);
                }

                if (root_value.object.get("compression_level")) |compression_level_value| {
                    if (compression_level_value != .integer) {
                        std.log.err("'{s}.compression_level' is not an integer", .{prefix});

                        return error.BadConfig;
                    }

                    if (compression_level_value.integer > 6) {
                        std.log.err("'{s}.quality' must be in range [0, 6]", .{prefix});

                        return error.BadConfig;
                    }

                    limits.compression_level = @intCast(compression_level_value.integer);
                }

                if (root_value.object.get("max_input_bytes")) |max_input_bytes_value| {
                    if (max_input_bytes_value != .integer) {
                        std.log.err("'{s}.max_input_bytes' is not an integer", .{prefix});

                        return error.BadConfig;
                    }

                    if (max_input_bytes_value.integer <= 0) {
                        std.log.err("'{s}.max_input_bytes' must be greater than zero", .{prefix});

                        return error.BadConfig;
                    }

                    limits.max_input_bytes = @intCast(max_input_bytes_value.integer);
                }

                if (root_value.object.get("max_output_bytes")) |max_output_bytes_value| {
                    if (max_output_bytes_value != .integer) {
                        std.log.err("'{s}.max_output_bytes' is not an integer", .{prefix});

                        return error.BadConfig;
                    }

                    if (max_output_bytes_value.integer <= 0) {
                        std.log.err("'{s}.max_output_bytes' must be greater than zero", .{prefix});

                        return error.BadConfig;
                    }

                    limits.max_output_bytes = @intCast(max_output_bytes_value.integer);
                }

                if (root_value.object.get("max_animation_frames")) |max_animation_frames_value| {
                    if (max_animation_frames_value != .integer) {
                        std.log.err("'{s}.max_animation_frames' is not an integer", .{prefix});

                        return error.BadConfig;
                    }

                    limits.max_animation_frames = @intCast(max_animation_frames_value.integer);
                }

                if (root_value.object.get("max_animation_duration_ms")) |max_animation_duration_ms_value| {
                    if (max_animation_duration_ms_value != .integer) {
                        std.log.err("'{s}.max_animation_duration_ms' is not an integer", .{prefix});

                        return error.BadConfig;
                    }

                    limits.max_animation_duration_ms = @intCast(max_animation_duration_ms_value.integer);
                }

                if (root_value.object.get("min_animation_frame_delay_ms")) |min_animation_frame_delay_ms_value| {
                    if (min_animation_frame_delay_ms_value != .integer) {
                        std.log.err("'{s}.min_animation_frame_delay_ms' is not an integer", .{prefix});

                        return error.BadConfig;
                    }

                    if (min_animation_frame_delay_ms_value.integer <= 0) {
                        std.log.err("'{s}.min_animation_frame_delay_ms' must be greater than zero", .{prefix});

                        return error.BadConfig;
                    }

                    limits.min_animation_frame_delay_ms = @intCast(min_animation_frame_delay_ms_value.integer);
                }

                if (root_value.object.get("max_animation_frame_delay_ms")) |max_animation_frame_delay_ms_value| {
                    if (max_animation_frame_delay_ms_value != .integer) {
                        std.log.err("'{s}.max_animation_frame_delay_ms' is not an integer", .{prefix});

                        return error.BadConfig;
                    }

                    limits.max_animation_frame_delay_ms = @intCast(max_animation_frame_delay_ms_value.integer);
                }

                if (limits.max_animation_frame_delay_ms < limits.min_animation_frame_delay_ms) {
                    std.log.err("'{s}.max_animation_frame_delay_ms' must be >= '{s}.min_animation_frame_delay_ms'", .{ prefix, prefix });

                    return error.BadConfig;
                }

                return limits;
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
};

pub fn parseConfig(io: std.Io, arena: std.mem.Allocator, path: []const u8) !Options {
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |err| {
        std.log.err("failed to read the config file '{s}': {t}", .{ path, err });

        return err;
    };

    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, content, .{}) catch |err| {
        std.log.err("failed to parse the config file '{s}': {t}", .{ path, err });

        return err;
    };

    if (root != .object) {
        std.log.err("expected an object", .{});

        return error.BadConfig;
    }

    var options: Options = .{};

    if (root.object.get("general")) |general_value| {
        if (general_value != .object) {
            std.log.err("'general' is not an object", .{});

            return error.BadConfig;
        }

        if (general_value.object.get("worker_id")) |worker_id_value| {
            if (worker_id_value != .integer) {
                std.log.err("'general.worker_id' is not an integer", .{});

                return error.BadConfig;
            }

            options.general.worker_id = @intCast(worker_id_value.integer);
        }

        if (general_value.object.get("max_peers")) |max_peers_value| {
            if (max_peers_value != .integer) {
                std.log.err("'general.max_peers' is not an integer", .{});

                return error.BadConfig;
            }

            options.general.max_peers = @intCast(max_peers_value.integer);
        }

        if (general_value.object.get("shutdown_timeout_s")) |shutdown_timeout_s_value| {
            if (shutdown_timeout_s_value != .integer) {
                std.log.err("'general.shutdown_timeout_s' is not an integer", .{});

                return error.BadConfig;
            }

            options.general.shutdown_timeout_s = @intCast(shutdown_timeout_s_value.integer);
        }

        if (general_value.object.get("io_timeout_us")) |io_timeout_us_value| {
            if (io_timeout_us_value != .integer) {
                std.log.err("'general.io_timeout_us' is not an integer", .{});

                return error.BadConfig;
            }

            options.general.io_timeout_us = @intCast(io_timeout_us_value.integer);
        }

        if (general_value.object.get("watchdog_interval_s")) |watchdog_interval_s_value| {
            if (watchdog_interval_s_value != .integer and watchdog_interval_s_value != .null) {
                std.log.err("'watchdog_interval_s_value' is not an integer or a null", .{});

                return error.BadConfig;
            }

            if (watchdog_interval_s_value != .null) {
                options.general.watchdog_interval_s = @intCast(watchdog_interval_s_value.integer);
            }
        }
    }

    if (root.object.get("socket")) |socket_value| {
        if (socket_value != .object) {
            std.log.err("'socket' is not an object", .{});

            return error.BadConfig;
        }

        if (socket_value.object.get("bind")) |bind_value| {
            if (bind_value != .object) {
                std.log.err("'socket.bind' is not an object", .{});

                return error.BadConfig;
            }

            const type_value = bind_value.object.get("type") orelse {
                std.log.err("'socket.bind.type' is missing", .{});

                return error.BadConfig;
            };

            if (type_value != .string) {
                std.log.err("'socket.bind.type' is not a string", .{});

                return error.BadConfig;
            }

            if (std.mem.eql(u8, type_value.string, "inet")) {
                const host_value = bind_value.object.get("host") orelse {
                    std.log.err("'socket.bind.host' is missing", .{});

                    return error.BadConfig;
                };

                if (host_value != .string) {
                    std.log.err("'socket.bind.host' is not a string", .{});

                    return error.BadConfig;
                }

                const port_value = bind_value.object.get("port") orelse {
                    std.log.err("'socket.bind.port' is missing", .{});

                    return error.BadConfig;
                };

                if (port_value != .string) {
                    std.log.err("'socket.bind.port' is not a string", .{});

                    return error.BadConfig;
                }

                options.socket.bind = .{
                    .inet = .{
                        .host = try arena.dupeSentinel(u8, host_value.string, 0),
                        .port = try arena.dupeSentinel(u8, port_value.string, 0),
                    },
                };
            } else if (std.mem.eql(u8, type_value.string, "unix")) {
                const path_value = bind_value.object.get("path") orelse {
                    std.log.err("'socket.bind.path' is missing", .{});

                    return error.BadConfig;
                };

                if (path_value != .string) {
                    std.log.err("'socket.bind.path' is not a string", .{});

                    return error.BadConfig;
                }

                options.socket.bind = .{
                    .unix = try arena.dupeSentinel(u8, path_value.string, 0),
                };
            } else {
                std.log.err("'socket.bind.type': unknown type '{s}'", .{type_value.string});

                return error.BadConfig;
            }
        }

        if (socket_value.object.get("downlink_buf_size")) |downlink_buf_size_value| {
            if (downlink_buf_size_value != .integer) {
                std.log.err("'socket.downlink_buf_size' is not an integer", .{});

                return error.BadConfig;
            }

            options.socket.downlink_buf_size = @intCast(downlink_buf_size_value.integer);
        }

        if (socket_value.object.get("uplink_buf_size")) |uplink_buf_size_value| {
            if (uplink_buf_size_value != .integer) {
                std.log.err("'socket.uplink_buf_size' is not an integer", .{});

                return error.BadConfig;
            }

            options.socket.uplink_buf_size = @intCast(uplink_buf_size_value.integer);
        }

        if (socket_value.object.get("disconnect_timeout_ms")) |disconnect_timeout_ms_value| {
            if (disconnect_timeout_ms_value != .integer) {
                std.log.err("'socket.disconnect_timeout_ms' is not an integer", .{});

                return error.BadConfig;
            }

            options.socket.disconnect_timeout_ms = @intCast(disconnect_timeout_ms_value.integer);
        }
    }

    if (root.object.get("http")) |http_value| {
        if (http_value != .object) {
            std.log.err("'http' is not an object", .{});

            return error.BadConfig;
        }

        if (http_value.object.get("max_path_size")) |max_path_size_value| {
            if (max_path_size_value != .integer) {
                std.log.err("'http.max_path_size_value' is not an integer", .{});

                return error.BadConfig;
            }

            options.http.max_path_size = @intCast(max_path_size_value.integer);
        }

        if (http_value.object.get("max_headers")) |max_headers_value| {
            if (max_headers_value != .integer) {
                std.log.err("'http.max_headers' is not an integer", .{});

                return error.BadConfig;
            }

            options.http.max_headers = @intCast(max_headers_value.integer);
        }

        if (http_value.object.get("max_query_params")) |max_query_params_value| {
            if (max_query_params_value != .integer) {
                std.log.err("'http.max_query_params' is not an integer", .{});

                return error.BadConfig;
            }

            options.http.max_query_params = @intCast(max_query_params_value.integer);
        }

        if (http_value.object.get("max_cookies")) |max_cookies_value| {
            if (max_cookies_value != .integer) {
                std.log.err("'http.max_cookies' is not an integer", .{});

                return error.BadConfig;
            }

            options.http.max_cookies = @intCast(max_cookies_value.integer);
        }

        if (http_value.object.get("read_timeout_ms")) |read_timeout_ms_value| {
            if (read_timeout_ms_value != .integer) {
                std.log.err("'http.read_timeout_ms' is not an integer", .{});

                return error.BadConfig;
            }

            options.http.read_timeout_ms = @intCast(read_timeout_ms_value.integer);
        }

        if (http_value.object.get("write_timeout_ms")) |write_timeout_ms_value| {
            if (write_timeout_ms_value != .integer) {
                std.log.err("'http.write_timeout_ms' is not an integer", .{});

                return error.BadConfig;
            }

            options.http.write_timeout_ms = @intCast(write_timeout_ms_value.integer);
        }

        if (http_value.object.get("host")) |host_value| {
            if (host_value != .string and host_value != .null) {
                std.log.err("'http.host' is not a string", .{});

                return error.BadConfig;
            }

            if (host_value != .null) {
                options.http.host = host_value.string;
            }
        }

        if (http_value.object.get("arenas_reset_interval_s")) |arenas_reset_interval_s_value| {
            if (arenas_reset_interval_s_value != .integer and arenas_reset_interval_s_value != .null) {
                std.log.err("'arenas_reset_interval_s' is not an integer or a null", .{});

                return error.BadConfig;
            }

            if (arenas_reset_interval_s_value != .null) {
                options.http.arenas_reset_interval_s = @intCast(arenas_reset_interval_s_value.integer);
            }
        }
    }

    if (root.object.get("db")) |db_value| {
        if (db_value != .object) {
            std.log.err("'db' is not an object", .{});

            return error.BadConfig;
        }

        if (db_value.object.get("conninfo")) |conninfo_value| {
            if (conninfo_value != .string) {
                std.log.err("'db.conninfo' is not a string", .{});

                return error.BadConfig;
            }

            options.db.conninfo = try arena.dupeSentinel(u8, conninfo_value.string, 0);
        }

        if (db_value.object.get("pool")) |pool_value| {
            if (pool_value != .integer) {
                std.log.err("'db.pool' is not an integer", .{});

                return error.BadConfig;
            }

            options.db.pool = @intCast(pool_value.integer);
        }
    }

    if (root.object.get("api")) |api_value| {
        if (api_value != .object) {
            std.log.err("'api' is not an object", .{});

            return error.BadConfig;
        }

        if (api_value.object.get("guilds")) |guilds_value| {
            if (guilds_value != .object) {
                std.log.err("'api.guilds' is not an object", .{});

                return error.BadConfig;
            }

            if (guilds_value.object.get("max_name_codepoints")) |max_name_codepoints_value| {
                if (max_name_codepoints_value != .integer) {
                    std.log.err("'api.guilds.max_name_codepoints' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.guilds.max_name_codepoints = @intCast(max_name_codepoints_value.integer);
            }

            if (guilds_value.object.get("max_emojis")) |max_emojis_value| {
                if (max_emojis_value != .integer) {
                    std.log.err("'api.guilds.max_emojis' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.guilds.max_emojis = @intCast(max_emojis_value.integer);
            }
        }

        if (api_value.object.get("messages")) |messages_value| {
            if (messages_value != .object) {
                std.log.err("'api.messages' is not an object", .{});

                return error.BadConfig;
            }

            if (messages_value.object.get("max_messages_limit")) |max_messages_limit_value| {
                if (max_messages_limit_value != .integer) {
                    std.log.err("'api.messages.max_messages_limit' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.messages.max_messages_limit = @intCast(max_messages_limit_value.integer);
            }

            if (messages_value.object.get("max_codepoints")) |max_codepoints_value| {
                if (max_codepoints_value != .integer) {
                    std.log.err("'api.messages.max_codepoints' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.messages.max_codepoints = @intCast(max_codepoints_value.integer);
            }

            if (messages_value.object.get("max_reactions")) |max_reactions_value| {
                if (max_reactions_value != .integer) {
                    std.log.err("'api.messages.max_reactions' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.messages.max_reactions = @intCast(max_reactions_value.integer);
            }

            if (messages_value.object.get("max_reactions_users_limit")) |max_reactions_users_limit_value| {
                if (max_reactions_users_limit_value != .integer) {
                    std.log.err("'api.messages.max_reactions_users_limit' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.messages.max_reactions_users_limit = @intCast(max_reactions_users_limit_value.integer);
            }

            if (messages_value.object.get("max_embeds")) |max_embeds_value| {
                if (max_embeds_value != .integer) {
                    std.log.err("'api.messages.max_embeds' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.messages.max_embeds = @intCast(max_embeds_value.integer);
            }

            if (messages_value.object.get("max_attachments")) |max_attachments_value| {
                if (max_attachments_value != .integer) {
                    std.log.err("'api.messages.max_attachments' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.messages.max_attachments = @intCast(max_attachments_value.integer);
            }

            if (messages_value.object.get("max_mention_users")) |max_mention_users_value| {
                if (max_mention_users_value != .integer) {
                    std.log.err("'api.messages.max_mention_users' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.messages.max_mention_users = @intCast(max_mention_users_value.integer);
            }

            if (messages_value.object.get("max_mention_roles")) |max_mention_roles_value| {
                if (max_mention_roles_value != .integer) {
                    std.log.err("'api.messages.max_mention_roles' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.messages.max_mention_roles = @intCast(max_mention_roles_value.integer);
            }

            if (messages_value.object.get("max_allowed_mention_users")) |max_allowed_mention_users_value| {
                if (max_allowed_mention_users_value != .integer) {
                    std.log.err("'api.messages.max_allowed_mention_users' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.messages.max_allowed_mention_users = @intCast(max_allowed_mention_users_value.integer);
            }

            if (messages_value.object.get("max_allowed_mention_roles")) |max_allowed_mention_roles_value| {
                if (max_allowed_mention_roles_value != .integer) {
                    std.log.err("'api.messages.max_allowed_mention_roles' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.messages.max_allowed_mention_roles = @intCast(max_allowed_mention_roles_value.integer);
            }
        }

        if (api_value.object.get("search")) |search_value| {
            if (search_value != .object) {
                std.log.err("'api.search' is not an object", .{});

                return error.BadConfig;
            }

            if (search_value.object.get("min_content_codepoints")) |min_content_codepoints_value| {
                if (min_content_codepoints_value != .integer) {
                    std.log.err("'api.search.min_content_codepoints' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.search.min_content_codepoints = @intCast(min_content_codepoints_value.integer);
            }

            if (search_value.object.get("max_content_codepoints")) |max_content_codepoints_value| {
                if (max_content_codepoints_value != .integer) {
                    std.log.err("'api.search.max_content_codepoints' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.search.max_content_codepoints = @intCast(max_content_codepoints_value.integer);
            }

            if (search_value.object.get("max_filter_ids")) |max_filter_ids_value| {
                if (max_filter_ids_value != .integer) {
                    std.log.err("'api.search.max_filter_ids' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.search.max_filter_ids = @intCast(max_filter_ids_value.integer);
            }
        }

        if (api_value.object.get("sync")) |sync_value| {
            if (sync_value != .object) {
                std.log.err("'api.sync' is not an object", .{});

                return error.BadConfig;
            }

            if (sync_value.object.get("max_lookback_s")) |max_lookback_s_value| {
                if (max_lookback_s_value != .integer) {
                    std.log.err("'api.sync.max_lookback_s' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.sync.max_lookback_s = @intCast(max_lookback_s_value.integer);
            }
        }

        if (api_value.object.get("audit_log")) |audit_log_value| {
            if (audit_log_value != .object) {
                std.log.err("'api.audit_log' is not an object", .{});

                return error.BadConfig;
            }

            if (audit_log_value.object.get("max_entries_limit")) |max_entries_limit_value| {
                if (max_entries_limit_value != .integer) {
                    std.log.err("'api.audit_log.max_entries_limit' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.audit_log.max_entries_limit = @intCast(max_entries_limit_value.integer);
            }
        }

        if (api_value.object.get("embeds")) |embeds_value| {
            if (embeds_value != .object) {
                std.log.err("'api.embeds' is not an object", .{});

                return error.BadConfig;
            }

            if (embeds_value.object.get("max_title_codepoints")) |max_title_codepoints_value| {
                if (max_title_codepoints_value != .integer) {
                    std.log.err("'api.embeds.max_title_codepoints' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.embeds.max_title_codepoints = @intCast(max_title_codepoints_value.integer);
            }

            if (embeds_value.object.get("max_description_codepoints")) |max_description_codepoints_value| {
                if (max_description_codepoints_value != .integer) {
                    std.log.err("'api.embeds.max_description_codepoints' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.embeds.max_description_codepoints = @intCast(max_description_codepoints_value.integer);
            }

            if (embeds_value.object.get("max_fields")) |max_fields_value| {
                if (max_fields_value != .integer) {
                    std.log.err("'api.embeds.max_fields' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.embeds.max_fields = @intCast(max_fields_value.integer);
            }

            if (embeds_value.object.get("max_footer_codepoints")) |max_footer_codepoints_value| {
                if (max_footer_codepoints_value != .integer) {
                    std.log.err("'api.embeds.max_footer_codepoints' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.embeds.max_footer_codepoints = @intCast(max_footer_codepoints_value.integer);
            }

            if (embeds_value.object.get("max_author_name_codepoints")) |max_author_name_codepoints_value| {
                if (max_author_name_codepoints_value != .integer) {
                    std.log.err("'api.embeds.max_author_name_codepoints' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.embeds.max_author_name_codepoints = @intCast(max_author_name_codepoints_value.integer);
            }

            if (embeds_value.object.get("max_field_name_codepoints")) |max_field_name_codepoints_value| {
                if (max_field_name_codepoints_value != .integer) {
                    std.log.err("'api.embeds.max_field_name_codepoints' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.embeds.max_field_name_codepoints = @intCast(max_field_name_codepoints_value.integer);
            }

            if (embeds_value.object.get("max_field_value_codepoints")) |max_field_value_codepoints_value| {
                if (max_field_value_codepoints_value != .integer) {
                    std.log.err("'api.embeds.max_field_value_codepoints' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.embeds.max_field_value_codepoints = @intCast(max_field_value_codepoints_value.integer);
            }

            if (embeds_value.object.get("max_url_codepoints")) |max_url_codepoints_value| {
                if (max_url_codepoints_value != .integer) {
                    std.log.err("'api.embeds.max_url_codepoints' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.embeds.max_url_codepoints = @intCast(max_url_codepoints_value.integer);
            }

            if (embeds_value.object.get("max_total_codepoints")) |max_total_codepoints_value| {
                if (max_total_codepoints_value != .integer) {
                    std.log.err("'api.embeds.max_total_codepoints' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.embeds.max_total_codepoints = @intCast(max_total_codepoints_value.integer);
            }
        }

        if (api_value.object.get("users")) |users_value| {
            if (users_value != .object) {
                std.log.err("'api.users' is not an object", .{});

                return error.BadConfig;
            }

            if (users_value.object.get("max_users_limit")) |max_users_limit| {
                if (max_users_limit != .integer) {
                    std.log.err("'api.users.max_users_limit' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.users.max_users_limit = @intCast(max_users_limit.integer);
            }

            if (users_value.object.get("min_username_codepoints")) |min_username_codepoints| {
                if (min_username_codepoints != .integer) {
                    std.log.err("'api.users.min_username_codepoints' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.users.min_username_codepoints = @intCast(min_username_codepoints.integer);
            }

            if (users_value.object.get("max_username_codepoints")) |max_username_codepoints| {
                if (max_username_codepoints != .integer) {
                    std.log.err("'api.users.max_username_codepoints' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.users.max_username_codepoints = @intCast(max_username_codepoints.integer);
            }

            if (users_value.object.get("min_display_name_codepoints")) |min_display_name_codepoints| {
                if (min_display_name_codepoints != .integer) {
                    std.log.err("'api.users.min_display_name_codepoints' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.users.min_display_name_codepoints = @intCast(min_display_name_codepoints.integer);
            }

            if (users_value.object.get("max_display_name_codepoints")) |max_display_name_codepoints| {
                if (max_display_name_codepoints != .integer) {
                    std.log.err("'api.users.max_display_name_codepoints' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.users.max_display_name_codepoints = @intCast(max_display_name_codepoints.integer);
            }

            if (users_value.object.get("max_userdata_bytes")) |max_userdata_bytes| {
                if (max_userdata_bytes != .integer) {
                    std.log.err("'api.users.max_userdata_bytes' is not an integer", .{});

                    return error.BadConfig;
                }

                if (max_userdata_bytes.integer <= 0) {
                    std.log.err("'api.users.max_userdata_bytes' must be greater than zero", .{});

                    return error.BadConfig;
                }

                options.api.users.max_userdata_bytes = @intCast(max_userdata_bytes.integer);
            }
        }

        if (api_value.object.get("roles")) |roles_value| {
            if (roles_value != .object) {
                std.log.err("'api.roles' is not an object", .{});

                return error.BadConfig;
            }

            if (roles_value.object.get("max_name_codepoints")) |max_name_codepoints| {
                if (max_name_codepoints != .integer) {
                    std.log.err("'api.roles.max_name_codepoints' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.roles.max_name_codepoints = @intCast(max_name_codepoints.integer);
            }
        }

        if (api_value.object.get("channels")) |channels_value| {
            if (channels_value != .object) {
                std.log.err("'api.channels' is not an object", .{});

                return error.BadConfig;
            }

            if (channels_value.object.get("max_name_codepoints")) |max_name_codepoints_value| {
                if (max_name_codepoints_value != .integer) {
                    std.log.err("'api.channels.max_name_codepoints' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.channels.max_name_codepoints = @intCast(max_name_codepoints_value.integer);
            }

            if (channels_value.object.get("max_topic_codepoints")) |max_topic_codepoints_value| {
                if (max_topic_codepoints_value != .integer) {
                    std.log.err("'api.channels.max_topic_codepoints' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.channels.max_topic_codepoints = @intCast(max_topic_codepoints_value.integer);
            }
        }

        if (api_value.object.get("emojis")) |emojis_value| {
            if (emojis_value != .object) {
                std.log.err("'api.emojis' is not an object", .{});

                return error.BadConfig;
            }

            if (emojis_value.object.get("max_emojis_limit")) |max_emojis_limit| {
                if (max_emojis_limit != .integer) {
                    std.log.err("'api.emojis.max_emojis_limit' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.emojis.max_emojis_limit = @intCast(max_emojis_limit.integer);
            }

            if (emojis_value.object.get("min_name_codepoints")) |min_name_codepoints| {
                if (min_name_codepoints != .integer) {
                    std.log.err("'api.emojis.min_name_codepoints' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.emojis.min_name_codepoints = @intCast(min_name_codepoints.integer);
            }

            if (emojis_value.object.get("max_name_codepoints")) |max_name_codepoints| {
                if (max_name_codepoints != .integer) {
                    std.log.err("'api.emojis.max_name_codepoints' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.emojis.max_name_codepoints = @intCast(max_name_codepoints.integer);
            }
        }

        if (api_value.object.get("files")) |files_value| {
            if (files_value != .object) {
                std.log.err("'api.files' is not an object", .{});

                return error.BadConfig;
            }

            if (files_value.object.get("max_name_codepoints")) |max_name_codepoints| {
                if (max_name_codepoints != .integer) {
                    std.log.err("'api.files.max_name_codepoints' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.files.max_name_codepoints = @intCast(max_name_codepoints.integer);
            }
        }

        if (api_value.object.get("push")) |push_value| {
            if (push_value != .object) {
                std.log.err("'api.push' is not an object", .{});

                return error.BadConfig;
            }

            if (push_value.object.get("max_subscriptions_per_user")) |value| {
                if (value != .integer) {
                    std.log.err("'api.push.max_subscriptions_per_user' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.push.max_subscriptions_per_user = @intCast(value.integer);
            }

            if (push_value.object.get("max_endpoint_bytes")) |value| {
                if (value != .integer) {
                    std.log.err("'api.push.max_endpoint_bytes' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.push.max_endpoint_bytes = @intCast(value.integer);
            }
        }

        if (api_value.object.get("webhooks")) |webhooks_value| {
            if (webhooks_value != .object) {
                std.log.err("'api.webhooks' is not an object", .{});

                return error.BadConfig;
            }

            if (webhooks_value.object.get("max_webhooks_per_channel")) |value| {
                if (value != .integer) {
                    std.log.err("'api.webhooks.max_webhooks_per_channel' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.webhooks.max_webhooks_per_channel = @intCast(value.integer);
            }

            if (webhooks_value.object.get("max_name_codepoints")) |value| {
                if (value != .integer) {
                    std.log.err("'api.webhooks.max_name_codepoints' is not an integer", .{});

                    return error.BadConfig;
                }

                options.api.webhooks.max_name_codepoints = @intCast(value.integer);
            }
        }

        if (api_value.object.get("github")) |github_value| {
            if (github_value != .object) {
                std.log.err("'api.github' is not an object", .{});

                return error.BadConfig;
            }

            inline for (.{
                .{ "max_body_bytes", "max_body_bytes" },
                .{ "max_title_codepoints", "max_title_codepoints" },
                .{ "max_push_title_codepoints", "max_push_title_codepoints" },
                .{ "max_description_codepoints", "max_description_codepoints" },
                .{ "max_commits", "max_commits" },
            }) |field| {
                if (github_value.object.get(field[0])) |value| {
                    if (value != .integer) {
                        std.log.err("'api.github." ++ field[0] ++ "' is not an integer", .{});

                        return error.BadConfig;
                    }

                    @field(options.api.github, field[1]) = @intCast(value.integer);
                }
            }
        }
    }

    if (root.object.get("auth")) |auth_value| {
        if (auth_value != .object) {
            std.log.err("'auth' is not an object", .{});

            return error.BadConfig;
        }

        if (auth_value.object.get("password")) |password_value| {
            if (password_value != .object) {
                std.log.err("'auth.password' is not an object", .{});

                return error.BadConfig;
            }

            if (password_value.object.get("iterations")) |iterations_value| {
                if (iterations_value != .integer) {
                    std.log.err("'auth.password.iterations' is not an integer", .{});

                    return error.BadConfig;
                }

                options.auth.password.iterations = @intCast(iterations_value.integer);
            }

            if (password_value.object.get("memory_kib")) |memory_kib_value| {
                if (memory_kib_value != .integer) {
                    std.log.err("'auth.password.memory_kib' is not an integer", .{});

                    return error.BadConfig;
                }

                options.auth.password.memory_kib = @intCast(memory_kib_value.integer);
            }

            if (password_value.object.get("parallelism")) |parallelism_value| {
                if (parallelism_value != .integer) {
                    std.log.err("'auth.password.parallelism' is not an integer", .{});

                    return error.BadConfig;
                }

                options.auth.password.parallelism = @intCast(parallelism_value.integer);
            }

            if (password_value.object.get("min_password_codepoints")) |min_password_codepoints_value| {
                if (min_password_codepoints_value != .integer) {
                    std.log.err("'auth.password.min_password_codepoints' is not an integer", .{});

                    return error.BadConfig;
                }

                options.auth.password.min_password_codepoints = @intCast(min_password_codepoints_value.integer);
            }

            if (password_value.object.get("max_password_codepoints")) |max_password_codepoints_value| {
                if (max_password_codepoints_value != .integer) {
                    std.log.err("'auth.password.max_password_codepoints' is not an integer", .{});

                    return error.BadConfig;
                }

                options.auth.password.max_password_codepoints = @intCast(max_password_codepoints_value.integer);
            }

            if (password_value.object.get("max_password_len")) |max_password_len_value| {
                if (max_password_len_value != .integer) {
                    std.log.err("'auth.password.max_password_len' is not an integer", .{});

                    return error.BadConfig;
                }

                options.auth.password.max_password_len = @intCast(max_password_len_value.integer);
            }
        }

        if (auth_value.object.get("access_token_exp_s")) |access_token_exp_s_value| {
            if (access_token_exp_s_value != .integer) {
                std.log.err("'auth.access_token_exp_s' is not an integer", .{});

                return error.BadConfig;
            }

            options.auth.access_token_exp_s = @intCast(access_token_exp_s_value.integer);
        }

        if (auth_value.object.get("access_token_key")) |access_token_key_value| {
            if (access_token_key_value != .string) {
                std.log.err("'auth.access_token_key' is not a string", .{});

                return error.BadConfig;
            }

            options.auth.access_token_key = access_token_key_value.string;
        }

        if (auth_value.object.get("refresh_token_exp_s")) |refresh_token_exp_s_value| {
            if (refresh_token_exp_s_value != .integer) {
                std.log.err("'auth.refresh_token_exp_s' is not an integer", .{});

                return error.BadConfig;
            }

            options.auth.refresh_token_exp_s = @intCast(refresh_token_exp_s_value.integer);
        }
    }

    if (root.object.get("system")) |system_value| {
        if (system_value != .object) {
            std.log.err("'system' is not an object", .{});

            return error.BadConfig;
        }

        if (system_value.object.get("token")) |token_value| {
            if (token_value != .string) {
                std.log.err("'system.token' is not a string", .{});

                return error.BadConfig;
            }

            options.system.token = token_value.string;
        }
    }

    if (root.object.get("services")) |services_value| {
        if (services_value != .object) {
            std.log.err("'services' is not an object", .{});

            return error.BadConfig;
        }

        if (services_value.object.get("pwhash")) |pwhash_value| {
            if (pwhash_value != .object) {
                std.log.err("'services.pwhash' is not an object", .{});

                return error.BadConfig;
            }

            if (pwhash_value.object.get("max_jobs")) |max_jobs_value| {
                if (max_jobs_value != .integer) {
                    std.log.err("'services.pwhash.max_jobs' is not an integer", .{});

                    return error.BadConfig;
                }

                options.services.pwhash.max_jobs = @intCast(max_jobs_value.integer);
            }
        }

        if (services_value.object.get("media")) |media_value| {
            if (media_value != .object) {
                std.log.err("'services.media' is not an object", .{});

                return error.BadConfig;
            }

            if (media_value.object.get("max_jobs")) |max_jobs_value| {
                if (max_jobs_value != .integer) {
                    std.log.err("'services.media.max_jobs' is not an integer", .{});

                    return error.BadConfig;
                }

                options.services.media.max_jobs = @intCast(max_jobs_value.integer);
            }
        }

        if (services_value.object.get("files")) |files_value| {
            if (files_value != .object) {
                std.log.err("'services.files' is not an object", .{});

                return error.BadConfig;
            }

            if (files_value.object.get("max_jobs")) |max_jobs_value| {
                if (max_jobs_value != .integer) {
                    std.log.err("'services.files.max_jobs' is not an integer", .{});

                    return error.BadConfig;
                }

                options.services.files.max_jobs = @intCast(max_jobs_value.integer);
            }
        }

        if (services_value.object.get("notifications")) |notifications_value| {
            if (notifications_value != .object) {
                std.log.err("'services.notifications' is not an object", .{});

                return error.BadConfig;
            }

            if (notifications_value.object.get("max_concurrent")) |max_concurrent_value| {
                if (max_concurrent_value != .integer) {
                    std.log.err("'services.notifications.max_concurrent' is not an integer", .{});

                    return error.BadConfig;
                }

                options.services.notifications.max_concurrent = @intCast(max_concurrent_value.integer);
            }

            if (notifications_value.object.get("queue_capacity")) |queue_capacity_value| {
                if (queue_capacity_value != .integer) {
                    std.log.err("'services.notifications.queue_capacity' is not an integer", .{});

                    return error.BadConfig;
                }

                options.services.notifications.queue_capacity = @intCast(queue_capacity_value.integer);
            }

            if (notifications_value.object.get("max_recipients")) |max_recipients_value| {
                if (max_recipients_value != .integer) {
                    std.log.err("'services.notifications.max_recipients' is not an integer", .{});

                    return error.BadConfig;
                }

                options.services.notifications.max_recipients = @intCast(max_recipients_value.integer);
            }
        }
    }

    if (root.object.get("websocket")) |websocket_value| {
        if (websocket_value != .object) {
            std.log.err("'websocket' is not an object", .{});

            return error.BadConfig;
        }

        if (websocket_value.object.get("auth_timeout_ms")) |auth_timeout_ms_value| {
            if (auth_timeout_ms_value != .integer) {
                std.log.err("'websocket.auth_timeout_ms' is not an integer", .{});

                return error.BadConfig;
            }

            options.websocket.auth_timeout_ms = @intCast(auth_timeout_ms_value.integer);
        }

        if (websocket_value.object.get("min_heartbeat_ms")) |min_heartbeat_ms_value| {
            if (min_heartbeat_ms_value != .integer) {
                std.log.err("'websocket.min_heartbeat_ms' is not an integer", .{});

                return error.BadConfig;
            }

            options.websocket.min_heartbeat_ms = @intCast(min_heartbeat_ms_value.integer);
        }

        if (websocket_value.object.get("max_heartbeat_ms")) |max_heartbeat_ms_value| {
            if (max_heartbeat_ms_value != .integer) {
                std.log.err("'websocket.max_heartbeat_ms' is not an integer", .{});

                return error.BadConfig;
            }

            options.websocket.max_heartbeat_ms = @intCast(max_heartbeat_ms_value.integer);
        }

        if (websocket_value.object.get("heartbeat_threshold_ms")) |heartbeat_threshold_ms_value| {
            if (heartbeat_threshold_ms_value != .integer) {
                std.log.err("'websocket.heartbeat_threshold_ms' is not an integer", .{});

                return error.BadConfig;
            }

            options.websocket.heartbeat_threshold_ms = @intCast(heartbeat_threshold_ms_value.integer);
        }
    }

    if (root.object.get("media")) |media_value| {
        if (media_value != .object) {
            std.log.err("'media' is not an object", .{});

            return error.BadConfig;
        }

        if (media_value.object.get("avatar")) |avatar_value| {
            if (avatar_value != .object) {
                std.log.err("'media.avatar' is not an object", .{});

                return error.BadConfig;
            }

            options.media.avatar = try Options.Media.Limits.parse("media.avatar", avatar_value, options.media.avatar);
        }

        if (media_value.object.get("emoji")) |emoji_value| {
            if (emoji_value != .object) {
                std.log.err("'media.emoji' is not an object", .{});

                return error.BadConfig;
            }

            options.media.emoji = try Options.Media.Limits.parse("media.emoji", emoji_value, options.media.emoji);
        }

        if (media_value.object.get("files")) |files_value| {
            if (files_value != .object) {
                std.log.err("'media.files' is not an object", .{});

                return error.BadConfig;
            }

            options.media.files = try Options.Media.Limits.parse("media.files", files_value, options.media.files);
        }
    }

    if (root.object.get("files")) |files_value| {
        if (files_value != .object) {
            std.log.err("'files' is not an object", .{});

            return error.BadConfig;
        }

        const type_value = files_value.object.get("type") orelse {
            std.log.err("missing 'files.type' field", .{});

            return error.BadConfig;
        };

        if (type_value != .string) {
            std.log.err("'files.type' is not a string", .{});

            return error.BadConfig;
        }

        if (std.mem.eql(u8, type_value.string, "none")) {
            options.files.storage = .none;
        } else if (std.mem.eql(u8, type_value.string, "s3")) {
            const s3_value = files_value.object.get("s3") orelse {
                std.log.err("missing 'files.s3' field", .{});

                return error.BadConfig;
            };

            if (s3_value != .object) {
                std.log.err("'files.s3' is not an object", .{});

                return error.BadConfig;
            }

            const endpoint_value = s3_value.object.get("endpoint") orelse {
                std.log.err("missing 'files.s3.endpoint' field", .{});

                return error.BadConfig;
            };

            if (endpoint_value != .string) {
                std.log.err("field 'files.s3.endpoint' is not a string", .{});

                return error.BadConfig;
            }

            const public_base_url_value = s3_value.object.get("public_base_url") orelse {
                std.log.err("missing 'files.s3.public_base_url' field", .{});

                return error.BadConfig;
            };

            if (public_base_url_value != .string) {
                std.log.err("field 'files.s3.public_base_url' is not a string", .{});

                return error.BadConfig;
            }

            const access_key_value = s3_value.object.get("access_key") orelse {
                std.log.err("missing 'files.s3.access_key' field", .{});

                return error.BadConfig;
            };

            if (access_key_value != .string) {
                std.log.err("field 'files.s3.access_key' is not a string", .{});

                return error.BadConfig;
            }

            const region_value = s3_value.object.get("region") orelse {
                std.log.err("missing 'files.s3.region' field", .{});

                return error.BadConfig;
            };

            if (region_value != .string) {
                std.log.err("field 'files.s3.region' is not a string", .{});

                return error.BadConfig;
            }

            const secret_key_value = s3_value.object.get("secret_key") orelse {
                std.log.err("missing 'files.s3.secret_key' field", .{});

                return error.BadConfig;
            };

            if (secret_key_value != .string) {
                std.log.err("field 'files.s3.secret_key' is not a string", .{});

                return error.BadConfig;
            }

            options.files.storage = .{
                .s3 = .{
                    .endpoint = endpoint_value.string,
                    .public_base_url = public_base_url_value.string,
                    .region = region_value.string,
                    .access_key = access_key_value.string,
                    .secret_key = secret_key_value.string,
                },
            };
        } else {
            std.log.err("bad 'files.type' value: '{s}'", .{type_value.string});

            return error.BadConfig;
        }

        if (files_value.object.get("max_size")) |max_size_value| {
            if (max_size_value != .integer) {
                std.log.err("'files.max_size' is not an integer", .{});

                return error.BadConfig;
            }

            if (max_size_value.integer <= 0) {
                std.log.err("'files.max_size' must be greater than zero", .{});

                return error.BadConfig;
            }

            options.files.max_size = @intCast(max_size_value.integer);
        }

        if (files_value.object.get("whitelist")) |whitelist_value| {
            switch (whitelist_value) {
                .null => options.files.whitelist = null,
                .array => |array| {
                    const list = arena.alloc([]const u8, array.items.len) catch {
                        return error.OutOfMemory;
                    };

                    for (array.items, 0..) |item, i| {
                        if (item != .string) {
                            std.log.err("'files.whitelist' entry is not a string", .{});

                            return error.BadConfig;
                        }

                        list[i] = arena.dupe(u8, item.string) catch {
                            return error.OutOfMemory;
                        };
                    }

                    options.files.whitelist = list;
                },
                else => {
                    std.log.err("'files.whitelist' is not an array or null", .{});

                    return error.BadConfig;
                },
            }
        }

        if (files_value.object.get("gc")) |gc_value| {
            if (gc_value != .object) {
                std.log.err("'files.gc' is not an object", .{});

                return error.BadConfig;
            }

            if (gc_value.object.get("interval_s")) |interval_value| {
                if (interval_value != .integer) {
                    std.log.err("'files.gc.interval_s' is not an integer", .{});

                    return error.BadConfig;
                }

                if (interval_value.integer <= 0) {
                    std.log.err("'files.gc.interval_s' must be greater than zero", .{});

                    return error.BadConfig;
                }

                options.files.gc.interval_s = @intCast(interval_value.integer);
            }

            if (gc_value.object.get("grace_s")) |grace_value| {
                if (grace_value != .integer) {
                    std.log.err("'files.gc.grace_s' is not an integer", .{});

                    return error.BadConfig;
                }

                if (grace_value.integer < 0) {
                    std.log.err("'files.gc.grace_s' must not be negative", .{});

                    return error.BadConfig;
                }

                options.files.gc.grace_s = @intCast(grace_value.integer);
            }
        }
    }

    if (root.object.get("push")) |push_value| {
        if (push_value != .object) {
            std.log.err("'push' is not an object", .{});

            return error.BadConfig;
        }

        if (push_value.object.get("enabled")) |enabled_value| {
            if (enabled_value != .bool) {
                std.log.err("'push.enabled' is not a boolean", .{});

                return error.BadConfig;
            }

            options.push.enabled = enabled_value.bool;
        }

        if (push_value.object.get("vapid")) |vapid_value| {
            if (vapid_value != .object) {
                std.log.err("'push.vapid' is not an object", .{});

                return error.BadConfig;
            }

            if (vapid_value.object.get("subject")) |subject_value| {
                if (subject_value != .string) {
                    std.log.err("'push.vapid.subject' is not a string", .{});

                    return error.BadConfig;
                }

                options.push.vapid.subject = subject_value.string;
            }

            if (vapid_value.object.get("public_key")) |public_key_value| {
                if (public_key_value != .string) {
                    std.log.err("'push.vapid.public_key' is not a string", .{});

                    return error.BadConfig;
                }

                options.push.vapid.public_key = public_key_value.string;
            }

            if (vapid_value.object.get("private_key")) |private_key_value| {
                if (private_key_value != .string) {
                    std.log.err("'push.vapid.private_key' is not a string", .{});

                    return error.BadConfig;
                }

                options.push.vapid.private_key = private_key_value.string;
            }
        }

        if (push_value.object.get("ttl_s")) |ttl_value| {
            if (ttl_value != .integer) {
                std.log.err("'push.ttl_s' is not an integer", .{});

                return error.BadConfig;
            }

            options.push.ttl_s = @intCast(ttl_value.integer);
        }

        if (push_value.object.get("max_preview_codepoints")) |preview_value| {
            if (preview_value != .integer) {
                std.log.err("'push.max_preview_codepoints' is not an integer", .{});

                return error.BadConfig;
            }

            options.push.max_preview_codepoints = @intCast(preview_value.integer);
        }
    }

    // A zero timeout would free every peer as soon as it is checked.
    if (options.socket.disconnect_timeout_ms == 0) {
        std.log.err("'socket.disconnect_timeout_ms' must be greater than zero", .{});

        return error.BadConfig;
    }

    if (options.http.read_timeout_ms == 0) {
        std.log.err("'http.read_timeout_ms' must be greater than zero", .{});

        return error.BadConfig;
    }

    if (options.http.write_timeout_ms == 0) {
        std.log.err("'http.write_timeout_ms' must be greater than zero", .{});

        return error.BadConfig;
    }

    if (options.websocket.auth_timeout_ms == 0) {
        std.log.err("'websocket.auth_timeout_ms' must be greater than zero", .{});

        return error.BadConfig;
    }

    if (options.services.media.max_jobs == 0) {
        std.log.err("'services.media.max_jobs' must be greater than zero", .{});

        return error.BadConfig;
    }

    if (options.services.files.max_jobs == 0) {
        std.log.err("'services.files.max_jobs' must be greater than zero", .{});

        return error.BadConfig;
    }

    if (options.services.notifications.max_concurrent == 0) {
        std.log.err("'services.notifications.max_concurrent' must be greater than zero", .{});

        return error.BadConfig;
    }

    if (options.services.notifications.queue_capacity == 0) {
        std.log.err("'services.notifications.queue_capacity' must be greater than zero", .{});

        return error.BadConfig;
    }

    if (options.services.notifications.max_recipients == 0) {
        std.log.err("'services.notifications.max_recipients' must be greater than zero", .{});

        return error.BadConfig;
    }

    // VAPID keys are only required when push is enabled; with push disabled the
    // subscription endpoints still work and the dispatcher does not send.
    if (options.push.enabled) {
        if (options.push.vapid.subject.len == 0) {
            std.log.err("'push.vapid.subject' is required when 'push.enabled' is true", .{});

            return error.BadConfig;
        }

        const public_key = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(options.push.vapid.public_key) catch {
            std.log.err("'push.vapid.public_key' is not valid base64url", .{});

            return error.BadConfig;
        };

        if (public_key != 65) {
            std.log.err("'push.vapid.public_key' must decode to 65 bytes", .{});

            return error.BadConfig;
        }

        const private_key = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(options.push.vapid.private_key) catch {
            std.log.err("'push.vapid.private_key' is not valid base64url", .{});

            return error.BadConfig;
        };

        if (private_key != 32) {
            std.log.err("'push.vapid.private_key' must decode to 32 bytes", .{});

            return error.BadConfig;
        }
    }

    return options;
}
