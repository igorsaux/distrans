# Tests for the current user's avatar endpoints:
#   PUT    /api/users/@me/avatar
#   DELETE /api/users/@me/avatar
#   GET    /api/users/{user_id}/avatar?hash={hash}
#
# Requirement numbering mirrors src/route/users/me/avatar.zig.
#
# PostTask:
#   R1 - user must be logged
#   R2 - non-empty body with image/webp|image/gif|image/png; else 400 "Bad image"
#        (empty) or 415 "Unsupported Media Type"
#   R3 - body at most media.avatar.max_input_bytes; else 413 "Image is too large"
#   R4 - valid WebP/GIF/PNG within media.avatar.max_dimensions and the
#        animation caps; else 400 "Bad image"
#   R5 - re-encode to webp (animations to animated webp), hash + store,
#        200 {"avatar_hash": ...}
#
# DeleteTask:
#   R1 - user must be logged
#   R2 - cleared, idempotent, 204

import re

import pytest

import gif
import jpg
import png
import webp

HASH_RE = re.compile(r"^[0-9a-f]{16}$")

AVATAR_WEBP = webp.make_webp()
LARGE_WEBP = webp.make_webp_with_padding()
ANIMATED_WEBP = webp.make_animated_webp(frames=3)
AVATAR_PNG = png.make_png(4, 4)
AVATAR_GIF = gif.make_animated_gif()
AVATAR_JPEG = jpg.make_jpeg(16, 8)


def auth_headers(session):
    return {"Authorization": f"Bearer {session.access_token}"}


def put_avatar(http_client, session, content, content_type="image/webp"):
    headers = auth_headers(session)

    if content is not None:
        headers["Content-Type"] = content_type

    return http_client.put("/api/users/@me/avatar", content=content, headers=headers)


def get_me(http_client, session):
    return http_client.get("/api/users/@me", headers=auth_headers(session))


def get_avatar(http_client, session, user_id, hash_value, auth=True):
    params = {} if hash_value is None else {"hash": hash_value}
    headers = auth_headers(session) if auth else {}

    return http_client.get(
        f"/api/users/{user_id}/avatar", params=params, headers=headers
    )


def delete_avatar(http_client, session):
    return http_client.delete("/api/users/@me/avatar", headers=auth_headers(session))


def is_webp(body):
    return body[:4] == b"RIFF" and body[8:12] == b"WEBP"


def is_animated_webp(body):
    # The VP8X chunk's feature flags byte has ANIMATION_FLAG = 0x02.
    return is_webp(body) and body[12:16] == b"VP8X" and bool(body[20] & 0x02)


# R1 - user must be logged
def test_put_avatar_unauthorized(http_client):
    response = http_client.put(
        "/api/users/@me/avatar", content=AVATAR_WEBP, headers={"Content-Type": "image/webp"}
    )

    assert response.status_code == 401


# R1
def test_delete_avatar_unauthorized(http_client):
    response = http_client.delete("/api/users/@me/avatar")

    assert response.status_code == 401


# GET /users/{user_id}/avatar is public: no authentication required
def test_get_avatar_public_no_auth(http_client, test_session, test_user):
    avatar_hash = put_avatar(http_client, test_session, AVATAR_WEBP).json()["avatar_hash"]

    response = get_avatar(http_client, None, test_user.id, avatar_hash, auth=False)

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("image/webp")
    assert is_webp(response.content)


# R1 - the public GET still rejects a wrong hash
def test_get_avatar_public_wrong_hash_not_found(http_client, test_session, test_user):
    put_avatar(http_client, test_session, AVATAR_WEBP)

    response = get_avatar(http_client, None, test_user.id, "0" * 16, auth=False)

    assert response.status_code == 404
    assert response.json()["message"] == "Avatar not found"


# R2 - an unsupported Content-Type is 415
def test_put_avatar_bad_content_type(http_client, test_session):
    response = put_avatar(http_client, test_session, AVATAR_WEBP, content_type="text/plain")

    assert response.status_code == 415
    assert response.json()["message"] == "Unsupported Media Type"


