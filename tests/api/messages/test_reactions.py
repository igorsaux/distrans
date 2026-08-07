# Tests for /api/messages/{message_id}/reactions (PUT, DELETE) and
# /api/messages/{message_id}/reactions/users (GET). The aggregate
# GET /api/messages/{message_id}/reactions was removed: reactions are returned
# inline with the message (GET /api/messages/{id} and the channel page).
#
# GET       - removed: a GET on the path is 405 Allow: PUT, DELETE
# GET users - R1 logged in; R2 message exists; R3 read_messages on the channel;
#             R4 custom emoji belongs to the message's guild; R5 query params
#             (emoji_id XOR unicode_emoji, keyset-paginated ids)
# PUT       - R1 JSON content type + non-empty body; R2 logged in; R3 message
#             exists; R4 add_reactions; R5 body object; R6 exactly one of
#             emoji_id/unicode_emoji; R7 custom emoji exists in the message's
#             guild; R8 unicode is one fully-qualified RGI sequence; R9 distinct
#             cap (api.messages.max_reactions); R10 idempotent add
# DELETE    - R1 logged in; R2 message exists; R3 emoji params
#             (emoji_id XOR unicode_emoji, none = remove all own); R4 optional
#             user_id target needs delete_reactions and a strictly higher role;
#             R5 idempotent remove

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "emojis"))

from conftest import (  # noqa: E402
    seed_role,
    system_create_user,
    system_login,
)

from permissions import (  # noqa: E402
    ADD_REACTIONS,
    DELETE_REACTIONS,
    READ_MESSAGES,
    SEND_MESSAGES,
)

from emoji_helpers import create_emoji_ok, create_guild_with_admin  # noqa: E402

CONFIG_PATH = Path(__file__).resolve().parents[3] / "config.tests.json"

with CONFIG_PATH.open() as f:
    CONFIG = json.load(f)

# A single fully-qualified RGI sequence (thumbs up).
THUMBS_UP = "\U0001F44D"
# Red heart, a different one.
HEART = "\u2764\uFE0F"

MAX_REACTIONS = CONFIG["api"]["messages"]["max_reactions"]
MAX_REACTIONS_USERS_LIMIT = CONFIG["api"]["messages"]["max_reactions_users_limit"]


def _url(message_id):
    return f"/api/messages/{message_id}/reactions"


def _users_url(message_id):
    return f"/api/messages/{message_id}/reactions/users"


def _auth(token):
    return {"Authorization": f"Bearer {token}"}


def _message_reactions(http_client, token, message_id):
    """Inline reactions of a message, read through the single-message endpoint
    (the aggregate GET /reactions endpoint was removed)."""
    response = http_client.get(f"/api/messages/{message_id}", headers=_auth(token))
    assert response.status_code == 200, response.text

    return response.json()["reactions"] or []


def _put(http_client, token, message_id, payload, content_type="application/json"):
    headers = _auth(token)

    if content_type is not None:
        headers["Content-Type"] = content_type

    return http_client.put(_url(message_id), json=payload, headers=headers)


def _delete(http_client, token, message_id, **params):
    return http_client.delete(_url(message_id), params=params, headers=_auth(token))


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


def _insert_reaction(
    db_conn, message_id, user_id, unicode_emoji=None, emoji_id=None, created_at=None
):
    kind = 0 if unicode_emoji is not None else 1
    created = created_at if created_at is not None else "now()"

    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.message_reactions"
            " (message_id, user_id, emoji_kind, emoji_id, unicode_emoji, created_at)"
            f" VALUES (%s, %s, %s, %s, %s, {created})",
            (message_id, user_id, kind, emoji_id, unicode_emoji),
        )


def _other_session(http_client, username="other"):
    user = system_create_user(http_client, username=username)
    access_token, _ = system_login(http_client, username)

    return user, access_token


# ---------------------------------------------------------------------------
# Inline reactions (the aggregate GET /reactions endpoint was removed)
# ---------------------------------------------------------------------------


def test_get_reactions_method_not_allowed(http_client, test_message, test_session):
    response = http_client.get(
        _url(test_message.id), headers=_auth(test_session.access_token)
    )

    assert response.status_code == 405
    assert response.headers["Allow"] == "PUT, DELETE"


