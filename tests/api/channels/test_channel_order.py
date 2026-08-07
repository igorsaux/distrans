# Tests for PUT /api/guilds/{guild_id}/channels/order (mass reorder by parent).
#
# R1 - content type must be application/json and body non-empty
# R2 - user must be logged
# R3 - the guild exists (404)
# R4 - body must be a JSON object with optional "parent_id" and an array "channels" (400)
# R5 - a set "parent_id" must exist (404), belong to the guild and be a category (400)
# R6 - "channels" must be exactly the children of the scope, each once (400)
# R7 - a channel whose index changes must satisfy modify_channels (403); an
#      unchanged index needs no rights
# R8 - success assigns dense 0..K-1 and emits one `channels_reordered` event

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from conftest import system_create_channel, system_login  # noqa: E402
from permissions import READ_MESSAGES, SEND_MESSAGES  # noqa: E402


def _order_url(guild_id):
    return f"/api/guilds/{guild_id}/channels/order"


def _auth(token):
    return {"Authorization": f"Bearer {token}"}


def _scope_channels(db_conn, guild_id, parent_id):
    with db_conn.cursor() as cur:
        if parent_id is None:
            cur.execute(
                "SELECT id, position FROM app.channels"
                " WHERE guild_id = %s AND parent_id IS NULL"
                " ORDER BY position, id",
                (guild_id,),
            )
        else:
            cur.execute(
                "SELECT id, position FROM app.channels"
                " WHERE guild_id = %s AND parent_id = %s"
                " ORDER BY position, id",
                (guild_id, parent_id),
            )

        return [str(row["id"]) for row in cur.fetchall()]


def _positions(db_conn, guild_id, parent_id):
    with db_conn.cursor() as cur:
        if parent_id is None:
            cur.execute(
                "SELECT id, position FROM app.channels"
                " WHERE guild_id = %s AND parent_id IS NULL",
                (guild_id,),
            )
        else:
            cur.execute(
                "SELECT id, position FROM app.channels"
                " WHERE guild_id = %s AND parent_id = %s",
                (guild_id, parent_id),
            )

        return {str(row["id"]): row["position"] for row in cur.fetchall()}


def _seed_root(http_client, test_guild):
    category = system_create_channel(
        http_client,
        test_guild.id,
        name="RootCat",
        kind="category",
        admin_token=test_guild.admin_token,
    )
    one = system_create_channel(
        http_client, test_guild.id, name="root-one", admin_token=test_guild.admin_token
    )
    two = system_create_channel(
        http_client, test_guild.id, name="root-two", admin_token=test_guild.admin_token
    )

    return category, one, two


# R1
def test_channel_order_non_json_content_type(http_client, test_guild):
    response = http_client.put(
        _order_url(test_guild.id),
        content=b"channels=[]",
        headers={
            **_auth(test_guild.admin_token),
            "Content-Type": "text/plain",
        },
    )

    assert response.status_code == 415


# R1
def test_channel_order_empty_body(http_client, test_guild):
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
def test_channel_order_unauthorized(http_client, test_guild):
    response = http_client.put(_order_url(test_guild.id), json={"channels": []})

    assert response.status_code == 401


# R3
def test_channel_order_unknown_guild(http_client, test_session):
    response = http_client.put(
        _order_url("2"),
        json={"channels": []},
        headers=_auth(test_session.access_token),
    )

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "Guild not found"


