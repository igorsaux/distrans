// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const ffmpeg = @import("avformat");
const swscale = @import("swscale");
const webp = @import("webp");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.images);

pub const INPUT_WEBP_MIME_TYPE = "image/webp";
pub const OUTPUT_IMAGE_MIME_TYPE = "image/webp";

pub const SUPPORTED_MIME_TYPES = [_][]const u8{
    "image/webp",
    "image/gif",
    "image/png",
    "image/jpeg",
    "image/jpg",
};

/// True when `mime` is one of `SUPPORTED_MIME_TYPES` (parameters and ASCII case
/// are ignored).
pub inline fn isSupportedMime(mime: ?[]const u8) bool {
    for (SUPPORTED_MIME_TYPES) |supported| {
        if (root.utils.matchMimeType(mime, supported)) {
            return true;
        }
    }

    return false;
}

/// Errors that are caused by the uploaded data and must map to a 4xx response.
/// Everything else is an internal failure.
pub const Error = error{
    /// The body is not a decodable supported image or violates the media caps.
    BadImage,
    /// The request body exceeded the configured input-byte cap.
    BodyTooLarge,
    OutOfMemory,
};

const AVIO_BUFFER_SIZE: usize = 32 * 1024;

/// Upper bound of a single `av_malloc` allocation. A small input can otherwise
/// request an absurd allocation from the decoder.
const MAX_AV_ALLOC: usize = 64 * 1024 * 1024;

/// Dimensions and animation flag read from the WebP container without involving
/// FFmpeg. They are needed before decoding so an oversized image or animation is
/// rejected before any decoder allocation happens.
const WebpInfo = struct {
    width: usize,
    height: usize,
    animated: bool,
};

inline fn readU24(input: []const u8) usize {
    return std.mem.readInt(u24, input[0..3], .little);
}

/// Duration (in ms) of the next `ANMF` chunk at or after `cursor.*`, advancing
/// the cursor past it. Returns null when no further frame header is present.
inline fn nextAnimationFrameDuration(input: []const u8, cursor: *usize) ?usize {
    var pos: usize = @max(cursor.*, 12);

    while (pos + 8 <= input.len) {
        const ty = input[pos..][0..4];
        const size: usize = std.mem.readInt(u32, input[pos + 4 ..][0..4], .little);
        const data_off = pos + 8;

        if (size > input.len -| data_off) {
            break;
        }

        const next = data_off + size + (size & 1);

        if (std.mem.eql(u8, ty, "ANMF")) {
            cursor.* = next;

            if (size < 16) {
                return null;
            }

            return readU24(input[data_off + 12 ..][0..3]);
        }

        pos = next;
    }

    cursor.* = pos;

    return null;
}

/// Parses the RIFF/WEBP chunks. Static images carry their dimensions in the
/// `VP8 ` (lossy) or `VP8L` (lossless) chunk; extended files (`VP8X`) carry the
/// canvas dimensions and the animation flag and hold their frames in `ANMF`
/// chunks. The animation caps (frame count and total duration after the same
/// per-frame clamping as the decoder path) are enforced here, so an oversized
/// animation is rejected before any decoder allocation happens.
inline fn parseWebpInfo(input: []const u8, limits: Limits) Error!WebpInfo {
    if (input.len < 12 or
        !std.mem.eql(u8, input[0..4], "RIFF") or
        !std.mem.eql(u8, input[8..12], "WEBP"))
    {
        return Error.BadImage;
    }

    const min_delay: usize = limits.min_animation_frame_delay_ms;
    const max_delay: usize = limits.max_animation_frame_delay_ms;

    var info: ?WebpInfo = null;
    var has_extended = false;
    var animated = false;
    var frame_count: usize = 0;
    var total_duration: usize = 0;

    var pos: usize = 12;

    while (pos + 8 <= input.len) {
        const ty = input[pos..][0..4];
        const size: usize = std.mem.readInt(u32, input[pos + 4 ..][0..4], .little);
        const data_off = pos + 8;

        if (size > input.len -| data_off) {
            return Error.BadImage;
        }

        const data = input[data_off..][0..size];

        if (std.mem.eql(u8, ty, "VP8X")) {
            if (data.len < 10) {
                return Error.BadImage;
            }

            has_extended = true;
            animated = (data[0] & 0x02) != 0;

            info = .{
                .width = readU24(data[4..7]) + 1,
                .height = readU24(data[7..10]) + 1,
                .animated = animated,
            };
        } else if (std.mem.eql(u8, ty, "VP8L")) {
            if (info == null and !has_extended) {
                if (data.len < 5 or data[0] != 0x2f) {
                    return Error.BadImage;
                }

                const bits = std.mem.readInt(u32, data[1..5], .little);

                info = .{
                    .width = @as(usize, bits & 0x3fff) + 1,
                    .height = @as(usize, (bits >> 14) & 0x3fff) + 1,
                    .animated = false,
                };
            }
        } else if (std.mem.eql(u8, ty, "VP8 ")) {
            if (info == null and !has_extended) {
                if (data.len < 10 or data[3] != 0x9d or data[4] != 0x01 or data[5] != 0x2a) {
                    return Error.BadImage;
                }

                info = .{
                    .width = @as(usize, std.mem.readInt(u16, data[6..8], .little) & 0x3fff),
                    .height = @as(usize, std.mem.readInt(u16, data[8..10], .little) & 0x3fff),
                    .animated = false,
                };
            }
        } else if (std.mem.eql(u8, ty, "ANMF")) {
            if (data.len < 16) {
                return Error.BadImage;
            }

            // `VP8X` must precede the frames and must announce the animation.
            const canvas = info orelse {
                return Error.BadImage;
            };

            if (!animated) {
                return Error.BadImage;
            }

            // The frame rectangle must stay within the canvas. libwebp clamps
            // this instead of failing, so it is checked here.
            const frame_x = readU24(data[0..3]);
            const frame_y = readU24(data[3..6]);
            const frame_width = readU24(data[6..9]) + 1;
            const frame_height = readU24(data[9..12]) + 1;

            if (frame_x + frame_width > canvas.width or
                frame_y + frame_height > canvas.height)
            {
                return Error.BadImage;
            }

            const raw_duration = readU24(data[12..15]);
            const delay = std.math.clamp(
                if (raw_duration > 0) raw_duration else min_delay,
                min_delay,
                max_delay,
            );

            frame_count += 1;

            if (frame_count > limits.max_animation_frames or
                total_duration + delay > limits.max_animation_duration_ms)
            {
                return Error.BadImage;
            }

            total_duration += delay;
        }

        pos = data_off + size + (size & 1);
    }

    const result = info orelse {
        return Error.BadImage;
    };

    if (result.width == 0 or result.height == 0 or
        result.width > limits.max_dimensions or
        result.height > limits.max_dimensions)
    {
        return Error.BadImage;
    }

    if (result.animated and frame_count == 0) {
        return Error.BadImage;
    }

    return result;
}

