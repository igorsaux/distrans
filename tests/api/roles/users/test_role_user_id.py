# Tests for PUT / DELETE /api/roles/{role_id}/users/{user_id}.
#
# PUT:
# R1 - user must be logged (401)
# R2 - the role exists (404 "Role not found")
# R3 - the target user exists and is not soft-deleted (404 "User not found")
# R4 - the role is not @everyone (400 "Cannot grant the @everyone role")
# R5 - user must have grant_roles (403 "Missing permissions")
# R6 - role hierarchy (403 "Missing permissions"):
#      a) the role's position must be strictly below the caller's highest
#      b) the caller's highest position must be strictly above the target's
# R7 - idempotency: granting a role the member already has is a 204 no-op
# R8 - success: 204, row in app.member_roles, emits `role_granted`
#
# DELETE mirrors PUT (R4 "Cannot revoke the @everyone role", R5 revoke_roles).
#
# The test_guild fixture grants its admin a superuser role at MAX_POSITION
# (highest = MAX_POSITION); test_user has no roles (highest = 0). Roles to
# grant are created at position 0.

import socket
import sys
from pathlib import Path

import pytest

from conftest import seed_role, system_login

# GatewayClient lives in tests/api/test_gateway.py; make it importable when
# this file is run standalone (not as part of the full suite).
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from permissions import READ_MESSAGES, SEND_MESSAGES, GRANT_ROLES, REVOKE_ROLES

# Upper bound of app.roles.position (SMALLINT); the fixture admin's superuser
# role sits here, leaving every custom role below it.
MAX_POSITION = 32767


def _set_everyone_permissions(db_conn, guild_id, permissions):
    with db_conn.cursor() as cur:
        cur.execute(
            "UPDATE app.roles SET permissions = %s WHERE id = %s",
            (permissions.to_bytes(16), guild_id),
        )


def _create_role(db_conn, guild_id, role_id, name, position=0, permissions=0):
    seed_role(db_conn, guild_id, role_id, name, position, permissions)


def _assign_role(db_conn, guild_id, user_id, role_id):
    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.member_roles (guild_id, role_id, user_id)"
            " VALUES (%s, %s, %s)",
            (guild_id, role_id, user_id),
        )


def _member_role_rows(db_conn, guild_id, user_id, role_id):
    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT 1 FROM app.member_roles"
            " WHERE guild_id = %s AND user_id = %s AND role_id = %s",
            (guild_id, user_id, role_id),
        )
        return cur.fetchall()


def _create_plain_user(http_client, system_headers, username):
    response = http_client.post(
        "/api/system/users",
        json={"username": username, "password": "12345678"},
        headers=system_headers,
    )
    assert response.status_code == 201

    return response.json()["id"]


def _role_user_url(role_id, user_id):
    return f"/api/roles/{role_id}/users/{user_id}"


# ---------------------------------------------------------------------------
# PUT
# ---------------------------------------------------------------------------


# R1
def test_put_role_user_unauthorized(http_client, test_guild, test_user):
    response = http_client.put(_role_user_url("5580001", test_user.id))

    assert response.status_code == 401


# Router: malformed role_id is rejected with 400 before auth
def test_put_role_user_malformed_role_id(http_client, test_guild, test_user):
    response = http_client.put(
        _role_user_url("abc", test_user.id),
        headers={"Authorization": "Bearer whatever"},
    )

    assert response.status_code == 400


# Router: malformed user_id is rejected with 400 before auth
def test_put_role_user_malformed_user_id(http_client, test_guild):
    response = http_client.put(
        _role_user_url("5580001", "abc"),
        headers={"Authorization": "Bearer whatever"},
    )

    assert response.status_code == 400


