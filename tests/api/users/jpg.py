"""Stdlib-only baseline JPEG builder for image upload tests.

The server decodes JPEG with FFmpeg (``jpeg_pipe``/``mjpeg``) and re-encodes to
WebP. Building a full JPEG encoder by hand is unnecessary: the tests only need a
small, valid, decodable image at a known (non-square) size, optionally carrying
an EXIF ``Orientation`` tag.

The image is a uniform mid-gray frame. After the JPEG level shift (subtract 128)
every 8x8 block is all-zero, so the entropy stream is just ``DC category 0`` +
``AC EOB`` per block. Minimal custom Huffman tables (one 2-bit code each) keep
the bitstream trivial and deterministic. All three components reuse table 0
(legal: the SOS selectors are free), and every MCU is 8x8 because all sampling
factors are 1x1.
"""

import struct

# Minimal Huffman tables: a single 2-bit code ("00") per table. A code of all
# ones is forbidden by JPEG, so "00" is safe. DC table symbol 0 is "category 0"
# (a zero DC difference); AC table symbol 0x00 is EOB.
_HUFF_BITS = [0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
_HUFF_DC_VALUES = [0x00]
_HUFF_AC_VALUES = [0x00]

_DC_BITS = "00"
_AC_BITS = "00"


def _seg(marker, payload):
    return bytes([0xFF, marker]) + struct.pack(">H", len(payload) + 2) + payload


def _dqt(quality=1):
    # One 8-bit quantization table, id 0, every entry = quality.
    return _seg(0xDB, bytes([0x00]) + bytes([quality] * 64))


def _sof0(width, height, components=3):
    payload = bytes([8]) + struct.pack(">HH", height, width) + bytes([components])
    for cid in range(1, components + 1):
        payload += bytes([cid, 0x11, 0x00])  # sampling 1x1, quant table 0
    return _seg(0xC0, payload)


def _dht():
    payload = bytes([0x00]) + bytes(_HUFF_BITS) + bytes(_HUFF_DC_VALUES)
    payload += bytes([0x10]) + bytes(_HUFF_BITS) + bytes(_HUFF_AC_VALUES)
    return _seg(0xC4, payload)


def _sos(components=3):
    payload = bytes([components])
    for cid in range(1, components + 1):
        payload += bytes([cid, 0x00])  # DC table 0, AC table 0
    payload += bytes([0x00, 0x3F, 0x00])  # Ss=0, Se=63, Ah/Al=0
    return _seg(0xDA, payload)


def _exif_app1(orientation):
    # Little-endian TIFF with a single IFD0 entry: Orientation (0x0112), SHORT,
    # count 1, value = orientation.
    tiff = b"II" + struct.pack("<H", 42) + struct.pack("<I", 8)
    tiff += struct.pack("<H", 1)
    tiff += struct.pack("<HHI", 0x0112, 3, 1) + struct.pack("<H", orientation) + b"\x00\x00"
    tiff += struct.pack("<I", 0)  # next IFD
    return _seg(0xE1, b"Exif\x00\x00" + tiff)


def _entropy(width, height, components=3):
    mcus = ((width + 7) // 8) * ((height + 7) // 8)
    bits = (_DC_BITS + _AC_BITS) * mcus * components

    while len(bits) % 8 != 0:
        bits += "1"

    out = bytearray()

    for i in range(0, len(bits), 8):
        byte = int(bits[i : i + 8], 2)

        out.append(byte)

        if byte == 0xFF:
            out.append(0x00)

    return bytes(out)


def make_jpeg(width=16, height=8, orientation=None):
    """A valid baseline JPEG. ``orientation`` adds an EXIF Orientation tag."""
    parts = [b"\xFF\xD8"]

    if orientation is not None:
        parts.append(_exif_app1(orientation))

    parts.append(_dqt())
    parts.append(_sof0(width, height))
    parts.append(_dht())
    parts.append(_sos())
    parts.append(_entropy(width, height))
    parts.append(b"\xFF\xD9")

    return b"".join(parts)


def not_jpeg():
    return b"\xff\xd8this is not a jpeg\xff\xd9"
