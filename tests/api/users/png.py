"""Stdlib-only PNG/APNG builders for image upload tests.

The server decodes PNG and APNG with FFmpeg and re-encodes to WebP. FFmpeg is
more tolerant than a strict decoder: it accepts RGB/palette, 16-bit and
interlaced images and ignores CRC errors and trailing truncation, so the
helpers below are split into:

* ``MALFORMED`` - inputs that still fail to decode (400 "Bad image");
* ``TOLERATED`` - inputs FFmpeg accepts even though they are not strictly
  conformant (kept as explicit tests so the behavior is pinned);
* APNG builders used to exercise the animated path.

A PNG carrying a ``tEXt`` chunk is also provided to pin the metadata scrub:
re-encoding forwards only decoded pixel frames, so the chunk must not survive.
"""

import struct
import zlib

SIGNATURE = b"\x89PNG\r\n\x1a\n"
IHDR_SIZE = 13
BYTES_PER_PIXEL = 4


def chunk(ty, data):
    return (
        struct.pack(">I", len(data))
        + ty
        + data
        + struct.pack(">I", zlib.crc32(ty + data) & 0xFFFFFFFF)
    )


def ihdr(
    width,
    height,
    bit_depth=8,
    color_type=6,
    compression=0,
    filter_method=0,
    interlace=0,
):
    return chunk(
        b"IHDR",
        struct.pack(
            ">IIBBBBB",
            width,
            height,
            bit_depth,
            color_type,
            compression,
            filter_method,
            interlace,
        ),
    )


def raw_rows(width, height, color):
    return b"".join(b"\x00" + bytes(color) * width for _ in range(height))


# A sentinel embedded in every metadata chunk below. Re-encoding must forward
# only decoded pixel frames, so it must never appear in the stored object.
METADATA_SENTINEL = b"DISTRANS_METADATA_SENTINEL"


def text_chunk(keyword=b"Comment", text=b"distrans-secret"):
    return chunk(b"tEXt", keyword + b"\x00" + text)


def ztxt_chunk(keyword=b"Comment", text=b"distrans-secret"):
    return chunk(b"zTXt", keyword + b"\x00\x00" + zlib.compress(text, 9))


def itxt_chunk(keyword=b"Comment", text=b"distrans-secret"):
    # keyword, compression flag=0, compression method, language tag, translated
    # keyword, then the text.
    payload = keyword + b"\x00" + b"\x00\x00" + b"\x00" + b"\x00" + text
    return chunk(b"iTXt", payload)


def _minimal_tiff(text):
    """A minimal little-endian TIFF image file directory.

    The PNG ``eXIf`` chunk holds the raw TIFF stream (no ``Exif\\0\\0`` prefix);
    FFmpeg rejects a prefixed body as an invalid TIFF header.
    """
    ifd_offset = 8
    entry_count = 1
    # One ASCII tag, then room for the count, the entry and the next-IFD offset.
    ifd = struct.pack("<H", entry_count)
    ifd += struct.pack("<HHII", 0x010E, 2, len(text) + 1, ifd_offset + 2 + entry_count * 12 + 4)
    ifd += struct.pack("<I", 0)
    return b"II*\x00" + struct.pack("<I", ifd_offset) + ifd + text + b"\x00"


def exif_chunk(text=b"distrans-secret"):
    return chunk(b"eXIf", _minimal_tiff(text))


