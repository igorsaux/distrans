# Tests for the guild custom emoji collection:
#   GET  /api/guilds/{guild_id}/emojis
#   POST /api/guilds/{guild_id}/emojis?name={name}
#
# Requirement numbering mirrors src/route/guilds/id/emojis.zig.
#
# GetTask:
#   R1 - limit > 0 and limit <= api.emojis.max_emojis_limit; malformed/unknown params are 400
#   R2 - user must be logged
#   R3 - the guild must exist (400 "Guild not found")
#
# PostTask:
#   R1 - user must be logged
#   R2 - non-empty body with an image/webp Content-Type; else 400 "Bad image"
#   R3 - the guild exists (404 "Guild not found")
#   R4 - create_emoji required (403 "Missing permissions")
#   R5 - "name" is the only accepted query parameter and it is required
#   R6 - "name" must normalize to [a-z0-9_], length within
#        api.emojis.min/max_name_codepoints
#   R7 - fewer than api.guilds.max_emojis emojis in the guild (400 "Too many emojis")
#   R8 - the upload is a valid WebP within the media.emoji caps; oversize is 413
#   R9 - stored; duplicate (guild, name) is 409 "Emoji name is already used"
#   R10 - 201 {"id", "name", "icon_hash"} + emoji_created dispatch

import json
import sys
from pathlib import Path

import pytest

from conftest import system_create_user, system_login

EMOJIS_DIR = Path(__file__).resolve().parents[1] / "emojis"

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(EMOJIS_DIR))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "users"))

from permissions import CREATE_EMOJI, CREATE_ROLES  # noqa: E402

import gif  # noqa: E402
import png  # noqa: E402
import webp  # noqa: E402

EMOJI_PNG = png.make_png(4, 4)
EMOJI_GIF = gif.make_animated_gif()

from emoji_helpers import (  # noqa: E402
    ANIMATED_WEBP,
    EMOJI_WEBP,
    HASH_RE,
    create_emoji,
    create_emoji_ok,
    create_guild_with_admin,
    get_icon,
    grant_role,
    is_animated_webp,
    list_emojis,
)

CONFIG_PATH = Path(__file__).resolve().parents[3] / "config.tests.json"

with CONFIG_PATH.open() as f:
    CONFIG = json.load(f)

MAX_EMOJIS = CONFIG["api"]["guilds"]["max_emojis"]
MIN_NAME = CONFIG["api"]["emojis"]["min_name_codepoints"]
MAX_NAME = CONFIG["api"]["emojis"]["max_name_codepoints"]

UNKNOWN_GUILD_ID = "999999999999"

BAD_NAMES = [
    "Upper",
    "with.dot",
    "with-dash",
    "with space",
    "юникод",
    "emoji😀",
    "a" * (MAX_NAME + 1),
    *(["a" * (MIN_NAME - 1)] if MIN_NAME > 1 else []),
]


def bit_user(http_client, db_conn, test_guild, username, permissions, role_id):
    user = system_create_user(http_client, username=username)
    token, _ = system_login(http_client, username)
    grant_role(db_conn, int(test_guild.id), int(user["id"]), role_id, permissions)

    return token


# GetTask R1 / R2
def test_list_emojis_unauthorized(http_client, test_guild):
    response = http_client.get(f"/api/guilds/{test_guild.id}/emojis")

    assert response.status_code == 401


# GetTask R3
def test_list_emojis_unknown_guild(http_client, test_guild):
    response = list_emojis(http_client, test_guild.admin_token, UNKNOWN_GUILD_ID)

    assert response.status_code == 404
    assert response.json()["message"] == "Guild not found"


# GetTask R1
@pytest.mark.parametrize("limit", [0, MAX_EMOJIS + 1, -1, "abc"])
def test_list_emojis_bad_limit(http_client, test_guild, limit):
    response = list_emojis(
        http_client, test_guild.admin_token, test_guild.id, limit=limit
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Bad 'limit' parameter"


# GetTask R1
def test_list_emojis_unknown_parameter(http_client, test_guild):
    response = list_emojis(http_client, test_guild.admin_token, test_guild.id, x="1")

    assert response.status_code == 400
    assert response.json()["message"] == "Unknown parameter"


# GetTask R1 - an empty guild returns an empty list
def test_list_emojis_empty(http_client, test_guild):
    response = list_emojis(http_client, test_guild.admin_token, test_guild.id)

    assert response.status_code == 200
    assert response.json() == []


# GetTask R1 - only the requested guild's emojis are returned
def test_list_emojis_isolated_per_guild(http_client, test_guild):
    other, other_token = create_guild_with_admin(http_client, "OtherGuild")

    create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "own_emoji")
    create_emoji_ok(http_client, other_token, other.id, "ghost_emoji")

    response = list_emojis(http_client, test_guild.admin_token, test_guild.id)

    assert response.status_code == 200
    assert [item["name"] for item in response.json()] == ["own_emoji"]


