def test_privacy_ok(http_client):
    response = http_client.get("/api/privacy")

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/markdown")

    body = response.text

    assert body.startswith("# Privacy Policy")
    assert "Last updated" in body
    assert "Argon2" in body
    assert "refresh_token" in body


def test_privacy_extra_path_not_found(http_client):
    response = http_client.get("/api/privacy/extra")

    assert response.status_code == 404


def test_privacy_wrong_method(http_client):
    response = http_client.post("/api/privacy", json={})

    assert response.status_code == 405
    assert response.headers["Allow"] == "GET"
