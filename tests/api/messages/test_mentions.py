# Tests for message mentions (parse from content, persist, project, allowed_mentions).
#
# POST  /api/channels/{channel_id}/messages - R10 (parse) / R11 (allowed_mentions)
# PATCH /api/messages/{message_id}          - R7 (recompute, no allowed_mentions)
# GET   /api/messages/{message_id}          - R5 (projection)
# GET   /api/channels/{channel_id}/messages - R5 (projection)
#
# Requirement numbering mirrors the route handlers.

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from conftest import CONFIG, seed_role, system_create_user

MAX_MENTION_USERS = CONFIG["api"]["messages"]["max_mention_users"]
MAX_MENTION_ROLES = CONFIG["api"]["messages"]["max_mention_roles"]


def auth_headers(session):
    return {"Authorization": f"Bearer {session.access_token}"}


def create_role(db_conn, guild_id, role_id, name="role", mentionable=True):
    seed_role(db_conn, guild_id, role_id, name, permissions=0, mentionable=mentionable)

    return str(role_id)


def post_message(http_client, session, channel_id, payload):
    return http_client.post(
        f"/api/channels/{channel_id}/messages",
        headers=auth_headers(session),
        json=payload,
    )


def patch_message(http_client, session, message_id, payload):
    return http_client.patch(
        f"/api/messages/{message_id}",
        headers=auth_headers(session),
        json=payload,
    )


def get_message(http_client, session, message_id):
    response = http_client.get(
        f"/api/messages/{message_id}", headers=auth_headers(session)
    )

    assert response.status_code == 200

    return response.json()


def mentions_of(body):
    return body["mentions"], body["mention_roles"], body["mention_everyone"]


# R10 - user mentions


def test_mention_user_basic(db_conn, http_client, test_channel, test_session):
    mentioned = system_create_user(http_client, username="mentioned")

    message_id = post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": f"hi <@{mentioned['id']}>!"},
    ).json()["id"]

    mentions, roles, everyone = mentions_of(get_message(http_client, test_session, message_id))

    assert mentions == [mentioned["id"]]
    assert roles == []
    assert everyone is False


def test_mention_user_legacy_bang_form(db_conn, http_client, test_channel, test_session):
    mentioned = system_create_user(http_client, username="legacy")

    message_id = post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": f"<@!{mentioned['id']}>"},
    ).json()["id"]

    mentions, _, _ = mentions_of(get_message(http_client, test_session, message_id))

    assert mentions == [mentioned["id"]]


def test_mention_user_dedup_and_order(db_conn, http_client, test_channel, test_session):
    a = system_create_user(http_client, username="dup_a")
    b = system_create_user(http_client, username="dup_b")

    message_id = post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": f"<@{a['id']}> <@{b['id']}> <@{a['id']}>"},
    ).json()["id"]

    mentions, _, _ = mentions_of(get_message(http_client, test_session, message_id))

    assert mentions == [a["id"], b["id"]]


def test_mention_user_unknown_id_dropped(db_conn, http_client, test_channel, test_session):
    message_id = post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": "hi <@999999999999>"},
    ).json()["id"]

    mentions, _, _ = mentions_of(get_message(http_client, test_session, message_id))

    assert mentions == []


def test_mention_user_deleted_id_dropped(db_conn, http_client, test_channel, test_session):
    victim = system_create_user(http_client, username="deleted_user")

    with db_conn.cursor() as cur:
        cur.execute(
            "UPDATE app.users SET deleted_at = now(), password_hash = NULL,"
            " display_name = NULL, avatar_data = NULL, avatar_hash = NULL"
            " WHERE id = %s",
            (int(victim["id"]),),
        )

    message_id = post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": f"hi <@{victim['id']}>"},
    ).json()["id"]

    mentions, _, _ = mentions_of(get_message(http_client, test_session, message_id))

    assert mentions == []


def test_mention_user_too_many(db_conn, http_client, test_channel, test_session):
    ids = " ".join(f"<@{1000 + i}>" for i in range(MAX_MENTION_USERS + 1))

    response = post_message(
        http_client, test_session, test_channel.id, {"content": ids}
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'mentions' is too long"


# R10 - role mentions


def test_mention_role_in_guild(db_conn, http_client, test_guild, test_channel, test_session):
    role_id = create_role(db_conn, test_guild.id, 424242)

    message_id = post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": f"hey <@&{role_id}>"},
    ).json()["id"]

    _, roles, _ = mentions_of(get_message(http_client, test_session, message_id))

    assert roles == [role_id]


