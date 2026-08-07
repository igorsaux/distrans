"""Minimal in-process Web Push service stand-in for the notification tests.

The server under test POSTs encrypted Web Push messages to whatever endpoint a
subscription carries. The tests create subscriptions pointing at
``http://127.0.0.1:9098/...`` (a loopback port distinct from the S3 mock's
9099); this module runs a plain HTTP server on that port and records what
arrives. The payload is opaque (encrypted), so tests assert on the request
shape (method, path, headers) rather than decrypting it.
"""

import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST, PORT = "127.0.0.1", 9098

ENDPOINT = f"http://{HOST}:{PORT}"


class MockPush:
    def __init__(self):
        self.requests = []
        self.statuses = []
        self._lock = threading.Lock()

    def reset(self):
        with self._lock:
            self.requests.clear()
            self.statuses.clear()

    def record(self, path, headers, body):
        with self._lock:
            self.requests.append(
                {
                    "path": path,
                    "headers": {k.lower(): v for k, v in headers.items()},
                    "body": body,
                }
            )

    def queue_status(self, code):
        """Forces the next response(s) to `code` (e.g. 410 to drop a sub)."""
        with self._lock:
            self.statuses.append(code)

    def next_status(self):
        with self._lock:
            if self.statuses:
                return self.statuses.pop(0)

            return 201

    def count(self):
        with self._lock:
            return len(self.requests)

    def all(self):
        with self._lock:
            return list(self.requests)

    def reset_subscriptions(self):
        with self._lock:
            self.requests.clear()


mock_push = MockPush()


class _Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)

        mock_push.record(self.path, dict(self.headers), body)

        code = mock_push.next_status()

        self.send_response(code)
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
