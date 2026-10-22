# Tests for /api/messages/{message_id} (GET, PATCH, DELETE).
#
# GET    - R1 logged in; R2 message exists; R3 read_messages on the channel
# PATCH  - R1 logged in; R2 message exists; R3 read_messages and author only;
#          R4 content validation
# DELETE - R1 logged in; R2 message exists; R3 read_messages;
#          R4 author deletes freely, non-author needs delete_messages;
#          R5 non-author strictly higher than the author

import sys
from pathlib import Path

# GatewayClient lives in tests/api/test_gateway.py; make it importable when
# this file is run standalone (not as part of the full suite).
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from conftest import CONFIG, seed_role, system_create_user, system_login

from permissions import READ_MESSAGES, SEND_MESSAGES, DELETE_MESSAGES


def _message_url(message_id):
    return f"/api/messages/{message_id}"


def _get_message(http_client, test_session, message_id):
    return http_client.get(
        _message_url(message_id),
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )


def _patch_message(http_client, test_session, message_id, **kwargs):
    headers = kwargs.pop("headers", None)

    if headers is None:
        headers = {"Authorization": f"Bearer {test_session.access_token}"}

    return http_client.patch(_message_url(message_id), headers=headers, **kwargs)


def _delete_message(http_client, test_session, message_id):
    return http_client.delete(
        _message_url(message_id),
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )


def _create_other_session(http_client, username="other"):
    user = system_create_user(http_client, username=username)
    access_token, _ = system_login(http_client, username)

    return user, access_token


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


def _add_overwrite(
    db_conn,
    guild_id,
    channel_id,
    target_type,
    allow=0,
    deny=0,
    role_id=None,
    user_id=None,
):
    # target_type: 0 = role, 1 = member
    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.overwrites"
            " (guild_id, channel_id, target_type, role_id, user_id, allow, deny)"
            " VALUES (%s, %s, %s, %s, %s, %s, %s)",
            (
                guild_id,
                channel_id,
                target_type,
                role_id,
                user_id,
                allow.to_bytes(16),
                deny.to_bytes(16),
            ),
        )


# ---------------------------------------------------------------------------
# GET
# ---------------------------------------------------------------------------


# R1
def test_get_message_unauthorized(http_client, test_message):
    response = http_client.get(_message_url(test_message.id))

    assert response.status_code == 401


# R2
def test_get_non_existent_message(http_client, test_session):
    response = _get_message(http_client, test_session, "1")

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "Message not found"


# R3 - GET /api/messages/{message_id} requires read_messages


def test_get_message_forbidden_without_read_messages(
    db_conn, http_client, test_guild, test_message, test_session
):
    # @everyone has only send_messages
    _set_everyone_permissions(db_conn, test_guild.id, SEND_MESSAGES)

    response = _get_message(http_client, test_session, test_message.id)

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


def test_get_message_allowed_by_assigned_role_permissions(
    db_conn, http_client, test_guild, test_message, test_user, test_session
):
    # @everyone has no permissions, but the assigned role grants read_messages
    _set_everyone_permissions(db_conn, test_guild.id, 0)

    _create_role(db_conn, test_guild.id, "1111111", "viewers", permissions=READ_MESSAGES)
    _assign_role(db_conn, test_guild.id, test_user.id, "1111111")

    response = _get_message(http_client, test_session, test_message.id)

    assert response.status_code == 200


def test_get_message_everyone_overwrite_deny(
    db_conn, http_client, test_guild, test_channel, test_message, test_session
):
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        0,
        role_id=test_guild.id,
        deny=READ_MESSAGES,
    )

    response = _get_message(http_client, test_session, test_message.id)

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


def test_get_message_member_overwrite_allow_overrides_everyone_deny(
    db_conn, http_client, test_guild, test_channel, test_message, test_user, test_session
):
    # step 1: @everyone overwrite denies read_messages
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        0,
        role_id=test_guild.id,
        deny=READ_MESSAGES,
    )
    # step 2: member overwrite re-allows it
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        1,
        user_id=test_user.id,
        allow=READ_MESSAGES,
    )

    response = _get_message(http_client, test_session, test_message.id)

    assert response.status_code == 200


# R3
def test_get_message(http_client, test_user, test_session, test_channel, test_message):
    response = _get_message(http_client, test_session, test_message.id)

    assert response.status_code == 200

    body = response.json()
    assert body["channel_id"] == test_channel.id
    assert body["author_id"] == test_user.id
    assert body["content"] == test_message.content
    assert body["reply_to_id"] is None
    assert body["edited_at"] is None
    assert "created_at" in body


# R3
def test_get_message_with_reply_and_edit(db_conn, http_client, test_channel, test_message, test_user, test_session):
    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.messages (id, channel_id, guild_id, author_id, content, reply_to_id, edited_at)"
            " SELECT %s, c.id, c.guild_id, %s, %s, %s, now() FROM app.channels c WHERE c.id = %s",
            ("34661247", test_user.id, "reply body", test_message.id, test_channel.id),
        )

    response = _get_message(http_client, test_session, "34661247")

    assert response.status_code == 200

    body = response.json()
    assert body["author_id"] == test_user.id
    assert body["content"] == "reply body"
    assert body["reply_to_id"] == test_message.id
    assert body["edited_at"] is not None


