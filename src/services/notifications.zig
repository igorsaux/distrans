// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../root.zig");

const curl = @import("curl");

const SCOPE = std.log.scoped(.notifications);

const P256 = std.crypto.ecc.P256;
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;
const Sha256 = std.crypto.hash.sha2.Sha256;
const EcdsaP256Sha256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;

pub inline fn endpointHash(endpoint: []const u8) [32]u8 {
    var out: [32]u8 = undefined;

    Sha256.hash(endpoint, &out, .{});

    return out;
}

/// Whether `p256dh` is an uncompressed SEC-1 P-256 point (validated to be on
/// the curve, not just 65 bytes long). Used by the subscription endpoint so a
/// malformed key is rejected before it reaches the worker.
pub inline fn isValidP256dh(p256dh: []const u8) bool {
    if (p256dh.len != 65) {
        return false;
    }

    _ = P256.fromSec1(p256dh) catch {
        return false;
    };

    return true;
}

/// Encrypts `plaintext` for a push subscription (RFC 8291, `aes128gcm`).
/// `ua_public` is the receiver's uncompressed P-256 point, `auth_secret` its
/// 16-byte authentication secret, `salt` the record salt and `ephemeral` the
/// application-server key pair. The salt and key pair are parameters (normally
/// random) so the RFC test vector can be reproduced.
pub fn encryptWith(
    allocator: std.mem.Allocator,
    ua_public: P256,
    auth_secret: [16]u8,
    salt: [16]u8,
    ephemeral: EcdsaP256Sha256.KeyPair,
    plaintext: []const u8,
) ![]u8 {
    const as_public = ephemeral.public_key.toUncompressedSec1();

    // ECDH: the x-coordinate of `ua_public * as_private`.
    const shared = try ua_public.mul(ephemeral.secret_key.toBytes(), .big);
    const ecdh_secret = shared.affineCoordinates().x.toBytes(.big);

    // key_info = "WebPush: info" || 0x00 || ua_public || as_public
    const key_info_prefix = "WebPush: info\x00";
    const cek_info = "Content-Encoding: aes128gcm\x00";
    const nonce_info = "Content-Encoding: nonce\x00";

    var key_info: [key_info_prefix.len + 65 + 65]u8 = undefined;
    @memcpy(key_info[0..key_info_prefix.len], key_info_prefix);
    @memcpy(key_info[key_info_prefix.len..][0..65], &ua_public.toUncompressedSec1());
    @memcpy(key_info[key_info_prefix.len + 65 ..][0..65], &as_public);

    // PRK_key = HKDF-Extract(auth_secret, ecdh_secret); IKM = HKDF-Expand(PRK_key, key_info, 32)
    const key_prk = HkdfSha256.extract(&auth_secret, &ecdh_secret);

    var ikm: [32]u8 = undefined;
    HkdfSha256.expand(&ikm, &key_info, key_prk);

    // PRK = HKDF-Extract(salt, IKM); CEK / NONCE = HKDF-Expand(PRK, info, L)
    const prk = HkdfSha256.extract(&salt, &ikm);

    var cek: [16]u8 = undefined;
    HkdfSha256.expand(&cek, cek_info, prk);

    var nonce: [12]u8 = undefined;
    HkdfSha256.expand(&nonce, nonce_info, prk);

    // Single final record: plaintext || 0x02.
    const padded = try allocator.alloc(u8, plaintext.len + 1);
    defer allocator.free(padded);

    @memcpy(padded[0..plaintext.len], plaintext);
    padded[plaintext.len] = 0x02;

    const ciphertext = try allocator.alloc(u8, padded.len);
    defer allocator.free(ciphertext);

    var tag: [Aes128Gcm.tag_length]u8 = undefined;
    Aes128Gcm.encrypt(ciphertext, &tag, padded, "", nonce, cek);

    // Body: salt(16) || rs(4)=4096 || idlen(1)=65 || keyid(65) || ciphertext || tag.
    const body = try allocator.alloc(u8, 16 + 4 + 1 + 65 + ciphertext.len + tag.len);

    var pos: usize = 0;
    @memcpy(body[pos..][0..16], &salt);
    pos += 16;
    std.mem.writeInt(u32, body[pos..][0..4], 4096, .big);
    pos += 4;
    body[pos] = 65;
    pos += 1;
    @memcpy(body[pos..][0..65], &as_public);
    pos += 65;
    @memcpy(body[pos..][0..ciphertext.len], ciphertext);
    pos += ciphertext.len;
    @memcpy(body[pos..][0..tag.len], &tag);

    return body;
}

inline fn encryptMessage(
    allocator: std.mem.Allocator,
    p256dh: []const u8,
    auth: []const u8,
    plaintext: []const u8,
) ![]u8 {
    if (p256dh.len != 65 or auth.len != 16) {
        return error.BadSubscription;
    }

    const ua_public = try P256.fromSec1(p256dh);

    var salt: [16]u8 = undefined;
    try std.Io.randomSecure(root.io, &salt);

    var seed: [EcdsaP256Sha256.KeyPair.seed_length]u8 = undefined;
    try std.Io.randomSecure(root.io, &seed);

    const ephemeral = try EcdsaP256Sha256.KeyPair.generateDeterministic(seed);

    return encryptWith(allocator, ua_public, auth[0..16].*, salt, ephemeral, plaintext);
}

