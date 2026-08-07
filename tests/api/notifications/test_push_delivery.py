# End-to-end push delivery tests: a created message must push an encrypted
# Web Push request to every subscription of a mentioned user, honoring the
# notification settings, `read_messages` rights, presence and the gone-subscription
# cleanup. The push service is the loopback mock (mock_push.py), so the request
# is inspected unencrypted at the transport level.

import base64
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))  # tests/
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # tests/api
sys.path.insert(0, str(Path(__file__).resolve().parent))  # tests/api/notifications

from conftest import (
    SYSTEM_HEADERS,
    seed_role,
    system_create_channel,
    system_create_guild,
    system_create_user,
    system_login,
)
from mock_push import ENDPOINT
from test_gateway import GatewayClient

SUB_URL = "/api/users/@me/push-subscriptions"


def auth(session):
    return {"Authorization": f"Bearer {session.access_token}"}


class Session:
    def __init__(self, access_token):
        self.access_token = access_token


def login(http_client, username):
    access_token, _ = system_login(http_client, username)

    return Session(access_token)


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


P256DH = "BGsX0fLhLEJH-Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT-NC4v4af5uO5-tKfA-eFivOM1drMV7Oy7ZAaDe_UfU"  # P-256 generator
AUTH = b64(b"\x44" * 16)


def subscribe(http_client, session, endpoint):
    response = http_client.post(
        SUB_URL,
        headers=auth(session),
        json={"endpoint": endpoint, "p256dh": P256DH, "auth": AUTH},
    )

    assert response.status_code == 201

    return response.json()["id"]


def post_message(http_client, session, channel_id, content):
    response = http_client.post(
        f"/api/channels/{channel_id}/messages",
        headers=auth(session),
        json={"content": content},
    )

    assert response.status_code == 201

    return response.json()["id"]


def wait_for_push(mock, count=1, timeout=8.0):
    deadline = time.monotonic() + timeout

    while time.monotonic() < deadline:
        if mock.count() >= count:
            return mock.all()

        time.sleep(0.05)

    pytest.fail(f"expected {count} push request(s), got {mock.count()}")


def expect_no_push(mock, timeout=2.0):
    time.sleep(timeout)

    assert mock.count() == 0, f"unexpected push request(s): {mock.all()}"


def create_role(db_conn, guild_id, role_id, mentionable=True):
    seed_role(db_conn, guild_id, role_id, "push_role", permissions=0, mentionable=mentionable)


def assign_role(db_conn, guild_id, user_id, role_id):
    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.member_roles (guild_id, user_id, role_id)"
            " VALUES (%s, %s, %s)",
            (guild_id, user_id, role_id),
        )


def set_guild_settings(http_client, session, guild_id, payload):
    response = http_client.patch(
        f"/api/users/@me/guilds/{guild_id}/notifications",
        headers=auth(session),
        json=payload,
    )

    assert response.status_code == 204


def set_channel_level(http_client, session, channel_id, level):
    response = http_client.patch(
        f"/api/users/@me/channels/{channel_id}/notifications",
        headers=auth(session),
        json={"level": level},
    )

    assert response.status_code == 204


def make_recipient(http_client):
    body = system_create_user(http_client, username="push_recipient")

    return body["id"], login(http_client, "push_recipient")


# ---------------------------------------------------------------------------


def test_mention_delivers_push(http_client, push_mock, test_session, test_channel):
    recipient_id, recipient = make_recipient(http_client)

    subscribe(http_client, recipient, f"{ENDPOINT}/push/mention")

    post_message(http_client, test_session, test_channel.id, f"hey <@{recipient_id}>")

    requests = wait_for_push(push_mock, 1)
    request = requests[0]

    assert request["path"] == "/push/mention"
    # The request is a real RFC 8291 message, not a plaintext JSON post.
    assert request["headers"]["content-encoding"] == "aes128gcm"
    assert "ttl" in request["headers"]
    assert request["headers"]["authorization"].startswith("vapid t=")
    # The body is longer than the 86-byte header alone (it carries ciphertext).
    assert len(request["body"]) > 86 + 16
    # The shape is salt(16) || rs(4)=4096 || idlen(1)=65 || keyid(65) || ct+tag.
    assert request["body"][16:20] == b"\x00\x00\x10\x00"
    assert request["body"][20] == 65


