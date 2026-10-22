# Tests for GET/PATCH/DELETE
# /api/webhooks/{webhook_id}/{token}/messages/{message_id}.
#
# Requirement numbering mirrors src/route/webhooks/id/messages.zig.
#
#   R1 - the webhook exists, is live and the token hashes to token_hash (404)
#   R2 - the message is live, belongs to the webhook's channel and was posted
#        by this webhook (404)
#   R3 - GET returns the canonical message; PATCH validates the body; DELETE
#        soft-deletes the message

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # tests/api
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "files"))

from conftest import CONFIG  # noqa: E402
from test_gateway import GatewayClient  # noqa: E402
from webhooks_common import (  # noqa: E402
    auth,
    create_webhook,
    delete_webhook,
    delete_webhook_message,
    execute_webhook,
    get_webhook_message,
    insert_file,
    patch_webhook_message,
)


def _post_user_message(http_client, test_session, channel_id, payload):
    response = http_client.post(
        f"/api/channels/{channel_id}/messages",
        headers=auth(test_session.access_token),
        json=payload,
    )
    assert response.status_code == 201, response.content

    return response.json()


def _create_webhook_message(http_client, test_guild, test_channel, name="hook"):
    webhook = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name=name
    )
    response = execute_webhook(
        http_client, webhook["id"], webhook["token"], {"content": "original"}
    )
    assert response.status_code == 201, response.content

    return webhook, response.json()


def _get(http_client, webhook, message_id):
    return get_webhook_message(
        http_client, webhook["id"], webhook["token"], message_id
    )


def _patch(http_client, webhook, message_id, payload):
    return patch_webhook_message(
        http_client, webhook["id"], webhook["token"], message_id, payload
    )


def _delete(http_client, webhook, message_id):
    return delete_webhook_message(
        http_client, webhook["id"], webhook["token"], message_id
    )


# R1, R2, R3 - a webhook can read its own message
def test_get_webhook_message(http_client, test_guild, test_channel):
    webhook, message = _create_webhook_message(http_client, test_guild, test_channel)

    response = _get(http_client, webhook, message["id"])

    assert response.status_code == 200, response.content

    body = response.json()
    assert body["id"] == message["id"]
    assert body["channel_id"] == str(test_channel.id)
    assert body["webhook_id"] == webhook["id"]
    assert body["author_id"] is None
    assert body["content"] == "original"


# R1 - an unknown webhook, a wrong token and a deleted webhook are 404
def test_get_webhook_message_unknown_webhook(http_client):
    response = get_webhook_message(http_client, 1, "sometoken", 1)

    assert response.status_code == 404
    assert response.json()["message"] == "Webhook not found"


def test_get_webhook_message_wrong_token(
    http_client, test_guild, test_channel
):
    webhook, message = _create_webhook_message(http_client, test_guild, test_channel)

    response = get_webhook_message(
        http_client, webhook["id"], "wrong-token", message["id"]
    )

    assert response.status_code == 404
    assert response.json()["message"] == "Webhook not found"


def test_get_webhook_message_after_webhook_delete(
    http_client, test_guild, test_channel
):
    webhook, message = _create_webhook_message(http_client, test_guild, test_channel)
    delete_webhook(http_client, test_guild.admin_token, webhook["id"])

    response = _get(http_client, webhook, message["id"])

    assert response.status_code == 404
    assert response.json()["message"] == "Webhook not found"


# R2 - a webhook may not read another webhook's message or a user message
def test_get_webhook_message_foreign_message(
    http_client, test_guild, test_channel, test_session
):
    first, _ = _create_webhook_message(
        http_client, test_guild, test_channel, name="first"
    )
    second, second_message = _create_webhook_message(
        http_client, test_guild, test_channel, name="second"
    )

    response = _get(http_client, first, second_message["id"])
    assert response.status_code == 404
    assert response.json()["message"] == "Message not found"

    user_message = _post_user_message(
        http_client, test_session, test_channel.id, {"content": "user"}
    )

    response = _get(http_client, second, user_message["id"])
    assert response.status_code == 404
    assert response.json()["message"] == "Message not found"


# R2 - a deleted message is 404
def test_get_deleted_webhook_message(http_client, test_guild, test_channel):
    webhook, message = _create_webhook_message(http_client, test_guild, test_channel)

    assert _delete(http_client, webhook, message["id"]).status_code == 204

    response = _get(http_client, webhook, message["id"])

    assert response.status_code == 404
    assert response.json()["message"] == "Message not found"


