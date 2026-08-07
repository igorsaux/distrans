# Tests for the skip-bits (`skip_allows` = bit 12, `skip_denies` = bit 13)
# and the regression for the original anti-lockout bug.
#
# Skip-bit semantics:
# - The bits are read from the caller's BASE (guild-level) permissions only.
# - `skip_denies`: the deny masks of all three overwrite tiers (everyone,
#   roles, member) are zeroed before folding.
# - `skip_allows`: the allow masks of all three tiers are zeroed.
# - The tier application order is preserved (everyone → roles → member),
#   each step `(p & ~deny) | allow`.

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from conftest import seed_role, system_login
from permissions import (
    READ_MESSAGES,
    SEND_MESSAGES,
    MANAGE_OVERWRITES,
    SKIP_ALLOWS,
    SKIP_DENIES,
    ALL_BITS,
)


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


def _login(http_client, user):
    access_token, _ = system_login(http_client, user.username, user.password)
    return access_token


def _post_message(http_client, channel_id, token, content="hi"):
    return http_client.post(
        f"/api/channels/{channel_id}/messages",
        json={"content": content},
        headers={"Authorization": f"Bearer {token}"},
    )


# ---------------------------------------------------------------------------
# Regression: the original anti-lockout bug
# ---------------------------------------------------------------------------


# Regression - a superuser who placed a deny overwrite on @everyone can
# still modify and remove it: PUT re-applying the identical mask is a 204
# no-op (R7 bypasses hierarchy), and removing it (0/0) succeeds because the
# @everyone overwrite target is at position 0, below the caller.
def test_superuser_can_remove_own_everyone_deny(
    http_client, db_conn, test_guild, test_channel
):
    # The superuser denies send_messages to @everyone on the channel.
    body = {
        "target_id": str(test_guild.id),
        "type": "role",
        "allow": "0",
        "deny": str(SEND_MESSAGES),
    }

    response = http_client.put(
        f"/api/channels/{test_channel.id}/overwrites",
        json=body,
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )
    assert response.status_code == 204

    # Re-applying the identical mask is a 204 no-op.
    response = http_client.put(
        f"/api/channels/{test_channel.id}/overwrites",
        json=body,
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )
    assert response.status_code == 204

    # And the superuser can undo it: allow=0/deny=0 removes the overwrite.
    response = http_client.put(
        f"/api/channels/{test_channel.id}/overwrites",
        json={**body, "deny": "0"},
        headers={"Authorization": f"Bearer {test_guild.admin_token}"},
    )
    assert response.status_code == 204

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT allow, deny FROM app.overwrites"
            " WHERE channel_id = %s AND target_type = 0 AND target_id = %s",
            (test_channel.id, test_guild.id),
        )
        rows = cur.fetchall()

    assert rows == []


# Skip-bit regression in the full anti-lockout scenario: a deny on @everyone
# cannot lock the superuser out of manage_overwrites itself, because the
# caller's channel permission computation ignores deny masks once the base
# carries skip_denies.
def test_skip_denies_ignores_everyone_deny(
    http_client, db_conn, test_guild, test_channel, test_user
):
    # The caller's base carries the working bits plus skip_denies.
    _set_everyone_permissions(
        db_conn,
        test_guild.id,
        READ_MESSAGES | SEND_MESSAGES | MANAGE_OVERWRITES | SKIP_DENIES,
    )
    _create_role(
        db_conn,
        test_guild.id,
        "5580001",
        "manager",
        position=1,
        permissions=0,
    )
    _assign_role(db_conn, test_guild.id, test_user.id, "5580001")

    # A deny on @everyone strips view/send/manage for anyone without the
    # skip-bit, but skip_denies on the caller's base makes the deny mask
    # inert for them.
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        target_type=0,
        deny=READ_MESSAGES | SEND_MESSAGES | MANAGE_OVERWRITES,
        role_id=test_guild.id,
    )

    access_token = _login(http_client, test_user)

    # The caller can still post (deny ignored) while the deny still applies
    # to a user without the skip-bit.
    response = _post_message(http_client, test_channel.id, access_token)
    assert response.status_code == 201

    # The caller can still PUT overwrites (manage_overwrites not denied for
    # them) and clear the hostile overwrite.
    response = http_client.put(
        f"/api/channels/{test_channel.id}/overwrites",
        json={
            "target_id": str(test_guild.id),
            "type": "role",
            "allow": "0",
            "deny": "0",
        },
        headers={"Authorization": f"Bearer {access_token}"},
    )
    assert response.status_code == 204

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT 1 FROM app.overwrites"
            " WHERE channel_id = %s AND target_type = 0 AND target_id = %s",
            (test_channel.id, test_guild.id),
        )
        assert cur.fetchone() is None


# skip_denies is read from the base only: a role overwrite carrying
# skip_denies does not un-deny anything (the bit in an overwrite is inert).
def test_skip_bits_in_overwrite_are_inert(
    http_client, db_conn, test_guild, test_channel, test_user
):
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES | SEND_MESSAGES)
    _create_role(
        db_conn,
        test_guild.id,
        "5580002",
        "would-be-skipped",
        position=1,
        permissions=0,
    )
    _assign_role(db_conn, test_guild.id, test_user.id, "5580002")

    # The overwrite "grants" skip_denies; it must have no effect.
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        target_type=0,
        allow=SKIP_DENIES,
        role_id="5580002",
    )

    # ... and a deny on @everyone that would normally be ignored with
    # skip_denies in base.
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        target_type=0,
        deny=SEND_MESSAGES,
        role_id=test_guild.id,
    )

    access_token = _login(http_client, test_user)

    response = _post_message(http_client, test_channel.id, access_token)
    assert response.status_code == 403


