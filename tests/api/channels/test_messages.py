import sys
from pathlib import Path

import pytest

from conftest import CONFIG, seed_role, system_create_channel

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from permissions import READ_MESSAGES, SEND_MESSAGES


# R1
def test_get_messages_unauthorized(http_client, test_channel):
    response = http_client.get(f"/api/channels/{test_channel.id}/messages")

    assert response.status_code == 401


def test_get_messages_unknown_parameter(http_client, test_channel, test_session):
    response = http_client.get(
        f"/api/channels/{test_channel.id}/messages",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
        },
        params={
            "foobar": 2,
        },
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Unknown parameter"


@pytest.mark.parametrize(
    "param_key,param_value",
    [
        ("limit", "foo"),
        ("before", "foo"),
        ("after", "foo"),
    ],
)
def test_get_messages_bad_parameter(
    http_client, test_channel, test_session, param_key, param_value
):
    response = http_client.get(
        f"/api/channels/{test_channel.id}/messages",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
        },
        params={
            param_key: param_value,
        },
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == f"Bad '{param_key}' parameter"


def test_get_non_existent_channel_messages(http_client, test_session):
    response = http_client.get(
        "/api/channels/1/messages",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
        },
    )

    assert response.status_code == 404

    body = response.json()
    assert body["message"] == "Channel not found"


def test_get_messages(http_client, test_channel, test_message, test_session):
    response = http_client.get(
        f"/api/channels/{test_channel.id}/messages",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
        },
    )

    assert response.status_code == 200

    body = response.json()
    assert len(body) == 1

    message = body[0]
    assert message["id"] == test_message.id
    assert message["channel_id"] == test_channel.id
    assert message["content"] == test_message.content


def insert_messages(db_conn, channel_id, author_id, ids):
    with db_conn.cursor() as cur:
        for mid in ids:
            cur.execute(
                "INSERT INTO app.messages (id, channel_id, guild_id, author_id, content) "
                "SELECT %s, c.id, c.guild_id, %s, %s FROM app.channels c WHERE c.id = %s;",
                (str(mid), author_id, f"msg-{mid}", channel_id),
            )


def _get_messages_raw(http_client, test_channel, test_session, **params):
    return http_client.get(
        f"/api/channels/{test_channel.id}/messages",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
        },
        params=params,
    )


def _get_messages(http_client, test_channel, test_session, **params):
    response = _get_messages_raw(http_client, test_channel, test_session, **params)

    assert response.status_code == 200

    return response.json()


# R2 - 'before', 'after' and 'around' are mutually exclusive


@pytest.mark.parametrize(
    "first_param,second_param",
    [
        ("before", "after"),
        ("before", "around"),
        ("after", "around"),
    ],
)
def test_get_messages_mutually_exclusive_params(
    http_client, test_channel, test_session, first_param, second_param
):
    response = _get_messages_raw(
        http_client,
        test_channel,
        test_session,
        **{first_param: 2, second_param: 2},
    )

    assert response.status_code == 400

    body = response.json()
    assert (
        body["message"]
        == "Parameters 'before', 'after' and 'around' are mutually exclusive"
    )


def test_get_messages_last(http_client, db_conn, test_channel, test_user, test_session):
    insert_messages(db_conn, test_channel.id, test_user.id, [1, 2, 3, 4, 5])

    body = _get_messages(http_client, test_channel, test_session)

    assert [m["id"] for m in body] == ["1", "2", "3", "4", "5"]
    assert [m["content"] for m in body] == ["msg-1", "msg-2", "msg-3", "msg-4", "msg-5"]


def test_get_messages_last_limit(
    http_client, db_conn, test_channel, test_user, test_session
):
    insert_messages(db_conn, test_channel.id, test_user.id, [1, 2, 3, 4, 5])

    body = _get_messages(http_client, test_channel, test_session, limit=2)

    assert [m["id"] for m in body] == ["4", "5"]


