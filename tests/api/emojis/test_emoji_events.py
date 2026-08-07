# Gateway dispatch tests for the custom emoji endpoints.
#
# POST   /api/guilds/{guild_id}/emojis emits `emoji_created` with {id, guild_id}
# PATCH  /api/emojis/{emoji_id}         emits `emoji_updated` with {id, guild_id}
# PUT    /api/emojis/{emoji_id}/icon    emits `emoji_updated` with {id, guild_id}
# DELETE /api/emojis/{emoji_id}         emits `emoji_deleted` with {id, guild_id}

import sys
from pathlib import Path

# GatewayClient lives in tests/api/test_gateway.py.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from emoji_helpers import (  # noqa: E402
    create_emoji_ok,
    delete_emoji,
    patch_emoji,
    update_icon,
)


def _identify(guild):
    from test_gateway import GatewayClient

    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": guild.admin_token}})
    assert ws.recv_json()["op"] == "hello"

    return ws


def test_create_emoji_emits_emoji_created_event(http_client, test_guild):
    ws = _identify(test_guild)

    body = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "evented")

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "emoji_created"
    assert event["d"] == {"id": body["id"], "guild_id": str(test_guild.id)}

    ws.close()


def test_patch_emoji_emits_emoji_updated_event(http_client, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "before")

    ws = _identify(test_guild)

    response = patch_emoji(
        http_client, test_guild.admin_token, emoji["id"], {"name": "after"}
    )
    assert response.status_code == 204

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "emoji_updated"
    assert event["d"] == {"id": emoji["id"], "guild_id": str(test_guild.id)}

    ws.close()


def test_put_icon_emits_emoji_updated_event(http_client, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "iconupdate")

    ws = _identify(test_guild)

    response = update_icon(http_client, test_guild.admin_token, emoji["id"])
    assert response.status_code == 200, response.content

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "emoji_updated"
    assert event["d"] == {"id": emoji["id"], "guild_id": str(test_guild.id)}

    ws.close()


def test_delete_emoji_emits_emoji_deleted_event(http_client, test_guild):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "doomed")

    ws = _identify(test_guild)

    response = delete_emoji(http_client, test_guild.admin_token, emoji["id"])
    assert response.status_code == 204

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "emoji_deleted"
    assert event["d"] == {"id": emoji["id"], "guild_id": str(test_guild.id)}

    ws.close()
