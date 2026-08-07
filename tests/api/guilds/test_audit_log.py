import sys
from pathlib import Path

import pytest

from conftest import (
    seed_role,
    system_create_channel,
)

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "users"))

from permissions import GUILD_MODIFY, VIEW_AUDIT_LOG  # noqa: E402

import webp  # noqa: E402

AUDIT_WEBP = webp.make_webp()

# app.audit_log.action values (mirror `AuditAction` in src/types.zig).
GUILD_NAME_UPDATE = 0
GUILD_AVATAR_UPDATE = 1
GUILD_AVATAR_DELETE = 2
CHANNEL_CREATE = 3
CHANNEL_NAME_UPDATE = 4
CHANNEL_TOPIC_UPDATE = 5
CHANNEL_PARENT_UPDATE = 6
ROLE_CREATE = 11
ROLE_DELETE = 16
EMOJI_CREATE = 20

ENTRY_KEYS = {
    "id",
    "actor_id",
    "action",
    "target_id",
    "target_user_id",
    "channel_id",
    "created_at",
}


def _auth(session):
    return {"Authorization": f"Bearer {session.access_token}"}


def _get(http_client, session, guild_id, **params):
    return http_client.get(
        f"/api/guilds/{guild_id}/audit-log", headers=_auth(session), params=params
    )


def _mask(bits):
    return int(bits).to_bytes(16, "big")


def _set_everyone_permissions(db_conn, guild_id, permissions):
    with db_conn.cursor() as cur:
        cur.execute(
            "UPDATE app.roles SET permissions = %s WHERE id = %s",
            (_mask(permissions), guild_id),
        )


def _user_id_by_username(db_conn, username):
    with db_conn.cursor() as cur:
        cur.execute("SELECT id FROM app.users WHERE username = %s", (username,))

        return cur.fetchone()["id"]


def _insert_audit(
    db_conn,
    entry_id,
    *,
    guild_id,
    actor_id,
    action,
    target_id=None,
    target_user_id=None,
    channel_id=None,
):
    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.audit_log"
            " (id, guild_id, actor_id, action, target_id, target_user_id, channel_id)"
            " VALUES (%s, %s, %s, %s, %s, %s, %s)",
            (
                entry_id,
                guild_id,
                actor_id,
                action,
                target_id,
                target_user_id,
                channel_id,
            ),
        )


def _ids(response):
    return [entry["id"] for entry in response.json()["entries"]]


def _envelope(response):
    body = response.json()

    assert set(body) == {"entries", "total"}

    return body


def _admin_id(db_conn, test_guild):
    return _user_id_by_username(db_conn, f"guild_admin_{test_guild.id}")


# ---------------------------------------------------------------------------
# R1: user must be logged
# ---------------------------------------------------------------------------


def test_audit_log_unauthorized(http_client, test_guild):
    response = http_client.get(f"/api/guilds/{test_guild.id}/audit-log")

    assert response.status_code == 401


# ---------------------------------------------------------------------------
# R2: the guild exists / parameters are well-formed
# ---------------------------------------------------------------------------