def _page_reactions(http_client, token, channel_id, message_id):
    response = http_client.get(
        f"/api/channels/{channel_id}/messages", headers=_auth(token)
    )
    assert response.status_code == 200, response.text

    for message in response.json():
        if message["id"] == str(message_id):
            return message["reactions"] or []

    raise AssertionError("message not found in the channel page")


def test_message_reactions_inline_summary(
    db_conn, http_client, test_channel, test_message, test_session, test_user
):
    other, _ = _other_session(http_client)

    _insert_reaction(db_conn, test_message.id, test_user.id, unicode_emoji=THUMBS_UP)
    _insert_reaction(db_conn, test_message.id, other["id"], unicode_emoji=THUMBS_UP)
    _insert_reaction(db_conn, test_message.id, other["id"], unicode_emoji=HEART)

    body = _page_reactions(
        http_client, test_session.access_token, test_channel.id, test_message.id
    )
    by_unicode = {item["unicode_emoji"]: item for item in body}

    assert set(by_unicode) == {THUMBS_UP, HEART}
    assert by_unicode[THUMBS_UP]["count"] == 2
    assert by_unicode[THUMBS_UP]["me"] is True
    assert by_unicode[THUMBS_UP]["emoji_id"] is None
    assert by_unicode[HEART]["count"] == 1
    assert by_unicode[HEART]["me"] is False


def test_message_reactions_inline_empty(http_client, test_message, test_session):
    assert (
        _message_reactions(http_client, test_session.access_token, test_message.id)
        == []
    )


def test_message_reactions_inline_custom_emoji(
    db_conn, http_client, test_guild, test_message, test_user, test_session
):
    emoji = create_emoji_ok(
        http_client, test_guild.admin_token, test_guild.id, "party"
    )

    _insert_reaction(db_conn, test_message.id, test_user.id, emoji_id=emoji["id"])

    assert _message_reactions(
        http_client, test_session.access_token, test_message.id
    ) == [
        {
            "emoji_id": emoji["id"],
            "unicode_emoji": None,
            "count": 1,
            "me": True,
        }
    ]


def test_message_reactions_inline_ordered_by_first_use(
    db_conn, http_client, test_message, test_session, test_user
):
    _insert_reaction(
        db_conn,
        test_message.id,
        test_user.id,
        unicode_emoji=HEART,
        created_at="'2020-01-01T00:00:00Z'",
    )
    _insert_reaction(
        db_conn,
        test_message.id,
        test_user.id,
        unicode_emoji=THUMBS_UP,
        created_at="'2021-01-01T00:00:00Z'",
    )

    body = _message_reactions(http_client, test_session.access_token, test_message.id)

    assert [item["unicode_emoji"] for item in body] == [HEART, THUMBS_UP]


# ---------------------------------------------------------------------------
# GET /reactions/users
# ---------------------------------------------------------------------------


def _get_users(http_client, token, message_id, **params):
    return http_client.get(_users_url(message_id), params=params, headers=_auth(token))


def test_get_reaction_users_unauthorized(http_client, test_message):
    response = http_client.get(
        _users_url(test_message.id), params={"unicode_emoji": THUMBS_UP}
    )

    assert response.status_code == 401


def test_get_reaction_users_not_found(http_client, test_session):
    response = _get_users(
        http_client, test_session.access_token, "1", unicode_emoji=THUMBS_UP
    )

    assert response.status_code == 404
    assert response.json()["message"] == "Message not found"


# R3
def test_get_reaction_users_forbidden_without_read_messages(
    db_conn, http_client, test_guild, test_message, test_session
):
    _set_everyone_permissions(db_conn, test_guild.id, SEND_MESSAGES)

    response = _get_users(
        http_client, test_session.access_token, test_message.id, unicode_emoji=THUMBS_UP
    )

    assert response.status_code == 403
    assert response.json()["message"] == "Missing permissions"