# R4 - content-only edit
def test_patch_webhook_message_content(http_client, test_guild, test_channel):
    webhook, message = _create_webhook_message(http_client, test_guild, test_channel)

    response = _patch(http_client, webhook, message["id"], {"content": "edited"})

    assert response.status_code == 200, response.content

    body = response.json()
    assert body["content"] == "edited"
    assert body["edited_at"] is not None
    assert body["webhook_id"] == webhook["id"]
    assert body["author_id"] is None

    stored = _get(http_client, webhook, message["id"])
    assert stored.json()["content"] == "edited"


# R4 - embeds-only edit keeps the content
def test_patch_webhook_message_embeds_only(
    http_client, test_guild, test_channel
):
    webhook, message = _create_webhook_message(http_client, test_guild, test_channel)

    response = _patch(
        http_client,
        webhook,
        message["id"],
        {"embeds": [{"title": "Only embeds"}]},
    )

    assert response.status_code == 200, response.content

    body = response.json()
    assert body["content"] == "original"
    assert body["embeds"][0]["title"] == "Only embeds"


# R4 - empty content is allowed when embeds are present
def test_patch_webhook_message_empty_content_with_embeds(
    http_client, test_guild, test_channel
):
    webhook, message = _create_webhook_message(http_client, test_guild, test_channel)

    response = _patch(
        http_client,
        webhook,
        message["id"],
        {"content": "", "embeds": [{"title": "Embeds"}]},
    )

    assert response.status_code == 200, response.content

    body = response.json()
    assert body["content"] == ""
    assert body["embeds"][0]["title"] == "Embeds"


# R4 - clearing embeds keeps non-empty content
def test_patch_webhook_message_clears_embeds(
    http_client, test_guild, test_channel
):
    webhook, message = _create_webhook_message(http_client, test_guild, test_channel)

    response = _patch(
        http_client,
        webhook,
        message["id"],
        {"embeds": [{"title": "Before"}]},
    )
    assert response.status_code == 200

    response = _patch(http_client, webhook, message["id"], {"embeds": None})
    assert response.status_code == 200
    assert response.json()["embeds"] is None
    assert response.json()["content"] == "original"


# R4 - neither content nor embeds is 400
def test_patch_webhook_message_requires_a_field(
    http_client, test_guild, test_channel
):
    webhook, message = _create_webhook_message(http_client, test_guild, test_channel)

    response = _patch(http_client, webhook, message["id"], {})

    assert response.status_code == 400
    assert response.json()["message"] == "'content' or 'embeds' is required"


# R4 - content-only edits cannot become empty
def test_patch_webhook_message_empty_content_without_embeds(
    http_client, test_guild, test_channel
):
    webhook, message = _create_webhook_message(http_client, test_guild, test_channel)

    response = _patch(http_client, webhook, message["id"], {"content": ""})

    assert response.status_code == 400
    assert response.json()["message"] == "'content' is empty"


# R4 - content validation mirrors the user message edit
def test_patch_webhook_message_invalid_content(
    http_client, test_guild, test_channel
):
    webhook, message = _create_webhook_message(http_client, test_guild, test_channel)

    response = _patch(http_client, webhook, message["id"], {"content": 42})
    assert response.status_code == 400
    assert response.json()["message"] == "'content' is not a string"

    max_codepoints = CONFIG["api"]["messages"]["max_codepoints"]
    response = _patch(
        http_client,
        webhook,
        message["id"],
        {"content": "a" * (max_codepoints + 1)},
    )
    assert response.status_code == 400
    assert response.json()["message"] == "'content' is too long"


