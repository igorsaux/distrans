import hashlib
import importlib.util
import re
import sys
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "reissuewebhooktoken.py"
sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("reissuewebhooktoken", SCRIPT)
reissuewebhooktoken = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(reissuewebhooktoken)


class Cursor:
    def __init__(self, row):
        self.row = row
        self.query = None
        self.params = None

    def execute(self, query, params):
        self.query = query
        self.params = params

    def fetchone(self):
        return self.row


def test_reissue_token_stores_sha256_and_returns_metadata():
    cursor = Cursor((42, "hooks"))

    result = reissuewebhooktoken.reissue_token(cursor, "7")

    assert result is not None
    token, channel_id, name = result
    assert channel_id == 42
    assert name == "hooks"
    assert re.fullmatch(r"[A-Za-z0-9_-]{43}", token)
    assert cursor.params == (hashlib.sha256(token.encode("utf-8")).digest(), 7)
    assert "deleted_at IS NULL" in cursor.query
    assert "RETURNING channel_id, name" in cursor.query


def test_reissue_token_reports_missing_or_deleted_webhook():
    cursor = Cursor(None)

    assert reissuewebhooktoken.reissue_token(cursor, 9) is None
