import hashlib
import importlib.util
import json
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


def test_import_preserves_dump_message_updated_at():
    """An imported message must not look freshly changed to `/messages/sync`."""

    class Cursor:
        rowcount = 0

        def __init__(self):
            self.queries = []

        def execute(self, query, *_):
            self.queries.append(query)

        def fetchall(self):
            return []

        def fetchone(self):
            return (0,)

    cur = Cursor()
    counters = {
        "messages_inserted": 0,
        "messages_webhook": 0,
        "messages_pinned": 0,
        "embeds_inserted": 0,
        "replies_linked": 0,
        "replies_dropped": 0,
    }

    importguild.flush_messages(cur, counters)

    insert = next(
        query for query in cur.queries if "INSERT INTO app.messages" in query
    )
    assert "updated_at" in insert
    assert "COALESCE(i.edited_at, i.created_at)" in insert


def test_reaction_emoji_canonicalized_to_fully_qualified():
    canonical = importguild.load_emoji_canonical()

    # Discord returns the emoji as the client sent it; the API stores and looks
    # up the canonical form, so the importer must write the same one.
    assert canonical["\u2764"] == "\u2764\ufe0f"
    assert canonical["\u00a9"] == "\u00a9\ufe0f"
    assert canonical["1\u20e3"] == "1\ufe0f\u20e3"

    # A fully-qualified sequence is already canonical, and a lone regional
    # indicator has no RGI form at all: neither is rewritten.
    assert "\U0001f44d" not in canonical
    assert "\U0001f1f5" not in canonical

    rows = importguild.stage_message_reactions(
        {"reactions": [{"emoji": "\u2764", "users": [1]}, {"emoji": "\U0001f1f5", "users": [2]}]},
        5,
        frozenset(),
        {"reactions_skipped_empty": 0, "reactions_skipped_foreign": 0},
        canonical,
    )

    assert rows == [(5, 1, 0, None, "\u2764\ufe0f"), (5, 2, 0, None, "\U0001f1f5")]


def test_iter_downloads_submits_only_a_bounded_window():
    from concurrent.futures import ThreadPoolExecutor

    submitted = []

    def fetch(entry):
        submitted.append(entry)
        return entry, b"", None

    window = 3

    with ThreadPoolExecutor(max_workers=2) as pool:
        downloads = importguild.iter_downloads(pool, fetch, range(100), window)

        for consumed in range(1, 21):
            entry, data, error = next(downloads)
            assert data == b""
            assert error is None
            # A completed download is never buffered beyond the window.
            assert consumed <= len(submitted) <= consumed + window

        downloads.close()

    assert len(submitted) < 100


def test_process_attachments_reuses_existing_file_without_download(monkeypatch):
    import time

    downloads = []
    monkeypatch.setattr(
        importguild, "download_bytes", lambda url: downloads.append(url) or b"bytes"
    )

    class Cursor:
        def __init__(self):
            self.rowcount = 0
            self._rows = []
            self.inserts = []

        def execute(self, query, params=None):
            if query.startswith("SELECT message_id, position"):
                self._rows = []
            elif query.startswith("SELECT id, content_type FROM app.files"):
                self._rows = [(55, "image/png")]
            elif query.startswith("SELECT content"):
                self._rows = [("hello",)]
            elif query.startswith("INSERT INTO app.message_attachments"):
                self._rows = []
                self.rowcount = 1
                self.inserts.append(params)
            else:
                self._rows = []
                self.rowcount = 1

        def fetchall(self):
            return self._rows

        def fetchone(self):
            return self._rows[0] if self._rows else None

    class Connection:
        def __init__(self):
            self.commits = 0

        def commit(self):
            self.commits += 1

    expires = format(int(time.time()) + 3600, "x")
    attachment = {
        "id": 55,
        "url": f"https://cdn.discordapp.com/attachments/1/55/a.png?ex={expires}",
        "filename": "a.png",
        "size": 10,
    }

    cur = Cursor()
    conn = Connection()
    counters = {
        "attachments_reused": 0,
        "attachments_linked": 0,
        "attachments_skipped_existing": 0,
        "attachments_skipped_host": 0,
        "attachments_skipped_download": 0,
        "attachments_skipped_expired": 0,
    }

    importguild.process_attachments(
        conn, cur, None, 1, [(10, 0, attachment)], counters
    )

    assert downloads == []
    assert counters["attachments_reused"] == 1
    assert cur.inserts == [(10, 55, 0, 10, 55, 10, 0, 55)]
    assert conn.commits >= 1


