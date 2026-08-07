# Tests for the guild avatar endpoints:
#   GET    /api/guilds/{guild_id}/avatar?hash={hash}
#   PUT    /api/guilds/{guild_id}/avatar
#   DELETE /api/guilds/{guild_id}/avatar
#
# Requirement numbering mirrors src/route/guilds/id/avatar.zig.
#
# GetTask:
#   R1 - "hash" must be present and match the stored hash; else 404 "Avatar not found"
#   R2 - only "hash" is accepted; anything else is 400 "Unknown parameter"
#
# PostTask:
#   R1 - user must be logged
#   R2 - non-empty body with an image/webp Content-Type; else 400 "Bad image"
#   R3 - the guild exists
#   R4 - guild_modify required
#   R5 - body at most media.max_avatar_input_bytes; else 413 "Image is too large"
#   R6 - valid static/animated WebP within media.max_avatar_dimensions and the
#        animation caps; else 400 "Bad image"
#   R7 - re-encode to webp (animations to animated webp), hash + store,
#        200 {"avatar_hash": ...}
#
# DeleteTask:
#   R1 - user must be logged
#   R2 - the guild exists
#   R3 - guild_modify required
#   R4 - cleared, idempotent, 204
#
# The test_guild fixture grants its admin a superuser role (all permission
# bits), so the admin token passes the guild_modify check. The success path of
# the permission gate is additionally pinned with a role that carries exactly
# GUILD_MODIFY (see tests/api/permissions.py).

import re
import sys
from pathlib import Path

import pytest

from conftest import seed_role, system_create_user, system_login

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from permissions import GUILD_MODIFY, MODIFY_CHANNELS

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "users"))

import gif
import jpg
import png
import webp

HASH_RE = re.compile(r"^[0-9a-f]{16}$")

AVATAR_WEBP = webp.make_webp()
AVATAR_PNG = png.make_png(4, 4)
AVATAR_GIF = gif.make_animated_gif()
LARGE_WEBP = webp.make_webp_with_padding()
ANIMATED_WEBP = webp.make_animated_webp(frames=3)

UNKNOWN_GUILD_ID = "999999999999"


def auth_headers(token):
    return {"Authorization": f"Bearer {token}"}


def put_avatar(http_client, token, guild_id, content, content_type="image/webp"):
    headers = auth_headers(token)

    if content is not None:
        headers["Content-Type"] = content_type

    return http_client.put(
        f"/api/guilds/{guild_id}/avatar", content=content, headers=headers
    )


def get_avatar(http_client, guild_id, hash_value, token=None):
    params = {} if hash_value is None else {"hash": hash_value}
    headers = auth_headers(token) if token else {}

    return http_client.get(
        f"/api/guilds/{guild_id}/avatar", params=params, headers=headers
    )


def delete_avatar(http_client, token, guild_id):
    return http_client.delete(
        f"/api/guilds/{guild_id}/avatar", headers=auth_headers(token)
    )


def get_guilds(http_client, token):
    return http_client.get("/api/guilds", headers=auth_headers(token))


def is_webp(body):
    return body[:4] == b"RIFF" and body[8:12] == b"WEBP"


def is_animated_webp(body):
    return is_webp(body) and body[12:16] == b"VP8X" and bool(body[20] & 0x02)


def _grant_role(db_conn, guild_id, user_id, role_id, permissions, position=1):
    seed_role(db_conn, guild_id, role_id, f"role-{role_id}", position, permissions)

    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.member_roles (guild_id, user_id, role_id)"
            " VALUES (%s, %s, %s)",
            (guild_id, user_id, role_id),
        )


def _bit_user(http_client, db_conn, test_guild, username, permissions, role_id):
    user = system_create_user(http_client, username=username)
    token, _ = system_login(http_client, username)
    _grant_role(db_conn, int(test_guild.id), int(user["id"]), role_id, permissions)

    return user, token


# GetTask R1 - the public GET has no authentication requirement
def test_get_avatar_public_no_auth(http_client, test_guild):
    avatar_hash = put_avatar(
        http_client, test_guild.admin_token, test_guild.id, AVATAR_WEBP
    ).json()["avatar_hash"]

    response = get_avatar(http_client, test_guild.id, avatar_hash, token=None)

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("image/webp")
    assert is_webp(response.content)


