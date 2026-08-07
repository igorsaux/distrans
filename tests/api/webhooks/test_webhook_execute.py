# Tests for POST /api/webhooks/{webhook_id}/{token} (execute).
#
# Requirement numbering mirrors src/route/webhooks/id/token.zig.
#
#   R1 - the webhook exists, is live and the token hashes to token_hash (404)
#   R2 - application/json, non-empty body
#   R3 - the message payload is validated exactly like
#        POST /api/channels/{channel_id}/messages R5-R11
#   R4 - the message is stored as the webhook and 201 {"id"} is returned; the
#        gateway event and notifications are emitted like a user message

import base64
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # tests/api
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "notifications"))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "files"))

from conftest import CONFIG, system_create_user, system_login  # noqa: E402
from mock_push import ENDPOINT  # noqa: E402
from test_gateway import GatewayClient  # noqa: E402
from webhooks_common import (  # noqa: E402
    auth,
    create_webhook,
    delete_webhook,
    execute_webhook,
    get_messages,
    insert_file,
)

PUBLIC_BASE_URL = CONFIG["files"]["s3"]["public_base_url"]

P256DH = "BGsX0fLhLEJH-Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT-NC4v4af5uO5-tKfA-eFivOM1drMV7Oy7ZAaDe_UfU"  # P-256 generator
AUTH = base64.urlsafe_b64encode(b"\x44" * 16).rstrip(b"=").decode()


def wait_for_push(mock, count=1, timeout=8.0):
    deadline = time.monotonic() + timeout

    while time.monotonic() < deadline:
        if mock.count() >= count:
            return mock.all()

        time.sleep(0.05)

    pytest.fail(f"expected {count} push request(s), got {mock.count()}")


# R1 - an unknown webhook is 404
def test_execute_unknown_webhook(http_client):
    response = execute_webhook(http_client, 1, "sometoken", {"content": "hi"})

    assert response.status_code == 404
    assert response.json()["message"] == "Webhook not found"


# R1 - a wrong token is 404
def test_execute_wrong_token(http_client, test_guild, test_channel):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    response = execute_webhook(http_client, created["id"], "wrong-token", {"content": "hi"})

    assert response.status_code == 404


# R1 - a soft-deleted webhook cannot execute
def test_execute_after_delete(http_client, test_guild, test_channel):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )
    delete_webhook(http_client, test_guild.admin_token, created["id"])

    response = execute_webhook(
        http_client, created["id"], created["token"], {"content": "hi"}
    )

    assert response.status_code == 404


# R2
def test_execute_empty_body(http_client, test_guild, test_channel):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    response = http_client.post(
        f"/api/webhooks/{created['id']}/{created['token']}", content=b""
    )

    assert response.status_code == 400


# R2
def test_execute_wrong_content_type(http_client, test_guild, test_channel):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    response = http_client.post(
        f"/api/webhooks/{created['id']}/{created['token']}",
        content=b'{"content": "hi"}',
        headers={"Content-Type": "text/plain"},
    )

    assert response.status_code == 415
    assert response.json()["message"] == "Unsupported Media Type"


# R3 - the shared message-create pipeline rejects bad payloads identically
def test_execute_missing_content(http_client, test_guild, test_channel):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    response = execute_webhook(http_client, created["id"], created["token"], {})

    assert response.status_code == 400
    assert response.json()["message"] == "'content' is missing"


# R4 - a plain message is stored as the webhook
def test_execute_creates_message(
    http_client, test_guild, test_channel, test_session
):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="poster"
    )

    response = execute_webhook(
        http_client, created["id"], created["token"], {"content": "from a webhook"}
    )

    assert response.status_code == 201, response.content
    message_id = response.json()["id"]

    messages = get_messages(http_client, test_session.access_token, test_channel.id)
    message = next(m for m in messages if m["id"] == message_id)

    assert message["content"] == "from a webhook"
    assert message["webhook_id"] == created["id"]
    assert message["author_id"] is None
    assert message["attachments"] == []


# R3 - forbidden codepoints are stripped like a user message
def test_execute_sanitizes_content(
    http_client, test_guild, test_channel, test_session
):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    response = execute_webhook(
        http_client, created["id"], created["token"], {"content": "a\u200bb"}
    )

    assert response.status_code == 201

    messages = get_messages(http_client, test_session.access_token, test_channel.id)
    message = next(m for m in messages if m["id"] == response.json()["id"])
    assert message["content"] == "ab"