/// The origin (`scheme://authority`) of a push endpoint; the VAPID `aud` claim.
inline fn endpointOrigin(endpoint: []const u8) ![]const u8 {
    const scheme_end = std.mem.indexOf(u8, endpoint, "://") orelse {
        return error.BadEndpoint;
    };

    const after_scheme = scheme_end + 3;
    const authority_end = std.mem.indexOfScalarPos(u8, endpoint, after_scheme, '/') orelse endpoint.len;

    if (authority_end == after_scheme) {
        return error.BadEndpoint;
    }

    return endpoint[0..authority_end];
}

inline fn base64Url(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const encoded_len = std.base64.url_safe_no_pad.Encoder.calcSize(bytes.len);
    const out = try allocator.alloc(u8, encoded_len);

    return std.base64.url_safe_no_pad.Encoder.encode(out, bytes);
}

/// The `Authorization: vapid t=<jwt>, k=<key>` header value. The JWT is ES256
/// over the configured VAPID key pair (RFC 8292).
inline fn vapidAuthorization(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
) ![]u8 {
    const vapid = root.options.push.vapid;

    const origin = try endpointOrigin(endpoint);

    const now_s: u64 = @intCast(std.Io.Timestamp.now(root.io, .real).toSeconds());
    const expires = now_s + 12 * 3600;

    const header = "{\"typ\":\"JWT\",\"alg\":\"ES256\"}";
    const claims = try std.fmt.allocPrint(
        allocator,
        "{{\"aud\":\"{s}\",\"exp\":{d},\"sub\":\"{s}\"}}",
        .{ origin, expires, vapid.subject },
    );

    const header_b64 = try base64Url(allocator, header);
    const claims_b64 = try base64Url(allocator, claims);
    const signing_input = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ header_b64, claims_b64 });

    var private_key: [32]u8 = undefined;
    std.base64.url_safe_no_pad.Decoder.decode(&private_key, vapid.private_key) catch {
        return error.BadVapidKey;
    };

    const secret_key = try EcdsaP256Sha256.SecretKey.fromBytes(private_key);
    const key_pair = try EcdsaP256Sha256.KeyPair.fromSecretKey(secret_key);

    var noise: [EcdsaP256Sha256.noise_length]u8 = undefined;
    try std.Io.randomSecure(root.io, &noise);

    const signature = try key_pair.sign(signing_input, noise);
    const signature_bytes = signature.toBytes();
    const signature_b64 = try base64Url(allocator, &signature_bytes);

    const jwt = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ signing_input, signature_b64 });

    return std.fmt.allocPrint(allocator, "Authorization: vapid t={s}, k={s}", .{ jwt, vapid.public_key });
}

// ---------------------------------------------------------------------------
// Sender
// ---------------------------------------------------------------------------

pub const Status = enum {
    /// The push service accepted the message.
    delivered,
    /// The subscription is no longer valid (HTTP 404/410) and must be removed.
    gone,
    /// A transient or unrelated failure.
    failed,
};