# GetTask R1
def test_get_avatar_streams_webp(http_client, test_guild):
    avatar_hash = put_avatar(
        http_client, test_guild.admin_token, test_guild.id, AVATAR_WEBP
    ).json()["avatar_hash"]

    response = get_avatar(http_client, test_guild.id, avatar_hash)

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("image/webp")
    assert is_webp(response.content)

    again = get_avatar(http_client, test_guild.id, avatar_hash)
    assert again.status_code == 200
    assert again.content == response.content


# GetTask R1
def test_get_avatar_wrong_hash_not_found(http_client, test_guild):
    put_avatar(http_client, test_guild.admin_token, test_guild.id, AVATAR_WEBP)

    response = get_avatar(http_client, test_guild.id, "0" * 16)

    assert response.status_code == 404
    assert response.json()["message"] == "Avatar not found"


# GetTask R1
def test_get_avatar_missing_hash_not_found(http_client, test_guild):
    put_avatar(http_client, test_guild.admin_token, test_guild.id, AVATAR_WEBP)

    response = get_avatar(http_client, test_guild.id, None)

    assert response.status_code == 404


# GetTask R1
def test_get_avatar_no_avatar_not_found(http_client, test_guild):
    response = get_avatar(http_client, test_guild.id, "0" * 16)

    assert response.status_code == 404


# GetTask R1
def test_get_avatar_unknown_guild_not_found(http_client, test_guild):
    avatar_hash = put_avatar(
        http_client, test_guild.admin_token, test_guild.id, AVATAR_WEBP
    ).json()["avatar_hash"]

    response = get_avatar(http_client, UNKNOWN_GUILD_ID, avatar_hash)

    assert response.status_code == 404