# ---------------------------------------------------------------------------
# PATCH
# ---------------------------------------------------------------------------


# R1
def test_patch_message_unauthorized(http_client, test_message):
    response = http_client.patch(_message_url(test_message.id), json={"content": "x"})

    assert response.status_code == 401


# R2
def test_patch_non_existent_message(http_client, test_session):
    response = _patch_message(http_client, test_session, "1", json={"content": "x"})

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "Message not found"


# R3 - the author needs read_messages and only the author may edit


def test_patch_message_forbidden_for_non_author_even_with_delete_messages(
    db_conn, http_client, test_guild, test_message, test_session
):
    _set_everyone_permissions(db_conn, test_guild.id, DELETE_MESSAGES)

    _, other_token = _create_other_session(http_client)

    response = http_client.patch(
        _message_url(test_message.id),
        json={"content": "hacked"},
        headers={"Authorization": f"Bearer {other_token}"},
    )

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


# R1 - content type must be application/json and body non-empty


def test_patch_message_bad_content_type(http_client, test_message, test_session):
    response = _patch_message(
        http_client,
        test_session,
        test_message.id,
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
            "Content-Type": "text/plain",
        },
        content="Hello, world!",
    )

    assert response.status_code == 415

    body = response.json()
    assert body["message"] == "Unsupported Media Type"


def test_patch_message_bad_json(http_client, test_message, test_session):
    response = _patch_message(
        http_client,
        test_session,
        test_message.id,
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
            "Content-Type": "application/json",
        },
        content=b"{not json",
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Bad JSON"


def test_patch_message_non_object_body(http_client, test_message, test_session):
    response = _patch_message(
        http_client,
        test_session,
        test_message.id,
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
            "Content-Type": "application/json",
        },
        content=b"[1, 2]",
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Expected an object"


# R4 - "content" must be present, a string, valid UTF-8; forbidden codepoints
# are stripped; after stripping the content is not empty and not too long


def test_patch_message_missing_content(http_client, test_message, test_session):
    response = _patch_message(http_client, test_session, test_message.id, json={})

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'content' or 'embeds' is required"


def test_patch_message_content_not_a_string(http_client, test_message, test_session):
    response = _patch_message(http_client, test_session, test_message.id, json={"content": 42})

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'content' is not a string"


def test_patch_message_empty_content(http_client, test_message, test_session):
    response = _patch_message(http_client, test_session, test_message.id, json={"content": ""})

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'content' is empty"


def test_patch_message_content_too_long(http_client, test_message, test_session):
    max_codepoints = CONFIG["api"]["messages"]["max_codepoints"]

    response = _patch_message(
        http_client,
        test_session,
        test_message.id,
        json={"content": "a" * (max_codepoints + 1)},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'content' is too long"


def test_patch_message_content_max_length(http_client, test_message, test_session):
    max_codepoints = CONFIG["api"]["messages"]["max_codepoints"]

    response = _patch_message(
        http_client, test_session, test_message.id, json={"content": "a" * max_codepoints}
    )

    assert response.status_code == 200


def test_patch_message_content_strips_forbidden_codepoints(
    http_client, test_message, test_session
):
    response = _patch_message(
        http_client,
        test_session,
        test_message.id,
        json={"content": "a\u200Bb\u202Ec\u2800d\ue000e\rf"},
    )

    assert response.status_code == 200

    stored = _get_message(http_client, test_session, test_message.id)

    assert stored.status_code == 200
    assert stored.json()["content"] == "abcdef"


def test_patch_message_content_normalized(http_client, test_message, test_session):
    response = _patch_message(
        http_client,
        test_session,
        test_message.id,
        json={"content": "\uFF21\uFF22"},  # fullwidth "AB"
    )

    assert response.status_code == 200

    stored = _get_message(http_client, test_session, test_message.id)

    assert stored.status_code == 200
    assert stored.json()["content"] == "AB"


# R3 - the author needs read_messages to edit


def test_patch_message_by_author_with_read_messages(
    db_conn, http_client, test_guild, test_message, test_session
):
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES)

    response = _patch_message(
        http_client, test_session, test_message.id, json={"content": "edited"}
    )

    assert response.status_code == 200

    body = response.json()
    assert "edited_at" in body
    assert body["edited_at"] > 0


def test_patch_message_forbidden_without_read_messages(
    db_conn, http_client, test_guild, test_message, test_session
):
    _set_everyone_permissions(db_conn, test_guild.id, 0)

    response = _patch_message(
        http_client, test_session, test_message.id, json={"content": "edited"}
    )

    assert response.status_code == 403
    assert response.json()["message"] == "Missing permissions"

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT content FROM app.messages WHERE id = %s",
            (int(test_message.id),),
        )
        row = cur.fetchone()

    assert row["content"] == test_message.content