def test_get_reaction_users_unknown_parameter(
    http_client, test_message, test_session
):
    response = _get_users(
        http_client,
        test_session.access_token,
        test_message.id,
        unicode_emoji=THUMBS_UP,
        foo="bar",
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Unknown parameter"


def test_get_reaction_users_neither_emoji(http_client, test_message, test_session):
    response = _get_users(http_client, test_session.access_token, test_message.id)

    assert response.status_code == 400
    assert response.json()["message"] == (
        "Specify exactly one of 'emoji_id' or 'unicode_emoji'"
    )


def test_get_reaction_users_both_emoji(http_client, test_message, test_session):
    response = _get_users(
        http_client,
        test_session.access_token,
        test_message.id,
        emoji_id="123",
        unicode_emoji=THUMBS_UP,
    )

    assert response.status_code == 400
    assert response.json()["message"] == (
        "Specify exactly one of 'emoji_id' or 'unicode_emoji'"
    )


def test_get_reaction_users_malformed_emoji_id(
    http_client, test_message, test_session
):
    response = _get_users(
        http_client, test_session.access_token, test_message.id, emoji_id="abc"
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'emoji_id' is invalid"


# R4
def test_get_reaction_users_unknown_emoji_id(
    http_client, test_message, test_session
):
    response = _get_users(
        http_client, test_session.access_token, test_message.id, emoji_id="999999"
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'emoji_id' is invalid"


# R4
def test_get_reaction_users_foreign_guild_emoji(
    http_client, test_message, test_session
):
    guild, token = create_guild_with_admin(http_client, "ReactUsersOtherG")
    emoji = create_emoji_ok(http_client, token, guild.id, "foreign")

    response = _get_users(
        http_client, test_session.access_token, test_message.id, emoji_id=emoji["id"]
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'emoji_id' is invalid"


def test_get_reaction_users_invalid_unicode(
    http_client, test_message, test_session
):
    for value in ["", "a", THUMBS_UP + THUMBS_UP]:
        response = _get_users(
            http_client, test_session.access_token, test_message.id, unicode_emoji=value
        )

        assert response.status_code == 400, value
        assert response.json()["message"] == "'unicode_emoji' is invalid"


def test_get_reaction_users_bad_limit(http_client, test_message, test_session):
    for value in [
        0,
        MAX_REACTIONS_USERS_LIMIT + 1,
        -1,
        "abc",
        "1.5",
    ]:
        response = _get_users(
            http_client,
            test_session.access_token,
            test_message.id,
            unicode_emoji=THUMBS_UP,
            limit=value,
        )

        assert response.status_code == 400, value
        assert response.json()["message"] == "Bad 'limit' parameter"


# R5 - the configured max is accepted
def test_get_reaction_users_max_limit(http_client, test_message, test_session):
    response = _get_users(
        http_client,
        test_session.access_token,
        test_message.id,
        unicode_emoji=THUMBS_UP,
        limit=MAX_REACTIONS_USERS_LIMIT,
    )

    assert response.status_code == 200


def test_get_reaction_users_bad_after(http_client, test_message, test_session):
    response = _get_users(
        http_client,
        test_session.access_token,
        test_message.id,
        unicode_emoji=THUMBS_UP,
        after="abc",
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Bad 'after' parameter"


def test_get_reaction_users_empty(http_client, test_message, test_session):
    response = _get_users(
        http_client, test_session.access_token, test_message.id, unicode_emoji=THUMBS_UP
    )

    assert response.status_code == 200
    assert response.json() == []


def test_get_reaction_users_returns_ids_ascending(
    db_conn, http_client, test_message, test_session, test_user
):
    other, _ = _other_session(http_client, "ascending")

    _insert_reaction(db_conn, test_message.id, test_user.id, unicode_emoji=THUMBS_UP)
    _insert_reaction(db_conn, test_message.id, other["id"], unicode_emoji=THUMBS_UP)
    # A different emoji must not show up.
    _insert_reaction(db_conn, test_message.id, other["id"], unicode_emoji=HEART)

    response = _get_users(
        http_client, test_session.access_token, test_message.id, unicode_emoji=THUMBS_UP
    )

    assert response.status_code == 200

    body = response.json()
    expected = sorted([test_user.id, other["id"]], key=int)

    assert body == expected
    assert all(isinstance(item, str) for item in body)


def test_get_reaction_users_custom_emoji(
    db_conn, http_client, test_guild, test_message, test_user, test_session
):
    emoji = create_emoji_ok(
        http_client, test_guild.admin_token, test_guild.id, "users_custom"
    )

    _insert_reaction(db_conn, test_message.id, test_user.id, emoji_id=emoji["id"])

    response = _get_users(
        http_client, test_session.access_token, test_message.id, emoji_id=emoji["id"]
    )

    assert response.status_code == 200
    assert response.json() == [test_user.id]


def test_get_reaction_users_keyset_pagination(
    db_conn, http_client, test_message, test_session, test_user
):
    other, _ = _other_session(http_client, "paginated")

    _insert_reaction(db_conn, test_message.id, test_user.id, unicode_emoji=THUMBS_UP)
    _insert_reaction(db_conn, test_message.id, other["id"], unicode_emoji=THUMBS_UP)

    first = _get_users(
        http_client,
        test_session.access_token,
        test_message.id,
        unicode_emoji=THUMBS_UP,
        limit="1",
    )

    assert first.status_code == 200
    assert len(first.json()) == 1

    second = _get_users(
        http_client,
        test_session.access_token,
        test_message.id,
        unicode_emoji=THUMBS_UP,
        limit="1",
        after=first.json()[0],
    )

    assert second.status_code == 200
    assert second.json() == [max([test_user.id, other["id"]], key=int)]


# Soft-deleted users drop out of both the user list and the summary count.
def test_get_reaction_users_excludes_deleted_users(
    db_conn, http_client, test_message, test_session, test_user, system_headers
):
    doomed = system_create_user(http_client, username="doomed_reactor")
    _insert_reaction(db_conn, test_message.id, doomed["id"], unicode_emoji=THUMBS_UP)

    response = http_client.delete(
        f"/api/system/users/{doomed['id']}", headers=system_headers
    )
    assert response.status_code == 204

    users = _get_users(
        http_client, test_session.access_token, test_message.id, unicode_emoji=THUMBS_UP
    )

    assert users.status_code == 200
    assert users.json() == []

    summary = _message_reactions(http_client, test_session.access_token, test_message.id)
    assert summary == []


# ---------------------------------------------------------------------------
# PUT
# ---------------------------------------------------------------------------


def test_put_reaction_unauthorized(http_client, test_message):
    response = http_client.put(_url(test_message.id), json={"unicode_emoji": THUMBS_UP})

    assert response.status_code == 401


def test_put_reaction_not_found(http_client, test_session):
    response = _put(http_client, test_session.access_token, "1", {"unicode_emoji": THUMBS_UP})

    assert response.status_code == 404
    assert response.json()["message"] == "Message not found"


# R1
def test_put_reaction_bad_content_type(
    http_client, test_message, test_session
):
    response = http_client.put(
        _url(test_message.id),
        content=b"{}",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
            "Content-Type": "text/plain",
        },
    )

    assert response.status_code == 415


# R1
def test_put_reaction_empty_body(http_client, test_message, test_session):
    response = http_client.put(
        _url(test_message.id),
        content=b"",
        headers={
            "Authorization": f"Bearer {test_session.access_token}",
            "Content-Type": "application/json",
        },
    )

    assert response.status_code == 400


# R4
def test_put_reaction_forbidden_without_add_reactions(
    db_conn, http_client, test_guild, test_message, test_session
):
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES | SEND_MESSAGES)

    response = _put(http_client, test_session.access_token, test_message.id, {"unicode_emoji": THUMBS_UP})

    assert response.status_code == 403
    assert response.json()["message"] == "Missing permissions"


# R4 (success path pins the add_reactions bit)
def test_put_reaction_allowed_by_exact_add_reactions_role(
    db_conn, http_client, test_guild, test_message, test_user, test_session
):
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES)
    _create_role(db_conn, test_guild.id, "7000001", "reactors", permissions=ADD_REACTIONS)
    _assign_role(db_conn, test_guild.id, test_user.id, "7000001")

    response = _put(http_client, test_session.access_token, test_message.id, {"unicode_emoji": THUMBS_UP})

    assert response.status_code == 204


# R6
def test_put_reaction_neither_emoji(http_client, test_message, test_session):
    response = _put(http_client, test_session.access_token, test_message.id, {})

    assert response.status_code == 400
    assert response.json()["message"] == "Specify exactly one of 'emoji_id' or 'unicode_emoji'"


# R6
def test_put_reaction_both_emoji(
    db_conn, http_client, test_guild, test_message, test_session
):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "both")

    response = _put(
        http_client,
        test_session.access_token,
        test_message.id,
        {"emoji_id": emoji["id"], "unicode_emoji": THUMBS_UP},
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Specify exactly one of 'emoji_id' or 'unicode_emoji'"


# R6
def test_put_reaction_null_emoji_id(http_client, test_message, test_session):
    response = _put(http_client, test_session.access_token, test_message.id, {"emoji_id": None})

    assert response.status_code == 400
    assert response.json()["message"] == "'emoji_id' is not a string"


# R6
def test_put_reaction_non_string_unicode(http_client, test_message, test_session):
    response = _put(http_client, test_session.access_token, test_message.id, {"unicode_emoji": 1})

    assert response.status_code == 400
    assert response.json()["message"] == "'unicode_emoji' is not a string"


# R7
def test_put_reaction_malformed_emoji_id(http_client, test_message, test_session):
    response = _put(http_client, test_session.access_token, test_message.id, {"emoji_id": "abc"})

    assert response.status_code == 400
    assert response.json()["message"] == "'emoji_id' is invalid"


# R7
def test_put_reaction_unknown_emoji_id(http_client, test_message, test_session):
    response = _put(http_client, test_session.access_token, test_message.id, {"emoji_id": "999999"})

    assert response.status_code == 400
    assert response.json()["message"] == "'emoji_id' is invalid"


# R7
def test_put_reaction_foreign_guild_emoji(
    http_client, test_message, test_session
):
    guild, token = create_guild_with_admin(http_client, "ReactionOtherGuild")
    emoji = create_emoji_ok(http_client, token, guild.id, "foreign")

    response = _put(http_client, test_session.access_token, test_message.id, {"emoji_id": emoji["id"]})

    assert response.status_code == 400
    assert response.json()["message"] == "'emoji_id' is invalid"


# R8
def test_put_reaction_rejects_invalid_unicode(http_client, test_message, test_session):
    for value in ["", "a", "\u263A", THUMBS_UP + THUMBS_UP]:
        response = _put(http_client, test_session.access_token, test_message.id, {"unicode_emoji": value})

        assert response.status_code == 400, value
        assert response.json()["message"] == "'unicode_emoji' is invalid"


# R10
def test_put_reaction_unicode_success_and_idempotent(
    http_client, test_message, test_session
):
    response = _put(http_client, test_session.access_token, test_message.id, {"unicode_emoji": THUMBS_UP})

    assert response.status_code == 204

    # Re-adding the same emoji is idempotent.
    response = _put(http_client, test_session.access_token, test_message.id, {"unicode_emoji": THUMBS_UP})

    assert response.status_code == 204

    body = _message_reactions(http_client, test_session.access_token, test_message.id)
    assert body == [
        {
            "emoji_id": None,
            "unicode_emoji": THUMBS_UP,
            "count": 1,
            "me": True,
        }
    ]


# R7 + R10
def test_put_reaction_custom_success(
    db_conn, http_client, test_guild, test_message, test_session
):
    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "success")

    response = _put(http_client, test_session.access_token, test_message.id, {"emoji_id": emoji["id"]})

    assert response.status_code == 204

    body = _message_reactions(http_client, test_session.access_token, test_message.id)
    assert body == [
        {
            "emoji_id": emoji["id"],
            "unicode_emoji": None,
            "count": 1,
            "me": True,
        }
    ]


# R9
def test_put_reaction_distinct_cap(
    db_conn, http_client, test_message, test_session, test_user
):
    for i in range(MAX_REACTIONS):
        _insert_reaction(db_conn, test_message.id, test_user.id, unicode_emoji=f"filler-{i}")

    response = _put(http_client, test_session.access_token, test_message.id, {"unicode_emoji": THUMBS_UP})

    assert response.status_code == 400
    assert response.json()["message"] == "Too many reactions"


# R9 - re-adding an already present emoji is allowed at the cap
def test_put_reaction_existing_emoji_allowed_at_cap(
    db_conn, http_client, test_message, test_session, test_user
):
    for i in range(MAX_REACTIONS - 1):
        _insert_reaction(db_conn, test_message.id, test_user.id, unicode_emoji=f"filler-{i}")

    _insert_reaction(db_conn, test_message.id, test_user.id, unicode_emoji=THUMBS_UP)

    response = _put(http_client, test_session.access_token, test_message.id, {"unicode_emoji": THUMBS_UP})

    assert response.status_code == 204


# ---------------------------------------------------------------------------
# DELETE
# ---------------------------------------------------------------------------


def test_delete_reaction_unauthorized(http_client, test_message):
    response = http_client.delete(_url(test_message.id), params={"unicode_emoji": THUMBS_UP})

    assert response.status_code == 401


def test_delete_reaction_not_found(http_client, test_session):
    response = _delete(http_client, test_session.access_token, "1", unicode_emoji=THUMBS_UP)

    assert response.status_code == 404
    assert response.json()["message"] == "Message not found"


def test_delete_reaction_unknown_parameter(http_client, test_message, test_session):
    response = _delete(http_client, test_session.access_token, test_message.id, foo="bar")

    assert response.status_code == 400
    assert response.json()["message"] == "Unknown parameter"


def test_delete_reaction_both_emoji(http_client, test_message, test_session):
    response = _delete(
        http_client,
        test_session.access_token,
        test_message.id,
        emoji_id="123",
        unicode_emoji=THUMBS_UP,
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Specify exactly one of 'emoji_id' or 'unicode_emoji'"


def test_delete_reaction_bad_user_id(http_client, test_message, test_session):
    response = _delete(http_client, test_session.access_token, test_message.id, user_id="abc")

    assert response.status_code == 400
    assert response.json()["message"] == "Bad 'user_id' parameter"


# R3 + query decoding: the client percent-encodes the unicode value
def test_delete_own_unicode_reaction_round_trip(
    http_client, test_message, test_session
):
    response = _put(http_client, test_session.access_token, test_message.id, {"unicode_emoji": THUMBS_UP})
    assert response.status_code == 204

    response = _delete(http_client, test_session.access_token, test_message.id, unicode_emoji=THUMBS_UP)

    assert response.status_code == 204
    assert _message_reactions(http_client, test_session.access_token, test_message.id) == []


# R5 - deleting a reaction that does not exist is still 204
def test_delete_absent_reaction_is_idempotent(http_client, test_message, test_session):
    response = _delete(http_client, test_session.access_token, test_message.id, unicode_emoji=THUMBS_UP)

    assert response.status_code == 204


# R4 - removing the caller's own reaction needs no permission
def test_delete_own_reaction_without_permissions(
    db_conn, http_client, test_guild, test_message, test_session, test_user
):
    _set_everyone_permissions(db_conn, test_guild.id, 0)
    _insert_reaction(db_conn, test_message.id, test_user.id, unicode_emoji=THUMBS_UP)

    response = _delete(http_client, test_session.access_token, test_message.id, unicode_emoji=THUMBS_UP)

    assert response.status_code == 204


# R3 - no emoji parameter removes all of the caller's reactions
def test_delete_all_own_reactions(
    db_conn, http_client, test_message, test_session, test_user
):
    _insert_reaction(db_conn, test_message.id, test_user.id, unicode_emoji=THUMBS_UP)
    _insert_reaction(db_conn, test_message.id, test_user.id, unicode_emoji=HEART)

    response = _delete(http_client, test_session.access_token, test_message.id)

    assert response.status_code == 204
    assert _message_reactions(http_client, test_session.access_token, test_message.id) == []


# R4
def test_delete_other_reaction_forbidden_without_delete_reactions(
    db_conn, http_client, test_guild, test_message, test_user
):
    _set_everyone_permissions(db_conn, test_guild.id, READ_MESSAGES | SEND_MESSAGES)

    caller, caller_token = _other_session(http_client, "nodelete")
    _create_role(db_conn, test_guild.id, "8000001", "higher", position=100, permissions=0)
    _assign_role(db_conn, test_guild.id, caller["id"], "8000001")

    _insert_reaction(db_conn, test_message.id, test_user.id, unicode_emoji=THUMBS_UP)

    response = _delete(
        http_client, caller_token, test_message.id, unicode_emoji=THUMBS_UP, user_id=test_user.id
    )

    assert response.status_code == 403
    assert response.json()["message"] == "Missing permissions"


# R4 - has delete_reactions but is not strictly higher than the target
def test_delete_other_reaction_forbidden_not_higher(
    db_conn, http_client, test_guild, test_message, test_user
):
    _set_everyone_permissions(
        db_conn, test_guild.id, READ_MESSAGES | SEND_MESSAGES | DELETE_REACTIONS
    )

    _create_role(db_conn, test_guild.id, "8000002", "target", position=5, permissions=0)
    _assign_role(db_conn, test_guild.id, test_user.id, "8000002")

    caller, caller_token = _other_session(http_client, "lower")

    _insert_reaction(db_conn, test_message.id, test_user.id, unicode_emoji=THUMBS_UP)

    response = _delete(
        http_client, caller_token, test_message.id, unicode_emoji=THUMBS_UP, user_id=test_user.id
    )

    assert response.status_code == 403
    assert response.json()["message"] == "Missing permissions"


# R4 (success path pins the delete_reactions bit + the hierarchy check)
def test_delete_other_reaction_success(
    db_conn, http_client, test_guild, test_message, test_user, test_session
):
    _set_everyone_permissions(
        db_conn, test_guild.id, READ_MESSAGES | SEND_MESSAGES | DELETE_REACTIONS
    )

    caller, caller_token = _other_session(http_client, "seniormod")
    _create_role(db_conn, test_guild.id, "8000003", "mod", position=5, permissions=0)
    _assign_role(db_conn, test_guild.id, caller["id"], "8000003")

    _insert_reaction(db_conn, test_message.id, test_user.id, unicode_emoji=THUMBS_UP)

    response = _delete(
        http_client, caller_token, test_message.id, unicode_emoji=THUMBS_UP, user_id=test_user.id
    )

    assert response.status_code == 204

    # The target's reaction is gone; the caller still sees an empty summary.
    assert _message_reactions(http_client, test_session.access_token, test_message.id) == []


# R3 + R4 - custom emoji target
def test_delete_other_custom_reaction_success(
    db_conn, http_client, test_guild, test_message, test_user, test_session
):
    _set_everyone_permissions(
        db_conn, test_guild.id, READ_MESSAGES | SEND_MESSAGES | DELETE_REACTIONS
    )

    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "custom")
    _insert_reaction(db_conn, test_message.id, test_user.id, emoji_id=emoji["id"])

    caller, caller_token = _other_session(http_client, "emoji_mod")
    _create_role(db_conn, test_guild.id, "8000004", "mod2", position=5, permissions=0)
    _assign_role(db_conn, test_guild.id, caller["id"], "8000004")

    response = _delete(
        http_client, caller_token, test_message.id, emoji_id=emoji["id"], user_id=test_user.id
    )

    assert response.status_code == 204
    assert _message_reactions(http_client, test_session.access_token, test_message.id) == []


# ---------------------------------------------------------------------------
# Gateway events
# ---------------------------------------------------------------------------


def test_reaction_added_event(
    http_client, test_message, test_session, test_user, test_channel, test_guild
):
    from test_gateway import GatewayClient

    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_session.access_token}})
    assert ws.recv_json()["op"] == "hello"

    response = _put(http_client, test_session.access_token, test_message.id, {"unicode_emoji": THUMBS_UP})
    assert response.status_code == 204

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "reaction_added"
    assert event["d"] == {
        "id": str(test_message.id),
        "channel_id": str(test_channel.id),
        "guild_id": str(test_guild.id),
        "user_id": str(test_user.id),
        "emoji_id": None,
        "unicode_emoji": THUMBS_UP,
    }

    ws.close()


