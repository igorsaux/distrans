# Tests for GET/PATCH/DELETE /api/webhooks/{webhook_id}.
#
# Requirement numbering mirrors src/route/webhooks/id.zig.
#
# GetTask:
#   R1 - user must be logged
#   R2 - the webhook exists (soft-deleted rows are still returned)
#
# PatchTask:
#   R1 - user must be logged
#   R2 - the webhook exists and is live
#   R3 - modify_webhooks on the webhook's channel
#   R4 - application/json, non-empty body
#   R5 - optional "name" validated like POST R5
#   R6 - 204 (an absent "name" is a no-op that also succeeds)
#
# DeleteTask:
#   R1 - user must be logged
#   R2 - the webhook exists and is live
#   R3 - delete_webhooks on the webhook's channel
#   R4 - soft-deleted, 204

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from permissions import DELETE_WEBHOOKS, MODIFY_WEBHOOKS  # noqa: E402
from webhooks_common import (  # noqa: E402
    WEBHOOK_LIMITS,
    auth,
    create_webhook,
    delete_webhook,
    get_webhook,
    grant,
    patch_webhook,
)


# ---------------------------------------------------------------------------
# GET
# ---------------------------------------------------------------------------


# R1
def test_get_webhook_unauthorized(http_client, test_guild, test_channel):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    response = http_client.get(f"/api/webhooks/{created['id']}")

    assert response.status_code == 401


# R2
def test_get_webhook_unknown(http_client, test_session):
    response = get_webhook(http_client, test_session.access_token, 1)

    assert response.status_code == 404
    assert response.json()["message"] == "Webhook not found"


# R2 - any authenticated user may read the metadata
def test_get_webhook_plain_user(http_client, test_guild, test_channel, test_session):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="readable"
    )

    response = get_webhook(http_client, test_session.access_token, created["id"])

    assert response.status_code == 200

    body = response.json()
    assert body["id"] == created["id"]
    assert body["guild_id"] == test_guild.id
    assert body["channel_id"] == test_channel.id
    assert body["name"] == "readable"
    assert body["avatar_hash"] is None
    assert body["deleted_at"] is None
    assert "token" not in body


# R2 - a soft-deleted webhook is still readable by id (intentional asymmetry)
def test_get_webhook_after_delete(http_client, test_guild, test_channel):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="gone"
    )

    assert (
        delete_webhook(http_client, test_guild.admin_token, created["id"]).status_code
        == 204
    )

    response = get_webhook(http_client, test_guild.admin_token, created["id"])

    assert response.status_code == 200

    body = response.json()
    assert body["name"] == "gone"
    assert body["deleted_at"] is not None


# ---------------------------------------------------------------------------
# PATCH
# ---------------------------------------------------------------------------


# R1
def test_patch_webhook_unauthorized(http_client, test_guild, test_channel):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    response = http_client.patch(f"/api/webhooks/{created['id']}", json={"name": "x"})

    assert response.status_code == 401


# R2
def test_patch_webhook_unknown(http_client, test_guild):
    response = patch_webhook(
        http_client, test_guild.admin_token, 1, {"name": "x"}
    )

    assert response.status_code == 404
    assert response.json()["message"] == "Webhook not found"


# R3
def test_patch_webhook_missing_permissions(
    http_client, test_guild, test_channel, test_session
):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    response = patch_webhook(
        http_client, test_session.access_token, created["id"], {"name": "x"}
    )

    assert response.status_code == 403
    assert response.json()["message"] == "Missing permissions"


# R3/R5/R6 - success with a role carrying exactly modify_webhooks
def test_patch_webhook_exact_permission(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="before"
    )
    grant(db_conn, test_guild.id, test_user.id, MODIFY_WEBHOOKS)

    response = patch_webhook(
        http_client, test_session.access_token, created["id"], {"name": "after"}
    )

    assert response.status_code == 204

    body = get_webhook(http_client, test_guild.admin_token, created["id"]).json()
    assert body["name"] == "after"


