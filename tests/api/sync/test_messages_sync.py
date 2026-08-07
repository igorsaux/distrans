# Changed-since message sync: `GET /api/channels/{channel_id}/messages/sync`.
#
# Covers R1 (auth), R2 (`since` validation), R3 (channel exists), R4
# (`read_messages`), and the id-array / upsert contract including soft deletes.

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from conftest import CONFIG

MAX_LOOKBACK_S = CONFIG["api"]["sync"]["max_lookback_s"]


def _headers(token):
    return {"Authorization": f"Bearer {token}"}


def _since_too_old_ms():
    return int((time.time() - (MAX_LOOKBACK_S + 3600)) * 1000)


def _post_message(http_client, token, channel_id, content="hello"):
    response = http_client.post(
        f"/api/channels/{channel_id}/messages",
        headers=_headers(token),
        json={"content": content},
    )

    assert response.status_code == 201

    return response.json()["id"]


def _sync(http_client, token, channel_id, since=None):
    params = {} if since is None else {"since": since}

    return http_client.get(
        f"/api/channels/{channel_id}/messages/sync",
        headers=_headers(token),
        params=params,
    )


# R1
def test_messages_sync_unauthorized(http_client, test_channel):
    response = http_client.get(f"/api/channels/{test_channel.id}/messages/sync")

    assert response.status_code == 401


# R2
def test_messages_sync_invalid_since(http_client, test_channel, test_session):
    response = _sync(
        http_client, test_session.access_token, test_channel.id, since="nope"
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'since' is invalid"


# R2
def test_messages_sync_too_old_since(http_client, test_channel, test_session):
    response = _sync(
        http_client,
        test_session.access_token,
        test_channel.id,
        since=_since_too_old_ms(),
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'since' is too old"


# R3
def test_messages_sync_missing_channel(http_client, test_session):
    response = _sync(
        http_client, test_session.access_token, 999999999999999999
    )

    assert response.status_code == 404
    assert response.json()["message"] == "Channel not found"


# R4
def test_messages_sync_forbidden_without_read_messages(
    http_client, test_guild, test_channel, test_session, db_conn
):
    # Strip every @everyone permission so the caller cannot read messages.
    with db_conn.cursor() as cur:
        cur.execute(
            "UPDATE app.roles SET permissions = %s WHERE id = %s",
            ((0).to_bytes(16), test_guild.id),
        )

    response = _sync(http_client, test_session.access_token, test_channel.id)

    assert response.status_code == 403
    assert response.json()["message"] == "Missing permissions"


def test_messages_sync_reports_created_and_edited(http_client, test_guild, test_channel):
    token = test_guild.admin_token

    cursor = _sync(http_client, token, test_channel.id).json()["updated_at"]

    time.sleep(0.05)

    message_id = _post_message(http_client, token, test_channel.id, "first")

    body = _sync(http_client, token, test_channel.id, since=cursor).json()
    assert message_id in body["messages"]

    # Advancing the cursor yields an empty delta.
    next_cursor = body["updated_at"]
    assert _sync(http_client, token, test_channel.id, since=next_cursor).json()[
        "messages"
    ] == []

    # An edit must bump the row back into the delta.
    time.sleep(0.05)

    assert (
        http_client.patch(
            f"/api/messages/{message_id}",
            headers=_headers(token),
            json={"content": "edited"},
        ).status_code
        == 200
    )

    body = _sync(http_client, token, test_channel.id, since=next_cursor).json()
    assert message_id in body["messages"]


def test_messages_sync_reports_soft_deleted(http_client, test_guild, test_channel):
    token = test_guild.admin_token

    message_id = _post_message(http_client, token, test_channel.id, "doomed")

    cursor = _sync(http_client, token, test_channel.id).json()["updated_at"]

    time.sleep(0.05)

    assert (
        http_client.delete(
            f"/api/messages/{message_id}", headers=_headers(token)
        ).status_code
        == 204
    )

    # A soft-deleted row stays present, so it is listed as changed; the client
    # drops it after fetching and seeing `deleted_at`.
    body = _sync(http_client, token, test_channel.id, since=cursor).json()
    assert message_id in body["messages"]