/// Sends push notifications with libcurl's multi interface: one worker thread
/// multiplexes up to `max_concurrent` concurrent transfers per window. The
/// dispatcher submits one window of subscriptions per message and polls for
/// the per-subscription statuses; the multi handle is kept across windows and
/// messages so its connection cache is reused. One window may be in flight at
/// a time, which bounds the memory to `max_concurrent` easy handles.
pub const Sender = struct {
    pub const Subscription = struct {
        user_id: root.types.UserId,
        endpoint: []const u8,
        p256dh: []const u8,
        auth: []const u8,
    };

    pub const Batch = struct {
        plaintext: []const u8,
        ttl_s: u64,
        subs: []const Subscription,
    };

    pub const Result = struct {
        /// Index-aligned with the submitted window.
        statuses: []Status,

        pub inline fn deinit(this: Result) void {
            root.gpa.free(this.statuses);
        }
    };

    pub const JobResult = union(enum) {
        ok: Result,
        err: anyerror,
    };

    const OwnedSubscription = struct {
        user_id: root.types.UserId,
        endpoint: []u8,
        p256dh: []u8,
        auth: []u8,
    };

    const OwnedBatch = struct {
        plaintext: []u8,
        ttl_s: u64,
        subs: []OwnedSubscription,

        fn deinit(this: OwnedBatch) void {
            for (this.subs) |sub| {
                root.gpa.free(sub.endpoint);
                root.gpa.free(sub.p256dh);
                root.gpa.free(sub.auth);
            }

            root.gpa.free(this.subs);
            root.gpa.free(this.plaintext);
        }
    };

    const State = union(enum) {
        free,
        working: OwnedBatch,
        done: Result,
        err: anyerror,
    };

    max_concurrent: usize,
    mutex: std.Io.Mutex = .init,
    state: State = .free,
    exiting: std.atomic.Value(bool) = .init(false),
    new_event: std.Io.Event = .unset,
    thread: ?std.Thread = null,
    multi: ?*curl.CURLM = null,
    scratch: std.heap.ArenaAllocator,

    pub inline fn init(max_concurrent: usize) !Sender {
        if (curl.curl_global_init(curl.CURL_GLOBAL_DEFAULT) != curl.CURLE_OK) {
            SCOPE.err("failed to initialize libcurl", .{});

            return error.Curl;
        }

        return .{
            .max_concurrent = max_concurrent,
            .scratch = .init(root.gpa),
        };
    }

    pub inline fn deinit(this: *Sender) void {
        // The worker thread is already joined, so the lock is uncontended.
        this.mutex.lock(root.io) catch @panic("failed to lock mutex");
        this.toFree();
        this.mutex.unlock(root.io);

        if (this.multi) |multi| {
            _ = curl.curl_multi_cleanup(multi);
            this.multi = null;
        }

        this.scratch.deinit();
    }

    pub inline fn run(this: *Sender) !void {
        std.debug.assert(this.thread == null);

        this.thread = try std.Thread.spawn(.{
            .allocator = root.gpa,
        }, workerThread, .{this});
    }

    pub inline fn stop(this: *Sender) void {
        std.debug.assert(this.thread != null);

        this.exiting.store(true, .monotonic);
        this.new_event.set(root.io);
        this.thread.?.join();
        this.thread = null;
    }

    inline fn awake(this: *Sender) void {
        this.new_event.set(root.io);
    }

    /// Submits one window of subscriptions. Deep-copies the slices so the
    /// caller's arena may be reused. Returns false when a previous window has
    /// not been collected with `poll` yet.
    pub inline fn submit(this: *Sender, batch: Batch) !bool {
        if (!this.mutex.tryLock()) {
            return false;
        }
        defer this.mutex.unlock(root.io);

        switch (this.state) {
            .free => {},
            else => return false,
        }

        const owned = try copyBatch(batch);

        this.state = .{ .working = owned };
        this.awake();

        return true;
    }

    /// Non-blocking. Returns null while no window is ready, the result of a
    /// finished window (owned by the caller), or a worker error.
    pub inline fn poll(this: *Sender) ?JobResult {
        if (!this.mutex.tryLock()) {
            return null;
        }
        defer this.mutex.unlock(root.io);

        switch (this.state) {
            .err => |err| {
                this.state = .free;
                return .{ .err = err };
            },
            .done => |result| {
                this.state = .free;
                return .{ .ok = result };
            },
            else => return null,
        }
    }

    inline fn toFree(this: *Sender) void {
        switch (this.state) {
            .working => |owned| owned.deinit(),
            .done => |result| result.deinit(),
            else => {},
        }

        this.state = .free;
    }

    inline fn copyBatch(batch: Batch) !OwnedBatch {
        const subs = try root.gpa.alloc(OwnedSubscription, batch.subs.len);
        errdefer root.gpa.free(subs);

        var copied: usize = 0;
        errdefer for (subs[0..copied]) |sub| {
            root.gpa.free(sub.endpoint);
            root.gpa.free(sub.p256dh);
            root.gpa.free(sub.auth);
        };

        for (batch.subs, 0..) |sub, i| {
            const endpoint = try root.gpa.dupe(u8, sub.endpoint);
            errdefer root.gpa.free(endpoint);

            const p256dh = try root.gpa.dupe(u8, sub.p256dh);
            errdefer root.gpa.free(p256dh);

            const auth = try root.gpa.dupe(u8, sub.auth);

            subs[i] = .{
                .user_id = sub.user_id,
                .endpoint = endpoint,
                .p256dh = p256dh,
                .auth = auth,
            };

            copied = i + 1;
        }

        const plaintext = try root.gpa.dupe(u8, batch.plaintext);

        return .{
            .plaintext = plaintext,
            .ttl_s = batch.ttl_s,
            .subs = subs,
        };
    }

    fn workerThread(this: *Sender) void {
        while (true) {
            this.new_event.wait(root.io) catch @panic("failed to wait for an event");
            this.new_event.reset();

            if (this.exiting.load(.monotonic)) {
                return;
            }

            this.doBatch();
        }
    }

    fn doBatch(this: *Sender) void {
        this.mutex.lock(root.io) catch @panic("failed to lock mutex");

        const owned = switch (this.state) {
            .working => |owned| owned,
            else => {
                this.mutex.unlock(root.io);

                return;
            },
        };

        this.mutex.unlock(root.io);

        _ = this.scratch.reset(.retain_capacity);

        const result = this.runBatch(this.scratch.allocator(), owned) catch |err| {
            this.mutex.lock(root.io) catch @panic("failed to lock mutex");
            this.toFree();
            this.state = .{ .err = err };
            this.mutex.unlock(root.io);

            return;
        };

        this.mutex.lock(root.io) catch @panic("failed to lock mutex");
        this.toFree();
        this.state = .{ .done = result };
        this.mutex.unlock(root.io);
    }

    inline fn isHttpUrl(endpoint: []const u8) bool {
        return std.mem.startsWith(u8, endpoint, "http://") or
            std.mem.startsWith(u8, endpoint, "https://");
    }

    inline fn mapStatus(http_code: c_long) Status {
        if (http_code >= 200 and http_code < 300) {
            return .delivered;
        }

        if (http_code == 404 or http_code == 410) {
            return .gone;
        }

        if (http_code != 0) {
            SCOPE.warn("push service returned HTTP {d}", .{http_code});
        }

        return .failed;
    }

    fn runBatch(
        this: *Sender,
        scratch: std.mem.Allocator,
        owned: OwnedBatch,
    ) !Result {
        const count = owned.subs.len;

        const statuses = try root.gpa.alloc(Status, count);
        errdefer root.gpa.free(statuses);

        @memset(statuses, .failed);

        if (this.multi == null) {
            this.multi = curl.curl_multi_init() orelse return error.Curl;
        }

        const multi = this.multi.?;

        // Bound the number of concurrent transfers the multi handle runs.
        _ = curl.curl_multi_setopt(multi, curl.CURLMOPT_MAX_TOTAL_CONNECTIONS, @as(c_long, @intCast(this.max_concurrent)));
        _ = curl.curl_multi_setopt(multi, curl.CURLMOPT_MAXCONNECTS, @as(c_long, @intCast(this.max_concurrent)));

        const handles = try scratch.alloc(?*curl.CURL, count);
        const lists = try scratch.alloc(?*curl.curl_slist, count);

        @memset(handles, null);
        @memset(lists, null);

        var added: usize = 0;

        for (owned.subs, 0..) |sub, i| {
            // Never let a subscription URL turn the sender into an SSRF gadget
            // for non-HTTP schemes.
            if (!isHttpUrl(sub.endpoint)) {
                continue;
            }

            const body = encryptMessage(scratch, sub.p256dh, sub.auth, owned.plaintext) catch |err| {
                SCOPE.warn("failed to encrypt a push payload: {t}", .{err});

                continue;
            };

            const authorization = vapidAuthorization(scratch, sub.endpoint) catch |err| {
                SCOPE.warn("failed to build the VAPID authorization: {t}", .{err});

                continue;
            };

            const handle = curl.curl_easy_init() orelse continue;

            const url_z = scratch.dupeZ(u8, sub.endpoint) catch {
                curl.curl_easy_cleanup(handle);

                continue;
            };
            const ttl_z = std.fmt.allocPrintSentinel(scratch, "TTL: {d}", .{owned.ttl_s}, 0) catch {
                curl.curl_easy_cleanup(handle);

                continue;
            };
            const authorization_z = scratch.dupeZ(u8, authorization) catch {
                curl.curl_easy_cleanup(handle);

                continue;
            };

            _ = curl.curl_easy_setopt(handle, curl.CURLOPT_URL, url_z.ptr);
            _ = curl.curl_easy_setopt(handle, curl.CURLOPT_NOSIGNAL, @as(c_long, 1));
            _ = curl.curl_easy_setopt(handle, curl.CURLOPT_CONNECTTIMEOUT_MS, @as(c_long, 5000));
            _ = curl.curl_easy_setopt(handle, curl.CURLOPT_TIMEOUT_MS, @as(c_long, 10000));
            _ = curl.curl_easy_setopt(handle, curl.CURLOPT_POSTFIELDS, body.ptr);
            _ = curl.curl_easy_setopt(handle, curl.CURLOPT_POSTFIELDSIZE_LARGE, @as(curl.curl_off_t, @intCast(body.len)));

            var headers: ?*curl.curl_slist = null;

            headers = curl.curl_slist_append(headers, "Content-Encoding: aes128gcm");
            headers = curl.curl_slist_append(headers, "Content-Type: application/octet-stream");
            headers = curl.curl_slist_append(headers, ttl_z.ptr);
            headers = curl.curl_slist_append(headers, authorization_z.ptr);

            _ = curl.curl_easy_setopt(handle, curl.CURLOPT_HTTPHEADER, headers);

            if (curl.curl_multi_add_handle(multi, handle) != curl.CURLM_OK) {
                curl.curl_slist_free_all(headers);
                curl.curl_easy_cleanup(handle);

                continue;
            }

            lists[i] = headers;
            handles[i] = handle;
            added += 1;
        }

        if (added > 0) {
            var running: c_int = 0;

            _ = curl.curl_multi_perform(multi, &running);

            while (running > 0) {
                var numfds: c_int = 0;

                _ = curl.curl_multi_poll(multi, null, 0, 1000, &numfds);

                if (curl.curl_multi_perform(multi, &running) != curl.CURLM_OK) {
                    break;
                }
            }
        }

        for (handles, 0..) |maybe_handle, i| {
            const handle = maybe_handle orelse continue;

            var http_code: c_long = 0;
            _ = curl.curl_easy_getinfo(handle, curl.CURLINFO_RESPONSE_CODE, &http_code);

            statuses[i] = mapStatus(http_code);

            _ = curl.curl_multi_remove_handle(multi, handle);

            if (lists[i]) |headers| {
                curl.curl_slist_free_all(headers);
            }

            curl.curl_easy_cleanup(handle);
        }

        return .{ .statuses = statuses };
    }
};