# R3 - embeds pass through
def test_execute_with_embeds(http_client, test_guild, test_channel, test_session):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    response = execute_webhook(
        http_client,
        created["id"],
        created["token"],
        {
            "content": "look",
            "embeds": [{"type": "rich", "title": "Title", "description": "Body"}],
        },
    )

    assert response.status_code == 201

    messages = get_messages(http_client, test_session.access_token, test_channel.id)
    message = next(m for m in messages if m["id"] == response.json()["id"])
    assert message["embeds"][0]["title"] == "Title"
    assert message["embeds"][0]["description"] == "Body"


# R3 - attachments are derived from the content
def test_execute_with_attachments(
    db_conn, http_client, test_guild, test_channel, test_session
):
    insert_file(db_conn, 100)

    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    response = execute_webhook(
        http_client,
        created["id"],
        created["token"],
        {"content": "[f](attachment://100)"},
    )

    assert response.status_code == 201, response.content

    expected = [
        {
            "id": "100",
            "name": "f.webp",
            "size": 10,
            "content_type": "image/webp",
            "hash": f"{100:064d}",
            "public_url": f"{PUBLIC_BASE_URL}/files/{100:064d}",
        }
    ]

    # The create response already carries the resolved attachments.
    assert response.json()["attachments"] == expected

    messages = get_messages(http_client, test_session.access_token, test_channel.id)
    message = next(m for m in messages if m["id"] == response.json()["id"])

    assert message["attachments"] == expected


# R3 - mentions are parsed and allowed_mentions filters them
def test_execute_with_mentions(
    http_client, test_guild, test_channel, test_user, test_session
):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    response = execute_webhook(
        http_client,
        created["id"],
        created["token"],
        {"content": f"hey <@{test_user.id}>"},
    )

    assert response.status_code == 201

    messages = get_messages(http_client, test_session.access_token, test_channel.id)
    message = next(m for m in messages if m["id"] == response.json()["id"])
    assert message["mentions"] == [test_user.id]


# R3 - allowed_mentions can drop the parsed mention without rewriting content
def test_execute_allowed_mentions_filters(
    http_client, test_guild, test_channel, test_user, test_session
):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    response = execute_webhook(
        http_client,
        created["id"],
        created["token"],
        {
            "content": f"hey <@{test_user.id}>",
            "allowed_mentions": {"parse": []},
        },
    )

    assert response.status_code == 201

    messages = get_messages(http_client, test_session.access_token, test_channel.id)
    message = next(m for m in messages if m["id"] == response.json()["id"])
    assert message["mentions"] == []
    assert f"<@{test_user.id}>" in message["content"]


# R1 - the execute token is not a bearer credential
def test_execute_token_cannot_manage(http_client, test_guild, test_channel):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    response = http_client.get(
        f"/api/webhooks/{created['id']}", headers=auth(created["token"])
    )

    assert response.status_code == 401


# R4 - the gateway gets a message_created event
def test_execute_dispatches_message_created(
    http_client, test_guild, test_channel, test_session
):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_session.access_token}})
    assert ws.recv_json()["op"] == "hello"

    response = execute_webhook(
        http_client, created["id"], created["token"], {"content": "event"}
    )
    assert response.status_code == 201
    message_id = response.json()["id"]

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "message_created"
    assert event["d"] == {
        "id": str(message_id),
        "channel_id": str(test_channel.id),
        "guild_id": str(test_guild.id),
    }

    ws.close()


# R4 - a webhook message notifies mentioned users (author_id NULL must not drop
# the push; this pins the LEFT JOIN in GetMessageForPush)
def test_execute_delivers_push(
    http_client, push_mock, test_guild, test_channel
):
    recipient = system_create_user(http_client, username="wh_recipient")
    access_token, _ = system_login(http_client, "wh_recipient")

    response = http_client.post(
        "/api/users/@me/push-subscriptions",
        headers=auth(access_token),
        json={
            "endpoint": f"{ENDPOINT}/push/webhook",
            "p256dh": P256DH,
            "auth": AUTH,
        },
    )
    assert response.status_code == 201

    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    response = execute_webhook(
        http_client,
        created["id"],
        created["token"],
        {"content": f"hey <@{recipient['id']}>"},
    )
    assert response.status_code == 201

    requests = wait_for_push(push_mock, 1)
    assert requests[0]["path"] == "/push/webhook"
    assert requests[0]["headers"]["content-encoding"] == "aes128gcm"
