"""Avatar fetching and transcoding helpers for ``importguild.py``.

The helpers here only touch the network and ``ffmpeg``/``ffprobe``; they never
open a database connection. The stored bytes must be WebP because the server
serves every avatar as ``image/webp`` and keys it with ``XXHash64`` of the
stored bytes (``src/services/media.zig``), so a downloaded PNG/GIF has to be
re-encoded locally with the same ``media.avatar`` settings the server uses.

``XXHash64`` is implemented inline so the importer does not need an extra
dependency: ``std.hash.XxHash64.hash(0, data)`` in the server is the canonical
xxHash64, which is what :func:`xxh64` computes.
"""
import dataclasses
import json
import os
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

_MASK64 = 0xFFFFFFFFFFFFFFFF
_P1 = 0x9E3779B185EBCA87
_P2 = 0xC2B2AE3D27D4EB4F
_P3 = 0x165667B19E3779F9
_P4 = 0x85EBCA77C2B2AE63
_P5 = 0x27D4EB2F165667C5

AVATAR_SECTION = "avatar"
EMOJI_SECTION = "emoji"


class SourceTooLarge(Exception):
    """The downloaded source exceeds ``max_input_bytes``."""


@dataclasses.dataclass
class Encoded:
    data: bytes
    hash: str
    downgraded: bool = False


@dataclasses.dataclass
class AvatarLimits:
    lossless: bool = False
    quality: int = 75
    compression_level: int = 4
    max_dimensions: int = 512
    max_input_bytes: int = 2 * 1024 * 1024
    max_output_bytes: int = 2 * 1024 * 1024
    max_animation_frames: int = 64
    max_animation_duration_ms: int = 10_000
    min_animation_frame_delay_ms: int = 20
    max_animation_frame_delay_ms: int = 2_000

    @classmethod
    def from_config(cls, config, section=AVATAR_SECTION):
        media = config.get("media") if isinstance(config, dict) else None
        section = media.get(section) if isinstance(media, dict) else None

        if not isinstance(section, dict):
            return cls()

        def flag(name, default):
            value = section.get(name)
            return bool(value) if isinstance(value, bool) else default

        def number(name, default, minimum=1):
            value = section.get(name)
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                return default
            return max(minimum, int(value))

        limits = cls(
            lossless=flag("lossless", cls.lossless),
            quality=min(100, number("quality", cls.quality, 0)),
            compression_level=min(6, number("compression_level", cls.compression_level, 0)),
            max_dimensions=number("max_dimensions", cls.max_dimensions),
            max_input_bytes=number("max_input_bytes", cls.max_input_bytes),
            max_output_bytes=number("max_output_bytes", cls.max_output_bytes),
            max_animation_frames=number("max_animation_frames", cls.max_animation_frames),
            max_animation_duration_ms=number("max_animation_duration_ms", cls.max_animation_duration_ms),
            min_animation_frame_delay_ms=number("min_animation_frame_delay_ms", cls.min_animation_frame_delay_ms),
            max_animation_frame_delay_ms=number("max_animation_frame_delay_ms", cls.max_animation_frame_delay_ms),
        )

        if limits.max_animation_frame_delay_ms < limits.min_animation_frame_delay_ms:
            limits.max_animation_frame_delay_ms = limits.min_animation_frame_delay_ms

        return limits


def _rotl(value, count):
    return ((value << count) | (value >> (64 - count))) & _MASK64


def _round(accumulator, block):
    accumulator = (accumulator + block * _P2) & _MASK64
    accumulator = _rotl(accumulator, 31)
    return (accumulator * _P1) & _MASK64


def _merge_round(accumulator, value):
    accumulator ^= _round(0, value)
    return (accumulator * _P1 + _P4) & _MASK64


