from conftest import SYSTEM_TOKEN

SUPERUSER_PERMISSIONS = str(2**128 - 1)


def _create_superuser(http_client, system_headers, guild_id, user_id):
    return http_client.post(
        "/api/system/superuser",
        json={"guild_id": guild_id, "user_id": user_id},
        headers=system_headers,
    )


# R1
def test_superuser_non_json_content_type(http_client, system_headers):
    response = http_client.post(
        "/api/system/superuser",
        content=b"guild_id=1",
        headers={**system_headers, "Content-Type": "text/plain"},
    )

    assert response.status_code == 415


# R1
def test_superuser_empty_body(http_client, system_headers):
    response = http_client.post(
        "/api/system/superuser",
        content=b"",
        headers={**system_headers, "Content-Type": "application/json"},
    )

    assert response.status_code == 400


# R2
def test_superuser_without_token(http_client, test_guild, test_user):
    response = http_client.post(
        "/api/system/superuser",
        json={"guild_id": test_guild.id, "user_id": test_user.id},
    )

    assert response.status_code == 401


# R3
def test_superuser_missing_guild_id(http_client, system_headers, test_user):
    response = http_client.post(
        "/api/system/superuser",
        json={"user_id": test_user.id},
        headers=system_headers,
    )

    assert response.status_code == 400


# R3
def test_superuser_guild_id_not_a_string(http_client, system_headers, test_user):
    response = http_client.post(
        "/api/system/superuser",
        json={"guild_id": 42, "user_id": test_user.id},
        headers=system_headers,
    )

    assert response.status_code == 400


# R3
def test_superuser_bad_guild_id(http_client, system_headers, test_user):
    response = http_client.post(
        "/api/system/superuser",
        json={"guild_id": "not-a-number", "user_id": test_user.id},
        headers=system_headers,
    )

    assert response.status_code == 400


# R4
def test_superuser_missing_user_id(http_client, system_headers, test_guild):
    response = http_client.post(
        "/api/system/superuser",
        json={"guild_id": test_guild.id},
        headers=system_headers,
    )

    assert response.status_code == 400


# R4
def test_superuser_user_id_not_a_string(http_client, system_headers, test_guild):
    response = http_client.post(
        "/api/system/superuser",
        json={"guild_id": test_guild.id, "user_id": 42},
        headers=system_headers,
    )

    assert response.status_code == 400


# R4
def test_superuser_bad_user_id(http_client, system_headers, test_guild):
    response = http_client.post(
        "/api/system/superuser",
        json={"guild_id": test_guild.id, "user_id": "not-a-number"},
        headers=system_headers,
    )

    assert response.status_code == 400


# R5
def test_superuser_unknown_guild(http_client, system_headers, test_user):
    response = _create_superuser(http_client, system_headers, "1", test_user.id)

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "Guild or user not found"


# R5
def test_superuser_unknown_user(http_client, system_headers, test_guild):
    response = _create_superuser(http_client, system_headers, test_guild.id, "1")

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "Guild or user not found"


# R5
def test_superuser(http_client, system_headers, test_guild, test_user):
    response = _create_superuser(
        http_client, system_headers, test_guild.id, test_user.id
    )

    assert response.status_code == 201

    role_id = response.json()["id"]
    assert role_id is not None

    token = http_client.post(
        "/api/auth/token",
        json={
            "grant_type": "password",
            "username": test_user.username,
            "password": test_user.password,
        },
    ).json()["access_token"]

    headers = {"Authorization": f"Bearer {token}"}

    roles = http_client.get(
        f"/api/guilds/{test_guild.id}/roles", headers=headers
    ).json()

    # test_guild fixture creates its own superuser role for guild_admin;
    # this test adds a second one for test_user.
    superuser_roles = [r for r in roles if r["name"] == "superuser"]
    assert len(superuser_roles) == 2

    role = next(r for r in superuser_roles if r["id"] == role_id)
    assert role["id"] == role_id
    assert role["permissions"] == SUPERUSER_PERMISSIONS
    # The superuser role sits on top (MAX(position) + 1); concurrent superusers
    # stack above each other rather than sharing the old fixed SMALLINT max.
    assert role["position"] == max(r["position"] for r in roles)
    assert role["position"] > 0

    member_roles = http_client.get(
        f"/api/guilds/{test_guild.id}/members/{test_user.id}/roles", headers=headers
    ).json()

    assert role_id in member_roles


def test_superuser_position_above_any_existing(
    http_client, db_conn, system_headers, test_guild, test_user
):
    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.roles (id, guild_id, name, position, permissions)"
            " VALUES (%s, %s, %s, %s, %s)",
            (777001, int(test_guild.id), "high", 5, (0).to_bytes(16)),
        )

    response = _create_superuser(
        http_client, system_headers, test_guild.id, test_user.id
    )

    assert response.status_code == 201

    role_id = response.json()["id"]

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT position FROM app.roles WHERE id = %s;", (int(role_id),)
        )
        row = cur.fetchone()

    assert row is not None
    # Sits above the seeded "high" role (5): MAX(position) + 1 = 6.
    assert row["position"] == 6


def test_superuser_twice_creates_new_role(
    http_client, db_conn, system_headers, test_guild, test_user
):
    first = _create_superuser(
        http_client, system_headers, test_guild.id, test_user.id
    )
    assert first.status_code == 201

    second = _create_superuser(
        http_client, system_headers, test_guild.id, test_user.id
    )
    assert second.status_code == 201

    first_role_id = int(first.json()["id"])
    second_role_id = int(second.json()["id"])

    assert first_role_id != second_role_id

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT position FROM app.roles WHERE id = %s ORDER BY id;", (first_role_id,)
        )
        first_pos = cur.fetchone()["position"]

        cur.execute("SELECT position FROM app.roles WHERE id = %s;", (second_role_id,))
        second_pos = cur.fetchone()["position"]

    # Each new superuser role stacks on top (MAX(position) + 1); the point of
    # the test is that a second, distinct role row is created above the first.
    assert second_pos == first_pos + 1
    assert first_pos > 1
    assert second_role_id != first_role_id


def test_superuser_permissions_actually_apply(
    http_client, db_conn, system_headers, test_guild, test_channel, test_user
):
    # With @everyone permissions stripped to zero, only the superuser
    # role grants the right to post messages.
    with db_conn.cursor() as cur:
        cur.execute(
            "UPDATE app.roles SET permissions = %s WHERE id = %s",
            ((0).to_bytes(16), int(test_guild.id)),
        )

    response = _create_superuser(
        http_client, system_headers, test_guild.id, test_user.id
    )
    assert response.status_code == 201

    token = http_client.post(
        "/api/auth/token",
        json={
            "grant_type": "password",
            "username": test_user.username,
            "password": test_user.password,
        },
    ).json()["access_token"]

    response = http_client.post(
        f"/api/channels/{test_channel.id}/messages",
        json={"content": "i am superuser"},
        headers={"Authorization": f"Bearer {token}"},
    )

    assert response.status_code == 201
