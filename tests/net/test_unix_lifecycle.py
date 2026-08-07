"""Unix-only lifecycle: bind path, stale paths, shutdown and the lock.

These cases are inherently unix-specific (a path on the filesystem, and the
single-instance lock); the transport-agnostic abuse cases live in
`test_slow_clients.py`.
"""

import errno
import os
import shutil
import socket
import subprocess
import tempfile
from pathlib import Path

import pytest

from conftest import BINARY, REPO_ROOT, spawn_server, teardown_server


def test_basic_request_over_unix_socket():
    handle = spawn_server("unix")

    try:
        status, body = handle.get()

        assert status == 200
        assert body
    finally:
        teardown_server(handle)


def test_missing_stale_and_non_socket_paths_give_distinct_errors():
    """The three connect failure modes the prod symptom can come from."""
    tmpdir = tempfile.mkdtemp(prefix="distrans-net-", dir="/tmp")

    try:
        missing = os.path.join(tmpdir, "missing.sock")
        stale = os.path.join(tmpdir, "stale.sock")
        nonsocket = os.path.join(tmpdir, "plain.sock")

        # A stale socket: bound once, then closed without unlinking. The
        # pathname survives with nobody listening.
        stale_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        stale_sock.bind(stale)
        stale_sock.close()

        Path(nonsocket).touch()

        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(1)

        try:
            with pytest.raises(FileNotFoundError):
                sock.connect(missing)

            with pytest.raises(ConnectionRefusedError):
                sock.connect(stale)

            # A plain file is not a socket at all.
            with pytest.raises(OSError) as excinfo:
                sock.connect(nonsocket)

            assert excinfo.value.errno in {errno.ECONNREFUSED, errno.ENOTSOCK}
        finally:
            sock.close()
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def test_sigterm_removes_the_socket_path_and_leaves_no_orphan():
    handle = spawn_server("unix")
    path = handle.socket_path

    try:
        assert handle.get()[0] == 200
        assert os.path.exists(path)
    finally:
        handle.stop()

    try:
        assert not os.path.exists(path)

        # No orphan process survived the shutdown.
        assert handle.proc.poll() is not None
    finally:
        teardown_server(handle)


def test_stale_path_is_rebound():
    handle = spawn_server("unix", stale_socket=True)

    try:
        assert handle.get()[0] == 200
    finally:
        teardown_server(handle)


def test_second_instance_is_refused_while_the_first_serves():
    first = spawn_server("unix")

    try:
        result = subprocess.run(
            [str(BINARY), first.config_path],
            cwd=str(REPO_ROOT),
            capture_output=True,
            timeout=15,
        )

        assert result.returncode != 0, "a second instance must not start"
        assert b"another instance" in result.stderr

        first.assert_alive()
        assert first.get()[0] == 200
    finally:
        teardown_server(first)
