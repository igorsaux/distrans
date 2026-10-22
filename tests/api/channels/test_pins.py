# Tests for /api/channels/{channel_id}/pins (GET) and
# /api/channels/{channel_id}/pins/{message_id} (PUT, DELETE).
#
# GET    - R1 logged in; R2 channel exists; R3 read_messages on the channel;
#          R4 keyset-paginated pinned message ids (limit/before/after)
# GET /pins/messages - same auth/permissions and pagination, but full pinned
#          message objects (pinned and non-deleted only, ascending)
# PUT    - R1 logged in; R2 channel exists; R3 read_messages + add_pins; R4
#          message exists in the channel; R5 idempotent pin + message_pinned
#          event
# DELETE - R1 logged in; R2 channel exists; R3 read_messages + delete_pins; R4
#          message exists in the channel; R5 idempotent unpin +
#          message_unpinned event

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from conftest import (  # noqa: E402
    seed_role,
    system_create_channel,
)

from permissions import (  # noqa: E402
    ADD_PINS,
    DELETE_PINS,
    READ_MESSAGES,
)


def _auth(token):
    return {"Authorization": f"Bearer {token}"}


def _pins_url(channel_id):
    return f"/api/channels/{channel_id}/pins"


def _pin_url(channel_id, message_id):
    return f"/api/channels/{channel_id}/pins/{message_id}"


def _pins_messages_url(channel_id):
    return f"/api/channels/{channel_id}/pins/messages"


def _list(http_client, token, channel_id, **params):
    return http_client.get(_pins_url(channel_id), headers=_auth(token), params=params)


def _list_messages(http_client, token, channel_id, **params):
    return http_client.get(
        _pins_messages_url(channel_id), headers=_auth(token), params=params
    )


def _put(http_client, token, channel_id, message_id):
    return http_client.put(_pin_url(channel_id, message_id), headers=_auth(token))


def _delete(http_client, token, channel_id, message_id):
    return http_client.delete(_pin_url(channel_id, message_id), headers=_auth(token))


def _insert_message(db_conn, channel_id, author_id, message_id, pinned=False):
    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.messages (id, channel_id, guild_id, author_id, content, pinned)"
            " SELECT %s, c.id, c.guild_id, %s, %s, %s FROM app.channels c WHERE c.id = %s",
            (message_id, author_id, f"msg-{message_id}", pinned, channel_id),
        )


def _soft_delete_message(db_conn, message_id):
    with db_conn.cursor() as cur:
        cur.execute(
            "UPDATE app.messages SET deleted_at = NOW(), content = '' WHERE id = %s",
            (message_id,),
        )


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
            "INSERT INTO app.member_roles (guild_id, user_id, role_id)"
            " VALUES (%s, %s, %s)",
            (guild_id, user_id, role_id),
        )


@pytest.fixture
def pin_permissions(db_conn, test_guild, test_user):
    """Grant the caller both pin bits (success-path tests only)."""
    _create_role(
        db_conn, test_guild.id, "9000001", "pins", permissions=ADD_PINS | DELETE_PINS
    )
    _assign_role(db_conn, test_guild.id, test_user.id, "9000001")


# ---------------------------------------------------------------------------
# GET
# ---------------------------------------------------------------------------


def test_get_pins_unauthorized(http_client, test_channel):
    response = http_client.get(_pins_url(test_channel.id))

    assert response.status_code == 401


def test_get_pins_non_existent_channel(http_client, test_session):
    response = _list(http_client, test_session.access_token, "1")

    assert response.status_code == 404
    assert response.json()["message"] == "Channel not found"


def test_get_pins_unknown_parameter(http_client, test_channel, test_session):
    response = _list(http_client, test_session.access_token, test_channel.id, foobar=2)

    assert response.status_code == 400
    assert response.json()["message"] == "Unknown parameter"


@pytest.mark.parametrize(
    "param_key,param_value",
    [
        ("limit", "foo"),
        ("before", "foo"),
        ("after", "foo"),
    ],
)
def test_get_pins_bad_parameter(
    http_client, test_channel, test_session, param_key, param_value
):
    response = _list(
        http_client, test_session.access_token, test_channel.id, **{param_key: param_value}
    )

    assert response.status_code == 400
    assert response.json()["message"] == f"Bad '{param_key}' parameter"