# GetTask R1 - keyset pagination via `after`
def test_list_emojis_after_pagination(http_client, test_guild):
    first = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "aaa")
    second = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "bbb")
    third = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "ccc")

    page = list_emojis(http_client, test_guild.admin_token, test_guild.id, limit=2).json()
    assert [item["id"] for item in page] == [first["id"], second["id"]]

    rest = list_emojis(
        http_client, test_guild.admin_token, test_guild.id, limit=2, after=second["id"]
    ).json()
    assert [item["id"] for item in rest] == [third["id"]]


# PostTask R1
def test_create_emoji_unauthorized(http_client, test_guild):
    response = http_client.post(
        f"/api/guilds/{test_guild.id}/emojis",
        params={"name": "nope"},
        content=EMOJI_WEBP,
        headers={"Content-Type": "image/webp"},
    )

    assert response.status_code == 401


# PostTask R2 - an unsupported Content-Type is 415
def test_create_emoji_bad_content_type(http_client, test_guild):
    response = create_emoji(
        http_client,
        test_guild.admin_token,
        test_guild.id,
        "bad_type",
        content_type="text/plain",
    )

    assert response.status_code == 415
    assert response.json()["message"] == "Unsupported Media Type"


# PostTask R8 - PNG and GIF bodies are accepted and re-encoded
def test_create_emoji_png(http_client, test_guild):
    response = create_emoji(
        http_client,
        test_guild.admin_token,
        test_guild.id,
        "png_emoji",
        content=EMOJI_PNG,
        content_type="image/png",
    )

    assert response.status_code == 201
    assert HASH_RE.fullmatch(response.json()["icon_hash"])


def test_create_emoji_gif(http_client, test_guild):
    response = create_emoji(
        http_client,
        test_guild.admin_token,
        test_guild.id,
        "gif_emoji",
        content=EMOJI_GIF,
        content_type="image/gif",
    )

    assert response.status_code == 201
    assert HASH_RE.fullmatch(response.json()["icon_hash"])


