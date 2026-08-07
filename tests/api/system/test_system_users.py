import psycopg
import pytest

from conftest import seed_role


# R1
def test_create_user_non_json_content_type(http_client, system_headers):
    response = http_client.post(
        "/api/system/users",
        content=b"username=u&password=p",
        headers={**system_headers, "Content-Type": "text/plain"},
    )

    assert response.status_code == 415


# R1
def test_create_user_empty_body(http_client, system_headers):
    response = http_client.post(
        "/api/system/users",
        content=b"",
        headers={**system_headers, "Content-Type": "application/json"},
    )

    assert response.status_code == 400


# R2
def test_create_user_without_token(http_client):
    response = http_client.post(
        "/api/system/users",
        json={"username": "uu", "password": "p"},
    )

    assert response.status_code == 401


# R2
def test_create_user_with_bad_token(http_client, system_headers):
    response = http_client.post(
        "/api/system/users",
        json={"username": "uu", "password": "p"},
        headers={"Authorization": "Bearer wrong-token"},
    )

    assert response.status_code == 401


# R3
def test_create_user_missing_username(http_client, system_headers):
    response = http_client.post(
        "/api/system/users",
        json={"password": "12345678"},
        headers=system_headers,
    )

    assert response.status_code == 400


# R3
def test_create_user_username_not_a_string(http_client, system_headers):
    response = http_client.post(
        "/api/system/users",
        json={"username": 42, "password": "12345678"},
        headers=system_headers,
    )

    assert response.status_code == 400


