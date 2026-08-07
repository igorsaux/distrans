# Tests for a single custom emoji:
#   PATCH  /api/emojis/{emoji_id}
#   DELETE /api/emojis/{emoji_id}
#
# Requirement numbering mirrors src/route/emojis/id.zig.
#
# PatchTask:
#   R1 - content type application/json and non-empty body (patchHandle)
#   R2 - user must be logged
#   R3 - the emoji exists (404 "Emoji not found")
#   R4 - valid JSON object ("Bad JSON" / "Expected an object")
#   R5 - "name" present, string, [a-z0-9_], within the codepoint bounds
#   R6 - modify_emoji required
#   R7 - renamed, 204, duplicate (guild, name) is 409
#
# DeleteTask:
#   R1 - user must be logged
#   R2 - the emoji exists (404 "Emoji not found")
#   R3 - delete_emoji required
#   R4 - deleted, 204

import json
import sys
from pathlib import Path

import pytest

from conftest import system_create_user, system_login

EMOJIS_DIR = Path(__file__).resolve().parent

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(EMOJIS_DIR))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "users"))

from permissions import CREATE_EMOJI, DELETE_EMOJI, MODIFY_EMOJI  # noqa: E402

from emoji_helpers import (  # noqa: E402
    create_emoji_ok,
    delete_emoji,
    grant_role,
    list_emojis,
    patch_emoji,
)

CONFIG_PATH = Path(__file__).resolve().parents[3] / "config.tests.json"

with CONFIG_PATH.open() as f:
    CONFIG = json.load(f)

MIN_NAME = CONFIG["api"]["emojis"]["min_name_codepoints"]
MAX_NAME = CONFIG["api"]["emojis"]["max_name_codepoints"]

UNKNOWN_EMOJI_ID = "999999999999"

BAD_NAMES = [
    "Upper",
    "with.dot",
    "with-dash",
    "юникод",
    "a" * (MAX_NAME + 1),
    *(["a" * (MIN_NAME - 1)] if MIN_NAME > 1 else []),
]


def bit_user(http_client, db_conn, test_guild, username, permissions, role_id):
    user = system_create_user(http_client, username=username)
    token, _ = system_login(http_client, username)
    grant_role(db_conn, int(test_guild.id), int(user["id"]), role_id, permissions)

    return token


# PatchTask R2 / DeleteTask R1
def test_emoji_patch_unauthorized(http_client, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "auth")

    response = http_client.patch(f"/api/emojis/{emoji['id']}", json={"name": "renamed"})

    assert response.status_code == 401


def test_emoji_delete_unauthorized(http_client, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "auth")

    response = http_client.delete(f"/api/emojis/{emoji['id']}")

    assert response.status_code == 401


# PatchTask R1
def test_emoji_patch_bad_content_type(http_client, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "ctype")

    response = patch_emoji(
        http_client, test_guild.admin_token, emoji["id"], {"name": "x"},
        content_type="text/plain",
    )

    assert response.status_code == 415
    assert response.json()["message"] == "Unsupported Media Type"


def test_emoji_patch_empty_body(http_client, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "empty")

    response = http_client.patch(
        f"/api/emojis/{emoji['id']}",
        content=b"",
        headers={
            "Authorization": f"Bearer {test_guild.admin_token}",
            "Content-Type": "application/json",
        },
    )

    assert response.status_code == 400


# PatchTask R3 / DeleteTask R2
def test_emoji_patch_unknown(http_client, test_guild):
    response = patch_emoji(
        http_client, test_guild.admin_token, UNKNOWN_EMOJI_ID, {"name": "x1"}
    )

    assert response.status_code == 404
    assert response.json()["message"] == "Emoji not found"


def test_emoji_delete_unknown(http_client, test_guild):
    response = delete_emoji(http_client, test_guild.admin_token, UNKNOWN_EMOJI_ID)

    assert response.status_code == 404
    assert response.json()["message"] == "Emoji not found"