// ---------------------------------------------------------------------------
// Queue
// ---------------------------------------------------------------------------

/// A message-created notification. The mention slices are owned by the queue
/// and freed by `deinit`.
pub const Job = struct {
    message_id: root.types.MessageId,
    channel_id: root.types.ChannelId,
    guild_id: root.types.GuildId,
    author_id: ?root.types.UserId = null,
    webhook_id: ?root.types.WebhookId = null,
    mention_everyone: bool,
    mention_user_ids: []root.types.UserId,
    mention_role_ids: []root.types.RoleId,

    pub inline fn deinit(this: *const Job) void {
        root.gpa.free(this.mention_user_ids);
        root.gpa.free(this.mention_role_ids);
    }
};

const Queue = struct {
    allocator: std.mem.Allocator,
    slots: []?Job,
    head: usize = 0,
    len: usize = 0,

    inline fn init(allocator: std.mem.Allocator, capacity: usize) !Queue {
        const slots = try allocator.alloc(?Job, capacity);

        @memset(slots, null);

        return .{
            .allocator = allocator,
            .slots = slots,
        };
    }

    inline fn deinit(this: *Queue) void {
        while (this.tryPop()) |job| {
            job.deinit();
        }

        this.allocator.free(this.slots);
    }

    inline fn tryPush(this: *Queue, job: Job) bool {
        if (this.len == this.slots.len) {
            return false;
        }

        const tail = (this.head + this.len) % this.slots.len;
        this.slots[tail] = job;
        this.len += 1;

        return true;
    }

    inline fn tryPop(this: *Queue) ?Job {
        if (this.len == 0) {
            return null;
        }

        const job = this.slots[this.head].?;
        this.slots[this.head] = null;
        this.head = (this.head + 1) % this.slots.len;
        this.len -= 1;

        return job;
    }
};

