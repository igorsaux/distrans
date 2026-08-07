import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from permissions import (
    READ_MESSAGES,
    SEND_MESSAGES,
    DELETE_MESSAGES,
    CREATE_CHANNELS,
    MODIFY_CHANNELS,
    SKIP_ALLOWS,
    SKIP_DENIES,
)

from conftest import seed_role, system_create_channel


def _get_channels(http_client, test_session, guild_id):
    response = http_client.get(
        f"/api/guilds/{guild_id}/channels",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )
    assert response.status_code == 200

    return response.json()


def _insert_message(db_conn, channel_id, author_id, message_id, content="hi"):
    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.messages (id, channel_id, guild_id, author_id, content)"
            " SELECT %s, c.id, c.guild_id, %s, %s FROM app.channels c WHERE c.id = %s",
            (str(message_id), author_id, content, channel_id),
        )


def _delete_message(http_client, test_session, message_id):
    response = http_client.delete(
        f"/api/messages/{message_id}",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )
    assert response.status_code == 204


def _set_everyone_permissions(db_conn, guild_id, permissions):
    with db_conn.cursor() as cur:
        cur.execute(
            "UPDATE app.roles SET permissions = %s WHERE id = %s",
            (permissions.to_bytes(16), guild_id),
        )


def _add_everyone_overwrite(db_conn, guild_id, channel_id, allow=0, deny=0):
    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.overwrites"
            " (guild_id, channel_id, target_type, role_id, user_id, allow, deny)"
            " VALUES (%s, %s, 0, %s, NULL, %s, %s)",
            (
                guild_id,
                channel_id,
                guild_id,
                allow.to_bytes(16),
                deny.to_bytes(16),
            ),
        )


# R1
def test_get_guild_channels_unauthorized(http_client, test_guild):
    response = http_client.get(f"/api/guilds/{test_guild.id}/channels")

    assert response.status_code == 401


def test_get_guild_empty_channels(http_client, test_guild, test_session):
    response = http_client.get(
        f"/api/guilds/{test_guild.id}/channels",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
        },
    )
    assert response.status_code == 200

    body = response.json()
    assert len(body) == 0


def test_get_non_existent_guild_channels(http_client, test_session):
    response = http_client.get(
        "/api/guilds/2/channels",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
        },
    )
    assert response.status_code == 404

    body = response.json()

    assert body["message"] == "Guild not found"


def test_get_guild_channels(http_client, test_guild, test_channel, test_session):
    response = http_client.get(
        f"/api/guilds/{test_guild.id}/channels",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
        },
    )
    assert response.status_code == 200

    body = response.json()
    assert len(body) == 1

    channel = body[0]
    assert channel["id"] == test_channel.id
    assert channel["name"] == test_channel.name
    assert channel["kind"] == "channel"
    assert channel["parent_id"] is None
    assert channel["topic"] is None
    assert channel["position"] == 0


def test_get_guild_category(http_client, test_guild, test_category, test_session):
    response = http_client.get(
        f"/api/guilds/{test_guild.id}/channels",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
        },
    )
    assert response.status_code == 200

    body = response.json()
    assert len(body) == 1

    category = body[0]
    assert category["id"] == test_category.id
    assert category["name"] == test_category.name
    assert category["kind"] == "category"
    assert category["parent_id"] is None
    assert category["position"] == 0


def test_get_guild_channel_in_category(
    http_client, db_conn, test_guild, test_category, test_channel, test_session
):
    with db_conn.cursor() as cur:
        cur.execute(
            "UPDATE app.channels SET parent_id = %s WHERE id = %s",
            (test_category.id, test_channel.id),
        )

    response = http_client.get(
        f"/api/guilds/{test_guild.id}/channels",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
        },
    )
    assert response.status_code == 200

    body = response.json()
    assert len(body) == 2

    by_id = {item["id"]: item for item in body}

    category = by_id[test_category.id]
    assert category["kind"] == "category"
    assert category["parent_id"] is None

    channel = by_id[test_channel.id]
    assert channel["kind"] == "channel"
    assert channel["parent_id"] == test_category.id


# ---------------------------------------------------------------------------
# last_message_id
# ---------------------------------------------------------------------------


def test_last_message_id_null_without_messages(
    http_client, test_guild, test_channel, test_session
):
    body = _get_channels(http_client, test_session, test_guild.id)

    assert len(body) == 1
    assert body[0]["last_message_id"] is None


