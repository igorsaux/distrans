import base64
import hashlib
import hmac
import json
import os
import socket
import struct
import sys
import time
from pathlib import Path

import pytest

from conftest import BASE_URL, CONFIG, SYSTEM_HEADERS

sys.path.insert(0, str(Path(__file__).resolve().parent / "users"))

import webp

WS_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def _ws_host_port():
    # BASE_URL looks like http://[::1]:8080 or http://localhost:8080
    url = BASE_URL.removeprefix("http://")
    host, port = url.rsplit(":", 1)

    if host.startswith("[") and host.endswith("]"):
        host = host[1:-1]

    return host, int(port)


class GatewayClient:
    def __init__(self):
        host, port = _ws_host_port()
        self.sock = socket.create_connection((host, port), timeout=5)
        self.key = base64.b64encode(os.urandom(16)).decode()
        self.buf = b""

        self.sock.sendall(
            (
                "GET /api/gateway HTTP/1.1\r\n"
                f"Host: {host}:{port}\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                f"Sec-WebSocket-Key: {self.key}\r\n"
                "Sec-WebSocket-Version: 13\r\n"
                "\r\n"
            ).encode()
        )

        status_line, self.headers = self._read_http_response_head()
        assert status_line.split(" ", 2)[:2] == ["HTTP/1.1", "101"], status_line
        header_dict = {k.lower(): v for k, v in self.headers}
        assert header_dict.get("upgrade", "").lower() == "websocket"
        assert header_dict.get("connection", "").lower() == "upgrade"

        expected = base64.b64encode(
            hashlib.sha1((self.key + WS_MAGIC).encode()).digest()
        ).decode()
        assert header_dict.get("sec-websocket-accept") == expected

    def _read_http_response_head(self):
        while b"\r\n\r\n" not in self.buf:
            self.buf += self.sock.recv(4096)

        head, self.buf = self.buf.split(b"\r\n\r\n", 1)
        lines = head.decode().split("\r\n")
        headers = []

        for line in lines[1:]:
            name, value = line.split(":", 1)
            headers.append((name.strip(), value.strip()))

        return lines[0], headers

    def _recv(self, n):
        while len(self.buf) < n:
            self.buf += self.sock.recv(4096)

        data, self.buf = self.buf[:n], self.buf[n:]

        return data

    def send_frame(self, opcode, payload):
        header = bytes([0x80 | opcode])
        mask = os.urandom(4)
        length = len(payload)

        if length <= 125:
            header += bytes([0x80 | length])
        elif length <= 0xFFFF:
            header += bytes([0x80 | 126]) + struct.pack(">H", length)
        else:
            header += bytes([0x80 | 127]) + struct.pack(">Q", length)

        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(header + mask + masked)

    def send_json(self, obj):
        self.send_frame(0x1, json.dumps(obj).encode())

    def recv_frame(self):
        first, second = self._recv(2)
        opcode = first & 0x0F
        length = second & 0x7F

        if length == 126:
            (length,) = struct.unpack(">H", self._recv(2))
        elif length == 127:
            (length,) = struct.unpack(">Q", self._recv(8))

        return opcode, self._recv(length)

    def recv_json(self, timeout=5.0):
        self.sock.settimeout(timeout)
        opcode, payload = self.recv_frame()
        assert opcode == 0x1, opcode

        return json.loads(payload)

    def close(self):
        try:
            self.send_frame(0x8, b"")
        except OSError:
            pass

        self.sock.close()

    def expect_closed(self, timeout=5.0):
        self.sock.settimeout(timeout)
        deadline = time.monotonic() + timeout

        while time.monotonic() < deadline:
            try:
                if self.sock.recv(4096) == b"":
                    return
            except (ConnectionResetError, BrokenPipeError):
                return
            except socket.timeout:
                break

        pytest.fail("the server did not close the connection")


def test_message_create_event(http_client, test_user, test_session, test_guild, test_channel):
    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_session.access_token}})

    hello = ws.recv_json()
    assert hello["op"] == "hello"

    response = http_client.post(
        f"/api/channels/{test_channel.id}/messages",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
        json={"content": "hello gateway"},
    )
    assert response.status_code == 201
    message_id = response.json()["id"]

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "message_created"
    assert event["d"] == {
        "id": str(message_id),
        "channel_id": str(test_channel.id),
        "guild_id": str(test_guild.id),
    }
    assert isinstance(event["s"], int)

    ws.close()


