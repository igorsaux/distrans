def test_terms_ok(http_client):
    response = http_client.get("/api/terms")

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/markdown")

    body = response.text

    assert body.startswith("# Terms of Service")
    assert "Version 1.0" in body
    assert "Last updated" in body


def test_terms_extra_path_not_found(http_client):
    response = http_client.get("/api/terms/extra")

    assert response.status_code == 404


def test_terms_wrong_method(http_client):
    response = http_client.post("/api/terms", json={})

    assert response.status_code == 405
    assert response.headers["Allow"] == "GET"