def test_last_message_id_reports_newest_message(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    _insert_message(db_conn, test_channel.id, test_user.id, 1)
    _insert_message(db_conn, test_channel.id, test_user.id, 2)

    body = _get_channels(http_client, test_session, test_guild.id)

    assert body[0]["last_message_id"] == "2"


def test_last_message_id_ignores_soft_deleted_messages(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    _insert_message(db_conn, test_channel.id, test_user.id, 1)
    _insert_message(db_conn, test_channel.id, test_user.id, 2)

    _delete_message(http_client, test_session, "2")

    body = _get_channels(http_client, test_session, test_guild.id)

    assert body[0]["last_message_id"] == "1"

    _delete_message(http_client, test_session, "1")

    body = _get_channels(http_client, test_session, test_guild.id)

    assert body[0]["last_message_id"] is None


def test_last_message_id_ignores_other_channels(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    other = system_create_channel(
        http_client, test_guild.id, name="Other", admin_token=test_guild.admin_token
    )

    _insert_message(db_conn, other.id, test_user.id, 5)
    _insert_message(db_conn, test_channel.id, test_user.id, 1)

    body = _get_channels(http_client, test_session, test_guild.id)

    by_id = {item["id"]: item for item in body}

    assert by_id[test_channel.id]["last_message_id"] == "1"
    assert by_id[other.id]["last_message_id"] == "5"


def test_last_message_id_per_channel_with_gaps(
    db_conn, http_client, test_guild, test_user, test_session
):
    # Regression for the loose-index-scan rewrite: many channels, most of them
    # empty, with sparse message ids. Each non-empty channel must report its own
    # newest message and every empty channel must stay null (the skip scan must
    # advance past empty channels, not stop at the first gap).
    channels = [
        system_create_channel(
            http_client,
            test_guild.id,
            name=f"gap-{i}",
            admin_token=test_guild.admin_token,
        )
        for i in range(8)
    ]

    _insert_message(db_conn, channels[0].id, test_user.id, 100)
    _insert_message(db_conn, channels[0].id, test_user.id, 130)
    _insert_message(db_conn, channels[3].id, test_user.id, 200)
    _insert_message(db_conn, channels[7].id, test_user.id, 250)
    _insert_message(db_conn, channels[7].id, test_user.id, 260)

    body = _get_channels(http_client, test_session, test_guild.id)
    by_id = {item["id"]: item for item in body}

    assert by_id[channels[0].id]["last_message_id"] == "130"
    assert by_id[channels[3].id]["last_message_id"] == "200"
    assert by_id[channels[7].id]["last_message_id"] == "260"

    for empty in (channels[1], channels[2], channels[4], channels[5], channels[6]):
        assert by_id[empty.id]["last_message_id"] is None


def test_last_message_id_null_for_category(
    http_client, test_guild, test_category, test_session
):
    body = _get_channels(http_client, test_session, test_guild.id)

    assert len(body) == 1
    assert body[0]["kind"] == "category"
    assert body[0]["last_message_id"] is None


def test_last_message_id_exposed_without_read_messages(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    _insert_message(db_conn, test_channel.id, test_user.id, 7)

    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES | SEND_MESSAGES)
    _add_everyone_overwrite(
        db_conn, test_guild.id, test_channel.id, deny=READ_MESSAGES
    )

    body = _get_channels(http_client, test_session, test_guild.id)

    # The "expose for all" decision: the list is not permission-filtered, so
    # last_message_id is still reported even when the caller cannot read.
    assert body[0]["last_message_id"] == "7"

    messages = http_client.get(
        f"/api/channels/{test_channel.id}/messages",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )
    assert messages.status_code == 403


def test_get_channel_reports_last_message_id(
    db_conn, http_client, test_channel, test_user, test_session
):
    response = http_client.get(
        f"/api/channels/{test_channel.id}",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )
    assert response.status_code == 200
    assert response.json()["last_message_id"] is None

    _insert_message(db_conn, test_channel.id, test_user.id, 3)
    _insert_message(db_conn, test_channel.id, test_user.id, 4)

    response = http_client.get(
        f"/api/channels/{test_channel.id}",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )
    assert response.status_code == 200
    assert response.json()["last_message_id"] == "4"


def test_channel_list_ordering_with_messages(
    db_conn, http_client, test_guild, test_user, test_session
):
    # The join must not reorder rows: root channels follow root order, each
    # child follows its category.
    alpha = system_create_channel(
        http_client, test_guild.id, name="Alpha", admin_token=test_guild.admin_token
    )
    category = system_create_channel(
        http_client,
        test_guild.id,
        name="Category",
        kind="category",
        admin_token=test_guild.admin_token,
    )
    beta = system_create_channel(
        http_client,
        test_guild.id,
        name="Beta",
        kind="channel",
        parent_id=category.id,
        admin_token=test_guild.admin_token,
    )

    _insert_message(db_conn, alpha.id, test_user.id, 10)
    _insert_message(db_conn, beta.id, test_user.id, 11)

    body = _get_channels(http_client, test_session, test_guild.id)

    assert [item["id"] for item in body] == [alpha.id, category.id, beta.id]


# ---------------------------------------------------------------------------
# permissions (effective channel mask of the requesting user)
# ---------------------------------------------------------------------------


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


def _assign_role(db_conn, guild_id, user_id, role_id):
    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.member_roles (guild_id, role_id, user_id)"
            " VALUES (%s, %s, %s)",
            (guild_id, role_id, user_id),
        )


def _permissions_of(body, channel_id):
    for item in body:
        if item["id"] == channel_id:
            return item["permissions"]

    raise AssertionError(f"channel {channel_id} missing from the list")


def test_permissions_are_decimal_strings(
    http_client, db_conn, test_guild, test_channel, test_category, test_session
):
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES | SEND_MESSAGES)

    body = _get_channels(http_client, test_session, test_guild.id)
    assert body

    for item in body:
        assert isinstance(item["permissions"], str)
        assert item["permissions"].isdigit()


def test_permissions_default_to_base_without_overwrites(
    http_client, db_conn, test_guild, test_channel, test_session
):
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES | SEND_MESSAGES)

    body = _get_channels(http_client, test_session, test_guild.id)

    assert _permissions_of(body, test_channel.id) == str(
        READ_MESSAGES | SEND_MESSAGES
    )


