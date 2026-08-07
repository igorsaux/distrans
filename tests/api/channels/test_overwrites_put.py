# Tests for PUT /api/channels/{channel_id}/overwrites.
#
# PUT (upsert):
# R1 - content type must be application/json and body non-empty (400)
# R2 - user must be logged (401)
# R3 - the channel exists (404 "Channel not found")
# R4 - user has manage_overwrites on the channel (403 "Missing permissions")
# R5 - body validation: target_id (decimal string), type ("role"|"member"),
#      allow/deny (decimal strings, no reserved bits);
#      400 "'<field>' is missing" / "'<field>' is not a string" /
#      "'<field>' is invalid"
# R6 - the target exists: role → 404 "Role not found", member (incl.
#      soft-deleted) → 404 "User not found"
# R7 - idempotent no-op: identical allow+deny → 204 (checked before
#      hierarchy)
# R8 - target hierarchy (403 "Missing permissions"): member target strictly
#      below the caller's highest position (self-overwrites always allowed); role
#      target position strictly below the caller's highest position
# R9 - changed-bits subset rule (403 "Missing permissions"): every bit
#      flipped by the request must be present in the caller's channel
#      permissions
# R10 - apply: allow=0 && deny=0 → remove the row, otherwise upsert
#
# Enforcement order is R1..R9, so tests exercising R5+ use a caller that
# passes R4: either the guild admin (superuser role, all bits, highest
# position MAX_POSITION from the fixture) or a seeded role with exact bits.

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from conftest import seed_role, system_login, SYSTEM_HEADERS as system_headers
from permissions import (
    READ_MESSAGES,
    SEND_MESSAGES,
    MANAGE_OVERWRITES,
)

GUILD_ADMIN_HIGHEST_POSITION = 32767


def _set_everyone_permissions(db_conn, guild_id, permissions):
    with db_conn.cursor() as cur:
        cur.execute(
            "UPDATE app.roles SET permissions = %s WHERE id = %s",
            (permissions.to_bytes(16), guild_id),
        )


def _create_role(db_conn, guild_id, role_id, name, position=0, permissions=0):
    seed_role(db_conn, guild_id, role_id, name, position, permissions)


def _assign_role(db_conn, guild_id, user_id, role_id):
    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.member_roles (guild_id, role_id, user_id)"
            " VALUES (%s, %s, %s)",
            (guild_id, role_id, user_id),
        )


def _add_overwrite(
    db_conn,
    guild_id,
    channel_id,
    target_type,
    allow=0,
    deny=0,
    role_id=None,
    user_id=None,
):
    # target_type: 0 = role, 1 = member
    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.overwrites"
            " (guild_id, channel_id, target_type, role_id, user_id, allow, deny)"
            " VALUES (%s, %s, %s, %s, %s, %s, %s)",
            (
                guild_id,
                channel_id,
                target_type,
                role_id,
                user_id,
                allow.to_bytes(16),
                deny.to_bytes(16),
            ),
        )


def _get_overwrite_rows(db_conn, channel_id, target_type, target_id):
    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT allow, deny FROM app.overwrites"
            " WHERE channel_id = %s AND target_type = %s AND target_id = %s",
            (channel_id, target_type, target_id),
        )
        return cur.fetchall()


def _create_plain_user(http_client, system_headers, username):
    response = http_client.post(
        "/api/system/users",
        json={"username": username, "password": "12345678"},
        headers=system_headers,
    )
    assert response.status_code == 201

    return response.json()["id"]


def _url(channel_id):
    return f"/api/channels/{channel_id}/overwrites"


def _put(http_client, channel_id, body, token):
    return http_client.put(
        _url(channel_id),
        json=body,
        headers={"Authorization": f"Bearer {token}"},
    )


def _base_body(**overrides):
    body = {
        "target_id": "1",
        "type": "role",
        "allow": "0",
        "deny": "0",
    }
    body.update(overrides)

    return body


# ---------------------------------------------------------------------------
# R1 / R2 / R3 / R4
# ---------------------------------------------------------------------------