# R4
def test_channel_order_channels_missing(http_client, test_guild):
    response = http_client.put(
        _order_url(test_guild.id), json={}, headers=_auth(test_guild.admin_token)
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Bad 'channels'"


# R4
def test_channel_order_channels_not_an_array(http_client, test_guild):
    response = http_client.put(
        _order_url(test_guild.id),
        json={"channels": "1"},
        headers=_auth(test_guild.admin_token),
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Bad 'channels'"


# R5 - unknown parent
def test_channel_order_unknown_parent(http_client, test_guild):
    response = http_client.put(
        _order_url(test_guild.id),
        json={"parent_id": "9999999", "channels": []},
        headers=_auth(test_guild.admin_token),
    )

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "Parent channel not found"


# R5 - parent must be a category
def test_channel_order_parent_not_a_category(http_client, test_guild):
    _category, one, _two = _seed_root(http_client, test_guild)

    response = http_client.put(
        _order_url(test_guild.id),
        json={"parent_id": one.id, "channels": []},
        headers=_auth(test_guild.admin_token),
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Parent channel must be a category"


# R6 - a channel from outside the scope is rejected
def test_channel_order_wrong_scope(http_client, db_conn, test_guild):
    category = system_create_channel(
        http_client,
        test_guild.id,
        name="ScopeCat",
        kind="category",
        admin_token=test_guild.admin_token,
    )
    child = system_create_channel(
        http_client,
        test_guild.id,
        name="scope-child",
        parent_id=category.id,
        admin_token=test_guild.admin_token,
    )
    root = system_create_channel(
        http_client, test_guild.id, name="scope-root", admin_token=test_guild.admin_token
    )

    response = http_client.put(
        _order_url(test_guild.id),
        json={"parent_id": category.id, "channels": [root.id]},
        headers=_auth(test_guild.admin_token),
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Bad 'channels'"


# R7 - moving a channel without modify_channels is forbidden
def test_channel_order_without_rights_moving(
    http_client, db_conn, test_guild, test_user, test_session
):
    _seed_root(http_client, test_guild)

    with db_conn.cursor() as cur:
        cur.execute(
            "UPDATE app.roles SET permissions = %s WHERE id = %s",
            ((READ_MESSAGES | SEND_MESSAGES).to_bytes(16), test_guild.id),
        )

    access_token, _ = system_login(http_client, test_user.username, test_user.password)

    ids = _scope_channels(db_conn, int(test_guild.id), None)

    response = http_client.put(
        _order_url(test_guild.id),
        json={"channels": list(reversed(ids))},
        headers=_auth(access_token),
    )

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


# R7 - an unchanged index needs no rights: a no-op is allowed
def test_channel_order_without_rights_noop(
    http_client, db_conn, test_guild, test_user
):
    _seed_root(http_client, test_guild)

    with db_conn.cursor() as cur:
        cur.execute(
            "UPDATE app.roles SET permissions = %s WHERE id = %s",
            ((READ_MESSAGES | SEND_MESSAGES).to_bytes(16), test_guild.id),
        )

    access_token, _ = system_login(http_client, test_user.username, test_user.password)

    ids = _scope_channels(db_conn, int(test_guild.id), None)

    response = http_client.put(
        _order_url(test_guild.id),
        json={"channels": ids},
        headers=_auth(access_token),
    )

    assert response.status_code == 204


# R8 - success assigns dense 0..K-1 within the root scope
def test_channel_order_success(http_client, db_conn, test_guild):
    category, one, two = _seed_root(http_client, test_guild)

    ids = _scope_channels(db_conn, int(test_guild.id), None)
    reordered = list(reversed(ids))

    response = http_client.put(
        _order_url(test_guild.id),
        json={"channels": reordered},
        headers=_auth(test_guild.admin_token),
    )

    assert response.status_code == 204
    assert response.content == b""

    positions = _positions(db_conn, int(test_guild.id), None)

    assert positions == {channel_id: index for index, channel_id in enumerate(reordered)}


# R8 - success within a category scope
def test_channel_order_category_scope(http_client, db_conn, test_guild):
    category = system_create_channel(
        http_client,
        test_guild.id,
        name="InnerCat",
        kind="category",
        admin_token=test_guild.admin_token,
    )
    first = system_create_channel(
        http_client,
        test_guild.id,
        name="inner-one",
        parent_id=category.id,
        admin_token=test_guild.admin_token,
    )
    second = system_create_channel(
        http_client,
        test_guild.id,
        name="inner-two",
        parent_id=category.id,
        admin_token=test_guild.admin_token,
    )

    reordered = [second.id, first.id]

    response = http_client.put(
        _order_url(test_guild.id),
        json={"parent_id": category.id, "channels": reordered},
        headers=_auth(test_guild.admin_token),
    )

    assert response.status_code == 204

    positions = _positions(db_conn, int(test_guild.id), int(category.id))

    assert positions == {str(second.id): 0, str(first.id): 1}


# R8 - one `channels_reordered` event carrying only the guild id
def test_channel_order_emits_event(http_client, db_conn, test_guild):
    from test_gateway import GatewayClient

    _seed_root(http_client, test_guild)

    ids = _scope_channels(db_conn, int(test_guild.id), None)

    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_guild.admin_token}})
    assert ws.recv_json()["op"] == "hello"

    response = http_client.put(
        _order_url(test_guild.id),
        json={"channels": list(reversed(ids))},
        headers=_auth(test_guild.admin_token),
    )
    assert response.status_code == 204

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "channels_reordered"
    assert event["d"] == {"guild_id": str(test_guild.id)}

    ws.close()
