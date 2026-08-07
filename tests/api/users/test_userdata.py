import json
from pathlib import Path

from conftest import system_create_user, system_login

CONFIG_PATH = Path(__file__).resolve().parent.parent.parent.parent / "config.tests.json"

with CONFIG_PATH.open() as f:
    CONFIG = json.load(f)

MAX_USERDATA_BYTES = CONFIG["api"]["users"]["max_userdata_bytes"]

USERDATA_URL = "/api/users/@me/userdata"


def _auth(session):
    return {"Authorization": f"Bearer {session.access_token}"}


# ---------------------------------------------------------------------------
# Auth (R1)
# ---------------------------------------------------------------------------


def test_get_userdata_unauthorized(http_client):
    response = http_client.get(USERDATA_URL)

    assert response.status_code == 401


def test_put_userdata_unauthorized(http_client):
    response = http_client.put(USERDATA_URL, json={"a": 1})

    assert response.status_code == 401


# ---------------------------------------------------------------------------
# PUT content-type / empty body (R1)
# ---------------------------------------------------------------------------


def test_put_userdata_bad_content_type(http_client, test_session):
    response = http_client.put(
        USERDATA_URL,
        content='{"a": 1}',
        headers={**_auth(test_session), "Content-Type": "text/plain"},
    )

    assert response.status_code == 415


def test_put_userdata_empty_body(http_client, test_session):
    response = http_client.put(USERDATA_URL, headers=_auth(test_session))

    assert response.status_code == 400


# ---------------------------------------------------------------------------
# Size cap (R3)
# ---------------------------------------------------------------------------


def test_put_userdata_too_large(http_client, test_session):
    # One byte over the cap. A JSON string of N 'a' chars is N+2 bytes.
    payload = '"' + "a" * (MAX_USERDATA_BYTES + 1) + '"'
    assert len(payload) > MAX_USERDATA_BYTES

    response = http_client.put(
        USERDATA_URL,
        content=payload,
        headers={**_auth(test_session), "Content-Type": "application/json"},
    )

    assert response.status_code == 413
    assert response.json()["message"] == "Userdata is too large"


# ---------------------------------------------------------------------------
# Bad JSON (R4)
# ---------------------------------------------------------------------------


def test_put_userdata_bad_json(http_client, test_session):
    response = http_client.put(
        USERDATA_URL,
        content="{",
        headers={**_auth(test_session), "Content-Type": "application/json"},
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Bad JSON"


# ---------------------------------------------------------------------------
# Empty state (R2)
# ---------------------------------------------------------------------------


def test_get_userdata_empty(http_client, test_session):
    response = http_client.get(USERDATA_URL, headers=_auth(test_session))

    assert response.status_code == 200
    assert response.json() == {"data": None, "updated_at": None}


# ---------------------------------------------------------------------------
# Round trip (R5)
# ---------------------------------------------------------------------------


def test_put_userdata_round_trip(http_client, test_session):
    value = {"theme": "dark", "sidebar": {"width": 280}, "tags": ["a", "b"]}

    put = http_client.put(USERDATA_URL, json=value, headers=_auth(test_session))
    assert put.status_code == 200

    body = put.json()
    assert isinstance(body["updated_at"], int)
    assert body["updated_at"] >= 0

    get = http_client.get(USERDATA_URL, headers=_auth(test_session))
    assert get.status_code == 200

    fetched = get.json()
    # The JSON value must round-trip as a value, not as a string.
    assert fetched["data"] == value
    assert fetched["updated_at"] >= body["updated_at"]


def test_put_userdata_accepts_non_object_json(http_client, test_session):
    # Raw JSON text: httpx treats `json=None` as "no body", so `null` is sent
    # explicitly as content.
    cases = [
        ("[1, 2, 3]", [1, 2, 3]),
        ('"hello"', "hello"),
        ("42", 42),
        ("true", True),
        ("null", None),
    ]

    for payload, expected in cases:
        put = http_client.put(
            USERDATA_URL,
            content=payload,
            headers={**_auth(test_session), "Content-Type": "application/json"},
        )
        assert put.status_code == 200, (payload, put.text)

        get = http_client.get(USERDATA_URL, headers=_auth(test_session))
        assert get.status_code == 200
        assert get.json()["data"] == expected


def test_put_userdata_replaces_previous(http_client, test_session):
    http_client.put(USERDATA_URL, json={"v": 1}, headers=_auth(test_session))
    first = http_client.get(USERDATA_URL, headers=_auth(test_session)).json()

    http_client.put(USERDATA_URL, json={"v": 2}, headers=_auth(test_session))
    second = http_client.get(USERDATA_URL, headers=_auth(test_session)).json()

    assert second["data"] == {"v": 2}
    assert second["updated_at"] >= first["updated_at"]


# ---------------------------------------------------------------------------
# Isolation: each user has their own blob
# ---------------------------------------------------------------------------


def test_userdata_is_per_user(http_client, test_session):
    other = system_create_user(http_client, username="userdata_other")
    other_token, _ = system_login(http_client, "userdata_other")
    other_headers = {"Authorization": f"Bearer {other_token}"}

    http_client.put(USERDATA_URL, json={"owner": "me"}, headers=_auth(test_session))

    response = http_client.get(USERDATA_URL, headers=other_headers)

    assert response.status_code == 200
    assert response.json() == {"data": None, "updated_at": None}


# ---------------------------------------------------------------------------
# Soft-delete clears the row
# ---------------------------------------------------------------------------


def test_soft_delete_removes_userdata(
    db_conn, http_client, test_session, test_user, system_headers
):
    value = {"to": "be cleared"}
    http_client.put(USERDATA_URL, json=value, headers=_auth(test_session))

    with db_conn.cursor() as cur:
        cur.execute("SELECT data FROM app.userdata WHERE user_id = %s", (test_user.id,))
        assert cur.fetchone() is not None

    response = http_client.delete(
        f"/api/system/users/{test_user.id}", headers=system_headers
    )
    assert response.status_code == 204

    with db_conn.cursor() as cur:
        cur.execute("SELECT data FROM app.userdata WHERE user_id = %s", (test_user.id,))
        assert cur.fetchone() is None