# R2 - only the supported raster types are accepted
@pytest.mark.parametrize("content_type", ["image/apng", "text/plain", "application/json"])
def test_put_avatar_unsupported_content_type(http_client, test_session, content_type):
    response = put_avatar(http_client, test_session, AVATAR_WEBP, content_type=content_type)

    assert response.status_code == 415
    assert response.json()["message"] == "Unsupported Media Type"


# R4/R5 - PNG and GIF are accepted and re-encoded
def test_put_avatar_png(http_client, test_session, test_user):
    response = put_avatar(http_client, test_session, AVATAR_PNG, content_type="image/png")

    assert response.status_code == 200
    assert HASH_RE.match(response.json()["avatar_hash"])

    image = get_avatar(
        http_client, test_session, test_user.id, response.json()["avatar_hash"]
    )
    assert image.status_code == 200
    assert image.content[:4] == b"RIFF"
    assert image.content[8:12] == b"WEBP"


def test_put_avatar_gif(http_client, test_session, test_user):
    response = put_avatar(http_client, test_session, AVATAR_GIF, content_type="image/gif")

    assert response.status_code == 200
    assert HASH_RE.match(response.json()["avatar_hash"])

    image = get_avatar(
        http_client, test_session, test_user.id, response.json()["avatar_hash"]
    )
    assert image.content[:4] == b"RIFF"
    assert image.content[8:12] == b"WEBP"
    assert image.content[12:16] == b"VP8X"
    assert image.content[20] & 0x02


# R4/R5 - JPEG (and the image/jpg alias) is accepted and re-encoded to WebP.
def test_put_avatar_jpeg(http_client, test_session, test_user):
    response = put_avatar(
        http_client, test_session, AVATAR_JPEG, content_type="image/jpeg"
    )

    assert response.status_code == 200
    assert HASH_RE.match(response.json()["avatar_hash"])

    image = get_avatar(
        http_client, test_session, test_user.id, response.json()["avatar_hash"]
    )
    assert image.status_code == 200
    assert image.content[:4] == b"RIFF"
    assert image.content[8:12] == b"WEBP"


def test_put_avatar_jpg_alias(http_client, test_session):
    response = put_avatar(
        http_client, test_session, AVATAR_JPEG, content_type="image/jpg"
    )

    assert response.status_code == 200
    assert HASH_RE.match(response.json()["avatar_hash"])


# R2 - an empty POST is a bad request, not a delete
def test_post_empty_body_bad_request(http_client, test_session, test_user):
    avatar_hash = put_avatar(http_client, test_session, AVATAR_WEBP).json()["avatar_hash"]

    response = put_avatar(http_client, test_session, None)

    assert response.status_code == 400
    assert response.json()["message"] == "Bad image"

    me = get_me(http_client, test_session).json()
    assert me["avatar_hash"] == avatar_hash

    response = get_avatar(http_client, test_session, test_user.id, avatar_hash)
    assert response.status_code == 200


# R3
def test_put_avatar_too_large(http_client, test_session):
    response = put_avatar(http_client, test_session, webp.oversized_body())

    assert response.status_code == 413
    assert response.json()["message"] == "Image is too large"


# R4
@pytest.mark.parametrize("name", sorted(webp.MALFORMED))
def test_post_malformed_webp(http_client, test_session, name):
    response = put_avatar(http_client, test_session, webp.MALFORMED[name]())

    assert response.status_code == 400, f"{name}: {response.content!r}"

    body = response.json()
    assert body["message"] == "Bad image"


# R4 - the server stays usable after each malformed upload
@pytest.mark.parametrize("name", sorted(webp.MALFORMED))
def test_server_survives_malformed_webp(http_client, test_session, name):
    put_avatar(http_client, test_session, webp.MALFORMED[name]())

    limits = http_client.get("/api/limits")
    assert limits.status_code == 200

    response = put_avatar(http_client, test_session, AVATAR_WEBP)
    assert response.status_code == 200


# R4 - a malformed PNG body is 400 even with a supported Content-Type
@pytest.mark.parametrize("name", sorted(png.MALFORMED))
def test_post_malformed_png(http_client, test_session, name):
    response = put_avatar(
        http_client, test_session, png.MALFORMED[name](), content_type="image/png"
    )

    assert response.status_code == 400, f"{name}: {response.content!r}"
    assert response.json()["message"] == "Bad image"