def make_png_with_all_text(width=4, height=4, color=(255, 0, 0, 255)):
    """A valid PNG carrying tEXt, zTXt, iTXt and eXIf metadata chunks."""
    raw = raw_rows(width, height, color)
    return (
        SIGNATURE
        + ihdr(width, height)
        + text_chunk(text=METADATA_SENTINEL)
        + ztxt_chunk(text=METADATA_SENTINEL)
        + itxt_chunk(text=METADATA_SENTINEL)
        + exif_chunk(text=METADATA_SENTINEL)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def make_png(width=4, height=4, color=(255, 0, 0, 255)):
    raw = raw_rows(width, height, color)
    return (
        SIGNATURE
        + ihdr(width, height)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def make_png_with_text(width=4, height=4, color=(255, 0, 0, 255), **kwargs):
    """A valid PNG carrying a ``tEXt`` chunk before the image data."""
    raw = raw_rows(width, height, color)
    return (
        SIGNATURE
        + ihdr(width, height)
        + text_chunk(**kwargs)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def make_noisy_png(width=300, height=300, seed=1):
    """A valid PNG whose compressed body is far larger than the socket buffer."""
    import random

    rng = random.Random(seed)
    rows = [
        b"\x00" + bytes(rng.getrandbits(8) for _ in range(width * BYTES_PER_PIXEL))
        for _ in range(height)
    ]
    raw = b"".join(rows)
    return (
        SIGNATURE
        + ihdr(width, height)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


# --- APNG -------------------------------------------------------------------


def actl(num_frames, num_plays=0):
    return chunk(b"acTL", struct.pack(">II", num_frames, num_plays))


def fctl(seq, width, height, x=0, y=0, delay_num=1, delay_den=10, dispose=0, blend=0):
    return chunk(
        b"fcTL",
        struct.pack(
            ">IIIIIHHBB", seq, width, height, x, y, delay_num, delay_den, dispose, blend
        ),
    )


def make_apng(
    width=4,
    height=4,
    frames=2,
    colors=None,
    delay_num=1,
    delay_den=10,
    num_plays=0,
):
    """A well-formed APNG. Frame 0 is stored in IDAT, the rest in fdAT."""
    if colors is None:
        colors = [(255, 0, 0, 255), (0, 255, 0, 255), (0, 0, 255, 255)]

    parts = [SIGNATURE, ihdr(width, height), actl(frames, num_plays)]

    seq = 0

    parts.append(fctl(seq, width, height, delay_num=delay_num, delay_den=delay_den))
    seq += 1
    parts.append(chunk(b"IDAT", zlib.compress(raw_rows(width, height, colors[0]), 9)))

    for i in range(1, frames):
        color = colors[i % len(colors)]
        parts.append(fctl(seq, width, height, delay_num=delay_num, delay_den=delay_den))
        seq += 1
        parts.append(
            chunk(
                b"fdAT",
                struct.pack(">I", seq) + zlib.compress(raw_rows(width, height, color), 9),
            )
        )
        seq += 1

    parts.append(chunk(b"IEND", b""))

    return b"".join(parts)


def make_apng_many_frames(frames=65):
    return make_apng(frames=frames)


def make_apng_long_delay(frames=10, delay_num=1000, delay_den=1):
    """Frame delays so large they stay above the max clamp for long enough to
    exceed media.animations_max_duration_ms."""
    return make_apng(frames=frames, delay_num=delay_num, delay_den=delay_den)


# --- malformed / tolerated --------------------------------------------------


def bad_signature():
    return b"X" + make_png()[1:]


def truncated():
    return make_png()[:-12]


def bad_ihdr_crc():
    data = bytearray(make_png())
    # signature + prologue + IHDR data; the first CRC byte follows.
    data[len(SIGNATURE) + 8 + IHDR_SIZE] ^= 0xFF
    return bytes(data)


def bad_idat_crc():
    data = bytearray(make_png())
    idx = data.find(b"IDAT")
    data_len = struct.unpack(">I", data[idx - 4 : idx])[0]
    data[idx + 4 + data_len] ^= 0xFF
    return bytes(data)


def bad_color_type():
    return (
        SIGNATURE
        + ihdr(4, 4, color_type=2)
        + chunk(b"IDAT", zlib.compress(raw_rows(4, 4, (255, 0, 0)), 9))
        + chunk(b"IEND", b"")
    )


def bad_bit_depth():
    return (
        SIGNATURE
        + ihdr(4, 4, bit_depth=16)
        + chunk(b"IDAT", zlib.compress(raw_rows(4, 4, (255, 0, 0, 255)), 9))
        + chunk(b"IEND", b"")
    )


def interlaced():
    return (
        SIGNATURE
        + ihdr(4, 4, interlace=1)
        + chunk(b"IDAT", zlib.compress(raw_rows(4, 4, (255, 0, 0, 255)), 9))
        + chunk(b"IEND", b"")
    )


def bad_zlib():
    return SIGNATURE + ihdr(4, 4) + chunk(b"IDAT", b"not zlib") + chunk(b"IEND", b"")


def bad_filter():
    raw = b"\x05" + bytes((255, 0, 0, 255)) * 4
    return (
        SIGNATURE
        + ihdr(4, 4)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def zero_dimensions():
    return SIGNATURE + ihdr(0, 4) + chunk(b"IDAT", zlib.compress(b"", 9)) + chunk(b"IEND", b"")


def huge_dimensions():
    return (
        SIGNATURE
        + ihdr(513, 513)
        + chunk(b"IDAT", zlib.compress(b"\x00\x00\x00\x00" * 513, 9))
        + chunk(b"IEND", b"")
    )


def not_png():
    return b"this is not a png at all"


def garbage_after_signature():
    # Larger than the 16 KB socket buffer, but small enough that the client can
    # finish sending before the server closes the connection after the 400.
    return SIGNATURE + b"\x00" * (64 * 1024)


def oversized_body():
    """A body just above the test config's media.avatar.max_input_bytes (1 MiB)."""
    return SIGNATURE + b"\x00" * (1024 * 1024 + 64 * 1024)


MALFORMED = {
    "bad_signature": bad_signature,
    "bad_zlib": bad_zlib,
    "zero_dimensions": zero_dimensions,
    "huge_dimensions": huge_dimensions,
    "not_png": not_png,
    "garbage_after_signature": garbage_after_signature,
}

# Accepted despite not being strictly conformant; FFmpeg does not verify CRCs,
# rejects only unknown filters it cannot undo, and decodes the IDAT stream it
# can read before EOF.
TOLERATED = {
    "bad_ihdr_crc": bad_ihdr_crc,
    "bad_idat_crc": bad_idat_crc,
    "bad_color_type": bad_color_type,
    "bad_bit_depth": bad_bit_depth,
    "bad_filter": bad_filter,
    "interlaced": interlaced,
    "truncated": truncated,
}
