from conftest import SYSTEM_TOKEN


def _create_superuser_role(http_client, guild_id, user_id):
    response = http_client.post(
        "/api/system/superuser",
        json={"guild_id": guild_id, "user_id": user_id},
        headers={"Authorization": f"Bearer {SYSTEM_TOKEN}"},
    )

    assert response.status_code == 201

    return response.json()["id"]


# R1
def test_delete_role_without_token(http_client, test_guild):
    response = http_client.delete(
        f"/api/system/guilds/{test_guild.id}/roles/123"
    )

    assert response.status_code == 401


# R2
def test_delete_everyone_role_forbidden(http_client, system_headers, test_guild):
    # @everyone role id == guild id
    response = http_client.delete(
        f"/api/system/guilds/{test_guild.id}/roles/{test_guild.id}",
        headers=system_headers,
    )

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Cannot delete the @everyone role"


# R3
def test_delete_non_existent_role(http_client, system_headers, test_guild):
    response = http_client.delete(
        f"/api/system/guilds/{test_guild.id}/roles/123456",
        headers=system_headers,
    )

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "Role not found"


# R3
def test_delete_role_of_other_guild(http_client, system_headers, test_guild):
    other = http_client.post(
        "/api/system/guilds",
        json={"name": "Other Guild"},
        headers=system_headers,
    ).json()

    response = http_client.delete(
        f"/api/system/guilds/{test_guild.id}/roles/{other['id']}",
        headers=system_headers,
    )

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "Role not found"


def test_delete_superuser_role(http_client, system_headers, test_guild, test_user):
    role_id = _create_superuser_role(http_client, test_guild.id, test_user.id)

    token = http_client.post(
        "/api/auth/token",
        json={
            "grant_type": "password",
            "username": test_user.username,
            "password": test_user.password,
        },
    ).json()["access_token"]

    headers = {"Authorization": f"Bearer {token}"}

    response = http_client.delete(
        f"/api/system/guilds/{test_guild.id}/roles/{role_id}",
        headers=system_headers,
    )

    assert response.status_code == 204
    assert response.content == b""

    member_roles = http_client.get(
        f"/api/guilds/{test_guild.id}/members/{test_user.id}/roles", headers=headers
    ).json()

    assert role_id not in member_roles


def test_delete_role_twice(http_client, system_headers, test_guild, test_user):
    role_id = _create_superuser_role(http_client, test_guild.id, test_user.id)

    response = http_client.delete(
        f"/api/system/guilds/{test_guild.id}/roles/{role_id}",
        headers=system_headers,
    )
    assert response.status_code == 204

    response = http_client.delete(
        f"/api/system/guilds/{test_guild.id}/roles/{role_id}",
        headers=system_headers,
    )

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "Role not found"