# R1 - wrong content type
def test_put_overwrite_bad_content_type(http_client, test_channel, test_session):
    response = http_client.put(
        _url(test_channel.id),
        content=b"{}",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
            "Content-Type": "text/plain",
        },
    )

    assert response.status_code == 415


# R1 - empty body
def test_put_overwrite_empty_body(http_client, test_channel, test_session):
    response = http_client.put(
        _url(test_channel.id),
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 400


# R2 - no token; R1 passes because the request carries a valid JSON body,
# so the request reaches the bearer middleware which answers 401
def test_put_overwrite_unauthorized(http_client, test_channel):
    response = http_client.put(
        _url(test_channel.id),
        json=_base_body(),
    )

    assert response.status_code == 401


# Router: malformed channel_id is rejected with 400 before auth
def test_put_overwrite_malformed_channel_id(http_client, test_session):
    response = http_client.put(
        _url("not-a-number"),
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 400


# R3
def test_put_overwrite_channel_not_found(http_client, test_session):
    body = _base_body()

    response = _put(http_client, "1", body, test_session.access_token)

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "Channel not found"


# R4 - caller has no manage_overwrites anywhere (zeroed @everyone, no roles)
def test_put_overwrite_without_manage_overwrites(
    http_client, db_conn, test_guild, test_channel, test_user
):
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES)

    access_token, _ = system_login(http_client, test_user.username, test_user.password)

    body = _base_body(target_id=str(test_guild.id))

    response = _put(http_client, test_channel.id, body, access_token)

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


# ---------------------------------------------------------------------------
# R5 - body validation (callers pass R4 via the admin superuser role)
# ---------------------------------------------------------------------------


# R5
def test_put_overwrite_bad_json(http_client, test_channel, test_guild):
    response = http_client.put(
        _url(test_channel.id),
        content=b"not json",
        headers={
            "Authorization": f"Bearer {test_guild.admin_token}",
            "Content-Type": "application/json",
        },
    )

    assert response.status_code == 400


# R5
def test_put_overwrite_non_object_body(http_client, test_channel, test_guild):
    response = http_client.put(
        _url(test_channel.id),
        content=b"[1, 2]",
        headers={
            "Authorization": f"Bearer {test_guild.admin_token}",
            "Content-Type": "application/json",
        },
    )

    assert response.status_code == 400


# R5
@pytest.mark.parametrize("field", ["target_id", "type", "allow", "deny"])
def test_put_overwrite_missing_field(http_client, test_channel, test_guild, field):
    body = _base_body()
    del body[field]

    response = _put(http_client, test_channel.id, body, test_guild.admin_token)

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == f"'{field}' is missing"


# R5
@pytest.mark.parametrize("field", ["target_id", "type", "allow", "deny"])
def test_put_overwrite_non_string_field(http_client, test_channel, test_guild, field):
    body = _base_body()
    body[field] = 123

    response = _put(http_client, test_channel.id, body, test_guild.admin_token)

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == f"'{field}' is not a string"


# R5
def test_put_overwrite_invalid_target_id(http_client, test_channel, test_guild):
    body = _base_body(target_id="not-a-number")

    response = _put(http_client, test_channel.id, body, test_guild.admin_token)

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'target_id' is invalid"


# R5
def test_put_overwrite_invalid_type(http_client, test_channel, test_guild):
    body = _base_body(type="guild")

    response = _put(http_client, test_channel.id, body, test_guild.admin_token)

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'type' is invalid"


# R5
@pytest.mark.parametrize("field", ["allow", "deny"])
def test_put_overwrite_invalid_permissions_field(
    http_client, test_channel, test_guild, field
):
    body = _base_body(**{field: "not-a-number"})

    response = _put(http_client, test_channel.id, body, test_guild.admin_token)

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == f"'{field}' is invalid"


# R5 - reserved bits are rejected (12 defined bits out of 128)
@pytest.mark.parametrize("field", ["allow", "deny"])
def test_put_overwrite_reserved_bit(http_client, test_channel, test_guild, field):
    body = _base_body(**{field: str(1 << 123)})

    response = _put(http_client, test_channel.id, body, test_guild.admin_token)

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == f"'{field}' is invalid"


# ---------------------------------------------------------------------------
# R6 - target existence (callers pass R4 via the admin superuser role)
# ---------------------------------------------------------------------------


# R6 - upsert create path with a non-existent role
def test_put_overwrite_role_not_found(http_client, test_guild, test_channel):
    body = _base_body(target_id="99999")

    response = _put(http_client, test_channel.id, body, test_guild.admin_token)

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "Role not found"


# R6
def test_put_overwrite_user_not_found(http_client, test_guild, test_channel):
    body = _base_body(target_id="99999", type="member")

    response = _put(http_client, test_channel.id, body, test_guild.admin_token)

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "User not found"


# R6 - a soft-deleted target user is reported as 404
def test_put_overwrite_soft_deleted_user(
    http_client, db_conn, system_headers, test_guild, test_channel
):
    user_id = _create_plain_user(http_client, system_headers, "goneaway")

    response = http_client.delete(
        f"/api/system/users/{user_id}", headers=system_headers
    )
    assert response.status_code == 204

    body = _base_body(target_id=user_id, type="member")

    response = _put(http_client, test_channel.id, body, test_guild.admin_token)

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "User not found"


# ---------------------------------------------------------------------------
# R7 / R8 - no-op and hierarchy (callers pass R4 via the admin superuser role)
# ---------------------------------------------------------------------------


# R7 - identical masks are a 204 no-op even against a target positioned at
# the caller's own highest position (no-op is checked before hierarchy)
def test_put_overwrite_no_op(http_client, db_conn, test_guild, test_channel):
    _create_role(
        db_conn,
        test_guild.id,
        "5570001",
        "highrole",
        position=GUILD_ADMIN_HIGHEST_POSITION,
    )

    old_allow = READ_MESSAGES
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        target_type=0,
        allow=old_allow,
        role_id="5570001",
    )

    body = _base_body(
        target_id="5570001",
        allow=str(old_allow),
    )

    response = _put(http_client, test_channel.id, body, test_guild.admin_token)

    assert response.status_code == 204
    assert response.content == b""

    rows = _get_overwrite_rows(db_conn, test_channel.id, 0, "5570001")
    assert len(rows) == 1
    assert int.from_bytes(rows[0]["allow"]) == old_allow