# R6 - an absent name is a no-op that still succeeds
def test_patch_webhook_absent_name_noop(
    http_client, test_guild, test_channel
):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="stay"
    )

    response = patch_webhook(
        http_client, test_guild.admin_token, created["id"], {}
    )

    assert response.status_code == 204

    body = get_webhook(http_client, test_guild.admin_token, created["id"]).json()
    assert body["name"] == "stay"


# R4
def test_patch_webhook_empty_body(http_client, test_guild, test_channel):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    response = http_client.patch(
        f"/api/webhooks/{created['id']}",
        content=b"",
        headers=auth(test_guild.admin_token),
    )

    assert response.status_code == 400


# R4
def test_patch_webhook_wrong_content_type(http_client, test_guild, test_channel):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    response = http_client.patch(
        f"/api/webhooks/{created['id']}",
        content=b'{"name": "x"}',
        headers={**auth(test_guild.admin_token), "Content-Type": "text/plain"},
    )

    assert response.status_code == 415
    assert response.json()["message"] == "Unsupported Media Type"


# R5
def test_patch_webhook_name_not_a_string(http_client, test_guild, test_channel):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    response = patch_webhook(
        http_client, test_guild.admin_token, created["id"], {"name": 5}
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'name' is not a string"


# R5
def test_patch_webhook_name_too_long(http_client, test_guild, test_channel):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    response = patch_webhook(
        http_client,
        test_guild.admin_token,
        created["id"],
        {"name": "a" * (WEBHOOK_LIMITS["max_name_codepoints"] + 1)},
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'name' is too long"


# R5
def test_patch_webhook_name_forbidden(http_client, test_guild, test_channel):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    response = patch_webhook(
        http_client, test_guild.admin_token, created["id"], {"name": "a\u200bb"}
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'name' is invalid"


# R2 - a soft-deleted webhook cannot be modified
def test_patch_webhook_after_delete(http_client, test_guild, test_channel):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )
    delete_webhook(http_client, test_guild.admin_token, created["id"])

    response = patch_webhook(
        http_client, test_guild.admin_token, created["id"], {"name": "x"}
    )

    assert response.status_code == 404
    assert response.json()["message"] == "Webhook not found"


# ---------------------------------------------------------------------------
# DELETE
# ---------------------------------------------------------------------------


# R1
def test_delete_webhook_unauthorized(http_client, test_guild, test_channel):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    response = http_client.delete(f"/api/webhooks/{created['id']}")

    assert response.status_code == 401


# R2
def test_delete_webhook_unknown(http_client, test_guild):
    response = delete_webhook(http_client, test_guild.admin_token, 1)

    assert response.status_code == 404
    assert response.json()["message"] == "Webhook not found"


# R3
def test_delete_webhook_missing_permissions(
    http_client, test_guild, test_channel, test_session
):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    response = delete_webhook(
        http_client, test_session.access_token, created["id"]
    )

    assert response.status_code == 403
    assert response.json()["message"] == "Missing permissions"


# R3/R4 - success with a role carrying exactly delete_webhooks
def test_delete_webhook_exact_permission(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )
    grant(db_conn, test_guild.id, test_user.id, DELETE_WEBHOOKS)

    response = delete_webhook(http_client, test_session.access_token, created["id"])

    assert response.status_code == 204
    assert response.content == b""

    # management is gone, the attribution read is not
    assert get_webhook(http_client, test_session.access_token, created["id"]).status_code == 200
    assert (
        patch_webhook(
            http_client, test_session.access_token, created["id"], {"name": "x"}
        ).status_code
        == 404
    )


# R2/R4 - deleting twice is 404 the second time
def test_delete_webhook_idempotent_conflict(http_client, test_guild, test_channel):
    created = create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="hook"
    )

    assert (
        delete_webhook(http_client, test_guild.admin_token, created["id"]).status_code
        == 204
    )
    assert (
        delete_webhook(http_client, test_guild.admin_token, created["id"]).status_code
        == 404
    )
