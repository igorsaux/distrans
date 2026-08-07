# Tests for POST/GET /api/channels/{channel_id}/webhooks.
#
# Requirement numbering mirrors src/route/channels/webhooks.zig.
#
# GetTask:
#   R1 - user must be logged
#   R2 - the channel exists
#   R3 - the response is the channel's live webhooks, no token
#
# PostTask:
#   R1 - user must be logged
#   R2 - the channel exists
#   R3 - user has create_webhooks on the channel
#   R4 - application/json, non-empty body
#   R5 - "name" is a string, NFKC-normalized, within max_name_codepoints and
#        passing the `.name` codepoint profile
#   R6 - fewer than max_webhooks_per_channel live webhooks
#   R7 - 201 {"id","token"}; the plaintext token is shown exactly once

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from permissions import CREATE_WEBHOOKS  # noqa: E402
from webhooks_common import (  # noqa: E402
    WEBHOOK_LIMITS,
    auth,
    create_webhook,
    get_webhook,
    list_webhooks,
    post_webhook,
)


# R1
def test_get_channel_webhooks_unauthorized(http_client, test_channel):
    response = http_client.get(f"/api/channels/{test_channel.id}/webhooks")

    assert response.status_code == 401


# R1
def test_post_channel_webhook_unauthorized(http_client, test_channel):
    response = http_client.post(
        f"/api/channels/{test_channel.id}/webhooks", json={"name": "hook"}
    )

    assert response.status_code == 401


# R2
def test_get_channel_webhooks_unknown_channel(http_client, test_session):
    response = list_webhooks(http_client, test_session.access_token, 1)

    assert response.status_code == 404
    assert response.json()["message"] == "Channel not found"


# R2
def test_post_channel_webhook_unknown_channel(http_client, test_session):
    response = post_webhook(
        http_client, test_session.access_token, 1, {"name": "hook"}
    )

    assert response.status_code == 404
    assert response.json()["message"] == "Channel not found"


# R3 - the default @everyone has no create_webhooks
def test_post_channel_webhook_missing_permissions(
    http_client, test_channel, test_session
):
    response = post_webhook(
        http_client, test_session.access_token, test_channel.id, {"name": "hook"}
    )

    assert response.status_code == 403
    assert response.json()["message"] == "Missing permissions"


# R3 - success with a role carrying exactly create_webhooks
def test_post_channel_webhook_exact_permission(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    from webhooks_common import grant

    grant(db_conn, test_guild.id, test_user.id, CREATE_WEBHOOKS)

    response = post_webhook(
        http_client, test_session.access_token, test_channel.id, {"name": "hook"}
    )

    assert response.status_code == 201, response.content

    body = response.json()
    assert body["id"]
    assert body["token"]


# R7 - the token is only in the create response
def test_post_channel_webhook_token_only_once(
    db_conn, http_client, test_guild, test_channel
):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="tokenhook"
    )

    listing = list_webhooks(http_client, test_guild.admin_token, test_channel.id).json()
    assert listing == [
        {
            "id": created["id"],
            "guild_id": test_guild.id,
            "channel_id": test_channel.id,
            "name": "tokenhook",
            "avatar_hash": None,
            "created_at": listing[0]["created_at"],
            "deleted_at": None,
        }
    ]

    fetched = get_webhook(http_client, test_guild.admin_token, created["id"]).json()
    assert "token" not in fetched

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT token_hash FROM app.webhooks WHERE id = %s", (created["id"],)
        )
        token_hash = cur.fetchone()["token_hash"]

    assert len(token_hash) == 32
    assert token_hash.hex() != created["token"]


# R3/R7 - list is ordered by id and carries full objects
def test_get_channel_webhooks_lists_live_webhooks(
    http_client, test_guild, test_channel
):
    first = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="a"
    )
    second = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="b"
    )

    body = list_webhooks(http_client, test_guild.admin_token, test_channel.id).json()

    assert [w["id"] for w in body] == [first["id"], second["id"]]
    assert [w["name"] for w in body] == ["a", "b"]
    for webhook in body:
        assert "token" not in webhook
        assert webhook["avatar_hash"] is None
        assert webhook["deleted_at"] is None


# R4 - an empty body is 400
def test_post_channel_webhook_empty_body(
    http_client, test_guild, test_channel
):
    response = http_client.post(
        f"/api/channels/{test_channel.id}/webhooks",
        content=b"",
        headers=auth(test_guild.admin_token),
    )

    assert response.status_code == 400


# R4 - a non-JSON body is 415
def test_post_channel_webhook_wrong_content_type(
    http_client, test_guild, test_channel
):
    response = http_client.post(
        f"/api/channels/{test_channel.id}/webhooks",
        content=b'{"name": "hook"}',
        headers={**auth(test_guild.admin_token), "Content-Type": "text/plain"},
    )

    assert response.status_code == 415
    assert response.json()["message"] == "Unsupported Media Type"


# R5
def test_post_channel_webhook_name_missing(http_client, test_guild, test_channel):
    response = post_webhook(
        http_client, test_guild.admin_token, test_channel.id, {}
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'name' is missing"


# R5
def test_post_channel_webhook_name_not_a_string(
    http_client, test_guild, test_channel
):
    response = post_webhook(
        http_client, test_guild.admin_token, test_channel.id, {"name": 5}
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'name' is not a string"


# R5
def test_post_channel_webhook_name_too_long(http_client, test_guild, test_channel):
    too_long = "a" * (WEBHOOK_LIMITS["max_name_codepoints"] + 1)

    response = post_webhook(
        http_client, test_guild.admin_token, test_channel.id, {"name": too_long}
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'name' is too long"


# R5 - a zero-width space is in the forbidden profile
def test_post_channel_webhook_name_forbidden(
    http_client, test_guild, test_channel
):
    response = post_webhook(
        http_client, test_guild.admin_token, test_channel.id, {"name": "a\u200bb"}
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'name' is invalid"


# R6
def test_post_channel_webhook_cap(http_client, test_guild, test_channel):
    limit = WEBHOOK_LIMITS["max_webhooks_per_channel"]

    for i in range(limit):
        create_webhook(
            http_client, test_guild.admin_token, test_channel.id, name=f"hook-{i}"
        )

    response = post_webhook(
        http_client, test_guild.admin_token, test_channel.id, {"name": "one-too-many"}
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'webhooks' is too many"


# R6 - soft-deleted webhooks do not count against the cap
def test_post_channel_webhook_cap_ignores_deleted(
    http_client, test_guild, test_channel
):
    limit = WEBHOOK_LIMITS["max_webhooks_per_channel"]

    created = [
        create_webhook(
            http_client, test_guild.admin_token, test_channel.id, name=f"hook-{i}"
        )
        for i in range(limit)
    ]

    response = http_client.delete(
        f"/api/webhooks/{created[0]['id']}",
        headers=auth(test_guild.admin_token),
    )
    assert response.status_code == 204

    response = post_webhook(
        http_client, test_guild.admin_token, test_channel.id, {"name": "replacement"}
    )
    assert response.status_code == 201


# The new limits are exposed by GET /api/limits
def test_limits_expose_webhooks(http_client):
    limits = http_client.get("/api/limits").json()

    assert limits["webhooks"] == {
        "max_webhooks_per_channel": WEBHOOK_LIMITS["max_webhooks_per_channel"],
        "max_name_codepoints": WEBHOOK_LIMITS["max_name_codepoints"],
    }