// ---------------------------------------------------------------------------
// Dispatcher
// ---------------------------------------------------------------------------

pub const Dispatcher = struct {
    const State = enum {
        idle,
        acquiring,
        resolving,
        rights,
        message,
        subscriptions,
        sending,
        cleanup,
    };

    const Target = struct {
        user_id: root.types.UserId,
    };

    const GoneSubscription = struct {
        user_id: root.types.UserId,
        endpoint_hash: [32]u8,
    };

    allocator: std.mem.Allocator,
    queue: Queue,
    state: State = .idle,
    arena: std.heap.ArenaAllocator,

    job: ?Job = null,
    db: ?*root.db.Connection = null,

    resolve_task: ?root.repo.notifications_fanout.ResolveRecipients.Lazy = null,
    recipients: []const root.repo.notifications_fanout.ResolveRecipients.Item = &.{},
    rights_index: usize = 0,
    rights_user_id: root.types.UserId = 0,
    rights_task: ?root.repo.rights.CheckUserChannelRights.Lazy = null,
    targets: std.ArrayList(Target) = .empty,

    message_task: ?root.repo.notifications_fanout.GetMessageForPush.Lazy = null,
    plaintext: ?[]const u8 = null,

    subs_task: ?root.repo.push_subscriptions.ListForUsers.Lazy = null,
    subs: []const root.repo.push_subscriptions.ListForUsers.Item = &.{},
    window_start: usize = 0,
    window_base: usize = 0,
    sender_busy: bool = false,

    gone: std.ArrayList(GoneSubscription) = .empty,
    cleanup_index: usize = 0,
    cleanup_user_id: root.types.UserId = 0,
    cleanup_hash: [32]u8 = undefined,
    cleanup_task: ?root.repo.push_subscriptions.DeleteByEndpointHash.Lazy = null,

    warned_disabled: bool = false,
    warned_overflow: bool = false,

    pub inline fn init(allocator: std.mem.Allocator, capacity: usize) !Dispatcher {
        return .{
            .allocator = allocator,
            .queue = try Queue.init(allocator, capacity),
            .arena = .init(allocator),
        };
    }

    pub inline fn deinit(this: *Dispatcher) void {
        this.finishJob();

        this.queue.deinit();
        this.arena.deinit();
    }

    /// Enqueues a message-create notification. Called from the message route on
    /// the event-loop thread. Never blocks: when push is disabled or the queue
    /// is full the notification is dropped and the message is unaffected.
    pub inline fn enqueue(
        this: *Dispatcher,
        message_id: root.types.MessageId,
        channel_id: root.types.ChannelId,
        guild_id: root.types.GuildId,
        author_id: ?root.types.UserId,
        webhook_id: ?root.types.WebhookId,
        mention_everyone: bool,
        mention_user_ids: []const root.types.UserId,
        mention_role_ids: []const root.types.RoleId,
    ) void {
        if (!root.options.push.enabled) {
            if (!this.warned_disabled) {
                this.warned_disabled = true;

                SCOPE.warn("push is disabled ('push.enabled' is false): notifications are dropped", .{});
            }

            return;
        }

        const users = root.gpa.dupe(root.types.UserId, mention_user_ids) catch |err| {
            SCOPE.err("failed to copy the mention users: {t}", .{err});

            return;
        };

        const roles = root.gpa.dupe(root.types.RoleId, mention_role_ids) catch |err| {
            root.gpa.free(users);

            SCOPE.err("failed to copy the mention roles: {t}", .{err});

            return;
        };

        const job: Job = .{
            .message_id = message_id,
            .channel_id = channel_id,
            .guild_id = guild_id,
            .author_id = author_id,
            .webhook_id = webhook_id,
            .mention_everyone = mention_everyone,
            .mention_user_ids = users,
            .mention_role_ids = roles,
        };

        if (!this.queue.tryPush(job)) {
            if (!this.warned_overflow) {
                this.warned_overflow = true;

                SCOPE.warn("the notification queue is full: dropping notifications", .{});
            }

            job.deinit();
        }
    }

    inline fn releaseTasks(this: *Dispatcher) void {
        if (this.resolve_task) |*t| {
            t.dispose();
            this.resolve_task = null;
        }

        if (this.rights_task) |*t| {
            t.dispose();
            this.rights_task = null;
        }

        if (this.message_task) |*t| {
            t.dispose();
            this.message_task = null;
        }

        if (this.subs_task) |*t| {
            t.dispose();
            this.subs_task = null;
        }

        if (this.cleanup_task) |*t| {
            t.dispose();
            this.cleanup_task = null;
        }
    }

    inline fn finishJob(this: *Dispatcher) void {
        this.gone.deinit(this.arena.allocator());
        this.gone = .empty;

        this.targets.deinit(this.arena.allocator());
        this.targets = .empty;

        this.releaseTasks();

        if (this.db) |db| {
            db.release();
            this.db = null;
        }

        if (this.job) |*job| {
            job.deinit();
            this.job = null;
        }

        _ = this.arena.reset(.retain_capacity);

        this.recipients = &.{};
        this.rights_index = 0;
        this.subs = &.{};
        this.window_start = 0;
        this.window_base = 0;
        this.sender_busy = false;
        this.cleanup_index = 0;
        this.plaintext = null;
        this.state = .idle;
    }

    pub inline fn tick(this: *Dispatcher, now_ms: u64) void {
        _ = now_ms;

        switch (this.state) {
            .idle => {
                const job = this.queue.tryPop() orelse return;

                this.job = job;
                this.state = .acquiring;
                this.tryAcquire();
            },
            .acquiring => this.tryAcquire(),
            .resolving => this.stepResolving(),
            .rights => this.stepRights(),
            .message => this.stepMessage(),
            .subscriptions => this.stepSubscriptions(),
            .sending => this.stepSending(),
            .cleanup => this.stepCleanup(),
        }
    }

    inline fn tryAcquire(this: *Dispatcher) void {
        this.db = root.db_pool.rent() orelse return;

        this.state = .resolving;
    }

    inline fn stepResolving(this: *Dispatcher) void {
        const job = this.job.?;

        // await this.resolve_task
        {
            if (this.resolve_task == null) {
                this.resolve_task = .from(.init(this.arena.allocator(), this.db.?, .{
                    .user_ids = job.mention_user_ids,
                    .role_ids = job.mention_role_ids,
                    .guild_id = job.guild_id,
                    .channel_id = job.channel_id,
                    .author_id = job.author_id,
                    .mention_everyone = job.mention_everyone,
                    .limit = root.options.services.notifications.max_recipients,
                }));
            }

            while (this.resolve_task.?.await()) |res| {
                switch (res) {
                    .pending => return,
                    .err => |err| {
                        SCOPE.err("failed to resolve the notification recipients: {t}", .{err});
                        this.finishJob();

                        return;
                    },
                    .ready => {},
                }
            }
        }

        this.recipients = this.resolve_task.?.result;
        this.rights_index = 0;
        this.state = .rights;
    }

    /// Starts at most one rights check per tick and collects the survivors.
    fn stepRights(this: *Dispatcher) void {
        if (this.rights_task) |*task| {
            while (task.await()) |res| {
                switch (res) {
                    .pending => return,
                    .err => |err| {
                        SCOPE.err("failed to check the read_messages right: {t}", .{err});

                        task.dispose();
                        this.rights_task = null;
                        this.finishJob();

                        return;
                    },
                    .ready => {},
                }
            }

            const allowed = task.result;

            task.dispose();
            this.rights_task = null;

            if (allowed) {
                this.targets.append(this.arena.allocator(), .{
                    .user_id = this.rights_user_id,
                }) catch |err| {
                    SCOPE.err("failed to grow the target list: {t}", .{err});
                    this.finishJob();

                    return;
                };
            }

            this.rights_index += 1;
        }

        while (this.rights_index < this.recipients.len) {
            const recipient = this.recipients[this.rights_index];

            // A connected user does not need a push.
            if (root.presence.isOnline(recipient.user_id)) {
                this.rights_index += 1;

                continue;
            }

            this.rights_user_id = recipient.user_id;
            this.rights_task = .from(.init(this.db.?, .{
                .guild_id = this.job.?.guild_id,
                .channel_id = this.job.?.channel_id,
                .user_id = recipient.user_id,
                .required = .{ .read_messages = true },
            }));

            return;
        }

        this.state = .message;
    }

    fn stepMessage(this: *Dispatcher) void {
        const job = this.job.?;

        // await this.message_task
        {
            if (this.message_task == null) {
                this.message_task = .from(.init(this.arena.allocator(), this.db.?, .{
                    .message_id = job.message_id,
                }));
            }

            while (this.message_task.?.await()) |res| {
                switch (res) {
                    .pending => return,
                    .err => |err| {
                        SCOPE.err("failed to read the message for a push: {t}", .{err});
                        this.finishJob();

                        return;
                    },
                    .ready => {},
                }
            }
        }

        const message = this.message_task.?.result orelse {
            // The message was deleted before we got to it.
            this.finishJob();

            return;
        };

        this.plaintext = buildPlaintext(this.arena.allocator(), job, message) catch |err| {
            SCOPE.err("failed to build the push payload: {t}", .{err});
            this.finishJob();

            return;
        };

        this.state = .subscriptions;
    }

    fn stepSubscriptions(this: *Dispatcher) void {
        if (this.targets.items.len == 0) {
            this.finishJob();

            return;
        }

        // await this.subs_task
        {
            if (this.subs_task == null) {
                const user_ids = this.arena.allocator().alloc(root.types.UserId, this.targets.items.len) catch |err| {
                    SCOPE.err("failed to prepare the subscription lookup: {t}", .{err});
                    this.finishJob();

                    return;
                };

                for (this.targets.items, 0..) |target, i| {
                    user_ids[i] = target.user_id;
                }

                this.subs_task = .from(.init(this.arena.allocator(), this.db.?, .{
                    .user_ids = user_ids,
                }));
            }

            while (this.subs_task.?.await()) |res| {
                switch (res) {
                    .pending => return,
                    .err => |err| {
                        SCOPE.err("failed to list the push subscriptions: {t}", .{err});
                        this.finishJob();

                        return;
                    },
                    .ready => {},
                }
            }
        }

        this.subs = this.subs_task.?.result;
        this.window_start = 0;
        this.window_base = 0;
        this.sender_busy = false;
        this.state = .sending;
    }

    fn stepSending(this: *Dispatcher) void {
        // Collect a finished window first so the sender becomes free.
        if (this.sender_busy) {
            const outcome = root.notifications_worker.poll() orelse return;

            this.sender_busy = false;

            switch (outcome) {
                .ok => |result| {
                    for (result.statuses, 0..) |status, i| {
                        if (status != .gone) {
                            continue;
                        }

                        const sub = this.subs[this.window_base + i];

                        this.gone.append(this.arena.allocator(), .{
                            .user_id = sub.user_id,
                            .endpoint_hash = endpointHash(sub.endpoint),
                        }) catch {};
                    }

                    result.deinit();
                },
                .err => |err| SCOPE.warn("a push window failed: {t}", .{err}),
            }
        }

        if (this.window_start >= this.subs.len) {
            this.cleanup_index = 0;
            this.state = .cleanup;

            return;
        }

        const max_concurrent = root.options.services.notifications.max_concurrent;
        const window = this.subs[this.window_start..@min(this.window_start + max_concurrent, this.subs.len)];

        const batch = this.arena.allocator().alloc(Sender.Subscription, window.len) catch |err| {
            SCOPE.err("failed to prepare a push window: {t}", .{err});
            this.finishJob();

            return;
        };

        for (window, 0..) |sub, i| {
            batch[i] = .{
                .user_id = sub.user_id,
                .endpoint = sub.endpoint,
                .p256dh = sub.p256dh,
                .auth = sub.auth,
            };
        }

        const submitted = root.notifications_worker.submit(.{
            .plaintext = this.plaintext.?,
            .ttl_s = root.options.push.ttl_s,
            .subs = batch,
        }) catch |err| {
            SCOPE.err("failed to submit a push window: {t}", .{err});
            this.finishJob();

            return;
        };

        if (!submitted) {
            // The sender has not been collected yet; retry next tick.
            return;
        }

        this.window_base = this.window_start;
        this.window_start += window.len;
        this.sender_busy = true;
    }

    inline fn stepCleanup(this: *Dispatcher) void {
        if (this.cleanup_task) |*task| {
            while (task.await()) |res| {
                switch (res) {
                    .pending => return,
                    .err => |err| {
                        SCOPE.err("failed to delete a stale push subscription: {t}", .{err});
                        task.dispose();
                        this.cleanup_task = null;
                        this.finishJob();

                        return;
                    },
                    .ready => {},
                }
            }

            task.dispose();
            this.cleanup_task = null;
            this.cleanup_index += 1;
        }

        if (this.cleanup_index >= this.gone.items.len) {
            this.finishJob();

            return;
        }

        const dead = this.gone.items[this.cleanup_index];
        this.cleanup_user_id = dead.user_id;
        this.cleanup_hash = dead.endpoint_hash;
        this.cleanup_task = .from(.init(this.db.?, .{
            .user_id = dead.user_id,
            .endpoint_hash = dead.endpoint_hash,
        }));
    }
};