/// Forces the animated webp loop count to infinite (0). `libwebp_anim` emits
/// the assembled file itself, so the `webp` muxer (which patches this field)
/// is not involved. Chunk scanning is done instead of a hardcoded offset.
inline fn forceInfiniteLoop(data: []u8) void {
    if (data.len < 12 or !std.mem.eql(u8, data[0..4], "RIFF") or !std.mem.eql(u8, data[8..12], "WEBP")) {
        return;
    }

    var pos: usize = 12;

    while (pos + 8 <= data.len) {
        const ty = data[pos..][0..4];
        const size = std.mem.readInt(u32, data[pos + 4 ..][0..4], .little);
        const data_off = pos + 8;

        if (@as(usize, size) > data.len -| data_off) {
            return;
        }

        if (std.mem.eql(u8, ty, "ANIM") and size >= 6) {
            std.mem.writeInt(u16, data[data_off + 4 ..][0..2], 0, .little);

            return;
        }

        pos = data_off + @as(usize, size) + (@as(usize, size) & 1);
    }
}

pub const Limits = struct {
    max_input_bytes: usize,
    max_output_bytes: usize,
    max_dimensions: usize,
    max_animation_frames: usize,
    min_animation_frame_delay_ms: usize,
    max_animation_frame_delay_ms: usize,
    max_animation_duration_ms: usize,
};

pub const Options = struct {
    lossless: bool,
    quality: usize,
    compression_level: usize,
};

const Spec = struct {
    /// One image job: the encoded upload plus the options and caps to process it
    /// with. Named `Input` rather than `Payload` so it does not collide with
    /// `Encode.Payload` (the request-facing options/limits pair).
    pub const Payload = struct {
        input: []const u8,
        /// MIME type of `input`; owned by the payload.
        mime_type: []const u8,
        options: Options,
        limits: Limits,

        pub inline fn dupe(this: Payload) !Payload {
            const input = try root.gpa.dupe(u8, this.input);
            errdefer root.gpa.free(input);

            return .{
                .input = input,
                .mime_type = try root.gpa.dupe(u8, this.mime_type),
                .options = this.options,
                .limits = this.limits,
            };
        }

        pub inline fn deinit(this: Payload) void {
            root.gpa.free(this.input);
            root.gpa.free(this.mime_type);
        }
    };

    pub const Result = struct {
        /// WEBP bytes
        data: []u8,
        /// XXHash64 of `data`, 16 lowercase hex chars.
        hash: [16]u8,

        pub inline fn deinit(this: Result) void {
            root.gpa.free(this.data);
        }
    };

    pub inline fn onInit() !void {
        ffmpeg.av_max_alloc(MAX_AV_ALLOC);
    }

    pub inline fn run(scratch: std.mem.Allocator, payload: *Payload) anyerror!Result {
        _ = scratch;

        return process(payload.input, payload.mime_type, payload.options, payload.limits);
    }
};

pub const Worker = root.worker.Worker(Spec);

const SEEK_SET: c_int = 0;
const SEEK_CUR: c_int = 1;
const SEEK_END: c_int = 2;
const AVSEEK_SIZE: c_int = 0x10000;

const IoContext = struct {
    data: []const u8,
    pos: usize = 0,
};

fn readPacket(opaque_ptr: ?*anyopaque, buf: [*c]u8, buf_size: c_int) callconv(.c) c_int {
    const io: *IoContext = @ptrCast(@alignCast(opaque_ptr.?));

    if (buf_size <= 0) {
        return 0;
    }

    const remaining = io.data.len - io.pos;

    if (remaining == 0) {
        // EOF must be signalled as AVERROR_EOF: avio_read's direct path treats
        // a plain 0 as "no progress" and would loop forever on a large read.
        return ffmpeg.AVERROR_EOF;
    }

    const n: usize = @min(@as(usize, @intCast(buf_size)), remaining);

    @memcpy(buf[0..n], io.data[io.pos..][0..n]);

    io.pos += n;

    return @intCast(n);
}

fn seekPacket(opaque_ptr: ?*anyopaque, offset: i64, whence: c_int) callconv(.c) i64 {
    const io: *IoContext = @ptrCast(@alignCast(opaque_ptr.?));

    if (whence == AVSEEK_SIZE) {
        return @intCast(io.data.len);
    }

    const base: i64 = switch (whence) {
        SEEK_SET => 0,
        SEEK_CUR => @intCast(io.pos),
        SEEK_END => @intCast(io.data.len),
        else => return -1,
    };

    const target = base + offset;

    if (target < 0 or target > @as(i64, @intCast(io.data.len))) {
        return -1;
    }

    io.pos = @intCast(target);

    return target;
}

