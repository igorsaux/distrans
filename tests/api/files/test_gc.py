# Tests for the files garbage collector (src/services/files.zig, `Gc`).
#
# The GC ticks from the server main loop. config.tests.json uses
# interval_s = 1 and a long grace_s, so a test backdates a file's created_at
# past the grace window and then polls until the row and the S3 object are gone.
#
# Covered:
#   - an unreferenced file past the grace window is collected (row + object)
#   - a file referenced by a message survives
#   - a fresh file survives (grace guard)
#   - a file within the grace window survives
#   - the collection is idempotent across passes

import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "users"))

from conftest import CONFIG

import webp

HASH_RE = re.compile(r"^[0-9a-f]{64}$")

GRACE_S = CONFIG["files"]["gc"]["grace_s"]

# Long enough for at least one GC pass at interval_s = 1, short enough to keep
# the suite fast.
POLL_TIMEOUT_S = 15.0
POLL_INTERVAL_S = 0.2


def auth_headers(session):
    return {"Authorization": f"Bearer {session.access_token}"}


def upload(http_client, session, name="gc.webp"):
    response = http_client.post(
        "/api/files",
        content=webp.make_webp(),
        headers={**auth_headers(session), "Content-Type": "image/webp"},
        params={"name": name},
    )

    assert response.status_code in (200, 201), response.content

    return response.json()


def file_row(db_conn, file_id):
    with db_conn.cursor() as cur:
        cur.execute("SELECT id, hash FROM app.files WHERE id = %s", (int(file_id),))

        return cur.fetchone()


def backdate(db_conn, file_id, seconds):
    with db_conn.cursor() as cur:
        cur.execute(
            "UPDATE app.files SET created_at = now() - make_interval(secs => %s)"
            " WHERE id = %s",
            (seconds, int(file_id)),
        )


def wait_until(predicate, timeout=POLL_TIMEOUT_S):
    deadline = time.monotonic() + timeout

    while time.monotonic() < deadline:
        if predicate():
            return True

        time.sleep(POLL_INTERVAL_S)

    return predicate()


def test_gc_collects_unreferenced_file(db_conn, http_client, test_session, s3_mock):
    body = upload(http_client, test_session)
    file_id, hash_value = body["id"], body["hash"]

    assert HASH_RE.match(hash_value)
    assert s3_mock.get(f"files/{hash_value}") is not None

    # Well past the grace window (grace_s = 3600 in the test config).
    backdate(db_conn, file_id, GRACE_S * 2)

    collected = wait_until(
        lambda: file_row(db_conn, file_id) is None
        and s3_mock.get(f"files/{hash_value}") is None
    )

    assert collected, "file was not collected"

    # The delete reached the mock as a DELETE on the object key.
    assert ("DELETE", f"/files/{hash_value}") in s3_mock.requests


def test_gc_keeps_referenced_file(
    db_conn, http_client, test_channel, test_session, s3_mock
):
    body = upload(http_client, test_session, name="kept.webp")
    file_id, hash_value = body["id"], body["hash"]

    # Attach the file to a message so it is referenced (content is the source
    # of truth: a `attachment://<id>` reference in the body).
    response = http_client.post(
        f"/api/channels/{test_channel.id}/messages",
        headers=auth_headers(test_session),
        json={"content": f"keep me ![k](attachment://{file_id})"},
    )

    assert response.status_code == 201

    backdate(db_conn, file_id, GRACE_S * 2)

    # Give the GC several intervals; the row and object must remain.
    time.sleep(3.0)

    assert file_row(db_conn, file_id) is not None
    assert s3_mock.get(f"files/{hash_value}") is not None


def test_gc_keeps_fresh_file(db_conn, http_client, test_session, s3_mock):
    body = upload(http_client, test_session, name="fresh.webp")
    file_id, hash_value = body["id"], body["hash"]

    # No backdating: the default created_at is inside the grace window.
    time.sleep(2.5)

    assert file_row(db_conn, file_id) is not None
    assert s3_mock.get(f"files/{hash_value}") is not None


def test_gc_grace_window_respected(db_conn, http_client, test_session, s3_mock):
    body = upload(http_client, test_session, name="within-grace.webp")
    file_id, hash_value = body["id"], body["hash"]

    # Older than "now" but still inside the grace window.
    backdate(db_conn, file_id, GRACE_S // 2)

    time.sleep(2.5)

    assert file_row(db_conn, file_id) is not None
    assert s3_mock.get(f"files/{hash_value}") is not None


def test_gc_is_idempotent(db_conn, http_client, test_session, s3_mock):
    body = upload(http_client, test_session, name="idem.webp")
    file_id, hash_value = body["id"], body["hash"]

    backdate(db_conn, file_id, GRACE_S * 2)

    assert wait_until(lambda: file_row(db_conn, file_id) is None)

    # A second pass must not error on the already-gone object.
    time.sleep(2.0)

    deletes = [
        r for r in s3_mock.requests if r == ("DELETE", f"/files/{hash_value}")
    ]

    assert len(deletes) == 1
