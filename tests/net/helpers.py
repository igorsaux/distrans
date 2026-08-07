"""Raw-socket helpers shared by the socket abuse tests."""

import socket
import struct
import time


def recv_until_closed(sock, timeout):
    """True if the peer closes the connection within `timeout`."""
    deadline = time.monotonic() + timeout
    sock.settimeout(0.2)

    while time.monotonic() < deadline:
        try:
            data = sock.recv(4096)
        except socket.timeout:
            continue
        except OSError:
            return True

        if not data:
            return True

    return False


def read_all(sock, timeout):
    """Read until EOF or timeout; returns whatever arrived."""
    sock.settimeout(timeout)
    chunks = []

    while True:
        try:
            data = sock.recv(65536)
        except socket.timeout:
            break
        except OSError:
            break

        if not data:
            break

        chunks.append(data)

    return b"".join(chunks)


def set_linger_reset(sock):
    """Make close() send an RST instead of a FIN."""
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))


def try_connect(handle):
    """Connect, returning None when the server refuses/resets the attempt."""
    try:
        return handle.connect_raw(timeout=2.0)
    except OSError:
        return None


def assert_recovers(server, attempts=25):
    """The server must still answer a normal request and be alive."""
    last = None

    for _ in range(attempts):
        server.assert_alive()

        try:
            status, _ = server.get(timeout=2.0)

            if status == 200:
                return
            last = status
        except OSError as e:
            last = e

        time.sleep(0.2)

    raise AssertionError(f"server did not recover: {last!r}")
