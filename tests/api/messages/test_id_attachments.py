# Tests for content-derived message attachments.
#
# The `content` is the source of truth: every literal `attachment://<file_id>`
# reference in the (sanitized) body becomes an attachment, deduplicated in
# first-appearance order. There is no `attachments` request field anymore
# (a stray one is ignored).
#
# POST  /api/channels/{channel_id}/messages - R9
# PATCH /api/messages/{message_id}          - R6
# GET   /api/messages/{message_id}          - R4
# GET   /api/channels/{channel_id}/messages - R5
#
# Requirement numbering mirrors the route handlers.

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from conftest import CONFIG

MAX_ATTACHMENTS = CONFIG["api"]["messages"]["max_attachments"]
PUBLIC_BASE_URL = CONFIG["files"]["s3"]["public_base_url"]


def auth_headers(session):
    return {"Authorization": f"Bearer {session.access_token}"}


def insert_file(db_conn, file_id, name="f.webp", hash_value=None, size=10,
                content_type="image/webp"):
    hash_value = hash_value or f"{file_id:064d}"

    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.files (id, name, hash, size, content_type)"
            " VALUES (%s, %s, %s, %s, %s)",
            (file_id, name, hash_value, size, content_type),
        )

    return hash_value


def expected_attachment(
    file_id, name="f.webp", hash_value=None, size=10, content_type="image/webp"
):
    hash_value = hash_value or f"{int(file_id):064d}"

    return {
        "id": str(file_id),
        "name": name,
        "size": size,
        "content_type": content_type,
        "hash": hash_value,
        "public_url": f"{PUBLIC_BASE_URL}/files/{hash_value}",
    }


def token(file_id, image=True, label="f"):
    marker = "!" if image else ""

    return f"{marker}[{label}](attachment://{file_id})"


def post_message(http_client, session, channel_id, payload):
    return http_client.post(
        f"/api/channels/{channel_id}/messages",
        headers=auth_headers(session),
        json=payload,
    )


def patch_message(http_client, session, message_id, payload):
    return http_client.patch(
        f"/api/messages/{message_id}",
        headers=auth_headers(session),
        json=payload,
    )


def get_message(http_client, session, message_id):
    response = http_client.get(
        f"/api/messages/{message_id}", headers=auth_headers(session)
    )

    assert response.status_code == 200

    return response.json()


def get_messages(http_client, session, channel_id):
    response = http_client.get(
        f"/api/channels/{channel_id}/messages", headers=auth_headers(session)
    )

    assert response.status_code == 200

    return response.json()


def attachment_rows(db_conn, message_id):
    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT file_id, position FROM app.message_attachments"
            " WHERE message_id = %s ORDER BY position",
            (int(message_id),),
        )

        return [(row["file_id"], row["position"]) for row in cur.fetchall()]


# R9 - create derives attachments from content


def test_post_message_with_attachments(db_conn, http_client, test_channel, test_session):
    insert_file(db_conn, 100)
    insert_file(db_conn, 200)

    response = post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": f"{token(100)} {token(200, image=False)}"},
    )

    assert response.status_code == 201, response.content

    body = response.json()
    message_id = body["id"]

    # The create response already carries the resolved attachments.
    assert body["attachments"] == [expected_attachment(100), expected_attachment(200)]

    assert get_message(http_client, test_session, message_id)["attachments"] == [
        expected_attachment(100),
        expected_attachment(200),
    ]


def test_post_message_attachments_order_preserved(
    db_conn, http_client, test_channel, test_session
):
    insert_file(db_conn, 100)
    insert_file(db_conn, 200)

    response = post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": f"{token(200)} {token(100)}"},
    )

    assert response.status_code == 201

    message_id = response.json()["id"]

    assert get_message(http_client, test_session, message_id)["attachments"] == [
        expected_attachment(200),
        expected_attachment(100),
    ]


def test_post_message_attachment_deduped(db_conn, http_client, test_channel, test_session):
    insert_file(db_conn, 100)

    response = post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": f"{token(100)} and again {token(100, label='other')}"},
    )

    assert response.status_code == 201

    message_id = response.json()["id"]

    assert get_message(http_client, test_session, message_id)["attachments"] == [
        expected_attachment(100)
    ]

    assert attachment_rows(db_conn, message_id) == [(100, 0)]


def test_post_message_no_attachments(db_conn, http_client, test_channel, test_session):
    response = post_message(
        http_client, test_session, test_channel.id, {"content": "no files"}
    )

    assert response.status_code == 201
    assert response.json()["attachments"] == []

    message_id = response.json()["id"]

    assert get_message(http_client, test_session, message_id)["attachments"] == []


def test_post_message_ignores_explicit_attachments_field(
    db_conn, http_client, test_channel, test_session
):
    # The request field was removed; an old client's stray `attachments` key is
    # silently ignored and the content decides the set.
    insert_file(db_conn, 100)

    response = post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": "plain text", "attachments": ["100"]},
    )

    assert response.status_code == 201
    assert response.json()["attachments"] == []


