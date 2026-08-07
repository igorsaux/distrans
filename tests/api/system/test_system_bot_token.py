import hashlib
import re

import pytest

from conftest import SYSTEM_HEADERS


def create_bot(http_client, username):
    response = http_client.post(
        "/api/system/users",
        json={"username": username, "is_bot": True},
        headers=SYSTEM_HEADERS,
    )

    assert response.status_code == 201

    return response.json()["id"]


def issue_bot_token(http_client, user_id):
    response = http_client.put(
        f"/api/system/users/{user_id}", headers=SYSTEM_HEADERS
    )

    assert response.status_code == 200

    return response.json()["token"]


BOT_TOKEN_RE = re.compile(r"^bot_[A-Za-z0-9_-]{43}$")


# R1
def test_put_bot_token_without_token(http_client, system_headers):
    user_id = create_bot(http_client, "notokbot")

    response = http_client.put(f"/api/system/users/{user_id}")

    assert response.status_code == 401


# R1
def test_put_bot_token_with_bad_token(http_client, system_headers):
    user_id = create_bot(http_client, "badtokbot")

    response = http_client.put(
        f"/api/system/users/{user_id}",
        headers={"Authorization": "Bearer wrong-token"},
    )

    assert response.status_code == 401


# R2
def test_put_bot_token_unknown_user(http_client, system_headers):
    response = http_client.put("/api/system/users/1", headers=system_headers)

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "User not found"


# R2
def test_put_bot_token_deleted_user(http_client, system_headers):
    user_id = create_bot(http_client, "doomedbot")

    response = http_client.delete(
        f"/api/system/users/{user_id}", headers=system_headers
    )
    assert response.status_code == 204

    response = http_client.put(
        f"/api/system/users/{user_id}", headers=system_headers
    )

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "User not found"


# R2
def test_put_bot_token_non_bot_user(http_client, system_headers):
    user = http_client.post(
        "/api/system/users",
        json={"username": "humanoid", "password": "12345678"},
        headers=system_headers,
    ).json()

    response = http_client.put(
        f"/api/system/users/{user['id']}", headers=system_headers
    )

    assert response.status_code == 409

    body = response.json()
    assert body["message"] == "User is not a bot"


# R3
def test_put_bot_token_issues_token(http_client, db_conn, system_headers):
    user_id = create_bot(http_client, "tokenedbot")

    token = issue_bot_token(http_client, user_id)

    assert BOT_TOKEN_RE.match(token)

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT token_hash FROM app.bot_tokens WHERE user_id = %s;",
            (int(user_id),),
        )
        rows = cur.fetchall()

    assert len(rows) == 1
    assert rows[0]["token_hash"] == hashlib.sha256(token.encode()).digest()


# R3 - rotation
def test_put_bot_token_rotates(http_client, db_conn, system_headers):
    user_id = create_bot(http_client, "rotatingbot")

    old_token = issue_bot_token(http_client, user_id)
    new_token = issue_bot_token(http_client, user_id)

    assert old_token != new_token

    old_headers = {"Authorization": f"Bearer {old_token}"}
    new_headers = {"Authorization": f"Bearer {new_token}"}

    assert (
        http_client.get("/api/users/@me", headers=old_headers).status_code == 401
    )
    assert (
        http_client.get("/api/users/@me", headers=new_headers).status_code == 200
    )

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT count(*) AS n FROM app.bot_tokens WHERE user_id = %s;",
            (int(user_id),),
        )
        assert cur.fetchone()["n"] == 1


def test_bot_token_auth_users_me(http_client, system_headers):
    user_id = create_bot(http_client, "authbot")
    token = issue_bot_token(http_client, user_id)

    response = http_client.get(
        "/api/users/@me", headers={"Authorization": f"Bearer {token}"}
    )

    assert response.status_code == 200

    body = response.json()
    assert body["id"] == user_id
    assert body["username"] == "authbot"
    assert body["is_bot"] is True


def test_bot_token_auth_user_by_id(http_client, system_headers):
    user_id = create_bot(http_client, "authbot2")
    token = issue_bot_token(http_client, user_id)

    headers = {"Authorization": f"Bearer {token}"}

    response = http_client.get(f"/api/users/{user_id}", headers=headers)

    assert response.status_code == 200

    body = response.json()
    assert body["username"] == "authbot2"
    assert body["is_bot"] is True


def test_bot_token_auth_users_list(http_client, system_headers):
    user_id = create_bot(http_client, "authbot3")
    token = issue_bot_token(http_client, user_id)

    response = http_client.get(
        "/api/users", headers={"Authorization": f"Bearer {token}"}
    )

    assert response.status_code == 200

    body = response.json()
    assert any(user["id"] == user_id for user in body)


def test_bot_token_invalid_garbage(http_client):
    for garbage in ("bot_wrong", "bot_", "bot_" + "!" * 43, "bot_" + "a" * 44):
        response = http_client.get(
            "/api/users/@me", headers={"Authorization": f"Bearer {garbage}"}
        )

        assert response.status_code == 401


def test_jwt_token_still_works(http_client, test_session):
    response = http_client.get(
        "/api/users/@me",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 200


def test_deleted_bot_token_rejected(http_client, system_headers):
    user_id = create_bot(http_client, "ghostbot")
    token = issue_bot_token(http_client, user_id)

    headers = {"Authorization": f"Bearer {token}"}
    assert http_client.get("/api/users/@me", headers=headers).status_code == 200

    response = http_client.delete(
        f"/api/system/users/{user_id}", headers=system_headers
    )
    assert response.status_code == 204

    assert http_client.get("/api/users/@me", headers=headers).status_code == 401


def test_users_me_includes_is_bot(http_client, test_session, test_user):
    response = http_client.get(
        "/api/users/@me",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 200
    assert response.json()["is_bot"] is False