# PatchTask R4
def test_emoji_patch_bad_json(http_client, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "json")

    response = http_client.patch(
        f"/api/emojis/{emoji['id']}",
        content=b"{not json",
        headers={
            "Authorization": f"Bearer {test_guild.admin_token}",
            "Content-Type": "application/json",
        },
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Bad JSON"


def test_emoji_patch_non_object(http_client, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "obj")

    response = patch_emoji(http_client, test_guild.admin_token, emoji["id"], ["nope"])

    assert response.status_code == 400
    assert response.json()["message"] == "Expected an object"


# PatchTask R5 - unknown keys alone are "nothing to update"
def test_emoji_patch_nothing_to_update(http_client, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "noop")

    response = patch_emoji(http_client, test_guild.admin_token, emoji["id"], {})

    assert response.status_code == 400
    assert response.json()["message"] == "Nothing to update"


# PatchTask R5 - "name" is not nullable
@pytest.mark.parametrize("value", [None, 1, True])
def test_emoji_patch_name_not_string(http_client, test_guild, value):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "type")

    response = patch_emoji(
        http_client, test_guild.admin_token, emoji["id"], {"name": value}
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'name' is not a string"


# PatchTask R5
@pytest.mark.parametrize("name", BAD_NAMES)
def test_emoji_patch_bad_name(http_client, test_guild, name):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "bad")

    response = patch_emoji(
        http_client, test_guild.admin_token, emoji["id"], {"name": name}
    )

    assert response.status_code == 400, f"{name!r}: {response.content!r}"

    message = response.json()["message"]
    assert message in ("'name' is invalid", "'name' is too short", "'name' is too long")


# PatchTask R6 - a logged-in user without modify_emoji
def test_emoji_patch_without_modify_forbidden(http_client, test_session, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "mod")

    response = patch_emoji(
        http_client, test_session.access_token, emoji["id"], {"name": "renamed"}
    )

    assert response.status_code == 403
    assert response.json()["message"] == "Missing permissions"


# PatchTask R6 - a role with a different emoji bit must not grant access
def test_emoji_patch_wrong_bit_forbidden(http_client, db_conn, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "wrong")

    token = bit_user(
        http_client, db_conn, test_guild, "emoji_patch_bit", CREATE_EMOJI, 991100011
    )

    response = patch_emoji(http_client, token, emoji["id"], {"name": "renamed"})

    assert response.status_code == 403


# PatchTask R6 / R7 - the success path pins the exact MODIFY_EMOJI bit numbering
def test_emoji_patch_exact_modify_bit(http_client, db_conn, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "exact")

    token = bit_user(
        http_client, db_conn, test_guild, "emoji_modify", MODIFY_EMOJI, 991100012
    )

    response = patch_emoji(http_client, token, emoji["id"], {"name": "renamed"})

    assert response.status_code == 204, response.content
    assert response.content == b""


# PatchTask R7 - the new name is visible in the list
def test_emoji_patch_renames(http_client, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "before")

    response = patch_emoji(
        http_client, test_guild.admin_token, emoji["id"], {"name": "after"}
    )

    assert response.status_code == 204

    listed = list_emojis(http_client, test_guild.admin_token, test_guild.id).json()
    assert [item["name"] for item in listed] == ["after"]


# PatchTask R7
def test_emoji_patch_duplicate_name(http_client, test_guild):
    create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "one")
    second = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "two")

    response = patch_emoji(
        http_client, test_guild.admin_token, second["id"], {"name": "one"}
    )

    assert response.status_code == 409
    assert response.json()["message"] == "Emoji name is already used"


# DeleteTask R3 - a logged-in user without delete_emoji
def test_emoji_delete_without_delete_forbidden(http_client, test_session, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "del")

    response = delete_emoji(http_client, test_session.access_token, emoji["id"])

    assert response.status_code == 403
    assert response.json()["message"] == "Missing permissions"


# DeleteTask R3 - a role with a different emoji bit must not grant access
def test_emoji_delete_wrong_bit_forbidden(http_client, db_conn, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "wrongdel")

    token = bit_user(
        http_client, db_conn, test_guild, "emoji_delete_bit", MODIFY_EMOJI, 991100013
    )

    response = delete_emoji(http_client, token, emoji["id"])

    assert response.status_code == 403


# DeleteTask R3 / R4 - the success path pins the exact DELETE_EMOJI bit numbering
def test_emoji_delete_exact_bit(http_client, db_conn, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "exactdel")

    token = bit_user(
        http_client, db_conn, test_guild, "emoji_delete", DELETE_EMOJI, 991100014
    )

    response = delete_emoji(http_client, token, emoji["id"])

    assert response.status_code == 204


# DeleteTask R4 - deleted and not found afterwards; deleting twice is 404
def test_emoji_delete_removes(http_client, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "gone")

    assert delete_emoji(http_client, test_guild.admin_token, emoji["id"]).status_code == 204

    listed = list_emojis(http_client, test_guild.admin_token, test_guild.id).json()
    assert listed == []

    assert delete_emoji(http_client, test_guild.admin_token, emoji["id"]).status_code == 404