def test_get_pins_mutually_exclusive(http_client, test_channel, test_session):
    response = _list(
        http_client, test_session.access_token, test_channel.id, before="1", after="2"
    )

    assert response.status_code == 400
    assert response.json()["message"] == (
        "Parameters 'before' and 'after' are mutually exclusive"
    )


def test_get_pins_bad_limit_range(http_client, test_channel, test_session):
    response = _list(http_client, test_session.access_token, test_channel.id, limit=0)

    assert response.status_code == 400
    assert response.json()["message"] == "Bad 'limit' parameter"


# R3
def test_get_pins_forbidden_without_read_messages(
    db_conn, http_client, test_guild, test_channel, test_session
):
    _set_everyone_permissions(db_conn, test_guild.id, 0)

    response = _list(http_client, test_session.access_token, test_channel.id)

    assert response.status_code == 403
    assert response.json()["message"] == "Missing permissions"


# R3 (success path pins the read_messages bit)
def test_get_pins_allowed_by_exact_read_messages_role(
    db_conn, http_client, test_guild, test_channel, test_session, test_user
):
    _set_everyone_permissions(db_conn, test_guild.id, 0)
    _create_role(db_conn, test_guild.id, "8000001", "readers", permissions=READ_MESSAGES)
    _assign_role(db_conn, test_guild.id, test_user.id, "8000001")

    response = _list(http_client, test_session.access_token, test_channel.id)

    assert response.status_code == 200


# R4
def test_get_pins_lists_ids_ascending(
    db_conn, http_client, test_channel, test_user, test_session
):
    _insert_message(db_conn, test_channel.id, test_user.id, "1001", pinned=True)
    _insert_message(db_conn, test_channel.id, test_user.id, "1002", pinned=False)
    _insert_message(db_conn, test_channel.id, test_user.id, "1003", pinned=True)

    response = _list(http_client, test_session.access_token, test_channel.id)

    assert response.status_code == 200
    assert response.json() == ["1001", "1003"]


# R4
def test_get_pins_keyset_pagination(
    db_conn, http_client, test_channel, test_user, test_session
):
    for mid in ("2001", "2002", "2003", "2004"):
        _insert_message(db_conn, test_channel.id, test_user.id, mid, pinned=True)

    # Default (no anchor) is "last": the newest `limit` pins, ascending.
    response = _list(http_client, test_session.access_token, test_channel.id, limit=2)

    assert response.status_code == 200
    assert response.json() == ["2003", "2004"]

    response = _list(
        http_client, test_session.access_token, test_channel.id, before="2003"
    )

    assert response.json() == ["2001", "2002"]

    response = _list(
        http_client, test_session.access_token, test_channel.id, after="2002"
    )

    assert response.json() == ["2003", "2004"]


# R4
def test_get_pins_empty(db_conn, http_client, test_channel, test_user, test_session):
    _insert_message(db_conn, test_channel.id, test_user.id, "3001", pinned=False)

    response = _list(http_client, test_session.access_token, test_channel.id)

    assert response.status_code == 200
    assert response.json() == []


# ---------------------------------------------------------------------------
# GET /pins/messages
# ---------------------------------------------------------------------------


def test_get_pinned_messages_unauthorized(http_client, test_channel):
    response = http_client.get(_pins_messages_url(test_channel.id))

    assert response.status_code == 401


def test_get_pinned_messages_non_existent_channel(http_client, test_session):
    response = _list_messages(http_client, test_session.access_token, "1")

    assert response.status_code == 404
    assert response.json()["message"] == "Channel not found"


