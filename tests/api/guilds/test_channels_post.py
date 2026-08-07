# Tests for POST /api/guilds/{guild_id}/channels (create channel).
#
# R1 - content type must be application/json and body non-empty
# R2 - user must be logged
# R3 - the guild exists
# R4 - user has rights to create channels (create_channels, guild-level)
# R5 - "name" must be present, a string, not too long and contain no forbidden
# codepoints
# R6 - optional "topic" must be a string, not too long and contain no forbidden
# codepoints
# R7 - "kind" must be present, a string and a valid ChannelKind
# R8 - optional "parent_id" must be a string parseable as a channel id
# R9 - kind = category => "parent_id" and "topic" must be absent
# R10 - the parent channel must exist
# R11 - the parent channel must belong to the same guild
# R12 - the parent channel must be a category

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from conftest import seed_role  # noqa: E402
from permissions import READ_MESSAGES, SEND_MESSAGES, CREATE_CHANNELS  # noqa: E402


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


def _create_channel(http_client, admin_token, guild_id, **payload):
    return http_client.post(
        f"/api/guilds/{guild_id}/channels",
        json=payload,
        headers={"Authorization": f"Bearer {admin_token}"},
    )


# R1
def test_create_channel_non_json_content_type(http_client, test_guild):
    response = http_client.post(
        f"/api/guilds/{test_guild.id}/channels",
        content=b"name=x",
        headers={
            "Authorization": f"Bearer {test_guild.admin_token}",
            "Content-Type": "text/plain",
        },
    )

    assert response.status_code == 415


# R1
def test_create_channel_empty_body(http_client, test_guild):
    response = http_client.post(
        f"/api/guilds/{test_guild.id}/channels",
        content=b"",
        headers={
            "Authorization": f"Bearer {test_guild.admin_token}",
            "Content-Type": "application/json",
        },
    )

    assert response.status_code == 400


# R2
def test_create_channel_unauthorized(http_client, test_guild):
    response = http_client.post(
        f"/api/guilds/{test_guild.id}/channels",
        json={"name": "x", "kind": "channel"},
    )

    assert response.status_code == 401


# R3
def test_create_channel_guild_not_found(http_client, test_guild):
    response = _create_channel(http_client, test_guild.admin_token, "2", name="x", kind="channel")

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "Guild not found"


# R4 - default @everyone permissions (3) do not include create_channels
def test_create_channel_without_permission(http_client, db_conn, test_guild, test_user):
    _set_everyone_permissions(
        db_conn, test_guild.id, READ_MESSAGES | SEND_MESSAGES
    )

    # login as the plain user (guild admin fixture has all bits)
    response = http_client.post(
        "/api/auth/token",
        json={"grant_type": "password", "username": test_user.username, "password": test_user.password},
    )
    assert response.status_code == 200

    token = response.json()["access_token"]

    response = _create_channel(http_client, token, test_guild.id, name="x", kind="channel")

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


# R4 - success via a role carrying create_channels
def test_create_channel_with_role_permission(
    http_client, db_conn, test_guild, test_user, test_session
):
    _set_everyone_permissions(
        db_conn, test_guild.id, READ_MESSAGES | SEND_MESSAGES
    )
    _create_role(
        db_conn, test_guild.id, "5550001", "channel-maker", permissions=CREATE_CHANNELS
    )
    _assign_role(db_conn, test_guild.id, test_user.id, "5550001")

    response = _create_channel(http_client, test_session.access_token, test_guild.id, name="x", kind="channel")

    assert response.status_code == 201

    body = response.json()
    assert body["id"] is not None


# R5
def test_create_channel_name_missing(http_client, test_guild):
    response = _create_channel(http_client, test_guild.admin_token, test_guild.id, kind="channel")

    assert response.status_code == 400


# R5
def test_create_channel_name_not_a_string(http_client, test_guild):
    response = _create_channel(http_client, test_guild.admin_token, test_guild.id, name=42, kind="channel")

    assert response.status_code == 400