# R8 - a role at position == caller's highest position cannot be modified
# (admin highest = MAX_POSITION from the fixture, target role also there)
def test_put_overwrite_role_hierarchy(http_client, db_conn, test_guild, test_channel):
    _create_role(
        db_conn,
        test_guild.id,
        "5570002",
        "rival",
        position=GUILD_ADMIN_HIGHEST_POSITION,
    )

    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        target_type=0,
        allow=READ_MESSAGES,
        role_id="5570002",
    )

    body = _base_body(
        target_id="5570002",
        allow=str(READ_MESSAGES | SEND_MESSAGES),
    )

    response = _put(http_client, test_channel.id, body, test_guild.admin_token)

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"

    rows = _get_overwrite_rows(db_conn, test_channel.id, 0, "5570002")
    assert int.from_bytes(rows[0]["allow"]) == READ_MESSAGES


# R8 - a member positioned at the caller's highest position cannot be given
# an overwrite (strict > semantics: self-overwrites are always allowed, equal
# targets are not; the fixture admin's highest position is MAX_POSITION, the
# target role sits at MAX_POSITION too)
def test_put_overwrite_member_hierarchy(
    http_client, db_conn, system_headers, test_guild, test_channel, test_user
):
    _create_role(
        db_conn,
        test_guild.id,
        "5570003",
        "boss",
        position=GUILD_ADMIN_HIGHEST_POSITION,
    )
    _assign_role(db_conn, test_guild.id, test_user.id, "5570003")

    body = _base_body(
        target_id=str(test_user.id),
        type="member",
        allow=str(READ_MESSAGES),
    )

    response = _put(http_client, test_channel.id, body, test_guild.admin_token)

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"

    assert _get_overwrite_rows(db_conn, test_channel.id, 1, test_user.id) == []