/// Converts decoded frames to the encoder pixel format and feeds them to the
/// still or animated libwebp encoder.
const Encoder = struct {
    ctx: *ffmpeg.AVCodecContext,
    frame: *ffmpeg.AVFrame,
    pix_fmt: c_int,
    width: c_int,
    height: c_int,
    sws: ?*swscale.SwsContext = null,
    src_fmt: c_int = ffmpeg.AV_PIX_FMT_NONE,
    frames: usize = 0,

    pub inline fn init(
        options: Options,
        animated: bool,
        width: c_int,
        height: c_int,
    ) Error!Encoder {
        const pix_fmt: c_int = if (options.lossless)
            ffmpeg.AV_PIX_FMT_BGRA
        else
            ffmpeg.AV_PIX_FMT_YUVA420P;

        const codec = ffmpeg.avcodec_find_encoder_by_name(if (animated) "libwebp_anim" else "libwebp") orelse {
            SCOPE.err("'libwebp_anim'/'libwebp' encoder not found", .{});

            return Error.BadImage;
        };

        var ctx: ?*ffmpeg.AVCodecContext = ffmpeg.avcodec_alloc_context3(codec) orelse {
            return Error.OutOfMemory;
        };
        errdefer ffmpeg.avcodec_free_context(&ctx);

        ctx.?.width = width;
        ctx.?.height = height;
        ctx.?.pix_fmt = pix_fmt;
        // libwebp_anim derives frame durations from the pts deltas in this time base.
        ctx.?.time_base = .{ .num = 1, .den = 1000 };
        ctx.?.framerate = .{ .num = 1000, .den = 1 };

        var dict: ?*ffmpeg.AVDictionary = null;

        _ = ffmpeg.av_dict_set(&dict, "lossless", if (options.lossless) "1" else "0", 0);

        var quality_buf: [16]u8 = undefined;
        const quality = std.fmt.bufPrintZ(&quality_buf, "{}", .{options.quality}) catch {
            return Error.OutOfMemory;
        };

        _ = ffmpeg.av_dict_set(&dict, "quality", quality.ptr, 0);

        var compression_buf: [16]u8 = undefined;
        const compression = std.fmt.bufPrintZ(&compression_buf, "{}", .{options.compression_level}) catch {
            return Error.OutOfMemory;
        };

        _ = ffmpeg.av_dict_set(&dict, "compression_level", compression.ptr, 0);

        const opened = ffmpeg.avcodec_open2(ctx.?, codec, &dict);

        ffmpeg.av_dict_free(&dict);

        if (opened < 0) {
            SCOPE.err("failed to open the webp encoder: {}", .{opened});

            return Error.BadImage;
        }

        var frame: ?*ffmpeg.AVFrame = ffmpeg.av_frame_alloc() orelse {
            return Error.OutOfMemory;
        };
        errdefer ffmpeg.av_frame_free(@ptrCast(&frame));

        frame.?.format = pix_fmt;
        frame.?.width = width;
        frame.?.height = height;

        if (ffmpeg.av_frame_get_buffer(frame, 0) < 0) {
            return Error.OutOfMemory;
        }

        return .{
            .ctx = ctx.?,
            .frame = frame.?,
            .pix_fmt = pix_fmt,
            .width = width,
            .height = height,
        };
    }

    pub inline fn deinit(this: *Encoder) void {
        if (this.sws) |sws| {
            swscale.sws_freeContext(sws);
            this.sws = null;
        }

        ffmpeg.av_frame_free(@ptrCast(&this.frame));
        ffmpeg.avcodec_free_context(@ptrCast(&this.ctx));
    }

    inline fn push(this: *Encoder, src: *ffmpeg.AVFrame) Error!void {
        if (src.width != this.width or src.height != this.height) {
            return Error.BadImage;
        }

        if (this.sws == null or this.src_fmt != src.format) {
            if (this.sws) |sws| {
                swscale.sws_freeContext(sws);
                this.sws = null;
            }

            this.sws = swscale.sws_getContext(
                src.width,
                src.height,
                src.format,
                this.width,
                this.height,
                this.pix_fmt,
                swscale.SWS_BILINEAR,
                null,
                null,
                null,
            ) orelse {
                return Error.BadImage;
            };

            this.src_fmt = src.format;
        }

        if (ffmpeg.av_frame_make_writable(this.frame) < 0) {
            return Error.OutOfMemory;
        }

        const scaled = swscale.sws_scale(
            this.sws.?,
            @ptrCast(&src.data),
            @ptrCast(&src.linesize),
            0,
            src.height,
            @ptrCast(&this.frame.data),
            @ptrCast(&this.frame.linesize),
        );

        if (scaled < 0) {
            return Error.BadImage;
        }

        if (ffmpeg.avcodec_send_frame(this.ctx, this.frame) < 0) {
            return Error.BadImage;
        }

        this.frames += 1;
    }
};

inline fn readU16(data: []const u8, off: usize, big: bool) ?u16 {
    if (off + 2 > data.len) {
        return null;
    }

    return if (big)
        std.mem.readInt(u16, data[off..][0..2], .big)
    else
        std.mem.readInt(u16, data[off..][0..2], .little);
}

inline fn readU32(data: []const u8, off: usize, big: bool) ?u32 {
    if (off + 4 > data.len) {
        return null;
    }

    return if (big)
        std.mem.readInt(u32, data[off..][0..4], .big)
    else
        std.mem.readInt(u32, data[off..][0..4], .little);
}

/// Reads the EXIF Orientation tag (0x0112) from a raw little/big-endian TIFF
/// stream (the body of an `Exif\0\0` APP1 segment). Returns 1..8, or null when
/// the tag is absent or the stream is malformed.
inline fn parseTiffOrientation(tiff: []const u8) ?u8 {
    if (tiff.len < 8) {
        return null;
    }

    const big = if (tiff[0] == 'M' and tiff[1] == 'M')
        true
    else if (tiff[0] == 'I' and tiff[1] == 'I')
        false
    else
        return null;

    if ((readU16(tiff, 2, big) orelse return null) != 42) {
        return null;
    }

    const ifd0: usize = readU32(tiff, 4, big) orelse return null;
    const count: usize = readU16(tiff, ifd0, big) orelse return null;

    var entry: usize = 0;

    while (entry < count) : (entry += 1) {
        const off = ifd0 + 2 + entry * 12;
        const tag = readU16(tiff, off, big) orelse return null;

        if (tag != 0x0112) {
            continue;
        }

        const ty = readU16(tiff, off + 2, big) orelse return null;
        const n = readU32(tiff, off + 4, big) orelse return null;

        if (ty != 3 or n < 1) {
            return null;
        }

        const value = readU16(tiff, off + 8, big) orelse return null;

        return if (value >= 1 and value <= 8) @intCast(value) else null;
    }

    return null;
}

