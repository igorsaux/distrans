# Tests for GET/PUT/DELETE /api/webhooks/{webhook_id}/avatar.
#
# Requirement numbering mirrors src/route/webhooks/id/avatar.zig.
#
# GetTask:
#   R1 - "hash" must be present and match the stored hash; a soft-deleted
#        webhook is still served -> 200 image/webp, otherwise 404
#        "Avatar not found"
#   R2 - only "hash" is accepted; any other query param -> 400
#
# PutTask:
#   R1 - user must be logged
#   R2 - the webhook exists and is live
#   R3 - modify_webhooks on the webhook's channel
#   R4 - non-empty body with image/webp|image/gif|image/png; empty is 400
#        "Bad image", unsupported type is 415
#   R5 - within media.avatar caps; 413 "Image is too large" / 400 "Bad image"
#   R6 - re-encoded to WebP, stored, 200 {"avatar_hash"}
#
# DeleteTask:
#   R1..R3 as above; R4 - cleared, 204

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "users"))

import png  # noqa: E402
import webp  # noqa: E402

from permissions import MODIFY_WEBHOOKS  # noqa: E402
from webhooks_common import (  # noqa: E402
    auth,
    create_webhook,
    get_webhook,
    grant,
)

HASH_RE = re.compile(r"^[0-9a-f]{16}$")

AVATAR_WEBP = webp.make_webp()
AVATAR_PNG = png.make_png(4, 4)


def avatar_url(webhook_id):
    return f"/api/webhooks/{webhook_id}/avatar"


def put_avatar(http_client, token, webhook_id, content, content_type="image/webp"):
    headers = auth(token)

    if content is not None:
        headers["Content-Type"] = content_type

    return http_client.put(avatar_url(webhook_id), content=content, headers=headers)


def delete_avatar(http_client, token, webhook_id):
    return http_client.delete(avatar_url(webhook_id), headers=auth(token))


def get_avatar(http_client, webhook_id, hash_value):
    params = {} if hash_value is None else {"hash": hash_value}

    return http_client.get(avatar_url(webhook_id), params=params)


# R1 - the stored avatar is served publicly (no bearer) as image/webp
def test_get_avatar_after_put(http_client, test_guild, test_channel):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    put = put_avatar(
        http_client, test_guild.admin_token, created["id"], AVATAR_WEBP
    )
    assert put.status_code == 200

    response = get_avatar(http_client, created["id"], put.json()["avatar_hash"])

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("image/webp")
    assert len(response.content) > 0
    assert response.headers["cache-control"] == "private, max-age=31536000, immutable"


# R1 - a hash that does not match the stored one is 404
def test_get_avatar_hash_mismatch(http_client, test_guild, test_channel):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    assert (
        put_avatar(
            http_client, test_guild.admin_token, created["id"], AVATAR_WEBP
        ).status_code
        == 200
    )

    response = get_avatar(http_client, created["id"], "0" * 16)

    assert response.status_code == 404
    assert response.json()["message"] == "Avatar not found"


# R1 - a missing or empty hash is 404
def test_get_avatar_missing_hash(http_client, test_guild, test_channel):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    missing = http_client.get(avatar_url(created["id"]))
    assert missing.status_code == 404
    assert missing.json()["message"] == "Avatar not found"

    empty = get_avatar(http_client, created["id"], "")
    assert empty.status_code == 404
    assert empty.json()["message"] == "Avatar not found"


# R1 - a webhook without an avatar is 404
def test_get_avatar_without_avatar(http_client, test_guild, test_channel):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    response = get_avatar(http_client, created["id"], "0" * 16)

    assert response.status_code == 404
    assert response.json()["message"] == "Avatar not found"


# R1 - an unknown webhook is 404
def test_get_avatar_unknown_webhook(http_client):
    response = get_avatar(http_client, 1, "0" * 16)

    assert response.status_code == 404
    assert response.json()["message"] == "Avatar not found"