def test_level_nothing_suppresses(http_client, push_mock, test_session, test_channel):
    recipient_id, recipient = make_recipient(http_client)

    subscribe(http_client, recipient, f"{ENDPOINT}/push/nothing")
    set_channel_level(http_client, recipient, test_channel.id, "nothing")

    post_message(http_client, test_session, test_channel.id, f"hey <@{recipient_id}>")

    expect_no_push(push_mock)


def test_author_is_not_notified(
    http_client, push_mock, test_session, test_user, test_channel
):
    subscribe(http_client, test_session, f"{ENDPOINT}/push/self")

    post_message(http_client, test_session, test_channel.id, f"me <@{test_user.id}>")

    expect_no_push(push_mock)


def test_suppress_everyone_suppresses(
    http_client, push_mock, test_session, test_guild, test_channel
):
    _, recipient = make_recipient(http_client)

    subscribe(http_client, recipient, f"{ENDPOINT}/push/everyone")

    # Suppression only gates the mention kinds, so the level must be
    # `only_mentions` for it to have an effect (with `all_messages` the message
    # is delivered anyway).
    set_guild_settings(
        http_client,
        recipient,
        test_guild.id,
        {"level": "only_mentions", "suppress_everyone": True},
    )

    post_message(http_client, test_session, test_channel.id, "@everyone hello")

    expect_no_push(push_mock)


def test_everyone_delivers_under_only_mentions(
    http_client, push_mock, test_session, test_guild, test_channel
):
    _, recipient = make_recipient(http_client)

    subscribe(http_client, recipient, f"{ENDPOINT}/push/everyone-only")
    set_guild_settings(http_client, recipient, test_guild.id, {"level": "only_mentions"})

    post_message(http_client, test_session, test_channel.id, "@everyone hi")

    wait_for_push(push_mock, 1)


def test_everyone_delivers_without_suppression(
    http_client, push_mock, test_session, test_channel
):
    _, recipient = make_recipient(http_client)

    subscribe(http_client, recipient, f"{ENDPOINT}/push/everyone-ok")

    post_message(http_client, test_session, test_channel.id, "@everyone hi")

    wait_for_push(push_mock, 1)


def test_suppress_roles_suppresses(
    http_client, db_conn, push_mock, test_session, test_guild, test_channel
):
    recipient_id, recipient = make_recipient(http_client)

    subscribe(http_client, recipient, f"{ENDPOINT}/push/role")

    # As with `suppress_everyone`, the level must be `only_mentions` for the
    # flag to matter.
    set_guild_settings(
        http_client,
        recipient,
        test_guild.id,
        {"level": "only_mentions", "suppress_roles": True},
    )

    role_id = 424242
    create_role(db_conn, test_guild.id, role_id)
    assign_role(db_conn, test_guild.id, recipient_id, role_id)

    post_message(http_client, test_session, test_channel.id, f"role <@&{role_id}>")

    expect_no_push(push_mock)


def test_role_mention_delivers(
    http_client, db_conn, push_mock, test_session, test_guild, test_channel
):
    recipient_id, recipient = make_recipient(http_client)

    subscribe(http_client, recipient, f"{ENDPOINT}/push/role-ok")

    role_id = 424243
    create_role(db_conn, test_guild.id, role_id)
    assign_role(db_conn, test_guild.id, recipient_id, role_id)

    post_message(http_client, test_session, test_channel.id, f"role <@&{role_id}>")

    wait_for_push(push_mock, 1)


def test_role_mention_delivers_under_only_mentions(
    http_client, db_conn, push_mock, test_session, test_guild, test_channel
):
    recipient_id, recipient = make_recipient(http_client)

    subscribe(http_client, recipient, f"{ENDPOINT}/push/role-only")
    set_channel_level(http_client, recipient, test_channel.id, "only_mentions")

    role_id = 424244
    create_role(db_conn, test_guild.id, role_id)
    assign_role(db_conn, test_guild.id, recipient_id, role_id)

    post_message(http_client, test_session, test_channel.id, f"role <@&{role_id}>")

    wait_for_push(push_mock, 1)