/// Scans a JPEG for the first `Exif\0\0` APP1 segment and returns its EXIF
/// Orientation (1..8), or null when absent. Orientation is not applied by the
/// decoder (FFmpeg only exposes it as metadata), so the encoder must rotate the
/// decoded frame itself to store an upright image.
inline fn jpegExifOrientation(input: []const u8) ?u8 {
    if (input.len < 4 or input[0] != 0xFF or input[1] != 0xD8) {
        return null;
    }

    var i: usize = 2;

    while (i + 3 < input.len) {
        if (input[i] != 0xFF) {
            i += 1;

            continue;
        }

        var marker = input[i + 1];

        while (marker == 0xFF and i + 2 < input.len) {
            i += 1;
            marker = input[i + 1];
        }

        // Standalone markers carry no length.
        if (marker == 0xD8 or marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7)) {
            i += 2;

            continue;
        }

        // Start-of-scan / end-of-image: no EXIF follows.
        if (marker == 0xDA or marker == 0xD9) {
            return null;
        }

        const seg_len: usize = std.mem.readInt(u16, input[i + 2 ..][0..2], .big);

        if (seg_len < 2) {
            return null;
        }

        const body = i + 4;
        const next = i + 2 + seg_len;

        if (next > input.len) {
            return null;
        }

        if (marker == 0xE1 and seg_len >= 8 and std.mem.eql(u8, input[body..][0..6], "Exif\x00\x00")) {
            return parseTiffOrientation(input[body + 6 .. next]);
        }

        i = next;
    }

    return null;
}

/// Pixel transform that makes an EXIF-oriented image upright.
const Orientation = struct {
    /// Clockwise quarter turns to apply after the optional mirror.
    quarter_turns: u8,
    /// Mirror horizontally before rotating.
    mirror: bool,
};

inline fn orientationTransform(code: u8) Orientation {
    return switch (code) {
        2 => .{ .quarter_turns = 0, .mirror = true },
        3 => .{ .quarter_turns = 2, .mirror = false },
        4 => .{ .quarter_turns = 2, .mirror = true },
        5 => .{ .quarter_turns = 3, .mirror = true },
        6 => .{ .quarter_turns = 1, .mirror = false },
        7 => .{ .quarter_turns = 1, .mirror = true },
        8 => .{ .quarter_turns = 3, .mirror = false },
        else => .{ .quarter_turns = 0, .mirror = false },
    };
}

/// Converts `src` to RGBA through swscale and applies the EXIF orientation.
/// Returns a new RGBA frame (dims swapped for odd quarter turns) the encoder
/// then converts to its own pixel format. Caller frees the result.
fn rotateRgba(src: *ffmpeg.AVFrame, orientation: Orientation) Error!*ffmpeg.AVFrame {
    const w = src.width;
    const h = src.height;
    const turns = orientation.quarter_turns;
    const swap = turns == 1 or turns == 3;
    const out_w: c_int = if (swap) h else w;
    const out_h: c_int = if (swap) w else h;

    const sws = swscale.sws_getContext(
        w,
        h,
        src.format,
        w,
        h,
        ffmpeg.AV_PIX_FMT_RGBA,
        swscale.SWS_BILINEAR,
        null,
        null,
        null,
    ) orelse {
        return Error.BadImage;
    };
    defer swscale.sws_freeContext(sws);

    var rgba: ?*ffmpeg.AVFrame = ffmpeg.av_frame_alloc() orelse {
        return Error.OutOfMemory;
    };
    defer ffmpeg.av_frame_free(&rgba);

    rgba.?.format = ffmpeg.AV_PIX_FMT_RGBA;
    rgba.?.width = w;
    rgba.?.height = h;

    if (ffmpeg.av_frame_get_buffer(rgba, 0) < 0) {
        return Error.OutOfMemory;
    }

    if (swscale.sws_scale(
        sws,
        @ptrCast(&src.data),
        @ptrCast(&src.linesize),
        0,
        h,
        @ptrCast(&rgba.?.data),
        @ptrCast(&rgba.?.linesize),
    ) < 0) {
        return Error.BadImage;
    }

    var out: ?*ffmpeg.AVFrame = ffmpeg.av_frame_alloc() orelse {
        return Error.OutOfMemory;
    };
    errdefer ffmpeg.av_frame_free(&out);

    out.?.format = ffmpeg.AV_PIX_FMT_RGBA;
    out.?.width = out_w;
    out.?.height = out_h;

    if (ffmpeg.av_frame_get_buffer(out, 0) < 0) {
        return Error.OutOfMemory;
    }

    const src_pixels = rgba.?.data[0];
    const src_stride: usize = @intCast(rgba.?.linesize[0]);
    const dst_pixels = out.?.data[0];
    const dst_stride: usize = @intCast(out.?.linesize[0]);

    var sy: c_int = 0;

    while (sy < h) : (sy += 1) {
        var sx: c_int = 0;

        while (sx < w) : (sx += 1) {
            const mx: c_int = if (orientation.mirror) w - 1 - sx else sx;

            const dx: c_int = switch (turns) {
                1 => h - 1 - sy,
                2 => w - 1 - mx,
                3 => sy,
                else => mx,
            };
            const dy: c_int = switch (turns) {
                1 => mx,
                2 => h - 1 - sy,
                3 => w - 1 - mx,
                else => sy,
            };

            const s_off = @as(usize, @intCast(sy)) * src_stride + @as(usize, @intCast(sx)) * 4;
            const d_off = @as(usize, @intCast(dy)) * dst_stride + @as(usize, @intCast(dx)) * 4;

            @memcpy(dst_pixels[d_off..][0..4], src_pixels[s_off..][0..4]);
        }
    }

    return out.?;
}

/// Lazily initializes the encoder on the first frame, applies EXIF orientation
/// to a still frame, and pushes it.
inline fn emitFrame(
    encoder: *?Encoder,
    options: Options,
    limits: Limits,
    decoded: *ffmpeg.AVFrame,
    animated: bool,
    orientation: Orientation,
    pts: i64,
    duration: i64,
) Error!void {
    const transform: Orientation = if (animated) .{ .quarter_turns = 0, .mirror = false } else orientation;

    if (encoder.* == null) {
        var w = decoded.width;
        var h = decoded.height;

        if (transform.quarter_turns == 1 or transform.quarter_turns == 3) {
            std.mem.swap(c_int, &w, &h);
        }

        encoder.* = try Encoder.init(options, animated, w, h);
    }

    const enc = &encoder.*.?;

    if (enc.frames + 1 > limits.max_animation_frames) {
        return Error.BadImage;
    }

    if (transform.quarter_turns != 0 or transform.mirror) {
        var rotated: ?*ffmpeg.AVFrame = try rotateRgba(decoded, transform);
        defer ffmpeg.av_frame_free(&rotated);

        enc.frame.pts = pts;
        enc.frame.duration = duration;

        return enc.push(rotated.?);
    }

    enc.frame.pts = pts;
    enc.frame.duration = duration;

    return enc.push(decoded);
}

