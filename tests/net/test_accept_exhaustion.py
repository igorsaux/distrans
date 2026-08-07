"""File-descriptor exhaustion must not hang or kill the accept loop.

Regression: `accept` used to busy-loop on `EMFILE` without making progress,
which froze event dispatch for the whole server. The `low_fd_server` fixture
runs the server with a small `RLIMIT_NOFILE`, and the flood is written once and
run over both transports.
"""

from helpers import assert_recovers, try_connect

FLOOD = 200


def test_fd_exhaustion_does_not_hang_the_server(low_fd_server):
    server = low_fd_server
    socks = []

    try:
        for _ in range(FLOOD):
            sock = try_connect(server)

            if sock is not None:
                socks.append(sock)

        server.assert_alive()
    finally:
        for sock in socks:
            sock.close()

    # A server stuck in the accept loop would never serve this.
    assert_recovers(server)