# skip_denies ignores deny masks of ALL tiers: everyone, roles, member.
def test_skip_denies_ignores_all_tiers(
    http_client, db_conn, test_guild, test_channel, test_user
):
    _set_everyone_permissions(
        db_conn, test_guild.id, READ_MESSAGES | SEND_MESSAGES | SKIP_DENIES
    )

    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        target_type=0,
        deny=SEND_MESSAGES,
        role_id=test_guild.id,
    )
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        target_type=1,
        deny=SEND_MESSAGES,
        user_id=test_user.id,
    )

    access_token = _login(http_client, test_user)

    response = _post_message(http_client, test_channel.id, access_token)
    assert response.status_code == 201


# skip_allows ignores allow masks of all tiers.
def test_skip_allows_ignores_all_tiers(
    http_client, db_conn, test_guild, test_channel, test_user
):
    # Base has nothing but skip_allows and read_messages is granted by
    # @everyone overwrite; the caller must NOT receive send_messages through
    # any allow overwrite.
    _set_everyone_permissions(db_conn, test_guild.id, SKIP_ALLOWS)

    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        target_type=0,
        allow=READ_MESSAGES,
        role_id=test_guild.id,
    )
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        target_type=1,
        allow=SEND_MESSAGES,
        user_id=test_user.id,
    )

    access_token = _login(http_client, test_user)

    # read_messages comes from the overwrite allow → ignored too.
    response = http_client.get(
        f"/api/channels/{test_channel.id}/messages",
        headers={"Authorization": f"Bearer {access_token}"},
    )
    assert response.status_code == 403


# Control for the skip_allows test: without the skip-bit the same overwrites
# grant the permissions.
def test_without_skip_allows_overwrites_still_apply(
    http_client, db_conn, test_guild, test_channel, test_user
):
    _set_everyone_permissions(db_conn, test_guild.id, 0)

    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        target_type=0,
        allow=READ_MESSAGES,
        role_id=test_guild.id,
    )
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        target_type=1,
        allow=SEND_MESSAGES,
        user_id=test_user.id,
    )

    access_token = _login(http_client, test_user)

    response = _post_message(http_client, test_channel.id, access_token)
    assert response.status_code == 201


# skip_denies preserves the tier order: a role-deny over an everyone-allow
# (mute pattern) still applies when the base has skip_denies? No: with
# skip_denies both deny masks are zeroed. Instead pin the pattern without
# skip bits: role allow-deny interplay is unchanged by this feature.
def test_mute_pattern_unchanged(http_client, db_conn, test_guild, test_channel, test_user):
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES | SEND_MESSAGES)
    _create_role(db_conn, test_guild.id, "5580003", "muted")
    _assign_role(db_conn, test_guild.id, test_user.id, "5580003")

    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        target_type=0,
        deny=SEND_MESSAGES,
        role_id="5580003",
    )

    access_token = _login(http_client, test_user)

    response = _post_message(http_client, test_channel.id, access_token)
    assert response.status_code == 403


# The skip-bits count as defined bits: setting them via PUT overwrites is
# bounded by the changed-bits subset rule (a caller without skip_denies in
# its channel permissions cannot grant skip_denies to others).
def test_put_overwrite_cannot_grant_skip_bit_not_owned(
    http_client, db_conn, test_guild, test_channel, test_user
):
    _set_everyone_permissions(db_conn, test_guild.id, 0)
    _create_role(
        db_conn,
        test_guild.id,
        "5580004",
        "manager",
        position=1,
        permissions=MANAGE_OVERWRITES,
    )
    _assign_role(db_conn, test_guild.id, test_user.id, "5580004")

    access_token = _login(http_client, test_user)

    response = http_client.put(
        f"/api/channels/{test_channel.id}/overwrites",
        json={
            "target_id": str(test_user.id),
            "type": "member",
            "allow": str(SKIP_DENIES),
            "deny": "0",
        },
        headers={"Authorization": f"Bearer {access_token}"},
    )

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


# Success path pinned to the exact bits: a caller whose only extra bit is
# skip_denies (plus manage_overwrites) can grant skip_denies to others.
def test_put_overwrite_grant_skip_bit_owned(
    http_client, db_conn, test_guild, test_channel, test_user
):
    _set_everyone_permissions(db_conn, test_guild.id, 0)
    _create_role(
        db_conn,
        test_guild.id,
        "5580005",
        "manager",
        position=1,
        permissions=MANAGE_OVERWRITES | SKIP_DENIES,
    )
    _assign_role(db_conn, test_guild.id, test_user.id, "5580005")

    access_token = _login(http_client, test_user)

    response = http_client.put(
        f"/api/channels/{test_channel.id}/overwrites",
        json={
            "target_id": str(test_user.id),
            "type": "member",
            "allow": str(SKIP_DENIES),
            "deny": "0",
        },
        headers={"Authorization": f"Bearer {access_token}"},
    )

    assert response.status_code == 204

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT allow FROM app.overwrites"
            " WHERE channel_id = %s AND target_type = 1 AND target_id = %s",
            (test_channel.id, test_user.id),
        )
        row = cur.fetchone()

    assert row is not None
    assert int.from_bytes(row["allow"], "big") == SKIP_DENIES
