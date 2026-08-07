"""Stdlib-only GIF89a builders for image upload tests.

The server decodes GIF with FFmpeg and re-encodes to animated WebP. Building a
valid GIF *bitstream* by hand would require a correct LZW encoder, so (as in
``webp.py``) this module embeds a few tiny valid GIFs produced with:

    ffmpeg -f lavfi -i color=c=<colour>:s=4x4:r=10:d=0.1 -frames:v 1 tiny.gif

Only the container is synthesised here: the metadata extensions are spliced in
after the global colour table, which is what the metadata-scrub tests need. The
compressed image data stays the one FFmpeg emitted.
"""

import base64
import struct

# A 4x4 single-colour GIF89a with a 256-entry global colour table.
GOOD_GIF = base64.b64decode(
    "R0lGODlhBAAEAPcfMQAAACQAAEgAAGwAAJAAALQAANgAAPwAAAAkACQkAEgkAGwkAJAkALQk"
    "ANgkAPwkAABIACRIAEhIAGxIAJBIALRIANhIAPxIAABsACRsAEhsAGxsAJBsALRsANhsAPxs"
    "AACQACSQAEiQAGyQAJCQALSQANiQAPyQAAC0ACS0AEi0AGy0AJC0ALS0ANi0APy0AADYACTY"
    "AEjYAGzYAJDYALTYANjYAPzYAAD8ACT8AEj8AGz8AJD8ALT8ANj8APz8AAAAVSQAVUgAVWwA"
    "VZAAVbQAVdgAVfwAVQAkVSQkVUgkVWwkVZAkVbQkVdgkVfwkVQBIVSRIVUhIVWxIVZBIVbRI"
    "VdhIVfxIVQBsVSRsVUhsVWxsVZBsVbRsVdhsVfxsVQCQVSSQVUiQVWyQVZCQVbSQVdiQVfyQ"
    "VQC0VSS0VUi0VWy0VZC0VbS0Vdi0Vfy0VQDYVSTYVUjYVWzYVZDYVbTYVdjYVfzYVQD8VST8"
    "VUj8VWz8VZD8VbT8Vdj8Vfz8VQAAqiQAqkgAqmwAqpAAqrQAqtgAqvwAqgAkqiQkqkgkqmwk"
    "qpAkqrQkqtgkqvwkqgBIqiRIqkhIqmxIqpBIqrRIqthIqvxIqgBsqiRsqkhsqmxsqpBsqrRs"
    "qthsqvxsqgCQqiSQqkiQqmyQqpCQqrSQqtiQqvyQqgC0qiS0qki0qmy0qpC0qrS0qti0qvy0"
    "qgDYqiTYqkjYqmzYqpDYqrTYqtjYqvzYqgD8qiT8qkj8qmz8qpD8qrT8qtj8qvz8qgAA/yQA"
    "/0gA/2wA/5AA/7QA/9gA//wA/wAk/yQk/0gk/2wk/5Ak/7Qk/9gk//wk/wBI/yRI/0hI/2xI"
    "/5BI/7RI/9hI//xI/wBs/yRs/0hs/2xs/5Bs/7Rs/9hs//xs/wCQ/ySQ/0iQ/2yQ/5CQ/7SQ"
    "/9iQ//yQ/wC0/yS0/0i0/2y0/5C0/7S0/9i0//y0/wDY/yTY/0jY/2zY/5DY/7TY/9jY//zY"
    "/wD8/yT8/0j8/0j8/5D8/7T8/9j8//z8/yH/C05FVFNDQVBFMi4wAwEAAAAh+QQECgAfACwA"
    "AAAABAAEAAAICwAPCBxIUKCBgQEBADs="
)