# R3
def test_create_user_username_too_short(http_client, system_headers):
    response = http_client.post(
        "/api/system/users",
        json={"username": "u", "password": "12345678"},
        headers=system_headers,
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'username' is too short"


# R3
def test_create_user_username_min_length(http_client, system_headers):
    response = http_client.post(
        "/api/system/users",
        json={"username": "ab", "password": "12345678"},
        headers=system_headers,
    )

    assert response.status_code == 201


# R3
def test_create_user_username_too_long(http_client, system_headers):
    response = http_client.post(
        "/api/system/users",
        json={"username": "u" * 33, "password": "12345678"},
        headers=system_headers,
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'username' is too long"


# R3
def test_create_user_username_max_length(http_client, system_headers):
    response = http_client.post(
        "/api/system/users",
        json={"username": "u" * 32, "password": "12345678"},
        headers=system_headers,
    )

    assert response.status_code == 201


# R3
@pytest.mark.parametrize(
    "username",
    [
        "Abc",
        "ab c",
        "ab@c",
        "ab-c",
        ".ab",
        "ab_",
        "a..b",
        "алис",
        "ab.c.d_",
    ],
)
def test_create_user_username_invalid(http_client, system_headers, username):
    response = http_client.post(
        "/api/system/users",
        json={"username": username, "password": "12345678"},
        headers=system_headers,
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'username' is invalid"


# R3
@pytest.mark.parametrize(
    "username",
    ["admin", "moderator", "support", "system", "everyone", "here", "me", "staff"],
)
def test_create_user_username_reserved(http_client, system_headers, username):
    response = http_client.post(
        "/api/system/users",
        json={"username": username, "password": "12345678"},
        headers=system_headers,
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'username' is reserved"


# R4 - password is optional: a user without a password can be created
def test_create_user_without_password(http_client, db_conn, system_headers):
    response = http_client.post(
        "/api/system/users",
        json={"username": "nopass"},
        headers=system_headers,
    )

    assert response.status_code == 201

    body = response.json()

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT password_hash FROM app.users WHERE id = %s;", (int(body["id"]),)
        )
        row = cur.fetchone()

    assert row is not None
    assert row["password_hash"] is None


# R4
def test_create_user_password_not_a_string(http_client, system_headers):
    response = http_client.post(
        "/api/system/users",
        json={"username": "uu", "password": 123456},
        headers=system_headers,
    )

    assert response.status_code == 400


# R4
def test_create_user_password_too_short(http_client, system_headers):
    response = http_client.post(
        "/api/system/users",
        json={"username": "uu", "password": "x" * 7},
        headers=system_headers,
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'password' is too short"


# R4
def test_create_user_password_min_length(http_client, system_headers):
    response = http_client.post(
        "/api/system/users",
        json={"username": "uu", "password": "x" * 8},
        headers=system_headers,
    )

    assert response.status_code == 201


# R4
def test_create_user_password_max_codepoints(http_client, system_headers):
    # 64 Cyrillic codepoints = 128 bytes: exactly at both limits.
    response = http_client.post(
        "/api/system/users",
        json={"username": "uu", "password": "ы" * 64},
        headers=system_headers,
    )

    assert response.status_code == 201


# R4
def test_create_user_password_codepoints_too_long(http_client, system_headers):
    # 65 codepoints under the byte cap: still rejected by the codepoint limit.
    response = http_client.post(
        "/api/system/users",
        json={"username": "uu", "password": "ы" * 65},
        headers=system_headers,
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'password' is too long"


# R4
def test_create_user_password_too_long(http_client, system_headers):
    response = http_client.post(
        "/api/system/users",
        json={"username": "uu", "password": "x" * 1025},
        headers=system_headers,
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'password' is too long"


# R5
def test_create_user_bad_display_name(http_client, system_headers):
    response = http_client.post(
        "/api/system/users",
        json={"username": "uu", "password": "12345678", "display_name": 1},
        headers=system_headers,
    )

    assert response.status_code == 400


# R5
def test_create_user_display_name_too_short(http_client, system_headers):
    response = http_client.post(
        "/api/system/users",
        json={"username": "uu", "password": "12345678", "display_name": ""},
        headers=system_headers,
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'display_name' is too short"


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
def test_create_user_display_name_invalid(http_client, system_headers, display_name):
    response = http_client.post(
        "/api/system/users",
        json={"username": "uu", "password": "12345678", "display_name": display_name},
        headers=system_headers,
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'display_name' is invalid"


# R5
def test_create_user_display_name_too_long(http_client, system_headers):
    response = http_client.post(
        "/api/system/users",
        json={"username": "uu", "password": "12345678", "display_name": "d" * 33},
        headers=system_headers,
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'display_name' is too long"


# R5
def test_create_user_display_name_max_length(http_client, system_headers):
    response = http_client.post(
        "/api/system/users",
        json={"username": "uu", "password": "12345678", "display_name": "d" * 32},
        headers=system_headers,
    )

    assert response.status_code == 201


# R7
def test_create_user_duplicate_username(http_client, system_headers):
    response = http_client.post(
        "/api/system/users",
        json={"username": "dup", "password": "12345678"},
        headers=system_headers,
    )
    assert response.status_code == 201

    response = http_client.post(
        "/api/system/users",
        json={"username": "dup", "password": "12345678"},
        headers=system_headers,
    )

    assert response.status_code == 409


def test_create_user(http_client, db_conn, system_headers):
    response = http_client.post(
        "/api/system/users",
        json={"username": "alice", "password": "secretpw", "display_name": "Alice"},
        headers=system_headers,
    )

    assert response.status_code == 201

    body = response.json()

    assert "id" in body

    with db_conn.cursor() as cur:
        cur.execute("SELECT id, password_hash FROM app.users WHERE username = 'alice';")
        row = cur.fetchone()

    assert row is not None
    assert str(row["id"]) == body["id"]
    assert row["password_hash"].startswith("$argon2id$")


def test_created_user_can_login(http_client, system_headers):
    http_client.post(
        "/api/system/users",
        json={"username": "bob", "password": "hunter2x"},
        headers=system_headers,
    )

    response = http_client.post(
        "/api/auth/token",
        json={"grant_type": "password", "username": "bob", "password": "hunter2x"},
    )

    assert response.status_code == 200
    assert "access_token" in response.json()


def test_created_user_reachable_via_users_api(http_client, system_headers):
    created = http_client.post(
        "/api/system/users",
        json={"username": "carol", "password": "12345678"},
        headers=system_headers,
    ).json()

    token = http_client.post(
        "/api/auth/token",
        json={"grant_type": "password", "username": "carol", "password": "12345678"},
    ).json()["access_token"]

    response = http_client.get(
        f"/api/users/{created['id']}",
        headers={"Authorization": f"Bearer {token}"},
    )

    assert response.status_code == 200
    assert response.json()["username"] == "carol"


# R6
def test_create_user_id_not_a_string(http_client, system_headers):
    response = http_client.post(
        "/api/system/users",
        json={"id": 123, "username": "uu", "password": "12345678"},
        headers=system_headers,
    )

    assert response.status_code == 400


# R6
def test_create_user_bad_id(http_client, system_headers):
    response = http_client.post(
        "/api/system/users",
        json={"id": "not-a-number", "username": "uu", "password": "12345678"},
        headers=system_headers,
    )

    assert response.status_code == 400


# R6
def test_create_user_with_id(http_client, db_conn, system_headers):
    response = http_client.post(
        "/api/system/users",
        json={"id": "123456789", "username": "withid", "password": "12345678"},
        headers=system_headers,
    )

    assert response.status_code == 201
    assert response.json()["id"] == "123456789"

    with db_conn.cursor() as cur:
        cur.execute("SELECT id, username FROM app.users WHERE id = 123456789;")
        row = cur.fetchone()

    assert row is not None
    assert row["username"] == "withid"


# R7
def test_create_user_duplicate_id(http_client, system_headers):
    response = http_client.post(
        "/api/system/users",
        json={"id": "987654321", "username": "dup_id", "password": "12345678"},
        headers=system_headers,
    )

    assert response.status_code == 201

    response = http_client.post(
        "/api/system/users",
        json={"id": "987654321", "username": "other_name", "password": "12345678"},
        headers=system_headers,
    )

    assert response.status_code == 409


# R8
def test_create_user_is_bot_not_a_boolean(http_client, system_headers):
    response = http_client.post(
        "/api/system/users",
        json={"username": "botstr", "is_bot": "yes"},
        headers=system_headers,
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'is_bot' is not a boolean"


# R8
def test_create_bot_with_password(http_client, system_headers):
    response = http_client.post(
        "/api/system/users",
        json={"username": "botpw", "is_bot": True, "password": "12345678"},
        headers=system_headers,
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'password' is not allowed for bots"


# R8
def test_create_bot(http_client, db_conn, system_headers):
    response = http_client.post(
        "/api/system/users",
        json={"username": "nicebot", "is_bot": True},
        headers=system_headers,
    )

    assert response.status_code == 201

    body = response.json()

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT is_bot, password_hash FROM app.users WHERE id = %s;",
            (int(body["id"]),),
        )
        row = cur.fetchone()

    assert row is not None
    assert row["is_bot"] is True
    assert row["password_hash"] is None


# R8
def test_create_non_bot_user_is_bot_false(http_client, db_conn, system_headers):
    response = http_client.post(
        "/api/system/users",
        json={"username": "human", "password": "12345678", "is_bot": False},
        headers=system_headers,
    )

    assert response.status_code == 201

    body = response.json()

    with db_conn.cursor() as cur:
        cur.execute("SELECT is_bot FROM app.users WHERE id = %s;", (int(body["id"]),))
        row = cur.fetchone()

    assert row is not None
    assert row["is_bot"] is False


def test_passwordless_user_cannot_login(http_client, system_headers):
    http_client.post(
        "/api/system/users",
        json={"username": "nopasslogin"},
        headers=system_headers,
    )

    response = http_client.post(
        "/api/auth/token",
        json={
            "grant_type": "password",
            "username": "nopasslogin",
            "password": "whatever",
        },
    )

    assert response.status_code == 401


def test_delete_user_removes_all_roles(
    http_client, db_conn, system_headers, test_guild, test_session
):
    user = http_client.post(
        "/api/system/users",
        json={"username": "roleless", "password": "12345678"},
        headers=system_headers,
    ).json()

    role_id = "5610001"

    seed_role(db_conn, test_guild.id, role_id, "doomed", permissions=0)

    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.member_roles (guild_id, role_id, user_id)"
            " VALUES (%s, %s, %s)",
            (test_guild.id, role_id, int(user["id"])),
        )

    response = http_client.delete(
        f"/api/system/users/{user['id']}", headers=system_headers
    )
    assert response.status_code == 204

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT count(*) AS n FROM app.member_roles WHERE user_id = %s;",
            (int(user["id"]),),
        )
        assert cur.fetchone()["n"] == 0

    member_roles = http_client.get(
        f"/api/guilds/{test_guild.id}/members/{user['id']}/roles",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert member_roles.status_code == 200
    assert member_roles.json() == [str(test_guild.id)]


def test_delete_user_clears_refresh_tokens(http_client, db_conn, system_headers):
    user = http_client.post(
        "/api/system/users",
        json={"username": "tokenless", "password": "12345678"},
        headers=system_headers,
    ).json()

    login = http_client.post(
        "/api/auth/token",
        json={
            "grant_type": "password",
            "username": "tokenless",
            "password": "12345678",
        },
    )

    assert login.status_code == 200
    assert "refresh_token" in login.cookies

    response = http_client.delete(
        f"/api/system/users/{user['id']}", headers=system_headers
    )
    assert response.status_code == 204

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT count(*) AS n FROM app.refresh_tokens WHERE user_id = %s;",
            (int(user["id"]),),
        )
        assert cur.fetchone()["n"] == 0

    refresh = http_client.post(
        "/api/auth/token/refresh",
        cookies={"refresh_token": login.cookies["refresh_token"]},
    )

    assert refresh.status_code == 401


def test_deleted_user_access_token_rejected(http_client, system_headers):
    user = http_client.post(
        "/api/system/users",
        json={"username": "deadwalker", "password": "12345678"},
        headers=system_headers,
    ).json()

    token = http_client.post(
        "/api/auth/token",
        json={
            "grant_type": "password",
            "username": "deadwalker",
            "password": "12345678",
        },
    ).json()["access_token"]

    headers = {"Authorization": f"Bearer {token}"}

    assert http_client.get("/api/users/@me", headers=headers).status_code == 200

    response = http_client.delete(
        f"/api/system/users/{user['id']}", headers=system_headers
    )
    assert response.status_code == 204

    response = http_client.get("/api/users/@me", headers=headers)

    assert response.status_code == 401


def test_delete_bot_clears_bot_tokens(http_client, db_conn, system_headers):
    user = http_client.post(
        "/api/system/users",
        json={"username": "tokbot", "is_bot": True},
        headers=system_headers,
    ).json()

    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.bot_tokens (user_id, token_hash) VALUES (%s, %s);",
            (int(user["id"]), b"\x01" * 32),
        )

    response = http_client.delete(
        f"/api/system/users/{user['id']}", headers=system_headers
    )
    assert response.status_code == 204

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT count(*) AS n FROM app.bot_tokens WHERE user_id = %s;",
            (int(user["id"]),),
        )
        assert cur.fetchone()["n"] == 0


# R1
def test_delete_user_without_token(http_client, test_user):
    response = http_client.delete(f"/api/system/users/{test_user.id}")

    assert response.status_code == 401


def test_delete_non_existent_user(http_client, system_headers):
    response = http_client.delete("/api/system/users/1", headers=system_headers)

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "User not found"


def test_delete_user(http_client, db_conn, system_headers):
    user = http_client.post(
        "/api/system/users",
        json={"username": "doomed", "password": "12345678"},
        headers=system_headers,
    ).json()

    response = http_client.delete(
        f"/api/system/users/{user['id']}", headers=system_headers
    )

    assert response.status_code == 204
    assert response.content == b""

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT username, display_name, avatar_hash, password_hash, deleted_at "
            "FROM app.users WHERE id = %s;",
            (int(user["id"]),),
        )
        row = cur.fetchone()

    assert row is not None
    assert row["username"] == f"deleted-{user['id']}"
    assert row["display_name"] is None
    assert row["avatar_hash"] is None
    assert row["password_hash"] is None
    assert row["deleted_at"] is not None


def test_soft_deleted_user_cannot_be_un_anonymized(
    http_client, db_conn, system_headers
):
    # Regression: the dropped `users_deleted_is_anonymous` constraint let a
    # soft-deleted row carry identifying data again (display_name / credentials /
    # avatar). The database must reject any such update on a deleted user.
    user = http_client.post(
        "/api/system/users",
        json={"username": "anonguard", "password": "12345678"},
        headers=system_headers,
    ).json()

    response = http_client.delete(
        f"/api/system/users/{user['id']}", headers=system_headers
    )
    assert response.status_code == 204

    with pytest.raises(psycopg.errors.CheckViolation):
        with db_conn.cursor() as cur:
            cur.execute(
                "UPDATE app.users SET display_name = 'resurrected' WHERE id = %s;",
                (int(user["id"]),),
            )


def test_deleted_user_cannot_login(http_client, system_headers):
    user = http_client.post(
        "/api/system/users",
        json={"username": "ghost2", "password": "12345678"},
        headers=system_headers,
    ).json()

    response = http_client.delete(
        f"/api/system/users/{user['id']}", headers=system_headers
    )
    assert response.status_code == 204

    response = http_client.post(
        "/api/auth/token",
        json={"grant_type": "password", "username": "ghost2", "password": "12345678"},
    )

    assert response.status_code == 401


def test_delete_user_twice(http_client, system_headers):
    user = http_client.post(
        "/api/system/users",
        json={"username": "twice", "password": "12345678"},
        headers=system_headers,
    ).json()

    response = http_client.delete(
        f"/api/system/users/{user['id']}", headers=system_headers
    )
    assert response.status_code == 204

    response = http_client.delete(
        f"/api/system/users/{user['id']}", headers=system_headers
    )

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "User not found"