# R8 - strict > semantics: a member at the caller's own highest position (a
# peer) may not receive an overwrite (the fixture admin's highest position
# is MAX_POSITION)
def test_put_overwrite_member_peer_denied(
    http_client, db_conn, test_guild, test_channel, test_user
):
    _create_role(
        db_conn,
        test_guild.id,
        "5570014",
        "peer",
        position=GUILD_ADMIN_HIGHEST_POSITION,
    )
    _assign_role(db_conn, test_guild.id, test_user.id, "5570014")

    body = _base_body(
        target_id=str(test_user.id),
        type="member",
        allow=str(READ_MESSAGES),
    )

    response = _put(http_client, test_channel.id, body, test_guild.admin_token)

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"

    assert _get_overwrite_rows(db_conn, test_channel.id, 1, test_user.id) == []


# R8 - self-overwrites are always allowed, even for a member with no roles
# (both highest positions are 0). The caller passes R4/R9 via @everyone
# bits while still having no member_roles.
def test_put_overwrite_member_self_allowed(
    http_client, db_conn, test_session, test_guild, test_channel
):
    _set_everyone_permissions(db_conn, test_guild.id, MANAGE_OVERWRITES | READ_MESSAGES)

    me = http_client.get(
        "/api/users/@me",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )
    assert me.status_code == 200

    body = _base_body(
        target_id=me.json()["id"],
        type="member",
        allow=str(READ_MESSAGES),
    )

    response = _put(http_client, test_channel.id, body, test_session.access_token)

    assert response.status_code == 204
    assert response.content == b""


# R8 - success path: a member strictly below the caller may receive an
# overwrite (role-less target, position 0 < admin's 1)
def test_put_overwrite_member_below_caller(
    http_client, db_conn, system_headers, test_guild, test_channel, test_user
):
    target_id = _create_plain_user(http_client, system_headers, "lowmember")

    body = _base_body(
        target_id=target_id,
        type="member",
        allow=str(READ_MESSAGES),
    )

    response = _put(http_client, test_channel.id, body, test_guild.admin_token)

    assert response.status_code == 204
    assert response.content == b""

    rows = _get_overwrite_rows(db_conn, test_channel.id, 1, target_id)
    assert len(rows) == 1
    assert int.from_bytes(rows[0]["allow"]) == READ_MESSAGES


# ---------------------------------------------------------------------------
# R9 - changed-bits subset rule (exact-bit pinning: @everyone zeroed, the
# caller's role carries exactly the listed bits)
# ---------------------------------------------------------------------------


# R9 - revoking a bit the caller does not own is rejected (the old row sits
# on a role target so its allow bits do not fold into the caller's own
# channel permissions)
def test_put_overwrite_revoke_bit_not_owned(
    http_client, db_conn, test_guild, test_channel, test_user
):
    _set_everyone_permissions(db_conn, test_guild.id, 0)
    _create_role(
        db_conn,
        test_guild.id,
        "5570004",
        "manager",
        position=1,
        permissions=MANAGE_OVERWRITES,
    )
    _assign_role(db_conn, test_guild.id, test_user.id, "5570004")
    _create_role(db_conn, test_guild.id, "5570015", "target", position=0)

    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        target_type=0,
        allow=READ_MESSAGES | SEND_MESSAGES,
        role_id="5570015",
    )

    access_token, _ = system_login(http_client, test_user.username, test_user.password)

    # changed = READ_MESSAGES (removed), which the caller does not own
    body = _base_body(
        target_id="5570015",
        allow=str(SEND_MESSAGES),
    )

    response = _put(http_client, test_channel.id, body, access_token)

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"

    rows = _get_overwrite_rows(db_conn, test_channel.id, 0, "5570015")
    assert int.from_bytes(rows[0]["allow"]) == READ_MESSAGES | SEND_MESSAGES


