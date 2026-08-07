import base64
import hashlib
import hmac
import json
import time
import uuid

import pytest

from conftest import CONFIG, system_create_user, system_login


def make_access_token(user_id: str) -> str:
    """Mint a bearer access token the same way the server does (HS256 JWT)."""
    key = CONFIG["auth"]["access_token_key"].encode()
    b64 = base64.urlsafe_b64encode

    header = b64(b'{ "alg": "HS256", "typ": "JWT" }').rstrip(b"=")
    payload = b64(
        json.dumps({"sub": user_id, "exp": int(time.time()) + 900}).encode()
    ).rstrip(b"=")

    signing_input = header + b"." + payload
    sign = hmac.new(key, signing_input, hashlib.sha256).digest()

    return (signing_input + b"." + b64(sign).rstrip(b"=")).decode()

# R1
def test_get_me_unauthorized(http_client):
    response = http_client.get("/api/users/@me")

    assert response.status_code == 401


def test_get_me(http_client, test_user, test_session):
    response = http_client.get(
        "/api/users/@me",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
        },
    )

    assert response.status_code == 200

    body = response.json()
    assert body["id"] == test_user.id


# R1
def test_patch_me_unauthorized(http_client):
    response = http_client.patch("/api/users/@me", json={})

    assert response.status_code == 401


# R1
def test_patch_me_bad_content_type(http_client, test_session):
    response = http_client.patch(
        "/api/users/@me",
        content="{}",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
            "Content-Type": "text/plain",
        },
    )

    assert response.status_code == 415