def test_reaction_added_custom_event(
    db_conn, http_client, test_guild, test_message, test_session, test_channel
):
    from test_gateway import GatewayClient

    emoji = create_emoji_ok(http_client, test_guild.admin_token, test_guild.id, "gateway")

    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_session.access_token}})
    assert ws.recv_json()["op"] == "hello"

    response = _put(http_client, test_session.access_token, test_message.id, {"emoji_id": emoji["id"]})
    assert response.status_code == 204

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "reaction_added"
    assert event["d"]["emoji_id"] == emoji["id"]
    assert event["d"]["unicode_emoji"] is None
    assert event["d"]["id"] == str(test_message.id)
    assert event["d"]["channel_id"] == str(test_channel.id)

    ws.close()


def test_reaction_removed_event(
    http_client, test_message, test_session, test_user, test_channel, test_guild
):
    from test_gateway import GatewayClient

    response = _put(http_client, test_session.access_token, test_message.id, {"unicode_emoji": THUMBS_UP})
    assert response.status_code == 204

    ws = GatewayClient()
    ws.send_json({"op": "identify", "d": {"token": test_session.access_token}})
    assert ws.recv_json()["op"] == "hello"

    response = _delete(http_client, test_session.access_token, test_message.id, unicode_emoji=THUMBS_UP)
    assert response.status_code == 204

    event = ws.recv_json()
    assert event["op"] == "dispatch"
    assert event["t"] == "reaction_removed"
    assert event["d"] == {
        "id": str(test_message.id),
        "channel_id": str(test_channel.id),
        "guild_id": str(test_guild.id),
        "user_id": str(test_user.id),
        "emoji_id": None,
        "unicode_emoji": THUMBS_UP,
    }

    ws.close()