# R4 - a malformed GIF body is 400 even with a supported Content-Type
@pytest.mark.parametrize("name", sorted(gif.MALFORMED))
def test_post_malformed_gif(http_client, test_session, name):
    response = put_avatar(
        http_client, test_session, gif.MALFORMED[name](), content_type="image/gif"
    )

    assert response.status_code == 400, f"{name}: {response.content!r}"
    assert response.json()["message"] == "Bad image"


# R4 - an APNG is decoded by the PNG path to its first frame (still webp)
def test_post_apng_first_frame(http_client, test_session, test_user):
    response = put_avatar(
        http_client, test_session, png.make_apng(frames=3), content_type="image/png"
    )

    assert response.status_code == 200

    image = get_avatar(
        http_client, test_session, test_user.id, response.json()["avatar_hash"]
    )
    assert is_webp(image.content)
    assert not is_animated_webp(image.content)


# R4 - the animation frame cap
def test_post_animated_webp_too_many_frames(http_client, test_session):
    response = put_avatar(http_client, test_session, webp.make_animated_webp_many_frames())

    assert response.status_code == 400
    assert response.json()["message"] == "Bad image"


# R4 - the animation duration cap
def test_post_animated_webp_too_long(http_client, test_session):
    response = put_avatar(http_client, test_session, webp.make_animated_webp_long())

    assert response.status_code == 400
    assert response.json()["message"] == "Bad image"


# R4 - many short frames must stay under the duration cap. This only passes when
# the per-frame minimum delay is wired from min_* (a max_* value clamps every
# frame to 2 s and pushes 64 frames over the 10 s cap).
def test_post_animated_webp_short_frames(http_client, test_session):
    response = put_avatar(
        http_client, test_session, webp.make_animated_webp_lots_of_short_frames()
    )

    assert response.status_code == 200, response.content
    assert HASH_RE.fullmatch(response.json()["avatar_hash"])


# R5
def test_put_avatar_sets_and_exposes_hash(http_client, test_session, test_user):
    response = put_avatar(http_client, test_session, AVATAR_WEBP)

    assert response.status_code == 200

    avatar_hash = response.json()["avatar_hash"]
    assert HASH_RE.fullmatch(avatar_hash)

    me = get_me(http_client, test_session).json()
    assert me["avatar_hash"] == avatar_hash
    assert "avatar_url" not in me

    other = http_client.get(
        f"/api/users/{test_user.id}", headers=auth_headers(test_session)
    ).json()
    assert other["avatar_hash"] == avatar_hash


# R5 - deterministic hashing of the encoded bytes
def test_put_avatar_same_image_same_hash(http_client, test_session):
    first = put_avatar(http_client, test_session, AVATAR_WEBP).json()["avatar_hash"]
    second = put_avatar(http_client, test_session, AVATAR_WEBP).json()["avatar_hash"]

    assert first == second


# R5 - a still image is stored as a still webp
def test_get_avatar_streams_webp(http_client, test_session, test_user):
    avatar_hash = put_avatar(http_client, test_session, AVATAR_WEBP).json()["avatar_hash"]

    response = get_avatar(http_client, test_session, test_user.id, avatar_hash)

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("image/webp")
    assert is_webp(response.content)

    again = get_avatar(http_client, test_session, test_user.id, avatar_hash)
    assert again.status_code == 200
    assert again.content == response.content


# R4 / R5 - an animated WebP is accepted and stored as an animated webp
def test_post_animated_webp(http_client, test_session, test_user):
    response = put_avatar(http_client, test_session, ANIMATED_WEBP)

    assert response.status_code == 200

    avatar_hash = response.json()["avatar_hash"]
    assert HASH_RE.fullmatch(avatar_hash)

    body = get_avatar(http_client, test_session, test_user.id, avatar_hash).content
    assert is_animated_webp(body)


# R4 / R5 - deterministic animated output
def test_post_animated_webp_same_hash(http_client, test_session):
    first = put_avatar(http_client, test_session, ANIMATED_WEBP).json()["avatar_hash"]
    second = put_avatar(http_client, test_session, ANIMATED_WEBP).json()["avatar_hash"]

    assert first == second