def test_get_pinned_messages_unknown_parameter(
    http_client, test_channel, test_session
):
    response = _list_messages(
        http_client, test_session.access_token, test_channel.id, foobar=2
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Unknown parameter"


@pytest.mark.parametrize(
    "param_key,param_value",
    [
        ("limit", "foo"),
        ("before", "foo"),
        ("after", "foo"),
    ],
)
def test_get_pinned_messages_bad_parameter(
    http_client, test_channel, test_session, param_key, param_value
):
    response = _list_messages(
        http_client, test_session.access_token, test_channel.id, **{param_key: param_value}
    )

    assert response.status_code == 400
    assert response.json()["message"] == f"Bad '{param_key}' parameter"


def test_get_pinned_messages_mutually_exclusive(
    http_client, test_channel, test_session
):
    response = _list_messages(
        http_client, test_session.access_token, test_channel.id, before="1", after="2"
    )

    assert response.status_code == 400
    assert response.json()["message"] == (
        "Parameters 'before' and 'after' are mutually exclusive"
    )


def test_get_pinned_messages_bad_limit_range(
    http_client, test_channel, test_session
):
    response = _list_messages(
        http_client, test_session.access_token, test_channel.id, limit=0
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Bad 'limit' parameter"


# R3
def test_get_pinned_messages_forbidden_without_read_messages(
    db_conn, http_client, test_guild, test_channel, test_session
):
    _set_everyone_permissions(db_conn, test_guild.id, 0)

    response = _list_messages(http_client, test_session.access_token, test_channel.id)

    assert response.status_code == 403
    assert response.json()["message"] == "Missing permissions"


# R4
def test_get_pinned_messages_lists_pinned_non_deleted_ascending(
    db_conn, http_client, test_channel, test_user, test_session
):
    _insert_message(db_conn, test_channel.id, test_user.id, "1001", pinned=True)
    _insert_message(db_conn, test_channel.id, test_user.id, "1002", pinned=False)
    _insert_message(db_conn, test_channel.id, test_user.id, "1003", pinned=True)
    _insert_message(db_conn, test_channel.id, test_user.id, "1004", pinned=True)
    _soft_delete_message(db_conn, "1004")

    response = _list_messages(http_client, test_session.access_token, test_channel.id)

    assert response.status_code == 200

    body = response.json()
    assert [message["id"] for message in body] == ["1001", "1003"]
    assert all(message["pinned"] is True for message in body)

    assert body[0]["channel_id"] == str(test_channel.id)
    assert body[0]["content"] == "msg-1001"


# R4
def test_get_pinned_messages_keyset_pagination(
    db_conn, http_client, test_channel, test_user, test_session
):
    for mid in ("2001", "2002", "2003", "2004"):
        _insert_message(db_conn, test_channel.id, test_user.id, mid, pinned=True)

    # Default (no anchor) is "last": the newest `limit` pins, ascending.
    response = _list_messages(
        http_client, test_session.access_token, test_channel.id, limit=2
    )

    assert response.status_code == 200
    assert [message["id"] for message in response.json()] == ["2003", "2004"]

    response = _list_messages(
        http_client, test_session.access_token, test_channel.id, before="2003"
    )

    assert [message["id"] for message in response.json()] == ["2001", "2002"]

    response = _list_messages(
        http_client, test_session.access_token, test_channel.id, after="2002"
    )

    assert [message["id"] for message in response.json()] == ["2003", "2004"]


# R4
def test_get_pinned_messages_empty(
    db_conn, http_client, test_channel, test_user, test_session
):
    _insert_message(db_conn, test_channel.id, test_user.id, "3002", pinned=False)

    response = _list_messages(http_client, test_session.access_token, test_channel.id)

    assert response.status_code == 200
    assert response.json() == []


# ---------------------------------------------------------------------------
# PUT
# ---------------------------------------------------------------------------


def test_put_pin_unauthorized(http_client, test_channel, test_message):
    response = http_client.put(_pin_url(test_channel.id, test_message.id))

    assert response.status_code == 401


def test_put_pin_non_existent_channel(http_client, test_session, test_message):
    response = _put(http_client, test_session.access_token, "1", test_message.id)

    assert response.status_code == 404
    assert response.json()["message"] == "Channel not found"


# R3
def test_put_pin_forbidden_without_add_pins(
    db_conn, http_client, test_guild, test_channel, test_message, test_session
):
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES)

    response = _put(http_client, test_session.access_token, test_channel.id, test_message.id)

    assert response.status_code == 403
    assert response.json()["message"] == "Missing permissions"


# R3 - read_messages is required even with add_pins
def test_put_pin_forbidden_without_read_messages(
    db_conn, http_client, test_guild, test_channel, test_message, test_session
):
    _set_everyone_permissions(db_conn, test_guild.id, ADD_PINS)

    response = _put(http_client, test_session.access_token, test_channel.id, test_message.id)

    assert response.status_code == 403
    assert response.json()["message"] == "Missing permissions"


# R3 (success path pins the add_pins bit)
def test_put_pin_allowed_by_exact_add_pins_role(
    db_conn, http_client, test_guild, test_channel, test_message, test_session, test_user
):
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES)
    _create_role(db_conn, test_guild.id, "8000002", "pinners", permissions=ADD_PINS)
    _assign_role(db_conn, test_guild.id, test_user.id, "8000002")

    response = _put(http_client, test_session.access_token, test_channel.id, test_message.id)

    assert response.status_code == 204

    body = _list(http_client, test_session.access_token, test_channel.id).json()
    assert body == [str(test_message.id)]


