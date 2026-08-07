# Gateway dispatch tests for /api/roles/{role_id}.
#
# PATCH success emits a `role_update` dispatch event with {id, guild_id}.
# DELETE success emits a `role_delete` dispatch event with {id, guild_id}.

import sys
from pathlib import Path

# GatewayClient lives in tests/api/test_gateway.py; make it importable when
# this file is run standalone (not as part of the full suite).
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from conftest import seed_role  # noqa: E402
from permissions import READ_MESSAGES, SEND_MESSAGES, MODIFY_ROLES  # noqa: E402


def _create_role(db_conn, guild_id, role_id, name, position=0, permissions=0):
    seed_role(db_conn, guild_id, role_id, name, position, permissions)


def test_patch_role_emits_role_update_event(http_client, db_conn, test_guild):
    from test_gateway import GatewayClient

    _create_role(
        db_conn,
        test_guild.id,
        "5570001",
        "evented",
        permissions=READ_MESSAGES | MODIFY_ROLES,
    )

    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_guild.admin_token}})
    assert ws.recv_json()["op"] == "hello"

    response = http_client.patch(
        f"/api/roles/5570001",
        json={"name": "evented-renamed"},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )
    assert response.status_code == 204

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "role_updated"
    assert event["d"] == {"id": "5570001", "guild_id": str(test_guild.id)}

    ws.close()


def test_delete_role_emits_role_delete_event(http_client, db_conn, test_guild):
    from test_gateway import GatewayClient

    _create_role(
        db_conn,
        test_guild.id,
        "5570002",
        "doomed",
        permissions=READ_MESSAGES | MODIFY_ROLES,
    )

    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_guild.admin_token}})
    assert ws.recv_json()["op"] == "hello"

    response = http_client.delete(
        f"/api/roles/5570002",
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )
    assert response.status_code == 204

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "role_deleted"
    assert event["d"] == {"id": "5570002", "guild_id": str(test_guild.id)}

    ws.close()


def test_patch_role_everyone_emits_role_update_event(http_client, test_guild):
    from test_gateway import GatewayClient

    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_guild.admin_token}})
    assert ws.recv_json()["op"] == "hello"

    response = http_client.patch(
        f"/api/roles/{test_guild.id}",
        json={"permissions": str(READ_MESSAGES | SEND_MESSAGES)},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )
    assert response.status_code == 204

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "role_updated"
    assert event["d"] == {"id": str(test_guild.id), "guild_id": str(test_guild.id)}

    ws.close()
