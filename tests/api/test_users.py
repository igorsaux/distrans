# R2 - user must be logged
def test_get_users_unauthorized(http_client):
    response = http_client.get("/api/users")

    assert response.status_code == 401


def test_get_users_unknown_parameter(http_client, test_session):
    response = http_client.get(
        "/api/users",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
        },
        params={
            "foobar": 2,
        },
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Unknown parameter"


# R1 - limit > 0 and limit <= 100
def test_get_users_limit_zero(http_client, test_session):
    response = http_client.get(
        "/api/users",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
        },
        params={
            "limit": 0,
        },
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Bad 'limit' parameter"


# R1
def test_get_users_limit_too_big(http_client, test_session):
    response = http_client.get(
        "/api/users",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
        },
        params={
            "limit": 101,
        },
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Bad 'limit' parameter"


# R1
def test_get_users_bad_limit(http_client, test_session):
    response = http_client.get(
        "/api/users",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
        },
        params={
            "limit": "foo",
        },
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Bad 'limit' parameter"


def test_get_users_bad_after(http_client, test_session):
    response = http_client.get(
        "/api/users",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
        },
        params={
            "after": "foo",
        },
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Bad 'after' parameter"


def test_get_users_only_test_user(http_client, test_session, test_user):
    body = get_users(http_client, test_session)

    assert len(body) == 1

    user = body[0]
    assert user["id"] == test_user.id
    assert user["username"] == test_user.username
    assert user["display_name"] is None
    assert user["avatar_hash"] is None


def create_users(http_client, system_headers, usernames):
    ids = []

    for username in usernames:
        response = http_client.post(
            "/api/system/users",
            json={"username": username, "password": "12345678"},
            headers=system_headers,
        )

        assert response.status_code == 201

        ids.append(response.json()["id"])

    return ids


def get_users_raw(http_client, test_session, **params):
    return http_client.get(
        "/api/users",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
        },
        params=params,
    )


def get_users(http_client, test_session, **params):
    response = get_users_raw(http_client, test_session, **params)

    assert response.status_code == 200

    return response.json()


def test_get_users(http_client, system_headers, test_session, test_user):
    created_ids = create_users(http_client, system_headers, ["alice", "bob", "carol"])

    body = get_users(http_client, test_session)

    assert len(body) == 4

    ids = [user["id"] for user in body]
    assert ids == sorted(ids, key=int)

    by_id = {user["id"]: user for user in body}
    assert set(by_id.keys()) == set(created_ids) | {test_user.id}
    assert by_id[test_user.id]["username"] == test_user.username


def test_get_users_limit(http_client, system_headers, test_session, test_user):
    create_users(http_client, system_headers, ["alice", "bob", "carol"])

    body = get_users(http_client, test_session, limit=2)
    all_users = get_users(http_client, test_session, limit=100)

    assert len(body) == 2
    assert [user["id"] for user in body] == [user["id"] for user in all_users][:2]


def test_get_users_default_limit(http_client, system_headers, test_session):
    create_users(http_client, system_headers, [f"user{i:02}" for i in range(51)])

    body = get_users(http_client, test_session)

    assert len(body) == 50


def test_get_users_after(http_client, system_headers, test_session, test_user):
    create_users(http_client, system_headers, ["alice", "bob", "carol"])

    first_page = get_users(http_client, test_session, limit=2)
    assert len(first_page) == 2

    second_page = get_users(
        http_client, test_session, limit=2, after=first_page[-1]["id"]
    )

    all_users = get_users(http_client, test_session, limit=100)

    assert len(second_page) == 2
    assert [user["id"] for user in second_page] == [user["id"] for user in all_users][
        2:4
    ]


def test_get_users_after_last_user(http_client, system_headers, test_session):
    create_users(http_client, system_headers, ["alice", "bob"])

    all_users = get_users(http_client, test_session, limit=100)
    assert len(all_users) == 3

    next_page = get_users(http_client, test_session, after=all_users[-1]["id"])

    assert len(next_page) == 0


def test_get_users_after_small_id(http_client, system_headers, test_session):
    create_users(http_client, system_headers, ["alice", "bob"])

    # IDs are time-based snowflakes, so any small id sorts before all of them.
    body = get_users(http_client, test_session, after=1)

    assert len(body) == 3
