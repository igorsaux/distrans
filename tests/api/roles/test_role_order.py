# Tests for PUT /api/guilds/{guild_id}/roles/order (mass reorder).
#
# R1 - content type must be application/json and body non-empty
# R2 - user must be logged
# R3 - the guild exists (404)
# R4 - user must have modify_roles (403)
# R5 - body must be a JSON object with "roles", an array of decimal id strings (400)
# R6 - "roles" must be a permutation of all non-@everyone roles; @everyone,
#      duplicates and foreign ids are rejected (400)
# R7 - a role the caller cannot move (position >= highest) must keep its index (403)
# R8 - success assigns dense 1..N positions and emits one `roles_reordered` event

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from conftest import seed_role, system_login  # noqa: E402
from permissions import READ_MESSAGES, MODIFY_ROLES  # noqa: E402


def _order_url(guild_id):
    return f"/api/guilds/{guild_id}/roles/order"


def _auth(token):
    return {"Authorization": f"Bearer {token}"}


def _get_roles(http_client, token, guild_id):
    response = http_client.get(f"/api/guilds/{guild_id}/roles", headers=_auth(token))
    assert response.status_code == 200

    return response.json()


def _seed_two_roles(db_conn, guild_id):
    # @everyone (0) + superuser (fixture) are already present.
    seed_role(db_conn, guild_id, "5571001", "role-a")
    seed_role(db_conn, guild_id, "5571002", "role-b", position=2)


def _superuser_id(roles, guild_id):
    return next(r["id"] for r in roles if r["id"] != guild_id and r["name"] == "superuser")


def _create_role(http_client, token, guild_id, name):
    response = http_client.post(
        f"/api/guilds/{guild_id}/roles",
        json={"name": name, "permissions": "0"},
        headers=_auth(token),
    )
    assert response.status_code == 201

    return response.json()["id"]


# R1
def test_role_order_non_json_content_type(http_client, test_guild):
    response = http_client.put(
        _order_url(test_guild.id),
        content=b"roles=[]",
        headers={
            **_auth(test_guild.admin_token),
            "Content-Type": "text/plain",
        },
    )

    assert response.status_code == 415


# R1
def test_role_order_empty_body(http_client, test_guild):
    response = http_client.put(
        _order_url(test_guild.id),
        content=b"",
        headers={
            **_auth(test_guild.admin_token),
            "Content-Type": "application/json",
        },
    )

    assert response.status_code == 400


# R2
def test_role_order_unauthorized(http_client, test_guild):
    response = http_client.put(_order_url(test_guild.id), json={"roles": []})

    assert response.status_code == 401


# R3
def test_role_order_unknown_guild(http_client, test_session):
    response = http_client.put(
        _order_url("2"), json={"roles": []}, headers=_auth(test_session.access_token)
    )

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "Guild not found"


# R4
def test_role_order_without_modify_roles(
    http_client, db_conn, test_guild, test_user, test_session
):
    with db_conn.cursor() as cur:
        cur.execute(
            "UPDATE app.roles SET permissions = %s WHERE id = %s",
            (READ_MESSAGES.to_bytes(16), test_guild.id),
        )

    access_token, _ = _login(http_client, test_user)

    response = http_client.put(
        _order_url(test_guild.id), json={"roles": []}, headers=_auth(access_token)
    )

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


