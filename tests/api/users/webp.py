"""Stdlib-only WebP builders for avatar upload tests.

The server decodes and re-encodes every upload: static images through FFmpeg
and animations through libwebp (``WebPAnimDecoder``), because FFmpeg only
gained an animated WebP demuxer/decoder in 9.0 while the deployments run 7.x.

Building a valid WebP *bitstream* by hand would require a full VP8/VP8L
encoder, so this module embeds a few tiny valid lossless frames (``VP8L``, one
per colour) and reuses them inside hand-assembled RIFF containers. That gives
exact control over the frame count, the frame durations and the frame payloads,
which is what the animation-cap and malformed-input tests need.

The embedded frames are 8x8 lossless WebPs produced with:

    ffmpeg -f lavfi -i color=c=<colour>:s=8x8,format=rgba -frames:v 1 \
        -c:v libwebp -lossless 1 tiny.webp

Only the container is synthesised here; the compressed payloads stay the ones
FFmpeg emitted.
"""

import base64
import json
import struct
from pathlib import Path

# The animation caps the test server runs with, so the boundary tests below stay
# correct when ``config.tests.json`` bumps them.
_CONFIG_PATH = Path(__file__).resolve().parents[3] / "config.tests.json"

with _CONFIG_PATH.open() as _f:
    _CONFIG = json.load(_f)

AVATAR_MAX_ANIMATION_FRAMES = _CONFIG["media"]["avatar"]["max_animation_frames"]
AVATAR_MAX_ANIMATION_DURATION_MS = _CONFIG["media"]["avatar"][
    "max_animation_duration_ms"
]
EMOJI_MAX_ANIMATION_FRAMES = _CONFIG["media"]["emoji"]["max_animation_frames"]

# Complete 8x8 lossless WebPs (``RIFF``/``WEBP``/``VP8L``), one per colour.
TINY_WEBP = base64.b64decode("UklGRhwAAABXRUJQVlA4TA8AAAAvB8ABAAcQ/Y/+ByKi/wEA")
GREEN_WEBP = base64.b64decode("UklGRhwAAABXRUJQVlA4TA8AAAAvB8ABAAdQwIj+ByKi/wEA")
BLUE_WEBP = base64.b64decode("UklGRhwAAABXRUJQVlA4TA8AAAAvB8ABAAcQ0f/+ByKi/wEA")

# An extended still WebP (``VP8X`` + ``ALPH`` + ``VP8 ``), the shape lossy
# encoders emit for images with transparency.
EXTENDED_WEBP = base64.b64decode(
    "UklGRmAAAABXRUJQVlA4WAoAAAAQAAAABwAABwAAQUxQSAoAAAABB9C/iAhERP8DVlA4IDAAAADQ"
    "AQCdASoIAAgAAgA0JaACdLoB+AADsAD+8MQL/yC5YXXI1/8gP+QH/ID/+PIAAAA="
)

FRAME_WIDTH = 8
FRAME_HEIGHT = 8


def _find_chunk(data, fourcc):
    pos = 12

    while pos + 8 <= len(data):
        size = struct.unpack_from("<I", data, pos + 4)[0]

        if data[pos : pos + 4] == fourcc:
            return data[pos + 8 : pos + 8 + size]

        pos += 8 + size + (size & 1)

    raise AssertionError(f"no {fourcc!r} chunk in the embedded WebP")


