"""Fixtures for the socket-level abuse suite.

The suite boots its own server processes, once per transport, and drives them
with raw sockets and plain HTTP. The abuse cases are written once and run over
both unix and TCP through the parameterized fixtures.

Requires `zig build` (the server binary) and a running `distrans_test` database.
"""

import http.client
import json
import os
import resource
import shutil
import socket
import subprocess
import tempfile
import time
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
CONFIG_PATH = REPO_ROOT / "config.tests.json"
BINARY = REPO_ROOT / "zig-out" / "bin" / "distrans"

TRANSPORTS = ["unix", "inet"]

# Kept small so the abuse cases stay fast.
MAX_PEERS = 32
# The peer cap for `small_peer_server`, small enough to fill with a couple of
# clients.
SMALL_MAX_PEERS = 2
READ_TIMEOUT_MS = 300
WRITE_TIMEOUT_MS = 300
DISCONNECT_TIMEOUT_MS = 150

# How long to wait for the server to react to an abuse case.
REACTION_TIMEOUT_S = 5.0
# How long to wait for the server to start listening.
START_TIMEOUT_S = 15.0


class ServerHandle:
    def __init__(self, transport, proc, tmpdir, config, config_path, port=None):
        self.transport = transport
        self.proc = proc
        self.tmpdir = tmpdir
        self.config = config
        self.config_path = config_path
        self.port = port
        self.log_file = None
        self.log_path = None

    @property
    def socket_path(self):
        return self.config["socket"]["bind"]["path"]

    def connect_raw(self, timeout=REACTION_TIMEOUT_S):
        """A blocking client socket connected to the server."""
        if self.transport == "unix":
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(timeout)
            sock.connect(self.socket_path)
        else:
            sock = socket.create_connection(("::1", self.port), timeout=timeout)

        return sock

    def http_connection(self, timeout=REACTION_TIMEOUT_S):
        if self.transport == "unix":
            conn = http.client.HTTPConnection("localhost", timeout=timeout)
            path = self.socket_path

            def connect():
                sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                sock.settimeout(timeout)
                sock.connect(path)
                conn.sock = sock

            conn.connect = connect
        else:
            conn = http.client.HTTPConnection("::1", self.port, timeout=timeout)

        return conn

    def get(self, path="/api/limits", timeout=REACTION_TIMEOUT_S):
        """A normal request; returns (status, body_bytes)."""
        conn = self.http_connection(timeout=timeout)

        try:
            conn.request("GET", path)
            response = conn.getresponse()

            return response.status, response.read()
        finally:
            conn.close()

    def read_log(self):
        if self.log_path is None:
            return ""

        with open(self.log_path, "r", errors="replace") as f:
            return f.read()

    def assert_alive(self):
        code = self.proc.poll()

        assert code is None, f"server exited unexpectedly with {code!r}"

    def stop(self, timeout=10.0):
        if self.proc.poll() is not None:
            return

        self.proc.terminate()

        try:
            self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(timeout=timeout)


def _free_port():
    """Pick a currently free loopback port (small TOCTOU window)."""
    with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as sock:
        sock.bind(("::1", 0))

        return sock.getsockname()[1]


def _wait_until_listening(handle, deadline):
    while time.monotonic() < deadline:
        if handle.proc.poll() is not None:
            raise RuntimeError(
                f"server exited during startup with {handle.proc.returncode!r}\n"
                f"{handle.read_log()}"
            )

        try:
            handle.connect_raw(timeout=0.5).close()

            return
        except OSError:
            time.sleep(0.05)

    raise RuntimeError("server did not start listening in time")


def spawn_server(
    transport,
    nofile=None,
    stale_socket=False,
    max_peers=None,
    read_timeout_ms=None,
):
    """Boot a server for `transport` and return a running `ServerHandle`.

    `max_peers` and `read_timeout_ms` default to the suite-wide abuse-case
    values; pass an override only where a test needs a different bound.
    """
    if not BINARY.exists():
        pytest.skip(f"server binary not built: {BINARY} (run `zig build`)")

    with CONFIG_PATH.open() as f:
        base = json.load(f)

    tmpdir = tempfile.mkdtemp(prefix="distrans-net-", dir="/tmp")
    port = None
    socket_path = None

    config = json.loads(json.dumps(base))
    config["general"]["max_peers"] = MAX_PEERS if max_peers is None else max_peers
    config["db"]["pool"] = 2
    config["http"]["read_timeout_ms"] = (
        READ_TIMEOUT_MS if read_timeout_ms is None else read_timeout_ms
    )
    config["http"]["write_timeout_ms"] = WRITE_TIMEOUT_MS
    config["socket"]["disconnect_timeout_ms"] = DISCONNECT_TIMEOUT_MS

    if transport == "unix":
        socket_path = os.path.join(tmpdir, "distrans.sock")

        if stale_socket:
            Path(socket_path).touch()

        config["socket"]["bind"] = {"type": "unix", "path": socket_path}
    else:
        port = _free_port()
        config["socket"]["bind"] = {"type": "inet", "host": "::1", "port": str(port)}

    config_path = os.path.join(tmpdir, "config.json")

    with open(config_path, "w") as f:
        json.dump(config, f)

    def preexec():
        if nofile is not None:
            resource.setrlimit(resource.RLIMIT_NOFILE, (nofile, nofile))

    log_path = os.path.join(tmpdir, "server.log")
    log_file = open(log_path, "w")

    proc = subprocess.Popen(
        [str(BINARY), config_path],
        cwd=str(REPO_ROOT),
        stdout=log_file,
        stderr=subprocess.STDOUT,
        preexec_fn=preexec if nofile is not None else None,
    )

    handle = ServerHandle(transport, proc, tmpdir, config, config_path, port=port)
    handle.log_file = log_file
    handle.log_path = log_path

    try:
        _wait_until_listening(handle, time.monotonic() + START_TIMEOUT_S)
    except Exception:
        handle.stop()
        log_file.close()
        shutil.rmtree(tmpdir, ignore_errors=True)

        raise

    return handle


def teardown_server(handle):
    handle.stop()

    if handle.log_file is not None:
        handle.log_file.close()

    shutil.rmtree(handle.tmpdir, ignore_errors=True)


@pytest.fixture(params=TRANSPORTS)
def server(request):
    handle = spawn_server(request.param)
    handle.assert_alive()

    yield handle

    teardown_server(handle)


@pytest.fixture(params=TRANSPORTS)
def low_fd_server(request):
    handle = spawn_server(request.param, nofile=64)
    handle.assert_alive()

    yield handle

    teardown_server(handle)


@pytest.fixture(params=TRANSPORTS)
def small_peer_server(request):
    """A server with a tiny peer cap and a long HTTP read timeout.

    The long read timeout keeps the occupying clients from being dropped as
    idle so the cap, and not the timeout, is what rejects the next client.
    """
    handle = spawn_server(
        request.param,
        max_peers=SMALL_MAX_PEERS,
        read_timeout_ms=5000,
    )
    handle.assert_alive()

    yield handle

    teardown_server(handle)