# R4
def test_put_pin_message_outside_channel(
    db_conn, http_client, test_guild, test_channel, test_session, test_user,
    pin_permissions,
):
    other = system_create_channel(
        http_client, test_guild.id, name="OtherChannel", admin_token=test_guild.admin_token
    )
    _insert_message(db_conn, other.id, test_user.id, "4001", pinned=False)

    response = _put(http_client, test_session.access_token, test_channel.id, "4001")

    assert response.status_code == 404
    assert response.json()["message"] == "Message not found"


# R4
def test_put_pin_missing_message(
    http_client, test_channel, test_session, pin_permissions
):
    response = _put(http_client, test_session.access_token, test_channel.id, "999999")

    assert response.status_code == 404
    assert response.json()["message"] == "Message not found"


# R5 - idempotent
def test_put_pin_idempotent(
    db_conn, http_client, test_channel, test_message, test_session, test_user,
    pin_permissions,
):
    response = _put(http_client, test_session.access_token, test_channel.id, test_message.id)
    assert response.status_code == 204

    response = _put(http_client, test_session.access_token, test_channel.id, test_message.id)
    assert response.status_code == 204

    body = _list(http_client, test_session.access_token, test_channel.id).json()
    assert body == [str(test_message.id)]


# R5
def test_put_pin_reflected_on_message(
    http_client, test_channel, test_message, test_session, pin_permissions
):
    response = _put(http_client, test_session.access_token, test_channel.id, test_message.id)
    assert response.status_code == 204

    body = http_client.get(
        f"/api/messages/{test_message.id}", headers=_auth(test_session.access_token)
    ).json()

    assert body["pinned"] is True

    body = http_client.get(
        f"/api/channels/{test_channel.id}/messages",
        headers=_auth(test_session.access_token),
    ).json()

    assert body[0]["pinned"] is True


# ---------------------------------------------------------------------------
# DELETE
# ---------------------------------------------------------------------------


def test_delete_pin_unauthorized(http_client, test_channel, test_message):
    response = http_client.delete(_pin_url(test_channel.id, test_message.id))

    assert response.status_code == 401


def test_delete_pin_non_existent_channel(http_client, test_session, test_message):
    response = _delete(http_client, test_session.access_token, "1", test_message.id)

    assert response.status_code == 404
    assert response.json()["message"] == "Channel not found"


# R3
def test_delete_pin_forbidden_without_delete_pins(
    db_conn,
    http_client,
    test_guild,
    test_channel,
    test_session,
    test_user,
):
    _insert_message(db_conn, test_channel.id, test_user.id, "5002", pinned=True)
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES)

    response = _delete(http_client, test_session.access_token, test_channel.id, "5002")

    assert response.status_code == 403
    assert response.json()["message"] == "Missing permissions"


# R3 - read_messages is required even with delete_pins
def test_delete_pin_forbidden_without_read_messages(
    db_conn,
    http_client,
    test_guild,
    test_channel,
    test_session,
    test_user,
):
    _insert_message(db_conn, test_channel.id, test_user.id, "5003", pinned=True)
    _set_everyone_permissions(db_conn, test_guild.id, DELETE_PINS)

    response = _delete(http_client, test_session.access_token, test_channel.id, "5003")

    assert response.status_code == 403
    assert response.json()["message"] == "Missing permissions"