def test_get_messages_before(
    http_client, db_conn, test_channel, test_user, test_session
):
    insert_messages(db_conn, test_channel.id, test_user.id, [1, 2, 3, 4, 5])

    body = _get_messages(http_client, test_channel, test_session, before=4)

    assert [m["id"] for m in body] == ["1", "2", "3"]


def test_get_messages_after(
    http_client, db_conn, test_channel, test_user, test_session
):
    insert_messages(db_conn, test_channel.id, test_user.id, [1, 2, 3, 4, 5])

    body = _get_messages(http_client, test_channel, test_session, after=2)

    assert [m["id"] for m in body] == ["3", "4", "5"]


def test_get_messages_around(
    http_client, db_conn, test_channel, test_user, test_session
):
    insert_messages(db_conn, test_channel.id, test_user.id, [1, 2, 3, 4, 5])

    body = _get_messages(http_client, test_channel, test_session, around=3, limit=5)

    assert [m["id"] for m in body] == ["1", "2", "3", "4", "5"]


def test_get_messages_around_partial(
    http_client, db_conn, test_channel, test_user, test_session
):
    insert_messages(db_conn, test_channel.id, test_user.id, [1, 2, 3, 4, 5])

    body = _get_messages(http_client, test_channel, test_session, around=1, limit=4)

    assert [m["id"] for m in body] == ["1", "2", "3"]


# Permissions are 16-byte big-endian u128 bitmasks.


def _post_message(http_client, test_session, channel_id, json=None, **kwargs):
    headers = kwargs.pop("headers", None)

    if headers is None:
        headers = {"Authorization": f"Bearer {test_session.access_token}"}

    return http_client.post(
        f"/api/channels/{channel_id}/messages",
        headers=headers,
        json={"content": "Hello, world!"} if json is None else json,
        **kwargs,
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
            "INSERT INTO app.member_roles (guild_id, user_id, role_id)"
            " VALUES (%s, %s, %s)",
            (guild_id, user_id, role_id),
        )


def _create_user(db_conn, user_id, username):
    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.users (id, username) VALUES (%s, %s)",
            (user_id, username),
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


def test_post_messages(db_conn, http_client, test_channel, test_session):
    response = _post_message(http_client, test_session, test_channel.id)

    assert response.status_code == 201

    body = response.json()
    message_id = body.get("id")

    assert message_id is not None

    with db_conn.cursor() as cur:
        cur.execute(f"SELECT content FROM app.messages WHERE id = '{message_id}'")
        msg = cur.fetchone()

        assert msg["content"] == "Hello, world!"


# R1 - POST /api/channels/{channel_id}/messages requires application/json
# content type and a non-empty body


def test_post_messages_bad_content_type(http_client, test_channel, test_session):
    response = http_client.post(
        f"/api/channels/{test_channel.id}/messages",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
            "Content-Type": "text/plain",
        },
        content="Hello, world!",
    )

    assert response.status_code == 415

    body = response.json()
    assert body["message"] == "Unsupported Media Type"


def test_post_messages_bad_json(http_client, test_channel, test_session):
    response = http_client.post(
        f"/api/channels/{test_channel.id}/messages",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
            "Content-Type": "application/json",
        },
        content=b"{not json",
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Bad JSON"


def test_post_messages_non_object_body(http_client, test_channel, test_session):
    response = http_client.post(
        f"/api/channels/{test_channel.id}/messages",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
            "Content-Type": "application/json",
        },
        content=b"[1, 2]",
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Expected an object"


# R5 - "content" must be present, a string, valid UTF-8; forbidden codepoints
# are stripped; after stripping the content is not empty and not too long


def test_post_messages_missing_content(http_client, test_channel, test_session):
    response = _post_message(http_client, test_session, test_channel.id, json={})

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'content' is missing"


