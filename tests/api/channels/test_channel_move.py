# Tests for PATCH /api/channels/{channel_id} (move channel: parent_id).
# Ordering within a parent is done through
# PUT /api/guilds/{guild_id}/channels/order, not here.
#
# R1 - content type must be application/json and body non-empty
# R2 - user must be logged
# R3 - the channel exists
# R4 - user has rights to modify channels (modify_channels)
# R5 - the body must contain at least one of name / topic / parent_id
# R9 - "parent_id" must be null or a string parseable as a channel id
# R10 - kind = category => "parent_id" must be absent or null
# R11 - the new parent channel must not be the channel itself
# R12 - the new parent channel must exist
# R13 - the new parent channel must belong to the same guild
# R14 - the new parent channel must be a category


import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from conftest import seed_role  # noqa: E402
from permissions import READ_MESSAGES, SEND_MESSAGES, MODIFY_CHANNELS  # noqa: E402


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


def _move_channel(http_client, token, channel_id, **payload):
    return http_client.patch(
        f"/api/channels/{channel_id}",
        json=payload,
        headers={"Authorization": f"Bearer {token}"},
    )


# R1
def test_move_channel_non_json_content_type(http_client, test_guild, test_channel):
    response = http_client.patch(
        f"/api/channels/{test_channel.id}",
        content=b"position=1",
        headers={
            "Authorization": f"Bearer {test_guild.admin_token}",
            "Content-Type": "text/plain",
        },
    )

    assert response.status_code == 415


# R1
def test_move_channel_empty_body(http_client, test_guild, test_channel):
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
def test_move_channel_unauthorized(http_client, test_channel):
    response = http_client.patch(
        f"/api/channels/{test_channel.id}",
        json={"parent_id": None},
    )

    assert response.status_code == 401


# R3
def test_move_unknown_channel(http_client, test_guild):
    response = _move_channel(http_client, test_guild.admin_token, "1", parent_id=None)

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "Channel not found"


# R4
def test_move_channel_without_permission(http_client, db_conn, test_guild, test_channel, test_session):
    _set_everyone_permissions(
        db_conn, test_guild.id, READ_MESSAGES | SEND_MESSAGES
    )

    response = _move_channel(
        http_client, test_session.access_token, test_channel.id, parent_id=None
    )

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


# R4 - exact-bit success path: a role carrying only modify_channels (bit 4)
# suffices to move a channel
def test_move_channel_with_role_permission(
    http_client, db_conn, test_guild, test_category, test_channel, test_user, test_session
):
    _set_everyone_permissions(
        db_conn, test_guild.id, READ_MESSAGES | SEND_MESSAGES
    )
    _create_role(
        db_conn, test_guild.id, "5550004", "channel-mover", permissions=MODIFY_CHANNELS
    )
    _assign_role(db_conn, test_guild.id, test_user.id, "5550004")

    response = _move_channel(
        http_client,
        test_session.access_token,
        test_channel.id,
        parent_id=test_category.id,
    )

    assert response.status_code == 204

    with db_conn.cursor() as cur:
        cur.execute("SELECT parent_id FROM app.channels WHERE id = %s", (test_channel.id,))
        row = cur.fetchone()

    assert int(row["parent_id"]) == int(test_category.id)


# R5
def test_move_channel_empty_object(http_client, test_guild, test_channel):
    response = _move_channel(http_client, test_guild.admin_token, test_channel.id)

    assert response.status_code == 400


# R10
def test_move_channel_parent_id_not_a_string(http_client, test_guild, test_channel):
    response = _move_channel(
        http_client, test_guild.admin_token, test_channel.id, parent_id=42
    )

    assert response.status_code == 400


# R10
def test_move_channel_parent_id_not_parseable(http_client, test_guild, test_channel):
    response = _move_channel(
        http_client, test_guild.admin_token, test_channel.id, parent_id="not-a-number"
    )

    assert response.status_code == 400


# R11
def test_move_category_under_parent(http_client, test_guild, test_category):
    response = _move_channel(
        http_client, test_guild.admin_token, test_category.id, parent_id="123"
    )

    assert response.status_code == 400


# R10 - explicit null parent for a category is allowed (no-op on parent)
def test_move_category_null_parent(http_client, test_guild, test_category):
    response = _move_channel(
        http_client, test_guild.admin_token, test_category.id, parent_id=None
    )

    assert response.status_code == 204


# R11 - the parent must not be the channel itself
def test_move_channel_self_parent(http_client, test_guild, test_channel):
    response = _move_channel(
        http_client, test_guild.admin_token, test_channel.id, parent_id=test_channel.id
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'parent_id' must not be the channel itself"


# R12
def test_move_channel_unknown_parent(http_client, test_guild, test_channel):
    response = _move_channel(
        http_client, test_guild.admin_token, test_channel.id, parent_id="9999999"
    )

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "Parent channel not found"


# R13
def test_move_channel_parent_other_guild(http_client, db_conn, test_guild, test_channel):
    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.guilds (id, name) VALUES (%s, %s)",
            ("7770001", "ForeignGuild"),
        )
        cur.execute(
            "INSERT INTO app.channels (id, guild_id, kind, name) VALUES (%s, %s, %s, %s)",
            ("8880001", "7770001", 1, "ForeignCategory"),
        )

    response = _move_channel(
        http_client, test_guild.admin_token, test_channel.id, parent_id="8880001"
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Parent channel belongs to another guild"


# R14
def test_move_channel_parent_not_a_category(http_client, db_conn, test_guild, test_category, test_channel):
    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.channels (id, guild_id, kind, name) VALUES (%s, %s, %s, %s)",
            ("8880002", test_guild.id, 0, "OtherChannel"),
        )

    response = _move_channel(
        http_client, test_guild.admin_token, test_channel.id, parent_id="8880002"
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Parent channel must be a category"


def test_move_channel_under_category(http_client, db_conn, test_guild, test_category, test_channel):
    response = _move_channel(
        http_client,
        test_guild.admin_token,
        test_channel.id,
        parent_id=test_category.id,
    )

    assert response.status_code == 204

    with db_conn.cursor() as cur:
        cur.execute("SELECT parent_id FROM app.channels WHERE id = %s", (test_channel.id,))
        row = cur.fetchone()

    assert int(row["parent_id"]) == int(test_category.id)


def test_move_channel_to_root(http_client, db_conn, test_guild, test_category, test_channel):
    with db_conn.cursor() as cur:
        cur.execute("UPDATE app.channels SET parent_id = %s WHERE id = %s", (test_category.id, test_channel.id))

    response = _move_channel(
        http_client, test_guild.admin_token, test_channel.id, parent_id=None
    )

    assert response.status_code == 204

    with db_conn.cursor() as cur:
        cur.execute("SELECT parent_id FROM app.channels WHERE id = %s", (test_channel.id,))
        row = cur.fetchone()

    assert row["parent_id"] is None