inline fn findDemuxer(names: []const [*:0]const u8) ?*const ffmpeg.AVInputFormat {
    for (names) |name| {
        if (ffmpeg.av_find_input_format(name)) |demuxer| {
            return demuxer;
        }
    }

    return null;
}

inline fn process(
    input: []const u8,
    mime_type: []const u8,
    options: Options,
    limits: Limits,
) Error!Spec.Result {
    if (root.utils.matchMimeType(mime_type, "image/webp")) {
        const info = try parseWebpInfo(input, limits);

        if (info.animated) {
            return processAnimated(input, options, limits);
        }

        return processStill(input, info, options, limits);
    }

    if (root.utils.matchMimeType(mime_type, "image/png")) {
        return processFfmpeg(input, .{
            .demuxers = &.{"png_pipe"},
            // An APNG is not special-cased: the APNG decoder is accepted and only
            // its first frame is kept.
            .codec_ids = &.{ ffmpeg.AV_CODEC_ID_PNG, ffmpeg.AV_CODEC_ID_APNG },
            .codec_whitelist = "png,apng",
            .animated = false,
            .use_packet_duration = false,
        }, options, limits);
    }

    if (root.utils.matchMimeType(mime_type, "image/gif")) {
        return processFfmpeg(input, .{
            .demuxers = &.{"gif"},
            .codec_ids = &.{ffmpeg.AV_CODEC_ID_GIF},
            .codec_whitelist = "gif",
            .animated = true,
            .use_packet_duration = true,
        }, options, limits);
    }

    if (root.utils.matchMimeType(mime_type, "image/jpeg") or
        root.utils.matchMimeType(mime_type, "image/jpg"))
    {
        return processFfmpeg(input, .{
            .demuxers = &.{ "jpeg_pipe", "mjpeg" },
            .codec_ids = &.{ffmpeg.AV_CODEC_ID_MJPEG},
            .codec_whitelist = "mjpeg",
            .animated = false,
            .use_packet_duration = false,
        }, options, limits);
    }

    return Error.BadImage;
}

/// Parameters of one FFmpeg decode pass.
const FfmpegFormat = struct {
    demuxers: []const [*:0]const u8,
    codec_ids: []const c_int,
    codec_whitelist: [*:0]const u8,
    animated: bool,
    /// When true, the per-frame delay is taken from the packet duration
    /// (GIF/APNG); otherwise the single frame gets `pts = 0`.
    use_packet_duration: bool,
};