const PushMessage = struct {
    type: []const u8 = "message_created",
    guild_id: []const u8,
    channel_id: []const u8,
    message_id: []const u8,
    channel_name: []const u8,
    author_id: ?[]const u8,
    author_name: []const u8,
    author_avatar_hash: ?[]const u8 = null,
    webhook_id: ?[]const u8 = null,
    content_preview: []const u8,
};

/// Truncates `text` to at most `max` Unicode codepoints without splitting a
/// UTF-8 sequence. `text` is expected to be valid UTF-8 (message content is
/// sanitized).
pub inline fn truncateCodepoints(text: []const u8, max: usize) []const u8 {
    var count: usize = 0;
    var i: usize = 0;

    while (i < text.len and count < max) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch break;

        if (i + n > text.len) {
            break;
        }

        i += n;
        count += 1;
    }

    return text[0..i];
}

inline fn buildPlaintext(
    allocator: std.mem.Allocator,
    job: Job,
    message: root.repo.notifications_fanout.GetMessageForPush.Item,
) ![]const u8 {
    const message_id = try std.fmt.allocPrint(allocator, "{d}", .{job.message_id});
    const channel_id = try std.fmt.allocPrint(allocator, "{d}", .{job.channel_id});
    const guild_id = try std.fmt.allocPrint(allocator, "{d}", .{job.guild_id});

    const author_id: ?[]const u8 = if (job.author_id) |id|
        try std.fmt.allocPrint(allocator, "{d}", .{id})
    else
        null;

    const webhook_id: ?[]const u8 = if (job.webhook_id) |id|
        try std.fmt.allocPrint(allocator, "{d}", .{id})
    else
        null;

    const payload: PushMessage = .{
        .guild_id = guild_id,
        .channel_id = channel_id,
        .message_id = message_id,
        .channel_name = message.channel_name,
        .author_id = author_id,
        .author_name = message.author_name,
        .author_avatar_hash = message.author_avatar_hash,
        .webhook_id = webhook_id,
        .content_preview = truncateCodepoints(message.content, root.options.push.max_preview_codepoints),
    };

    var writer: std.Io.Writer.Allocating = .init(allocator);

    try std.json.fmt(payload, .{}).format(&writer.writer);

    return writer.written();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn decodeBase64Url(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const len = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded);
    const out = try allocator.alloc(u8, len);

    errdefer allocator.free(out);

    try std.base64.url_safe_no_pad.Decoder.decode(out, encoded);

    return out;
}