def test_previous_report_state_keeps_tokens_and_valid_markers(tmp_path):
    path = tmp_path / "report.json"
    path.write_text(
        json.dumps(
            {
                "webhook_tokens": {"7": "token", "8": 5},
                "completed_channels": {
                    "1": {"size": 10, "mtime": 20, "attachments": True},
                    "2": {"size": "10", "mtime": 20},
                },
            }
        ),
        encoding="utf-8",
    )

    previous = importguild.load_previous_report(str(path))

    assert importguild.previous_webhook_tokens(previous) == {"7": "token"}
    assert importguild.previous_completed_channels(previous) == {
        "1": {
            "size": 10,
            "mtime": 20,
            "attachments": True,
            "attachments_skipped": 0,
        }
    }


def test_load_previous_report_tolerates_missing_or_broken_file(tmp_path):
    assert importguild.load_previous_report(str(tmp_path / "missing.json")) == {}

    broken = tmp_path / "broken.json"
    broken.write_text("{not json", encoding="utf-8")

    assert importguild.load_previous_report(str(broken)) == {}


def test_import_message_file_streams_bytes_and_reports_progress(tmp_path):
    message = {
        "id": 501,
        "channel_id": 1,
        "author_id": 7,
        "author_name": "alice",
        "content": "hello",
        "created_at": "2024-01-01T00:00:00+00:00",
        "mentions": [],
        "attachments": [],
        "embeds": [],
        "reactions": [],
    }
    path = tmp_path / "1.jsonl"
    path.write_bytes(
        json.dumps(message).encode("utf-8")
        + b"\n"
        + b'{"id": 502, "content": "\xff"}\n'
    )

    class Copy:
        def __init__(self):
            self.rows = []

        def __enter__(self):
            return self

        def __exit__(self, *_exc):
            return False

        def write_row(self, row):
            self.rows.append(row)

    class Cursor:
        def __init__(self):
            self.copies = []

        def copy(self, sql):
            copy = Copy()
            self.copies.append((sql, copy))
            return copy

        def execute(self, *_args):
            return None

    cur = Cursor()
    counters = {
        "malformed_lines": [],
        "legacy_mentions_normalized": 0,
        "message_links_rewritten": 0,
        "gif_embeds_replaced": 0,
        "gif_links_unresolved": 0,
        "messages_skipped_empty": 0,
        "embeds_skipped_too_many": 0,
        "reactions_skipped_empty": 0,
        "reactions_skipped_foreign": 0,
    }
    progress = []

    written, attachments = importguild.import_message_file(
        cur,
        100,
        1,
        str(path),
        importguild.UserCache(),
        set(),
        {7},
        set(),
        set(),
        {},
        importguild.Usernames(set()),
        set(),
        10,
        counters,
        progress=lambda count, done: progress.append((count, done)),
    )

    assert written == 1
    assert attachments == []
    assert counters["malformed_lines"] == [f"{path}:2"]
    assert progress[-1] == (1, path.stat().st_size)
    rows = cur.copies[0][1].rows
    assert len(rows) == 1
    assert rows[0][0] == 501
    assert rows[0][4] == "hello"


