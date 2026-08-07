# Tests for the file endpoints:
#   POST /api/files
#
# Requirement numbering mirrors src/route/files.zig.
#
# PostTask:
#   R1 - user must be logged
#   R2 - storage configured
#   R3 - non-empty body; else 400 "Bad file"
#   R4 - Content-Type allowed by files.whitelist; else 415
#   R5 - body at most files.max_size; else 413 "File is too large"
#   R6 - "name" query parameter is required and valid
#   R7 - supported raster types are re-encoded to webp (<= media.files.max_input_bytes);
#        other whitelisted types are stored raw
#   R8 - hash + insert/reuse + S3 upload; 201 for a new file, 200 when the bytes
#        already exist; body
#        {"id","name","size","content_type","hash","public_url"}

import hashlib
import re
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "users"))

from conftest import CONFIG

import gif
import jpg
import png
import webp

MAX_SIZE = CONFIG["files"]["max_size"]
PUBLIC_BASE_URL = CONFIG["files"]["s3"]["public_base_url"]
MAX_FILES_INPUT = CONFIG["media"]["files"]["max_input_bytes"]

HASH_RE = re.compile(r"^[0-9a-f]{64}$")

# A real, decodable WebP so the re-encode path is exercised.
WEBP_BYTES = webp.make_webp()
PNG_BYTES = png.make_png(4, 4)
GIF_BYTES = gif.make_animated_gif()
TEXT_BYTES = b"hello, distrans\n"


def auth_headers(session):
    return {"Authorization": f"Bearer {session.access_token}"}


def upload(http_client, session, content=WEBP_BYTES, name="file.webp", **kwargs):
    headers = kwargs.pop("headers", None)

    if headers is None:
        headers = auth_headers(session)

    if content is not None:
        headers["Content-Type"] = kwargs.pop("content_type", "image/webp")

    params = kwargs.pop("params", {"name": name})

    return http_client.post(
        "/api/files", content=content, headers=headers, params=params, **kwargs
    )


def assert_file_body(body, *, name, size, content_type, hash_value):
    assert body["id"].isdigit()
    assert body["name"] == name
    assert body["size"] == size
    assert body["content_type"] == content_type
    assert body["hash"] == hash_value
    assert body["public_url"] == f"{PUBLIC_BASE_URL}/files/{hash_value}"
    # created_at is not part of the client-facing shape.
    assert "created_at" not in body


# R1 - POST /api/files requires a bearer token
def test_post_files_unauthorized(http_client):
    response = http_client.post(
        "/api/files",
        content=WEBP_BYTES,
        headers={"Content-Type": "image/webp"},
        params={"name": "file.webp"},
    )

    assert response.status_code == 401


def test_post_files_success(http_client, test_session, s3_mock):
    response = upload(http_client, test_session)

    assert response.status_code == 201

    body = response.json()
    assert HASH_RE.match(body["hash"])
    assert_file_body(
        body,
        name="file.webp",
        size=len(s3_mock.get(f"files/{body['hash']}")),
        content_type="image/webp",
        hash_value=body["hash"],
    )

    # R8 - the re-encoded bytes reached S3 under files/<hash>
    stored = s3_mock.get(f"files/{body['hash']}")
    assert stored is not None
    assert stored[:4] == b"RIFF"
    assert stored[8:12] == b"WEBP"
    assert s3_mock.get_content_type(f"files/{body['hash']}") == "image/webp"


def test_post_files_dedup(http_client, test_session, s3_mock):
    first_response = upload(http_client, test_session)
    second_response = upload(http_client, test_session)

    # The first upload creates a row (201); the second reuses it (200).
    assert first_response.status_code == 201
    assert second_response.status_code == 200

    first = first_response.json()
    second = second_response.json()

    assert first == second

    # only one PUT happened
    puts = [r for r in s3_mock.requests if r[0] == "PUT"]
    assert len(puts) == 1


# R3 - the body must be non-empty
def test_post_files_empty_body(http_client, test_session):
    response = upload(http_client, test_session, content=b"")

    assert response.status_code == 400
    assert response.json()["message"] == "Bad file"


# R4 - Content-Type must be allowed by files.whitelist
def test_post_files_not_whitelisted(http_client, test_session):
    response = upload(http_client, test_session, content_type="application/json")

    assert response.status_code == 415
    assert response.json()["message"] == "Unsupported Media Type"