def test_audit_log_unknown_guild(http_client, test_guild):
    response = http_client.get(
        "/api/guilds/1/audit-log",
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 404
    assert response.json()["message"] == "Guild not found"


def test_audit_log_wrong_method(http_client, test_guild):
    response = http_client.post(
        f"/api/guilds/{test_guild.id}/audit-log",
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )

    assert response.status_code == 405
    assert "GET" in response.headers["allow"]


def test_audit_log_unknown_parameter(http_client, test_guild):
    headers = {"Authorization": f"Bearer {test_guild.admin_token}"}
    response = http_client.get(
        f"/api/guilds/{test_guild.id}/audit-log", headers=headers, params={"foo": "1"}
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Unknown parameter"


@pytest.mark.parametrize(
    "param_key,param_value",
    [
        ("limit", "0"),
        ("limit", "101"),
        ("limit", "foo"),
        ("offset", "-1"),
        ("offset", "foo"),
        ("sort", "bogus"),
        ("user", "foo"),
        ("action", ""),
        ("action", "bogus"),
        ("action", "role_create,"),
        ("action", ",role_create"),
    ],
)
def test_audit_log_bad_parameter(
    http_client, test_guild, param_key, param_value
):
    headers = {"Authorization": f"Bearer {test_guild.admin_token}"}
    response = http_client.get(
        f"/api/guilds/{test_guild.id}/audit-log",
        headers=headers,
        params={param_key: param_value},
    )

    assert response.status_code == 400
    assert response.json()["message"] == f"Bad '{param_key}' parameter"


# ---------------------------------------------------------------------------
# R3: view_audit_log is required (exactly)
# ---------------------------------------------------------------------------


def test_audit_log_forbidden_without_permission(
    db_conn, http_client, test_guild, test_session
):
    _set_everyone_permissions(db_conn, test_guild.id, 0)

    response = _get(http_client, test_session, test_guild.id)

    assert response.status_code == 403
    assert response.json()["message"] == "Missing permissions"


def test_audit_log_requires_exactly_view_audit_log(
    db_conn, http_client, test_guild, test_user, test_session
):
    _set_everyone_permissions(db_conn, test_guild.id, 0)
    seed_role(
        db_conn, test_guild.id, "8100001", "auditors", permissions=VIEW_AUDIT_LOG
    )

    # Not granted yet: the role carries the bit but the user does not have it.
    response = _get(http_client, test_session, test_guild.id)
    assert response.status_code == 403

    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.member_roles (guild_id, role_id, user_id)"
            " VALUES (%s, %s, %s)",
            (test_guild.id, "8100001", test_user.id),
        )

    response = _get(http_client, test_session, test_guild.id)
    assert response.status_code == 200


def test_audit_log_other_bits_do_not_grant_access(
    db_conn, http_client, test_guild, test_user, test_session
):
    _set_everyone_permissions(db_conn, test_guild.id, 0)
    seed_role(db_conn, test_guild.id, "8100002", "mods", permissions=GUILD_MODIFY)

    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.member_roles (guild_id, role_id, user_id)"
            " VALUES (%s, %s, %s)",
            (test_guild.id, "8100002", test_user.id),
        )

    response = _get(http_client, test_session, test_guild.id)

    assert response.status_code == 403


# ---------------------------------------------------------------------------
# R4: entries are written by the audited mutations
# ---------------------------------------------------------------------------


def test_audit_log_records_guild_name_update(db_conn, http_client, test_guild):
    admin_id = _admin_id(db_conn, test_guild)

    response = http_client.patch(
        f"/api/guilds/{test_guild.id}",
        json={"name": "Renamed"},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )
    assert response.status_code == 204

    response = _get_authed(http_client, test_guild, action="guild_name_update")

    assert response.status_code == 200

    entries = response.json()["entries"]
    assert len(entries) == 1

    entry = entries[0]
    assert set(entry) == ENTRY_KEYS
    assert entry["action"] == "guild_name_update"
    assert entry["actor_id"] == str(admin_id)
    assert entry["target_id"] is None
    assert entry["channel_id"] is None
    assert isinstance(entry["created_at"], int)


def test_audit_log_records_channel_create_and_update(db_conn, http_client, test_guild):
    channel = system_create_channel(
        http_client, test_guild.id, "Audited", admin_token=test_guild.admin_token
    )

    response = http_client.patch(
        f"/api/channels/{channel.id}",
        json={"name": "Audited2"},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )
    assert response.status_code == 204

    response = _get_authed(
        http_client, test_guild, action="channel_create,channel_name_update"
    )

    assert response.status_code == 200

    by_action = {entry["action"]: entry for entry in response.json()["entries"]}
    assert by_action["channel_create"]["channel_id"] == channel.id
    assert by_action["channel_name_update"]["channel_id"] == channel.id


