import jwt
import pytest


def test_post_refresh_empty_body(http_client):
    response = http_client.post("/api/auth/token/refresh")

    assert response.status_code == 400


# R1
def test_post_refresh_no_cookies(http_client):
    response = http_client.post("/api/auth/token/refresh")

    assert response.status_code == 400


# R1
def test_post_refresh_without_refresh_token_cookie(http_client):
    response = http_client.post(
        "/api/auth/token/refresh", headers={"Cookie": "other_cookie=foobar"}
    )

    assert response.status_code == 400


# R2
def test_post_refresh_bad_token(http_client):
    response = http_client.post(
        "/api/auth/token/refresh", headers={"Cookie": "refresh_token=foobar"}
    )

    assert response.status_code == 401

    body = response.json()
    assert body["message"] == "Bad refresh token"


def test_post_refresh_token(db_conn, http_client, test_session):
    old_hash = None

    with db_conn.cursor() as cur:
        cur.execute("SELECT * FROM app.refresh_tokens;")
        res = cur.fetchall()
        assert len(res) == 1
        old_hash = res[0]["token_hash"]

    response = http_client.post(
        "/api/auth/token/refresh",
        headers={"Cookie": f"refresh_token={test_session.refresh_token}"},
    )

    assert response.status_code == 200

    set_cookie_header = response.headers.get("set-cookie")
    assert set_cookie_header is not None
    assert set_cookie_header.startswith("refresh_token=")
    assert "Path=/api" in set_cookie_header
    assert "Path=/api/auth" not in set_cookie_header

    body = response.json()

    access_token = body.get("access_token")
    assert access_token is not None

    try:
        payload = jwt.decode(access_token, "CHANGE_ME", algorithms=["HS256"])
    except jwt.ExpiredSignatureError:
        pytest.fail("JWT is expired")
    except jwt.InvalidTokenError:
        pytest.fail("Invalid JWT")

    with db_conn.cursor() as cur:
        cur.execute("SELECT * FROM app.refresh_tokens;")
        res = cur.fetchall()
        assert len(res) == 1
        assert old_hash != res[0]["token_hash"]
