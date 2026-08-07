def _create_user(http_client, system_headers, username, password="12345678", **extra):
    payload = {"username": username, "password": password}
    payload.update(extra)

    response = http_client.post(
        "/api/system/users", json=payload, headers=system_headers
    )

    assert response.status_code == 201

    return response.json()


# R1 - user must be logged
def test_get_user_unauthorized(http_client, test_user):
    response = http_client.get(f"/api/users/{test_user.id}")

    assert response.status_code == 401


# R2 - the user exists
def test_get_unknown_user(http_client, test_session):
    response = http_client.get(
        "/api/users/1",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
        },
    )

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "User not found"


# R2
def test_get_user(http_client, test_user, test_session):
    response = http_client.get(
        f"/api/users/{test_user.id}",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
        },
    )

    assert response.status_code == 200

    body = response.json()
    assert body["username"] == test_user.username


# R2
def test_get_user_with_display_name(http_client, system_headers, test_session):
    created = _create_user(
        http_client,
        system_headers,
        username="full_profile",
        display_name="Full Profile",
    )

    response = http_client.get(
        f"/api/users/{created['id']}",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
        },
    )

    assert response.status_code == 200

    body = response.json()
    assert body["username"] == "full_profile"
    assert body["display_name"] == "Full Profile"
    assert body["avatar_hash"] is None


# R2
def test_get_user_without_optional_fields(http_client, test_user, test_session):
    response = http_client.get(
        f"/api/users/{test_user.id}",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
        },
    )

    assert response.status_code == 200

    body = response.json()
    assert body["username"] == test_user.username
    assert body["display_name"] is None
    assert body["avatar_hash"] is None


def test_get_user_bad_id(http_client, test_session):
    response = http_client.get(
        "/api/users/not-a-number",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
        },
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Bad Request"