# R2
def test_put_role_user_role_not_found(http_client, test_guild, test_user):
    response = http_client.put(
        _role_user_url("999999", test_user.id),
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "Role not found"


# R3
def test_put_role_user_user_not_found(http_client, db_conn, test_guild):
    _create_role(db_conn, test_guild.id, "5580001", "target")

    response = http_client.put(
        _role_user_url("5580001", "999999"),
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "User not found"


# R3 - a soft-deleted target user is reported as 404
def test_put_role_user_soft_deleted_user(
    http_client, db_conn, system_headers, test_guild
):
    user_id = _create_plain_user(http_client, system_headers, "goneaway")
    _create_role(db_conn, test_guild.id, "5580001", "target")

    response = http_client.delete(
        f"/api/system/users/{user_id}", headers=system_headers
    )
    assert response.status_code == 204

    response = http_client.put(
        _role_user_url("5580001", user_id),
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "User not found"


# R4
def test_put_role_user_everyone(http_client, test_guild, test_user):
    response = http_client.put(
        _role_user_url(test_guild.id, test_user.id),
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Cannot grant the @everyone role"


# R5 - @everyone lacks grant_roles
def test_put_role_user_without_grant_roles(
    http_client, db_conn, test_guild, test_user, system_headers
):
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES | SEND_MESSAGES)
    _create_role(db_conn, test_guild.id, "5580001", "target")

    access_token, _ = system_login(http_client, test_user.username, test_user.password)

    response = http_client.put(
        _role_user_url("5580001", test_user.id),
        headers={"Authorization": f"Bearer {access_token}"},
    )

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


# R6a - a role at position >= caller's highest position cannot be granted
def test_put_role_user_hierarchy_position(http_client, db_conn, test_guild, test_user):
    _create_role(db_conn, test_guild.id, "5580002", "rival", position=MAX_POSITION)

    response = http_client.put(
        _role_user_url("5580002", test_user.id),
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


# R6b - cannot grant a role to a member whose highest position is >= caller's
def test_put_role_user_hierarchy_target(http_client, db_conn, test_guild, test_user):
    _create_role(db_conn, test_guild.id, "5580003", "target")
    _create_role(db_conn, test_guild.id, "5580004", "rival", position=MAX_POSITION)
    _assign_role(db_conn, test_guild.id, test_user.id, "5580004")

    response = http_client.put(
        _role_user_url("5580003", test_user.id),
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


# R6 - success path: a caller whose grant_roles comes from a role above the
# target role can grant that target role to a member below them
def test_put_role_user_rights_success_path(
    http_client, db_conn, test_guild, test_user, system_headers
):
    target_id = _create_plain_user(http_client, system_headers, "grantee")

    _create_role(
        db_conn,
        test_guild.id,
        "5580005",
        "granter",
        position=1,
        permissions=GRANT_ROLES,
    )
    _assign_role(db_conn, test_guild.id, test_user.id, "5580005")
    _create_role(db_conn, test_guild.id, "5580006", "target")

    access_token, _ = system_login(http_client, test_user.username, test_user.password)

    response = http_client.put(
        _role_user_url("5580006", target_id),
        headers={"Authorization": f"Bearer {access_token}"},
    )

    assert response.status_code == 204
    assert response.content == b""

    assert len(_member_role_rows(db_conn, test_guild.id, target_id, "5580006")) == 1


# R7 - granting a role the member already has is a 204 no-op with one row
def test_put_role_user_idempotent(http_client, db_conn, test_guild, test_user):
    _create_role(db_conn, test_guild.id, "5580007", "target")
    _assign_role(db_conn, test_guild.id, test_user.id, "5580007")

    response = http_client.put(
        _role_user_url("5580007", test_user.id),
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )
    assert response.status_code == 204

    response = http_client.put(
        _role_user_url("5580007", test_user.id),
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 204
    assert response.content == b""
    assert len(_member_role_rows(db_conn, test_guild.id, test_user.id, "5580007")) == 1


# R8 - success: 204, row in app.member_roles, visible via GET member roles
def test_put_role_user_success(
    http_client, db_conn, test_guild, test_user, test_session
):
    _create_role(db_conn, test_guild.id, "5580008", "granted")

    response = http_client.put(
        _role_user_url("5580008", test_user.id),
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 204
    assert response.content == b""

    assert len(_member_role_rows(db_conn, test_guild.id, test_user.id, "5580008")) == 1

    api_response = http_client.get(
        f"/api/guilds/{test_guild.id}/members/{test_user.id}/roles",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )
    assert api_response.status_code == 200
    assert "5580008" in api_response.json()


# ---------------------------------------------------------------------------
# DELETE
# ---------------------------------------------------------------------------


# R1
def test_delete_role_user_unauthorized(http_client, test_guild, test_user):
    response = http_client.delete(_role_user_url("5590001", test_user.id))

    assert response.status_code == 401


# Router: malformed user_id is rejected with 400 before auth
def test_delete_role_user_malformed_user_id(http_client, test_guild):
    response = http_client.delete(
        _role_user_url("5590001", "abc"),
        headers={"Authorization": "Bearer whatever"},
    )

    assert response.status_code == 400


# R2
def test_delete_role_user_role_not_found(http_client, test_guild, test_user):
    response = http_client.delete(
        _role_user_url("999999", test_user.id),
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "Role not found"


# R3
def test_delete_role_user_user_not_found(http_client, db_conn, test_guild):
    _create_role(db_conn, test_guild.id, "5590001", "target")

    response = http_client.delete(
        _role_user_url("5590001", "999999"),
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "User not found"


# R3 - a soft-deleted target user is reported as 404
def test_delete_role_user_soft_deleted_user(
    http_client, db_conn, system_headers, test_guild
):
    user_id = _create_plain_user(http_client, system_headers, "gonedeeper")

    _create_role(db_conn, test_guild.id, "5590002", "target")
    _assign_role(db_conn, test_guild.id, user_id, "5590002")

    response = http_client.delete(
        f"/api/system/users/{user_id}", headers=system_headers
    )
    assert response.status_code == 204

    response = http_client.delete(
        _role_user_url("5590002", user_id),
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "User not found"


# R4
def test_delete_role_user_everyone(http_client, test_guild, test_user):
    response = http_client.delete(
        _role_user_url(test_guild.id, test_user.id),
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Cannot revoke the @everyone role"


# R5 - @everyone lacks revoke_roles
def test_delete_role_user_without_revoke_roles(
    http_client, db_conn, test_guild, test_user, system_headers
):
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES | SEND_MESSAGES)
    _create_role(db_conn, test_guild.id, "5590003", "target")
    _assign_role(db_conn, test_guild.id, test_user.id, "5590003")

    access_token, _ = system_login(http_client, test_user.username, test_user.password)

    response = http_client.delete(
        _role_user_url("5590003", test_user.id),
        headers={"Authorization": f"Bearer {access_token}"},
    )

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


# R6a - a role at position >= caller's highest position cannot be revoked
def test_delete_role_user_hierarchy_position(
    http_client, db_conn, test_guild, test_user
):
    _create_role(db_conn, test_guild.id, "5590004", "rival", position=MAX_POSITION)
    _assign_role(db_conn, test_guild.id, test_user.id, "5590004")

    response = http_client.delete(
        _role_user_url("5590004", test_user.id),
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


# R6b - cannot revoke a role from a member whose highest position is >= caller's
def test_delete_role_user_hierarchy_target(
    http_client, db_conn, test_guild, test_user
):
    _create_role(db_conn, test_guild.id, "5590005", "target")
    _assign_role(db_conn, test_guild.id, test_user.id, "5590005")
    _create_role(db_conn, test_guild.id, "5590006", "rival", position=MAX_POSITION)
    _assign_role(db_conn, test_guild.id, test_user.id, "5590006")

    response = http_client.delete(
        _role_user_url("5590005", test_user.id),
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


# R7 - revoking a role the member does not have is a 204 no-op
def test_delete_role_user_idempotent(http_client, db_conn, test_guild, test_user):
    _create_role(db_conn, test_guild.id, "5590007", "target")

    response = http_client.delete(
        _role_user_url("5590007", test_user.id),
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 204
    assert response.content == b""
    assert len(_member_role_rows(db_conn, test_guild.id, test_user.id, "5590007")) == 0


# R8 - success: 204, row removed from app.member_roles
def test_delete_role_user_success(http_client, db_conn, test_guild, test_user):
    _create_role(db_conn, test_guild.id, "5590008", "revoked")
    _assign_role(db_conn, test_guild.id, test_user.id, "5590008")

    response = http_client.delete(
        _role_user_url("5590008", test_user.id),
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 204
    assert response.content == b""

    assert len(_member_role_rows(db_conn, test_guild.id, test_user.id, "5590008")) == 0


# R5 - exact-bit success path: a caller whose only role bit is revoke_roles
# (bit 10) can revoke a role below them
def test_delete_role_user_rights_success_path(
    http_client, db_conn, test_guild, test_user, system_headers
):
    revokee_id = _create_plain_user(http_client, system_headers, "revokee")

    _create_role(db_conn, test_guild.id, "5590009", "target")
    _assign_role(db_conn, test_guild.id, revokee_id, "5590009")
    _create_role(
        db_conn,
        test_guild.id,
        "5590010",
        "revoker",
        position=2,
        permissions=REVOKE_ROLES,
    )
    _assign_role(db_conn, test_guild.id, test_user.id, "5590010")

    access_token, _ = system_login(http_client, test_user.username, test_user.password)

    response = http_client.delete(
        _role_user_url("5590009", revokee_id),
        headers={"Authorization": f"Bearer {access_token}"},
    )

    assert response.status_code == 204
    assert response.content == b""

    assert len(_member_role_rows(db_conn, test_guild.id, revokee_id, "5590009")) == 0


# ---------------------------------------------------------------------------
# Gateway events
# ---------------------------------------------------------------------------


# R8 - PUT success emits exactly one `role_grant` dispatch
def test_put_role_user_emits_role_grant_event(
    http_client, db_conn, test_guild, test_user
):
    from test_gateway import GatewayClient

    _create_role(db_conn, test_guild.id, "5600001", "evented")

    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_guild.admin_token}})
    assert ws.recv_json()["op"] == "hello"

    response = http_client.put(
        _role_user_url("5600001", test_user.id),
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )
    assert response.status_code == 204

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "role_granted"
    assert event["d"] == {
        "id": "5600001",
        "guild_id": str(test_guild.id),
        "user_id": str(test_user.id),
    }

    # Regression: exactly one event must be dispatched (no double raise)
    with pytest.raises(socket.timeout):
        ws.recv_json(timeout=1.0)

    ws.close()


# R7 - the idempotent PUT no-op must not emit any event
def test_put_role_user_idempotent_emits_no_event(
    http_client, db_conn, test_guild, test_user
):
    from test_gateway import GatewayClient

    _create_role(db_conn, test_guild.id, "5600002", "evented")
    _assign_role(db_conn, test_guild.id, test_user.id, "5600002")

    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_guild.admin_token}})
    assert ws.recv_json()["op"] == "hello"

    response = http_client.put(
        _role_user_url("5600002", test_user.id),
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )
    assert response.status_code == 204

    with pytest.raises(socket.timeout):
        ws.recv_json(timeout=1.0)

    ws.close()


# R8 - DELETE success emits exactly one `role_revoke` dispatch
def test_delete_role_user_emits_role_revoke_event(
    http_client, db_conn, test_guild, test_user
):
    from test_gateway import GatewayClient

    _create_role(db_conn, test_guild.id, "5600003", "evented")
    _assign_role(db_conn, test_guild.id, test_user.id, "5600003")

    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_guild.admin_token}})
    assert ws.recv_json()["op"] == "hello"

    response = http_client.delete(
        _role_user_url("5600003", test_user.id),
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )
    assert response.status_code == 204

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "role_revoked"
    assert event["d"] == {
        "id": "5600003",
        "guild_id": str(test_guild.id),
        "user_id": str(test_user.id),
    }

    # Regression: exactly one event must be dispatched (no double raise)
    with pytest.raises(socket.timeout):
        ws.recv_json(timeout=1.0)

    ws.close()