test "RFC 8291 section 5 test vector" {
    const ua_public_bytes = try decodeBase64Url(
        std.testing.allocator,
        "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
    );
    defer std.testing.allocator.free(ua_public_bytes);

    const as_private_bytes = try decodeBase64Url(std.testing.allocator, "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw");
    defer std.testing.allocator.free(as_private_bytes);

    const auth_bytes = try decodeBase64Url(std.testing.allocator, "BTBZMqHH6r4Tts7J_aSIgg");
    defer std.testing.allocator.free(auth_bytes);

    const salt_bytes = try decodeBase64Url(std.testing.allocator, "DGv6ra1nlYgDCS1FRnbzlw");
    defer std.testing.allocator.free(salt_bytes);

    const expected = try decodeBase64Url(
        std.testing.allocator,
        "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27ml" ++
            "mlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPT" ++
            "pK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN",
    );
    defer std.testing.allocator.free(expected);

    const ua_public = try P256.fromSec1(ua_public_bytes);
    const secret_key = try EcdsaP256Sha256.SecretKey.fromBytes(as_private_bytes[0..32].*);
    const ephemeral = try EcdsaP256Sha256.KeyPair.fromSecretKey(secret_key);

    const body = try encryptWith(
        std.testing.allocator,
        ua_public,
        auth_bytes[0..16].*,
        salt_bytes[0..16].*,
        ephemeral,
        "When I grow up, I want to be a watermelon",
    );
    defer std.testing.allocator.free(body);

    try std.testing.expectEqualSlices(u8, expected, body);
}