def test_mention_role_foreign_guild_dropped(db_conn, http_client, test_guild, test_channel, test_session):
    # A role that belongs to a different guild must not be mentioned here.
    other_role = 424243

    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.guilds (id, name) VALUES (%s, 'OtherGuild')",
            (999999,),
        )
        cur.execute(
            "INSERT INTO app.roles (id, guild_id, name, position, permissions, mentionable)"
            " VALUES (%s, %s, 'foreign', 0, %s, true)",
            (other_role, 999999, bytes(16)),
        )

    message_id = post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": f"hey <@&{other_role}>"},
    ).json()["id"]

    _, roles, _ = mentions_of(get_message(http_client, test_session, message_id))

    assert roles == []


def test_mention_role_unknown_dropped(db_conn, http_client, test_channel, test_session):
    message_id = post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": "hey <@&888888888>"},
    ).json()["id"]

    _, roles, _ = mentions_of(get_message(http_client, test_session, message_id))

    assert roles == []


def test_mention_role_too_many(db_conn, http_client, test_guild, test_channel, test_session):
    ids = " ".join(f"<@&{500000 + i}>" for i in range(MAX_MENTION_ROLES + 1))

    response = post_message(
        http_client, test_session, test_channel.id, {"content": ids}
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'mentions' is too long"


# R10 - @everyone / @here


def test_mention_everyone_and_here(db_conn, http_client, test_channel, test_session):
    message_id = post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": "@everyone ping and @here too"},
    ).json()["id"]

    _, _, everyone = mentions_of(get_message(http_client, test_session, message_id))

    assert everyone is True


def test_mention_everyone_inside_word_not_matched(db_conn, http_client, test_channel, test_session):
    message_id = post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": "foo@everything and bar"},
    ).json()["id"]

    _, _, everyone = mentions_of(get_message(http_client, test_session, message_id))

    assert everyone is False


# R10 - channel mention unsupported (stays plain text)


def test_channel_mention_not_supported(db_conn, http_client, test_channel, test_session):
    message_id = post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": f"see <#{test_channel.id}>"},
    ).json()["id"]

    body = get_message(http_client, test_session, message_id)

    assert body["mentions"] == []
    assert body["mention_roles"] == []
    assert body["mention_everyone"] is False


# R5 - list projection


def test_list_projects_mentions(db_conn, http_client, test_channel, test_session):
    mentioned = system_create_user(http_client, username="listed_mention")

    message_id = post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": f"<@{mentioned['id']}> @everyone"},
    ).json()["id"]

    response = http_client.get(
        f"/api/channels/{test_channel.id}/messages", headers=auth_headers(test_session)
    )

    assert response.status_code == 200

    matching = [m for m in response.json() if m["id"] == message_id]

    assert matching[0]["mentions"] == [mentioned["id"]]
    assert matching[0]["mention_everyone"] is True


# R11 - allowed_mentions


def test_allowed_mentions_parse_empty_suppresses_all(
    db_conn, http_client, test_channel, test_session
):
    mentioned = system_create_user(http_client, username="suppressed")

    message_id = post_message(
        http_client,
        test_session,
        test_channel.id,
        {
            "content": f"<@{mentioned['id']}> @everyone",
            "allowed_mentions": {"parse": []},
        },
    ).json()["id"]

    mentions, roles, everyone = mentions_of(get_message(http_client, test_session, message_id))

    assert mentions == []
    assert roles == []
    assert everyone is False


def test_allowed_mentions_parse_users_only(
    db_conn, http_client, test_guild, test_channel, test_session
):
    mentioned = system_create_user(http_client, username="users_only")
    role_id = create_role(db_conn, test_guild.id, 424250)

    message_id = post_message(
        http_client,
        test_session,
        test_channel.id,
        {
            "content": f"<@{mentioned['id']}> <@&{role_id}> @everyone",
            "allowed_mentions": {"parse": ["users"]},
        },
    ).json()["id"]

    mentions, roles, everyone = mentions_of(get_message(http_client, test_session, message_id))

    assert mentions == [mentioned["id"]]
    assert roles == []
    assert everyone is False