def test_import_webhooks_reports_only_lost_generated_tokens():
    class Cursor:
        rowcount = 0

        def execute(self, *_args):
            self.rowcount = 0

    webhook_dump = {
        3000: {"token": "from-dump", "channel_id": 2001, "name": "incoming"},
        3001: {"token": None, "channel_id": 2001, "name": "follower"},
    }
    counters = {
        "webhooks_imported": 0,
        "webhooks_skipped_channel": 0,
        "webhook_tokens": {},
        "webhook_tokens_unknown": [],
    }

    known = importguild.import_webhooks(
        Cursor(), 999, webhook_dump, {2001}, counters
    )

    # Both rows already exist from the interrupted run. Only the webhook whose
    # token was generated (not taken from the dump) has an unrecoverable
    # plaintext token.
    assert known == {3000, 3001}
    assert counters["webhook_tokens_unknown"] == ["3001"]
    assert counters["webhook_tokens"] == {}

    counters["webhook_tokens_unknown"] = []
    counters["webhook_tokens"] = {"3001": "recorded"}

    importguild.import_webhooks(Cursor(), 999, webhook_dump, {2001}, counters)

    assert counters["webhook_tokens_unknown"] == []


def test_flush_messages_returns_ids_for_incremental_import():
    class Cursor:
        rowcount = 0

        def __init__(self):
            self.queries = []

        def execute(self, query, *_args):
            self.queries.append(query)
            self.rowcount = 0

        def fetchall(self):
            return [(501, None), (502, 3000)]

        def fetchone(self):
            return (0,)

    counters = {
        "messages_inserted": 0,
        "messages_webhook": 0,
        "messages_pinned": 0,
        "embeds_inserted": 0,
        "replies_linked": 0,
        "replies_dropped": 0,
    }

    ids = importguild.flush_messages(Cursor(), counters, return_ids=True)

    assert ids == {501, 502}
    assert counters["messages_inserted"] == 2
    assert counters["messages_webhook"] == 1


def test_process_attachments_incremental_skips_old_messages(monkeypatch):
    import time

    downloads = []
    monkeypatch.setattr(
        importguild, "download_bytes", lambda url: downloads.append(url) or b"bytes"
    )

    class Cursor:
        def __init__(self):
            self.rowcount = 0
            self._rows = []

        def execute(self, query, params=None):
            if query.startswith("SELECT message_id, position"):
                self._rows = []
            elif query.startswith("SELECT id, content_type FROM app.files"):
                self._rows = []
            elif query.startswith("SELECT content"):
                self._rows = [("hello",)]
            else:
                self._rows = []
                self.rowcount = 1

        def fetchall(self):
            return self._rows

        def fetchone(self):
            return self._rows[0] if self._rows else None

    class Connection:
        def __init__(self):
            self.commits = 0

        def commit(self):
            self.commits += 1

    class S3:
        def available(self):
            return True

        def put(self, *_args, **_kwargs):
            return True

    expires = format(int(time.time()) + 3600, "x")

    def attachment(att_id):
        return {
            "id": att_id,
            "url": f"https://cdn.discordapp.com/attachments/1/{att_id}/a.png?ex={expires}",
            "filename": "a.png",
            "size": 10,
        }

    counters = {
        "warnings": [],
        "attachments_uploaded": 0,
        "attachments_linked": 0,
        "attachments_reused": 0,
        "attachments_skipped_incremental": 0,
        "attachments_skipped_existing": 0,
        "attachments_skipped_host": 0,
        "attachments_skipped_download": 0,
        "attachments_skipped_expired": 0,
        "attachment_bytes_uploaded": 0,
        "s3_puts": 0,
    }

    cur = Cursor()
    conn = Connection()

    importguild.process_attachments(
        conn,
        cur,
        S3(),
        1,
        [(10, 0, attachment(100)), (11, 0, attachment(101))],
        counters,
        message_filter={11},
    )

    # Only the attachment of the newly inserted message is downloaded; the old
    # message's never-linked attachment is reported, not retried.
    assert len(downloads) == 1
    assert "101" in downloads[0]
    assert counters["attachments_skipped_incremental"] == 1
    assert counters["attachments_linked"] == 1
    assert any("--refresh-messages" in warning for warning in counters["warnings"])
