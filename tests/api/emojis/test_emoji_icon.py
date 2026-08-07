# Tests for the custom emoji icon endpoint:
#   GET /api/emojis/{emoji_id}/icon?hash={hash}
#   PUT /api/emojis/{emoji_id}/icon
#
# Requirement numbering mirrors src/route/emojis/id/icon.zig.
#
# GetTask:
#   R1 - "hash" must be present and match the stored icon hash; else 404 "Icon not found"
#   R2 - only "hash" is accepted; anything else is 400 "Unknown parameter"
#
# PutTask:
#   R1 - user must be logged (bearer)
#   R2 - non-empty body with an image/webp Content-Type and no query parameter;
#        else 400 "Bad image" / "Unknown parameter"
#   R3 - the emoji exists (404 "Emoji not found")
#   R4 - modify_emoji required (403 "Missing permissions")
#   R5 - valid static/animated WebP within the media.emoji caps; oversize is 413
#        "Image is too large", otherwise 400 "Bad image"
#   R6 - icon replaced, 200 {"icon_hash"}, dispatches emoji_updated

import sys
from pathlib import Path

from conftest import system_create_user, system_login

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "users"))

from permissions import CREATE_EMOJI, MODIFY_EMOJI  # noqa: E402

from emoji_helpers import (  # noqa: E402
    EMOJI_WEBP,
    HASH_RE,
    create_emoji_ok,
    get_icon,
    grant_role,
    is_webp,
    update_icon,
)

import gif  # noqa: E402
import jpg  # noqa: E402
import png  # noqa: E402
import webp  # noqa: E402

EMOJI_PNG = png.make_png(4, 4)
EMOJI_GIF = gif.make_animated_gif()

UNKNOWN_EMOJI_ID = "999999999999"


def bit_user(http_client, db_conn, test_guild, username, permissions, role_id):
    user = system_create_user(http_client, username=username)
    token, _ = system_login(http_client, username)
    grant_role(db_conn, int(test_guild.id), int(user["id"]), role_id, permissions)

    return token


# GetTask R1 - the public GET has no authentication requirement
def test_get_icon_public_no_auth(http_client, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "pub")

    response = get_icon(http_client, emoji["id"], emoji["icon_hash"], token=None)

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("image/webp")
    assert is_webp(response.content)


# GetTask R1 - the stored bytes round-trip unchanged
def test_get_icon_streams_webp(http_client, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "stream")

    response = get_icon(http_client, emoji["id"], emoji["icon_hash"])

    assert response.status_code == 200
    assert is_webp(response.content)

    again = get_icon(http_client, emoji["id"], emoji["icon_hash"])
    assert again.status_code == 200
    assert again.content == response.content


# GetTask R1
def test_get_icon_wrong_hash_not_found(http_client, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "wronghash")

    response = get_icon(http_client, emoji["id"], "0" * 16)

    assert response.status_code == 404
    assert response.json()["message"] == "Icon not found"


# GetTask R1
def test_get_icon_missing_hash_not_found(http_client, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "nohash")

    response = get_icon(http_client, emoji["id"], None)

    assert response.status_code == 404
    assert response.json()["message"] == "Icon not found"


# GetTask R1
def test_get_icon_unknown_emoji_not_found(http_client, test_guild):
    response = get_icon(http_client, UNKNOWN_EMOJI_ID, "0" * 16)

    assert response.status_code == 404


# GetTask R1 - the hash of a different emoji must not match
def test_get_icon_other_emoji_hash_not_found(http_client, test_guild):
    first = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "first")
    second = create_emoji_ok(
        http_client,
        test_guild.admin_token,
        test_guild.id,
        "second",
        content=webp.EXTENDED_WEBP,
    )

    assert second["icon_hash"] != first["icon_hash"]

    response = get_icon(http_client, first["id"], second["icon_hash"])

    assert response.status_code == 404


