# Channel permission overwrites are embedded in every `Channel` object
# (GET /api/channels/{channel_id} and GET /api/guilds/{guild_id}/channels).
# The separate GET /api/channels/{channel_id}/overwrites collection endpoint was
# removed; only PUT remains on that path.

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from conftest import seed_role
from permissions import READ_MESSAGES, SEND_MESSAGES


def _create_role(db_conn, guild_id, role_id, name, position=0):
    seed_role(db_conn, guild_id, role_id, name, position, 3)


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


def _auth(test_session):
    return {"Authorization": f"Bearer {test_session.access_token}"}


def _get_channel(http_client, channel_id, test_session):
    return http_client.get(
        f"/api/channels/{channel_id}",
        headers=_auth(test_session),
    )


def _get_channel_list(http_client, guild_id, test_session):
    return http_client.get(
        f"/api/guilds/{guild_id}/channels",
        headers=_auth(test_session),
    )


def _channel_overwrites(http_client, channel_id, test_session):
    response = _get_channel(http_client, channel_id, test_session)
    assert response.status_code == 200, response.text

    return response.json()["overwrites"]


# The aggregate GET endpoint is gone: only PUT is allowed on the path.
def test_get_overwrites_method_not_allowed(http_client, test_channel, test_session):
    response = http_client.get(
        f"/api/channels/{test_channel.id}/overwrites",
        headers=_auth(test_session),
    )

    assert response.status_code == 405
    assert response.headers["Allow"] == "PUT"


def test_channel_overwrites_empty(http_client, test_channel, test_session):
    assert _channel_overwrites(http_client, test_channel.id, test_session) == []


def test_channel_overwrites_role(
    http_client, db_conn, test_guild, test_channel, test_session
):
    _create_role(db_conn, test_guild.id, "1111111", "mods")

    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        target_type=0,
        allow=READ_MESSAGES | SEND_MESSAGES,
        deny=SEND_MESSAGES,
        role_id="1111111",
    )

    body = _channel_overwrites(http_client, test_channel.id, test_session)
    assert len(body) == 1

    overwrite = body[0]
    assert overwrite["target_id"] == "1111111"
    assert overwrite["type"] == "role"
    # permissions are returned as decimal strings for JS BigInt compatibility
    assert overwrite["allow"] == str(READ_MESSAGES | SEND_MESSAGES)
    assert overwrite["deny"] == str(SEND_MESSAGES)


def test_channel_overwrites_member(
    http_client, db_conn, test_guild, test_channel, test_user, test_session
):
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        target_type=1,
        allow=READ_MESSAGES,
        user_id=test_user.id,
    )

    body = _channel_overwrites(http_client, test_channel.id, test_session)
    assert len(body) == 1

    overwrite = body[0]
    assert overwrite["target_id"] == test_user.id
    assert overwrite["type"] == "member"
    assert overwrite["allow"] == str(READ_MESSAGES)
    assert overwrite["deny"] == "0"


def test_channel_overwrites_everyone_role(
    http_client, db_conn, test_guild, test_channel, test_session
):
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        target_type=0,
        deny=SEND_MESSAGES,
        role_id=test_guild.id,
    )

    body = _channel_overwrites(http_client, test_channel.id, test_session)
    assert len(body) == 1

    overwrite = body[0]
    assert overwrite["target_id"] == test_guild.id
    assert overwrite["type"] == "role"
    assert overwrite["allow"] == "0"
    assert overwrite["deny"] == str(SEND_MESSAGES)


def test_channel_overwrites_not_leaked_from_other_channels(
    http_client, db_conn, test_guild, test_channel, test_session
):
    _create_role(db_conn, test_guild.id, "1111111", "mods")

    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        target_type=0,
        allow=READ_MESSAGES,
        role_id="1111111",
    )

    other_channel_id = "9999999"
    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.channels (id, guild_id, name) VALUES (%s, %s, %s)",
            (other_channel_id, test_guild.id, "OtherChannel"),
        )

    _create_role(db_conn, test_guild.id, "2222222", "other-mods")

    _add_overwrite(
        db_conn,
        test_guild.id,
        other_channel_id,
        target_type=0,
        allow=SEND_MESSAGES,
        role_id="2222222",
    )

    body = _channel_overwrites(http_client, test_channel.id, test_session)
    assert len(body) == 1
    assert body[0]["target_id"] == "1111111"


def test_channel_overwrites_ordering(
    http_client, db_conn, test_guild, test_channel, test_user, test_session
):
    # roles (target_type=0) come before members (target_type=1),
    # ties break by target_id ascending; the seeded rows must satisfy
    # the overwrites_not_empty constraint (allow or deny non-zero)
    _create_role(db_conn, test_guild.id, "2222222", "role-b")
    _create_role(db_conn, test_guild.id, "1111111", "role-a")

    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        target_type=1,
        allow=READ_MESSAGES,
        user_id=test_user.id,
    )
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        target_type=0,
        allow=READ_MESSAGES,
        role_id="2222222",
    )
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        target_type=0,
        allow=READ_MESSAGES,
        role_id="1111111",
    )

    body = _channel_overwrites(http_client, test_channel.id, test_session)
    assert [(o["type"], o["target_id"]) for o in body] == [
        ("role", "1111111"),
        ("role", "2222222"),
        ("member", test_user.id),
    ]


def test_channel_list_embeds_overwrites(
    http_client, db_conn, test_guild, test_channel, test_session
):
    _create_role(db_conn, test_guild.id, "1111111", "mods")

    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        target_type=0,
        allow=READ_MESSAGES,
        role_id="1111111",
    )

    response = _get_channel_list(http_client, test_guild.id, test_session)
    assert response.status_code == 200, response.text

    channel = next(c for c in response.json() if c["id"] == test_channel.id)
    assert [(o["type"], o["target_id"]) for o in channel["overwrites"]] == [
        ("role", "1111111"),
    ]