def test_user_create_event(http_client, test_session):
    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_session.access_token}})
    assert ws.recv_json()["op"] == "hello"

    response = http_client.post(
        "/api/system/users",
        json={"username": "wsuser", "password": "12345678"},
        headers=SYSTEM_HEADERS,
    )
    assert response.status_code == 201
    user_id = response.json()["id"]

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "user_created"
    assert event["d"] == {"id": str(user_id)}

    ws.close()


def test_guild_create_event(http_client, test_session):
    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_session.access_token}})
    assert ws.recv_json()["op"] == "hello"

    response = http_client.post(
        "/api/system/guilds", json={"name": "WsGuild"}, headers=SYSTEM_HEADERS
    )
    assert response.status_code == 201
    guild_id = response.json()["id"]

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "guild_created"
    assert event["d"] == {"id": str(guild_id)}

    ws.close()


def test_channel_create_event(http_client, test_session, test_guild):
    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_session.access_token}})
    assert ws.recv_json()["op"] == "hello"

    response = http_client.post(
        f"/api/guilds/{test_guild.id}/channels",
        json={"name": "WsChannel", "kind": "channel"},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )
    assert response.status_code == 201
    channel_id = response.json()["id"]

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "channel_created"
    assert event["d"] == {"id": str(channel_id), "guild_id": str(test_guild.id)}

    ws.close()


def test_channel_update_event(http_client, test_session, test_guild, test_channel):
    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_session.access_token}})
    assert ws.recv_json()["op"] == "hello"

    response = http_client.patch(
        f"/api/channels/{test_channel.id}",
        json={"name": "WsRenamedChannel"},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )
    assert response.status_code == 204

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "channel_updated"
    assert event["d"] == {"id": str(test_channel.id), "guild_id": str(test_guild.id)}

    ws.close()


def test_channel_delete_event(http_client, test_session, test_guild, test_channel):
    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_session.access_token}})
    assert ws.recv_json()["op"] == "hello"

    response = http_client.delete(
        f"/api/channels/{test_channel.id}",
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )
    assert response.status_code == 204

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "channel_deleted"
    assert event["d"] == {"id": str(test_channel.id), "guild_id": str(test_guild.id)}

    ws.close()


def test_guild_delete_event(http_client, test_session):
    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_session.access_token}})
    assert ws.recv_json()["op"] == "hello"

    response = http_client.post(
        "/api/system/guilds", json={"name": "DoomedWsGuild"}, headers=SYSTEM_HEADERS
    )
    assert response.status_code == 201
    guild_id = response.json()["id"]

    # Skip the guild_create dispatch
    assert ws.recv_json()["t"] == "guild_created"

    response = http_client.delete(
        f"/api/system/guilds/{guild_id}", headers=SYSTEM_HEADERS
    )
    assert response.status_code == 204

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "guild_deleted"
    assert event["d"] == {"id": str(guild_id)}

    ws.close()


def test_guild_update_event(http_client, test_session, test_guild):
    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_session.access_token}})
    assert ws.recv_json()["op"] == "hello"

    response = http_client.patch(
        f"/api/guilds/{test_guild.id}",
        json={"name": "WsRenamedGuild"},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )
    assert response.status_code == 204

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "guild_updated"
    assert event["d"] == {"id": str(test_guild.id)}
    assert isinstance(event["s"], int)

    ws.close()


def test_guild_avatar_update_event(http_client, test_session, test_guild):
    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_session.access_token}})
    assert ws.recv_json()["op"] == "hello"

    response = http_client.put(
        f"/api/guilds/{test_guild.id}/avatar",
        content=webp.make_webp(),
        headers={
            "Authorization": f"Bearer {test_guild.admin_token}",
            "Content-Type": "image/webp",
        },
    )
    assert response.status_code == 200

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "guild_updated"
    assert event["d"] == {"id": str(test_guild.id)}

    ws.close()


def test_guild_avatar_delete_event(http_client, test_session, test_guild):
    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_session.access_token}})
    assert ws.recv_json()["op"] == "hello"

    response = http_client.delete(
        f"/api/guilds/{test_guild.id}/avatar",
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )
    assert response.status_code == 204

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "guild_updated"
    assert event["d"] == {"id": str(test_guild.id)}

    ws.close()


