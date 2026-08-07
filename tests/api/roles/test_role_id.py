# Tests for GET / PATCH / DELETE /api/roles/{role_id}.
#
# GET:
# R1 - user must be logged
# R2 - the role exists (404 "Role not found")
#
# GET returns "mentionable" (defaults to true).
#
# PATCH:
# R1  - content type must be application/json and body non-empty
# R2  - user must be logged
# R3  - the role exists (404 "Role not found")
# R4  - body must be valid JSON and an object
# R5  - at least one of "name"/"permissions"/"color"/"mentionable" present
#       ("Nothing to update"; "color": null counts as present)
# R6  - @everyone role (role_id == guild_id): only "permissions" may be changed
# R7  - optional "name": string, <= api.roles.max_name_codepoints, no forbidden
#       codepoints; explicit null -> 400 "'name' is not a string"
# R8  - optional "permissions": string, parseable 128-bit decimal mask,
#       no reserved bits (400 "Bad 'permissions'");
#       explicit null -> 400 "'permissions' is not a string"
# R9  - optional "color": integer in [0, 16777215]; "color": null clears it
# R10 - optional "mentionable": boolean; absent leaves it unchanged
# R11 - rights: required = modify_roles | (new permissions when present)
# R12 - role hierarchy: role's current position must be strictly < user's
#       highest role position
#
# DELETE:
# R1 - user must be logged
# R2 - the role exists (404)
# R3 - cannot delete the @everyone role (403)
# R4 - user must have delete_roles (403)
# R5 - role hierarchy: role position strictly < user's highest role position
#
# The test_guild fixture grants its admin a superuser role on top; a role
# seeded above it cannot be edited/deleted. test_user has no roles: highest
# position 0. Ordering is changed only through
# PUT /guilds/{guild_id}/roles/order.

import sys
from pathlib import Path

import pytest

from conftest import seed_role, system_login

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from permissions import (
    READ_MESSAGES,
    SEND_MESSAGES,
    ADD_REACTIONS,
    CREATE_CHANNELS,
    MODIFY_CHANNELS,
    DELETE_CHANNELS,
    CREATE_ROLES,
    MODIFY_ROLES,
    DELETE_ROLES,
    ALL_BITS,
)

MAX_NAME_CODEPOINTS = 24
MAX_POSITION = 32767
MAX_COLOR = 16777215

# defaultEveryone(): read_messages | send_messages | add_reactions
DEFAULT_EVERYONE_PERMISSIONS = str(READ_MESSAGES | SEND_MESSAGES | ADD_REACTIONS)


def _set_everyone_permissions(db_conn, guild_id, permissions):
    with db_conn.cursor() as cur:
        cur.execute(
            "UPDATE app.roles SET permissions = %s WHERE id = %s",
            (permissions.to_bytes(16), guild_id),
        )


def _create_role(db_conn, guild_id, role_id, name, position=0, permissions=0, color=None):
    seed_role(db_conn, guild_id, role_id, name, position, permissions, color=color)


def _assign_role(db_conn, guild_id, user_id, role_id):
    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.member_roles (guild_id, user_id, role_id)"
            " VALUES (%s, %s, %s)",
            (guild_id, user_id, role_id),
        )


def _role_url(guild_id, role_id):
    return f"/api/roles/{role_id}"


# ---------------------------------------------------------------------------
# GET
# ---------------------------------------------------------------------------


# R1
def test_get_role_unauthorized(http_client, test_guild):
    response = http_client.get(_role_url(test_guild.id, test_guild.id))

    assert response.status_code == 401


