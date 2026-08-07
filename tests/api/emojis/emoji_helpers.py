# Shared helpers for the custom emoji tests.
#
# The requirement numbering mirrors src/route/guilds/id/emojis.zig and
# src/route/emojis/id.zig. Only the API surface is exercised here; the webp
# fixtures come from tests/api/users/webp.py (the emoji caps are 64 px and 32
# frames, so the embedded 8x8 frames fit).

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "users"))

from permissions import (  # noqa: E402
    ADD_REACTIONS,
    CREATE_EMOJI,
    CREATE_ROLES,
    DELETE_REACTIONS,
    DELETE_EMOJI,
    GUILD_MODIFY,
    MODIFY_EMOJI,
)

import webp  # noqa: E402

from conftest import (  # noqa: E402
    SYSTEM_HEADERS,
    seed_role,
    system_create_guild,
    system_create_user,
    system_login,
)

HASH_RE = re.compile(r"^[0-9a-f]{16}$")

EMOJI_WEBP = webp.make_webp()
ANIMATED_WEBP = webp.make_animated_webp(frames=3)


def create_guild_with_admin(http_client, name):
    """Create a guild plus an admin whose superuser role carries every bit.

    `conftest.system_create_guild` returns a guild without a token, so the
    cross-guild isolation tests need this wrapper.
    """
    guild = system_create_guild(http_client, name=name)
    admin = system_create_user(http_client, username=f"guild_admin_{guild.id}")

    response = http_client.post(
        "/api/system/superuser",
        json={"guild_id": guild.id, "user_id": admin["id"]},
        headers=SYSTEM_HEADERS,
    )
    assert response.status_code == 201, response.content

    token, _ = system_login(http_client, f"guild_admin_{guild.id}")

    return guild, token


def auth_headers(token):
    return {"Authorization": f"Bearer {token}"}


def create_emoji(
    http_client,
    token,
    guild_id,
    name,
    content=EMOJI_WEBP,
    content_type="image/webp",
    params=None,
):
    headers = auth_headers(token)

    if content is not None and content_type is not None:
        headers["Content-Type"] = content_type

    return http_client.post(
        f"/api/guilds/{guild_id}/emojis",
        params=params if params is not None else {"name": name},
        content=content,
        headers=headers,
    )


def create_emoji_ok(
    http_client, token, guild_id, name, content=EMOJI_WEBP, expected_name=None
):
    response = create_emoji(http_client, token, guild_id, name, content)
    assert response.status_code == 201, response.content

    body = response.json()
    assert body["name"] == (name if expected_name is None else expected_name)
    assert HASH_RE.fullmatch(body["icon_hash"])

    return body


def list_emojis(http_client, token, guild_id, **params):
    return http_client.get(
        f"/api/guilds/{guild_id}/emojis", params=params, headers=auth_headers(token)
    )


def patch_emoji(http_client, token, emoji_id, payload, content_type="application/json"):
    headers = auth_headers(token)

    if content_type is not None:
        headers["Content-Type"] = content_type

    return http_client.patch(
        f"/api/emojis/{emoji_id}", json=payload, headers=headers
    )


def delete_emoji(http_client, token, emoji_id):
    return http_client.delete(
        f"/api/emojis/{emoji_id}", headers=auth_headers(token)
    )


def get_icon(http_client, emoji_id, hash_value, token=None):
    params = {} if hash_value is None else {"hash": hash_value}
    headers = auth_headers(token) if token else {}

    return http_client.get(
        f"/api/emojis/{emoji_id}/icon", params=params, headers=headers
    )


def update_icon(
    http_client, token, emoji_id, content=EMOJI_WEBP, content_type="image/webp", params=None
):
    headers = auth_headers(token)

    if content is not None and content_type is not None:
        headers["Content-Type"] = content_type

    return http_client.put(
        f"/api/emojis/{emoji_id}/icon",
        params=params or {},
        content=content,
        headers=headers,
    )


def is_webp(body):
    return body[:4] == b"RIFF" and body[8:12] == b"WEBP"


def is_animated_webp(body):
    return is_webp(body) and body[12:16] == b"VP8X" and bool(body[20] & 0x02)


def grant_role(db_conn, guild_id, user_id, role_id, permissions, position=1):
    """Create a role carrying exactly `permissions` and grant it to `user_id`."""
    seed_role(db_conn, guild_id, role_id, f"role-{role_id}", position, permissions)

    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.member_roles (guild_id, user_id, role_id)"
            " VALUES (%s, %s, %s)",
            (guild_id, user_id, role_id),
        )
