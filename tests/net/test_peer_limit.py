"""The peer cap must reject excess connections and recover when slots free.

The cap (`general.max_peers`) is an internal bound that a client can only see
through its effect: once every slot is occupied the server accepts and then
closes the next connection instead of serving it. Runs once per transport via
the `small_peer_server` fixture (cap 2, long HTTP read timeout).
"""

import time

from conftest import REACTION_TIMEOUT_S, SMALL_MAX_PEERS
from helpers import assert_recovers, recv_until_closed


def test_connection_above_max_peers_is_closed_and_the_server_recovers(
    small_peer_server,
):
    server = small_peer_server

    # Idle raw clients never complete a request, so they hold their peer slots
    # for the whole test instead of being freed after a response.
    occupying = [server.connect_raw() for _ in range(SMALL_MAX_PEERS)]

    extra = None

    try:
        # Give the accept loop a moment to claim the slots.
        time.sleep(0.2)

        extra = server.connect_raw()
        extra.sendall(b"GET /api/limits HTTP/1.1\r\nHost: localhost\r\n\r\n")

        assert recv_until_closed(extra, REACTION_TIMEOUT_S)
        server.assert_alive()
    finally:
        if extra is not None:
            extra.close()

        for sock in occupying:
            sock.close()

    # Closing the occupying clients frees their slots for normal traffic.
    assert_recovers(server)