/// Decodes a PNG/APNG/GIF/JPEG body and re-encodes it to WebP. A non-animated
/// format keeps only the first decoded frame. Still JPEG frames are rotated to
/// honor their EXIF orientation. Runs on the worker thread.
fn processFfmpeg(
    input: []const u8,
    format: FfmpegFormat,
    options: Options,
    limits: Limits,
) Error!Spec.Result {
    var io: IoContext = .{ .data = input };

    const avio_buffer = root.gpa.alloc(u8, AVIO_BUFFER_SIZE) catch {
        return Error.OutOfMemory;
    };

    const avio = ffmpeg.avio_alloc_context(
        avio_buffer.ptr,
        @intCast(avio_buffer.len),
        0,
        &io,
        readPacket,
        null,
        seekPacket,
    ) orelse {
        root.gpa.free(avio_buffer);

        return Error.OutOfMemory;
    };

    defer {
        var avio_ref: ?*ffmpeg.AVIOContext = avio;
        ffmpeg.avio_context_free(&avio_ref);
        root.gpa.free(avio_buffer);
    }

    const fmt: *ffmpeg.AVFormatContext = @ptrCast(ffmpeg.avformat_alloc_context() orelse {
        return Error.OutOfMemory;
    });

    fmt.pb = avio;
    fmt.flags |= ffmpeg.AVFMT_FLAG_CUSTOM_IO;

    var fmt_ref: ?*ffmpeg.AVFormatContext = fmt;

    defer ffmpeg.avformat_close_input(&fmt_ref);

    const demuxer = findDemuxer(format.demuxers) orelse {
        SCOPE.err("demuxer not found", .{});

        return Error.BadImage;
    };

    var open_dict: ?*ffmpeg.AVDictionary = null;
    _ = ffmpeg.av_dict_set(&open_dict, "codec_whitelist", format.codec_whitelist, 0);
    _ = ffmpeg.av_dict_set(&open_dict, "ignore_loop", "1", 0);

    const opened = ffmpeg.avformat_open_input(&fmt_ref, "dummy", demuxer, &open_dict);

    ffmpeg.av_dict_free(&open_dict);

    if (opened < 0) {
        // `avformat_open_input` frees the context on failure.
        return Error.BadImage;
    }

    if (ffmpeg.avformat_find_stream_info(fmt_ref, null) < 0) {
        return Error.BadImage;
    }

    var stream: ?*ffmpeg.AVStream = null;
    var video_index: c_int = -1;
    var i: c_uint = 0;

    while (i < fmt_ref.?.nb_streams) : (i += 1) {
        const candidate = fmt_ref.?.streams[i];

        if (candidate.*.codecpar.*.codec_type == ffmpeg.AVMEDIA_TYPE_VIDEO) {
            stream = candidate;
            video_index = @intCast(i);

            break;
        }
    }

    if (stream == null) {
        return Error.BadImage;
    }

    const codecpar = stream.?.codecpar;
    const codec_id = codecpar.*.codec_id;

    var codec_ok = false;

    for (format.codec_ids) |allowed| {
        if (codec_id == allowed) {
            codec_ok = true;

            break;
        }
    }

    if (!codec_ok) {
        return Error.BadImage;
    }

    const width = codecpar.*.width;
    const height = codecpar.*.height;

    if (width <= 0 or height <= 0 or
        width > limits.max_dimensions or height > limits.max_dimensions)
    {
        return Error.BadImage;
    }

    if (ffmpeg.av_image_check_size2(
        @intCast(width),
        @intCast(height),
        @as(i64, @intCast(limits.max_dimensions)) * @as(i64, @intCast(limits.max_dimensions)),
        ffmpeg.AV_PIX_FMT_NONE,
        0,
        null,
    ) < 0) {
        return Error.BadImage;
    }

    const decoder = ffmpeg.avcodec_find_decoder(codec_id) orelse {
        return Error.BadImage;
    };

    var codec_ctx: ?*ffmpeg.AVCodecContext = ffmpeg.avcodec_alloc_context3(decoder) orelse {
        return Error.OutOfMemory;
    };
    defer ffmpeg.avcodec_free_context(&codec_ctx);

    if (ffmpeg.avcodec_parameters_to_context(codec_ctx.?, codecpar) < 0) {
        return Error.BadImage;
    }

    if (ffmpeg.avcodec_open2(codec_ctx.?, decoder, null) < 0) {
        return Error.BadImage;
    }

    var encoder: ?Encoder = null;
    defer if (encoder) |*enc| enc.deinit();

    // EXIF orientation applies to still JPEG frames only; animated formats and
    // the other still types have no orientation metadata wired here.
    const orientation: Orientation = if (format.animated)
        .{ .quarter_turns = 0, .mirror = false }
    else
        orientationTransform(jpegExifOrientation(input) orelse 1);

    var packet: ?*ffmpeg.AVPacket = ffmpeg.av_packet_alloc() orelse {
        return Error.OutOfMemory;
    };
    defer ffmpeg.av_packet_free(&packet);

    var decoded: ?*ffmpeg.AVFrame = ffmpeg.av_frame_alloc() orelse {
        return Error.OutOfMemory;
    };
    defer ffmpeg.av_frame_free(&decoded);

    const min_delay: i64 = @intCast(limits.min_animation_frame_delay_ms);
    const max_delay: i64 = @intCast(limits.max_animation_frame_delay_ms);
    const max_duration: i64 = @intCast(limits.max_animation_duration_ms);

    var total_duration_ms: i64 = 0;

    decode: while (true) {
        const read = ffmpeg.av_read_frame(fmt_ref, packet);

        if (read == ffmpeg.AVERROR_EOF) {
            break;
        }

        if (read < 0) {
            return Error.BadImage;
        }

        if (packet.?.stream_index != video_index) {
            ffmpeg.av_packet_unref(packet);

            continue;
        }

        var raw_delay_ms: i64 = 0;

        if (format.use_packet_duration and packet.?.duration > 0) {
            raw_delay_ms = @intCast(ffmpeg.av_rescale_q(packet.?.duration, stream.?.time_base, .{ .num = 1, .den = 1000 }));
        }

        if (ffmpeg.avcodec_send_packet(codec_ctx.?, packet) < 0) {
            ffmpeg.av_packet_unref(packet);

            return Error.BadImage;
        }

        ffmpeg.av_packet_unref(packet);

        while (true) {
            const received = ffmpeg.avcodec_receive_frame(codec_ctx.?, decoded);

            if (received < 0) {
                break;
            }

            if (format.animated) {
                const delay = std.math.clamp(
                    if (raw_delay_ms > 0) raw_delay_ms else min_delay,
                    min_delay,
                    max_delay,
                );

                if (total_duration_ms + delay > max_duration) {
                    ffmpeg.av_frame_unref(decoded);

                    return Error.BadImage;
                }

                total_duration_ms += delay;

                emitFrame(&encoder, options, limits, decoded.?, true, orientation, total_duration_ms - delay, delay) catch |err| {
                    ffmpeg.av_frame_unref(decoded);

                    return err;
                };
            } else {
                emitFrame(&encoder, options, limits, decoded.?, false, orientation, 0, 0) catch |err| {
                    ffmpeg.av_frame_unref(decoded);

                    return err;
                };
            }

            ffmpeg.av_frame_unref(decoded);

            if (!format.animated) {
                // Only the first frame of a static format (or of an APNG) is kept.
                break :decode;
            }
        }
    }

    if (ffmpeg.avcodec_send_packet(codec_ctx.?, null) >= 0) {
        while (true) {
            const received = ffmpeg.avcodec_receive_frame(codec_ctx.?, decoded);

            if (received < 0) {
                break;
            }

            if (format.animated) {
                if (total_duration_ms + min_delay > max_duration) {
                    ffmpeg.av_frame_unref(decoded);

                    return Error.BadImage;
                }

                total_duration_ms += min_delay;

                emitFrame(&encoder, options, limits, decoded.?, true, orientation, total_duration_ms - min_delay, min_delay) catch |err| {
                    ffmpeg.av_frame_unref(decoded);

                    return err;
                };
            } else if (encoder == null or encoder.?.frames == 0) {
                emitFrame(&encoder, options, limits, decoded.?, false, orientation, 0, 0) catch |err| {
                    ffmpeg.av_frame_unref(decoded);

                    return err;
                };
            }

            ffmpeg.av_frame_unref(decoded);

            if (!format.animated) {
                break;
            }
        }
    }

    if (encoder == null or encoder.?.frames == 0) {
        return Error.BadImage;
    }

    return collectEncoded(&encoder.?, limits, format.animated);
}