def test_post_messages_content_not_a_string(http_client, test_channel, test_session):
    response = _post_message(
        http_client, test_session, test_channel.id, json={"content": 42}
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'content' is not a string"


def test_post_messages_empty_content(http_client, test_channel, test_session):
    response = _post_message(http_client, test_session, test_channel.id, json={"content": ""})

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'content' is empty"


def test_post_messages_content_too_long(http_client, test_channel, test_session):
    max_codepoints = CONFIG["api"]["messages"]["max_codepoints"]

    response = _post_message(
        http_client,
        test_session,
        test_channel.id,
        json={"content": "a" * (max_codepoints + 1)},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'content' is too long"


def test_post_messages_content_max_length(http_client, test_channel, test_session):
    max_codepoints = CONFIG["api"]["messages"]["max_codepoints"]

    response = _post_message(
        http_client, test_session, test_channel.id, json={"content": "a" * max_codepoints}
    )

    assert response.status_code == 201


def test_post_messages_content_invalid_utf8(http_client, test_channel, test_session):
    # invalid UTF-8 inside a JSON string is rejected by the JSON parser
    response = http_client.post(
        f"/api/channels/{test_channel.id}/messages",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
            "Content-Type": "application/json",
        },
        content=b'{"content": "\xff\xfe"}',
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "Bad JSON"


def test_post_messages_content_strips_forbidden_codepoints(
    http_client, test_channel, test_session
):
    response = _post_message(
        http_client, test_session, test_channel.id, json={"content": "a\u200Bb\u202Ec\u2800d\ue000e\rf"}
    )

    assert response.status_code == 201

    message_id = response.json()["id"]

    stored = http_client.get(
        f"/api/messages/{message_id}",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert stored.status_code == 200
    assert stored.json()["content"] == "abcdef"


def test_post_messages_content_normalized(http_client, test_channel, test_session):
    response = _post_message(
        http_client,
        test_session,
        test_channel.id,
        json={"content": "\uFF21\uFF22 \uFB01"},  # fullwidth "AB" + "fi" ligature
    )

    assert response.status_code == 201

    message_id = response.json()["id"]

    stored = http_client.get(
        f"/api/messages/{message_id}",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert stored.status_code == 200
    assert stored.json()["content"] == "AB fi"


def test_post_messages_content_keeps_newline_tab_and_bidi_marks(
    http_client, test_channel, test_session
):
    content = "a\nb\tc\u200Dd\u200Ce\u200Ff\u200Eg\u2066h\u2069i"

    response = _post_message(http_client, test_session, test_channel.id, json={"content": content})

    assert response.status_code == 201

    message_id = response.json()["id"]

    stored = http_client.get(
        f"/api/messages/{message_id}",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert stored.status_code == 200
    assert stored.json()["content"] == content


def test_post_messages_content_keeps_zwj_emoji(http_client, test_channel, test_session):
    content = "family: \U0001F468\u200D\U0001F469\u200D\U0001F467"

    response = _post_message(http_client, test_session, test_channel.id, json={"content": content})

    assert response.status_code == 201

    message_id = response.json()["id"]

    stored = http_client.get(
        f"/api/messages/{message_id}",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert stored.status_code == 200
    assert stored.json()["content"] == content


def test_post_messages_content_keeps_tag_flag(http_client, test_channel, test_session):
    content = "flags: \U0001F3F4\U000E0067\U000E0062\U000E0073\U000E0063\U000E0074"

    response = _post_message(http_client, test_session, test_channel.id, json={"content": content})

    assert response.status_code == 201

    message_id = response.json()["id"]

    stored = http_client.get(
        f"/api/messages/{message_id}",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert stored.status_code == 200
    assert stored.json()["content"] == content


def test_post_messages_content_only_forbidden_codepoints_is_empty(
    http_client, test_channel, test_session
):
    response = _post_message(
        http_client, test_session, test_channel.id, json={"content": "\u200B\u202E"}
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'content' is empty"


def test_post_messages_content_limit_counts_after_stripping(
    http_client, test_channel, test_session
):
    max_codepoints = CONFIG["api"]["messages"]["max_codepoints"]

    response = _post_message(
        http_client,
        test_session,
        test_channel.id,
        json={"content": "a" * max_codepoints + "\u200B"},
    )

    assert response.status_code == 201


# R6/R7 - optional reply_to_id must reference a live message in the same channel


def test_post_messages_with_reply_to_id(db_conn, http_client, test_channel, test_message, test_session):
    response = _post_message(
        http_client,
        test_session,
        test_channel.id,
        json={"content": "a reply", "reply_to_id": test_message.id},
    )

    assert response.status_code == 201

    message_id = response.json()["id"]

    stored = http_client.get(
        f"/api/messages/{message_id}",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert stored.status_code == 200
    assert stored.json()["reply_to_id"] == test_message.id


def test_post_messages_reply_to_id_explicit_null(http_client, test_channel, test_session):
    response = _post_message(
        http_client,
        test_session,
        test_channel.id,
        json={"content": "no reply", "reply_to_id": None},
    )

    assert response.status_code == 201

    message_id = response.json()["id"]

    stored = http_client.get(
        f"/api/messages/{message_id}",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert stored.status_code == 200
    assert stored.json()["reply_to_id"] is None


def test_post_messages_reply_to_id_in_other_channel(
    db_conn, http_client, test_guild, test_channel, test_message, test_session
):
    other_channel = system_create_channel(
        http_client, test_guild.id, name="OtherChannel", admin_token=test_guild.admin_token
    )

    response = _post_message(
        http_client,
        test_session,
        other_channel.id,
        json={"content": "cross-channel reply", "reply_to_id": test_message.id},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'reply_to_id' is invalid"


def test_post_messages_reply_to_id_non_existent(http_client, test_channel, test_session):
    response = _post_message(
        http_client,
        test_session,
        test_channel.id,
        json={"content": "a reply", "reply_to_id": "1"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'reply_to_id' is invalid"


def test_post_messages_reply_to_id_deleted_target(
    db_conn, http_client, test_channel, test_message, test_session
):
    with db_conn.cursor() as cur:
        cur.execute(
            "UPDATE app.messages SET content = '', author_id = NULL, deleted_at = now()"
            " WHERE id = %s",
            (int(test_message.id),),
        )

    response = _post_message(
        http_client,
        test_session,
        test_channel.id,
        json={"content": "a reply", "reply_to_id": test_message.id},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'reply_to_id' is invalid"


def test_post_messages_reply_to_id_not_a_string(http_client, test_channel, test_session):
    response = _post_message(
        http_client,
        test_session,
        test_channel.id,
        json={"content": "a reply", "reply_to_id": 12345},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'reply_to_id' is not a string"


def test_post_messages_reply_to_id_non_numeric_string(http_client, test_channel, test_session):
    response = _post_message(
        http_client,
        test_session,
        test_channel.id,
        json={"content": "a reply", "reply_to_id": "not-a-number"},
    )

    assert response.status_code == 400

    body = response.json()
    assert body["message"] == "'reply_to_id' is invalid"


# R4 - POST /api/channels/{channel_id}/messages requires send_messages
def test_post_messages_forbidden_without_send_messages(
    db_conn, http_client, test_guild, test_channel, test_session
):
    # @everyone has only read_messages
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES)

    response = _post_message(http_client, test_session, test_channel.id)

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


def test_post_messages_allowed_by_assigned_role_permissions(
    db_conn, http_client, test_guild, test_user, test_channel, test_session
):
    # @everyone has only read_messages, but the assigned role grants send_messages
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES)

    _create_role(db_conn, test_guild.id, "1111111", "mods", permissions=SEND_MESSAGES)
    _assign_role(db_conn, test_guild.id, test_user.id, "1111111")

    response = _post_message(http_client, test_session, test_channel.id)

    assert response.status_code == 201


def test_post_messages_everyone_overwrite_deny(
    db_conn, http_client, test_guild, test_channel, test_session
):
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        0,
        role_id=test_guild.id,
        deny=SEND_MESSAGES,
    )

    response = _post_message(http_client, test_session, test_channel.id)

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


def test_post_messages_role_overwrite_deny_for_assigned_role(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    _create_role(db_conn, test_guild.id, "1111111", "muted")
    _assign_role(db_conn, test_guild.id, test_user.id, "1111111")

    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        0,
        role_id="1111111",
        deny=SEND_MESSAGES,
    )

    response = _post_message(http_client, test_session, test_channel.id)

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


def test_post_messages_role_overwrite_ignored_for_other_roles(
    db_conn, http_client, test_guild, test_channel, test_session
):
    # the user does not have this role, so the overwrite must not apply
    _create_role(db_conn, test_guild.id, "1111111", "muted")

    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        0,
        role_id="1111111",
        deny=SEND_MESSAGES,
    )

    response = _post_message(http_client, test_session, test_channel.id)

    assert response.status_code == 201


def test_post_messages_role_overwrites_allow_wins_over_deny(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    # role overwrites are folded: single allow wins over a single deny
    _create_role(db_conn, test_guild.id, "1111111", "mods")
    _create_role(db_conn, test_guild.id, "2222222", "muted")

    _assign_role(db_conn, test_guild.id, test_user.id, "1111111")
    _assign_role(db_conn, test_guild.id, test_user.id, "2222222")

    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        0,
        role_id="1111111",
        allow=SEND_MESSAGES,
    )
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        0,
        role_id="2222222",
        deny=SEND_MESSAGES,
    )

    response = _post_message(http_client, test_session, test_channel.id)

    assert response.status_code == 201


def test_post_messages_role_overwrite_allow_overrides_everyone_deny(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    _create_role(db_conn, test_guild.id, "1111111", "mods")

    _assign_role(db_conn, test_guild.id, test_user.id, "1111111")

    # step 1: @everyone overwrite denies send_messages
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        0,
        role_id=test_guild.id,
        deny=SEND_MESSAGES,
    )
    # step 2: role overwrite re-allows it
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        0,
        role_id="1111111",
        allow=SEND_MESSAGES,
    )

    response = _post_message(http_client, test_session, test_channel.id)

    assert response.status_code == 201


def test_post_messages_member_overwrite_allow_overrides_role_deny(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    _create_role(db_conn, test_guild.id, "1111111", "muted")

    _assign_role(db_conn, test_guild.id, test_user.id, "1111111")

    # step 2: role overwrite denies send_messages
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        0,
        role_id="1111111",
        deny=SEND_MESSAGES,
    )
    # step 3: member overwrite re-allows it
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        1,
        user_id=test_user.id,
        allow=SEND_MESSAGES,
    )

    response = _post_message(http_client, test_session, test_channel.id)

    assert response.status_code == 201


def test_post_messages_member_overwrite_deny_overrides_role_allow(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    _create_role(db_conn, test_guild.id, "1111111", "mods")

    _assign_role(db_conn, test_guild.id, test_user.id, "1111111")

    # step 2: role overwrite allows send_messages
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        0,
        role_id="1111111",
        allow=SEND_MESSAGES,
    )
    # step 3: member overwrite denies it
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        1,
        user_id=test_user.id,
        deny=SEND_MESSAGES,
    )

    response = _post_message(http_client, test_session, test_channel.id)

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


def test_post_messages_member_overwrite_of_other_user_ignored(
    db_conn, http_client, test_guild, test_channel, test_session
):
    other_user_id = "8888888"
    _create_user(db_conn, other_user_id, "other")

    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        1,
        user_id=other_user_id,
        deny=SEND_MESSAGES,
    )

    response = _post_message(http_client, test_session, test_channel.id)

    assert response.status_code == 201


def test_post_messages_overwrites_apply_only_to_their_channel(
    db_conn, http_client, test_guild, test_channel, test_session
):
    other_channel_id = "9523144"

    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.channels (id, guild_id, name)" " VALUES (%s, %s, %s)",
            (other_channel_id, test_guild.id, "OtherChannel"),
        )

    _add_overwrite(
        db_conn,
        test_guild.id,
        other_channel_id,
        0,
        role_id=test_guild.id,
        deny=SEND_MESSAGES,
    )

    response = _post_message(http_client, test_session, test_channel.id)

    assert response.status_code == 201


# R3 - GET /api/channels/{channel_id}/messages requires read_messages


def test_get_messages_forbidden_without_read_messages(
    db_conn, http_client, test_guild, test_channel, test_session
):
    # @everyone has only send_messages
    _set_everyone_permissions(db_conn, test_guild.id, SEND_MESSAGES)

    response = _get_messages_raw(http_client, test_channel, test_session)

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


def test_get_messages_allowed_with_read_messages(
    db_conn, http_client, test_guild, test_channel, test_session
):
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES)

    response = _get_messages_raw(http_client, test_channel, test_session)

    assert response.status_code == 200


def test_get_messages_allowed_by_assigned_role_permissions(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    # @everyone has no permissions, but the assigned role grants read_messages
    _set_everyone_permissions(db_conn, test_guild.id, 0)

    _create_role(db_conn, test_guild.id, "1111111", "viewers", permissions=READ_MESSAGES)
    _assign_role(db_conn, test_guild.id, test_user.id, "1111111")

    response = _get_messages_raw(http_client, test_channel, test_session)

    assert response.status_code == 200


def test_get_messages_everyone_overwrite_deny(
    db_conn, http_client, test_guild, test_channel, test_session
):
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        0,
        role_id=test_guild.id,
        deny=READ_MESSAGES,
    )

    response = _get_messages_raw(http_client, test_channel, test_session)

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


def test_get_messages_role_overwrite_allow_overrides_everyone_deny(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    _create_role(db_conn, test_guild.id, "1111111", "viewers")

    _assign_role(db_conn, test_guild.id, test_user.id, "1111111")

    # step 1: @everyone overwrite denies read_messages
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        0,
        role_id=test_guild.id,
        deny=READ_MESSAGES,
    )
    # step 2: role overwrite re-allows it
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        0,
        role_id="1111111",
        allow=READ_MESSAGES,
    )

    response = _get_messages_raw(http_client, test_channel, test_session)

    assert response.status_code == 200


def test_get_messages_member_overwrite_deny_overrides_role_allow(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    _create_role(db_conn, test_guild.id, "1111111", "viewers")

    _assign_role(db_conn, test_guild.id, test_user.id, "1111111")

    # step 2: role overwrite allows read_messages
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        0,
        role_id="1111111",
        allow=READ_MESSAGES,
    )
    # step 3: member overwrite denies it
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        1,
        user_id=test_user.id,
        deny=READ_MESSAGES,
    )

    response = _get_messages_raw(http_client, test_channel, test_session)

    assert response.status_code == 403

    body = response.json()
    assert body["message"] == "Missing permissions"


def test_get_messages_member_overwrite_allow_overrides_everyone_deny(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    # step 1: @everyone overwrite denies read_messages
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        0,
        role_id=test_guild.id,
        deny=READ_MESSAGES,
    )
    # step 3: member overwrite re-allows it
    _add_overwrite(
        db_conn,
        test_guild.id,
        test_channel.id,
        1,
        user_id=test_user.id,
        allow=READ_MESSAGES,
    )

    response = _get_messages_raw(http_client, test_channel, test_session)

    assert response.status_code == 200


def test_get_messages_overwrites_apply_only_to_their_channel(
    db_conn, http_client, test_guild, test_channel, test_session
):
    other_channel_id = "9523144"

    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.channels (id, guild_id, name)" " VALUES (%s, %s, %s)",
            (other_channel_id, test_guild.id, "OtherChannel"),
        )

    _add_overwrite(
        db_conn,
        test_guild.id,
        other_channel_id,
        0,
        role_id=test_guild.id,
        deny=READ_MESSAGES,
    )

    response = _get_messages_raw(http_client, test_channel, test_session)

    assert response.status_code == 200