# R7 - a whitelisted non-raster type is stored raw
def test_post_files_text_passthrough(http_client, test_session, s3_mock):
    response = upload(
        http_client,
        test_session,
        content=TEXT_BYTES,
        name="note.txt",
        content_type="text/plain",
    )

    assert response.status_code == 201

    body = response.json()
    key = f"files/{body['hash']}"
    assert s3_mock.get(key) == TEXT_BYTES
    assert s3_mock.get_content_type(key) == "text/plain"

    assert_file_body(
        body,
        name="note.txt",
        size=len(TEXT_BYTES),
        content_type="text/plain",
        hash_value=body["hash"],
    )


# R7 - a supported raster type is re-encoded to webp
def test_post_files_png_recode(http_client, test_session, s3_mock):
    response = upload(
        http_client, test_session, content=PNG_BYTES, name="img.png", content_type="image/png"
    )

    assert response.status_code == 201

    body = response.json()
    key = f"files/{body['hash']}"
    stored = s3_mock.get(key)
    assert stored[:4] == b"RIFF"
    assert stored[8:12] == b"WEBP"
    assert s3_mock.get_content_type(key) == "image/webp"

    # R8 - the hash is over the stored (re-encoded) bytes
    assert body["hash"] == hashlib.sha256(stored).hexdigest()

    assert_file_body(
        body,
        name="img.png",
        size=len(stored),
        content_type="image/webp",
        hash_value=body["hash"],
    )


# R7 - re-encoding drops PNG container metadata (tEXt)
def test_post_files_png_metadata_scrubbed(http_client, test_session, s3_mock):
    payload = png.make_png_with_text(keyword=b"Comment", text=b"distrans-secret")

    response = upload(
        http_client, test_session, content=payload, name="img.png", content_type="image/png"
    )

    assert response.status_code == 201

    stored = s3_mock.get(f"files/{response.json()['hash']}")
    assert stored is not None
    assert b"tEXt" not in stored
    assert b"zTXt" not in stored
    assert b"iTXt" not in stored
    assert b"distrans-secret" not in stored


# R7 - re-encoding is the metadata scrubber: no container metadata survives for
# any supported format. This is a regression guard: decoding must forward only
# pixel frames, so a future change that copies the source container would leak
# EXIF/XMP/ICCP, PNG text chunks or GIF extensions.
_PNG_METADATA = png.make_png_with_all_text()
_WEBP_METADATA = webp.make_webp_with_metadata()
_ANIMATED_WEBP_METADATA = webp.make_animated_webp_with_metadata()
_GIF_METADATA = gif.make_gif_with_metadata()
_ANIMATED_GIF_METADATA = gif.make_animated_gif_with_metadata()


@pytest.mark.parametrize(
    "content,content_type,name",
    [
        (_PNG_METADATA, "image/png", "meta.png"),
        (_WEBP_METADATA, "image/webp", "meta.webp"),
        (_GIF_METADATA, "image/gif", "meta.gif"),
        (_ANIMATED_GIF_METADATA, "image/gif", "meta_anim.gif"),
    ],
    ids=["png", "webp", "gif", "animated-gif"],
)
def test_post_files_metadata_scrubbed(
    http_client, test_session, s3_mock, content, content_type, name
):
    response = upload(
        http_client, test_session, content=content, name=name, content_type=content_type
    )

    assert response.status_code == 201, response.content

    stored = s3_mock.get(f"files/{response.json()['hash']}")
    assert stored is not None

    # The stored object is always a WebP produced by our encoder.
    assert stored[:4] == b"RIFF"
    assert stored[8:12] == b"WEBP"

    # No metadata sentinel, and none of the metadata containers.
    assert png.METADATA_SENTINEL not in stored
    assert webp.METADATA_SENTINEL not in stored
    assert gif.METADATA_SENTINEL not in stored

    for fourcc in (b"EXIF", b"XMP ", b"ICCP", b"tEXt", b"zTXt", b"iTXt", b"eXIf"):
        assert fourcc not in stored, f"{fourcc!r} survived the re-encode"

    # Only frame/canvas chunks remain.
    assert set(webp.chunk_fourccs(stored)) <= {b"VP8X", b"VP8L", b"VP8 ", b"ALPH", b"ANIM", b"ANMF"}


# R7 - the same scrub applies to the animated-webp code path (libwebp decoder)
def test_post_files_animated_webp_metadata_scrubbed(http_client, test_session, s3_mock):
    response = upload(
        http_client,
        test_session,
        content=_ANIMATED_WEBP_METADATA,
        name="meta_anim.webp",
        content_type="image/webp",
    )

    assert response.status_code == 201

    stored = s3_mock.get(f"files/{response.json()['hash']}")
    assert webp.METADATA_SENTINEL not in stored
    assert b"EXIF" not in stored
    assert b"XMP " not in stored
    assert b"ICCP" not in stored
    # stays animated
    assert stored[12:16] == b"VP8X"
    assert stored[20] & 0x02