def test_audit_log_records_role_create_and_grant(
    db_conn, http_client, test_guild, test_user
):
    response = http_client.post(
        f"/api/guilds/{test_guild.id}/roles",
        json={"name": "newrole", "permissions": "0"},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )
    assert response.status_code == 201
    role_id = response.json()["id"]

    response = http_client.put(
        f"/api/roles/{role_id}/users/{test_user.id}",
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )
    assert response.status_code == 204

    response = _get_authed(http_client, test_guild, action="role_create,role_grant")

    assert response.status_code == 200

    by_action = {entry["action"]: entry for entry in response.json()["entries"]}
    assert by_action["role_create"]["target_id"] == role_id
    assert by_action["role_grant"]["target_id"] == role_id
    assert by_action["role_grant"]["target_user_id"] == test_user.id


def test_audit_log_self_delete_not_recorded(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    created = http_client.post(
        f"/api/channels/{test_channel.id}/messages",
        json={"content": "self"},
        headers=_auth(test_session),
    )
    assert created.status_code == 201
    self_message_id = created.json()["id"]

    response = http_client.delete(
        f"/api/messages/{self_message_id}", headers=_auth(test_session)
    )
    assert response.status_code == 204

    entries = _get_authed(http_client, test_guild, action="message_delete").json()[
        "entries"
    ]
    assert all(entry["target_id"] != self_message_id for entry in entries)


def test_audit_log_moderation_delete_recorded(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    created = http_client.post(
        f"/api/channels/{test_channel.id}/messages",
        json={"content": "moderate me"},
        headers=_auth(test_session),
    )
    assert created.status_code == 201
    message_id = created.json()["id"]

    response = http_client.delete(
        f"/api/messages/{message_id}",
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )
    assert response.status_code == 204

    entries = _get_authed(http_client, test_guild, action="message_delete").json()[
        "entries"
    ]
    matching = [entry for entry in entries if entry["target_id"] == message_id]
    assert len(matching) == 1
    assert matching[0]["channel_id"] == test_channel.id


def _get_authed(http_client, test_guild, **params):
    return http_client.get(
        f"/api/guilds/{test_guild.id}/audit-log",
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
        params=params,
    )


# ---------------------------------------------------------------------------
# Filters
# ---------------------------------------------------------------------------


def test_audit_log_filter_by_user(
    db_conn, http_client, test_guild, test_user
):
    admin_id = _admin_id(db_conn, test_guild)

    _insert_audit(
        db_conn, 1001, guild_id=test_guild.id, actor_id=test_user.id, action=ROLE_CREATE
    )
    _insert_audit(
        db_conn, 1002, guild_id=test_guild.id, actor_id=admin_id, action=ROLE_CREATE
    )

    response = _get_authed(http_client, test_guild, user=test_user.id)

    assert response.status_code == 200

    body = _envelope(response)
    assert _ids(response) == ["1001"]
    assert body["total"] == 1


def test_audit_log_filter_by_action_multi(db_conn, http_client, test_guild, test_user):
    for entry_id, action in (
        (1011, ROLE_CREATE),
        (1012, ROLE_DELETE),
        (1013, EMOJI_CREATE),
    ):
        _insert_audit(
            db_conn,
            entry_id,
            guild_id=test_guild.id,
            actor_id=test_user.id,
            action=action,
        )

    response = _get_authed(
        http_client, test_guild, user=test_user.id, action="role_create,role_delete"
    )

    assert response.status_code == 200
    assert _ids(response) == ["1012", "1011"]
    assert response.json()["total"] == 2


# ---------------------------------------------------------------------------
# Pagination
# ---------------------------------------------------------------------------


def test_audit_log_pagination_and_total(db_conn, http_client, test_guild, test_user):
    for entry_id in (1021, 1022, 1023, 1024):
        _insert_audit(
            db_conn,
            entry_id,
            guild_id=test_guild.id,
            actor_id=test_user.id,
            action=ROLE_CREATE,
        )

    response = _get_authed(http_client, test_guild, user=test_user.id, limit=2)
    assert _ids(response) == ["1024", "1023"]
    assert response.json()["total"] == 4

    response = _get_authed(
        http_client, test_guild, user=test_user.id, limit=2, offset=2
    )
    assert _ids(response) == ["1022", "1021"]
    assert response.json()["total"] == 4

    response = _get_authed(
        http_client, test_guild, user=test_user.id, sort="oldest", limit=2
    )
    assert _ids(response) == ["1021", "1022"]


def test_audit_log_offset_beyond_last_page(
    db_conn, http_client, test_guild, test_user
):
    _insert_audit(
        db_conn, 1031, guild_id=test_guild.id, actor_id=test_user.id, action=ROLE_CREATE
    )

    response = _get_authed(http_client, test_guild, user=test_user.id, offset=10)

    assert response.status_code == 200

    body = _envelope(response)
    assert body["entries"] == []
    assert body["total"] == 1


def test_audit_log_default_limit_is_25(
    db_conn, http_client, test_guild, test_user
):
    for entry_id in range(1100, 1130):
        _insert_audit(
            db_conn,
            entry_id,
            guild_id=test_guild.id,
            actor_id=test_user.id,
            action=ROLE_CREATE,
        )

    response = _get_authed(http_client, test_guild, user=test_user.id)

    assert response.status_code == 200

    body = _envelope(response)
    assert len(body["entries"]) == 25
    assert body["total"] == 30


# ---------------------------------------------------------------------------
# Granular actions: one entry per changed field, written in a single batch
# ---------------------------------------------------------------------------


def _admin_headers(test_guild):
    return {"Authorization": f"Bearer {test_guild.admin_token}"}


def _actions(http_client, test_guild, **params):
    response = _get_authed(http_client, test_guild, **params)

    assert response.status_code == 200

    return response.json()["entries"]


def test_audit_log_channel_patch_writes_one_entry_per_field(
    http_client, test_guild, test_channel
):
    response = http_client.patch(
        f"/api/channels/{test_channel.id}",
        json={"name": "Renamed", "topic": "hello"},
        headers=_admin_headers(test_guild),
    )
    assert response.status_code == 204

    entries = _actions(
        http_client,
        test_guild,
        action="channel_name_update,channel_topic_update",
    )

    by_action = {entry["action"]: entry for entry in entries}
    assert set(by_action) == {"channel_name_update", "channel_topic_update"}
    assert by_action["channel_name_update"]["channel_id"] == test_channel.id
    assert by_action["channel_topic_update"]["channel_id"] == test_channel.id


def test_audit_log_channel_parent_update(
    http_client, test_guild, test_channel, test_category
):
    response = http_client.patch(
        f"/api/channels/{test_channel.id}",
        json={"parent_id": test_category.id},
        headers=_admin_headers(test_guild),
    )
    assert response.status_code == 204

    entries = _actions(http_client, test_guild, action="channel_parent_update")

    assert len(entries) == 1
    assert entries[0]["action"] == "channel_parent_update"
    assert entries[0]["channel_id"] == test_channel.id


def test_audit_log_role_patch_writes_one_entry_per_field(http_client, test_guild):
    created = http_client.post(
        f"/api/guilds/{test_guild.id}/roles",
        json={"name": "granular", "permissions": "0"},
        headers=_admin_headers(test_guild),
    )
    assert created.status_code == 201
    role_id = created.json()["id"]

    response = http_client.patch(
        f"/api/roles/{role_id}",
        json={"name": "renamed", "color": 16711680, "mentionable": False},
        headers=_admin_headers(test_guild),
    )
    assert response.status_code == 204

    entries = _actions(
        http_client,
        test_guild,
        action="role_name_update,role_color_update,role_mentionable_update",
    )

    assert len(entries) == 3
    assert {entry["action"] for entry in entries} == {
        "role_name_update",
        "role_color_update",
        "role_mentionable_update",
    }
    assert all(entry["target_id"] == role_id for entry in entries)


def test_audit_log_overwrite_role_and_member_split(
    http_client, db_conn, test_guild, test_channel, test_user
):
    role_id = "8200001"
    seed_role(db_conn, test_guild.id, role_id, "overwrite-role")

    role_response = http_client.put(
        f"/api/channels/{test_channel.id}/overwrites",
        json={"target_id": role_id, "type": "role", "allow": "1", "deny": "0"},
        headers=_admin_headers(test_guild),
    )
    assert role_response.status_code == 204

    member_response = http_client.put(
        f"/api/channels/{test_channel.id}/overwrites",
        json={"target_id": test_user.id, "type": "member", "allow": "1", "deny": "0"},
        headers=_admin_headers(test_guild),
    )
    assert member_response.status_code == 204

    entries = _actions(
        http_client,
        test_guild,
        action="role_overwrite_update,member_overwrite_update",
    )

    by_action = {entry["action"]: entry for entry in entries}
    assert set(by_action) == {"role_overwrite_update", "member_overwrite_update"}

    role_entry = by_action["role_overwrite_update"]
    assert role_entry["channel_id"] == test_channel.id
    assert role_entry["target_id"] == role_id
    assert role_entry["target_user_id"] is None

    member_entry = by_action["member_overwrite_update"]
    assert member_entry["channel_id"] == test_channel.id
    assert member_entry["target_id"] is None
    assert member_entry["target_user_id"] == test_user.id


def test_audit_log_guild_avatar_update_and_delete(http_client, test_guild):
    put = http_client.put(
        f"/api/guilds/{test_guild.id}/avatar",
        content=AUDIT_WEBP,
        headers={**_admin_headers(test_guild), "Content-Type": "image/webp"},
    )
    assert put.status_code == 200

    delete = http_client.delete(
        f"/api/guilds/{test_guild.id}/avatar", headers=_admin_headers(test_guild)
    )
    assert delete.status_code == 204

    entries = _actions(
        http_client, test_guild, action="guild_avatar_update,guild_avatar_delete"
    )

    assert {entry["action"] for entry in entries} == {
        "guild_avatar_update",
        "guild_avatar_delete",
    }


def test_audit_log_emoji_name_and_icon(http_client, test_guild):
    headers = {**_admin_headers(test_guild), "Content-Type": "image/webp"}

    created = http_client.post(
        f"/api/guilds/{test_guild.id}/emojis",
        params={"name": "audited"},
        content=AUDIT_WEBP,
        headers=headers,
    )
    assert created.status_code == 201
    emoji_id = created.json()["id"]

    patch = http_client.patch(
        f"/api/emojis/{emoji_id}",
        json={"name": "renamed"},
        headers=_admin_headers(test_guild),
    )
    assert patch.status_code == 204

    icon = http_client.put(
        f"/api/emojis/{emoji_id}/icon", content=AUDIT_WEBP, headers=headers
    )
    assert icon.status_code == 200

    entries = _actions(
        http_client,
        test_guild,
        action="emoji_create,emoji_name_update,emoji_icon_update",
    )

    by_action = {entry["action"]: entry for entry in entries}
    assert set(by_action) == {
        "emoji_create",
        "emoji_name_update",
        "emoji_icon_update",
    }
    assert all(entry["target_id"] == emoji_id for entry in by_action.values())


def test_audit_log_webhook_name_and_avatar(http_client, test_guild, test_channel):
    created = http_client.post(
        f"/api/channels/{test_channel.id}/webhooks",
        json={"name": "audited"},
        headers=_admin_headers(test_guild),
    )
    assert created.status_code == 201
    webhook_id = created.json()["id"]

    patch = http_client.patch(
        f"/api/webhooks/{webhook_id}",
        json={"name": "renamed"},
        headers=_admin_headers(test_guild),
    )
    assert patch.status_code == 204

    put = http_client.put(
        f"/api/webhooks/{webhook_id}/avatar",
        content=AUDIT_WEBP,
        headers={**_admin_headers(test_guild), "Content-Type": "image/webp"},
    )
    assert put.status_code == 200

    delete = http_client.delete(
        f"/api/webhooks/{webhook_id}/avatar", headers=_admin_headers(test_guild)
    )
    assert delete.status_code == 204

    entries = _actions(
        http_client,
        test_guild,
        action=(
            "webhook_create,webhook_name_update,"
            "webhook_avatar_update,webhook_avatar_delete"
        ),
    )

    by_action = {entry["action"]: entry for entry in entries}
    assert set(by_action) == {
        "webhook_create",
        "webhook_name_update",
        "webhook_avatar_update",
        "webhook_avatar_delete",
    }
    assert all(entry["target_id"] == webhook_id for entry in by_action.values())
