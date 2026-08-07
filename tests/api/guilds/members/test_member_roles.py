import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from conftest import seed_role  # noqa: E402
from permissions import READ_MESSAGES, SEND_MESSAGES  # noqa: E402


def _create_role(db_conn, guild_id, role_id, name, position=0):
    # defaultEveryone(): read_messages | send_messages
    seed_role(db_conn, guild_id, role_id, name, position, READ_MESSAGES | SEND_MESSAGES)


def _assign_role(db_conn, guild_id, user_id, role_id):
    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.member_roles (guild_id, user_id, role_id)"
            " VALUES (%s, %s, %s)",
            (guild_id, user_id, role_id),
        )


def _create_user(db_conn, user_id, username):
    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.users (id, username) VALUES (%s, %s)",
            (user_id, username),
        )


def _get_member_roles(http_client, test_session, guild_id, user_id):
    return http_client.get(
        f"/api/guilds/{guild_id}/members/{user_id}/roles",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
        },
    )


# R1
def test_get_member_roles_unauthorized(http_client, test_guild, test_user):
    response = http_client.get(f"/api/guilds/{test_guild.id}/members/{test_user.id}/roles")

    assert response.status_code == 401


def test_get_non_existent_guild_member_roles(http_client, test_session, test_user):
    response = _get_member_roles(http_client, test_session, "2", test_user.id)

    assert response.status_code == 404

    body = response.json()

    assert body["message"] == "Guild not found"


def test_get_roles_of_non_existent_member(http_client, test_guild, test_session):
    response = _get_member_roles(http_client, test_session, test_guild.id, "2")

    assert response.status_code == 404

    body = response.json()

    assert body["message"] == "User not found"


def test_get_member_roles_invalid_user_id(http_client, test_guild, test_session):
    response = _get_member_roles(http_client, test_session, test_guild.id, "not-a-number")

    assert response.status_code == 400


def test_get_member_roles_everyone_only(http_client, test_guild, test_user, test_session):
    response = _get_member_roles(http_client, test_session, test_guild.id, test_user.id)

    assert response.status_code == 200

    body = response.json()

    # role ids are returned as strings for JS BigInt compatibility
    assert body == [test_guild.id]


def test_get_member_roles_ordering_by_position(
    http_client, db_conn, test_guild, test_user, test_session
):
    _create_role(db_conn, test_guild.id, "1111111", "mods", position=1)
    _create_role(db_conn, test_guild.id, "2222222", "admins", position=2)

    _assign_role(db_conn, test_guild.id, test_user.id, "1111111")
    _assign_role(db_conn, test_guild.id, test_user.id, "2222222")

    response = _get_member_roles(http_client, test_session, test_guild.id, test_user.id)

    assert response.status_code == 200

    body = response.json()

    assert body == ["2222222", "1111111", test_guild.id]


def test_get_member_roles_ordering_desc(
    http_client, db_conn, test_guild, test_user, test_session
):
    # Positions are unique per guild; a higher position sorts first.
    _create_role(db_conn, test_guild.id, "3333333", "role-a", position=1)
    _create_role(db_conn, test_guild.id, "4444444", "role-b", position=2)

    _assign_role(db_conn, test_guild.id, test_user.id, "3333333")
    _assign_role(db_conn, test_guild.id, test_user.id, "4444444")

    response = _get_member_roles(http_client, test_session, test_guild.id, test_user.id)

    assert response.status_code == 200

    body = response.json()

    assert body == ["4444444", "3333333", test_guild.id]


def test_get_member_roles_not_leaked_from_other_users(
    http_client, db_conn, test_guild, test_user, test_session
):
    other_user_id = "8888888"
    _create_user(db_conn, other_user_id, "other")

    _create_role(db_conn, test_guild.id, "5555555", "mods", position=1)
    _assign_role(db_conn, test_guild.id, other_user_id, "5555555")

    response = _get_member_roles(http_client, test_session, test_guild.id, test_user.id)

    assert response.status_code == 200

    body = response.json()

    assert body == [test_guild.id]


def test_get_member_roles_only_from_requested_guild(
    http_client, db_conn, test_guild, test_user, test_session
):
    other_guild_id = "6666666"

    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.guilds (id, name) VALUES (%s, %s)",
            (other_guild_id, "OtherGuild"),
        )

    _create_role(db_conn, other_guild_id, other_guild_id, "@everyone")
    _create_role(db_conn, other_guild_id, "7777777", "other-mods", position=1)

    _assign_role(db_conn, other_guild_id, test_user.id, "7777777")

    response = _get_member_roles(http_client, test_session, test_guild.id, test_user.id)

    assert response.status_code == 200

    body = response.json()

    assert body == [test_guild.id]