# A 4x4 three-frame animated GIF89a (red/green/blue, 100 ms per frame).
GOOD_ANIMATED_GIF = base64.b64decode(
    "R0lGODlhBAAEAPcfMQAAACQAAEgAAGwAAJAAALQAANgAAPwAAAAkACQkAEgkAGwkAJAkALQk"
    "ANgkAPwkAABIACRIAEhIAGxIAJBIALRIANhIAPxIAABsACRsAEhsAGxsAJBsALRsANhsAPxs"
    "AACQACSQAEiQAGyQAJCQALSQANiQAPyQAAC0ACS0AEi0AGy0AJC0ALS0ANi0APy0AADYACTY"
    "AEjYAGzYAJDYALTYANjYAPzYAAD8ACT8AEj8AGz8AJD8ALT8ANj8APz8AAAAVSQAVUgAVWwA"
    "VZAAVbQAVdgAVfwAVQAkVSQkVUgkVWwkVZAkVbQkVdgkVfwkVQBIVSRIVUhIVWxIVZBIVbRI"
    "VdhIVfxIVQBsVSRsVUhsVWxsVZBsVbRsVdhsVfxsVQCQVSSQVUiQVWyQVZCQVbSQVdiQVfyQ"
    "VQC0VSS0VUi0VWy0VZC0VbS0Vdi0Vfy0VQDYVSTYVUjYVWzYVZDYVbTYVdjYVfzYVQD8VST8"
    "VUj8VWz8VZD8VbT8Vdj8Vfz8VQAAqiQAqkgAqmwAqpAAqrQAqtgAqvwAqgAkqiQkqkgkqmwk"
    "qpAkqrQkqtgkqvwkqgBIqiRIqkhIqmxIqpBIqrRIqthIqvxIqgBsqiRsqkhsqmxsqpBsqrRs"
    "qthsqvxsqgCQqiSQqkiQqmyQqpCQqrSQqtiQqvyQqgC0qiS0qki0qmy0qpC0qrS0qti0qvy0"
    "qgDYqiTYqkjYqmzYqpDYqrTYqtjYqvzYqgD8qiT8qkj8qmz8qpD8qrT8qtj8qvz8qgAA/yQA"
    "/0gA/2wA/5AA/7QA/9gA//wA/wAk/yQk/0gk/2wk/5Ak/7Qk/9gk//wk/wBI/yRI/0hI/2xI"
    "/5BI/7RI/9hI//xI/wBs/yRs/0hs/2xs/5Bs/7Rs/9hs//xs/wCQ/ySQ/0iQ/2yQ/5CQ/7SQ"
    "/9iQ//yQ/wC0/yS0/0i0/2y0/5C0/7S0/9i0//y0/wDY/yTY/0jY/2zY/5DY/7TY/9jY//zY"
    "/wD8/yT8/0j8/2z8/5D8/7T8/9j8//z8/yH/C05FVFNDQVBFMi4wAwEAAAAh+QQECgAfACwA"
    "AAAABAAEAAAICwAPCBxIUKCBgQEBACH5BAUKAAAALAAAAAAEAAQAAAgNAEFgACGwYEEMAwcG"
    "BAAh+QQFCgAAACwAAAAABAAEAAAICgABARtIsKDBgAAAOw=="
)

# The global colour table ends here (header 6 + descriptor 7 + 3 * 256).
_GCT_END = 13 + 3 * 256

# A sentinel embedded in every metadata extension below. Re-encoding must
# forward only decoded pixel frames, so it must never appear in the stored
# object.
METADATA_SENTINEL = b"DISTRANS_METADATA_SENTINEL"


def _sub_blocks(data):
    out = bytearray()
    pos = 0

    while pos < len(data):
        block = data[pos : pos + 255]
        out.append(len(block))
        out += block
        pos += len(block)

    out.append(0)

    return bytes(out)


def comment_extension(text):
    """A GIF comment extension (`0x21 0xFE`)."""
    return b"\x21\xfe" + _sub_blocks(text)


def application_extension(identifier, data):
    """A GIF application extension (`0x21 0xFF`)."""
    block = identifier[:8].ljust(8, b"\x00") + b"\x01\x00\x00" + data

    return b"\x21\xff" + _sub_blocks(block)


def _splice(base, extensions):
    """Insert `extensions` after the global colour table of `base`."""
    return base[:_GCT_END] + b"".join(extensions) + base[_GCT_END:]


def make_gif():
    """A valid static GIF89a."""
    return GOOD_GIF


def make_animated_gif():
    """A valid 3-frame animated GIF89a."""
    return GOOD_ANIMATED_GIF


def make_gif_with_metadata():
    """A static GIF89a carrying comment and application extensions."""
    return _splice(
        GOOD_GIF,
        [
            comment_extension(b"comment-" + METADATA_SENTINEL),
            application_extension(b"NETSCAPE", b"app-" + METADATA_SENTINEL),
        ],
    )


def make_animated_gif_with_metadata():
    """An animated GIF89a carrying comment and application extensions."""
    return _splice(
        GOOD_ANIMATED_GIF,
        [
            comment_extension(b"comment-" + METADATA_SENTINEL),
            application_extension(b"NETSCAPE", b"app-" + METADATA_SENTINEL),
        ],
    )


# --- malformed --------------------------------------------------------------

MALFORMED = {
    "bad_signature": lambda: b"XIF89a" + GOOD_GIF[6:],
    "not_gif": lambda: b"definitely not a gif",
    "empty": lambda: b"GIF89a",
}

# FFmpeg decodes a GIF that is missing only the trailer.
TOLERATED = {
    "truncated": lambda: GOOD_GIF[:-6],
}
