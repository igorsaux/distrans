# Tests for the push subscription endpoints:
#   GET    /api/users/@me/push-subscriptions
#   POST   /api/users/@me/push-subscriptions
#   DELETE /api/users/@me/push-subscriptions/{subscription_id}
#
# List:
#   R1 - user must be logged (401)
#   R2 - array of {id, endpoint, created_at}; secrets are never returned
# Create:
#   R1 - application/json (415), non-empty body (400)
#   R2 - user must be logged (401)
#   R3 - object with endpoint/p256dh/auth strings
#   R4 - endpoint http(s) within max_endpoint_bytes; p256dh 65 bytes; auth 16
#   R5 - per-user cap; at the cap re-posting an owned endpoint stays allowed,
#        taking over another account's endpoint is 400
#   R6 - endpoint is globally unique: 201 when the caller did not own it before
#        (new or takeover), 200 when the caller already owned it
# Delete:
#   R1 - user must be logged (401)
#   R2 - unknown/foreign id -> 404
#   R3 - 204 on success

import base64
import json
import sys
from pathlib import Path

from conftest import CONFIG, system_create_user, system_login

sys.path.insert(0, str(Path(__file__).resolve().parent))

from mock_push import ENDPOINT

MAX_SUBSCRIPTIONS = CONFIG["api"]["push"]["max_subscriptions_per_user"]
MAX_ENDPOINT_BYTES = CONFIG["api"]["push"]["max_endpoint_bytes"]

URL = "/api/users/@me/push-subscriptions"


def auth(session):
    return {"Authorization": f"Bearer {session.access_token}"}


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


P256DH = "BGsX0fLhLEJH-Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT-NC4v4af5uO5-tKfA-eFivOM1drMV7Oy7ZAaDe_UfU"  # P-256 generator
AUTH = b64(b"\x22" * 16)  # 16 bytes


def subscription(endpoint=None, p256dh=P256DH, auth=AUTH):
    return {
        "endpoint": endpoint or f"{ENDPOINT}/push/abc",
        "p256dh": p256dh,
        "auth": auth,
    }


def _login(http_client, username):
    class Session:
        pass

    access_token, _ = system_login(http_client, username)

    session = Session()
    session.access_token = access_token

    return session


# ---------------------------------------------------------------------------
# Auth (R1/R2)
# ---------------------------------------------------------------------------


def test_list_unauthorized(http_client):
    assert http_client.get(URL).status_code == 401


def test_create_unauthorized(http_client):
    assert http_client.post(URL, json=subscription()).status_code == 401


def test_delete_unauthorized(http_client):
    assert http_client.delete(f"{URL}/1").status_code == 401


# ---------------------------------------------------------------------------
# Create validation (R1, R3, R4)
# ---------------------------------------------------------------------------


def test_create_empty_body(http_client, test_session):
    assert http_client.post(URL, headers=auth(test_session)).status_code == 400


def test_create_bad_content_type(http_client, test_session):
    response = http_client.post(
        URL,
        content=json.dumps(subscription()),
        headers={**auth(test_session), "Content-Type": "text/plain"},
    )

    assert response.status_code == 415


def test_create_non_object(http_client, test_session):
    response = http_client.post(URL, headers=auth(test_session), json=[1, 2])

    assert response.status_code == 400
    assert response.json()["message"] == "Expected an object"


def test_create_missing_endpoint(http_client, test_session):
    payload = subscription()
    del payload["endpoint"]

    response = http_client.post(URL, headers=auth(test_session), json=payload)

    assert response.status_code == 400
    assert response.json()["message"] == "'endpoint' is not a string"


