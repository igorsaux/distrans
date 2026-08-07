# R1
def test_get_guilds_unauthorized(http_client, test_guild):
    response = http_client.get("/api/guilds")

    assert response.status_code == 401


def test_get_empty_guilds(http_client, db_conn, test_session):
    response = http_client.get(
        "/api/guilds",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
        },
    )

    assert response.status_code == 200

    body = response.json()
    assert len(body) == 0

    with db_conn.cursor() as cur:
        cur.execute("SELECT id FROM app.guilds;")
        rows = cur.fetchall()

        assert len(rows) == 0


def test_get_guilds(http_client, db_conn, test_session, test_guild):
    response = http_client.get(
        "/api/guilds",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
        },
    )

    assert response.status_code == 200

    body = response.json()
    assert len(body) == 1

    guild = body[0]

    assert guild["id"] == test_guild.id
    assert guild["name"] == test_guild.name
    assert guild["avatar_hash"] is None
    assert "icon_url" not in guild