def xxh64(data, seed=0):
    """Canonical xxHash64 of ``data`` (matches Zig's ``std.hash.XxHash64``)."""
    length = len(data)
    index = 0

    if length >= 32:
        v1 = (seed + _P1 + _P2) & _MASK64
        v2 = (seed + _P2) & _MASK64
        v3 = seed & _MASK64
        v4 = (seed - _P1) & _MASK64

        while index <= length - 32:
            v1 = _round(v1, int.from_bytes(data[index : index + 8], "little"))
            v2 = _round(v2, int.from_bytes(data[index + 8 : index + 16], "little"))
            v3 = _round(v3, int.from_bytes(data[index + 16 : index + 24], "little"))
            v4 = _round(v4, int.from_bytes(data[index + 24 : index + 32], "little"))
            index += 32

        accumulator = (
            _rotl(v1, 1) + _rotl(v2, 7) + _rotl(v3, 12) + _rotl(v4, 18)
        ) & _MASK64
        accumulator = _merge_round(accumulator, v1)
        accumulator = _merge_round(accumulator, v2)
        accumulator = _merge_round(accumulator, v3)
        accumulator = _merge_round(accumulator, v4)
    else:
        accumulator = (seed + _P5) & _MASK64

    accumulator = (accumulator + length) & _MASK64

    while index + 8 <= length:
        block = _round(0, int.from_bytes(data[index : index + 8], "little"))
        accumulator ^= block
        accumulator = (_rotl(accumulator, 27) * _P1 + _P4) & _MASK64
        index += 8

    if index + 4 <= length:
        accumulator ^= (int.from_bytes(data[index : index + 4], "little") * _P1) & _MASK64
        accumulator = (_rotl(accumulator, 23) * _P2 + _P3) & _MASK64
        index += 4

    while index < length:
        accumulator ^= (data[index] * _P5) & _MASK64
        accumulator = (_rotl(accumulator, 11) * _P1) & _MASK64
        index += 1

    accumulator ^= accumulator >> 33
    accumulator = (accumulator * _P2) & _MASK64
    accumulator ^= accumulator >> 29
    accumulator = (accumulator * _P3) & _MASK64
    accumulator ^= accumulator >> 32

    return accumulator


def content_hash(data):
    return f"{xxh64(data):016x}"


def normalize_cdn_size(url, max_dimensions):
    """Clamp a Discord CDN ``size`` query parameter to the avatar cap."""
    if not url:
        return url

    parsed = urllib.parse.urlsplit(url)

    if "discordapp" not in (parsed.netloc or ""):
        return url

    size = 16
    while size * 2 <= max_dimensions:
        size *= 2

    params = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
    replaced = False
    rebuilt = []

    for key, value in params:
        if key == "size":
            rebuilt.append((key, str(size)))
            replaced = True
        else:
            rebuilt.append((key, value))

    if not replaced:
        rebuilt.append(("size", str(size)))

    return urllib.parse.urlunsplit(parsed._replace(query=urllib.parse.urlencode(rebuilt)))


def _cdn_size_candidates(url, minimum=64):
    """Discord CDN URLs to try, halving the requested size on each fallback."""
    candidates = [url]

    for _ in range(4):
        parsed = urllib.parse.urlsplit(candidates[-1])

        if "discordapp" not in (parsed.netloc or ""):
            break

        params = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
        current = None

        for key, value in params:
            if key == "size":
                try:
                    current = int(value)
                except ValueError:
                    current = None

        if not current or current <= minimum:
            break

        next_size = max(minimum, current // 2)
        rebuilt = [(key, str(next_size) if key == "size" else value) for key, value in params]
        candidates.append(
            urllib.parse.urlunsplit(parsed._replace(query=urllib.parse.urlencode(rebuilt)))
        )

    return candidates


def _download(url, max_bytes, timeout=30, attempts=4):
    request = urllib.request.Request(
        url, headers={"User-Agent": "distrans-importguild/1.0"}
    )

    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                data = response.read(max_bytes + 1)

            if len(data) > max_bytes:
                raise SourceTooLarge(f"source exceeds max_input_bytes ({max_bytes})")

            return data
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503, 504) and attempt + 1 < attempts:
                time.sleep(2**attempt)

                continue

            raise


def download(url, max_bytes=None, timeout=30, attempts=4):
    """Download ``url``, optionally capped at ``max_bytes``.

    Returns the raw bytes. Unlike :func:`_download` this is the public entry
    point used for passthrough attachments (no size cap by default); it raises
    on failure so the caller can count the skip.
    """
    if max_bytes is None:
        request = urllib.request.Request(
            url, headers={"User-Agent": "distrans-importguild/1.0"}
        )

        last_error = None

        for attempt in range(attempts):
            try:
                with urllib.request.urlopen(request, timeout=timeout) as response:
                    return response.read()
            except urllib.error.HTTPError as e:
                last_error = e

                if e.code in (429, 500, 502, 503, 504) and attempt + 1 < attempts:
                    time.sleep(2**attempt)

                    continue

                raise
            except (urllib.error.URLError, OSError):
                raise

        raise last_error

    return _download(url, max_bytes, timeout=timeout, attempts=attempts)



def _run(cmd):
    result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    if result.returncode != 0:
        message = result.stderr.decode("utf-8", "replace").strip()
        raise RuntimeError(message or f"{cmd[0]} exited with {result.returncode}")

    return result.stdout.decode("utf-8", "replace")