def test_allowed_mentions_explicit_users_list(
    db_conn, http_client, test_channel, test_session
):
    a = system_create_user(http_client, username="allow_a")
    b = system_create_user(http_client, username="allow_b")

    message_id = post_message(
        http_client,
        test_session,
        test_channel.id,
        {
            "content": f"<@{a['id']}> <@{b['id']}>",
            "allowed_mentions": {"users": [a["id"]]},
        },
    ).json()["id"]

    mentions, _, _ = mentions_of(get_message(http_client, test_session, message_id))

    assert mentions == [a["id"]]


def test_allowed_mentions_phantom_id_ignored(
    db_conn, http_client, test_channel, test_session
):
    a = system_create_user(http_client, username="phantom_a")

    message_id = post_message(
        http_client,
        test_session,
        test_channel.id,
        {
            "content": f"<@{a['id']}>",
            "allowed_mentions": {"users": [a["id"], "987654321"]},
        },
    ).json()["id"]

    mentions, _, _ = mentions_of(get_message(http_client, test_session, message_id))

    assert mentions == [a["id"]]


def test_allowed_mentions_parse_and_users_conflict(
    db_conn, http_client, test_channel, test_session
):
    response = post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": "hi", "allowed_mentions": {"parse": ["users"], "users": ["1"]}},
    )

    assert response.status_code == 400
    assert response.json()["message"] == (
        "'allowed_mentions.parse' is mutually exclusive with 'users' and 'roles'"
    )


def test_allowed_mentions_not_an_object(db_conn, http_client, test_channel, test_session):
    response = post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": "hi", "allowed_mentions": []},
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'allowed_mentions' is not an object"


# R7 - PATCH recomputes


def test_patch_recomputes_mentions(db_conn, http_client, test_channel, test_session):
    a = system_create_user(http_client, username="patch_a")
    b = system_create_user(http_client, username="patch_b")

    message_id = post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": f"<@{a['id']}>"},
    ).json()["id"]

    response = patch_message(
        http_client, test_session, message_id, {"content": f"<@{b['id']}> @everyone"}
    )

    assert response.status_code == 200

    mentions, roles, everyone = mentions_of(get_message(http_client, test_session, message_id))

    assert mentions == [b["id"]]
    assert everyone is True


def test_patch_can_remove_mentions(db_conn, http_client, test_channel, test_session):
    a = system_create_user(http_client, username="patch_rm")

    message_id = post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": f"<@{a['id']}>"},
    ).json()["id"]

    response = patch_message(
        http_client, test_session, message_id, {"content": "no mentions now"}
    )

    assert response.status_code == 200

    mentions, _, everyone = mentions_of(get_message(http_client, test_session, message_id))

    assert mentions == []
    assert everyone is False


def test_patch_ignores_allowed_mentions(db_conn, http_client, test_channel, test_session):
    a = system_create_user(http_client, username="patch_am")

    message_id = post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": "hi"},
    ).json()["id"]

    response = patch_message(
        http_client,
        test_session,
        message_id,
        {
            "content": f"<@{a['id']}>",
            "allowed_mentions": {"parse": []},
        },
    )

    assert response.status_code == 200

    mentions, _, _ = mentions_of(get_message(http_client, test_session, message_id))

    # PATCH does not honor allowed_mentions (it is not part of the edit path).
    assert mentions == [a["id"]]


# R10 - soft delete clears mentions


def test_soft_delete_clears_mentions(db_conn, http_client, test_channel, test_session):
    a = system_create_user(http_client, username="del_mention")

    message_id = post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": f"<@{a['id']}> @everyone"},
    ).json()["id"]

    response = http_client.delete(
        f"/api/messages/{message_id}", headers=auth_headers(test_session)
    )

    assert response.status_code == 204

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT mention_everyone, mention_user_ids, mention_role_ids"
            " FROM app.messages WHERE id = %s",
            (int(message_id),),
        )

        row = cur.fetchone()

    assert row["mention_everyone"] is False
    assert row["mention_user_ids"] == []
    assert row["mention_role_ids"] == []