test "truncateCodepoints is UTF-8 safe" {
    const text = "héllo wörld";

    try std.testing.expectEqualStrings("hé", truncateCodepoints(text, 2));
    try std.testing.expectEqualStrings("", truncateCodepoints(text, 0));
    try std.testing.expectEqualStrings(text, truncateCodepoints(text, 100));
}

test "buildPlaintext carries the full author identity" {
    const previous_options = root.options;

    defer root.options = previous_options;

    const options: @import("../config.zig").Options = .{ .push = .{ .enabled = true } };
    root.options = &options;

    // A user message: author id + name + avatar hash, no webhook id.
    {
        const job: Job = .{
            .message_id = 10,
            .channel_id = 20,
            .guild_id = 30,
            .author_id = 40,
            .webhook_id = null,
            .mention_everyone = false,
            .mention_user_ids = &.{},
            .mention_role_ids = &.{},
        };

        const message: root.repo.notifications_fanout.GetMessageForPush.Item = .{
            .content = "hello",
            .channel_name = "general",
            .author_name = "Alice",
            .author_avatar_hash = "0123456789abcdef",
        };

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        const plaintext = try buildPlaintext(arena.allocator(), job, message);

        try std.testing.expect(std.mem.indexOf(u8, plaintext, "\"author_id\":\"40\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, plaintext, "\"author_name\":\"Alice\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, plaintext, "\"author_avatar_hash\":\"0123456789abcdef\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, plaintext, "\"webhook_id\":null") != null);
    }

    // A webhook message: no user author (null), webhook id + its avatar hash.
    {
        const job: Job = .{
            .message_id = 11,
            .channel_id = 21,
            .guild_id = 31,
            .author_id = null,
            .webhook_id = 50,
            .mention_everyone = false,
            .mention_user_ids = &.{},
            .mention_role_ids = &.{},
        };

        const message: root.repo.notifications_fanout.GetMessageForPush.Item = .{
            .content = "hi",
            .channel_name = "general",
            .author_name = "GitHub",
            .author_avatar_hash = null,
        };

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        const plaintext = try buildPlaintext(arena.allocator(), job, message);

        try std.testing.expect(std.mem.indexOf(u8, plaintext, "\"author_id\":null") != null);
        try std.testing.expect(std.mem.indexOf(u8, plaintext, "\"author_name\":\"GitHub\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, plaintext, "\"author_avatar_hash\":null") != null);
        try std.testing.expect(std.mem.indexOf(u8, plaintext, "\"webhook_id\":\"50\"") != null);
    }
}

test "enqueue drops when push is disabled and queues when enabled" {
    const previous_gpa = root.gpa;
    const previous_options = root.options;
    const previous_log = std.testing.log_level;

    defer {
        root.gpa = previous_gpa;
        root.options = previous_options;
        std.testing.log_level = previous_log;
    }

    root.gpa = std.testing.allocator;

    const users = [_]root.types.UserId{1};
    const roles = [_]root.types.RoleId{2};

    // Disabled: the job is dropped (and the warn it logs is suppressed here).
    {
        const options: @import("../config.zig").Options = .{};
        std.debug.assert(!options.push.enabled);

        root.options = &options;
        std.testing.log_level = .err;

        var dispatcher = try Dispatcher.init(std.testing.allocator, 4);
        defer dispatcher.deinit();

        dispatcher.enqueue(1, 2, 3, 4, null, false, &users, &roles);

        try std.testing.expect(dispatcher.queue.tryPop() == null);
    }

    // Enabled: the job is copied into the queue and freed by `deinit`.
    {
        const options: @import("../config.zig").Options = .{ .push = .{ .enabled = true } };

        root.options = &options;

        var dispatcher = try Dispatcher.init(std.testing.allocator, 4);
        defer dispatcher.deinit();

        dispatcher.enqueue(1, 2, 3, 4, null, true, &users, &roles);

        const job = dispatcher.queue.tryPop() orelse return error.TestExpectedJob;
        try std.testing.expectEqual(@as(root.types.MessageId, 1), job.message_id);
        try std.testing.expect(job.mention_everyone);
        try std.testing.expectEqualSlices(root.types.UserId, &users, job.mention_user_ids);
        try std.testing.expectEqualSlices(root.types.RoleId, &roles, job.mention_role_ids);
        job.deinit();
    }
}
