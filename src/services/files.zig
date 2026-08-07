// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../root.zig");

const curl = @import("curl");

const SCOPE = std.log.scoped(.files);

pub const Hash = std.crypto.hash.sha2.Sha256;

/// Lowercase hex of a SHA-256 digest (64 chars).
pub inline fn hexDigest(digest: *const [Hash.digest_length]u8) [Hash.digest_length * 2]u8 {
    var out: [Hash.digest_length * 2]u8 = undefined;

    _ = std.fmt.bufPrint(&out, "{x}", .{digest}) catch unreachable;

    return out;
}

const Spec = struct {
    pub const Put = struct {
        /// Raw file bytes to PUT. Owned by the payload.
        content: []const u8,
        /// Full object key, e.g. `files/<hash>`. Owned by the payload.
        key: []const u8,
        /// MIME type to store the object with. Owned by the payload.
        content_type: []const u8,
        /// Original file name; embedded into the object's `Content-Disposition`
        /// so a download saves under this name. Owned by the payload.
        name: []const u8,

        pub inline fn dupe(this: Put) !Put {
            const content = try root.gpa.dupe(u8, this.content);
            errdefer root.gpa.free(content);

            const key = try root.gpa.dupe(u8, this.key);
            errdefer root.gpa.free(key);

            const content_type = try root.gpa.dupe(u8, this.content_type);
            errdefer root.gpa.free(content_type);

            const name = try root.gpa.dupe(u8, this.name);
            errdefer root.gpa.free(name);

            return .{
                .content = content,
                .key = key,
                .content_type = content_type,
                .name = name,
            };
        }

        pub inline fn deinit(this: Put) void {
            root.gpa.free(this.content);
            root.gpa.free(this.key);
            root.gpa.free(this.content_type);
            root.gpa.free(this.name);
        }
    };

    pub const Delete = struct {
        /// Full object key, e.g. `files/<hash>`. Owned by the payload.
        key: []const u8,

        pub inline fn dupe(this: Delete) !Delete {
            return .{
                .key = try root.gpa.dupe(u8, this.key),
            };
        }

        pub inline fn deinit(this: Delete) void {
            root.gpa.free(this.key);
        }
    };

    pub const Payload = union(enum) {
        upload: Put,
        delete: Delete,

        pub inline fn dupe(this: Payload) !Payload {
            return switch (this) {
                .upload => |value| .{ .upload = try value.dupe() },
                .delete => |value| .{ .delete = try value.dupe() },
            };
        }

        pub inline fn deinit(this: Payload) void {
            switch (this) {
                .upload => |value| value.deinit(),
                .delete => |value| value.deinit(),
            }
        }
    };

    pub const Result = union(enum) {
        upload: bool,
        delete: bool,

        pub inline fn deinit(this: Result) void {
            _ = this;
        }
    };

    const Cursor = struct {
        content: []const u8,
        pos: usize = 0,
    };

    pub inline fn onInit() !void {
        if (curl.curl_global_init(curl.CURL_GLOBAL_DEFAULT) != curl.CURLE_OK) {
            SCOPE.err("failed to initialize libcurl", .{});

            return error.Curl;
        }
    }

    fn readCallback(
        buffer: [*c]u8,
        size: usize,
        nitems: usize,
        userdata: ?*anyopaque,
    ) callconv(.c) usize {
        const cursor: *Cursor = @ptrCast(@alignCast(userdata.?));

        const want = size * nitems;
        const remaining = cursor.content.len - cursor.pos;

        if (remaining == 0) {
            return 0;
        }

        const n = @min(want, remaining);

        @memcpy(buffer[0..n], cursor.content[cursor.pos..][0..n]);
        cursor.pos += n;

        return n;
    }

    /// A libcurl easy handle with the shared SigV4 / URL / credentials setup
    /// applied. `headers` is owned and freed on `deinit`.
    const Request = struct {
        handle: *curl.CURL,
        headers: ?*curl.curl_slist = null,

        inline fn init(key: []const u8) !Request {
            const storage = switch (root.options.files.storage) {
                .s3 => |s3| s3,
                else => return error.S3NotConfigured,
            };

            const url_z = std.fmt.allocPrintSentinel(root.gpa, "{s}/{s}", .{ storage.endpoint, key }, 0) catch {
                return error.OutOfMemory;
            };
            defer root.gpa.free(url_z);

            const provider_z = std.fmt.allocPrintSentinel(root.gpa, "aws:amz:{s}:s3", .{storage.region}, 0) catch {
                return error.OutOfMemory;
            };
            defer root.gpa.free(provider_z);

            const userpwd_z = std.fmt.allocPrintSentinel(root.gpa, "{s}:{s}", .{ storage.access_key, storage.secret_key }, 0) catch {
                return error.OutOfMemory;
            };
            defer root.gpa.free(userpwd_z);

            const handle = curl.curl_easy_init() orelse {
                SCOPE.err("failed to create a curl handle", .{});

                return error.S3RequestFailed;
            };
            errdefer curl.curl_easy_cleanup(handle);

            _ = curl.curl_easy_setopt(handle, curl.CURLOPT_URL, url_z.ptr);
            _ = curl.curl_easy_setopt(handle, curl.CURLOPT_HTTPAUTH, @as(c_ulong, curl.CURLAUTH_AWS_SIGV4));
            _ = curl.curl_easy_setopt(handle, curl.CURLOPT_AWS_SIGV4, provider_z.ptr);
            _ = curl.curl_easy_setopt(handle, curl.CURLOPT_USERPWD, userpwd_z.ptr);
            _ = curl.curl_easy_setopt(handle, curl.CURLOPT_NOSIGNAL, @as(c_long, 1));

            var headers: ?*curl.curl_slist = null;
            errdefer if (headers) |h| curl.curl_slist_free_all(h);

            // Suppress the `Expect: 100-continue` negotiation: some S3-compatible
            // servers (and the local test mock) do not answer it.
            headers = curl.curl_slist_append(headers, "Expect:");

            return .{
                .handle = handle,
                .headers = headers,
            };
        }

        inline fn addHeader(this: *Request, header: [*:0]const u8) void {
            this.headers = curl.curl_slist_append(this.headers, header);
        }

        inline fn applyHeaders(this: *Request) void {
            _ = curl.curl_easy_setopt(this.handle, curl.CURLOPT_HTTPHEADER, this.headers);
        }

        inline fn perform(this: *Request, comptime error_name: anyerror) !void {
            const code = curl.curl_easy_perform(this.handle);

            if (code != curl.CURLE_OK) {
                SCOPE.err("curl_easy_perform failed: {d}", .{code});

                return error_name;
            }
        }

        inline fn responseCode(this: *Request) c_long {
            var http_code: c_long = 0;
            _ = curl.curl_easy_getinfo(this.handle, curl.CURLINFO_RESPONSE_CODE, &http_code);

            return http_code;
        }

        inline fn deinit(this: *Request) void {
            if (this.headers) |h| {
                curl.curl_slist_free_all(h);
                this.headers = null;
            }

            curl.curl_easy_cleanup(this.handle);
        }
    };

    fn runUpload(payload: Put) anyerror!Result {
        const content_type_z = std.fmt.allocPrintSentinel(root.gpa, "Content-Type: {s}", .{payload.content_type}, 0) catch {
            return error.OutOfMemory;
        };
        defer root.gpa.free(content_type_z);

        // Objects are hash-addressed and immutable: cache them forever. Every
        // object is an attachment carrying the original name
        // (`filename`/`filename*`, RFC 6266/5987), so a direct navigation to
        // `public_url` saves the file under its name (like a chat attachment).
        // Embedded resources (`<img>`/`<video>`/`<audio src>`) ignore
        // `Content-Disposition`, so inline rendering/playback is unaffected.
        const cache_control: [*:0]const u8 = "Cache-Control: public, max-age=31536000, immutable";

        const params = root.utils.fileNameDisposition(root.gpa, payload.name) catch {
            return error.OutOfMemory;
        };
        defer root.gpa.free(params);

        const disposition_z = std.fmt.allocPrintSentinel(root.gpa, "Content-Disposition: attachment; {s}", .{params}, 0) catch {
            return error.OutOfMemory;
        };
        defer root.gpa.free(disposition_z);

        var request = try Request.init(payload.key);
        defer request.deinit();

        request.addHeader(content_type_z);
        request.addHeader(cache_control);
        request.addHeader(disposition_z);
        request.applyHeaders();

        var cursor: Cursor = .{ .content = payload.content };

        _ = curl.curl_easy_setopt(request.handle, curl.CURLOPT_UPLOAD, @as(c_long, 1));
        _ = curl.curl_easy_setopt(request.handle, curl.CURLOPT_READFUNCTION, &readCallback);
        _ = curl.curl_easy_setopt(request.handle, curl.CURLOPT_READDATA, &cursor);
        _ = curl.curl_easy_setopt(request.handle, curl.CURLOPT_INFILESIZE_LARGE, @as(curl.curl_off_t, @intCast(payload.content.len)));

        try request.perform(error.S3UploadFailed);

        const http_code = request.responseCode();

        if (http_code < 200 or http_code >= 300) {
            SCOPE.err("S3 upload returned HTTP {d}", .{http_code});

            return error.S3UploadFailed;
        }

        return .{ .upload = true };
    }

    fn runDelete(payload: Delete) anyerror!Result {
        var request = try Request.init(payload.key);
        defer request.deinit();

        request.applyHeaders();

        _ = curl.curl_easy_setopt(request.handle, curl.CURLOPT_CUSTOMREQUEST, @as([*:0]const u8, "DELETE"));

        try request.perform(error.S3DeleteFailed);

        const http_code = request.responseCode();

        // 404 is a success: the object may already be gone.
        if (http_code != 404 and (http_code < 200 or http_code >= 300)) {
            SCOPE.err("S3 delete returned HTTP {d}", .{http_code});

            return error.S3DeleteFailed;
        }

        return .{ .delete = true };
    }

    pub inline fn run(
        scratch: std.mem.Allocator,
        payload: *Payload,
    ) anyerror!Result {
        _ = scratch;

        return switch (payload.*) {
            .upload => |value| try runUpload(value),
            .delete => |value| try runDelete(value),
        };
    }
};