# R4 - invalid embeds are rejected
def test_patch_webhook_message_invalid_embeds(
    http_client, test_guild, test_channel
):
    webhook, message = _create_webhook_message(http_client, test_guild, test_channel)

    response = _patch(
        http_client,
        webhook,
        message["id"],
        {"embeds": [{"title": 1}]},
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Bad embed: field 'title' is not a string"


# R4 - attachments are derived from the new content
def test_patch_webhook_message_attachments(
    db_conn, http_client, test_guild, test_channel
):
    insert_file(db_conn, 100)
    webhook, message = _create_webhook_message(http_client, test_guild, test_channel)

    response = _patch(
        http_client,
        webhook,
        message["id"],
        {"content": "[f](attachment://100)"},
    )

    assert response.status_code == 200, response.content
    assert response.json()["attachments"][0]["id"] == "100"

    response = _patch(
        http_client,
        webhook,
        message["id"],
        {"content": "[f](attachment://999)"},
    )
    assert response.status_code == 400
    assert response.json()["message"] == "'attachments' is invalid"


# R4 - mentions are recomputed from the new content
def test_patch_webhook_message_mentions(
    http_client, test_guild, test_channel, test_user
):
    webhook, message = _create_webhook_message(http_client, test_guild, test_channel)

    response = _patch(
        http_client,
        webhook,
        message["id"],
        {"content": f"hey <@{test_user.id}>"},
    )

    assert response.status_code == 200, response.content
    assert response.json()["mentions"] == [test_user.id]


# R2 - a webhook may not edit another webhook's message or a user message
def test_patch_webhook_message_foreign_message(
    http_client, test_guild, test_channel, test_session
):
    first, _ = _create_webhook_message(
        http_client, test_guild, test_channel, name="first"
    )
    _, second_message = _create_webhook_message(
        http_client, test_guild, test_channel, name="second"
    )

    response = _patch(http_client, first, second_message["id"], {"content": "x"})
    assert response.status_code == 404
    assert response.json()["message"] == "Message not found"

    user_message = _post_user_message(
        http_client, test_session, test_channel.id, {"content": "user"}
    )
    response = _patch(http_client, first, user_message["id"], {"content": "x"})
    assert response.status_code == 404
    assert response.json()["message"] == "Message not found"


# R3 - PATCH requires JSON and a non-empty body
def test_patch_webhook_message_content_type(
    http_client, test_guild, test_channel
):
    webhook, message = _create_webhook_message(http_client, test_guild, test_channel)

    response = http_client.patch(
        f"/api/webhooks/{webhook['id']}/{webhook['token']}/messages/{message['id']}",
        content=b'{"content": "x"}',
        headers={"Content-Type": "text/plain"},
    )
    assert response.status_code == 415

    response = http_client.patch(
        f"/api/webhooks/{webhook['id']}/{webhook['token']}/messages/{message['id']}",
        content=b"",
    )
    assert response.status_code == 400


# R3 - DELETE soft-deletes and is idempotent
def test_delete_webhook_message(http_client, test_guild, test_channel, test_session):
    webhook, message = _create_webhook_message(http_client, test_guild, test_channel)

    response = _delete(http_client, webhook, message["id"])

    assert response.status_code == 204
    assert _get(http_client, webhook, message["id"]).status_code == 404
    assert _delete(http_client, webhook, message["id"]).status_code == 404

    messages = http_client.get(
        f"/api/channels/{test_channel.id}/messages",
        headers=auth(test_session.access_token),
    ).json()
    assert all(item["id"] != message["id"] for item in messages)


# R2 - a webhook may not delete another webhook's message or a user message
def test_delete_webhook_message_foreign_message(
    http_client, test_guild, test_channel, test_session
):
    first, _ = _create_webhook_message(
        http_client, test_guild, test_channel, name="first"
    )
    _, second_message = _create_webhook_message(
        http_client, test_guild, test_channel, name="second"
    )

    response = _delete(http_client, first, second_message["id"])
    assert response.status_code == 404
    assert response.json()["message"] == "Message not found"

    user_message = _post_user_message(
        http_client, test_session, test_channel.id, {"content": "user"}
    )
    response = _delete(http_client, first, user_message["id"])
    assert response.status_code == 404
    assert response.json()["message"] == "Message not found"


# R4 - gateway events are emitted for edit and delete
def test_webhook_message_gateway_events(
    http_client, test_guild, test_channel, test_session
):
    webhook, message = _create_webhook_message(http_client, test_guild, test_channel)

    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_session.access_token}})
    assert ws.recv_json()["op"] == "hello"

    try:
        response = _patch(
            http_client, webhook, message["id"], {"content": "edited"}
        )
        assert response.status_code == 200

        event = ws.recv_json()
        assert event["op"] == "dispatch"
        assert event["t"] == "message_updated"
        assert event["d"] == {
            "id": message["id"],
            "channel_id": str(test_channel.id),
            "guild_id": str(test_guild.id),
        }

        response = _delete(http_client, webhook, message["id"])
        assert response.status_code == 204

        event = ws.recv_json()
        assert event["op"] == "dispatch"
        assert event["t"] == "message_deleted"
        assert event["d"] == {
            "id": message["id"],
            "channel_id": str(test_channel.id),
            "guild_id": str(test_guild.id),
        }
    finally:
        ws.close()


# Path validation
def test_webhook_message_bad_message_id(http_client, test_guild, test_channel):
    webhook, _ = _create_webhook_message(http_client, test_guild, test_channel)

    response = http_client.get(
        f"/api/webhooks/{webhook['id']}/{webhook['token']}/messages/not-a-number"
    )

    assert response.status_code == 400


def test_webhook_message_method_not_allowed(
    http_client, test_guild, test_channel
):
    webhook, message = _create_webhook_message(http_client, test_guild, test_channel)

    response = http_client.post(
        f"/api/webhooks/{webhook['id']}/{webhook['token']}/messages/{message['id']}"
    )

    assert response.status_code == 405
