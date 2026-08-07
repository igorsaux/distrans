# defaultEveryone(): read_messages | send_messages | add_reactions
# (mirrors the shared bit constants, which mirror src/types.zig)
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from permissions import ADD_REACTIONS, READ_MESSAGES, SEND_MESSAGES

DEFAULT_EVERYONE_PERMISSIONS = str(READ_MESSAGES | SEND_MESSAGES | ADD_REACTIONS)


# R1
def test_get_guild_roles_unauthorized(http_client, test_guild):
    response = http_client.get(f"/api/guilds/{test_guild.id}/roles")

    assert response.status_code == 401


def test_get_non_existent_guild_roles(http_client, test_session):
    response = http_client.get(
        "/api/guilds/2/roles",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
        },
    )
    assert response.status_code == 404

    body = response.json()

    assert body["message"] == "Guild not found"


def test_get_guild_roles(http_client, test_guild, test_session):
    response = http_client.get(
        f"/api/guilds/{test_guild.id}/roles",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
        },
    )

    assert response.status_code == 200

    body = response.json()
    # The test_guild fixture adds a superuser role for guild_admin.
    assert len(body) == 2

    role = next(role for role in body if role["id"] == test_guild.id)
    assert role["name"] == "@everyone"
    assert role["position"] == 0
    # permissions are returned as a decimal string for JS BigInt compatibility
    assert role["permissions"] == DEFAULT_EVERYONE_PERMISSIONS
    assert role["color"] is None
    assert role["mentionable"] is True

    # The fixture's superuser role sits on top (MAX(position) + 1); with only
    # @everyone below it that is position 1.
    superuser = next(role for role in body if role["name"] == "superuser")
    assert superuser["position"] == 1


def test_get_guild_roles_superuser_position_is_top(http_client, db_conn, test_guild):
    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT position FROM app.roles"
            " WHERE guild_id = %s AND name = 'superuser'",
            (test_guild.id,),
        )
        row = cur.fetchone()

    assert row is not None
    assert row["position"] == 1


def test_get_guild_roles_inserted_without_permissions_use_default_everyone(
    http_client, db_conn, test_guild, test_session
):
    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.roles (id, guild_id, name, position)"
            " VALUES (%s, %s, %s, %s)",
            ("9523143", test_guild.id, "mods", 2),
        )

    response = http_client.get(
        f"/api/guilds/{test_guild.id}/roles",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
        },
    )

    assert response.status_code == 200

    body = response.json()
    # @everyone + the fixture's superuser role + the inserted role.
    assert len(body) == 3

    mods = next(role for role in body if role["name"] == "mods")
    assert mods["position"] == 2
    assert mods["permissions"] == DEFAULT_EVERYONE_PERMISSIONS
    assert mods["color"] is None


def test_get_guild_roles_custom_permissions(
    http_client, db_conn, test_guild, test_session
):
    # 16-byte big-endian literal: read_messages=false, send_messages and
    # add_reactions stay set.
    custom_permissions = int(DEFAULT_EVERYONE_PERMISSIONS) ^ READ_MESSAGES

    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.roles (id, guild_id, name, position, permissions)"
            " VALUES (%s, %s, %s, %s, %s)",
            ("9523144", test_guild.id, "muted", 2, custom_permissions.to_bytes(16)),
        )

    response = http_client.get(
        f"/api/guilds/{test_guild.id}/roles",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
        },
    )

    assert response.status_code == 200

    body = response.json()
    # @everyone + the fixture's superuser role + the inserted role.
    assert len(body) == 3

    muted = next(role for role in body if role["name"] == "muted")
    assert muted["permissions"] == str(custom_permissions)


def test_get_guild_roles_color(http_client, db_conn, test_guild, test_session):
    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.roles (id, guild_id, name, position, color)"
            " VALUES (%s, %s, %s, %s, %s)",
            ("9523145", test_guild.id, "green", 2, 65280),
        )

    response = http_client.get(
        f"/api/guilds/{test_guild.id}/roles",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
        },
    )

    assert response.status_code == 200

    body = response.json()

    green = next(role for role in body if role["name"] == "green")
    assert green["color"] == 65280

    # Roles without a color expose null.
    everyone = next(role for role in body if role["id"] == test_guild.id)
    assert everyone["color"] is None