# R5
def test_create_channel_name_too_long(http_client, test_guild):
    response = _create_channel(
        http_client, test_guild.admin_token, test_guild.id, name="a" * 25, kind="channel"
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'name' is too long"


# R5
def test_create_channel_name_forbidden_codepoints(http_client, test_guild):
    response = _create_channel(
        http_client, test_guild.admin_token, test_guild.id, name="a\u200Bb", kind="channel"
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'name' is invalid"


# R6
def test_create_channel_topic_not_a_string(http_client, test_guild):
    response = _create_channel(
        http_client, test_guild.admin_token, test_guild.id, name="x", kind="channel", topic=42
    )

    assert response.status_code == 400


# R6
def test_create_channel_topic_too_long(http_client, test_guild):
    response = _create_channel(
        http_client, test_guild.admin_token, test_guild.id, name="x", kind="channel", topic="a" * 129
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'topic' is too long"


# R6
def test_create_channel_topic_forbidden_codepoints(http_client, test_guild):
    response = _create_channel(
        http_client, test_guild.admin_token, test_guild.id, name="x", kind="channel", topic="t\u202Ep"
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'topic' is invalid"


# R7
def test_create_channel_kind_missing(http_client, test_guild):
    response = _create_channel(http_client, test_guild.admin_token, test_guild.id, name="x")

    assert response.status_code == 400


# R7
def test_create_channel_kind_not_a_string(http_client, test_guild):
    response = _create_channel(
        http_client, test_guild.admin_token, test_guild.id, name="x", kind=1
    )

    assert response.status_code == 400


# R7
def test_create_channel_bad_kind(http_client, test_guild):
    response = _create_channel(http_client, test_guild.admin_token, test_guild.id, name="x", kind="bad")

    assert response.status_code == 400


# R8
def test_create_channel_parent_id_not_a_string(http_client, test_guild):
    response = _create_channel(
        http_client, test_guild.admin_token, test_guild.id, name="x", kind="channel", parent_id=42
    )

    assert response.status_code == 400


# R8
def test_create_channel_parent_id_not_parseable(http_client, test_guild):
    response = _create_channel(
        http_client, test_guild.admin_token, test_guild.id, name="x", kind="channel", parent_id="not-a-number"
    )

    assert response.status_code == 400


# R9
def test_create_category_with_parent(http_client, test_guild, test_category):
    response = _create_channel(
        http_client, test_guild.admin_token, test_guild.id, name="x", kind="category", parent_id=test_category.id
    )

    assert response.status_code == 400


# R9
def test_create_category_with_topic(http_client, test_guild):
    response = _create_channel(
        http_client, test_guild.admin_token, test_guild.id, name="x", kind="category", topic="nope"
    )

    assert response.status_code == 400


# R10
def test_create_channel_unknown_parent(http_client, test_guild):
    response = _create_channel(
        http_client, test_guild.admin_token, test_guild.id, name="x", kind="channel", parent_id="9999999"
    )

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "Parent channel not found"


# R11
def test_create_channel_parent_other_guild(http_client, db_conn, test_guild):
    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.guilds (id, name) VALUES (%s, %s)",
            ("7770001", "ForeignGuild"),
        )
        cur.execute(
            "INSERT INTO app.channels (id, guild_id, kind, name) VALUES (%s, %s, %s, %s)",
            ("8880001", "7770001", 1, "ForeignCategory"),
        )

    response = _create_channel(
        http_client, test_guild.admin_token, test_guild.id, name="x", kind="channel", parent_id="8880001"
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Parent channel belongs to another guild"


# R12
def test_create_channel_parent_not_a_category(http_client, test_guild, test_channel):
    response = _create_channel(
        http_client, test_guild.admin_token, test_guild.id, name="x", kind="channel", parent_id=test_channel.id
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Parent channel must be a category"


def test_create_channel_persists(http_client, db_conn, test_guild):
    response = _create_channel(
        http_client, test_guild.admin_token, test_guild.id, name="gen", kind="channel", topic="hello"
    )

    assert response.status_code == 201

    channel_id = response.json()["id"]

    with db_conn.cursor() as cur:
        cur.execute("SELECT guild_id, kind, name, topic FROM app.channels WHERE id = %s", (channel_id,))
        row = cur.fetchone()

    assert row is not None
    assert int(row["guild_id"]) == int(test_guild.id)
    assert row["kind"] == 0
    assert row["name"] == "gen"
    assert row["topic"] == "hello"


def test_create_channel_overwrite_sync_from_category(
    http_client, db_conn, test_guild, test_category, test_session
):
    # A deny overwrite on the category must be copied to the created child.
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_category.id,
        target_type=0,
        deny=SEND_MESSAGES,
        role_id=test_guild.id,
    )

    response = _create_channel(
        http_client,
        test_guild.admin_token,
        test_guild.id,
        name="synced",
        kind="channel",
        parent_id=test_category.id,
    )

    assert response.status_code == 201

    channel_id = response.json()["id"]

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT target_type, role_id, allow, deny FROM app.overwrites WHERE channel_id = %s",
            (channel_id,),
        )
        rows = cur.fetchall()

    assert len(rows) == 1

    row = rows[0]
    assert row["target_type"] == 0
    assert int(row["role_id"]) == int(test_guild.id)
    assert int.from_bytes(row["allow"], "big") == 0
    assert int.from_bytes(row["deny"], "big") == SEND_MESSAGES

    # Also visible through the API (embedded in the channel object).
    api_response = http_client.get(
        f"/api/channels/{channel_id}",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )
    assert api_response.status_code == 200

    body = api_response.json()["overwrites"]
    assert len(body) == 1
    assert body[0]["target_id"] == str(test_guild.id)
    assert body[0]["type"] == "role"
    assert body[0]["deny"] == str(SEND_MESSAGES)


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


def test_create_root_channel_has_no_overwrites(http_client, db_conn, test_guild):
    response = _create_channel(http_client, test_guild.admin_token, test_guild.id, name="root", kind="channel")

    assert response.status_code == 201

    channel_id = response.json()["id"]

    with db_conn.cursor() as cur:
        cur.execute("SELECT count(*) AS n FROM app.overwrites WHERE channel_id = %s", (channel_id,))
        row = cur.fetchone()

    assert row["n"] == 0
