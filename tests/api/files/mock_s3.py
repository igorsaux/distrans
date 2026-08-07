"""Minimal in-process S3 stand-in for the file upload tests.

The server under test PUTs objects to the ``files.s3.endpoint`` from
``config.tests.json`` (``http://127.0.0.1:9099``); this module runs a plain
HTTP server on that exact port and records what arrives. Signature headers are
ignored: the point is to assert that the bytes reach the object key.
"""

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

CONFIG_PATH = Path(__file__).resolve().parents[3] / "config.tests.json"

with CONFIG_PATH.open() as f:
    _CONFIG = json.load(f)

_ENDPOINT = _CONFIG["files"]["s3"]["endpoint"]
assert _ENDPOINT.startswith("http://127.0.0.1:"), (
    "tests require a loopback S3 endpoint in config.tests.json, got "
    f"{_ENDPOINT!r}"
)

HOST, PORT = "127.0.0.1", int(_ENDPOINT.rsplit(":", 1)[1])


class MockS3:
    def __init__(self):
        self.objects = {}
        self.content_types = {}
        self.cache_control = {}
        self.content_disposition = {}
        self.requests = []
        self._lock = threading.Lock()

    def reset(self):
        with self._lock:
            self.objects.clear()
            self.content_types.clear()
            self.cache_control.clear()
            self.content_disposition.clear()
            self.requests.clear()

    def put(self, key, body, content_type=None, cache_control=None, content_disposition=None):
        with self._lock:
            self.objects[key] = body
            self.content_types[key] = content_type
            self.cache_control[key] = cache_control
            self.content_disposition[key] = content_disposition

    def record(self, method, path):
        with self._lock:
            self.requests.append((method, path))

    def get(self, key):
        with self._lock:
            return self.objects.get(key)

    def get_content_type(self, key):
        with self._lock:
            return self.content_types.get(key)

    def get_cache_control(self, key):
        with self._lock:
            return self.cache_control.get(key)

    def get_content_disposition(self, key):
        with self._lock:
            return self.content_disposition.get(key)

    def delete(self, key):
        with self._lock:
            self.content_types.pop(key, None)
            self.cache_control.pop(key, None)
            self.content_disposition.pop(key, None)

            return self.objects.pop(key, None) is not None


mock_s3 = MockS3()


class _Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _key(self):
        return self.path.lstrip("/")

    def do_PUT(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)

        mock_s3.record("PUT", self.path)
        mock_s3.put(
            self._key(),
            body,
            self.headers.get("Content-Type"),
            self.headers.get("Cache-Control"),
            self.headers.get("Content-Disposition"),
        )

        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        body = mock_s3.get(self._key())

        if body is None:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_HEAD(self):
        body = mock_s3.get(self._key())

        self.send_response(200 if body is not None else 404)
        self.send_header("Content-Length", str(len(body)) if body else "0")
        self.end_headers()

    def do_DELETE(self):
        mock_s3.record("DELETE", self.path)
        existed = mock_s3.delete(self._key())

        self.send_response(204 if existed else 404)
        self.send_header("Content-Length", "0")
        self.end_headers()


_server = None
_thread = None


def start():
    global _server, _thread

    if _server is not None:
        return

    _server = ThreadingHTTPServer((HOST, PORT), _Handler)
    _thread = threading.Thread(target=_server.serve_forever, daemon=True)
    _thread.start()


def stop():
    global _server, _thread

    if _server is None:
        return

    _server.shutdown()
    _server.server_close()
    _server = None
    _thread = None
