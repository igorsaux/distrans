"""Slow, idle and abruptly closed clients must not wedge the server.

Runs once per transport (unix and TCP) via the `server` fixture.
"""

import socket

from conftest import MAX_PEERS, REACTION_TIMEOUT_S
from helpers import (
    assert_recovers,
    read_all,
    recv_until_closed,
    set_linger_reset,
    try_connect,
)

REQUEST = b"GET /api/limits HTTP/1.1\r\nHost: localhost\r\n\r\n"


def test_slowloris_idle_connections_are_dropped_and_server_recovers(server):
    slow = []

    try:
        for _ in range(MAX_PEERS):
            sock = server.connect_raw()
            sock.sendall(b"GET /api/lim")
            slow.append(sock)

        for sock in slow:
            assert recv_until_closed(sock, REACTION_TIMEOUT_S)

        assert_recovers(server)
    finally:
        for sock in slow:
            sock.close()


def test_partial_body_does_not_wedge_the_server(server):
    sock = server.connect_raw()

    try:
        sock.sendall(
            b"POST /api/auth/token HTTP/1.1\r\n"
            b"Host: localhost\r\n"
            b"Content-Type: application/json\r\n"
            b"Content-Length: 1000\r\n"
            b"\r\n"
            b'{"grant_type":'
        )

        read_all(sock, REACTION_TIMEOUT_S)
        assert_recovers(server)
    finally:
        sock.close()


def test_slow_reader_does_not_wedge_the_server(server):
    sock = server.connect_raw()

    try:
        sock.sendall(REQUEST)

        # Never read the response; the server must still accept new work.
        assert_recovers(server)
        assert recv_until_closed(sock, REACTION_TIMEOUT_S)
    finally:
        sock.close()


def test_abrupt_reset_does_not_wedge_the_server(server):
    sock = server.connect_raw()
    set_linger_reset(sock)

    try:
        sock.sendall(REQUEST)
    finally:
        # RST instead of a graceful FIN.
        sock.close()

    assert_recovers(server)


def test_half_close_closes_cleanly_and_server_recovers(server):
    # A half-closed client is treated as done: the server drops the peer. The
    # contract here is that it must close cleanly (no hang, no leak) and keep
    # serving other clients.
    sock = server.connect_raw()

    try:
        sock.sendall(REQUEST)
        sock.shutdown(socket.SHUT_WR)

        read_all(sock, REACTION_TIMEOUT_S)

        assert recv_until_closed(sock, REACTION_TIMEOUT_S)
        assert_recovers(server)
    finally:
        sock.close()


def test_connect_flood_is_survived(server):
    socks = []

    try:
        for _ in range(MAX_PEERS + 16):
            sock = try_connect(server)

            if sock is not None:
                socks.append(sock)

        server.assert_alive()
    finally:
        for sock in socks:
            sock.close()

    assert_recovers(server)
