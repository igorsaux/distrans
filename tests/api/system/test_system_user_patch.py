import pytest

from conftest import system_login


def create_user(http_client, system_headers, username="target", password="12345678", **extra):
    payload = {"username": username, "password": password}
    payload.update(extra)

    response = http_client.post(
        "/api/system/users", json=payload, headers=system_headers
    )

    assert response.status_code == 201

    return response.json()["id"]


def create_passwordless_user(http_client, system_headers, username="nopass"):
    response = http_client.post(
        "/api/system/users", json={"username": username}, headers=system_headers
    )

    assert response.status_code == 201

    return response.json()["id"]


def patch_user(http_client, system_headers, user_id, payload):
    return http_client.patch(
        f"/api/system/users/{user_id}", json=payload, headers=system_headers
    )


def get_user_row(db_conn, user_id):
    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT username, display_name, avatar_hash, password_hash "
            "FROM app.users WHERE id = %s;",
            (int(user_id),),
        )

        return cur.fetchone()


def login_status(http_client, username, password):
    return http_client.post(
        "/api/auth/token",
        json={"grant_type": "password", "username": username, "password": password},
    ).status_code


def count_refresh_tokens(db_conn, user_id):
    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT count(*) AS n FROM app.refresh_tokens WHERE user_id = %s;",
            (int(user_id),),
        )

        return cur.fetchone()["n"]


# R1
def test_patch_user_non_json_content_type(http_client, system_headers, test_user):
    response = http_client.patch(
        f"/api/system/users/{test_user.id}",
        content=b"{}",
        headers={**system_headers, "Content-Type": "text/plain"},
    )

    assert response.status_code == 415


# R1
def test_patch_user_empty_body(http_client, system_headers, test_user):
    response = http_client.patch(
        f"/api/system/users/{test_user.id}", headers=system_headers
    )

    assert response.status_code == 400


# R2
def test_patch_user_without_token(http_client, test_user):
    response = http_client.patch(
        f"/api/system/users/{test_user.id}", json={"display_name": "No Token"}
    )

    assert response.status_code == 401


# R2
def test_patch_user_with_bad_token(http_client, test_user):
    response = http_client.patch(
        f"/api/system/users/{test_user.id}",
        json={"display_name": "Bad Token"},
        headers={"Authorization": "Bearer wrong-token"},
    )

    assert response.status_code == 401