def test_create_bad_endpoint_scheme(http_client, test_session):
    response = http_client.post(
        URL,
        headers=auth(test_session),
        json=subscription(endpoint="ftp://example.com/x"),
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'endpoint' is invalid"


def test_create_endpoint_too_long(http_client, test_session):
    endpoint = f"{ENDPOINT}/" + "a" * MAX_ENDPOINT_BYTES

    response = http_client.post(
        URL, headers=auth(test_session), json=subscription(endpoint=endpoint)
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'endpoint' is invalid"


def test_create_bad_p256dh(http_client, test_session):
    response = http_client.post(
        URL,
        headers=auth(test_session),
        json=subscription(p256dh=b64(b"\x01" * 10)),
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'p256dh' is invalid"


def test_create_p256dh_not_on_curve(http_client, test_session):
    # 65 bytes, but not a valid point on P-256.
    response = http_client.post(
        URL,
        headers=auth(test_session),
        json=subscription(p256dh=b64(b"\x04" + b"\x11" * 64)),
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'p256dh' is invalid"


def test_create_bad_auth(http_client, test_session):
    response = http_client.post(
        URL,
        headers=auth(test_session),
        json=subscription(auth=b64(b"\x01" * 5)),
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'auth' is invalid"


# ---------------------------------------------------------------------------
# Create / list / delete round-trip (R2, R6, R3)
# ---------------------------------------------------------------------------


def test_create_list_delete(http_client, test_session, test_user, db_conn):
    created = http_client.post(
        URL, headers=auth(test_session), json=subscription()
    )

    assert created.status_code == 201

    body = created.json()
    assert body["endpoint"] == f"{ENDPOINT}/push/abc"
    assert isinstance(body["created_at"], int)

    listed = http_client.get(URL, headers=auth(test_session))

    assert listed.status_code == 200
    assert listed.json() == [body]

    # Secrets never leave the server.
    assert "p256dh" not in listed.text
    assert "auth" not in listed.text

    subscription_id = body["id"]

    deleted = http_client.delete(
        f"{URL}/{subscription_id}", headers=auth(test_session)
    )

    assert deleted.status_code == 204
    assert http_client.get(URL, headers=auth(test_session)).json() == []

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT count(*) AS n FROM app.push_subscriptions WHERE user_id = %s",
            (test_user.id,),
        )
        assert cur.fetchone()["n"] == 0


def test_create_is_idempotent_per_endpoint(http_client, test_session):
    first = http_client.post(URL, headers=auth(test_session), json=subscription())

    assert first.status_code == 201

    second = http_client.post(URL, headers=auth(test_session), json=subscription())

    assert second.status_code == 200
    assert second.json()["id"] == first.json()["id"]

    listed = http_client.get(URL, headers=auth(test_session)).json()

    assert len(listed) == 1


def test_subscriptions_are_per_user(http_client, test_session):
    http_client.post(URL, headers=auth(test_session), json=subscription())

    system_create_user(http_client, username="push_other")
    other = _login(http_client, "push_other")

    assert http_client.get(URL, headers=auth(other)).json() == []


def test_endpoint_transfers_between_accounts(http_client, db_conn):
    # A browser endpoint belongs to exactly one account: registering it from
    # another account takes it over (moves the row) instead of creating a second
    # row, so the previous owner keeps nothing.
    owner = system_create_user(http_client, username="push_owner")
    owner_session = _login(http_client, "push_owner")

    endpoint = f"{ENDPOINT}/push/shared-device"
    first = http_client.post(
        URL, headers=auth(owner_session), json=subscription(endpoint=endpoint)
    )

    assert first.status_code == 201

    taker = system_create_user(http_client, username="push_taker")
    taker_session = _login(http_client, "push_taker")

    takeover = http_client.post(
        URL, headers=auth(taker_session), json=subscription(endpoint=endpoint)
    )

    # The caller did not own it before, so a takeover is a 201.
    assert takeover.status_code == 201

    # The old owner no longer sees it; the new owner does.
    assert http_client.get(URL, headers=auth(owner_session)).json() == []

    listed = http_client.get(URL, headers=auth(taker_session)).json()

    assert len(listed) == 1
    assert listed[0]["endpoint"] == endpoint

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT count(*) AS n, min(user_id) AS owner FROM app.push_subscriptions"
            " WHERE endpoint = %s",
            (endpoint,),
        )
        row = cur.fetchone()

    assert row["n"] == 1
    assert int(row["owner"]) == int(taker["id"])

    # Re-posting an endpoint the caller now owns stays idempotent (200).
    again = http_client.post(
        URL, headers=auth(taker_session), json=subscription(endpoint=endpoint)
    )

    assert again.status_code == 200

    # The previous owner (whose own endpoint was taken) did not lose anything
    # else and cannot delete the taker's subscription.
    assert (
        http_client.delete(
            f"{URL}/{listed[0]['id']}", headers=auth(owner_session)
        ).status_code
        == 404
    )


def test_endpoint_takeover_rejected_at_cap(http_client):
    # An endpoint owned by another account is not "existing" for the caller, so
    # at the cap the caller cannot take it over.
    other = system_create_user(http_client, username="push_cap_owner")
    other_session = _login(http_client, "push_cap_owner")

    shared = f"{ENDPOINT}/push/cap-shared"
    assert (
        http_client.post(
            URL, headers=auth(other_session), json=subscription(endpoint=shared)
        ).status_code
        == 201
    )

    taker = system_create_user(http_client, username="push_cap_taker")
    taker_session = _login(http_client, "push_cap_taker")

    for i in range(MAX_SUBSCRIPTIONS):
        response = http_client.post(
            URL,
            headers=auth(taker_session),
            json=subscription(endpoint=f"{ENDPOINT}/push/cap/{i}"),
        )

        assert response.status_code == 201

    over = http_client.post(
        URL, headers=auth(taker_session), json=subscription(endpoint=shared)
    )

    assert over.status_code == 400
    assert over.json()["message"] == "'subscriptions' is too many"

    # Re-posting an endpoint the caller already owns stays allowed at the cap.
    own = http_client.post(
        URL,
        headers=auth(taker_session),
        json=subscription(endpoint=f"{ENDPOINT}/push/cap/0"),
    )

    assert own.status_code == 200

    # The original owner kept the endpoint.
    assert len(http_client.get(URL, headers=auth(other_session)).json()) == 1


def test_delete_unknown_subscription(http_client, test_session):
    response = http_client.delete(f"{URL}/999999", headers=auth(test_session))

    assert response.status_code == 404
    assert response.json()["message"] == "Subscription not found"


def test_delete_foreign_subscription(http_client, test_session):
    created = http_client.post(URL, headers=auth(test_session), json=subscription())

    assert created.status_code == 201

    system_create_user(http_client, username="push_thief")
    thief = _login(http_client, "push_thief")

    response = http_client.delete(
        f"{URL}/{created.json()['id']}", headers=auth(thief)
    )

    assert response.status_code == 404


def test_delete_malformed_id(http_client, test_session):
    response = http_client.delete(f"{URL}/not-a-number", headers=auth(test_session))

    assert response.status_code == 400


def test_wrong_method(http_client, test_session):
    response = http_client.put(URL, headers=auth(test_session), json={})

    assert response.status_code == 405
    assert "GET" in response.headers["allow"]


# ---------------------------------------------------------------------------
# Cap (R5)
# ---------------------------------------------------------------------------


def test_create_enforces_per_user_cap(http_client, test_session):
    for i in range(MAX_SUBSCRIPTIONS):
        response = http_client.post(
            URL,
            headers=auth(test_session),
            json=subscription(endpoint=f"{ENDPOINT}/push/{i}"),
        )

        assert response.status_code == 201

    over = http_client.post(
        URL,
        headers=auth(test_session),
        json=subscription(endpoint=f"{ENDPOINT}/push/over"),
    )

    assert over.status_code == 400
    assert over.json()["message"] == "'subscriptions' is too many"

    # Re-posting an endpoint that already exists stays allowed at the cap.
    again = http_client.post(
        URL,
        headers=auth(test_session),
        json=subscription(endpoint=f"{ENDPOINT}/push/0"),
    )

    assert again.status_code == 200


# ---------------------------------------------------------------------------
# Lifecycle: subscriptions follow the credential / the account
# ---------------------------------------------------------------------------


class _Session:
    def __init__(self, access_token):
        self.access_token = access_token


def _subscribe(http_client, session, endpoint):
    created = http_client.post(
        URL, headers=auth(session), json=subscription(endpoint=endpoint)
    )

    assert created.status_code == 201


def _count_subscriptions(db_conn, user_id):
    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT count(*) AS n FROM app.push_subscriptions WHERE user_id = %s",
            (int(user_id),),
        )
        return cur.fetchone()["n"]


def test_password_change_with_cookie_removes_subscriptions(http_client, db_conn):
    user = system_create_user(http_client, username="push_pw_cookie")
    access_token, refresh_token = system_login(http_client, "push_pw_cookie")
    session = _Session(access_token)

    _subscribe(http_client, session, f"{ENDPOINT}/push/pw-cookie")

    changed = http_client.patch(
        "/api/users/@me",
        headers=auth(session),
        cookies={"refresh_token": refresh_token},
        json={"password": "new-pass-123", "current_password": "12345678"},
    )

    assert changed.status_code == 204

    # The credential changed, so the subscription is gone even though the
    # current session survives.
    assert http_client.get(URL, headers=auth(session)).json() == []
    assert _count_subscriptions(db_conn, user["id"]) == 0


def test_password_change_without_cookie_removes_subscriptions(http_client, db_conn):
    user = system_create_user(http_client, username="push_pw_nocookie")
    access_token, _ = system_login(http_client, "push_pw_nocookie")
    session = _Session(access_token)

    _subscribe(http_client, session, f"{ENDPOINT}/push/pw-nocookie")

    changed = http_client.patch(
        "/api/users/@me",
        headers=auth(session),
        json={"password": "new-pass-123", "current_password": "12345678"},
    )

    assert changed.status_code == 204
    assert http_client.get(URL, headers=auth(session)).json() == []
    assert _count_subscriptions(db_conn, user["id"]) == 0


def test_system_password_reset_removes_subscriptions(
    http_client, db_conn, system_headers
):
    user = system_create_user(http_client, username="push_pw_system")
    access_token, _ = system_login(http_client, "push_pw_system")
    session = _Session(access_token)

    _subscribe(http_client, session, f"{ENDPOINT}/push/pw-system")

    reset = http_client.patch(
        f"/api/system/users/{user['id']}",
        headers=system_headers,
        json={"password": "new-pass-123"},
    )

    assert reset.status_code == 204
    assert http_client.get(URL, headers=auth(session)).json() == []
    assert _count_subscriptions(db_conn, user["id"]) == 0


def test_delete_user_clears_push_subscriptions(
    http_client, db_conn, system_headers
):
    user = system_create_user(http_client, username="push_deleted")
    access_token, _ = system_login(http_client, "push_deleted")
    session = _Session(access_token)

    _subscribe(http_client, session, f"{ENDPOINT}/push/deleted")

    assert _count_subscriptions(db_conn, user["id"]) == 1

    deleted = http_client.delete(
        f"/api/system/users/{user['id']}", headers=system_headers
    )

    assert deleted.status_code == 204
    assert _count_subscriptions(db_conn, user["id"]) == 0