def test_permissions_reflect_everyone_overwrite_deny(
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

    body = _get_channels(http_client, test_session, test_guild.id)

    assert _permissions_of(body, test_channel.id) == str(SEND_MESSAGES)


def test_permissions_reflect_everyone_overwrite_allow(
    http_client, db_conn, test_guild, test_channel, test_session
):
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES)
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        target_type=0,
        allow=SEND_MESSAGES,
        role_id=test_guild.id,
    )

    body = _get_channels(http_client, test_session, test_guild.id)

    assert _permissions_of(body, test_channel.id) == str(
        READ_MESSAGES | SEND_MESSAGES
    )


def test_permissions_reflect_role_and_member_overwrites(
    http_client, db_conn, test_guild, test_channel, test_user, test_session
):
    _set_everyone_permissions(db_conn, test_guild.id, 0)
    seed_role(db_conn, test_guild.id, "910001", "viewer", position=1, permissions=0)
    _assign_role(db_conn, test_guild.id, test_user.id, "910001")

    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        target_type=0,
        allow=READ_MESSAGES,
        role_id="910001",
    )
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        target_type=1,
        allow=SEND_MESSAGES,
        user_id=test_user.id,
    )

    body = _get_channels(http_client, test_session, test_guild.id)

    assert _permissions_of(body, test_channel.id) == str(
        READ_MESSAGES | SEND_MESSAGES
    )


def test_permissions_honor_skip_denies(
    http_client, db_conn, test_guild, test_channel, test_session
):
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES | SKIP_DENIES)
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        target_type=0,
        deny=READ_MESSAGES,
        role_id=test_guild.id,
    )

    body = _get_channels(http_client, test_session, test_guild.id)

    # The deny mask is inert because skip_denies comes from the base.
    assert _permissions_of(body, test_channel.id) == str(
        READ_MESSAGES | SKIP_DENIES
    )


def test_permissions_honor_skip_allows(
    http_client, db_conn, test_guild, test_channel, test_session
):
    _set_everyone_permissions(db_conn, test_guild.id, SKIP_ALLOWS)
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        target_type=0,
        allow=READ_MESSAGES,
        role_id=test_guild.id,
    )

    body = _get_channels(http_client, test_session, test_guild.id)

    # The allow mask is inert because skip_allows comes from the base.
    assert _permissions_of(body, test_channel.id) == str(SKIP_ALLOWS)


def test_permissions_expose_mutation_bits_without_read(
    http_client, db_conn, test_guild, test_channel, test_session
):
    # A channel can carry visibility-relevant bits without read_messages.
    _set_everyone_permissions(db_conn, test_guild.id, MODIFY_CHANNELS | DELETE_MESSAGES)

    body = _get_channels(http_client, test_session, test_guild.id)

    assert _permissions_of(body, test_channel.id) == str(
        MODIFY_CHANNELS | DELETE_MESSAGES
    )


def test_permissions_category_carries_guild_bits(
    http_client, db_conn, test_guild, test_category, test_session
):
    _set_everyone_permissions(db_conn, test_guild.id, CREATE_CHANNELS)

    body = _get_channels(http_client, test_session, test_guild.id)

    assert _permissions_of(body, test_category.id) == str(CREATE_CHANNELS)


def test_permissions_are_per_channel(
    http_client, db_conn, test_guild, test_channel, test_session
):
    other = system_create_channel(
        http_client, test_guild.id, name="Other", admin_token=test_guild.admin_token
    )

    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES | SEND_MESSAGES)
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        target_type=0,
        deny=READ_MESSAGES,
        role_id=test_guild.id,
    )

    body = _get_channels(http_client, test_session, test_guild.id)

    assert _permissions_of(body, test_channel.id) == str(SEND_MESSAGES)
    assert _permissions_of(body, other.id) == str(
        READ_MESSAGES | SEND_MESSAGES
    )


def test_permissions_match_single_channel_get(
    http_client, db_conn, test_guild, test_channel, test_session
):
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES | SEND_MESSAGES)
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        target_type=0,
        deny=SEND_MESSAGES,
        role_id=test_guild.id,
    )

    body = _get_channels(http_client, test_session, test_guild.id)

    response = http_client.get(
        f"/api/channels/{test_channel.id}",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )
    assert response.status_code == 200

    # The batch formula and the single-channel formula must agree bit for bit.
    assert response.json()["permissions"] == _permissions_of(body, test_channel.id)
    assert response.json()["permissions"] == str(READ_MESSAGES)