# GetTask R2
def test_get_icon_unknown_parameter(http_client, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "param")

    response = http_client.get(
        f"/api/emojis/{emoji['id']}/icon",
        params={"hash": emoji["icon_hash"], "x": "1"},
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Unknown parameter"


# PutTask R1
def test_put_icon_unauthorized(http_client, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "putauth")

    response = http_client.put(
        f"/api/emojis/{emoji['id']}/icon",
        content=EMOJI_WEBP,
        headers={"Content-Type": "image/webp"},
    )

    assert response.status_code == 401


# PutTask R2 - an unsupported Content-Type is 415
def test_put_icon_bad_content_type(http_client, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "puttype")

    response = update_icon(
        http_client,
        test_guild.admin_token,
        emoji["id"],
        content=EMOJI_WEBP,
        content_type="text/plain",
    )

    assert response.status_code == 415
    assert response.json()["message"] == "Unsupported Media Type"


# PutTask R5/R6 - PNG and GIF icons are accepted and re-encoded
def test_put_icon_png(http_client, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "putpng")

    response = update_icon(
        http_client,
        test_guild.admin_token,
        emoji["id"],
        content=EMOJI_PNG,
        content_type="image/png",
    )

    assert response.status_code == 200
    assert HASH_RE.match(response.json()["icon_hash"])


def test_put_icon_gif(http_client, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "putgif")

    response = update_icon(
        http_client,
        test_guild.admin_token,
        emoji["id"],
        content=EMOJI_GIF,
        content_type="image/gif",
    )

    assert response.status_code == 200
    assert HASH_RE.match(response.json()["icon_hash"])


# PutTask R5/R6 - a JPEG icon is accepted and re-encoded
def test_put_icon_jpeg(http_client, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "putjpg")

    response = update_icon(
        http_client,
        test_guild.admin_token,
        emoji["id"],
        content=jpg.make_jpeg(16, 8),
        content_type="image/jpeg",
    )

    assert response.status_code == 200
    assert HASH_RE.match(response.json()["icon_hash"])


# PutTask R2
def test_put_icon_empty_body(http_client, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "putempty")

    response = update_icon(
        http_client, test_guild.admin_token, emoji["id"], content=b""
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Bad image"


# PutTask R2
def test_put_icon_unknown_parameter(http_client, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "putparam")

    response = update_icon(
        http_client,
        test_guild.admin_token,
        emoji["id"],
        params={"x": "1"},
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Unknown parameter"


# PutTask R3
def test_put_icon_unknown_emoji(http_client, test_guild):
    response = update_icon(http_client, test_guild.admin_token, UNKNOWN_EMOJI_ID)

    assert response.status_code == 404
    assert response.json()["message"] == "Emoji not found"


# PutTask R4 - a logged-in user without modify_emoji
def test_put_icon_without_modify_forbidden(http_client, test_session, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "putmod")

    response = update_icon(http_client, test_session.access_token, emoji["id"])

    assert response.status_code == 403
    assert response.json()["message"] == "Missing permissions"


# PutTask R4 - a role with a different emoji bit must not grant access
def test_put_icon_wrong_bit_forbidden(http_client, db_conn, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "putwrong")

    token = bit_user(
        http_client, db_conn, test_guild, "emoji_put_bit", CREATE_EMOJI, 991100021
    )

    response = update_icon(http_client, token, emoji["id"])

    assert response.status_code == 403


# PutTask R4 / R6 - the success path pins the exact MODIFY_EMOJI bit numbering
def test_put_icon_exact_modify_bit(http_client, db_conn, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "putexact")

    token = bit_user(
        http_client, db_conn, test_guild, "emoji_put_modify", MODIFY_EMOJI, 991100022
    )

    response = update_icon(http_client, token, emoji["id"])

    assert response.status_code == 200, response.content
    assert HASH_RE.fullmatch(response.json()["icon_hash"])


# PutTask R5
def test_put_icon_too_large(http_client, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "putlarge")

    response = update_icon(
        http_client,
        test_guild.admin_token,
        emoji["id"],
        content=webp.oversized_body(),
    )

    assert response.status_code == 413
    assert response.json()["message"] == "Image is too large"


# PutTask R5
def test_put_icon_malformed(http_client, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "putbad")

    response = update_icon(
        http_client,
        test_guild.admin_token,
        emoji["id"],
        content=b"this is not a webp at all",
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Bad image"


# PutTask R6 - the new icon is served at the new hash and the old hash is stale
def test_put_icon_replaces(http_client, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "replace")

    old_hash = emoji["icon_hash"]

    response = update_icon(
        http_client,
        test_guild.admin_token,
        emoji["id"],
        content=webp.EXTENDED_WEBP,
    )

    assert response.status_code == 200, response.content

    new_hash = response.json()["icon_hash"]
    assert HASH_RE.fullmatch(new_hash)
    assert new_hash != old_hash

    new_icon = get_icon(http_client, emoji["id"], new_hash)
    assert new_icon.status_code == 200
    assert is_webp(new_icon.content)

    assert get_icon(http_client, emoji["id"], old_hash).status_code == 404


# PutTask R6 - an animated WebP may replace a static icon
def test_put_icon_animated(http_client, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "animup")

    response = update_icon(
        http_client,
        test_guild.admin_token,
        emoji["id"],
        content=webp.make_animated_webp(frames=3),
    )

    assert response.status_code == 200, response.content

    icon = get_icon(http_client, emoji["id"], response.json()["icon_hash"])
    assert icon.status_code == 200