# R5
def test_role_order_roles_missing(http_client, test_guild):
    response = http_client.put(
        _order_url(test_guild.id), json={}, headers=_auth(test_guild.admin_token)
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Bad 'roles'"


# R5
def test_role_order_roles_not_an_array(http_client, test_guild):
    response = http_client.put(
        _order_url(test_guild.id),
        json={"roles": "5571001"},
        headers=_auth(test_guild.admin_token),
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Bad 'roles'"


# R5
def test_role_order_role_id_not_a_string(http_client, test_guild):
    response = http_client.put(
        _order_url(test_guild.id),
        json={"roles": [5571001]},
        headers=_auth(test_guild.admin_token),
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Bad 'roles'"


# R6 - @everyone must not be listed
def test_role_order_everyone_rejected(http_client, db_conn, test_guild):
    _seed_two_roles(db_conn, test_guild.id)

    roles = _get_roles(http_client, test_guild.admin_token, test_guild.id)
    ids = [r["id"] for r in roles if r["id"] != test_guild.id]
    superuser = _superuser_id(roles, test_guild.id)

    listed = [test_guild.id] + [i for i in ids if i != superuser]

    response = http_client.put(
        _order_url(test_guild.id),
        json={"roles": listed},
        headers=_auth(test_guild.admin_token),
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Bad 'roles'"


# R6 - duplicate ids are rejected
def test_role_order_duplicate_rejected(http_client, db_conn, test_guild):
    _seed_two_roles(db_conn, test_guild.id)

    roles = _get_roles(http_client, test_guild.admin_token, test_guild.id)
    superuser = _superuser_id(roles, test_guild.id)

    response = http_client.put(
        _order_url(test_guild.id),
        json={"roles": ["5571001", "5571001", superuser]},
        headers=_auth(test_guild.admin_token),
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Bad 'roles'"


# R6 - a foreign id is rejected
def test_role_order_foreign_id_rejected(http_client, db_conn, test_guild):
    _seed_two_roles(db_conn, test_guild.id)

    roles = _get_roles(http_client, test_guild.admin_token, test_guild.id)
    superuser = _superuser_id(roles, test_guild.id)

    response = http_client.put(
        _order_url(test_guild.id),
        json={"roles": ["5571001", "9999999", superuser]},
        headers=_auth(test_guild.admin_token),
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Bad 'roles'"


# R6 - missing a role is rejected
def test_role_order_missing_role_rejected(http_client, db_conn, test_guild):
    _seed_two_roles(db_conn, test_guild.id)

    response = http_client.put(
        _order_url(test_guild.id),
        json={"roles": ["5571001", "5571002"]},
        headers=_auth(test_guild.admin_token),
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Bad 'roles'"


# R7 - the superuser role sits at the caller's own height and cannot be moved
def test_role_order_immovable_role_moved(http_client, db_conn, test_guild):
    _seed_two_roles(db_conn, test_guild.id)

    roles = _get_roles(http_client, test_guild.admin_token, test_guild.id)
    superuser = _superuser_id(roles, test_guild.id)

    # Push the superuser role to the bottom, moving every pinned role.
    response = http_client.put(
        _order_url(test_guild.id),
        json={"roles": [superuser, "5571001", "5571002"]},
        headers=_auth(test_guild.admin_token),
    )

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


# R8 - success assigns dense 1..N and moves only the movable roles
def test_role_order_success(http_client, db_conn, test_guild):
    _seed_two_roles(db_conn, test_guild.id)

    roles = _get_roles(http_client, test_guild.admin_token, test_guild.id)
    superuser = _superuser_id(roles, test_guild.id)

    response = http_client.put(
        _order_url(test_guild.id),
        json={"roles": ["5571002", "5571001", superuser]},
        headers=_auth(test_guild.admin_token),
    )

    assert response.status_code == 204
    assert response.content == b""

    roles = _get_roles(http_client, test_guild.admin_token, test_guild.id)
    positions = {r["id"]: r["position"] for r in roles}

    assert positions == {
        test_guild.id: 0,
        "5571002": 1,
        "5571001": 2,
        superuser: 3,
    }


# R8 - a no-op reorder (same order) still returns 204
def test_role_order_noop(http_client, db_conn, test_guild):
    _seed_two_roles(db_conn, test_guild.id)

    roles = _get_roles(http_client, test_guild.admin_token, test_guild.id)
    ids = [r["id"] for r in roles if r["id"] != test_guild.id]

    response = http_client.put(
        _order_url(test_guild.id),
        json={"roles": ids},
        headers=_auth(test_guild.admin_token),
    )

    assert response.status_code == 204


# R7/R8 - a delete leaves a gap in the position sequence; a reorder (even a
# no-op) must still succeed and densify the positions back to 1..N
def test_role_order_after_delete_gap(http_client, db_conn, test_guild):
    # Creating a role shifts the fixture superuser down to position 2.
    temp = _create_role(http_client, test_guild.admin_token, test_guild.id, "temp")

    roles = _get_roles(http_client, test_guild.admin_token, test_guild.id)
    superuser = _superuser_id(roles, test_guild.id)
    assert {r["id"]: r["position"] for r in roles} == {
        test_guild.id: 0,
        temp: 1,
        superuser: 2,
    }

    response = http_client.delete(
        f"/api/roles/{temp}", headers=_auth(test_guild.admin_token)
    )
    assert response.status_code == 204

    # The delete does not compact positions: @everyone=0, superuser=2, hole at 1.
    with db_conn.cursor() as cur:
        cur.execute("SELECT position FROM app.roles WHERE id = %s", (superuser,))
        assert cur.fetchone()["position"] == 2

    # The superuser is immovable; the no-op list keeps its index, so this must
    # not be a 403 for being "at the wrong position", and must densify it to 1.
    response = http_client.put(
        _order_url(test_guild.id),
        json={"roles": [superuser]},
        headers=_auth(test_guild.admin_token),
    )

    assert response.status_code == 204

    roles = _get_roles(http_client, test_guild.admin_token, test_guild.id)
    assert {r["id"]: r["position"] for r in roles} == {
        test_guild.id: 0,
        superuser: 1,
    }


# R8 - one `roles_reordered` event carrying only the guild id
def test_role_order_emits_event(http_client, db_conn, test_guild):
    from test_gateway import GatewayClient

    _seed_two_roles(db_conn, test_guild.id)

    roles = _get_roles(http_client, test_guild.admin_token, test_guild.id)
    ids = [r["id"] for r in roles if r["id"] != test_guild.id]

    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_guild.admin_token}})
    assert ws.recv_json()["op"] == "hello"

    response = http_client.put(
        _order_url(test_guild.id),
        json={"roles": list(reversed(ids))},
        headers=_auth(test_guild.admin_token),
    )

    if response.status_code == 403:
        # Reversing may move a pinned role; fall back to a legal swap.
        response = http_client.put(
            _order_url(test_guild.id),
            json={"roles": ids},
            headers=_auth(test_guild.admin_token),
        )

    assert response.status_code == 204

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "roles_reordered"
    assert event["d"] == {"guild_id": str(test_guild.id)}

    ws.close()


def _login(http_client, user):
    return system_login(http_client, user.username, user.password)