/// Decodes a static WebP body and re-encodes it to WebP.
fn processStill(
    input: []const u8,
    info: WebpInfo,
    options: Options,
    limits: Limits,
) Error!Spec.Result {
    if (ffmpeg.av_image_check_size2(
        @intCast(info.width),
        @intCast(info.height),
        @as(i64, @intCast(limits.max_dimensions)) * @as(i64, @intCast(limits.max_dimensions)),
        ffmpeg.AV_PIX_FMT_NONE,
        0,
        null,
    ) < 0) {
        return Error.BadImage;
    }

    var io: IoContext = .{ .data = input };

    const avio_buffer = root.gpa.alloc(u8, AVIO_BUFFER_SIZE) catch {
        return Error.OutOfMemory;
    };

    const avio = ffmpeg.avio_alloc_context(
        avio_buffer.ptr,
        @intCast(avio_buffer.len),
        0,
        &io,
        readPacket,
        null,
        seekPacket,
    ) orelse {
        root.gpa.free(avio_buffer);

        return Error.OutOfMemory;
    };

    defer {
        var avio_ref: ?*ffmpeg.AVIOContext = avio;
        ffmpeg.avio_context_free(&avio_ref);
        root.gpa.free(avio_buffer);
    }

    const fmt: *ffmpeg.AVFormatContext = @ptrCast(ffmpeg.avformat_alloc_context() orelse {
        return Error.OutOfMemory;
    });

    fmt.pb = avio;
    fmt.flags |= ffmpeg.AVFMT_FLAG_CUSTOM_IO;

    var fmt_ref: ?*ffmpeg.AVFormatContext = fmt;

    defer ffmpeg.avformat_close_input(&fmt_ref);

    // Only still images reach this function: animated WebP is validated and
    // stored verbatim (see `Encode.poll`) because FFmpeg builds that lack the
    // `webp_anim` demuxer/decoder cannot composite ANMF frames at all. Static
    // WebP is demuxed by `webp_pipe` (or the legacy `webp` demuxer).
    const demuxer = findDemuxer(&.{ "webp_pipe", "webp" }) orelse {
        return Error.BadImage;
    };

    var open_dict: ?*ffmpeg.AVDictionary = null;
    _ = ffmpeg.av_dict_set(&open_dict, "codec_whitelist", "webp,webp_anim", 0);

    const opened = ffmpeg.avformat_open_input(&fmt_ref, "dummy", demuxer, &open_dict);

    ffmpeg.av_dict_free(&open_dict);

    if (opened < 0) {
        // `avformat_open_input` frees the context on failure.
        return Error.BadImage;
    }

    if (ffmpeg.avformat_find_stream_info(fmt_ref, null) < 0) {
        return Error.BadImage;
    }

    var stream: ?*ffmpeg.AVStream = null;
    var video_index: c_int = -1;
    var i: c_uint = 0;

    while (i < fmt_ref.?.nb_streams) : (i += 1) {
        const candidate = fmt_ref.?.streams[i];

        if (candidate.*.codecpar.*.codec_type == ffmpeg.AVMEDIA_TYPE_VIDEO) {
            stream = candidate;
            video_index = @intCast(i);

            break;
        }
    }

    if (stream == null) {
        return Error.BadImage;
    }

    const codecpar = stream.?.codecpar;
    const codec_id = codecpar.*.codec_id;

    if (codec_id != ffmpeg.AV_CODEC_ID_WEBP) {
        return Error.BadImage;
    }

    const decoder = ffmpeg.avcodec_find_decoder(codec_id) orelse {
        return Error.BadImage;
    };

    var codec_ctx: ?*ffmpeg.AVCodecContext = ffmpeg.avcodec_alloc_context3(decoder) orelse {
        return Error.OutOfMemory;
    };
    defer ffmpeg.avcodec_free_context(&codec_ctx);

    if (ffmpeg.avcodec_parameters_to_context(codec_ctx.?, codecpar) < 0) {
        return Error.BadImage;
    }

    if (ffmpeg.avcodec_open2(codec_ctx.?, decoder, null) < 0) {
        return Error.BadImage;
    }

    var encoder = try Encoder.init(options, false, @intCast(info.width), @intCast(info.height));
    defer encoder.deinit();

    var packet: ?*ffmpeg.AVPacket = ffmpeg.av_packet_alloc() orelse {
        return Error.OutOfMemory;
    };
    defer ffmpeg.av_packet_free(&packet);

    var decoded: ?*ffmpeg.AVFrame = ffmpeg.av_frame_alloc() orelse {
        return Error.OutOfMemory;
    };
    defer ffmpeg.av_frame_free(&decoded);

    while (true) {
        const read = ffmpeg.av_read_frame(fmt_ref, packet);

        if (read == ffmpeg.AVERROR_EOF) {
            break;
        }

        if (read < 0) {
            return Error.BadImage;
        }

        if (packet.?.stream_index != video_index) {
            ffmpeg.av_packet_unref(packet);

            continue;
        }

        if (ffmpeg.avcodec_send_packet(codec_ctx.?, packet) < 0) {
            ffmpeg.av_packet_unref(packet);

            return Error.BadImage;
        }

        ffmpeg.av_packet_unref(packet);

        while (true) {
            const received = ffmpeg.avcodec_receive_frame(codec_ctx.?, decoded);

            if (received < 0) {
                break;
            }

            if (encoder.frames + 1 > limits.max_animation_frames) {
                ffmpeg.av_frame_unref(decoded);

                return Error.BadImage;
            }

            encoder.frame.pts = 0;
            encoder.frame.duration = 0;

            encoder.push(decoded.?) catch |err| {
                ffmpeg.av_frame_unref(decoded);

                return err;
            };

            ffmpeg.av_frame_unref(decoded);
        }
    }

    if (ffmpeg.avcodec_send_packet(codec_ctx.?, null) >= 0) {
        while (ffmpeg.avcodec_receive_frame(codec_ctx.?, decoded) >= 0) {
            if (encoder.frames + 1 > limits.max_animation_frames) {
                ffmpeg.av_frame_unref(decoded);

                return Error.BadImage;
            }

            encoder.frame.pts = 0;
            encoder.frame.duration = 0;

            encoder.push(decoded.?) catch |err| {
                ffmpeg.av_frame_unref(decoded);

                return err;
            };

            ffmpeg.av_frame_unref(decoded);
        }
    }

    return collectEncoded(&encoder, limits, false);
}