# R1
def test_patch_me_empty_body(http_client, test_session):
    response = http_client.patch(
        "/api/users/@me",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 400


# R3
def test_patch_me_bad_json(http_client, test_session):
    response = http_client.patch(
        "/api/users/@me",
        content="{",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
            "Content-Type": "application/json",
        },
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Bad JSON"


# R3
def test_patch_me_expected_object(http_client, test_session):
    response = http_client.patch(
        "/api/users/@me",
        json=[1, 2, 3],
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Expected an object"


# R6 - every PATCH requires "current_password", even a no-op
def test_patch_me_no_op(http_client, test_user, test_session):
    response = http_client.patch(
        "/api/users/@me",
        json={"current_password": test_user.password},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 204

    response = http_client.get(
        "/api/users/@me",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.json()["display_name"] is None


# R6
def test_patch_me_no_op_without_current_password(http_client, test_session):
    response = http_client.patch(
        "/api/users/@me",
        json={},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'current_password' is missing"


# R6
def test_patch_me_display_name_without_current_password(http_client, test_session):
    response = http_client.patch(
        "/api/users/@me",
        json={"display_name": "No Confirm"},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'current_password' is missing"


# R5
def test_patch_me_display_name(http_client, test_user, test_session):
    response = http_client.patch(
        "/api/users/@me",
        json={"display_name": "New Name", "current_password": test_user.password},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 204

    response = http_client.get(
        "/api/users/@me",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.json()["display_name"] == "New Name"


# R5
def test_patch_me_display_name_clear(http_client, test_user, test_session):
    response = http_client.patch(
        "/api/users/@me",
        json={"display_name": "New Name", "current_password": test_user.password},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 204

    response = http_client.patch(
        "/api/users/@me",
        json={"display_name": None, "current_password": test_user.password},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 204

    response = http_client.get(
        "/api/users/@me",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.json()["display_name"] is None


# R5
def test_patch_me_bad_display_name(http_client, test_session):
    response = http_client.patch(
        "/api/users/@me",
        json={"display_name": 1},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'display_name' is not a string"


# R5
def test_patch_me_display_name_too_short(http_client, test_session):
    response = http_client.patch(
        "/api/users/@me",
        json={"display_name": ""},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'display_name' is too short"


# R5
def test_patch_me_display_name_too_long(http_client, test_session):
    response = http_client.patch(
        "/api/users/@me",
        json={"display_name": "d" * 33},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'display_name' is too long"


# R5
def test_patch_me_display_name_max_length(http_client, test_user, test_session):
    response = http_client.patch(
        "/api/users/@me",
        json={"display_name": "d" * 32, "current_password": test_user.password},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 204


# R5 - the display_name is NFKC-normalized before storage
def test_patch_me_display_name_normalized(http_client, db_conn, test_user, test_session):
    response = http_client.patch(
        "/api/users/@me",
        json={
            "display_name": "\uFF26\uFF55\uFF4C\uFF4C",  # fullwidth "Full"
            "current_password": test_user.password,
        },
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 204

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT display_name FROM app.users WHERE id = %s", (test_user.id,)
        )
        row = cur.fetchone()

    assert row["display_name"] == "Full"


# R5
@pytest.mark.parametrize(
    "display_name",
    [
        "d\u200b",  # zero-width space (Cf)
        "\u0001",  # C0 control
        "\u202e",  # BiDi override (Cf)
        "\U000e0041",  # tag character
        "d\ufeff",  # zero-width no-break space (Cf)
        "d\u2028",  # line separator (Zl)
        "\u3164",  # hangul filler (invisible letter)
        "\u2800",  # blank braille pattern
        "\ue000",  # private use area
        "\u115f",  # hangul filler (invisible letter)
    ],
)
def test_patch_me_display_name_invalid(http_client, test_session, display_name):
    response = http_client.patch(
        "/api/users/@me",
        json={"display_name": display_name},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'display_name' is invalid"


# R5 - the refresh_token cookie is required only when "password" is present
def test_patch_me_display_name_without_refresh_cookie(http_client, test_user, test_session):
    response = http_client.patch(
        "/api/users/@me",
        json={"display_name": "No Cookie", "current_password": test_user.password},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 204


# R6 - "password" requires "current_password"
def test_patch_me_password_without_current_password(http_client, test_session):
    response = http_client.patch(
        "/api/users/@me",
        json={"password": "876543219"},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'current_password' is missing"


# R6
def test_patch_me_bad_current_password_type(http_client, test_session):
    response = http_client.patch(
        "/api/users/@me",
        json={"password": "876543219", "current_password": 1},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'current_password' is not a string"


# R6
def test_patch_me_current_password_too_long(http_client, test_session):
    response = http_client.patch(
        "/api/users/@me",
        json={
            "password": "876543219",
            "current_password": "x" * (CONFIG["auth"]["password"]["max_password_len"] + 1),
        },
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'current_password' is too long"


# R9 - "current_password" alone (no password change) must still match the stored hash
def test_patch_me_current_password_alone_wrong(http_client, test_session):
    response = http_client.patch(
        "/api/users/@me",
        json={"current_password": "wrong-current-password"},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 401

    body = response.json()
    assert body["message"] == "Bad password"


# R9 - "current_password" alone (no password change) does not touch the stored password
def test_patch_me_current_password_alone_no_op(http_client, test_user, test_session):
    response = http_client.patch(
        "/api/users/@me",
        json={"current_password": test_user.password},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 204

    # Login with the unchanged password still works.
    access_token, _ = system_login(http_client, test_user.username, test_user.password)
    assert access_token


# R9 - confirming with a wrong current password fails
def test_patch_me_bad_password(http_client, test_session):
    response = http_client.patch(
        "/api/users/@me",
        json={"password": "876543219", "current_password": "87654321"},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 401

    body = response.json()
    assert body["message"] == "Bad password"


# R8 - the new password must differ from the current one
def test_patch_me_same_password(http_client, test_user, test_session):
    response = http_client.patch(
        "/api/users/@me",
        json={"password": test_user.password, "current_password": test_user.password},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'password' must be different from the current password"


# R7 - a passwordless account gets "User has no password"
def test_patch_me_password_passwordless_user(http_client, system_headers):
    username = f"nopass{uuid.uuid4().hex[:8]}"

    response = http_client.post(
        "/api/system/users",
        json={"username": username},
        headers=system_headers,
    )

    assert response.status_code == 201

    user_id = response.json()["id"]

    # A passwordless user cannot log in; mint a bearer token directly (the
    # access token is a plain signed JWT, only the bearer middleware checks it).
    access_token = make_access_token(user_id)

    response = http_client.patch(
        "/api/users/@me",
        json={"password": "876543219", "current_password": "12345678"},
        headers={"Authorization": f"Bearer {access_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "User has no password"


# R9 - a successful password change re-hashes the stored password
def test_patch_me_password(http_client, test_user, test_session):
    new_password = "9 Westminster"

    response = http_client.patch(
        "/api/users/@me",
        json={"password": new_password, "current_password": test_user.password},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 204

    # Login works with the new password.
    access_token, _ = system_login(http_client, test_user.username, new_password)
    assert access_token

    # The old password is rejected on login.
    response = http_client.post(
        "/api/auth/token",
        json={
            "grant_type": "password",
            "username": test_user.username,
            "password": test_user.password,
        },
    )

    assert response.status_code == 401


# R9/R11 - with the refresh_token cookie the cookie session survives
def test_patch_me_password_revokes_other_sessions(
    http_client, db_conn, test_user, test_session
):
    # A second session for the same user.
    _, second_refresh_token = system_login(
        http_client, test_user.username, test_user.password
    )

    response = http_client.patch(
        "/api/users/@me",
        json={"password": "9 Westminster", "current_password": test_user.password},
        cookies={"refresh_token": test_session.refresh_token},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 204

    # Exactly one refresh token remains: the current session's.
    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT count(*) AS n FROM app.refresh_tokens WHERE user_id = %s;",
            (int(test_user.id),),
        )

        row = cur.fetchone()

    assert row["n"] == 1

    # The second session's refresh token is revoked.
    response = http_client.post(
        "/api/auth/token/refresh",
        headers={"Cookie": f"refresh_token={second_refresh_token}"},
    )

    assert response.status_code == 401

    # The session that performed the password change survives.
    response = http_client.post(
        "/api/auth/token/refresh",
        headers={"Cookie": f"refresh_token={test_session.refresh_token}"},
    )

    assert response.status_code == 200


# R11 - without the cookie every refresh token of the user is revoked
def test_patch_me_password_revokes_all_sessions_without_cookie(
    http_client, db_conn, test_user, test_session
):
    response = http_client.patch(
        "/api/users/@me",
        json={"password": "9 Westminster", "current_password": test_user.password},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 204

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT count(*) AS n FROM app.refresh_tokens WHERE user_id = %s;",
            (int(test_user.id),),
        )

        row = cur.fetchone()

    assert row["n"] == 0

    # The previous session's refresh token is revoked too.
    response = http_client.post(
        "/api/auth/token/refresh",
        headers={"Cookie": f"refresh_token={test_session.refresh_token}"},
    )

    assert response.status_code == 401


# R9 - a wrong current_password on a no-op PATCH fails and changes nothing
def test_patch_me_no_op_wrong_current_password(http_client, test_user, test_session):
    response = http_client.patch(
        "/api/users/@me",
        json={"current_password": "wrong-current-password"},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 401

    body = response.json()
    assert body["message"] == "Bad password"

    # Login with the unchanged password still works.
    access_token, _ = system_login(http_client, test_user.username, test_user.password)
    assert access_token


# R9 - a wrong current_password on a display_name PATCH fails and changes nothing
def test_patch_me_display_name_wrong_current_password(
    http_client, test_user, test_session
):
    response = http_client.patch(
        "/api/users/@me",
        json={"display_name": "Not Applied", "current_password": "wrong-password"},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 401

    body = response.json()
    assert body["message"] == "Bad password"

    response = http_client.get(
        "/api/users/@me",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.json()["display_name"] is None


# R7 - a no-op PATCH from a passwordless account gets "User has no password"
def test_patch_me_no_op_passwordless_user(http_client, system_headers):
    username = f"nopass{uuid.uuid4().hex[:8]}"

    response = http_client.post(
        "/api/system/users",
        json={"username": username},
        headers=system_headers,
    )

    assert response.status_code == 201

    user_id = response.json()["id"]

    # A passwordless user cannot log in; mint a bearer token directly (the
    # access token is a plain signed JWT, only the bearer middleware checks it).
    access_token = make_access_token(user_id)

    response = http_client.patch(
        "/api/users/@me",
        json={"current_password": "12345678"},
        headers={"Authorization": f"Bearer {access_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "User has no password"


# R7 - bots have no password and cannot PATCH their account at all
def test_patch_me_bot_rejected(http_client, system_headers):
    username = f"bot{uuid.uuid4().hex[:8]}"

    response = http_client.post(
        "/api/system/users",
        json={"username": username, "is_bot": True},
        headers=system_headers,
    )

    assert response.status_code == 201

    user_id = response.json()["id"]

    access_token = make_access_token(user_id)

    response = http_client.patch(
        "/api/users/@me",
        json={
            "display_name": "Bot Name",
            "current_password": "12345678",
        },
        headers={"Authorization": f"Bearer {access_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "User has no password"


# R4 - a username change is applied and login follows the new name
def test_patch_me_username(http_client, test_user, test_session):
    new_username = f"new.name_{uuid.uuid4().hex[:8]}"

    response = http_client.patch(
        "/api/users/@me",
        json={"username": new_username, "current_password": test_user.password},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 204

    response = http_client.get(
        "/api/users/@me",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.json()["username"] == new_username

    # Login works with the new username.
    access_token, _ = system_login(http_client, new_username, test_user.password)
    assert access_token

    # The old username is rejected on login.
    response = http_client.post(
        "/api/auth/token",
        json={
            "grant_type": "password",
            "username": test_user.username,
            "password": test_user.password,
        },
    )

    assert response.status_code == 401


# R6 - a username change requires "current_password" too
def test_patch_me_username_without_current_password(http_client, test_session):
    response = http_client.patch(
        "/api/users/@me",
        json={"username": "new.name_x"},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'current_password' is missing"


# R4 - "username" is not nullable
def test_patch_me_username_null(http_client, test_user, test_session):
    response = http_client.patch(
        "/api/users/@me",
        json={"username": None, "current_password": test_user.password},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'username' is not a string"


# R4
def test_patch_me_bad_username_type(http_client, test_user, test_session):
    response = http_client.patch(
        "/api/users/@me",
        json={"username": 1, "current_password": test_user.password},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'username' is not a string"


# R4
def test_patch_me_username_too_short(http_client, test_user, test_session):
    response = http_client.patch(
        "/api/users/@me",
        json={"username": "a", "current_password": test_user.password},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'username' is too short"


# R4
def test_patch_me_username_too_long(http_client, test_user, test_session):
    response = http_client.patch(
        "/api/users/@me",
        json={"username": "a" * 33, "current_password": test_user.password},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'username' is too long"


# R4
def test_patch_me_username_max_length(http_client, test_user, test_session):
    response = http_client.patch(
        "/api/users/@me",
        json={"username": "a" * 32, "current_password": test_user.password},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 204


# R4
@pytest.mark.parametrize(
    "username",
    [
        "Abc",  # uppercase
        "a b",  # space
        ".abc",  # leading dot
        "abc.",  # trailing dot
        "a..b",  # double dot
        "abc-d",  # hyphen
    ],
)
def test_patch_me_username_invalid(http_client, test_user, test_session, username):
    response = http_client.patch(
        "/api/users/@me",
        json={"username": username, "current_password": test_user.password},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'username' is invalid"


# R4
def test_patch_me_username_reserved(http_client, test_user, test_session):
    response = http_client.patch(
        "/api/users/@me",
        json={"username": "admin", "current_password": test_user.password},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'username' is reserved"


# R10 - the new username is already taken
def test_patch_me_username_taken(http_client, test_user, test_session):
    other_username = f"taken_{uuid.uuid4().hex[:8]}"

    system_create_user(http_client, username=other_username)

    response = http_client.patch(
        "/api/users/@me",
        json={"username": other_username, "current_password": test_user.password},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 409

    body = response.json()
    assert body["message"] == "Username is already used"

    # Nothing was mutated: login with the unchanged username still works.
    access_token, _ = system_login(http_client, test_user.username, test_user.password)
    assert access_token


# R10 - patching one's own current username is a no-op
def test_patch_me_username_own_unchanged(http_client, test_user, test_session):
    response = http_client.patch(
        "/api/users/@me",
        json={"username": test_user.username, "current_password": test_user.password},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 204


# Regression: a display_name-only PATCH must not touch the stored password hash
# (repo.users.Update derives the password_hash set-flag from password_hash_set).
def test_patch_me_display_name_keeps_password(
    http_client, db_conn, test_user, test_session
):
    def password_hash():
        with db_conn.cursor() as cur:
            cur.execute(
                "SELECT password_hash FROM app.users WHERE id = %s;",
                (int(test_user.id),),
            )

            return cur.fetchone()["password_hash"]

    before = password_hash()

    response = http_client.patch(
        "/api/users/@me",
        json={"display_name": "Still Has Password", "current_password": test_user.password},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 204

    after = password_hash()

    assert after is not None
    assert after == before

    # Login with the original password still succeeds.
    access_token, _ = system_login(http_client, test_user.username, test_user.password)
    assert access_token
