# R1
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from permissions import ADD_REACTIONS, READ_MESSAGES, SEND_MESSAGES

DEFAULT_EVERYONE_PERMISSIONS = (READ_MESSAGES | SEND_MESSAGES | ADD_REACTIONS).to_bytes(16)


def test_create_guild_non_json_content_type(http_client, system_headers):
    response = http_client.post(
        "/api/system/guilds",
        content=b"name=g",
        headers={**system_headers, "Content-Type": "text/plain"},
    )

    assert response.status_code == 415


# R1
def test_create_guild_empty_body(http_client, system_headers):
    response = http_client.post(
        "/api/system/guilds",
        content=b"",
        headers={**system_headers, "Content-Type": "application/json"},
    )

    assert response.status_code == 400


# R2
def test_create_guild_without_token(http_client):
    response = http_client.post("/api/system/guilds", json={"name": "g"})

    assert response.status_code == 401


# R3
def test_create_guild_missing_name(http_client, system_headers):
    response = http_client.post("/api/system/guilds", json={}, headers=system_headers)

    assert response.status_code == 400


# R3
def test_create_guild_name_not_a_string(http_client, system_headers):
    response = http_client.post(
        "/api/system/guilds", json={"name": 42}, headers=system_headers
    )

    assert response.status_code == 400


# R3
def test_create_guild_name_too_long(http_client, system_headers):
    response = http_client.post(
        "/api/system/guilds", json={"name": "g" * 19}, headers=system_headers
    )

    assert response.status_code == 400


# R3
def test_create_guild_name_max_length(http_client, system_headers):
    response = http_client.post(
        "/api/system/guilds", json={"name": "g" * 18}, headers=system_headers
    )

    assert response.status_code == 201


# R3
def test_create_guild_name_forbidden_codepoints(http_client, system_headers):
    response = http_client.post(
        "/api/system/guilds", json={"name": "g\u200Bh"}, headers=system_headers
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'name' is invalid"


def test_create_guild(http_client, db_conn, system_headers):
    response = http_client.post(
        "/api/system/guilds",
        json={"name": "My Guild"},
        headers=system_headers,
    )

    assert response.status_code == 201

    body = response.json()

    assert "id" in body

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT id, name FROM app.guilds WHERE id = %s;", (int(body["id"]),)
        )
        guild_row = cur.fetchone()

        cur.execute(
            "SELECT id, name, permissions FROM app.roles WHERE guild_id = %s;",
            (int(body["id"]),),
        )
        role_rows = cur.fetchall()

    assert guild_row is not None

    # @everyone role is created with id == guild_id and default permissions
    assert len(role_rows) == 1
    assert str(role_rows[0]["id"]) == body["id"]
    assert role_rows[0]["name"] == "@everyone"
    assert bytes(role_rows[0]["permissions"]) == DEFAULT_EVERYONE_PERMISSIONS


def test_created_guild_roles_listed_via_api(http_client, system_headers):
    guild = http_client.post(
        "/api/system/guilds",
        json={"name": "Roles Guild"},
        headers=system_headers,
    ).json()

    http_client.post(
        "/api/system/users",
        json={"username": "u1", "password": "12345678"},
        headers=system_headers,
    )

    token = http_client.post(
        "/api/auth/token",
        json={"grant_type": "password", "username": "u1", "password": "12345678"},
    ).json()["access_token"]

    response = http_client.get(
        f"/api/guilds/{guild['id']}/roles",
        headers={"Authorization": f"Bearer {token}"},
    )

    assert response.status_code == 200

    roles = response.json()
    assert len(roles) == 1
    assert roles[0]["name"] == "@everyone"

# R4
def test_create_guild_id_not_a_string(http_client, system_headers):
    response = http_client.post(
        "/api/system/guilds",
        json={"id": 42, "name": "g"},
        headers=system_headers,
    )

    assert response.status_code == 400


# R4
def test_create_guild_bad_id(http_client, system_headers):
    response = http_client.post(
        "/api/system/guilds",
        json={"id": "not-a-number", "name": "g"},
        headers=system_headers,
    )

    assert response.status_code == 400


# R4, R5
def test_create_guild_with_id(http_client, db_conn, system_headers):
    response = http_client.post(
        "/api/system/guilds",
        json={"id": "555000111", "name": "Pinned Guild"},
        headers=system_headers,
    )

    assert response.status_code == 201
    assert response.json()["id"] == "555000111"

    with db_conn.cursor() as cur:
        cur.execute("SELECT id, name FROM app.guilds WHERE id = 555000111;")
        guild_row = cur.fetchone()

        cur.execute(
            "SELECT id FROM app.roles WHERE guild_id = 555000111;"
        )
        role_rows = cur.fetchall()

    assert guild_row is not None
    assert guild_row["name"] == "Pinned Guild"

    # @everyone role is created with id == guild_id
    assert len(role_rows) == 1
    assert str(role_rows[0]["id"]) == "555000111"


# R5
def test_create_guild_duplicate_id(http_client, system_headers):
    response = http_client.post(
        "/api/system/guilds",
        json={"id": "666000222", "name": "First"},
        headers=system_headers,
    )

    assert response.status_code == 201

    response = http_client.post(
        "/api/system/guilds",
        json={"id": "666000222", "name": "Second"},
        headers=system_headers,
    )

    assert response.status_code == 409


# R1
def test_delete_guild_without_token(http_client, test_guild):
    response = http_client.delete(f"/api/system/guilds/{test_guild.id}")

    assert response.status_code == 401


def test_delete_non_existent_guild(http_client, system_headers):
    response = http_client.delete("/api/system/guilds/1", headers=system_headers)

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "Guild not found"


def test_delete_guild(http_client, db_conn, system_headers):
    guild = http_client.post(
        "/api/system/guilds", json={"name": "Doomed"}, headers=system_headers
    ).json()

    response = http_client.delete(
        f"/api/system/guilds/{guild['id']}", headers=system_headers
    )

    assert response.status_code == 204
    assert response.content == b""

    with db_conn.cursor() as cur:
        cur.execute("SELECT id FROM app.guilds WHERE id = %s;", (int(guild["id"]),))
        assert cur.fetchone() is None

        # Roles are cleaned up by the cascade
        cur.execute("SELECT id FROM app.roles WHERE guild_id = %s;", (int(guild["id"]),))
        assert cur.fetchall() == []


def test_deleted_guild_not_found_via_api(http_client, system_headers):
    guild = http_client.post(
        "/api/system/guilds", json={"name": "Doomed2"}, headers=system_headers
    ).json()

    user = http_client.post(
        "/api/system/users",
        json={"username": "doomed2user", "password": "12345678"},
        headers=system_headers,
    ).json()

    token = http_client.post(
        "/api/auth/token",
        json={"grant_type": "password", "username": "doomed2user", "password": "12345678"},
    ).json()["access_token"]

    response = http_client.delete(
        f"/api/system/guilds/{guild['id']}", headers=system_headers
    )
    assert response.status_code == 204

    response = http_client.get(
        f"/api/guilds/{guild['id']}/roles",
        headers={"Authorization": f"Bearer {token}"},
    )

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "Guild not found"


def test_delete_guild_twice(http_client, system_headers):
    guild = http_client.post(
        "/api/system/guilds", json={"name": "Doomed3"}, headers=system_headers
    ).json()

    response = http_client.delete(
        f"/api/system/guilds/{guild['id']}", headers=system_headers
    )
    assert response.status_code == 204

    response = http_client.delete(
        f"/api/system/guilds/{guild['id']}", headers=system_headers
    )

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "Guild not found"