def read_dimensions(data):
    """Return ``(width, height)`` of a WebP, for still lossy/lossless or
    extended containers."""
    assert data[:4] == b"RIFF" and data[8:12] == b"WEBP", "not a WebP"

    pos = 12

    while pos + 8 <= len(data):
        fourcc = data[pos : pos + 4]
        size = struct.unpack_from("<I", data, pos + 4)[0]
        payload = data[pos + 8 : pos + 8 + size]

        if fourcc == b"VP8X":
            return (
                int.from_bytes(payload[4:7], "little") + 1,
                int.from_bytes(payload[7:10], "little") + 1,
            )

        if fourcc == b"VP8L":
            bits = int.from_bytes(payload[1:5], "little")

            return ((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1)

        if fourcc == b"VP8 ":
            return (
                int.from_bytes(payload[6:8], "little") & 0x3FFF,
                int.from_bytes(payload[8:10], "little") & 0x3FFF,
            )

        pos += 8 + size + (size & 1)

    raise AssertionError("no image chunk in the WebP")


# The raw VP8L payloads. Distinct frames matter: an animation whose frames are
# all identical is collapsed to a still by the encoder, which would defeat the
# animated-path assertions.
VP8L_FRAMES = [_find_chunk(data, b"VP8L") for data in (TINY_WEBP, GREEN_WEBP, BLUE_WEBP)]
VP8L_FRAME = VP8L_FRAMES[0]

for _data in (TINY_WEBP, GREEN_WEBP, BLUE_WEBP):
    assert _data[:4] == b"RIFF" and _data[8:12] == b"WEBP"


def _u24(value):
    return value.to_bytes(3, "little")


def _chunk(fourcc, payload):
    pad = b"\x00" if len(payload) & 1 else b""
    return fourcc + struct.pack("<I", len(payload)) + payload + pad


def _riff(*chunks):
    body = b"WEBP" + b"".join(chunks)
    return b"RIFF" + struct.pack("<I", len(body)) + body


def _vp8x_payload(flags, width, height):
    return bytes([flags, 0, 0, 0]) + _u24(width - 1) + _u24(height - 1)


def make_webp():
    """A valid 8x8 lossless WebP."""
    return _riff(_chunk(b"VP8L", VP8L_FRAME))


def make_animated_webp(
    frames=3,
    duration_ms=100,
    loop=0,
    width=FRAME_WIDTH,
    height=FRAME_HEIGHT,
):
    """A valid animated WebP with `frames` identical frames.

    Frame colours cycle through three distinct payloads so the animation is not
    collapsed to a still. The frame durations are written verbatim into the
    `ANMF` chunks, so the caller controls the total animation duration exactly.
    """
    chunks = [
        _chunk(b"VP8X", _vp8x_payload(0x02, width, height)),
        _chunk(b"ANIM", b"\x00\x00\x00\x00" + struct.pack("<H", loop)),
    ]

    for index in range(frames):
        frame = _chunk(b"VP8L", VP8L_FRAMES[index % len(VP8L_FRAMES)])

        anmf = (
            _u24(0)
            + _u24(0)
            + _u24(width - 1)
            + _u24(height - 1)
            + _u24(duration_ms)
            + b"\x00"
            + frame
        )

        chunks.append(_chunk(b"ANMF", anmf))

    return _riff(*chunks)


def make_animated_webp_many_frames(
    frames=None,
    duration_ms=50,
    max_frames=AVATAR_MAX_ANIMATION_FRAMES,
):
    """One frame more than ``media.max_avatar_animation_frames``.

    The per-frame duration is kept short so the total stays under
    ``max_avatar_animation_duration_ms``: this must trip the *frame* cap, not
    the duration cap. Defaults to the configured cap so the test does not go
    stale when the limit changes.
    """
    if frames is None:
        frames = max_frames + 1

    return make_animated_webp(frames=frames, duration_ms=duration_ms)


def make_animated_webp_long(duration_ms=2000, frames=10):
    """A total duration above media.max_avatar_animation_duration_ms."""
    return make_animated_webp(frames=frames, duration_ms=duration_ms)


def make_animated_webp_lots_of_short_frames(frames=64, duration_ms=100):
    """Stays under the duration cap only when the per-frame minimum delay is
    wired correctly (the regression this guards against clamped every frame to
    max_avatar_animation_frame_delay_ms)."""
    return make_animated_webp(frames=frames, duration_ms=duration_ms)


def chunk_fourccs(data):
    """Top-level RIFF chunk fourccs of a WebP, in order."""
    assert data[:4] == b"RIFF" and data[8:12] == b"WEBP", "not a WebP"

    names = []
    pos = 12

    while pos + 8 <= len(data):
        size = struct.unpack_from("<I", data, pos + 4)[0]
        names.append(data[pos : pos + 4])
        pos += 8 + size + (size & 1)

    return names


def read_loop(data):
    """The `ANIM` loop count of an animated WebP, or None when there is none."""
    try:
        payload = _find_chunk(data, b"ANIM")
    except AssertionError:
        return None

    return struct.unpack_from("<H", payload, 4)[0]


def make_webp_with_padding(size=32768):
    """A valid WebP followed by a large unknown ancillary chunk.

    The body is larger than the socket buffer, so the server has to read it
    across many polls, while the image itself stays decodable.
    """
    return _riff(
        _chunk(b"VP8L", VP8L_FRAME),
        _chunk(b"JUNK", b"\x00" * size),
    )


# A sentinel embedded in every metadata payload below. Re-encoding must forward
# only decoded pixel frames, so it must never appear in the stored object.
METADATA_SENTINEL = b"DISTRANS_METADATA_SENTINEL"

# VP8X feature flags (libwebp WebPFeatureFlags).
_VP8X_ALPHA = 0x10
_VP8X_EXIF = 0x08
_VP8X_XMP = 0x04
_VP8X_ICCP = 0x20


def make_webp_with_metadata(width=FRAME_WIDTH, height=FRAME_HEIGHT):
    """A static WebP carrying ICCP, EXIF and XMP metadata chunks."""
    flags = _VP8X_ICCP | _VP8X_EXIF | _VP8X_XMP

    return _riff(
        _chunk(b"VP8X", _vp8x_payload(flags, width, height)),
        _chunk(b"ICCP", b"fake-icc-profile-" + METADATA_SENTINEL),
        _chunk(b"VP8L", VP8L_FRAME),
        _chunk(b"EXIF", b"Exif\x00\x00fake-exif-" + METADATA_SENTINEL),
        _chunk(b"XMP ", b"<x:xmpmeta>" + METADATA_SENTINEL + b"</x:xmpmeta>"),
    )


def make_animated_webp_with_metadata(
    frames=3,
    duration_ms=100,
    width=FRAME_WIDTH,
    height=FRAME_HEIGHT,
):
    """An animated WebP carrying ICCP, EXIF and XMP metadata chunks."""
    flags = 0x02 | _VP8X_ICCP | _VP8X_EXIF | _VP8X_XMP

    chunks = [
        _chunk(b"VP8X", _vp8x_payload(flags, width, height)),
        _chunk(b"ICCP", b"fake-icc-profile-" + METADATA_SENTINEL),
        _chunk(b"ANIM", b"\x00\x00\x00\x00" + struct.pack("<H", 0)),
    ]

    for index in range(frames):
        frame = _chunk(b"VP8L", VP8L_FRAMES[index % len(VP8L_FRAMES)])
        anmf = (
            _u24(0)
            + _u24(0)
            + _u24(width - 1)
            + _u24(height - 1)
            + _u24(duration_ms)
            + b"\x00"
            + frame
        )
        chunks.append(_chunk(b"ANMF", anmf))

    chunks.append(_chunk(b"EXIF", b"Exif\x00\x00fake-exif-" + METADATA_SENTINEL))
    chunks.append(_chunk(b"XMP ", b"<x:xmpmeta>" + METADATA_SENTINEL + b"</x:xmpmeta>"))

    return _riff(*chunks)


# --- malformed / undecodable -------------------------------------------------


def not_webp():
    return b"this is not a webp at all"


def bad_riff():
    data = bytearray(make_webp())
    data[0:4] = b"RIFX"
    return bytes(data)


def bad_webp_tag():
    data = bytearray(make_webp())
    data[8:12] = b"WEBB"
    return bytes(data)


def truncated():
    return make_webp()[:20]


def huge_dimensions(width=513, height=513):
    """A VP8X canvas above media.max_avatar_dimensions."""
    return _riff(
        _chunk(b"VP8X", _vp8x_payload(0, width, height)),
        _chunk(b"VP8L", VP8L_FRAME),
    )


def animated_without_frames():
    """VP8X advertises animation but no ANMF chunk follows."""
    return _riff(
        _chunk(b"VP8X", _vp8x_payload(0x02, FRAME_WIDTH, FRAME_HEIGHT)),
        _chunk(b"ANIM", b"\x00\x00\x00\x00\x00\x00"),
    )


def bad_vp8l_signature():
    payload = bytes([0x00]) + VP8L_FRAME[1:]
    return _riff(_chunk(b"VP8L", payload))


def extended_no_frame():
    """An extended container with dimensions but no decodable frame."""
    return _riff(
        _chunk(b"VP8X", _vp8x_payload(0, FRAME_WIDTH, FRAME_HEIGHT)),
    )


def _animated_with_raw_frame(frame_chunk, canvas=FRAME_WIDTH):
    """An animated container whose ANMF wraps `frame_chunk` verbatim."""
    anmf = (
        _u24(0)
        + _u24(0)
        + _u24(canvas - 1)
        + _u24(canvas - 1)
        + _u24(100)
        + b"\x00"
        + frame_chunk
    )

    return _riff(
        _chunk(b"VP8X", _vp8x_payload(0x02, canvas, canvas)),
        _chunk(b"ANIM", b"\x00\x00\x00\x00\x00\x00"),
        _chunk(b"ANMF", anmf),
    )


def animated_bad_frame_signature():
    """Animated, but the frame payload is not a VP8L bitstream."""
    return _animated_with_raw_frame(_chunk(b"VP8L", bytes([0x00]) + VP8L_FRAME[1:]))


def animated_bad_frame_chunk():
    """Animated, but the ANMF sub-chunk is not a known frame chunk."""
    return _animated_with_raw_frame(_chunk(b"NOPE", VP8L_FRAME))


def animated_no_frame_bitstream():
    """Animated, but the ANMF carries only an alpha chunk."""
    return _animated_with_raw_frame(_chunk(b"ALPH", b"\x00\x00\x00\x00"))


def animated_frame_out_of_canvas():
    """ANMF frame dimensions exceed the declared canvas."""
    anmf = (
        _u24(0)
        + _u24(0)
        + _u24(FRAME_WIDTH * 4 - 1)
        + _u24(FRAME_HEIGHT * 4 - 1)
        + _u24(100)
        + b"\x00"
        + _chunk(b"VP8L", VP8L_FRAME)
    )

    return _riff(
        _chunk(b"VP8X", _vp8x_payload(0x02, FRAME_WIDTH, FRAME_HEIGHT)),
        _chunk(b"ANIM", b"\x00\x00\x00\x00\x00\x00"),
        _chunk(b"ANMF", anmf),
    )


MALFORMED = {
    "animated_bad_frame_chunk": animated_bad_frame_chunk,
    "animated_bad_frame_signature": animated_bad_frame_signature,
    "animated_frame_out_of_canvas": animated_frame_out_of_canvas,
    "animated_no_frame_bitstream": animated_no_frame_bitstream,
    "animated_without_frames": animated_without_frames,
    "bad_riff": bad_riff,
    "bad_vp8l_signature": bad_vp8l_signature,
    "bad_webp_tag": bad_webp_tag,
    "extended_no_frame": extended_no_frame,
    "huge_dimensions": huge_dimensions,
    "not_webp": not_webp,
    "truncated": truncated,
}


def oversized_body():
    """A body just above the test config's media.max_avatar_input_bytes (1 MiB)."""
    return b"RIFF\xff\xff\xff\xffWEBP" + b"\x00" * (1024 * 1024 + 64 * 1024)
