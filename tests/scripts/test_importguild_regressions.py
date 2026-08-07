import hashlib
import importlib.util
import sys
from pathlib import Path

import pytest


SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "importguild.py"
sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("importguild_regressions", SCRIPT)
importguild = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(importguild)


def report():
    return {
        "warnings": [],
        "attachments_uploaded": 0,
        "attachment_bytes_uploaded": 0,
        "attachments_linked": 0,
        "s3_puts": 0,
        "deleted_users_anonymized": 0,
    }


def test_attachment_token_serialization_matches_media_and_label_rules():
    assert importguild.serialize_attachment_token(
        12, "photo](one)\n.png\x00", "image/png"
    ) == "![photo\\]\\(one\\) .png](attachment://12)"
    assert importguild.serialize_attachment_token(
        13, "clip.mp4", "video/mp4"
    ) == "[clip.mp4](attachment://13)"
    assert importguild.serialize_attachment_token(
        14, "unknown.bin", "image/avif"
    ) == "[unknown.bin](attachment://14)"


def test_append_tokens_keeps_content_and_is_idempotent():
    class Cursor:
        content = "original text"

        def execute(self, query, params):
            if query.startswith("SELECT content"):
                self.row = (self.content,)
            elif query.startswith("UPDATE app.messages"):
                self.content = params[0]

        def fetchone(self):
            return self.row

    cur = Cursor()
    refs = [(4, 8, "a.png", "image/png"), (4, 8, "duplicate.png", "image/png")]
    importguild.append_attachment_tokens(cur, refs)
    assert cur.content == "original text\n\n![a.png](attachment://8)\n![duplicate.png](attachment://8)"
    importguild.append_attachment_tokens(cur, refs)
    assert cur.content.count("attachment://8") == 2


def test_anonymize_only_touches_new_deleted_placeholders():
    class Cursor:
        rowcount = 1

        def execute(self, query, params):
            self.ids = set(params[0])

    cur = Cursor()
    counters = report()
    importguild.anonymize_deleted_users(cur, {100, 200}, {100}, counters)
    assert cur.ids == {100}
    assert counters["deleted_users_anonymized"] == 1


def test_deleted_author_marker_does_not_anonymize_preexisting_account():
    class Cursor:
        def execute(self, query, params):
            pytest.fail("must not mutate an account that was not inserted here")

    counters = report()
    importguild.anonymize_deleted_users(Cursor(), {200}, set(), counters)
    assert counters["deleted_users_anonymized"] == 0


def test_hash_match_restores_s3_and_uses_existing_file_id():
    body = b"same bytes"
    digest = hashlib.sha256(body).hexdigest()

    class Cursor:
        rowcount = 0

        def execute(self, query, params):
            self.query, self.params = query, params

        def fetchone(self):
            return (900, "image/png")

    class S3:
        def __init__(self):
            self.puts = []

        def available(self):
            return True

        def put(self, key, data, content_type):
            self.puts.append((key, data, content_type))

    cur, s3, counters = Cursor(), S3(), report()
    assert importguild.store_attachment(
        cur, s3, 901, body, {"filename": "different.png"}, counters
    ) == (900, "image/png")
    assert s3.puts == [(f"files/{digest}", body, "image/png")]
    assert counters["s3_puts"] == 1


def test_mismatched_existing_id_hash_is_not_reused_or_uploaded():
    class Cursor:
        rowcount = 0

        def execute(self, query, params):
            self.query = query

        def fetchone(self):
            return None

    class S3:
        def available(self):
            return True

        def put(self, *args):
            pytest.fail("must not upload under an id with a different hash")

    cur, counters = Cursor(), report()
    assert importguild.store_attachment(
        cur, S3(), 902, b"new bytes", {"filename": "x"}, counters
    ) is None
    assert "different bytes" in counters["warnings"][0]