# ---------------------------------------------------------------------------
# Level hierarchy: `all_messages` is the default and delivers without a mention
# ---------------------------------------------------------------------------


def test_all_messages_delivers_without_mention(
    http_client, push_mock, test_session, test_channel
):
    _, recipient = make_recipient(http_client)

    subscribe(http_client, recipient, f"{ENDPOINT}/push/all")

    # No settings row: the default level is `all_messages`.
    post_message(http_client, test_session, test_channel.id, "just a plain message")

    wait_for_push(push_mock, 1)


def test_only_mentions_skips_without_mention(
    http_client, push_mock, test_session, test_channel
):
    _, recipient = make_recipient(http_client)

    subscribe(http_client, recipient, f"{ENDPOINT}/push/only-skip")
    set_channel_level(http_client, recipient, test_channel.id, "only_mentions")

    post_message(http_client, test_session, test_channel.id, "no mention here")

    expect_no_push(push_mock)


def test_only_mentions_delivers_on_mention(
    http_client, push_mock, test_session, test_channel
):
    recipient_id, recipient = make_recipient(http_client)

    subscribe(http_client, recipient, f"{ENDPOINT}/push/only-mention")
    set_channel_level(http_client, recipient, test_channel.id, "only_mentions")

    post_message(http_client, test_session, test_channel.id, f"hey <@{recipient_id}>")

    wait_for_push(push_mock, 1)


def test_all_messages_ignores_suppression(
    http_client, push_mock, test_session, test_guild, test_channel
):
    _, recipient = make_recipient(http_client)

    subscribe(http_client, recipient, f"{ENDPOINT}/push/all-suppress")

    # `suppress_everyone` never mutes `all_messages`.
    set_guild_settings(http_client, recipient, test_guild.id, {"suppress_everyone": True})

    post_message(http_client, test_session, test_channel.id, "@everyone hello")

    wait_for_push(push_mock, 1)


def test_channel_override_only_mentions_beats_guild_all_messages(
    http_client, push_mock, test_session, test_channel
):
    _, recipient = make_recipient(http_client)

    subscribe(http_client, recipient, f"{ENDPOINT}/push/override")

    # The guild stays at the default `all_messages`; the channel override wins.
    set_channel_level(http_client, recipient, test_channel.id, "only_mentions")

    post_message(http_client, test_session, test_channel.id, "no mention here")

    expect_no_push(push_mock)


def test_read_messages_denied_skips(
    http_client, db_conn, push_mock, test_session, test_guild, test_channel
):
    from permissions import READ_MESSAGES

    recipient_id, recipient = make_recipient(http_client)

    subscribe(http_client, recipient, f"{ENDPOINT}/push/denied")

    # A member-specific overwrite that denies read_messages (allow mask none,
    # deny mask read_messages) wins over the base permissions.
    deny = READ_MESSAGES.to_bytes(16, "big")
    allow = (0).to_bytes(16, "big")
    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.overwrites"
            " (guild_id, channel_id, target_type, user_id, allow, deny)"
            " VALUES (%s, %s, 1, %s, %s, %s)",
            (test_guild.id, test_channel.id, recipient_id, allow, deny),
        )

    post_message(http_client, test_session, test_channel.id, f"hey <@{recipient_id}>")

    expect_no_push(push_mock)


def test_online_user_is_skipped(
    http_client, push_mock, test_session, test_channel
):
    recipient_id, recipient = make_recipient(http_client)

    subscribe(http_client, recipient, f"{ENDPOINT}/push/online")

    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": recipient.access_token}})
    assert ws.recv_json()["op"] == "hello"

    try:
        post_message(
            http_client, test_session, test_channel.id, f"hey <@{recipient_id}>"
        )

        # The user has an active gateway connection, so no push is sent.
        expect_no_push(push_mock)
    finally:
        ws.close()