# R4 / R5 - animations are normalized to loop forever
def test_post_animated_webp_forces_infinite_loop(http_client, test_session, test_user):
    payload = webp.make_animated_webp(frames=3, loop=5)

    assert webp.read_loop(payload) == 5

    avatar_hash = put_avatar(http_client, test_session, payload).json()["avatar_hash"]
    body = get_avatar(http_client, test_session, test_user.id, avatar_hash).content

    assert webp.read_loop(body) == 0


# R4 / R5 - an extended still WebP (VP8X + ALPH) is treated as a still
def test_post_extended_still_webp(http_client, test_session, test_user):
    response = put_avatar(http_client, test_session, webp.EXTENDED_WEBP)

    assert response.status_code == 200

    avatar_hash = response.json()["avatar_hash"]
    body = get_avatar(http_client, test_session, test_user.id, avatar_hash).content
    assert is_webp(body)
    assert not is_animated_webp(body)


# R1
def test_get_avatar_wrong_hash_not_found(http_client, test_session, test_user):
    put_avatar(http_client, test_session, AVATAR_WEBP)

    response = get_avatar(http_client, test_session, test_user.id, "0" * 16)

    assert response.status_code == 404
    assert response.json()["message"] == "Avatar not found"


# R1
def test_get_avatar_missing_hash_not_found(http_client, test_session, test_user):
    put_avatar(http_client, test_session, AVATAR_WEBP)

    response = get_avatar(http_client, test_session, test_user.id, None)

    assert response.status_code == 404


# R1
def test_get_avatar_no_avatar_not_found(http_client, test_session, test_user):
    response = get_avatar(http_client, test_session, test_user.id, "0" * 16)

    assert response.status_code == 404


# R1
def test_get_avatar_unknown_user_not_found(http_client, test_session, test_user):
    avatar_hash = put_avatar(http_client, test_session, AVATAR_WEBP).json()["avatar_hash"]

    response = get_avatar(http_client, test_session, 1, avatar_hash)

    assert response.status_code == 404


# R1
def test_get_avatar_hash_of_other_user_not_found(
    http_client, system_headers, test_session, test_user
):
    avatar_hash = put_avatar(http_client, test_session, AVATAR_WEBP).json()["avatar_hash"]

    other = http_client.post(
        "/api/system/users",
        json={"username": "other_avatar_user"},
        headers=system_headers,
    ).json()

    response = get_avatar(http_client, test_session, other["id"], avatar_hash)

    assert response.status_code == 404


# R2 - the dedicated deletion endpoint
def test_delete_avatar_clears(http_client, test_session, test_user):
    avatar_hash = put_avatar(http_client, test_session, AVATAR_WEBP).json()["avatar_hash"]

    response = delete_avatar(http_client, test_session)

    assert response.status_code == 204
    assert response.content == b""

    me = get_me(http_client, test_session).json()
    assert me["avatar_hash"] is None

    response = get_avatar(http_client, test_session, test_user.id, avatar_hash)
    assert response.status_code == 404


# R2 - deleting is idempotent
def test_delete_avatar_idempotent(http_client, test_session):
    put_avatar(http_client, test_session, AVATAR_WEBP)

    assert delete_avatar(http_client, test_session).status_code == 204
    assert delete_avatar(http_client, test_session).status_code == 204


# R2 - deleting without an avatar succeeds
def test_delete_avatar_without_avatar(http_client, test_session):
    response = delete_avatar(http_client, test_session)

    assert response.status_code == 204

    me = get_me(http_client, test_session).json()
    assert me["avatar_hash"] is None


# R4 - an upload larger than the socket buffer must be read across many polls
def test_post_large_webp(http_client, test_session):
    response = put_avatar(http_client, test_session, LARGE_WEBP)

    assert response.status_code == 200

    avatar_hash = response.json()["avatar_hash"]
    assert HASH_RE.fullmatch(avatar_hash)


# R1 - deleted users are rejected by the bearer middleware
def test_avatar_of_deleted_user(http_client, system_headers, test_session, test_user):
    response = http_client.delete(
        f"/api/system/users/{test_user.id}", headers=system_headers
    )
    assert response.status_code == 204

    response = put_avatar(http_client, test_session, AVATAR_WEBP)
    assert response.status_code == 401

    # the public GET returns 404 for a deleted user (no avatar to serve)
    response = get_avatar(http_client, test_session, test_user.id, "0" * 16)
    assert response.status_code == 404