def test_user_delete_event(http_client, test_session):
    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_session.access_token}})
    assert ws.recv_json()["op"] == "hello"

    response = http_client.post(
        "/api/system/users",
        json={"username": "wsdoomed", "password": "12345678"},
        headers=SYSTEM_HEADERS,
    )
    assert response.status_code == 201
    user_id = response.json()["id"]

    # Skip the user_create dispatch
    assert ws.recv_json()["t"] == "user_created"

    response = http_client.delete(
        f"/api/system/users/{user_id}", headers=SYSTEM_HEADERS
    )
    assert response.status_code == 204

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "user_deleted"
    assert event["d"] == {"id": str(user_id)}

    ws.close()


def test_role_create_event(http_client, test_session, test_guild, test_user):
    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_session.access_token}})
    assert ws.recv_json()["op"] == "hello"

    response = http_client.post(
        "/api/system/superuser",
        json={"guild_id": test_guild.id, "user_id": test_user.id},
        headers=SYSTEM_HEADERS,
    )
    assert response.status_code == 201
    role_id = response.json()["id"]

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "role_created"
    assert event["d"] == {"id": str(role_id), "guild_id": str(test_guild.id)}

    ws.close()


def test_role_delete_event(http_client, test_session, test_guild, test_user):
    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_session.access_token}})
    assert ws.recv_json()["op"] == "hello"

    response = http_client.post(
        "/api/system/superuser",
        json={"guild_id": test_guild.id, "user_id": test_user.id},
        headers=SYSTEM_HEADERS,
    )
    assert response.status_code == 201
    role_id = response.json()["id"]

    # Skip the role_create dispatch
    assert ws.recv_json()["t"] == "role_created"

    response = http_client.delete(
        f"/api/system/guilds/{test_guild.id}/roles/{role_id}",
        headers=SYSTEM_HEADERS,
    )
    assert response.status_code == 204

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "role_deleted"
    assert event["d"] == {"id": str(role_id), "guild_id": str(test_guild.id)}

    ws.close()


def test_user_updated_event(http_client, test_session, test_user):
    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_session.access_token}})
    assert ws.recv_json()["op"] == "hello"

    response = http_client.patch(
        "/api/users/@me",
        json={"display_name": "WsUpdated", "current_password": test_user.password},
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )
    assert response.status_code == 204

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "user_updated"
    assert event["d"] == {"id": str(test_user.id)}
    assert isinstance(event["s"], int)

    ws.close()


def test_unidentified_socket_closed():
    ws = GatewayClient()
    ws.expect_closed()


def test_bot_token_identify(http_client, system_headers):
    response = http_client.post(
        "/api/system/users",
        json={"username": "wsbot", "is_bot": True},
        headers=system_headers,
    )
    assert response.status_code == 201
    bot_id = response.json()["id"]

    response = http_client.put(
        f"/api/system/users/{bot_id}", headers=system_headers
    )
    assert response.status_code == 200
    bot_token = response.json()["token"]

    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": bot_token}})

    hello = ws.recv_json()
    assert hello["op"] == "hello"

    ws.close()


def test_bot_token_identify_bad_token():
    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": "bot_" + "a" * 43}})
    ws.expect_closed()


def _create_bot_with_token(http_client, system_headers, username="poolbot"):
    response = http_client.post(
        "/api/system/users",
        json={"username": username, "is_bot": True},
        headers=system_headers,
    )
    assert response.status_code == 201, response.content
    bot_id = response.json()["id"]

    response = http_client.put(
        f"/api/system/users/{bot_id}", headers=system_headers
    )
    assert response.status_code == 200, response.content

    return bot_id, response.json()["token"]


def test_bot_identify_releases_db_connection(
    http_client, system_headers, test_session
):
    """A bot identify must not pin its lookup connection for the session.

    Opening as many bot gateway sessions as the pool has connections would
    exhaust every slot if each held its lookup connection until close; a
    DB-backed request from another user must still succeed while they stay
    connected.
    """
    pool_size = CONFIG["db"]["pool"]
    _, bot_token = _create_bot_with_token(http_client, system_headers)

    sessions = []

    try:
        for _ in range(pool_size):
            ws = GatewayClient()
            ws.send_json({"op": "identify", "d": {"token": bot_token}})
            assert ws.recv_json()["op"] == "hello"
            sessions.append(ws)

        response = http_client.get(
            "/api/users/@me",
            headers={"Authorization": f"Bearer {test_session.access_token}"},
        )
        assert response.status_code == 200
    finally:
        for ws in sessions:
            ws.close()


