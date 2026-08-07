import jwt
import pytest

from conftest import CONFIG


def test_post_token_empty_body(http_client):
    response = http_client.post("/api/auth/token")

    assert response.status_code == 400


# R1
def test_post_token_wrong_content_type(http_client):
    response = http_client.post(
        "/api/auth/token",
        content="grant_type=password",
        headers={"Content-Type": "text/plain"},
    )

    assert response.status_code == 415


# R2
def test_post_token_missing_grant_type(http_client):
    response = http_client.post(
        "/api/auth/token",
        json={
            "username": "foobar",
            "password": "12345678",
        },
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'grant_type' is missing"


# R2
def test_post_token_invalid_grant_type(http_client):
    response = http_client.post(
        "/api/auth/token",
        json={
            "grant_type": 123,
        },
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'grant_type' is not a string"


# R2
def test_post_token_bad_grant_type(http_client):
    response = http_client.post(
        "/api/auth/token",
        json={
            "grant_type": "client_credentials",
        },
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Bad 'grant_type'"


# R3
def test_post_token_missing_username(http_client):
    response = http_client.post(
        "/api/auth/token",
        json={
            "grant_type": "password",
            "password": "12345678",
        },
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'username' is missing"


# R3
def test_post_token_invalid_username(http_client):
    response = http_client.post(
        "/api/auth/token",
        json={
            "grant_type": "password",
            "username": 123,
            "password": "12345678",
        },
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'username' is not a string"


# R4
def test_post_token_missing_password(http_client):
    response = http_client.post(
        "/api/auth/token",
        json={
            "grant_type": "password",
            "username": "foobar",
        },
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'password' is missing"


# R4
def test_post_token_invalid_password(http_client):
    response = http_client.post(
        "/api/auth/token",
        json={
            "grant_type": "password",
            "username": "foobar",
            "password": 123456,
        },
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'password' is not a string"


# R5
def test_post_token_too_long_password(http_client):
    max_len = CONFIG["auth"]["password"]["max_password_len"]

    response = http_client.post(
        "/api/auth/token",
        json={
            "grant_type": "password",
            "username": "foobar",
            "password": "1" * (max_len + 1),
        },
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'password' is too long"


# R6, R7
def test_post_token_bad_creds(http_client):
    response = http_client.post(
        "/api/auth/token",
        json={
            "grant_type": "password",
            "username": "foobar",
            "password": "12345678",
        },
    )

    assert response.status_code == 401

    body = response.json()
    assert body["message"] == "Bad password or username"


# R6, R7
def test_post_token_bad_password(http_client, test_user):
    response = http_client.post(
        "/api/auth/token",
        json={
            "grant_type": "password",
            "username": test_user.username,
            "password": "wrong-password",
        },
    )

    assert response.status_code == 401

    body = response.json()
    assert body["message"] == "Bad password or username"


def test_post_token_auth(http_client, test_user):
    response = http_client.post(
        "/api/auth/token",
        json={
            "grant_type": "password",
            "username": test_user.username,
            "password": test_user.password,
        },
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
