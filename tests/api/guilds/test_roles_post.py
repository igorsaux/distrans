# Tests for POST /api/guilds/{guild_id}/roles (create role).
#
# R1 - content type must be application/json and body non-empty
# R2 - user must be logged
# R3 - the guild exists
# R4 - body must be valid JSON and an object
# R5 - "name" must be present, a string, not too long and contain no forbidden
# codepoints (400 "'name' is invalid")
# R6 - "permissions" must be present, a string parseable as a 128-bit decimal mask with no reserved bits
# R7 - optional "color" must be an integer in [0, 16777215] (or null)
# R8 - optional "mentionable" must be a boolean (or null -> default true)
# R9 - user may only grant permissions one already has: (requested & ~base) == 0
# R10 - role hierarchy: the caller must have at least one non-@everyone role.
# The test_guild fixture grants its admin a superuser role on top.

import sys
from pathlib import Path

import pytest

from conftest import SYSTEM_HEADERS, seed_role, system_login

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from permissions import (
    READ_MESSAGES,
    SEND_MESSAGES,
    CREATE_CHANNELS,
    CREATE_ROLES,
    ALL_BITS,
)

MAX_NAME_CODEPOINTS = 24
MAX_COLOR = 16777215


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


def _post_role(http_client, token, guild_id, **payload):
    return http_client.post(
        f"/api/guilds/{guild_id}/roles",
        json=payload,
        headers={"Authorization": f"Bearer {token}"},
    )


# R1
def test_post_role_non_json_content_type(http_client, test_guild):
    response = http_client.post(
        f"/api/guilds/{test_guild.id}/roles",
        content=b"name=x",
        headers={
            "Authorization": f"Bearer {test_guild.admin_token}",
            "Content-Type": "text/plain",
        },
    )

    assert response.status_code == 415


# R1
def test_post_role_empty_body(http_client, test_guild):
    response = http_client.post(
        f"/api/guilds/{test_guild.id}/roles",
        content=b"",
        headers={
            "Authorization": f"Bearer {test_guild.admin_token}",
            "Content-Type": "application/json",
        },
    )

    assert response.status_code == 400


# R2
def test_post_role_unauthorized(http_client, test_guild):
    response = http_client.post(
        f"/api/guilds/{test_guild.id}/roles",
        json={"name": "x", "permissions": "3"},
    )

    assert response.status_code == 401


# R3
def test_post_role_guild_not_found(http_client, test_guild):
    response = _post_role(
        http_client, test_guild.admin_token, "2", name="x", permissions="3"
    )

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "Guild not found"