# PostTask R2
def test_create_emoji_empty_body(http_client, test_guild):
    response = create_emoji(
        http_client, test_guild.admin_token, test_guild.id, "empty", content=None
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Bad image"


# PostTask R3
def test_create_emoji_unknown_guild(http_client, test_guild):
    response = create_emoji(
        http_client, test_guild.admin_token, UNKNOWN_GUILD_ID, "ghost"
    )

    assert response.status_code == 404
    assert response.json()["message"] == "Guild not found"


# PostTask R4 - a logged-in user without create_emoji
def test_create_emoji_without_create_forbidden(http_client, test_session, test_guild):
    response = create_emoji(
        http_client, test_session.access_token, test_guild.id, "nope"
    )

    assert response.status_code == 403
    assert response.json()["message"] == "Missing permissions"


# PostTask R4 - a role with a different bit must not grant access
def test_create_emoji_wrong_bit_forbidden(http_client, db_conn, test_guild):
    token = bit_user(
        http_client, db_conn, test_guild, "emoji_wrong_bit", CREATE_ROLES, 991100001
    )

    response = create_emoji(http_client, token, test_guild.id, "wrong_bit")

    assert response.status_code == 403


# PostTask R4 - the success path pins the exact CREATE_EMOJI bit numbering
def test_create_emoji_exact_create_bit(http_client, db_conn, test_guild):
    token = bit_user(
        http_client, db_conn, test_guild, "emoji_create", CREATE_EMOJI, 991100002
    )

    response = create_emoji(http_client, token, test_guild.id, "exact_bit")

    assert response.status_code == 201, response.content
    assert HASH_RE.fullmatch(response.json()["icon_hash"])


# PostTask R5
def test_create_emoji_missing_name(http_client, test_guild):
    response = create_emoji(
        http_client, test_guild.admin_token, test_guild.id, None, params={}
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'name' is missing"


# PostTask R5
def test_create_emoji_unknown_query_parameter(http_client, test_guild):
    response = create_emoji(
        http_client,
        test_guild.admin_token,
        test_guild.id,
        "ok",
        params={"name": "ok", "x": "1"},
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Unknown parameter"


# PostTask R6
@pytest.mark.parametrize("name", BAD_NAMES)
def test_create_emoji_bad_name(http_client, test_guild, name):
    response = create_emoji(http_client, test_guild.admin_token, test_guild.id, name)

    assert response.status_code == 400, f"{name!r}: {response.content!r}"

    message = response.json()["message"]
    assert message in ("'name' is invalid", "'name' is too short", "'name' is too long")


# PostTask R6 - a name at the upper bound is accepted
def test_create_emoji_name_at_max_length(http_client, test_guild):
    name = "a" * MAX_NAME

    body = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, name)

    assert body["name"] == name


# PostTask R6 - a name at the lower bound is accepted
def test_create_emoji_name_at_min_length(http_client, test_guild):
    name = "a" * MIN_NAME

    body = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, name)

    assert body["name"] == name


# PostTask R7
def test_create_emoji_guild_full(http_client, db_conn, test_guild):
    with db_conn.cursor() as cur:
        cur.executemany(
            "INSERT INTO app.emojis (id, guild_id, name, icon_data, icon_hash)"
            " VALUES (%s, %s, %s, %s, %s)",
            [
                (700000000 + index, int(test_guild.id), f"seed_{index}", b"\x00", "0" * 16)
                for index in range(MAX_EMOJIS)
            ],
        )

    response = create_emoji(
        http_client, test_guild.admin_token, test_guild.id, "one_too_many"
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Too many emojis"


# PostTask R8
def test_create_emoji_too_large(http_client, test_guild):
    response = create_emoji(
        http_client,
        test_guild.admin_token,
        test_guild.id,
        "too_large",
        content=webp.oversized_body(),
    )

    assert response.status_code == 413
    assert response.json()["message"] == "Image is too large"


# PostTask R8
def test_create_emoji_malformed(http_client, test_guild):
    response = create_emoji(
        http_client,
        test_guild.admin_token,
        test_guild.id,
        "malformed",
        content=b"this is not a webp at all",
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Bad image"


# PostTask R8 - the server stays usable after a malformed upload
def test_create_emoji_server_survives_malformed(http_client, test_guild):
    create_emoji(
        http_client, test_guild.admin_token, test_guild.id, "malformed", content=b"nope"
    )

    assert http_client.get("/api/limits").status_code == 200

    response = create_emoji(
        http_client, test_guild.admin_token, test_guild.id, "after_malformed"
    )
    assert response.status_code == 201


# PostTask R9
def test_create_emoji_duplicate_name(http_client, test_guild):
    create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "dup")

    response = create_emoji(http_client, test_guild.admin_token, test_guild.id, "dup")

    assert response.status_code == 409
    assert response.json()["message"] == "Emoji name is already used"


# PostTask R9 - the same name may exist in a different guild
def test_create_emoji_same_name_other_guild(http_client, test_guild):
    other, other_token = create_guild_with_admin(http_client, "OtherGuild")

    create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "shared")
    create_emoji_ok(http_client, other_token, other.id, "shared")


# PostTask R10
def test_create_emoji_returns_body_and_lists(http_client, test_guild):
    body = create_emoji_ok(
        http_client, test_guild.admin_token, test_guild.id, "party_parrot"
    )

    assert set(body) == {"id", "name", "icon_hash"}

    listed = list_emojis(http_client, test_guild.admin_token, test_guild.id).json()
    assert listed == [body]


# PostTask R8 / R10 - an animated WebP is stored as an animated webp
def test_create_emoji_animated(http_client, test_guild):
    body = create_emoji_ok(
        http_client,
        test_guild.admin_token,
        test_guild.id,
        "party_blob",
        content=ANIMATED_WEBP,
    )

    response = get_icon(http_client, body["id"], body["icon_hash"])

    assert response.status_code == 200
    assert is_animated_webp(response.content)