def _float_or_none(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _int_or_none(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _parse_fraction(value):
    if not value or value == "0/0":
        return None

    if "/" in value:
        numerator, _, denominator = value.partition("/")
        numerator_value = _float_or_none(numerator)
        denominator_value = _float_or_none(denominator)

        if not numerator_value or not denominator_value:
            return None

        return numerator_value / denominator_value

    return _float_or_none(value)


def _probe(path):
    cmd = [
        "ffprobe",
        "-v",
        "error",
        "-count_frames",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream=width,height,nb_read_frames,nb_frames,avg_frame_rate,r_frame_rate",
        "-show_entries",
        "format=duration",
        "-of",
        "json",
        path,
    ]
    payload = json.loads(_run(cmd))
    streams = payload.get("streams") or []

    if not streams:
        raise ValueError("no video stream")

    stream = streams[0]
    frames = (
        _int_or_none(stream.get("nb_read_frames"))
        or _int_or_none(stream.get("nb_frames"))
        or 1
    )

    return {
        "frames": frames,
        "width": _int_or_none(stream.get("width")) or 0,
        "height": _int_or_none(stream.get("height")) or 0,
        "duration_s": _float_or_none((payload.get("format") or {}).get("duration")),
        "fps": _parse_fraction(stream.get("avg_frame_rate"))
        or _parse_fraction(stream.get("r_frame_rate"))
        or 0.0,
    }


def _probe_frame_times(path):
    """Return ``(timestamps, explicit_durations)`` in seconds.

    The animated WebP demuxer reports a frame `duration` in raw ticks without
    `pkt_duration_time`, so per-frame timing is reconstructed from the
    ``best_effort_timestamp_time`` deltas by the caller.
    """
    cmd = [
        "ffprobe",
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_entries",
        "frame=best_effort_timestamp_time,pkt_duration_time",
        "-of",
        "json",
        path,
    ]
    payload = json.loads(_run(cmd))
    timestamps = []
    explicit = []

    for frame in payload.get("frames") or []:
        timestamps.append(_float_or_none(frame.get("best_effort_timestamp_time")))
        explicit.append(_float_or_none(frame.get("pkt_duration_time")))

    return timestamps, explicit


def _frame_durations(path):
    timestamps, explicit = _probe_frame_times(path)
    durations = []

    for index in range(len(timestamps)):
        if explicit[index] is not None:
            durations.append(explicit[index])
        elif (
            index + 1 < len(timestamps)
            and timestamps[index] is not None
            and timestamps[index + 1] is not None
        ):
            durations.append(timestamps[index + 1] - timestamps[index])
        else:
            durations.append(None)

    known = sorted(duration for duration in durations if duration is not None)

    if not known:
        return [duration for duration in durations if duration is not None]

    median = known[len(known) // 2]

    return [duration if duration is not None else median for duration in durations]


def _scaled_size(width, height, max_dimensions):
    largest = max(width, height)

    if largest <= max_dimensions:
        return width, height

    ratio = max_dimensions / largest
    return max(1, round(width * ratio)), max(1, round(height * ratio))


def _ladder(limits):
    quality = max(0, min(100, limits.quality))
    level = max(0, min(6, limits.compression_level))

    yield quality, level

    while quality > 0 or level < 6:
        quality = max(0, quality - 15)
        level = min(6, level + 1)
        yield quality, level


def _scale_filter(size, source_size):
    if size == source_size:
        return None

    return f"scale={size[0]}:{size[1]}"


def _encode_static(source, tmp_dir, info, limits, output_name="out.webp"):
    size = _scaled_size(info["width"], info["height"], limits.max_dimensions)
    filters = [entry for entry in (_scale_filter(size, (info["width"], info["height"])),) if entry]

    for quality, level in _ladder(limits):
        destination = os.path.join(tmp_dir, output_name)
        cmd = ["ffmpeg", "-y", "-v", "error", "-i", source]

        if filters:
            cmd += ["-vf", ",".join(filters)]

        cmd += [
            "-frames:v",
            "1",
            "-c:v",
            "libwebp",
            "-lossless",
            "1" if limits.lossless else "0",
            "-q:v",
            str(quality),
            "-compression_level",
            str(level),
            "-f",
            "webp",
            destination,
        ]
        _run(cmd)

        with open(destination, "rb") as f:
            data = f.read()

        if len(data) <= limits.max_output_bytes:
            return data

    return None


def _output_violates_caps(path, limits):
    durations = _frame_durations(path)

    if not durations:
        return True

    if len(durations) > limits.max_animation_frames:
        return True

    total_ms = sum(durations) * 1000.0

    if total_ms > limits.max_animation_duration_ms + 1:
        return True

    for duration in durations:
        milliseconds = duration * 1000.0

        if (
            milliseconds + 1 < limits.min_animation_frame_delay_ms
            or milliseconds - 1 > limits.max_animation_frame_delay_ms
        ):
            return True

    return False


def _encode_animated(source, tmp_dir, info, limits):
    size = _scaled_size(info["width"], info["height"], limits.max_dimensions)
    source_size = (info["width"], info["height"])

    fps_min = 1000.0 / limits.max_animation_frame_delay_ms
    fps_max = 1000.0 / limits.min_animation_frame_delay_ms
    source_fps = info.get("fps") or 0.0

    if source_fps <= 0:
        forced_fps = fps_max
    elif source_fps < fps_min:
        forced_fps = fps_min
    elif source_fps > fps_max:
        forced_fps = fps_max
    else:
        forced_fps = None

    for quality, level in _ladder(limits):
        destination = os.path.join(tmp_dir, "out.webp")
        cmd = ["ffmpeg", "-y", "-v", "error", "-i", source]

        filters = [entry for entry in (_scale_filter(size, source_size),) if entry]

        if forced_fps is not None:
            filters.append(f"fps={forced_fps:.6f}")

        if filters:
            cmd += ["-vf", ",".join(filters)]

        cmd += [
            "-t",
            f"{limits.max_animation_duration_ms / 1000.0:.3f}",
            "-frames:v",
            str(limits.max_animation_frames),
            "-c:v",
            "libwebp_anim",
            "-loop",
            "0",
            "-lossless",
            "1" if limits.lossless else "0",
            "-q:v",
            str(quality),
            "-compression_level",
            str(level),
            "-f",
            "webp",
            destination,
        ]
        _run(cmd)

        with open(destination, "rb") as f:
            data = f.read()

        if len(data) > limits.max_output_bytes:
            continue

        if _output_violates_caps(destination, limits):
            break

        return data, False

    fallback = _encode_static(source, tmp_dir, info, limits, output_name="fallback.webp")

    if fallback is None:
        return None, False

    return fallback, True


def encode_avatar(url, limits, *, fetch=None, log=None):
    """Download and re-encode one avatar to a compliant WebP.

    Returns an :class:`Encoded`, or ``None`` when the source cannot be fetched
    or cannot be brought within the configured caps. ``fetch(url, max_bytes)``
    can be overridden in tests.
    """
    fetch = fetch or _download
    log = log or (lambda _message: None)

    source = None
    last_error = None

    for candidate in _cdn_size_candidates(url):
        try:
            source = fetch(candidate, limits.max_input_bytes)

            break
        except SourceTooLarge as e:
            last_error = e
            log(f"avatar source too large ({e}), retrying at a smaller size")

            continue
        except Exception as e:  # noqa: BLE001 - a bad avatar must never abort the import
            log(f"avatar download failed: {e}")

            return None

    if source is None:
        log(f"avatar download failed: {last_error}")

        return None

    if not source:
        log("avatar source is empty")
        return None

    with tempfile.TemporaryDirectory(prefix="importguild-avatar-") as tmp_dir:
        source_path = os.path.join(tmp_dir, "source")
        with open(source_path, "wb") as f:
            f.write(source)

        try:
            info = _probe(source_path)
        except Exception as e:  # noqa: BLE001
            log(f"avatar probe failed: {e}")
            return None

        if info["width"] <= 0 or info["height"] <= 0:
            log("avatar has no dimensions")
            return None

        try:
            if info["frames"] > 1:
                data, downgraded = _encode_animated(source_path, tmp_dir, info, limits)
            else:
                data = _encode_static(source_path, tmp_dir, info, limits)
                downgraded = False
        except Exception as e:  # noqa: BLE001
            log(f"avatar transcode failed: {e}")
            return None

    if data is None:
        log("avatar does not fit the media caps")
        return None

    return Encoded(data=data, hash=content_hash(data), downgraded=downgraded)


def normalize_emoji_url(emoji_id, animated, max_dimensions):
    """Build the Discord CDN URL for a custom emoji icon at the largest size
    that fits ``max_dimensions`` (Discord rounds the `size` param to powers of
    two)."""
    size = 16
    while size * 2 <= max_dimensions:
        size *= 2

    suffix = "gif" if animated else "png"

    return (
        f"https://cdn.discordapp.com/emojis/{emoji_id}.{suffix}"
        f"?size={size}"
    )


def encode_emoji(url, limits, *, fetch=None, log=None):
    """Download and re-encode one custom emoji icon (see :func:`encode_avatar`)."""
    return encode_avatar(url, limits, fetch=fetch, log=log)
