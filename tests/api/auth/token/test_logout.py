def test_post_logout_without_cookies(http_client):
    response = http_client.post("/api/auth/token/logout")

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Bad Request"


# R1
def test_post_logout_without_refresh_token_cookie(http_client):
    response = http_client.post(
        "/api/auth/token/logout", headers={"Cookie": "other_cookie=foobar"}
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Bad Request"


# R2
def test_post_logout_bad_token(db_conn, http_client, test_session):
    with db_conn.cursor() as cur:
        cur.execute("DELETE FROM app.refresh_tokens;")

    response = http_client.post(
        "/api/auth/token/logout",
        headers={"Cookie": f"refresh_token={test_session.refresh_token}"},
    )

    assert response.status_code == 401

    body = response.json()
    assert body["message"] == "Bad refresh token"


# R2
def test_post_logout_unknown_token(http_client):
    response = http_client.post(
        "/api/auth/token/logout", headers={"Cookie": "refresh_token=foobar"}
    )

    assert response.status_code == 401

    body = response.json()
    assert body["message"] == "Bad refresh token"


def test_post_logout(db_conn, http_client, test_session):
    with db_conn.cursor() as cur:
        cur.execute("SELECT * FROM app.refresh_tokens;")
        res = cur.fetchall()
        assert len(res) == 1

    response = http_client.post(
        "/api/auth/token/logout",
        headers={"Cookie": f"refresh_token={test_session.refresh_token}"},
    )

    assert response.status_code == 200

    set_cookie_header = response.headers.get("set-cookie")
    assert set_cookie_header is not None
    assert set_cookie_header.startswith("refresh_token=;")
    assert "Path=/api" in set_cookie_header
    assert "Path=/api/auth" not in set_cookie_header
    assert "Max-Age=0" in set_cookie_header

    with db_conn.cursor() as cur:
        cur.execute("SELECT * FROM app.refresh_tokens;")
        res = cur.fetchall()
        assert len(res) == 0


def test_post_logout_twice(db_conn, http_client, test_session):
    response = http_client.post(
        "/api/auth/token/logout",
        headers={"Cookie": f"refresh_token={test_session.refresh_token}"},
    )

    assert response.status_code == 200

    response = http_client.post(
        "/api/auth/token/logout",
        headers={"Cookie": f"refresh_token={test_session.refresh_token}"},
    )

    assert response.status_code == 401

    body = response.json()
    assert body["message"] == "Bad refresh token"