# R2
def test_get_role_not_found(http_client, test_guild, test_session):
    response = http_client.get(
        _role_url(test_guild.id, "999999"),
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "Role not found"


# Router behavior: a malformed role_id is rejected with 400 before auth
def test_get_role_malformed_id(http_client, test_guild):
    response = http_client.get(_role_url(test_guild.id, "abc"))

    assert response.status_code == 400


# Router behavior: a malformed role_id is rejected with 400 before auth
def test_patch_role_malformed_id(http_client, test_guild):
    response = http_client.patch(
        _role_url(test_guild.id, "abc"),
        json={"name": "x"},
    )

    assert response.status_code == 400


# R2 - regression: @everyone has NULL color; the color read used to crash
def test_get_role_everyone(http_client, test_guild, test_session):
    response = http_client.get(
        _role_url(test_guild.id, test_guild.id),
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 200

    body = response.json()
    assert body["guild_id"] == test_guild.id
    assert body["name"] == "@everyone"
    assert body["position"] == 0
    assert body["permissions"] == DEFAULT_EVERYONE_PERMISSIONS
    assert body["color"] is None


def test_get_role_full_object(http_client, db_conn, test_guild, test_session):
    _create_role(
        db_conn,
        test_guild.id,
        "5560001",
        "colored",
        permissions=READ_MESSAGES | SEND_MESSAGES,
        color=65280,
    )

    response = http_client.get(
        _role_url(test_guild.id, "5560001"),
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 200

    body = response.json()
    assert body["guild_id"] == test_guild.id
    assert body["name"] == "colored"
    assert body["position"] == 1
    assert body["permissions"] == str(READ_MESSAGES | SEND_MESSAGES)
    assert body["color"] == 65280
    # mentionable defaults to true
    assert body["mentionable"] is True


# R10b - mentionable can be toggled both ways via PATCH
def test_patch_role_mentionable_toggle(http_client, db_conn, test_guild):
    _create_role(db_conn, test_guild.id, "5562001", "target")

    response = http_client.patch(
        _role_url(test_guild.id, "5562001"),
        json={"mentionable": False},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 204

    response = http_client.get(
        _role_url(test_guild.id, "5562001"),
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 200
    assert response.json()["mentionable"] is False

    response = http_client.patch(
        _role_url(test_guild.id, "5562001"),
        json={"mentionable": True},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 204

    response = http_client.get(
        _role_url(test_guild.id, "5562001"),
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.json()["mentionable"] is True


# R10b
def test_patch_role_mentionable_not_a_boolean(http_client, db_conn, test_guild):
    _create_role(db_conn, test_guild.id, "5562002", "target")

    response = http_client.patch(
        _role_url(test_guild.id, "5562002"),
        json={"mentionable": "yes"},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'mentionable' is not a boolean"


# ---------------------------------------------------------------------------
# PATCH
# ---------------------------------------------------------------------------


# R1
def test_patch_role_non_json_content_type(http_client, test_guild):
    response = http_client.patch(
        _role_url(test_guild.id, test_guild.id),
        content=b"name=x",
        headers={
            "Authorization": f"Bearer {test_guild.admin_token}",
            "Content-Type": "text/plain",
        },
    )

    assert response.status_code == 415


# R1
def test_patch_role_empty_body(http_client, test_guild):
    response = http_client.patch(
        _role_url(test_guild.id, test_guild.id),
        content=b"",
        headers={
            "Authorization": f"Bearer {test_guild.admin_token}",
            "Content-Type": "application/json",
        },
    )

    assert response.status_code == 400


# R2
def test_patch_role_unauthorized(http_client, test_guild):
    response = http_client.patch(
        _role_url(test_guild.id, test_guild.id),
        json={"name": "x"},
    )

    assert response.status_code == 401


# R3
def test_patch_role_not_found(http_client, test_guild):
    response = http_client.patch(
        _role_url(test_guild.id, "999999"),
        json={"name": "x"},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "Role not found"


# R4
def test_patch_role_bad_json(http_client, test_guild):
    response = http_client.patch(
        _role_url(test_guild.id, test_guild.id),
        content=b"{not json",
        headers={
            "Authorization": f"Bearer {test_guild.admin_token}",
            "Content-Type": "application/json",
        },
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Bad JSON"


# R4
def test_patch_role_not_an_object(http_client, test_guild):
    response = http_client.patch(
        _role_url(test_guild.id, test_guild.id),
        content=b"[1, 2, 3]",
        headers={
            "Authorization": f"Bearer {test_guild.admin_token}",
            "Content-Type": "application/json",
        },
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Expected an object"


# R5
def test_patch_role_nothing_to_update(http_client, test_guild):
    response = http_client.patch(
        _role_url(test_guild.id, test_guild.id),
        json={},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Nothing to update"


# R5 - unknown fields don't count as updates
def test_patch_role_unknown_field_nothing_to_update(http_client, test_guild):
    response = http_client.patch(
        _role_url(test_guild.id, test_guild.id),
        json={"unrelated": 1},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Nothing to update"


# R6
def test_patch_role_everyone_name_rejected(http_client, test_guild):
    response = http_client.patch(
        _role_url(test_guild.id, test_guild.id),
        json={"name": "renamed"},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Only 'permissions' can be changed on the @everyone role"


# R6 - @everyone permissions-only change succeeds
def test_patch_role_everyone_permissions(http_client, db_conn, test_guild):
    response = http_client.patch(
        _role_url(test_guild.id, test_guild.id),
        json={"permissions": str(READ_MESSAGES | SEND_MESSAGES | CREATE_CHANNELS)},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 204

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT permissions FROM app.roles WHERE id = %s",
            (test_guild.id,),
        )
        row = cur.fetchone()

    assert int.from_bytes(row["permissions"], "big") == (
        READ_MESSAGES | SEND_MESSAGES | CREATE_CHANNELS
    )


# R7 - explicit null in the non-nullable "name" is a type error
def test_patch_role_name_null(http_client, db_conn, test_guild):
    _create_role(db_conn, test_guild.id, "5561001", "target")

    response = http_client.patch(
        _role_url(test_guild.id, "5561001"),
        json={"name": None},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'name' is not a string"


# R7
def test_patch_role_name_not_a_string(http_client, db_conn, test_guild):
    _create_role(db_conn, test_guild.id, "5561001", "target")

    response = http_client.patch(
        _role_url(test_guild.id, "5561001"),
        json={"name": 42},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'name' is not a string"


# R7
def test_patch_role_name_too_long(http_client, db_conn, test_guild):
    _create_role(db_conn, test_guild.id, "5561002", "target")

    response = http_client.patch(
        _role_url(test_guild.id, "5561002"),
        json={"name": "a" * (MAX_NAME_CODEPOINTS + 1)},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'name' is too long"


# R7 - forbidden codepoints (zero-width space) are rejected
def test_patch_role_name_forbidden_codepoints(http_client, db_conn, test_guild):
    _create_role(db_conn, test_guild.id, "5561010", "target")

    response = http_client.patch(
        _role_url(test_guild.id, "5561010"),
        json={"name": "a\u200Bb"},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'name' is invalid"


# R7 - forbidden codepoints (blank braille pattern) are rejected
def test_patch_role_name_forbidden_braille_blank(http_client, db_conn, test_guild):
    _create_role(db_conn, test_guild.id, "5561011", "target")

    response = http_client.patch(
        _role_url(test_guild.id, "5561011"),
        json={"name": "a\u2800b"},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'name' is invalid"


# R7 - a valid multi-codepoint name is accepted
def test_patch_role_name_multi_codepoint(http_client, db_conn, test_guild):
    _create_role(db_conn, test_guild.id, "5561012", "target")

    response = http_client.patch(
        _role_url(test_guild.id, "5561012"),
        json={"name": "rôle ✨"},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 204

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT name FROM app.roles WHERE id = %s",
            ("5561012",),
        )
        row = cur.fetchone()

    assert row["name"] == "rôle ✨"


# R8 - explicit null in the non-nullable "permissions" is a type error
def test_patch_role_permissions_null(http_client, db_conn, test_guild):
    _create_role(db_conn, test_guild.id, "5561003", "target")

    response = http_client.patch(
        _role_url(test_guild.id, "5561003"),
        json={"permissions": None},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'permissions' is not a string"


# R8
def test_patch_role_permissions_not_a_string(http_client, db_conn, test_guild):
    _create_role(db_conn, test_guild.id, "5561003", "target")

    response = http_client.patch(
        _role_url(test_guild.id, "5561003"),
        json={"permissions": 3},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'permissions' is not a string"


# R8
def test_patch_role_permissions_not_parseable(http_client, db_conn, test_guild):
    _create_role(db_conn, test_guild.id, "5561004", "target")

    response = http_client.patch(
        _role_url(test_guild.id, "5561004"),
        json={"permissions": "abc"},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Bad 'permissions'"


# R8
def test_patch_role_permissions_reserved_bits(http_client, db_conn, test_guild):
    _create_role(db_conn, test_guild.id, "5561005", "target")

    response = http_client.patch(
        _role_url(test_guild.id, "5561005"),
        json={"permissions": str(1 << 123)},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Bad 'permissions'"


# R10
def test_patch_role_color_not_an_integer(http_client, db_conn, test_guild):
    _create_role(db_conn, test_guild.id, "5561008", "target")

    response = http_client.patch(
        _role_url(test_guild.id, "5561008"),
        json={"color": "red"},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'color' is not an integer"


# R10
def test_patch_role_color_out_of_range(http_client, db_conn, test_guild):
    _create_role(db_conn, test_guild.id, "5561009", "target")

    response = http_client.patch(
        _role_url(test_guild.id, "5561009"),
        json={"color": MAX_COLOR + 1},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Bad 'color'"


# R10 - "color": null counts as present and clears the color
def test_patch_role_color_null_clears(http_client, db_conn, test_guild, test_session):
    _create_role(
        db_conn, test_guild.id, "5561011", "colored", position=0, color=65280
    )

    response = http_client.patch(
        _role_url(test_guild.id, "5561011"),
        json={"color": None},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 204
    assert response.content == b""

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT color FROM app.roles WHERE id = %s",
            ("5561011",),
        )
        row = cur.fetchone()

    assert row["color"] is None

    api_response = http_client.get(
        _role_url(test_guild.id, "5561011"),
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )
    assert api_response.status_code == 200
    assert api_response.json()["color"] is None


# R6 - "color" cannot be set on @everyone
def test_patch_role_everyone_color_rejected(http_client, test_guild):
    response = http_client.patch(
        _role_url(test_guild.id, test_guild.id),
        json={"color": 255},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Only 'permissions' can be changed on the @everyone role"


# R6 - clearing the color on @everyone is rejected as well
def test_patch_role_everyone_color_null_rejected(http_client, test_guild):
    response = http_client.patch(
        _role_url(test_guild.id, test_guild.id),
        json={"color": None},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Only 'permissions' can be changed on the @everyone role"


# R11 - no modify_roles in base permissions
def test_patch_role_without_modify_roles(http_client, db_conn, test_guild, test_user):
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES | SEND_MESSAGES)
    _create_role(
        db_conn, test_guild.id, "5562001", "target", permissions=READ_MESSAGES
    )

    access_token, _ = system_login(http_client, test_user.username, test_user.password)

    response = http_client.patch(
        _role_url(test_guild.id, "5562001"),
        json={"name": "renamed"},
        headers={"Authorization": f"Bearer {access_token}"},
    )

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


# R11 - subset rule: granting a permission bit the caller lacks is forbidden
def test_patch_role_granting_absent_bit(http_client, db_conn, test_guild, test_user):
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES | MODIFY_ROLES)
    _create_role(
        db_conn, test_guild.id, "5562002", "target", permissions=READ_MESSAGES
    )

    access_token, _ = system_login(http_client, test_user.username, test_user.password)

    response = http_client.patch(
        _role_url(test_guild.id, "5562002"),
        json={"permissions": str(READ_MESSAGES | SEND_MESSAGES)},
        headers={"Authorization": f"Bearer {access_token}"},
    )

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


# R11 - subset rule applies to @everyone too
def test_patch_role_everyone_granting_absent_bit(
    http_client, db_conn, test_guild, test_user
):
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES | MODIFY_ROLES)

    access_token, _ = system_login(http_client, test_user.username, test_user.password)

    response = http_client.patch(
        _role_url(test_guild.id, test_guild.id),
        json={"permissions": str(ALL_BITS)},
        headers={"Authorization": f"Bearer {access_token}"},
    )

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


# R12 - editing a role at position >= own highest is forbidden
def test_patch_role_hierarchy_position(http_client, db_conn, test_guild):
    _create_role(
        db_conn,
        test_guild.id,
        "5562003",
        "rival",
        position=MAX_POSITION,
        permissions=READ_MESSAGES,
    )

    response = http_client.patch(
        _role_url(test_guild.id, "5562003"),
        json={"name": "renamed"},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


# R12 - @everyone edit by a user whose highest position is 0 is forbidden
def test_patch_role_everyone_hierarchy(http_client, db_conn, test_guild, test_user):
    _set_everyone_permissions(db_conn, test_guild.id, ALL_BITS)

    access_token, _ = system_login(http_client, test_user.username, test_user.password)

    response = http_client.patch(
        _role_url(test_guild.id, test_guild.id),
        json={"permissions": str(ALL_BITS)},
        headers={"Authorization": f"Bearer {access_token}"},
    )

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


# Success: 204, row updated, GET reflects the change; unlisted/null fields kept
def test_patch_role_success(http_client, db_conn, test_guild, test_session):
    _create_role(
        db_conn,
        test_guild.id,
        "5563001",
        "patched",
        permissions=READ_MESSAGES,
        color=255,
    )

    response = http_client.patch(
        _role_url(test_guild.id, "5563001"),
        json={"name": "renamed", "permissions": str(READ_MESSAGES | SEND_MESSAGES)},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 204
    assert response.content == b""

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT name, position, permissions, color FROM app.roles WHERE id = %s",
            ("5563001",),
        )
        row = cur.fetchone()

    assert row["name"] == "renamed"
    assert row["position"] == 1
    assert int.from_bytes(row["permissions"], "big") == READ_MESSAGES | SEND_MESSAGES
    assert row["color"] == 255

    api_response = http_client.get(
        _role_url(test_guild.id, "5563001"),
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )
    assert api_response.status_code == 200

    body = api_response.json()
    assert body["name"] == "renamed"
    assert body["permissions"] == str(READ_MESSAGES | SEND_MESSAGES)
    assert body["color"] == 255


# Success: color update
def test_patch_role_color(http_client, db_conn, test_guild):
    _create_role(db_conn, test_guild.id, "5563002", "colored", color=None)

    response = http_client.patch(
        _role_url(test_guild.id, "5563002"),
        json={"color": 16711680},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 204

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT color FROM app.roles WHERE id = %s",
            ("5563002",),
        )
        row = cur.fetchone()

    assert row["color"] == 16711680


# R11 - exact-bit success path: a caller whose only role bit is modify_roles
# (bit 7) can rename a role below them
def test_patch_role_with_exact_modify_roles_permission(
    http_client, db_conn, test_guild, test_user
):
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES | SEND_MESSAGES)
    _create_role(
        db_conn,
        test_guild.id,
        "5562005",
        "renamer",
        position=1,
        permissions=MODIFY_ROLES,
    )
    _assign_role(db_conn, test_guild.id, test_user.id, "5562005")
    _create_role(db_conn, test_guild.id, "5562006", "target", position=0)

    access_token, _ = system_login(http_client, test_user.username, test_user.password)

    response = http_client.patch(
        _role_url(test_guild.id, "5562006"),
        json={"name": "renamed"},
        headers={"Authorization": f"Bearer {access_token}"},
    )

    assert response.status_code == 204

    with db_conn.cursor() as cur:
        cur.execute("SELECT name FROM app.roles WHERE id = %s", ("5562006",))
        row = cur.fetchone()

    assert row["name"] == "renamed"


# ---------------------------------------------------------------------------
# DELETE
# ---------------------------------------------------------------------------


# R1
def test_delete_role_unauthorized(http_client, test_guild):
    response = http_client.delete(_role_url(test_guild.id, test_guild.id))

    assert response.status_code == 401


# R2
def test_delete_role_not_found(http_client, test_guild):
    response = http_client.delete(
        _role_url(test_guild.id, "999999"),
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "Role not found"


# R3
def test_delete_role_everyone(http_client, test_guild):
    response = http_client.delete(
        _role_url(test_guild.id, test_guild.id),
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Cannot delete the @everyone role"


# R4
def test_delete_role_without_delete_roles(http_client, db_conn, test_guild, test_user):
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES | MODIFY_ROLES)
    _create_role(db_conn, test_guild.id, "5564001", "target")

    access_token, _ = system_login(http_client, test_user.username, test_user.password)

    response = http_client.delete(
        _role_url(test_guild.id, "5564001"),
        headers={"Authorization": f"Bearer {access_token}"},
    )

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


# R5 - a role at position >= own highest cannot be deleted
# (the fixture admin's superuser role sits at MAX_POSITION)
def test_delete_role_hierarchy(http_client, db_conn, test_guild):
    _create_role(
        db_conn,
        test_guild.id,
        "5564002",
        "rival",
        position=MAX_POSITION,
        permissions=READ_MESSAGES,
    )

    response = http_client.delete(
        _role_url(test_guild.id, "5564002"),
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


# Success: 204, role gone from DB, member_roles rows cascaded, gone from the
# guild roles collection
def test_delete_role_success(http_client, db_conn, test_guild, test_user, test_session):
    _create_role(db_conn, test_guild.id, "5565001", "doomed", position=0)
    _assign_role(db_conn, test_guild.id, test_user.id, "5565001")

    response = http_client.delete(
        _role_url(test_guild.id, "5565001"),
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 204
    assert response.content == b""

    with db_conn.cursor() as cur:
        cur.execute("SELECT 1 FROM app.roles WHERE id = %s", ("5565001",))
        assert cur.fetchone() is None

        cur.execute(
            "SELECT 1 FROM app.member_roles WHERE role_id = %s", ("5565001",)
        )
        assert cur.fetchone() is None

    api_response = http_client.get(
        f"/api/guilds/{test_guild.id}/roles",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )
    assert api_response.status_code == 200

    roles = api_response.json()
    assert all(role["id"] != "5565001" for role in roles)


# R4 - exact-bit success path: a caller whose only role bit is delete_roles
# (bit 8) can delete a role below them
def test_delete_role_with_exact_delete_roles_permission(
    http_client, db_conn, test_guild, test_user
):
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES | SEND_MESSAGES)
    _create_role(
        db_conn,
        test_guild.id,
        "5565002",
        "deleter",
        position=1,
        permissions=DELETE_ROLES,
    )
    _assign_role(db_conn, test_guild.id, test_user.id, "5565002")
    _create_role(db_conn, test_guild.id, "5565003", "doomed", position=0)

    access_token, _ = system_login(http_client, test_user.username, test_user.password)

    response = http_client.delete(
        _role_url(test_guild.id, "5565003"),
        headers={"Authorization": f"Bearer {access_token}"},
    )

    assert response.status_code == 204

    with db_conn.cursor() as cur:
        cur.execute("SELECT 1 FROM app.roles WHERE id = %s", ("5565003",))
        assert cur.fetchone() is None
