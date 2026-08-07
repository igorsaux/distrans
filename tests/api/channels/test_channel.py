# Tests for GET / PATCH / DELETE /api/channels/{channel_id}.
#
# GET:
#   R1 - user must be logged
#   R2 - the channel exists
#   NOTE - channel metadata is readable by any authenticated user;
#          read_messages gates only /messages endpoints (see AGENTS.md).
# PATCH:
#   R1 - content type must be application/json and body non-empty
#   R2 - user must be logged
#   R3 - the channel exists
#   R4 - user has rights to modify channels (modify_channels)
#   R5 - the body must contain at least one of "name" / "topic"
#   R6 - "name" must be a string, not too long and contain no forbidden
#        codepoints
#   R7 - "topic" must be a string (or null), not too long and contain no
#        forbidden codepoints
#   R8 - kind = category => "topic" must be absent
# DELETE:
#   R1 - user must be logged
#   R2 - the channel exists
#   R3 - user has rights to delete channels (delete_channels)

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from conftest import seed_role  # noqa: E402
from permissions import READ_MESSAGES, SEND_MESSAGES, MODIFY_CHANNELS, DELETE_CHANNELS  # noqa: E402


def _set_everyone_permissions(db_conn, guild_id, permissions):
    with db_conn.cursor() as cur:
        cur.execute(
            "UPDATE app.roles SET permissions = %s WHERE id = %s",
            (permissions.to_bytes(16), guild_id),
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


def _login(http_client, username, password="12345678"):
    response = http_client.post(
        "/api/auth/token",
        json={"grant_type": "password", "username": username, "password": password},
    )
    assert response.status_code == 200

    return response.json()["access_token"]


# ---------------------------------------------------------------------------
# GET
# ---------------------------------------------------------------------------


# R1
def test_get_channel_unauthorized(http_client, test_channel):
    response = http_client.get(f"/api/channels/{test_channel.id}")

    assert response.status_code == 401


# R2
def test_get_unknown_channel(http_client, test_session):
    response = http_client.get(
        "/api/channels/1",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "Channel not found"


def test_get_channel(http_client, test_guild, test_channel, test_session):
    response = http_client.get(
        f"/api/channels/{test_channel.id}",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 200

    body = response.json()
    assert body["id"] == str(test_channel.id)
    assert body["guild_id"] == str(test_guild.id)
    assert body["parent_id"] is None
    assert body["kind"] == "channel"
    assert body["name"] == test_channel.name
    assert body["topic"] is None
    assert body["position"] == 0


def test_get_channel_with_topic(http_client, test_guild, test_category, test_session):
    response = http_client.post(
        f"/api/guilds/{test_guild.id}/channels",
        json={
            "name": "TopicChannel",
            "kind": "channel",
            "parent_id": test_category.id,
            "topic": "hello",
        },
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )
    assert response.status_code == 201

    channel_id = response.json()["id"]

    response = http_client.get(
        f"/api/channels/{channel_id}",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 200

    body = response.json()
    assert body["parent_id"] == str(test_category.id)
    assert body["topic"] == "hello"


def test_get_channel_metadata_readable_without_read_messages(
    http_client, db_conn, test_guild, test_channel, test_session
):
    # Metadata is not gated by read_messages: a deny overwrite of
    # read_messages blocks messages, not the channel object itself.
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES | SEND_MESSAGES)
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        target_type=0,
        deny=READ_MESSAGES,
        role_id=test_guild.id,
    )

    response = http_client.get(
        f"/api/channels/{test_channel.id}",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 200
    assert response.json()["id"] == str(test_channel.id)

    # ...but the same overwrite still gates the messages collection.
    messages = http_client.get(
        f"/api/channels/{test_channel.id}/messages",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert messages.status_code == 403


def test_get_channel_reports_effective_permissions(
    http_client, db_conn, test_guild, test_channel, test_session
):
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES | SEND_MESSAGES)
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        target_type=0,
        deny=READ_MESSAGES,
        role_id=test_guild.id,
    )

    response = http_client.get(
        f"/api/channels/{test_channel.id}",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 200
    assert response.json()["permissions"] == str(SEND_MESSAGES)


# ---------------------------------------------------------------------------
# PATCH
# ---------------------------------------------------------------------------


# R1
def test_patch_channel_non_json_content_type(http_client, test_guild, test_channel):
    response = http_client.patch(
        f"/api/channels/{test_channel.id}",
        content=b"name=x",
        headers={
            "Authorization": f"Bearer {test_guild.admin_token}",
            "Content-Type": "text/plain",
        },
    )

    assert response.status_code == 415


# R1
def test_patch_channel_empty_body(http_client, test_guild, test_channel):
    response = http_client.patch(
        f"/api/channels/{test_channel.id}",
        content=b"",
        headers={
            "Authorization": f"Bearer {test_guild.admin_token}",
            "Content-Type": "application/json",
        },
    )

    assert response.status_code == 400


# R2
def test_patch_channel_unauthorized(http_client, test_channel):
    response = http_client.patch(f"/api/channels/{test_channel.id}", json={"name": "x"})

    assert response.status_code == 401


# R3
def test_patch_unknown_channel(http_client, test_guild):
    response = http_client.patch(
        "/api/channels/1",
        json={"name": "x"},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "Channel not found"


# R4
def test_patch_channel_without_permission(
    http_client, db_conn, test_guild, test_channel, test_session
):
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES | SEND_MESSAGES)

    response = http_client.patch(
        f"/api/channels/{test_channel.id}",
        json={"name": "x"},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


# R4 - success via a role carrying modify_channels
def test_patch_channel_with_role_permission(
    http_client, db_conn, test_guild, test_channel, test_session
):
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES | SEND_MESSAGES)

    seed_role(db_conn, test_guild.id, "5550002", "channel-mod", permissions=MODIFY_CHANNELS)

    with db_conn.cursor() as cur:
        cur.execute("SELECT id FROM app.users WHERE username = %s", ("anon",))
        row = cur.fetchone()
        assert row is not None
        cur.execute(
            "INSERT INTO app.member_roles (guild_id, user_id, role_id) VALUES (%s, %s, %s)",
            (test_guild.id, row["id"], "5550002"),
        )

    response = http_client.patch(
        f"/api/channels/{test_channel.id}",
        json={"name": "renamed-by-role"},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 204


# R5
def test_patch_channel_empty_object(http_client, test_guild, test_channel):
    response = http_client.patch(
        f"/api/channels/{test_channel.id}",
        json={},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 400


# R6
def test_patch_channel_name_not_a_string(http_client, test_guild, test_channel):
    response = http_client.patch(
        f"/api/channels/{test_channel.id}",
        json={"name": 42},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 400


# R6
def test_patch_channel_name_too_long(http_client, test_guild, test_channel):
    response = http_client.patch(
        f"/api/channels/{test_channel.id}",
        json={"name": "a" * 25},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'name' is too long"


# R6
def test_patch_channel_name_forbidden_codepoints(http_client, test_guild, test_channel):
    response = http_client.patch(
        f"/api/channels/{test_channel.id}",
        json={"name": "a\u200Bb"},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'name' is invalid"


# R7
def test_patch_channel_topic_not_a_string(http_client, test_guild, test_channel):
    response = http_client.patch(
        f"/api/channels/{test_channel.id}",
        json={"topic": 42},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 400


# R7
def test_patch_channel_topic_too_long(http_client, test_guild, test_channel):
    response = http_client.patch(
        f"/api/channels/{test_channel.id}",
        json={"topic": "a" * 129},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'topic' is too long"


# R7
def test_patch_channel_topic_forbidden_codepoints(http_client, test_guild, test_channel):
    response = http_client.patch(
        f"/api/channels/{test_channel.id}",
        json={"topic": "t\u202Ep"},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'topic' is invalid"


# R8
def test_patch_category_topic(http_client, test_guild, test_category):
    response = http_client.patch(
        f"/api/channels/{test_category.id}",
        json={"topic": "nope"},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'topic' must be null"


def test_patch_channel_name_and_topic(http_client, db_conn, test_guild, test_channel):
    response = http_client.patch(
        f"/api/channels/{test_channel.id}",
        json={"name": "renamed", "topic": "new topic"},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 204

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT name, topic FROM app.channels WHERE id = %s", (test_channel.id,)
        )
        row = cur.fetchone()

    assert row["name"] == "renamed"
    assert row["topic"] == "new topic"


def test_patch_channel_name_and_topic_normalized(
    http_client, db_conn, test_guild, test_channel
):
    response = http_client.patch(
        f"/api/channels/{test_channel.id}",
        json={"name": "\uFF21\uFF22", "topic": "\uFF23\uFF24"},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 204

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT name, topic FROM app.channels WHERE id = %s", (test_channel.id,)
        )
        row = cur.fetchone()

    assert row["name"] == "AB"
    assert row["topic"] == "CD"


def test_patch_channel_topic_null_clears(
    http_client, db_conn, test_guild, test_channel
):
    with db_conn.cursor() as cur:
        cur.execute(
            "UPDATE app.channels SET topic = 'old topic' WHERE id = %s",
            (test_channel.id,),
        )

    response = http_client.patch(
        f"/api/channels/{test_channel.id}",
        json={"topic": None},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 204

    with db_conn.cursor() as cur:
        cur.execute("SELECT topic FROM app.channels WHERE id = %s", (test_channel.id,))
        row = cur.fetchone()

    assert row["topic"] is None


def test_patch_channel_name_kept_when_absent(
    http_client, db_conn, test_guild, test_channel
):
    response = http_client.patch(
        f"/api/channels/{test_channel.id}",
        json={"topic": "only topic"},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 204


# ---------------------------------------------------------------------------
# DELETE
# ---------------------------------------------------------------------------


# R1
def test_delete_channel_unauthorized(http_client, test_channel):
    response = http_client.delete(f"/api/channels/{test_channel.id}")

    assert response.status_code == 401


# R2
def test_delete_unknown_channel(http_client, test_guild):
    response = http_client.delete(
        "/api/channels/1",
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "Channel not found"


# R3
def test_delete_channel_without_permission(
    http_client, db_conn, test_guild, test_channel, test_session
):
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES | SEND_MESSAGES)

    response = http_client.delete(
        f"/api/channels/{test_channel.id}",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


# R3 - success via a role carrying delete_channels
def test_delete_channel_with_role_permission(
    http_client, db_conn, test_guild, test_channel, test_session
):
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES | SEND_MESSAGES)

    seed_role(db_conn, test_guild.id, "5550003", "channel-deleter", permissions=DELETE_CHANNELS)

    with db_conn.cursor() as cur:
        cur.execute("SELECT id FROM app.users WHERE username = %s", ("anon",))
        row = cur.fetchone()
        assert row is not None
        cur.execute(
            "INSERT INTO app.member_roles (guild_id, user_id, role_id) VALUES (%s, %s, %s)",
            (test_guild.id, row["id"], "5550003"),
        )

    response = http_client.delete(
        f"/api/channels/{test_channel.id}",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 204


def test_delete_channel_cascades_messages(
    http_client, db_conn, test_guild, test_channel, test_message
):
    response = http_client.delete(
        f"/api/channels/{test_channel.id}",
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 204
    assert response.content == b""

    with db_conn.cursor() as cur:
        cur.execute("SELECT 1 FROM app.channels WHERE id = %s", (test_channel.id,))
        assert cur.fetchone() is None

        cur.execute("SELECT 1 FROM app.messages WHERE id = %s", (test_message.id,))
        assert cur.fetchone() is None


def test_delete_category_reparents_children(
    http_client, db_conn, test_guild, test_category, test_channel
):
    # Children survive the category deletion: they keep their guild and
    # become root channels (parent_id is cleared by ON DELETE SET NULL).
    with db_conn.cursor() as cur:
        cur.execute(
            "UPDATE app.channels SET parent_id = %s WHERE id = %s",
            (test_category.id, test_channel.id),
        )

    response = http_client.delete(
        f"/api/channels/{test_category.id}",
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 204

    with db_conn.cursor() as cur:
        cur.execute("SELECT 1 FROM app.channels WHERE id = %s", (test_category.id,))
        assert cur.fetchone() is None

        cur.execute(
            "SELECT parent_id, guild_id FROM app.channels WHERE id = %s",
            (test_channel.id,),
        )
        row = cur.fetchone()

    assert row is not None
    assert row["parent_id"] is None
    assert int(row["guild_id"]) == int(test_guild.id)