# R3 (success path pins the delete_pins bit)
def test_delete_pin_allowed_by_exact_delete_pins_role(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    _insert_message(db_conn, test_channel.id, test_user.id, "5001", pinned=True)
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES)
    _create_role(db_conn, test_guild.id, "8000003", "unpinners", permissions=DELETE_PINS)
    _assign_role(db_conn, test_guild.id, test_user.id, "8000003")

    response = _delete(http_client, test_session.access_token, test_channel.id, "5001")

    assert response.status_code == 204

    body = _list(http_client, test_session.access_token, test_channel.id).json()
    assert body == []


# R4
def test_delete_pin_missing_message(
    http_client, test_channel, test_session, pin_permissions
):
    response = _delete(http_client, test_session.access_token, test_channel.id, "999999")

    assert response.status_code == 404
    assert response.json()["message"] == "Message not found"


# R5 - idempotent (unpinning an absent pin still succeeds)
def test_delete_pin_idempotent(
    db_conn, http_client, test_channel, test_message, test_session, pin_permissions
):
    response = _put(http_client, test_session.access_token, test_channel.id, test_message.id)
    assert response.status_code == 204

    response = _delete(http_client, test_session.access_token, test_channel.id, test_message.id)
    assert response.status_code == 204

    response = _delete(http_client, test_session.access_token, test_channel.id, test_message.id)
    assert response.status_code == 204

    body = _list(http_client, test_session.access_token, test_channel.id).json()
    assert body == []


# R5 - soft-deleting a message drops the pin
def test_soft_delete_drops_pin(
    http_client, test_channel, test_message, test_session, pin_permissions
):
    _put(http_client, test_session.access_token, test_channel.id, test_message.id)

    response = http_client.delete(
        f"/api/messages/{test_message.id}", headers=_auth(test_session.access_token)
    )
    assert response.status_code == 204

    body = _list(http_client, test_session.access_token, test_channel.id).json()
    assert body == []


# ---------------------------------------------------------------------------
# Gateway events
# ---------------------------------------------------------------------------


def test_message_pinned_event(
    http_client, test_message, test_session, test_channel, test_guild, pin_permissions
):
    from test_gateway import GatewayClient

    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_session.access_token}})
    assert ws.recv_json()["op"] == "hello"

    response = _put(http_client, test_session.access_token, test_channel.id, test_message.id)
    assert response.status_code == 204

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "message_pinned"
    assert event["d"] == {
        "id": str(test_message.id),
        "channel_id": str(test_channel.id),
        "guild_id": str(test_guild.id),
    }

    ws.close()


def test_message_unpinned_event(
    http_client, test_message, test_session, test_channel, test_guild, pin_permissions
):
    from test_gateway import GatewayClient

    _put(http_client, test_session.access_token, test_channel.id, test_message.id)

    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_session.access_token}})
    assert ws.recv_json()["op"] == "hello"

    response = _delete(http_client, test_session.access_token, test_channel.id, test_message.id)
    assert response.status_code == 204

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "message_unpinned"
    assert event["d"] == {
        "id": str(test_message.id),
        "channel_id": str(test_channel.id),
        "guild_id": str(test_guild.id),
    }

    ws.close()


def test_pin_no_op_event(
    http_client, test_message, test_session, test_channel, pin_permissions
):
    from test_gateway import GatewayClient

    # First put actually pins and raises; drain its event.
    _put(http_client, test_session.access_token, test_channel.id, test_message.id)

    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_session.access_token}})
    assert ws.recv_json()["op"] == "hello"

    # A second put is a no-op and must emit no event.
    response = _put(http_client, test_session.access_token, test_channel.id, test_message.id)
    assert response.status_code == 204

    # Unpinning once works, then a repeat unpin emits nothing.
    response = _delete(http_client, test_session.access_token, test_channel.id, test_message.id)
    assert response.status_code == 204
    event = ws.recv_json()
    assert event["t"] == "message_unpinned"

    response = _delete(http_client, test_session.access_token, test_channel.id, test_message.id)
    assert response.status_code == 204

    ws.close()