pub const Worker = root.worker.Worker(Spec);

/// Poll-based task that hands an upload to the files worker thread. The payload
/// is copied into the worker job (the job may outlive the request), so the
/// request body does not need to stay alive.
pub const Upload = struct {
    pub const Item = bool;

    pub const Result = Item;

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Upload, Result, anyerror);

    pub const Payload = Spec.Put;

    payload: Payload,
    job: ?*Worker.Job = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *Upload = @ptrCast(@alignCast(ctx));

        if (this.job == null) {
            this.job = root.files_worker.spawn(.{ .upload = this.payload }) catch |err| {
                SCOPE.err("Upload failed to spawn a job: {t}", .{err});

                return .{ .err = err };
            } orelse {
                return .{ .pending = .job };
            };
        }

        if (this.job.?.check()) |res| {
            switch (res) {
                .ok => |ok| return .{ .ready = ok.upload },
                .err => |err| return .{ .err = err },
            }
        }

        return .{ .pending = .job };
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *Upload = @ptrCast(@alignCast(ctx));

        if (this.job) |j| {
            j.release();
            this.job = null;
        }
    }

    pub inline fn init(payload: Payload) Upload {
        return .{
            .payload = payload,
        };
    }

    pub inline fn task(this: *Upload) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};

/// Tick-driven garbage collector for S3-backed files. It runs a guarded
/// `DELETE ... RETURNING` (see `repo.files.SelectOrphans`) at most every
/// `files.gc.interval_s` and feeds the returned hashes to the files worker as
/// delete jobs, spreading the work across ticks so uploads are never starved.
///
/// A DB connection is held only while the delete query is in flight, never
/// while idle or draining. Entry order is row-first: once the row is gone the
/// FK guarantees nobody can attach the file, so a failed S3 delete only leaks an
/// object (accepted).
pub const Gc = struct {
    const State = enum {
        idle,
        querying,
        draining,
    };

    allocator: std.mem.Allocator,
    state: State = .idle,
    last_run_ms: u64 = 0,
    /// Owned `files/<hash>` keys waiting for a worker slot.
    pending: std.ArrayList([]u8) = .empty,
    /// Delete jobs spawned by the GC, released as they complete.
    inflight: std.ArrayList(*Worker.Job) = .empty,
    query: ?root.repo.files.SelectOrphans.Lazy = null,
    /// The connection returned by `db_pool.rent()`. It is released once the
    /// query task is disposed: `rent()` and the repo task's `init` each take a
    /// reference, so both must be dropped.
    db: ?*root.db.Connection = null,

    pub inline fn init(allocator: std.mem.Allocator) Gc {
        return .{
            .allocator = allocator,
        };
    }

    pub inline fn deinit(this: *Gc) void {
        this.releaseInflight();

        if (this.query) |*q| {
            q.dispose();
            this.query = null;
        }

        this.releaseDb();

        for (this.pending.items) |key| {
            this.allocator.free(key);
        }

        this.pending.deinit(this.allocator);
        this.inflight.deinit(this.allocator);
    }

    inline fn releaseInflight(this: *Gc) void {
        for (this.inflight.items) |job| {
            job.release();
        }

        this.inflight.clearRetainingCapacity();
    }

    /// Drops the extra reference `db_pool.rent()` took. The repo task's
    /// `dispose` drops its own via `db.release()`.
    inline fn releaseDb(this: *Gc) void {
        if (this.db) |db| {
            db.release();
            this.db = null;
        }
    }

    /// Release every finished job so its worker slot becomes reusable. Called
    /// on every tick, including while idle: an unreleased `done` job keeps its
    /// slot busy and would starve uploads.
    inline fn reap(this: *Gc) void {
        var i: usize = 0;

        while (i < this.inflight.items.len) {
            const job = this.inflight.items[i];

            if (job.check()) |res| {
                switch (res) {
                    .ok => SCOPE.debug("GC deleted a file", .{}),
                    .err => |err| SCOPE.err("GC failed to delete an object: {t}", .{err}),
                }

                job.release();
                _ = this.inflight.swapRemove(i);

                continue;
            }

            i += 1;
        }
    }

    /// Reap finished jobs, then hand out as many pending deletes as worker
    /// slots allow. Returns true once there is no pending work and no job left.
    inline fn drain(this: *Gc) bool {
        this.reap();

        while (this.pending.items.len > 0) {
            const key = this.pending.items[0];

            const job = root.files_worker.spawn(.{ .delete = .{ .key = key } }) catch |err| {
                SCOPE.err("GC failed to spawn a delete job: {t}", .{err});

                break;
            } orelse break;

            this.allocator.free(key);
            _ = this.pending.orderedRemove(0);

            this.inflight.append(this.allocator, job) catch |err| {
                SCOPE.err("GC failed to track a delete job: {t}", .{err});
                job.release();
            };
        }

        return this.pending.items.len == 0 and this.inflight.items.len == 0;
    }

    pub fn tick(this: *Gc, now_ms: u64) void {
        switch (this.state) {
            .idle => {
                // Always reclaim finished jobs, even before the interval elapses.
                this.reap();

                const interval_ms: u64 = @as(u64, root.options.files.gc.interval_s) * 1000;

                if (this.last_run_ms != 0 and now_ms - this.last_run_ms < interval_ms) {
                    return;
                }

                if (root.options.files.storage != .s3) {
                    this.last_run_ms = now_ms;

                    return;
                }

                const db = root.db_pool.rent() orelse return;
                this.db = db;

                var max_jobs: u64 = @intCast(root.options.services.files.max_jobs);

                if (max_jobs == 0) {
                    max_jobs = 1;
                }

                this.query = .from(root.repo.files.SelectOrphans.init(this.allocator, db, .{
                    .grace_s = @intCast(root.options.files.gc.grace_s),
                    .limit = max_jobs,
                }));
                this.state = .querying;
            },
            .querying => {
                const query = &this.query.?;

                while (query.await()) |res| {
                    switch (res) {
                        .pending => return,
                        .err => |err| {
                            SCOPE.err("GC query failed: {t}", .{err});
                            query.dispose();
                            this.query = null;
                            this.releaseDb();
                            this.state = .idle;
                            this.last_run_ms = now_ms;

                            return;
                        },
                        .ready => unreachable,
                    }
                }

                // Copy the hashes before disposing: the query task owns them.
                for (query.result) |hash| {
                    const key = std.fmt.allocPrint(this.allocator, "files/{s}", .{hash}) catch |err| {
                        SCOPE.err("GC failed to build an object key: {t}", .{err});

                        continue;
                    };

                    this.pending.append(this.allocator, key) catch |err| {
                        SCOPE.err("GC failed to queue an object key: {t}", .{err});
                        this.allocator.free(key);
                    };
                }

                query.dispose();
                this.query = null;
                this.releaseDb();
                this.state = .draining;
            },
            .draining => {},
        }

        if (this.state == .draining and this.drain()) {
            this.state = .idle;
            this.last_run_ms = now_ms;
        }
    }
};
