# Tests for the `embeds` field of /api/messages/{message_id} (GET, PATCH, DELETE).
#
# GET    - returns the message embeds (null when none).
# PATCH  - R5 optional "embeds" replaces the embeds; null/[] clears them;
#          absent keeps them.
# DELETE - a soft delete wipes the embeds.

import pytest


def _message_url(message_id):
    return f"/api/messages/{message_id}"


def _post_message(http_client, test_session, channel_id, payload):
    response = http_client.post(
        f"/api/channels/{channel_id}/messages",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
        json=payload,
    )

    assert response.status_code == 201

    return response.json()["id"]


def _get_message(http_client, test_session, message_id):
    return http_client.get(
        _message_url(message_id),
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )


def _patch_message(http_client, test_session, message_id, payload):
    return http_client.patch(
        _message_url(message_id),
        headers={"Authorization": f"Bearer {test_session.access_token}"},
        json=payload,
    )


def _delete_message(http_client, test_session, message_id):
    return http_client.delete(
        _message_url(message_id),
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )


# GET


def test_get_message_without_embeds(http_client, test_message, test_session):
    response = _get_message(http_client, test_session, test_message.id)

    assert response.status_code == 200
    assert response.json()["embeds"] is None


def test_get_message_with_embeds(http_client, test_channel, test_session):
    message_id = _post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": "with embed", "embeds": [{"title": "Title"}]},
    )

    response = _get_message(http_client, test_session, message_id)

    assert response.status_code == 200

    embeds = response.json()["embeds"]
    assert len(embeds) == 1
    assert embeds[0]["title"] == "Title"
    assert embeds[0]["type"] == "rich"


# PATCH


def test_patch_message_adds_embeds(http_client, test_message, test_session):
    response = _patch_message(
        http_client,
        test_session,
        test_message.id,
        {"content": "edited", "embeds": [{"title": "Added"}]},
    )

    assert response.status_code == 200

    stored = _get_message(http_client, test_session, test_message.id)

    assert stored.status_code == 200
    assert stored.json()["embeds"][0]["title"] == "Added"


def test_patch_message_replaces_embeds(http_client, test_channel, test_session):
    message_id = _post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": "with embed", "embeds": [{"title": "Before"}]},
    )

    response = _patch_message(
        http_client,
        test_session,
        message_id,
        {"content": "edited", "embeds": [{"title": "After"}]},
    )

    assert response.status_code == 200

    stored = _get_message(http_client, test_session, message_id)

    assert stored.status_code == 200
    assert [e["title"] for e in stored.json()["embeds"]] == ["After"]


def test_patch_message_clears_embeds_with_null(http_client, test_channel, test_session):
    message_id = _post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": "with embed", "embeds": [{"title": "Before"}]},
    )

    response = _patch_message(
        http_client, test_session, message_id, {"content": "edited", "embeds": None}
    )

    assert response.status_code == 200

    stored = _get_message(http_client, test_session, message_id)

    assert stored.status_code == 200
    assert stored.json()["embeds"] is None


def test_patch_message_clears_embeds_with_empty_array(
    http_client, test_channel, test_session
):
    message_id = _post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": "with embed", "embeds": [{"title": "Before"}]},
    )

    response = _patch_message(
        http_client, test_session, message_id, {"content": "edited", "embeds": []}
    )

    assert response.status_code == 200

    stored = _get_message(http_client, test_session, message_id)

    assert stored.status_code == 200
    assert stored.json()["embeds"] is None


def test_patch_message_keeps_embeds_when_absent(http_client, test_channel, test_session):
    message_id = _post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": "with embed", "embeds": [{"title": "Kept"}]},
    )

    response = _patch_message(
        http_client, test_session, message_id, {"content": "edited"}
    )

    assert response.status_code == 200

    stored = _get_message(http_client, test_session, message_id)

    assert stored.status_code == 200
    assert stored.json()["embeds"][0]["title"] == "Kept"


def test_patch_message_embeds_only_keeps_content(
    http_client, test_channel, test_session
):
    message_id = _post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": "keep me", "embeds": [{"title": "Before"}]},
    )

    response = _patch_message(
        http_client,
        test_session,
        message_id,
        {"embeds": [{"title": "After"}]},
    )

    assert response.status_code == 200, response.content

    stored = _get_message(http_client, test_session, message_id)

    assert stored.status_code == 200
    assert stored.json()["content"] == "keep me"
    assert [e["title"] for e in stored.json()["embeds"]] == ["After"]


@pytest.mark.parametrize(
    "embeds,message",
    [
        ("not an array", "'embeds' is not an array"),
        ([{"title": 1}], "Bad embed: field 'title' is not a string"),
        ([{"timestamp": -1}], "Bad embed: field 'timestamp' is invalid"),
    ],
)
def test_patch_message_invalid_embeds(
    http_client, test_message, test_session, embeds, message
):
    response = _patch_message(
        http_client,
        test_session,
        test_message.id,
        {"content": "edited", "embeds": embeds},
    )

    assert response.status_code == 400
    assert response.json()["message"] == message


def test_patch_message_invalid_embeds_does_not_change_message(
    http_client, test_channel, test_session
):
    message_id = _post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": "original", "embeds": [{"title": "Original"}]},
    )

    response = _patch_message(
        http_client,
        test_session,
        message_id,
        {"content": "hacked", "embeds": [{"title": 1}]},
    )

    assert response.status_code == 400

    stored = _get_message(http_client, test_session, message_id)

    assert stored.status_code == 200
    assert stored.json()["content"] == "original"
    assert stored.json()["embeds"][0]["title"] == "Original"


# DELETE


def test_delete_message_clears_embeds(
    db_conn, http_client, test_channel, test_session
):
    message_id = _post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": "with embed", "embeds": [{"title": "Gone"}]},
    )

    response = _delete_message(http_client, test_session, message_id)

    assert response.status_code == 204

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT content, embeds FROM app.messages WHERE id = %s",
            (int(message_id),),
        )
        row = cur.fetchone()

    assert row is not None
    assert row["content"] == ""
    assert row["embeds"] is None