def test_guild_push_disabled_suppresses_that_guild_only(
    http_client, push_mock, test_session, test_guild, test_channel
):
    recipient_id, recipient = make_recipient(http_client)

    subscribe(http_client, recipient, f"{ENDPOINT}/push/per-guild")

    other_guild = system_create_guild(http_client, name="OtherGuild")
    other_admin = system_create_user(
        http_client, username=f"og_admin_{other_guild.id}"
    )
    response = http_client.post(
        "/api/system/superuser",
        json={"guild_id": other_guild.id, "user_id": other_admin["id"]},
        headers=SYSTEM_HEADERS,
    )
    assert response.status_code == 201
    other_admin_token, _ = system_login(
        http_client, f"og_admin_{other_guild.id}"
    )
    other_channel = system_create_channel(
        http_client,
        other_guild.id,
        name="OtherChannel",
        admin_token=other_admin_token,
    )

    set_guild_settings(http_client, recipient, test_guild.id, {"push": False})

    # Guild A has push off: no push for a mention there.
    post_message(http_client, test_session, test_channel.id, f"hey <@{recipient_id}>")
    expect_no_push(push_mock)

    # Guild B is unaffected and still pushes.
    post_message(http_client, test_session, other_channel.id, f"hey <@{recipient_id}>")
    wait_for_push(push_mock, 1)

    # Toggling guild A back on restores its pushes; guild B stays unaffected.
    set_guild_settings(http_client, recipient, test_guild.id, {"push": True})

    post_message(http_client, test_session, test_channel.id, f"hey <@{recipient_id}>")
    wait_for_push(push_mock, 2)


def test_guild_push_default_is_enabled(
    http_client, push_mock, test_session, test_channel
):
    # No `guild_notification_settings` row means `push = true` (COALESCE default).
    recipient_id, recipient = make_recipient(http_client)

    subscribe(http_client, recipient, f"{ENDPOINT}/push/default-push")

    post_message(http_client, test_session, test_channel.id, f"hey <@{recipient_id}>")

    wait_for_push(push_mock, 1)


def test_gone_subscription_is_removed(
    http_client, push_mock, test_session, test_channel
):
    recipient_id, recipient = make_recipient(http_client)

    subscribe(http_client, recipient, f"{ENDPOINT}/push/gone")

    # The push service reports the subscription as gone on the next request.
    push_mock.queue_status(410)

    post_message(http_client, test_session, test_channel.id, f"hey <@{recipient_id}>")

    wait_for_push(push_mock, 1)

    # The dispatcher deletes the dead subscription; poll until it disappears.
    deadline = time.monotonic() + 8.0

    while time.monotonic() < deadline:
        listed = http_client.get(SUB_URL, headers=auth(recipient)).json()

        if listed == []:
            return

        time.sleep(0.1)

    pytest.fail("the gone subscription was not deleted")


def test_endpoint_takeover_redirects_push(
    http_client, push_mock, test_session, test_channel
):
    # One endpoint belongs to one account: after another account takes it over,
    # mentions of the old owner no longer push to that device, mentions of the
    # new owner do.
    recipient_id, recipient = make_recipient(http_client)

    shared = f"{ENDPOINT}/push/takeover"
    subscribe(http_client, recipient, shared)

    body = system_create_user(http_client, username="push_delivery_taker")
    taker_id = body["id"]
    taker = login(http_client, "push_delivery_taker")

    # Silence the taker's ambient `all_messages` traffic so the test only
    # observes mention-triggered pushes.
    set_channel_level(http_client, taker, test_channel.id, "only_mentions")

    # The second registration takes the endpoint over (still answered 201).
    subscribe(http_client, taker, shared)

    # The old owner's mention is not pushed anymore.
    post_message(http_client, test_session, test_channel.id, f"hey <@{recipient_id}>")
    expect_no_push(push_mock)

    # The new owner's mention is pushed to the same device.
    post_message(http_client, test_session, test_channel.id, f"hey <@{taker_id}>")
    wait_for_push(push_mock, 1)