/// Decodes an animated WebP body and re-encodes it to an animated WebP. Uses
/// libwebp's `WebPAnimDecoder`, which composites the `ANMF` frames into the full
/// canvas; FFmpeg cannot do this before 9.0.
fn processAnimated(
    input: []const u8,
    options: Options,
    limits: Limits,
) Error!Spec.Result {
    var data: webp.WebPData = .{
        .bytes = input.ptr,
        .size = input.len,
    };

    var decoder_options: webp.WebPAnimDecoderOptions = undefined;

    if (webp.WebPAnimDecoderOptionsInit(&decoder_options) == 0) {
        return Error.BadImage;
    }

    decoder_options.color_mode = webp.MODE_RGBA;
    decoder_options.use_threads = 0;

    // The decoder does not copy the bitstream; `input` stays alive for the whole
    // call (and nothing else touches it on the worker thread).
    const decoder = webp.WebPAnimDecoderNew(&data, &decoder_options) orelse {
        return Error.BadImage;
    };
    defer webp.WebPAnimDecoderDelete(decoder);

    var anim_info: webp.WebPAnimInfo = undefined;

    if (webp.WebPAnimDecoderGetInfo(decoder, &anim_info) == 0) {
        return Error.BadImage;
    }

    if (anim_info.canvas_width == 0 or anim_info.canvas_height == 0 or
        anim_info.frame_count == 0 or
        anim_info.canvas_width > limits.max_dimensions or
        anim_info.canvas_height > limits.max_dimensions or
        anim_info.frame_count > limits.max_animation_frames)
    {
        return Error.BadImage;
    }

    var encoder = try Encoder.init(options, true, @intCast(anim_info.canvas_width), @intCast(anim_info.canvas_height));
    defer encoder.deinit();

    var frame: ?*ffmpeg.AVFrame = ffmpeg.av_frame_alloc() orelse {
        return Error.OutOfMemory;
    };
    defer ffmpeg.av_frame_free(&frame);

    // Wraps the decoder's canvas buffer, so it must not own any plane memory.
    frame.?.format = ffmpeg.AV_PIX_FMT_RGBA;
    frame.?.width = @intCast(anim_info.canvas_width);
    frame.?.height = @intCast(anim_info.canvas_height);

    const min_delay: usize = limits.min_animation_frame_delay_ms;
    const max_delay: usize = limits.max_animation_frame_delay_ms;

    var total_duration: usize = 0;
    var cursor: usize = 0;

    while (webp.WebPAnimDecoderHasMoreFrames(decoder) != 0) {
        var pixels: [*c]u8 = undefined;
        var timestamp: c_int = 0;

        if (webp.WebPAnimDecoderGetNext(decoder, &pixels, &timestamp) == 0) {
            return Error.BadImage;
        }

        const raw_duration = nextAnimationFrameDuration(input, &cursor) orelse min_delay;
        const delay = std.math.clamp(
            if (raw_duration > 0) raw_duration else min_delay,
            min_delay,
            max_delay,
        );

        if (encoder.frames + 1 > limits.max_animation_frames or
            total_duration + delay > limits.max_animation_duration_ms)
        {
            return Error.BadImage;
        }

        total_duration += delay;

        frame.?.data[0] = pixels;
        frame.?.linesize[0] = @intCast(anim_info.canvas_width * 4);

        encoder.frame.pts = @intCast(total_duration - delay);
        encoder.frame.duration = @intCast(delay);

        try encoder.push(frame.?);
    }

    if (encoder.frames == 0) {
        return Error.BadImage;
    }

    return collectEncoded(&encoder, limits, true);
}

/// Flushes the encoder and gathers the emitted packets into a `Result`.
fn collectEncoded(
    encoder: *Encoder,
    limits: Limits,
    animated: bool,
) Error!Spec.Result {
    if (ffmpeg.avcodec_send_frame(encoder.ctx, null) < 0) {
        return Error.BadImage;
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(root.gpa);

    var out_packet: ?*ffmpeg.AVPacket = ffmpeg.av_packet_alloc() orelse {
        return Error.OutOfMemory;
    };
    defer ffmpeg.av_packet_free(&out_packet);

    while (true) {
        const received = ffmpeg.avcodec_receive_packet(encoder.ctx, out_packet);

        if (received < 0) {
            break;
        }

        const size: usize = @intCast(out_packet.?.size);

        if (size > 0) {
            if (out.items.len + size > limits.max_output_bytes) {
                ffmpeg.av_packet_unref(out_packet);

                return Error.BadImage;
            }

            out.appendSlice(root.gpa, out_packet.?.data[0..size]) catch {
                ffmpeg.av_packet_unref(out_packet);

                return Error.OutOfMemory;
            };
        }

        ffmpeg.av_packet_unref(out_packet);
    }

    if (out.items.len == 0) {
        return Error.BadImage;
    }

    const data = root.gpa.alloc(u8, out.items.len) catch {
        return Error.OutOfMemory;
    };
    errdefer root.gpa.free(data);

    @memcpy(data, out.items);

    return finishResult(data, animated);
}

fn finishResult(data: []u8, animated: bool) Spec.Result {
    if (animated) {
        forceInfiniteLoop(data);
    }

    var hash: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&hash, "{x:0>16}", .{std.hash.XxHash64.hash(0, data)}) catch unreachable;

    return .{
        .data = data,
        .hash = hash,
    };
}

/// Poll-based task that hands an already-buffered image to the media worker.
/// It is request-agnostic: the caller owns body buffering (`route.generic.Body`).
pub const Encode = struct {
    pub const Result = struct {
        /// WEBP bytes
        data: []const u8,
        /// XXHash64 of `data`, 16 lowercase hex chars.
        hash: [16]u8,
    };

    pub const Task = root.task.Task(Result, anyerror);
    pub const Lazy = root.task.LazyTask(Encode, Result, anyerror);

    pub const Payload = struct {
        data: []const u8,
        mime_type: []const u8,
        options: Options,
        limits: Limits,
    };

    payload: Payload,
    job: ?*Worker.Job = null,

    fn poll(ctx: *anyopaque) Task.PollT {
        const this: *Encode = @ptrCast(@alignCast(ctx));

        if (this.job == null) {
            this.job = root.media_worker.spawn(.{
                .input = this.payload.data,
                .mime_type = this.payload.mime_type,
                .options = this.payload.options,
                .limits = this.payload.limits,
            }) catch |err| {
                SCOPE.err("Encode failed to spawn a job: {t}", .{err});

                return .{ .err = err };
            } orelse {
                return .{ .pending = .job };
            };
        }

        if (this.job.?.check()) |res| {
            switch (res) {
                .ok => |ok| return .{
                    .ready = .{
                        .data = ok.data,
                        .hash = ok.hash,
                    },
                },
                .err => |err| return .{ .err = err },
            }
        }

        return .{ .pending = .job };
    }

    fn dispose(ctx: *anyopaque) void {
        const this: *Encode = @ptrCast(@alignCast(ctx));

        if (this.job) |j| {
            j.release();
            this.job = null;
        }
    }

    pub inline fn init(payload: Payload) Encode {
        return .{
            .payload = payload,
        };
    }

    pub inline fn task(this: *Encode) Task {
        return .init(this, &.{ .poll = poll, .dispose = dispose });
    }
};