# R7 - an animated GIF is re-encoded to an animated webp
def test_post_files_gif_recode(http_client, test_session, s3_mock):
    response = upload(
        http_client, test_session, content=GIF_BYTES, name="anim.gif", content_type="image/gif"
    )

    assert response.status_code == 201

    stored = s3_mock.get(f"files/{response.json()['hash']}")
    assert stored[:4] == b"RIFF"
    assert stored[8:12] == b"WEBP"
    # VP8X extended header with the animation flag set (0x02)
    assert stored[12:16] == b"VP8X"
    assert stored[20] & 0x02


# R7 - a declared-supported type with an undecodable body is 400
def test_post_files_bad_raster(http_client, test_session):
    response = upload(
        http_client,
        test_session,
        content=b"not really a png",
        name="img.png",
        content_type="image/png",
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Bad file"


# R7 - a supported raster over media.files.max_input_bytes is 413
def test_post_files_raster_too_large(http_client, test_session):
    # files.max_size == media.files.max_input_bytes in the test config, so the
    # outer barrier (files.max_size) is the one that fires; keep the payload
    # decodable-looking anyway.
    response = upload(
        http_client,
        test_session,
        content=PNG_BYTES + b"\x00" * (MAX_FILES_INPUT + 1),
        name="img.png",
        content_type="image/png",
    )

    assert response.status_code == 413


# R5 - body at most files.max_size
def test_post_files_too_large(http_client, test_session):
    response = upload(
        http_client,
        test_session,
        content=b"x" * (MAX_SIZE + 1),
        content_type="image/webp",
    )

    assert response.status_code == 413
    assert response.json()["message"] == "File is too large"


# R6 - "name" is required and must be valid
def test_post_files_missing_name(http_client, test_session):
    response = upload(http_client, test_session, params={})

    assert response.status_code == 400
    assert response.json()["message"] == "Missing 'name' parameter"


def test_post_files_empty_name(http_client, test_session):
    response = upload(http_client, test_session, params={"name": ""})

    assert response.status_code == 400
    assert response.json()["message"] == "Bad 'name' parameter"


def test_post_files_forbidden_name(http_client, test_session):
    # zero-width space + bidi override are forbidden in a name
    response = upload(http_client, test_session, params={"name": "a\u200Bb"})

    assert response.status_code == 400
    assert response.json()["message"] == "Bad 'name' parameter"


def test_post_files_name_too_long(http_client, test_session):
    max_codepoints = CONFIG["api"]["files"]["max_name_codepoints"]

    response = upload(
        http_client, test_session, params={"name": "a" * (max_codepoints + 1)}
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Bad 'name' parameter"


def test_post_files_unknown_parameter(http_client, test_session):
    response = upload(
        http_client, test_session, params={"name": "file.webp", "foo": "bar"}
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Unknown parameter"


# The removed per-file endpoints must not resolve any more.
def test_get_file_endpoint_removed(http_client, test_session):
    body = upload(http_client, test_session).json()
    headers = auth_headers(test_session)

    response = http_client.get(
        f"/api/files/{body['id']}", params={"hash": body["hash"]}, headers=headers
    )

    assert response.status_code == 404


def test_get_file_content_endpoint_removed(http_client, test_session):
    body = upload(http_client, test_session).json()

    response = http_client.get(
        f"/api/files/{body['id']}/content",
        params={"hash": body["hash"]},
        follow_redirects=False,
    )

    assert response.status_code == 404


# R7 - a JPEG is re-encoded to WebP, and its EXIF orientation is honored.
def test_post_files_jpeg_recode(http_client, test_session, s3_mock):
    response = upload(
        http_client,
        test_session,
        content=jpg.make_jpeg(16, 8),
        name="photo.jpg",
        content_type="image/jpeg",
    )

    assert response.status_code == 201
    body = response.json()
    assert body["content_type"] == "image/webp"

    stored = s3_mock.get(f"files/{body['hash']}")
    assert stored[:4] == b"RIFF" and stored[8:12] == b"WEBP"
    assert webp.read_dimensions(stored) == (16, 8)
    assert s3_mock.get_content_type(f"files/{body['hash']}") == "image/webp"


# R7 - the non-standard image/jpg alias is accepted and re-encoded too.
def test_post_files_jpg_alias_recode(http_client, test_session, s3_mock):
    response = upload(
        http_client,
        test_session,
        content=jpg.make_jpeg(16, 8),
        name="photo.jpg",
        content_type="image/jpg",
    )

    assert response.status_code == 201
    assert response.json()["content_type"] == "image/webp"


# R7 - a still JPEG with a 90-degree EXIF orientation is stored rotated
# (dimensions swapped), not sideways.
def test_post_files_jpeg_orientation_swaps_dimensions(http_client, test_session, s3_mock):
    response = upload(
        http_client,
        test_session,
        content=jpg.make_jpeg(16, 8, orientation=6),
        name="portrait.jpg",
        content_type="image/jpeg",
    )

    assert response.status_code == 201

    stored = s3_mock.get(f"files/{response.json()['hash']}")
    assert webp.read_dimensions(stored) == (8, 16)


# R7 - an EXIF orientation of 1 is identity: no rotation.
def test_post_files_jpeg_orientation_identity(http_client, test_session, s3_mock):
    response = upload(
        http_client,
        test_session,
        content=jpg.make_jpeg(16, 8, orientation=1),
        name="landscape.jpg",
        content_type="image/jpeg",
    )

    assert response.status_code == 201

    stored = s3_mock.get(f"files/{response.json()['hash']}")
    assert webp.read_dimensions(stored) == (16, 8)


# R4/R7 - text/* in the whitelist admits arbitrary text subtypes, stored raw.
def test_post_files_text_wildcard_passthrough(http_client, test_session, s3_mock):
    response = upload(
        http_client,
        test_session,
        content=b"# heading\n\nbody\n",
        name="readme.md",
        content_type="text/markdown",
    )

    assert response.status_code == 201
    body = response.json()
    assert body["content_type"] == "text/markdown"

    stored = s3_mock.get(f"files/{body['hash']}")
    assert stored == b"# heading\n\nbody\n"
    assert s3_mock.get_content_type(f"files/{body['hash']}") == "text/markdown"


# Object headers: every object is cacheable and an attachment carrying the
# original name as `filename`/`filename*`, so a direct navigation saves the file
# under its name (like a chat attachment).
def test_post_files_object_headers(http_client, test_session, s3_mock):
    media = upload(
        http_client, test_session, content=PNG_BYTES, name="img.png", content_type="image/png"
    ).json()

    media_key = f"files/{media['hash']}"
    assert (
        s3_mock.get_cache_control(media_key)
        == "public, max-age=31536000, immutable"
    )
    assert (
        s3_mock.get_content_disposition(media_key)
        == "attachment; filename=\"img.png\"; filename*=UTF-8''img.png"
    )

    text = upload(
        http_client,
        test_session,
        content=b"plain",
        name="note.txt",
        content_type="text/plain",
    ).json()

    text_key = f"files/{text['hash']}"
    assert (
        s3_mock.get_cache_control(text_key)
        == "public, max-age=31536000, immutable"
    )
    assert (
        s3_mock.get_content_disposition(text_key)
        == "attachment; filename=\"note.txt\"; filename*=UTF-8''note.txt"
    )


# A non-ASCII name is ASCII-fallbacked in `filename` and RFC 5987 percent-encoded
# in `filename*`, so a download saves under the original Cyrillic name.
def test_post_files_object_disposition_non_ascii(http_client, test_session, s3_mock):
    response = upload(
        http_client,
        test_session,
        content=b"plain",
        name="отчёт.txt",
        content_type="text/plain",
    )

    assert response.status_code == 201

    key = f"files/{response.json()['hash']}"
    assert (
        s3_mock.get_content_disposition(key)
        == "attachment; filename=\"_____.txt\"; "
        "filename*=UTF-8''%D0%BE%D1%82%D1%87%D1%91%D1%82.txt"
    )


# A name with quotes and a slash is sanitized in the fallback and
# percent-encoded in `filename*`, so the header cannot be broken.
def test_post_files_object_disposition_sanitized(http_client, test_session, s3_mock):
    response = upload(
        http_client,
        test_session,
        content=b"plain",
        name='a"b/c.txt',
        content_type="text/plain",
    )

    assert response.status_code == 201

    key = f"files/{response.json()['hash']}"
    assert (
        s3_mock.get_content_disposition(key)
        == "attachment; filename=\"a_b_c.txt\"; filename*=UTF-8''a%22b%2Fc.txt"
    )


# A name with a line break is rejected before upload, so it can never reach the
# Content-Disposition header.
def test_post_files_name_with_newline_rejected(http_client, test_session):
    response = upload(http_client, test_session, params={"name": "a\nb.txt"})

    assert response.status_code == 400
    assert response.json()["message"] == "Bad 'name' parameter"


