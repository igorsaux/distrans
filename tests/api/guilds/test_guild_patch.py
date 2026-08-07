# Tests for PATCH /api/guilds/{guild_id} (update a guild).
#
# Requirement numbering mirrors src/route/guilds/id.zig:
#   R1 - content type must be application/json and body non-empty
#   R2 - user must be logged
#   R3 - the guild exists (404 "Guild not found")
#   R4 - guild_modify required (403 "Missing permissions")
#   R5 - body is a JSON object with a recognized field; else 400 "Nothing to update"
#   R6 - "name" must be a string, not too long and contain no forbidden codepoints
#
# The test_guild fixture grants its admin a superuser role (all bits); the
# success path additionally pins the exact GUILD_MODIFY bit via a dedicated
# role (see tests/api/permissions.py).

import sys
from pathlib import Path

from conftest import seed_role, system_create_user, system_login

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from permissions import GUILD_MODIFY, MODIFY_CHANNELS

MAX_NAME_CODEPOINTS = 18

UNKNOWN_GUILD_ID = "999999999998"


def _auth(token):
    return {"Authorization": f"Bearer {token}"}


def _patch(http_client, token, guild_id, body):
    return http_client.patch(
        f"/api/guilds/{guild_id}", json=body, headers=_auth(token)
    )


def _guild_name(http_client, token, guild_id):
    guilds = http_client.get("/api/guilds", headers=_auth(token)).json()

    return next(g["name"] for g in guilds if g["id"] == guild_id)


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


# R1
def test_patch_guild_non_json_content_type(http_client, test_guild):
    response = http_client.patch(
        f"/api/guilds/{test_guild.id}",
        content=b"name=x",
        headers={**_auth(test_guild.admin_token), "Content-Type": "text/plain"},
    )

    assert response.status_code == 415


# R1
def test_patch_guild_empty_body(http_client, test_guild):
    response = http_client.patch(
        f"/api/guilds/{test_guild.id}",
        content=b"",
        headers={**_auth(test_guild.admin_token), "Content-Type": "application/json"},
    )

    assert response.status_code == 400


# R2
def test_patch_guild_unauthorized(http_client, test_guild):
    response = http_client.patch(
        f"/api/guilds/{test_guild.id}", json={"name": "x"}
    )

    assert response.status_code == 401


# R3
def test_patch_guild_missing_not_found(http_client, test_guild):
    response = _patch(
        http_client, test_guild.admin_token, UNKNOWN_GUILD_ID, {"name": "renamed"}
    )

    assert response.status_code == 404
    assert response.json()["message"] == "Guild not found"


# R4
def test_patch_guild_without_guild_modify_forbidden(
    http_client, test_session, test_guild
):
    response = _patch(
        http_client, test_session.access_token, test_guild.id, {"name": "renamed"}
    )

    assert response.status_code == 403
    assert response.json()["message"] == "Missing permissions"


# R4 - a different permission bit must not grant access
def test_patch_guild_wrong_permission_bit_forbidden(
    http_client, db_conn, test_guild
):
    _, token = _bit_user(
        http_client, db_conn, test_guild, "patch_wrong_bit", MODIFY_CHANNELS, 992000001
    )

    response = _patch(http_client, token, test_guild.id, {"name": "renamed"})

    assert response.status_code == 403


# R4 - the success path pins the exact GUILD_MODIFY bit numbering
def test_patch_guild_exact_guild_modify_bit(http_client, db_conn, test_guild):
    _, token = _bit_user(
        http_client, db_conn, test_guild, "patch_guild_modify", GUILD_MODIFY, 992000002
    )

    response = _patch(http_client, token, test_guild.id, {"name": "exact bit"})

    assert response.status_code == 204


# R5
def test_patch_guild_nothing_to_update(http_client, test_guild):
    response = _patch(http_client, test_guild.admin_token, test_guild.id, {})

    assert response.status_code == 400
    assert response.json()["message"] == "Nothing to update"


# R5 - unknown keys alone are not an update
def test_patch_guild_unknown_field_only(http_client, test_guild):
    response = _patch(
        http_client, test_guild.admin_token, test_guild.id, {"unknown": "x"}
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Nothing to update"


# R6
def test_patch_guild_name_not_a_string(http_client, test_guild):
    response = _patch(http_client, test_guild.admin_token, test_guild.id, {"name": 42})

    assert response.status_code == 400
    assert response.json()["message"] == "'name' is not a string"


# R6
def test_patch_guild_name_too_long(http_client, test_guild):
    response = _patch(
        http_client,
        test_guild.admin_token,
        test_guild.id,
        {"name": "g" * (MAX_NAME_CODEPOINTS + 1)},
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'name' is too long"


# R6
def test_patch_guild_name_forbidden_codepoints(http_client, test_guild):
    response = _patch(
        http_client, test_guild.admin_token, test_guild.id, {"name": "g\u200Bh"}
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'name' is invalid"


# R6 - a valid rename succeeds and is reflected by GET /api/guilds
def test_patch_guild_renames(http_client, test_guild):
    response = _patch(
        http_client, test_guild.admin_token, test_guild.id, {"name": "Renamed"}
    )

    assert response.status_code == 204
    assert response.content == b""
    assert _guild_name(http_client, test_guild.admin_token, test_guild.id) == "Renamed"


# R6 - the maximum length is accepted
def test_patch_guild_name_max_length(http_client, test_guild):
    name = "g" * MAX_NAME_CODEPOINTS

    response = _patch(
        http_client, test_guild.admin_token, test_guild.id, {"name": name}
    )

    assert response.status_code == 204
    assert _guild_name(http_client, test_guild.admin_token, test_guild.id) == name


# R6 - the name is NFKC-normalized before storage
def test_patch_guild_name_normalized(http_client, test_guild):
    response = _patch(
        http_client,
        test_guild.admin_token,
        test_guild.id,
        {"name": "\uFF27\uFF55\uFF49\uFF4C\uFF44"},  # fullwidth "Guild"
    )

    assert response.status_code == 204
    assert _guild_name(http_client, test_guild.admin_token, test_guild.id) == "Guild"