def test_patch_message_success(db_conn, http_client, test_message, test_session):
    response = _patch_message(
        http_client, test_session, test_message.id, json={"content": "edited body"}
    )

    assert response.status_code == 200

    body = response.json()
    assert isinstance(body["edited_at"], int)

    stored = _get_message(http_client, test_session, test_message.id)

    assert stored.status_code == 200
    assert stored.json()["content"] == "edited body"
    assert stored.json()["edited_at"] == body["edited_at"]


# ---------------------------------------------------------------------------
# DELETE
# ---------------------------------------------------------------------------


# R1
def test_delete_message_unauthorized(http_client, test_message):
    response = http_client.delete(_message_url(test_message.id))

    assert response.status_code == 401


# R2
def test_delete_non_existent_message(http_client, test_session):
    response = _delete_message(http_client, test_session, "1")

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "Message not found"


# R3 - the author needs read_messages to delete the own message


def test_delete_own_message_with_read_messages(
    db_conn, http_client, test_guild, test_message, test_session
):
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES)

    response = _delete_message(http_client, test_session, test_message.id)

    assert response.status_code == 204

    stored = _get_message(http_client, test_session, test_message.id)

    assert stored.status_code == 404

    # soft delete: content wiped, author anonymized, deleted_at set
    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT content, author_id, deleted_at FROM app.messages WHERE id = %s",
            (int(test_message.id),),
        )
        row = cur.fetchone()

    assert row is not None
    assert row["content"] == ""
    assert row["author_id"] is None
    assert row["deleted_at"] is not None


def test_delete_own_message_forbidden_without_read_messages(
    db_conn, http_client, test_guild, test_message, test_session
):
    _set_everyone_permissions(db_conn, test_guild.id, 0)

    response = _delete_message(http_client, test_session, test_message.id)

    assert response.status_code == 403
    assert response.json()["message"] == "Missing permissions"

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT deleted_at FROM app.messages WHERE id = %s",
            (int(test_message.id),),
        )
        row = cur.fetchone()

    assert row is not None
    assert row["deleted_at"] is None


# R4 - a non-author needs delete_messages


def test_delete_message_by_non_author_without_delete_messages(
    db_conn, http_client, test_guild, test_message, test_session
):
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES)

    _, other_token = _create_other_session(http_client)

    response = http_client.delete(
        _message_url(test_message.id),
        headers={"Authorization": f"Bearer {other_token}"},
    )

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


# R5 - a non-author must be strictly higher than the author


def test_delete_message_by_non_author_with_equal_position(
    db_conn, http_client, test_guild, test_message, test_session
):
    # @everyone (position 0) grants read_messages and delete_messages, but the
    # author's highest position is 0 too: not strictly higher.
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES | DELETE_MESSAGES)

    _, other_token = _create_other_session(http_client)

    response = http_client.delete(
        _message_url(test_message.id),
        headers={"Authorization": f"Bearer {other_token}"},
    )

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


def test_delete_message_by_non_author_with_higher_position(
    db_conn, http_client, test_guild, test_message, test_session
):
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES)

    other_user, other_token = _create_other_session(http_client)

    _create_role(
        db_conn, test_guild.id, "1111111", "mods", position=1, permissions=DELETE_MESSAGES
    )
    _assign_role(db_conn, test_guild.id, other_user["id"], "1111111")

    response = http_client.delete(
        _message_url(test_message.id),
        headers={"Authorization": f"Bearer {other_token}"},
    )

    assert response.status_code == 204


# R3 - a non-author still needs read_messages
def test_delete_message_by_non_author_without_read_messages(
    db_conn, http_client, test_guild, test_message, test_session
):
    _set_everyone_permissions(db_conn, test_guild.id, DELETE_MESSAGES)

    other_user, other_token = _create_other_session(http_client)

    _create_role(
        db_conn, test_guild.id, "1111112", "mods", position=1, permissions=0
    )
    _assign_role(db_conn, test_guild.id, other_user["id"], "1111112")

    response = http_client.delete(
        _message_url(test_message.id),
        headers={"Authorization": f"Bearer {other_token}"},
    )

    assert response.status_code == 403
    assert response.json()["message"] == "Missing permissions"


# ---------------------------------------------------------------------------
# Gateway events
# ---------------------------------------------------------------------------


def test_patch_message_emits_message_updated_event(
    http_client, test_message, test_session, test_channel, test_guild
):
    from test_gateway import GatewayClient

    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_session.access_token}})
    assert ws.recv_json()["op"] == "hello"

    response = _patch_message(
        http_client, test_session, test_message.id, json={"content": "ws edit"}
    )
    assert response.status_code == 200

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "message_updated"
    assert event["d"] == {
        "id": str(test_message.id),
        "channel_id": str(test_channel.id),
        "guild_id": str(test_guild.id),
    }

    ws.close()


def test_delete_message_emits_message_deleted_event(
    http_client, test_message, test_session, test_channel, test_guild
):
    from test_gateway import GatewayClient

    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_session.access_token}})
    assert ws.recv_json()["op"] == "hello"

    response = _delete_message(http_client, test_session, test_message.id)
    assert response.status_code == 204

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "message_deleted"
    assert event["d"] == {
        "id": str(test_message.id),
        "channel_id": str(test_channel.id),
        "guild_id": str(test_guild.id),
    }

    ws.close()
