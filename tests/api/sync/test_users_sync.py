# Changed-since user sync: `GET /api/users/sync`.
#
# Covers R1 (auth), R2 (`since` validation), the id-array / upsert contract,
# and soft-deleted users.

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from conftest import CONFIG, SYSTEM_HEADERS, system_create_user

MAX_LOOKBACK_S = CONFIG["api"]["sync"]["max_lookback_s"]


def _headers(token):
    return {"Authorization": f"Bearer {token}"}


def _since_too_old_ms():
    return int((time.time() - (MAX_LOOKBACK_S + 3600)) * 1000)


def _sync(http_client, token, since=None):
    params = {} if since is None else {"since": since}

    return http_client.get(
        "/api/users/sync", headers=_headers(token), params=params
    )


# R1
def test_users_sync_unauthorized(http_client):
    response = http_client.get("/api/users/sync")

    assert response.status_code == 401


def test_users_sync_unknown_parameter(http_client, test_session):
    response = http_client.get(
        "/api/users/sync",
        headers=_headers(test_session.access_token),
        params={"nope": 1},
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Unknown parameter"


# R2
def test_users_sync_invalid_since(http_client, test_session):
    response = _sync(http_client, test_session.access_token, since="nope")

    assert response.status_code == 400
    assert response.json()["message"] == "'since' is invalid"


# R2
def test_users_sync_too_old_since(http_client, test_session):
    response = _sync(
        http_client, test_session.access_token, since=_since_too_old_ms()
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'since' is too old"


def test_users_sync_shape(http_client, test_session):
    response = _sync(http_client, test_session.access_token)

    assert response.status_code == 200

    body = response.json()
    assert isinstance(body["updated_at"], int)
    assert set(body.keys()) == {"updated_at", "users"}
    assert test_session is not None


def test_users_sync_reports_changed_user(http_client, test_session):
    cursor = _sync(http_client, test_session.access_token).json()["updated_at"]

    time.sleep(0.05)

    user = system_create_user(http_client, username="freshuser")

    body = _sync(http_client, test_session.access_token, since=cursor).json()
    assert user["id"] in body["users"]

    # Advancing the cursor yields an empty delta.
    assert _sync(
        http_client, test_session.access_token, since=body["updated_at"]
    ).json()["users"] == []


def test_users_sync_reports_soft_deleted(http_client, test_session):
    user = system_create_user(http_client, username="doomeduser")

    cursor = _sync(http_client, test_session.access_token).json()["updated_at"]

    time.sleep(0.05)

    assert (
        http_client.delete(
            f"/api/system/users/{user['id']}", headers=SYSTEM_HEADERS
        ).status_code
        == 204
    )

    # A soft-deleted user stays present, so it is listed as changed.
    body = _sync(http_client, test_session.access_token, since=cursor).json()
    assert user["id"] in body["users"]