# R2 - only "hash" is accepted
def test_get_avatar_unknown_parameter(http_client, test_guild, test_channel):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    response = http_client.get(
        avatar_url(created["id"]), params={"hash": "0" * 16, "extra": "1"}
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Unknown parameter"


# R1 - a soft-deleted webhook still serves its avatar (attribution rendering),
# even though PUT/DELETE on it are 404
def test_get_avatar_soft_deleted_still_served(
    http_client, test_guild, test_channel
):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    put = put_avatar(
        http_client, test_guild.admin_token, created["id"], AVATAR_WEBP
    )
    assert put.status_code == 200

    assert (
        http_client.delete(
            f"/api/webhooks/{created['id']}", headers=auth(test_guild.admin_token)
        ).status_code
        == 204
    )

    response = get_avatar(http_client, created["id"], put.json()["avatar_hash"])

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("image/webp")
    assert len(response.content) > 0


# R1
def test_put_avatar_unauthorized(http_client, test_guild, test_channel):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    response = http_client.put(
        avatar_url(created["id"]), content=AVATAR_WEBP, headers={"Content-Type": "image/webp"}
    )

    assert response.status_code == 401


# R1
def test_delete_avatar_unauthorized(http_client, test_guild, test_channel):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    response = http_client.delete(avatar_url(created["id"]))

    assert response.status_code == 401


# R2
def test_put_avatar_unknown_webhook(http_client, test_guild):
    response = put_avatar(http_client, test_guild.admin_token, 1, AVATAR_WEBP)

    assert response.status_code == 404
    assert response.json()["message"] == "Webhook not found"


# R3
def test_put_avatar_missing_permissions(
    http_client, test_guild, test_channel, test_session
):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    response = put_avatar(
        http_client, test_session.access_token, created["id"], AVATAR_WEBP
    )

    assert response.status_code == 403
    assert response.json()["message"] == "Missing permissions"


# R4
def test_put_avatar_empty_body(http_client, test_guild, test_channel):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    response = put_avatar(http_client, test_guild.admin_token, created["id"], None)

    assert response.status_code == 400
    assert response.json()["message"] == "Bad image"


# R4
def test_put_avatar_unsupported_content_type(
    http_client, test_guild, test_channel
):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    response = put_avatar(
        http_client,
        test_guild.admin_token,
        created["id"],
        AVATAR_WEBP,
        content_type="text/plain",
    )

    assert response.status_code == 415
    assert response.json()["message"] == "Unsupported Media Type"


# R5
def test_put_avatar_too_large(http_client, test_guild, test_channel):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    response = put_avatar(
        http_client, test_guild.admin_token, created["id"], webp.oversized_body()
    )

    assert response.status_code == 413
    assert response.json()["message"] == "Image is too large"


# R5
def test_put_avatar_malformed(http_client, test_guild, test_channel):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    response = put_avatar(
        http_client,
        test_guild.admin_token,
        created["id"],
        webp.MALFORMED[sorted(webp.MALFORMED)[0]](),
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Bad image"


# R3/R6 - success with a role carrying exactly modify_webhooks
def test_put_avatar_exact_permission(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )
    grant(db_conn, test_guild.id, test_user.id, MODIFY_WEBHOOKS)

    response = put_avatar(
        http_client, test_session.access_token, created["id"], AVATAR_WEBP
    )

    assert response.status_code == 200

    avatar_hash = response.json()["avatar_hash"]
    assert HASH_RE.fullmatch(avatar_hash)

    body = get_webhook(http_client, test_session.access_token, created["id"]).json()
    assert body["avatar_hash"] == avatar_hash


# R6 - PNG is accepted and re-encoded
def test_put_avatar_png(http_client, test_guild, test_channel):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    response = put_avatar(
        http_client,
        test_guild.admin_token,
        created["id"],
        AVATAR_PNG,
        content_type="image/png",
    )

    assert response.status_code == 200
    assert HASH_RE.fullmatch(response.json()["avatar_hash"])


# R2 - a soft-deleted webhook has no avatar surface
def test_put_avatar_after_delete(http_client, test_guild, test_channel):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )
    http_client.delete(
        f"/api/webhooks/{created['id']}", headers=auth(test_guild.admin_token)
    )

    response = put_avatar(
        http_client, test_guild.admin_token, created["id"], AVATAR_WEBP
    )

    assert response.status_code == 404
    assert response.json()["message"] == "Webhook not found"


# R3/R4 - clear with exactly modify_webhooks; idempotent
def test_delete_avatar_exact_permission(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )
    grant(db_conn, test_guild.id, test_user.id, MODIFY_WEBHOOKS)

    assert (
        put_avatar(
            http_client, test_session.access_token, created["id"], AVATAR_WEBP
        ).status_code
        == 200
    )

    response = delete_avatar(http_client, test_session.access_token, created["id"])
    assert response.status_code == 204
    assert response.content == b""

    body = get_webhook(http_client, test_session.access_token, created["id"]).json()
    assert body["avatar_hash"] is None

    # clearing twice is still 204
    assert (
        delete_avatar(http_client, test_session.access_token, created["id"]).status_code
        == 204
    )


# R3
def test_delete_avatar_missing_permissions(
    http_client, test_guild, test_channel, test_session
):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    response = delete_avatar(
        http_client, test_session.access_token, created["id"]
    )

    assert response.status_code == 403