# R4
def test_post_role_bad_json(http_client, test_guild):
    response = http_client.post(
        f"/api/guilds/{test_guild.id}/roles",
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
def test_post_role_not_an_object(http_client, test_guild):
    response = http_client.post(
        f"/api/guilds/{test_guild.id}/roles",
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
def test_post_role_name_missing(http_client, test_guild):
    response = _post_role(http_client, test_guild.admin_token, test_guild.id, permissions="3")

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'name' is missing"


# R5
def test_post_role_name_not_a_string(http_client, test_guild):
    response = _post_role(http_client, test_guild.admin_token, test_guild.id, name=42, permissions="3")

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'name' is not a string"


# R5
def test_post_role_name_too_long(http_client, test_guild):
    response = _post_role(
        http_client,
        test_guild.admin_token,
        test_guild.id,
        name="a" * (MAX_NAME_CODEPOINTS + 1),
        permissions="3",
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'name' is too long"


# R5 - forbidden codepoints (zero-width space) are rejected
def test_post_role_name_forbidden_codepoints(http_client, test_guild):
    response = _post_role(
        http_client,
        test_guild.admin_token,
        test_guild.id,
        name="a\u200Bb",
        permissions="3",
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'name' is invalid"


# R5 - forbidden codepoints (invisible hangul filler) are rejected
def test_post_role_name_forbidden_hangul_filler(http_client, test_guild):
    response = _post_role(
        http_client,
        test_guild.admin_token,
        test_guild.id,
        name="a\u3164b",
        permissions="3",
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'name' is invalid"


# R7
def test_post_role_permissions_missing(http_client, test_guild):
    response = _post_role(http_client, test_guild.admin_token, test_guild.id, name="x")

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'permissions' is missing"


# R7
def test_post_role_permissions_not_a_string(http_client, test_guild):
    response = _post_role(
        http_client, test_guild.admin_token, test_guild.id, name="x", permissions=3
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'permissions' is not a string"


# R7
def test_post_role_permissions_not_parseable(http_client, test_guild):
    response = _post_role(
        http_client, test_guild.admin_token, test_guild.id, name="x", permissions="abc"
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Bad 'permissions'"


# R7
def test_post_role_permissions_negative(http_client, test_guild):
    response = _post_role(
        http_client, test_guild.admin_token, test_guild.id, name="x", permissions="-1"
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Bad 'permissions'"


# R7 - reserved (undefined) bits are rejected
def test_post_role_permissions_reserved_bits(http_client, test_guild):
    response = _post_role(
        http_client, test_guild.admin_token, test_guild.id, name="x", permissions=str(1 << 123)
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Bad 'permissions'"


# R8
def test_post_role_color_not_an_integer(http_client, test_guild):
    response = _post_role(
        http_client,
        test_guild.admin_token,
        test_guild.id,
        name="x",
        permissions="3",
        color="red",
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'color' is not an integer"


# R8
def test_post_role_color_negative(http_client, test_guild):
    response = _post_role(
        http_client,
        test_guild.admin_token,
        test_guild.id,
        name="x",
        permissions="3",
        color=-1,
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Bad 'color'"


# R8
def test_post_role_color_too_big(http_client, test_guild):
    response = _post_role(
        http_client,
        test_guild.admin_token,
        test_guild.id,
        name="x",
        permissions="3",
        color=MAX_COLOR + 1,
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Bad 'color'"


# R9 - default @everyone permissions (3) do not include the requested bits
def test_post_role_without_permission(http_client, db_conn, test_guild, test_user):
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES | SEND_MESSAGES)

    access_token, _ = system_login(http_client, test_user.username, test_user.password)

    response = _post_role(
        http_client, access_token, test_guild.id, name="x", permissions=str(ALL_BITS)
    )

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


# R9 - success via a role carrying the requested bits
def test_post_role_with_role_permission(http_client, db_conn, test_guild, test_user, test_session):
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES | SEND_MESSAGES)
    _create_role(
        db_conn, test_guild.id, "5550001", "role-maker", position=5, permissions=ALL_BITS | CREATE_ROLES
    )
    _assign_role(db_conn, test_guild.id, test_user.id, "5550001")

    response = _post_role(
        http_client,
        test_session.access_token,
        test_guild.id,
        name="newrole",
        permissions=str(ALL_BITS),
        position=4,
    )

    assert response.status_code == 201

    body = response.json()
    assert body["id"] is not None


# R9 - permissions equal to the base are allowed (subset, not strict).
# The user needs a role above position 0 to satisfy the hierarchy rule (R10).
def test_post_role_permissions_equal_to_base(http_client, db_conn, test_guild, test_user, test_session):
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES | SEND_MESSAGES)
    _create_role(
        db_conn, test_guild.id, "5550002", "equal-maker", position=5, permissions=ALL_BITS | CREATE_ROLES
    )
    _assign_role(db_conn, test_guild.id, test_user.id, "5550002")

    response = _post_role(
        http_client,
        test_session.access_token,
        test_guild.id,
        name="same",
        permissions=str(READ_MESSAGES | SEND_MESSAGES),
    )

    assert response.status_code == 201


# R9 - subset rule without create_roles: the base contains all requested bits
# but lacks create_roles itself
def test_post_role_lacks_create_roles_bit(http_client, db_conn, test_guild, test_user):
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES | SEND_MESSAGES)

    access_token, _ = system_login(http_client, test_user.username, test_user.password)

    response = _post_role(
        http_client,
        access_token,
        test_guild.id,
        name="x",
        permissions=str(READ_MESSAGES | SEND_MESSAGES),
    )

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


# R9 - create_roles present but the requested mask exceeds the base
def test_post_role_create_roles_without_requested_bit(
    http_client, db_conn, test_guild, test_user
):
    _set_everyone_permissions(
        db_conn, test_guild.id, READ_MESSAGES | SEND_MESSAGES | CREATE_ROLES
    )

    access_token, _ = system_login(http_client, test_user.username, test_user.password)

    response = _post_role(
        http_client,
        access_token,
        test_guild.id,
        name="x",
        permissions=str(READ_MESSAGES | CREATE_CHANNELS),
    )

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


# R10 - hierarchy dominance: even with sufficient permission bits, a user whose
# highest role position is 0 (only @everyone) cannot create roles at all
def test_post_role_hierarchy_dominance(http_client, db_conn, test_guild, test_user):
    _set_everyone_permissions(db_conn, test_guild.id, ALL_BITS)

    access_token, _ = system_login(http_client, test_user.username, test_user.password)

    response = _post_role(
        http_client,
        access_token,
        test_guild.id,
        name="x",
        permissions=str(ALL_BITS),
    )

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


def test_post_role_persists(http_client, db_conn, test_guild, test_session):
    response = _post_role(
        http_client,
        test_guild.admin_token,
        test_guild.id,
        name="gen",
        permissions=str(ALL_BITS),
        color=65280,
    )

    assert response.status_code == 201

    role_id = response.json()["id"]

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT guild_id, name, position, permissions, color FROM app.roles WHERE id = %s",
            (role_id,),
        )
        row = cur.fetchone()

    assert row is not None
    assert int(row["guild_id"]) == int(test_guild.id)
    assert row["name"] == "gen"
    assert row["position"] == 1
    assert int.from_bytes(row["permissions"], "big") == ALL_BITS
    assert row["color"] == 65280

    # Visible through the GET collection endpoint.
    api_response = http_client.get(
        f"/api/guilds/{test_guild.id}/roles",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )
    assert api_response.status_code == 200

    roles = api_response.json()
    role = next(role for role in roles if role["id"] == role_id)

    assert role["name"] == "gen"
    assert role["position"] == 1
    assert role["permissions"] == str(ALL_BITS)
    assert role["color"] == 65280


def test_post_role_minimal_payload_defaults(http_client, db_conn, test_guild):
    response = _post_role(
        http_client,
        test_guild.admin_token,
        test_guild.id,
        name="minimal",
        permissions=str(READ_MESSAGES | SEND_MESSAGES),
    )

    assert response.status_code == 201

    role_id = response.json()["id"]

    with db_conn.cursor() as cur:
        cur.execute("SELECT position, color FROM app.roles WHERE id = %s", (role_id,))
        row = cur.fetchone()

    assert row["position"] == 1
    assert row["color"] is None


def test_post_role_name_at_limit_and_color_max(http_client, db_conn, test_guild):
    response = _post_role(
        http_client,
        test_guild.admin_token,
        test_guild.id,
        name="a" * MAX_NAME_CODEPOINTS,
        permissions=str(READ_MESSAGES),
        color=MAX_COLOR,
    )

    assert response.status_code == 201

    body = response.json()

    with db_conn.cursor() as cur:
        cur.execute("SELECT name, color FROM app.roles WHERE id = %s", (body["id"],))
        row = cur.fetchone()

    assert row["name"] == "a" * MAX_NAME_CODEPOINTS
    assert row["color"] == MAX_COLOR


def test_post_role_emits_role_create_event(http_client, test_session, test_guild):
    from test_gateway import GatewayClient

    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_session.access_token}})
    assert ws.recv_json()["op"] == "hello"

    response = _post_role(
        http_client,
        test_guild.admin_token,
        test_guild.id,
        name="evented",
        permissions=str(READ_MESSAGES | SEND_MESSAGES),
    )
    assert response.status_code == 201
    role_id = response.json()["id"]

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "role_created"
    assert event["d"] == {"id": str(role_id), "guild_id": str(test_guild.id)}

    ws.close()


@pytest.mark.parametrize("field", ["color"])
def test_post_role_field_null_is_accepted(http_client, db_conn, test_guild, field):
    response = _post_role(
        http_client,
        test_guild.admin_token,
        test_guild.id,
        name="nullable",
        permissions=str(READ_MESSAGES),
        **{field: None},
    )

    assert response.status_code == 201


# R8b - mentionable defaults to true and can be set false on create
def test_post_role_mentionable_default_true(http_client, test_guild):
    response = _post_role(
        http_client,
        test_guild.admin_token,
        test_guild.id,
        name="mentionable_default",
        permissions=str(READ_MESSAGES),
    )

    assert response.status_code == 201

    role_id = response.json()["id"]

    response = http_client.get(
        f"/api/roles/{role_id}",
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 200
    assert response.json()["mentionable"] is True


def test_post_role_mentionable_false(http_client, test_guild):
    response = _post_role(
        http_client,
        test_guild.admin_token,
        test_guild.id,
        name="not_mentionable",
        permissions=str(READ_MESSAGES),
        mentionable=False,
    )

    assert response.status_code == 201

    role_id = response.json()["id"]

    response = http_client.get(
        f"/api/roles/{role_id}",
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 200
    assert response.json()["mentionable"] is False


def test_post_role_mentionable_not_a_boolean(http_client, test_guild):
    response = _post_role(
        http_client,
        test_guild.admin_token,
        test_guild.id,
        name="bad_mentionable",
        permissions=str(READ_MESSAGES),
        mentionable="yes",
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'mentionable' is not a boolean"