def test_patch_user_bad_json(http_client, system_headers, test_user):
    response = http_client.patch(
        f"/api/system/users/{test_user.id}",
        content=b"{",
        headers={**system_headers, "Content-Type": "application/json"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Bad JSON"


def test_patch_user_expected_object(http_client, system_headers, test_user):
    response = patch_user(http_client, system_headers, test_user.id, [1, 2])

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Expected an object"


# R3
def test_patch_user_username_not_a_string(http_client, system_headers, test_user):
    response = patch_user(http_client, system_headers, test_user.id, {"username": 42})

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'username' is not a string"


# R3
def test_patch_user_username_null(http_client, system_headers, test_user):
    response = patch_user(http_client, system_headers, test_user.id, {"username": None})

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'username' is not a string"


# R3
def test_patch_user_username_too_short(http_client, system_headers, test_user):
    response = patch_user(http_client, system_headers, test_user.id, {"username": "u"})

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'username' is too short"


# R3
def test_patch_user_username_too_long(http_client, system_headers, test_user):
    response = patch_user(
        http_client, system_headers, test_user.id, {"username": "u" * 33}
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'username' is too long"


# R3
@pytest.mark.parametrize(
    "username",
    ["Abc", "a b", "a..b", "-ab", ".ab", "ab."],
)
def test_patch_user_username_invalid(http_client, system_headers, test_user, username):
    response = patch_user(
        http_client, system_headers, test_user.id, {"username": username}
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'username' is invalid"


# R3
def test_patch_user_username_reserved(http_client, system_headers, test_user):
    response = patch_user(
        http_client, system_headers, test_user.id, {"username": "admin"}
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'username' is reserved"


# R3
def test_patch_user_username(http_client, db_conn, system_headers, test_user):
    response = patch_user(
        http_client, system_headers, test_user.id, {"username": "renamed"}
    )

    assert response.status_code == 204

    row = get_user_row(db_conn, test_user.id)
    assert row["username"] == "renamed"

    # The account is reachable under the new name via the users API.
    access_token, _ = system_login(http_client, "renamed", test_user.password)

    response = http_client.get(
        f"/api/users/{test_user.id}",
        headers={"Authorization": f"Bearer {access_token}"},
    )

    assert response.status_code == 200
    assert response.json()["username"] == "renamed"


# R3
def test_patch_user_username_max_length(http_client, system_headers, test_user):
    response = patch_user(
        http_client, system_headers, test_user.id, {"username": "u" * 32}
    )

    assert response.status_code == 204


# R4
def test_patch_user_display_name_not_a_string(http_client, system_headers, test_user):
    response = patch_user(
        http_client, system_headers, test_user.id, {"display_name": 1}
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'display_name' is not a string"


# R4
def test_patch_user_display_name_too_short(http_client, system_headers, test_user):
    response = patch_user(
        http_client, system_headers, test_user.id, {"display_name": ""}
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'display_name' is too short"


# R4
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
def test_patch_user_display_name_invalid(
    http_client, system_headers, test_user, display_name
):
    response = patch_user(
        http_client, system_headers, test_user.id, {"display_name": display_name}
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'display_name' is invalid"


# R4
def test_patch_user_display_name_too_long(http_client, system_headers, test_user):
    response = patch_user(
        http_client, system_headers, test_user.id, {"display_name": "d" * 33}
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'display_name' is too long"


# R4
def test_patch_user_display_name(http_client, db_conn, system_headers, test_user):
    response = patch_user(
        http_client, system_headers, test_user.id, {"display_name": "New Name"}
    )

    assert response.status_code == 204

    row = get_user_row(db_conn, test_user.id)
    assert row["display_name"] == "New Name"


# R4
def test_patch_user_display_name_clear(http_client, db_conn, system_headers, test_user):
    response = patch_user(
        http_client, system_headers, test_user.id, {"display_name": "New Name"}
    )
    assert response.status_code == 204

    response = patch_user(
        http_client, system_headers, test_user.id, {"display_name": None}
    )

    assert response.status_code == 204

    row = get_user_row(db_conn, test_user.id)
    assert row["display_name"] is None


# R5
def test_patch_user_password_not_a_string(http_client, system_headers, test_user):
    response = patch_user(
        http_client, system_headers, test_user.id, {"password": 12345678}
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'password' is not a string"


# R5
def test_patch_user_password_too_short(http_client, system_headers, test_user):
    response = patch_user(
        http_client, system_headers, test_user.id, {"password": "x" * 7}
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'password' is too short"


# R5
def test_patch_user_password_codepoints_too_long(http_client, system_headers, test_user):
    response = patch_user(
        http_client, system_headers, test_user.id, {"password": "ы" * 65}
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'password' is too long"


# R5
def test_patch_user_password_too_long(http_client, system_headers, test_user):
    response = patch_user(
        http_client, system_headers, test_user.id, {"password": "x" * 1025}
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'password' is too long"


# R5
def test_patch_user_password_sets_on_passwordless(
    http_client, db_conn, system_headers
):
    user_id = create_passwordless_user(http_client, system_headers, username="setpass")

    response = patch_user(
        http_client, system_headers, user_id, {"password": "newpass12"}
    )

    assert response.status_code == 204

    row = get_user_row(db_conn, user_id)
    assert row["password_hash"] is not None
    assert row["password_hash"].startswith("$argon2id$")

    assert login_status(http_client, "setpass", "newpass12") == 200


# R5
def test_patch_user_password_change(http_client, system_headers):
    user_id = create_user(http_client, system_headers, username="changer")

    response = patch_user(
        http_client, system_headers, user_id, {"password": "newpass12"}
    )

    assert response.status_code == 204

    assert login_status(http_client, "changer", "12345678") == 401
    assert login_status(http_client, "changer", "newpass12") == 200


# R5
def test_patch_user_password_clear(http_client, db_conn, system_headers):
    user_id = create_user(http_client, system_headers, username="clearer")

    response = patch_user(http_client, system_headers, user_id, {"password": None})

    assert response.status_code == 204

    row = get_user_row(db_conn, user_id)
    assert row["password_hash"] is None

    assert login_status(http_client, "clearer", "12345678") == 401


# R6
def test_patch_user_unknown_user(http_client, system_headers):
    response = patch_user(
        http_client, system_headers, "123456789", {"username": "ghost"}
    )

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "User not found"


# R6
def test_patch_user_deleted_user(http_client, system_headers):
    user_id = create_user(http_client, system_headers, username="doomed")

    response = http_client.delete(
        f"/api/system/users/{user_id}", headers=system_headers
    )
    assert response.status_code == 204

    response = patch_user(http_client, system_headers, user_id, {"username": "undead"})

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "User not found"


# R6 - an empty object is a no-op and changes nothing
def test_patch_user_empty_object(http_client, db_conn, system_headers, test_user):
    before = get_user_row(db_conn, test_user.id)

    response = patch_user(http_client, system_headers, test_user.id, {})

    assert response.status_code == 204
    assert response.content == b""

    after = get_user_row(db_conn, test_user.id)

    assert before == after


# R6
def test_patch_user_empty_object_unknown(http_client, system_headers):
    response = patch_user(http_client, system_headers, "123456789", {})

    assert response.status_code == 404


# R7
def test_patch_user_bot_password_forbidden(http_client, system_headers):
    # A bot must be created without a password at all.
    response = http_client.post(
        "/api/system/users",
        json={"username": "botpw", "is_bot": True},
        headers=system_headers,
    )
    assert response.status_code == 201

    bot_id = response.json()["id"]

    response = patch_user(
        http_client, system_headers, bot_id, {"password": "12345678"}
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'password' is not allowed for bots"


# R7
def test_patch_user_bot_editable(http_client, db_conn, system_headers):
    response = http_client.post(
        "/api/system/users",
        json={"username": "editbot", "is_bot": True},
        headers=system_headers,
    )
    assert response.status_code == 201

    bot_id = response.json()["id"]

    response = patch_user(
        http_client,
        system_headers,
        bot_id,
        {
            "username": "renamedbot",
            "display_name": "Renamed Bot",
        },
    )

    assert response.status_code == 204

    row = get_user_row(db_conn, bot_id)
    assert row["username"] == "renamedbot"
    assert row["display_name"] == "Renamed Bot"


# R7 - clearing the password of a bot is allowed and changes nothing
def test_patch_user_bot_password_null(http_client, db_conn, system_headers):
    response = http_client.post(
        "/api/system/users",
        json={"username": "nullbot", "is_bot": True},
        headers=system_headers,
    )
    assert response.status_code == 201

    bot_id = response.json()["id"]

    response = patch_user(
        http_client, system_headers, bot_id, {"password": None}
    )

    assert response.status_code == 204

    row = get_user_row(db_conn, bot_id)
    assert row["password_hash"] is None


# R8
def test_patch_user_username_taken(http_client, system_headers):
    user_id = create_user(http_client, system_headers, username="first")
    create_user(http_client, system_headers, username="second")

    response = patch_user(
        http_client, system_headers, user_id, {"username": "second"}
    )

    assert response.status_code == 409

    body = response.json()
    assert body["message"] == "Username is already used"

    # Nothing was mutated: the old username still works.
    assert login_status(http_client, "first", "12345678") == 200


# R8
def test_patch_user_username_own_unchanged(http_client, system_headers):
    user_id = create_user(http_client, system_headers, username="same")

    response = patch_user(http_client, system_headers, user_id, {"username": "same"})

    assert response.status_code == 204


# R9 - changing the password revokes every refresh token
def test_patch_user_password_revokes_refresh_tokens(
    http_client, db_conn, system_headers
):
    user_id = create_user(http_client, system_headers, username="revoker")

    _, refresh_token = system_login(http_client, "revoker", "12345678")

    response = patch_user(
        http_client, system_headers, user_id, {"password": "newpass12"}
    )

    assert response.status_code == 204
    assert count_refresh_tokens(db_conn, user_id) == 0

    response = http_client.post(
        "/api/auth/token/refresh",
        headers={"Cookie": f"refresh_token={refresh_token}"},
    )

    assert response.status_code == 401


# R9 - clearing the password revokes every refresh token
def test_patch_user_password_clear_revokes_refresh_tokens(
    http_client, db_conn, system_headers
):
    user_id = create_user(http_client, system_headers, username="clearrevoke")

    _, refresh_token = system_login(http_client, "clearrevoke", "12345678")

    response = patch_user(http_client, system_headers, user_id, {"password": None})

    assert response.status_code == 204
    assert count_refresh_tokens(db_conn, user_id) == 0

    response = http_client.post(
        "/api/auth/token/refresh",
        headers={"Cookie": f"refresh_token={refresh_token}"},
    )

    assert response.status_code == 401


# R9 - a non-password change keeps the refresh tokens
def test_patch_user_non_password_change_keeps_tokens(
    http_client, db_conn, system_headers
):
    user_id = create_user(http_client, system_headers, username="keeper")

    _, refresh_token = system_login(http_client, "keeper", "12345678")

    assert count_refresh_tokens(db_conn, user_id) == 1

    response = patch_user(
        http_client, system_headers, user_id, {"display_name": "Keeper"}
    )

    assert response.status_code == 204
    assert count_refresh_tokens(db_conn, user_id) == 1

    response = http_client.post(
        "/api/auth/token/refresh",
        headers={"Cookie": f"refresh_token={refresh_token}"},
    )

    assert response.status_code == 200