# R9 - granting a bit the caller does not own is rejected
def test_put_overwrite_grant_bit_not_owned(
    http_client, db_conn, test_guild, test_channel, test_user
):
    _set_everyone_permissions(db_conn, test_guild.id, 0)
    _create_role(
        db_conn,
        test_guild.id,
        "5570005",
        "manager",
        position=1,
        permissions=MANAGE_OVERWRITES,
    )
    _assign_role(db_conn, test_guild.id, test_user.id, "5570005")
    _create_role(db_conn, test_guild.id, "5570016", "target", position=0)

    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        target_type=0,
        allow=READ_MESSAGES,
        role_id="5570016",
    )

    access_token, _ = system_login(http_client, test_user.username, test_user.password)

    # changed = SEND_MESSAGES (added), which the caller does not own
    body = _base_body(
        target_id="5570016",
        allow=str(READ_MESSAGES | SEND_MESSAGES),
    )

    response = _put(http_client, test_channel.id, body, access_token)

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"

    rows = _get_overwrite_rows(db_conn, test_channel.id, 0, "5570016")
    assert int.from_bytes(rows[0]["allow"]) == READ_MESSAGES


# R9 - removal (0/0) with bits the caller does not own is rejected
def test_put_overwrite_remove_bit_not_owned(
    http_client, db_conn, test_guild, test_channel, test_user
):
    _set_everyone_permissions(db_conn, test_guild.id, 0)
    _create_role(
        db_conn,
        test_guild.id,
        "5570006",
        "manager",
        position=1,
        permissions=MANAGE_OVERWRITES,
    )
    _assign_role(db_conn, test_guild.id, test_user.id, "5570006")
    _create_role(db_conn, test_guild.id, "5570017", "target", position=0)

    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        target_type=0,
        allow=READ_MESSAGES | SEND_MESSAGES,
        role_id="5570017",
    )

    access_token, _ = system_login(http_client, test_user.username, test_user.password)

    # changed = READ_MESSAGES | SEND_MESSAGES (removed)
    body = _base_body(target_id="5570017")

    response = _put(http_client, test_channel.id, body, access_token)

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"

    rows = _get_overwrite_rows(db_conn, test_channel.id, 0, "5570017")
    assert int.from_bytes(rows[0]["allow"]) == READ_MESSAGES | SEND_MESSAGES


# ---------------------------------------------------------------------------
# R9 / R10 - success paths
# ---------------------------------------------------------------------------


# R9/R10 - update success pinned to exact bits: the caller's role carries
# exactly manage_overwrites | send_messages; changed = send_messages (owned)
def test_put_overwrite_update_success(
    http_client, db_conn, test_guild, test_channel, test_user
):
    _set_everyone_permissions(db_conn, test_guild.id, 0)
    _create_role(
        db_conn,
        test_guild.id,
        "5570007",
        "manager",
        position=1,
        permissions=MANAGE_OVERWRITES | SEND_MESSAGES,
    )
    _assign_role(db_conn, test_guild.id, test_user.id, "5570007")
    _create_role(db_conn, test_guild.id, "5570008", "target")

    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        target_type=0,
        allow=READ_MESSAGES,
        role_id="5570008",
    )

    access_token, _ = system_login(http_client, test_user.username, test_user.password)

    body = _base_body(
        target_id="5570008",
        allow=str(READ_MESSAGES | SEND_MESSAGES),
    )

    response = _put(http_client, test_channel.id, body, access_token)

    assert response.status_code == 204
    assert response.content == b""

    rows = _get_overwrite_rows(db_conn, test_channel.id, 0, "5570008")
    assert len(rows) == 1
    assert int.from_bytes(rows[0]["allow"]) == READ_MESSAGES | SEND_MESSAGES
    assert int.from_bytes(rows[0]["deny"]) == 0