# GetTask R2
def test_get_avatar_unknown_parameter_bad_request(http_client, test_guild):
    response = http_client.get(
        f"/api/guilds/{test_guild.id}/avatar", params={"hash": "0" * 16, "x": "1"}
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Unknown parameter"


# PutTask R1
def test_put_avatar_unauthorized(http_client, test_guild):
    response = http_client.put(
        f"/api/guilds/{test_guild.id}/avatar",
        content=AVATAR_WEBP,
        headers={"Content-Type": "image/webp"},
    )

    assert response.status_code == 401


# DeleteTask R1
def test_delete_avatar_unauthorized(http_client, test_guild):
    response = http_client.delete(f"/api/guilds/{test_guild.id}/avatar")

    assert response.status_code == 401


# PostTask R2 - an unsupported Content-Type is 415
def test_put_avatar_bad_content_type(http_client, test_guild):
    response = put_avatar(
        http_client, test_guild.admin_token, test_guild.id, AVATAR_WEBP,
        content_type="text/plain",
    )

    assert response.status_code == 415
    assert response.json()["message"] == "Unsupported Media Type"


# PostTask R2 - only the supported raster types are accepted
@pytest.mark.parametrize("content_type", ["image/apng", "text/plain", "application/json"])
def test_put_avatar_unsupported_content_type(http_client, test_guild, content_type):
    response = put_avatar(
        http_client, test_guild.admin_token, test_guild.id, AVATAR_WEBP,
        content_type=content_type,
    )

    assert response.status_code == 415
    assert response.json()["message"] == "Unsupported Media Type"


# PostTask R6/R7 - PNG and GIF are accepted and re-encoded
def test_put_avatar_png(http_client, test_guild):
    response = put_avatar(
        http_client, test_guild.admin_token, test_guild.id, AVATAR_PNG,
        content_type="image/png",
    )

    assert response.status_code == 200
    assert HASH_RE.match(response.json()["avatar_hash"])

    image = get_avatar(
        http_client, test_guild.id, response.json()["avatar_hash"]
    )
    assert is_webp(image.content)


def test_put_avatar_gif(http_client, test_guild):
    response = put_avatar(
        http_client, test_guild.admin_token, test_guild.id, AVATAR_GIF,
        content_type="image/gif",
    )

    assert response.status_code == 200

    image = get_avatar(
        http_client, test_guild.id, response.json()["avatar_hash"]
    )
    assert is_animated_webp(image.content)


# PostTask R6/R7 - JPEG is accepted and re-encoded to WebP
def test_put_avatar_jpeg(http_client, test_guild):
    response = put_avatar(
        http_client, test_guild.admin_token, test_guild.id, jpg.make_jpeg(16, 8),
        content_type="image/jpeg",
    )

    assert response.status_code == 200
    assert HASH_RE.match(response.json()["avatar_hash"])

    image = get_avatar(
        http_client, test_guild.id, response.json()["avatar_hash"]
    )
    assert is_webp(image.content)


# PostTask R2 - an empty POST is a bad request, not a delete
def test_post_empty_body_bad_request(http_client, test_guild):
    avatar_hash = put_avatar(
        http_client, test_guild.admin_token, test_guild.id, AVATAR_WEBP
    ).json()["avatar_hash"]

    response = put_avatar(
        http_client, test_guild.admin_token, test_guild.id, None
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Bad image"

    assert get_avatar(http_client, test_guild.id, avatar_hash).status_code == 200


# PostTask R3
def test_put_avatar_missing_guild_not_found(http_client, test_guild):
    response = put_avatar(
        http_client, test_guild.admin_token, UNKNOWN_GUILD_ID, AVATAR_WEBP
    )

    assert response.status_code == 404
    assert response.json()["message"] == "Guild not found"


# PostTask R4 - a logged-in user without guild_modify
def test_put_avatar_without_guild_modify_forbidden(
    http_client, test_session, test_guild
):
    response = put_avatar(
        http_client, test_session.access_token, test_guild.id, AVATAR_WEBP
    )

    assert response.status_code == 403
    assert response.json()["message"] == "Missing permissions"


# PostTask R4 - a role with a different bit must not grant access
def test_put_avatar_wrong_permission_bit_forbidden(
    http_client, db_conn, test_guild
):
    _, token = _bit_user(
        http_client, db_conn, test_guild, "avatar_wrong_bit", MODIFY_CHANNELS, 991000001
    )

    response = put_avatar(http_client, token, test_guild.id, AVATAR_WEBP)

    assert response.status_code == 403


# PostTask R4 - the success path pins the exact GUILD_MODIFY bit numbering
def test_put_avatar_exact_guild_modify_bit(http_client, db_conn, test_guild):
    _, token = _bit_user(
        http_client, db_conn, test_guild, "avatar_guild_modify", GUILD_MODIFY, 991000002
    )

    response = put_avatar(http_client, token, test_guild.id, AVATAR_WEBP)

    assert response.status_code == 200
    assert HASH_RE.fullmatch(response.json()["avatar_hash"])


# PostTask R5
def test_put_avatar_too_large(http_client, test_guild):
    response = put_avatar(
        http_client, test_guild.admin_token, test_guild.id, webp.oversized_body()
    )

    assert response.status_code == 413
    assert response.json()["message"] == "Image is too large"


# PostTask R7
def test_put_avatar_sets_and_exposes_hash(http_client, test_guild):
    response = put_avatar(
        http_client, test_guild.admin_token, test_guild.id, AVATAR_WEBP
    )

    assert response.status_code == 200

    avatar_hash = response.json()["avatar_hash"]
    assert HASH_RE.fullmatch(avatar_hash)

    guilds = get_guilds(http_client, test_guild.admin_token).json()
    guild = next(g for g in guilds if g["id"] == test_guild.id)
    assert guild["avatar_hash"] == avatar_hash
    assert "icon_url" not in guild


# PostTask R7 - deterministic hashing of the encoded bytes
def test_put_avatar_same_image_same_hash(http_client, test_guild):
    first = put_avatar(
        http_client, test_guild.admin_token, test_guild.id, AVATAR_WEBP
    ).json()["avatar_hash"]
    second = put_avatar(
        http_client, test_guild.admin_token, test_guild.id, AVATAR_WEBP
    ).json()["avatar_hash"]

    assert first == second


# PostTask R6 / R7 - an animated WebP is stored as an animated webp
def test_post_animated_webp(http_client, test_guild):
    response = put_avatar(
        http_client, test_guild.admin_token, test_guild.id, ANIMATED_WEBP
    )

    assert response.status_code == 200

    avatar_hash = response.json()["avatar_hash"]
    body = get_avatar(http_client, test_guild.id, avatar_hash).content
    assert is_animated_webp(body)


# PostTask R6 / R7 - an extended still WebP (VP8X + ALPH) is treated as a still
def test_post_extended_still_webp(http_client, test_guild):
    response = put_avatar(
        http_client, test_guild.admin_token, test_guild.id, webp.EXTENDED_WEBP
    )

    assert response.status_code == 200

    avatar_hash = response.json()["avatar_hash"]
    body = get_avatar(http_client, test_guild.id, avatar_hash).content
    assert is_webp(body)
    assert not is_animated_webp(body)


# PostTask R6 - the animation caps
def test_post_animated_webp_too_many_frames(http_client, test_guild):
    response = put_avatar(
        http_client, test_guild.admin_token, test_guild.id,
        webp.make_animated_webp_many_frames(),
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Bad image"


def test_post_animated_webp_too_long(http_client, test_guild):
    response = put_avatar(
        http_client, test_guild.admin_token, test_guild.id,
        webp.make_animated_webp_long(),
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Bad image"


# PostTask R6 - many short frames must stay under the duration cap (guards the
# per-frame minimum delay wiring).
def test_post_animated_webp_short_frames(http_client, test_guild):
    response = put_avatar(
        http_client, test_guild.admin_token, test_guild.id,
        webp.make_animated_webp_lots_of_short_frames(),
    )

    assert response.status_code == 200, response.content
    assert HASH_RE.fullmatch(response.json()["avatar_hash"])


# PostTask R6
@pytest.mark.parametrize("name", sorted(webp.MALFORMED))
def test_post_malformed_webp(http_client, test_guild, name):
    response = put_avatar(
        http_client, test_guild.admin_token, test_guild.id, webp.MALFORMED[name]()
    )

    assert response.status_code == 400, f"{name}: {response.content!r}"
    assert response.json()["message"] == "Bad image"


# PostTask R6 - the server stays usable after each malformed upload
@pytest.mark.parametrize("name", sorted(webp.MALFORMED))
def test_server_survives_malformed_webp(http_client, test_guild, name):
    put_avatar(
        http_client, test_guild.admin_token, test_guild.id, webp.MALFORMED[name]()
    )

    assert http_client.get("/api/limits").status_code == 200

    response = put_avatar(
        http_client, test_guild.admin_token, test_guild.id, AVATAR_WEBP
    )
    assert response.status_code == 200


# PostTask R6 - an upload larger than the socket buffer must be read across many polls
def test_post_large_webp(http_client, test_guild):
    response = put_avatar(
        http_client, test_guild.admin_token, test_guild.id, LARGE_WEBP
    )

    assert response.status_code == 200
    assert HASH_RE.fullmatch(response.json()["avatar_hash"])


# DeleteTask R2
def test_delete_avatar_missing_guild_not_found(http_client, test_guild):
    response = delete_avatar(http_client, test_guild.admin_token, UNKNOWN_GUILD_ID)

    assert response.status_code == 404
    assert response.json()["message"] == "Guild not found"


# DeleteTask R3
def test_delete_avatar_without_guild_modify_forbidden(
    http_client, test_session, test_guild
):
    response = delete_avatar(http_client, test_session.access_token, test_guild.id)

    assert response.status_code == 403
    assert response.json()["message"] == "Missing permissions"


# DeleteTask R3 - the success path pins the exact GUILD_MODIFY bit numbering
def test_delete_avatar_exact_guild_modify_bit(http_client, db_conn, test_guild):
    _, token = _bit_user(
        http_client, db_conn, test_guild, "avatar_del_modify", GUILD_MODIFY, 991000003
    )

    response = delete_avatar(http_client, token, test_guild.id)

    assert response.status_code == 204


# DeleteTask R4
def test_delete_avatar_clears(http_client, test_guild):
    avatar_hash = put_avatar(
        http_client, test_guild.admin_token, test_guild.id, AVATAR_WEBP
    ).json()["avatar_hash"]

    response = delete_avatar(http_client, test_guild.admin_token, test_guild.id)

    assert response.status_code == 204
    assert response.content == b""

    guilds = get_guilds(http_client, test_guild.admin_token).json()
    guild = next(g for g in guilds if g["id"] == test_guild.id)
    assert guild["avatar_hash"] is None

    assert get_avatar(http_client, test_guild.id, avatar_hash).status_code == 404


# DeleteTask R4 - deleting is idempotent
def test_delete_avatar_idempotent(http_client, test_guild):
    put_avatar(http_client, test_guild.admin_token, test_guild.id, AVATAR_WEBP)

    assert delete_avatar(http_client, test_guild.admin_token, test_guild.id).status_code == 204
    assert delete_avatar(http_client, test_guild.admin_token, test_guild.id).status_code == 204


# DeleteTask R4 - deleting without an avatar succeeds
def test_delete_avatar_without_avatar(http_client, test_guild):
    response = delete_avatar(http_client, test_guild.admin_token, test_guild.id)

    assert response.status_code == 204