def test_jwt_identify_still_works(http_client, test_session):
    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_session.access_token}})

    hello = ws.recv_json()
    assert hello["op"] == "hello"

    ws.close()


def _make_access_token(user_id, exp):
    key = CONFIG["auth"]["access_token_key"].encode()
    b64 = lambda value: base64.urlsafe_b64encode(value).rstrip(b"=").decode()
    signing_input = (
        b64(b'{ "alg": "HS256", "typ": "JWT" }')
        + "."
        + b64(json.dumps({"sub": str(user_id), "exp": exp}).encode())
    )
    signature = hmac.new(key, signing_input.encode(), hashlib.sha256).digest()

    return f"{signing_input}.{b64(signature)}"


def test_jwt_identify_rejects_expired_token(test_user):
    token = _make_access_token(test_user.id, int(time.time()) - 60)
    ws = GatewayClient()
    try:
        ws.send_json({"op": "identify", "d": {"token": token}})
        ws.expect_closed()
    finally:
        ws.close()


def test_jwt_identify_rejects_user_deleted_after_token_issued(
    http_client, test_user, test_session
):
    response = http_client.delete(
        f"/api/system/users/{test_user.id}", headers=SYSTEM_HEADERS
    )
    assert response.status_code == 204

    ws = GatewayClient()
    try:
        ws.send_json(
            {"op": "identify", "d": {"token": test_session.access_token}}
        )
        ws.expect_closed()
    finally:
        ws.close()


def _create_webhook(http_client, token, channel_id, name="WsHook"):
    response = http_client.post(
        f"/api/channels/{channel_id}/webhooks",
        json={"name": name},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 201, response.content

    return response.json()


def test_webhook_create_event(http_client, test_session, test_guild, test_channel):
    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_session.access_token}})
    assert ws.recv_json()["op"] == "hello"

    created = _create_webhook(http_client, test_guild.admin_token, test_channel.id)

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "webhook_created"
    assert event["d"] == {
        "id": str(created["id"]),
        "guild_id": str(test_guild.id),
        "channel_id": str(test_channel.id),
    }

    ws.close()


def test_webhook_update_event(http_client, test_session, test_guild, test_channel):
    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_session.access_token}})
    assert ws.recv_json()["op"] == "hello"

    created = _create_webhook(http_client, test_guild.admin_token, test_channel.id)
    assert ws.recv_json()["t"] == "webhook_created"

    response = http_client.patch(
        f"/api/webhooks/{created['id']}",
        json={"name": "WsHookRenamed"},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )
    assert response.status_code == 204

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "webhook_updated"
    assert event["d"] == {
        "id": str(created["id"]),
        "guild_id": str(test_guild.id),
        "channel_id": str(test_channel.id),
    }

    ws.close()


def test_webhook_avatar_update_event(
    http_client, test_session, test_guild, test_channel
):
    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_session.access_token}})
    assert ws.recv_json()["op"] == "hello"

    created = _create_webhook(http_client, test_guild.admin_token, test_channel.id)
    assert ws.recv_json()["t"] == "webhook_created"

    response = http_client.put(
        f"/api/webhooks/{created['id']}/avatar",
        content=webp.make_webp(),
        headers={
            "Authorization": f"Bearer {test_guild.admin_token}",
            "Content-Type": "image/webp",
        },
    )
    assert response.status_code == 200

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "webhook_updated"
    assert event["d"] == {
        "id": str(created["id"]),
        "guild_id": str(test_guild.id),
        "channel_id": str(test_channel.id),
    }

    ws.close()


def test_webhook_delete_event(http_client, test_session, test_guild, test_channel):
    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_session.access_token}})
    assert ws.recv_json()["op"] == "hello"

    created = _create_webhook(http_client, test_guild.admin_token, test_channel.id)
    assert ws.recv_json()["t"] == "webhook_created"

    response = http_client.delete(
        f"/api/webhooks/{created['id']}",
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )
    assert response.status_code == 204

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "webhook_deleted"
    assert event["d"] == {
        "id": str(created["id"]),
        "guild_id": str(test_guild.id),
        "channel_id": str(test_channel.id),
    }

    ws.close()