# R10 - upsert create: no old row, member target, deny mask
def test_put_overwrite_create_success(
    http_client, db_conn, system_headers, test_guild, test_channel, test_user
):
    _set_everyone_permissions(db_conn, test_guild.id, 0)
    _create_role(
        db_conn,
        test_guild.id,
        "5570009",
        "manager",
        position=1,
        permissions=MANAGE_OVERWRITES | SEND_MESSAGES,
    )
    _assign_role(db_conn, test_guild.id, test_user.id, "5570009")

    target_id = _create_plain_user(http_client, system_headers, "targetmember")

    access_token, _ = system_login(http_client, test_user.username, test_user.password)

    body = _base_body(
        target_id=target_id,
        type="member",
        deny=str(SEND_MESSAGES),
    )

    response = _put(http_client, test_channel.id, body, access_token)

    assert response.status_code == 204
    assert response.content == b""

    rows = _get_overwrite_rows(db_conn, test_channel.id, 1, target_id)
    assert len(rows) == 1
    assert int.from_bytes(rows[0]["allow"]) == 0
    assert int.from_bytes(rows[0]["deny"]) == SEND_MESSAGES


# R10 - allow=0 && deny=0 removes the row
def test_put_overwrite_remove_success(
    http_client, db_conn, test_guild, test_channel, test_user
):
    _set_everyone_permissions(db_conn, test_guild.id, 0)
    _create_role(
        db_conn,
        test_guild.id,
        "5570010",
        "manager",
        position=1,
        permissions=MANAGE_OVERWRITES | SEND_MESSAGES | READ_MESSAGES,
    )
    _assign_role(db_conn, test_guild.id, test_user.id, "5570010")
    _create_role(db_conn, test_guild.id, "5570011", "target")

    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        target_type=0,
        allow=READ_MESSAGES | SEND_MESSAGES,
        role_id="5570011",
    )

    access_token, _ = system_login(http_client, test_user.username, test_user.password)

    body = _base_body(target_id="5570011")

    response = _put(http_client, test_channel.id, body, access_token)

    assert response.status_code == 204
    assert response.content == b""

    assert _get_overwrite_rows(db_conn, test_channel.id, 0, "5570011") == []


# R10 - updating the @everyone overwrite (position 0, below the caller).
# Note: the @everyone overwrite folds into the caller's own channel
# permissions, so the old mask must not deny a bit the caller needs for R9.
# Here the old allow=VIEW grants VIEW to the caller as well; changed bits
# are VIEW (removed) and SEND (added), both present in the caller's channel
# permissions (VIEW via the old overwrite fold, SEND via the role).
def test_put_overwrite_everyone_role_target(
    http_client, db_conn, test_guild, test_channel, test_user
):
    _set_everyone_permissions(db_conn, test_guild.id, 0)
    _create_role(
        db_conn,
        test_guild.id,
        "5570012",
        "manager",
        position=1,
        permissions=MANAGE_OVERWRITES | SEND_MESSAGES,
    )
    _assign_role(db_conn, test_guild.id, test_user.id, "5570012")

    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        target_type=0,
        allow=READ_MESSAGES,
        role_id=test_guild.id,
    )

    access_token, _ = system_login(http_client, test_user.username, test_user.password)

    body = _base_body(
        target_id=str(test_guild.id),
        deny=str(SEND_MESSAGES),
    )

    response = _put(http_client, test_channel.id, body, access_token)

    assert response.status_code == 204
    assert response.content == b""

    rows = _get_overwrite_rows(db_conn, test_channel.id, 0, test_guild.id)
    assert len(rows) == 1
    assert int.from_bytes(rows[0]["allow"]) == 0
    assert int.from_bytes(rows[0]["deny"]) == SEND_MESSAGES


# R7 - two identical PUTs → both 204, exactly one row
def test_put_overwrite_idempotent_repeat(http_client, db_conn, test_guild, test_channel):
    _create_role(db_conn, test_guild.id, "5570013", "target", position=0)

    body = _base_body(
        target_id="5570013",
        allow=str(READ_MESSAGES),
    )

    response = _put(http_client, test_channel.id, body, test_guild.admin_token)
    assert response.status_code == 204

    response = _put(http_client, test_channel.id, body, test_guild.admin_token)

    assert response.status_code == 204
    assert response.content == b""
    assert len(_get_overwrite_rows(db_conn, test_channel.id, 0, "5570013")) == 1