def test_post_message_external_link_is_not_an_attachment(
    http_client, test_channel, test_session
):
    response = post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": "![x](https://example.com/a.png)"},
    )

    assert response.status_code == 201
    assert response.json()["attachments"] == []


def test_post_message_attachment_missing_file(http_client, test_channel, test_session):
    response = post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": token(999999)},
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'attachments' is invalid"


def test_post_message_attachment_too_many(http_client, test_channel, test_session):
    content = " ".join(token(1000 + i) for i in range(MAX_ATTACHMENTS + 1))

    response = post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": content},
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'attachments' is too long"


def test_post_message_overflowing_reference_is_text(
    http_client, test_channel, test_session
):
    # A run of digits that does not fit a file id is ordinary text: not a
    # reference, not an error.
    response = post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": "attachment://999999999999999999999999999999"},
    )

    assert response.status_code == 201
    assert response.json()["attachments"] == []


# R5 - the list endpoint projects attachments too


def test_get_messages_projects_attachments(
    db_conn, http_client, test_channel, test_session
):
    insert_file(db_conn, 100)

    message_id = post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": token(100)},
    ).json()["id"]

    messages = get_messages(http_client, test_session, test_channel.id)

    matching = [m for m in messages if m["id"] == message_id]

    assert matching[0]["attachments"] == [expected_attachment(100)]


# R6 - edit derives attachments from the new content


def test_patch_message_derives_attachments(
    db_conn, http_client, test_channel, test_session
):
    insert_file(db_conn, 100)
    insert_file(db_conn, 200)

    message_id = post_message(
        http_client, test_session, test_channel.id, {"content": token(100)}
    ).json()["id"]

    response = patch_message(
        http_client,
        test_session,
        message_id,
        {"content": f"{token(100)} {token(200)}"},
    )

    assert response.status_code == 200
    assert response.json()["attachments"] == [
        expected_attachment(100),
        expected_attachment(200),
    ]

    # The rows are replaced to match the content, in position order.
    assert attachment_rows(db_conn, message_id) == [(100, 0), (200, 1)]


def test_patch_message_removes_token_drops_attachment(
    db_conn, http_client, test_channel, test_session
):
    insert_file(db_conn, 100)
    insert_file(db_conn, 200)

    message_id = post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": f"{token(100)} {token(200)}"},
    ).json()["id"]

    response = patch_message(
        http_client, test_session, message_id, {"content": token(100)}
    )

    assert response.status_code == 200
    assert response.json()["attachments"] == [expected_attachment(100)]
    assert attachment_rows(db_conn, message_id) == [(100, 0)]


def test_patch_message_clear_all_tokens(
    db_conn, http_client, test_channel, test_session
):
    insert_file(db_conn, 100)

    message_id = post_message(
        http_client, test_session, test_channel.id, {"content": token(100)}
    ).json()["id"]

    response = patch_message(
        http_client, test_session, message_id, {"content": "no files now"}
    )

    assert response.status_code == 200
    assert response.json()["attachments"] == []
    assert attachment_rows(db_conn, message_id) == []


def test_patch_message_reorders_attachments(
    db_conn, http_client, test_channel, test_session
):
    insert_file(db_conn, 100)
    insert_file(db_conn, 200)

    message_id = post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": f"{token(100)} {token(200)}"},
    ).json()["id"]

    response = patch_message(
        http_client,
        test_session,
        message_id,
        {"content": f"{token(200)} {token(100)}"},
    )

    assert response.status_code == 200
    assert response.json()["attachments"] == [
        expected_attachment(200),
        expected_attachment(100),
    ]
    assert attachment_rows(db_conn, message_id) == [(200, 0), (100, 1)]


def test_patch_message_attachment_missing_file(
    db_conn, http_client, test_channel, test_session
):
    message_id = post_message(
        http_client, test_session, test_channel.id, {"content": "edit me"}
    ).json()["id"]

    response = patch_message(
        http_client, test_session, message_id, {"content": token(999999)}
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'attachments' is invalid"
    assert attachment_rows(db_conn, message_id) == []


def test_patch_message_attachment_too_many(
    http_client, test_channel, test_session
):
    message_id = post_message(
        http_client, test_session, test_channel.id, {"content": "edit me"}
    ).json()["id"]

    content = " ".join(token(1000 + i) for i in range(MAX_ATTACHMENTS + 1))

    response = patch_message(
        http_client, test_session, message_id, {"content": content}
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'attachments' is too long"


# Soft-delete clears attachments


def test_soft_delete_clears_attachments(
    db_conn, http_client, test_channel, test_session
):
    insert_file(db_conn, 100)

    message_id = post_message(
        http_client, test_session, test_channel.id, {"content": token(100)}
    ).json()["id"]

    response = http_client.delete(
        f"/api/messages/{message_id}", headers=auth_headers(test_session)
    )

    assert response.status_code == 204

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT count(*) AS n FROM app.message_attachments WHERE message_id = %s",
            (int(message_id),),
        )

        assert cur.fetchone()["n"] == 0
