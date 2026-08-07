# Changed-since guild sync: `GET /api/guilds/{guild_id}/sync`.
#
# Covers R1 (auth), R2 (`since` validation), R3 (guild exists), and the
# id-array / upsert contract including the caller's full `member_roles` set.

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from conftest import CONFIG, system_create_channel

MAX_LOOKBACK_S = CONFIG["api"]["sync"]["max_lookback_s"]


def _headers(token):
    return {"Authorization": f"Bearer {token}"}


def _since_too_old_ms():
    return int((time.time() - (MAX_LOOKBACK_S + 3600)) * 1000)


# R1
def test_guild_sync_unauthorized(http_client, test_guild):
    response = http_client.get(f"/api/guilds/{test_guild.id}/sync")

    assert response.status_code == 401


def test_guild_sync_unknown_parameter(http_client, test_guild, test_session):
    response = http_client.get(
        f"/api/guilds/{test_guild.id}/sync",
        headers=_headers(test_session.access_token),
        params={"nope": 1},
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Unknown parameter"


# R2
def test_guild_sync_invalid_since(http_client, test_guild, test_session):
    response = http_client.get(
        f"/api/guilds/{test_guild.id}/sync",
        headers=_headers(test_session.access_token),
        params={"since": "not-a-number"},
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'since' is invalid"


# R2
def test_guild_sync_too_old_since(http_client, test_guild, test_session):
    response = http_client.get(
        f"/api/guilds/{test_guild.id}/sync",
        headers=_headers(test_session.access_token),
        params={"since": _since_too_old_ms()},
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'since' is too old"


# R3
def test_guild_sync_missing_guild(http_client, test_session):
    response = http_client.get(
        "/api/guilds/999999999999999999/sync",
        headers=_headers(test_session.access_token),
    )

    assert response.status_code == 404
    assert response.json()["message"] == "Guild not found"


def test_guild_sync_shape(http_client, test_guild, test_session):
    response = http_client.get(
        f"/api/guilds/{test_guild.id}/sync",
        headers=_headers(test_session.access_token),
    )

    assert response.status_code == 200

    body = response.json()
    assert isinstance(body["updated_at"], int)
    assert set(body.keys()) == {
        "updated_at",
        "channels",
        "roles",
        "emojis",
        "overwrites",
        "member_roles",
    }
    # @everyone is always present.
    assert test_guild.id in body["roles"]


def test_guild_sync_reports_changed_channel(
    http_client, test_guild, test_session
):
    cursor = http_client.get(
        f"/api/guilds/{test_guild.id}/sync",
        headers=_headers(test_session.access_token),
    ).json()["updated_at"]

    time.sleep(0.05)

    channel = system_create_channel(
        http_client,
        test_guild.id,
        name="Synced",
        admin_token=test_guild.admin_token,
    )

    body = http_client.get(
        f"/api/guilds/{test_guild.id}/sync",
        headers=_headers(test_session.access_token),
        params={"since": cursor},
    ).json()

    assert channel.id in body["channels"]

    # Advancing the cursor from the response yields an empty delta.
    body2 = http_client.get(
        f"/api/guilds/{test_guild.id}/sync",
        headers=_headers(test_session.access_token),
        params={"since": body["updated_at"]},
    ).json()

    assert body2["channels"] == []


def test_guild_sync_reports_overwrites_with_channel_id(
    http_client, test_guild, test_channel, test_session, db_conn
):
    cursor = http_client.get(
        f"/api/guilds/{test_guild.id}/sync",
        headers=_headers(test_session.access_token),
    ).json()["updated_at"]

    time.sleep(0.05)

    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.overwrites"
            " (guild_id, channel_id, target_type, role_id, user_id, allow, deny)"
            " VALUES (%s, %s, 0, %s, NULL, %s, %s)",
            (
                test_guild.id,
                test_channel.id,
                test_guild.id,
                (0).to_bytes(16),
                (1).to_bytes(16),
            ),
        )

    body = http_client.get(
        f"/api/guilds/{test_guild.id}/sync",
        headers=_headers(test_session.access_token),
        params={"since": cursor},
    ).json()

    assert {
        "channel_id": str(test_channel.id),
        "target_id": str(test_guild.id),
        "type": "role",
    } in body["overwrites"]


def test_guild_sync_member_roles_includes_everyone(
    http_client, test_guild, test_session
):
    # `test_user` holds no granted role, so its only effective role is the
    # implicit `@everyone` (id == guild id). Dropping it here would zero the
    # client's guild base permissions and hide read/send on every channel.
    body = http_client.get(
        f"/api/guilds/{test_guild.id}/sync",
        headers=_headers(test_session.access_token),
    ).json()

    assert test_guild.id in body["member_roles"]


def test_guild_sync_member_roles_is_full_set(
    http_client, test_guild, test_user, test_session
):
    admin = _headers(test_guild.admin_token)

    role = http_client.post(
        f"/api/guilds/{test_guild.id}/roles",
        headers=admin,
        json={"name": "Synced", "permissions": "0"},
    ).json()

    # Grant, then the caller's sync must include the granted role alongside the
    # always-present `@everyone`.
    assert (
        http_client.put(
            f"/api/roles/{role['id']}/users/{test_user.id}", headers=admin
        ).status_code
        == 204
    )

    body = http_client.get(
        f"/api/guilds/{test_guild.id}/sync",
        headers=_headers(test_session.access_token),
    ).json()

    assert role["id"] in body["member_roles"]
    assert test_guild.id in body["member_roles"]

    # Revoke, then the next sync must not include it (full-set, not a delta)
    # while `@everyone` stays.
    assert (
        http_client.delete(
            f"/api/roles/{role['id']}/users/{test_user.id}", headers=admin
        ).status_code
        == 204
    )

    body = http_client.get(
        f"/api/guilds/{test_guild.id}/sync",
        headers=_headers(test_session.access_token),
    ).json()

    assert role["id"] not in body["member_roles"]
    assert test_guild.id in body["member_roles"]
