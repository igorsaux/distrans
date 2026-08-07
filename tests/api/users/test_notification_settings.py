# Tests for the per-user notification settings endpoints:
#   /api/users/@me/guilds/{guild_id}/notifications        (GET, PATCH)
#   /api/users/@me/channels/{channel_id}/notifications    (GET, PATCH)
#
# Guild GET:
#   R1 - user must be logged (401)
#   R2 - the guild exists (404 "Guild not found")
#   R3 - defaults when no row (all_messages/false/false/true); never 404 for unset
# Guild PATCH:
#   R1 - application/json (415), non-empty body (400)
#   R2 - user must be logged (401)
#   R3 - the guild exists (404)
#   R4 - object with >=1 recognized field (400 "Expected an object"/"Nothing to update")
#   R5 - optional level enum (400 "'level' is not a string"/"'level' is invalid")
#   R6 - optional booleans (400 "'<field>' is not a boolean")
#   R7 - merge + upsert; 204, no gateway event
# Channel GET:
#   R1 - user must be logged (401)
#   R2 - the channel exists (404)
#   R3 - default level inherit when no row
#   R4 - effective_level resolves channel -> parent category -> guild
# Channel PATCH:
#   R1 - application/json (415), non-empty body (400)
#   R2 - user must be logged (401)
#   R3 - the channel exists (404); categories are valid targets
#   R4 - object with >=1 recognized field (400)
#   R5 - optional level enum (400)

import dataclasses

from conftest import system_create_channel, system_create_user, system_login


@dataclasses.dataclass(frozen=True)
class _Session:
    access_token: str


def _auth(session):
    return {"Authorization": f"Bearer {session.access_token}"}


def _login(http_client, username):
    access_token, _ = system_login(http_client, username)

    return _Session(access_token=access_token)


def _guild_url(guild_id):
    return f"/api/users/@me/guilds/{guild_id}/notifications"


def _channel_url(channel_id):
    return f"/api/users/@me/channels/{channel_id}/notifications"


# ---------------------------------------------------------------------------
# Auth (R1)
# ---------------------------------------------------------------------------


def test_guild_get_unauthorized(http_client, test_guild):
    assert http_client.get(_guild_url(test_guild.id)).status_code == 401


def test_guild_patch_unauthorized(http_client, test_guild):
    response = http_client.patch(_guild_url(test_guild.id), json={"level": "nothing"})

    assert response.status_code == 401


def test_channel_get_unauthorized(http_client, test_channel):
    assert http_client.get(_channel_url(test_channel.id)).status_code == 401


def test_channel_patch_unauthorized(http_client, test_channel):
    response = http_client.patch(
        _channel_url(test_channel.id), json={"level": "nothing"}
    )

    assert response.status_code == 401


# ---------------------------------------------------------------------------
# Guild GET (R2, R3)
# ---------------------------------------------------------------------------


def test_guild_get_unknown_guild(http_client, test_session):
    response = http_client.get(_guild_url("999999"), headers=_auth(test_session))

    assert response.status_code == 404
    assert response.json()["message"] == "Guild not found"


def test_guild_get_defaults(http_client, test_session, test_guild):
    response = http_client.get(_guild_url(test_guild.id), headers=_auth(test_session))

    assert response.status_code == 200
    assert response.json() == {
        "level": "all_messages",
        "suppress_everyone": False,
        "suppress_roles": False,
        "push": True,
    }


# ---------------------------------------------------------------------------
# Guild PATCH (R1, R4, R5, R6, R7)
# ---------------------------------------------------------------------------


def test_guild_patch_empty_body(http_client, test_session, test_guild):
    response = http_client.patch(_guild_url(test_guild.id), headers=_auth(test_session))

    assert response.status_code == 400


def test_guild_patch_bad_content_type(http_client, test_session, test_guild):
    response = http_client.patch(
        _guild_url(test_guild.id),
        content='{"level": "nothing"}',
        headers={**_auth(test_session), "Content-Type": "text/plain"},
    )

    assert response.status_code == 415


def test_guild_patch_non_object(http_client, test_session, test_guild):
    response = http_client.patch(
        _guild_url(test_guild.id), json=[1, 2], headers=_auth(test_session)
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Expected an object"


def test_guild_patch_nothing_to_update(http_client, test_session, test_guild):
    response = http_client.patch(
        _guild_url(test_guild.id), json={}, headers=_auth(test_session)
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Nothing to update"


def test_guild_patch_invalid_level(http_client, test_session, test_guild):
    response = http_client.patch(
        _guild_url(test_guild.id), json={"level": "sometimes"}, headers=_auth(test_session)
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'level' is invalid"


def test_guild_patch_level_not_string(http_client, test_session, test_guild):
    response = http_client.patch(
        _guild_url(test_guild.id), json={"level": None}, headers=_auth(test_session)
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'level' is not a string"


def test_guild_patch_bool_not_bool(http_client, test_session, test_guild):
    response = http_client.patch(
        _guild_url(test_guild.id),
        json={"suppress_everyone": "yes"},
        headers=_auth(test_session),
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'suppress_everyone' is not a boolean"


def test_guild_patch_roundtrip(http_client, test_session, test_guild):
    response = http_client.patch(
        _guild_url(test_guild.id),
        json={"level": "only_mentions", "suppress_everyone": True, "push": False},
        headers=_auth(test_session),
    )

    assert response.status_code == 204

    body = http_client.get(
        _guild_url(test_guild.id), headers=_auth(test_session)
    ).json()

    assert body == {
        "level": "only_mentions",
        "suppress_everyone": True,
        "suppress_roles": False,
        "push": False,
    }


def test_guild_patch_partial_keeps_other_fields(http_client, test_session, test_guild):
    http_client.patch(
        _guild_url(test_guild.id),
        json={"level": "nothing", "suppress_roles": True},
        headers=_auth(test_session),
    )

    response = http_client.patch(
        _guild_url(test_guild.id),
        json={"push": False},
        headers=_auth(test_session),
    )

    assert response.status_code == 204

    body = http_client.get(
        _guild_url(test_guild.id), headers=_auth(test_session)
    ).json()

    assert body == {
        "level": "nothing",
        "suppress_everyone": False,
        "suppress_roles": True,
        "push": False,
    }


def test_guild_patch_ignores_unknown_fields(http_client, test_session, test_guild):
    response = http_client.patch(
        _guild_url(test_guild.id),
        json={"level": "nothing", "unknown": 123},
        headers=_auth(test_session),
    )

    assert response.status_code == 204

    body = http_client.get(
        _guild_url(test_guild.id), headers=_auth(test_session)
    ).json()

    assert body["level"] == "nothing"


def test_guild_settings_are_per_user(http_client, test_session, test_guild):
    http_client.patch(
        _guild_url(test_guild.id), json={"level": "nothing"}, headers=_auth(test_session)
    )

    system_create_user(http_client, username="other_user")
    other_session = _login(http_client, "other_user")

    body = http_client.get(
        _guild_url(test_guild.id), headers=_auth(other_session)
    ).json()

    assert body["level"] == "all_messages"


def test_guild_patch_stored_in_db(http_client, db_conn, test_session, test_user, test_guild):
    http_client.patch(
        _guild_url(test_guild.id),
        json={"level": "only_mentions", "suppress_roles": True},
        headers=_auth(test_session),
    )

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT level, suppress_everyone, suppress_roles, push"
            " FROM app.guild_notification_settings"
            " WHERE user_id = %s AND guild_id = %s",
            (test_user.id, test_guild.id),
        )
        row = cur.fetchone()

    assert row == {
        "level": 1,
        "suppress_everyone": False,
        "suppress_roles": True,
        "push": True,
    }


# ---------------------------------------------------------------------------
# Channel GET (R2, R3, R4)
# ---------------------------------------------------------------------------


def test_channel_get_unknown_channel(http_client, test_session):
    response = http_client.get(_channel_url("999999"), headers=_auth(test_session))

    assert response.status_code == 404
    assert response.json()["message"] == "Channel not found"


def test_channel_get_default_inherit(http_client, test_session, test_channel):
    response = http_client.get(_channel_url(test_channel.id), headers=_auth(test_session))

    assert response.status_code == 200
    assert response.json() == {"level": "inherit", "effective_level": "all_messages"}


def test_channel_get_category_is_valid(http_client, test_session, test_category):
    response = http_client.get(_channel_url(test_category.id), headers=_auth(test_session))

    assert response.status_code == 200
    assert response.json() == {"level": "inherit", "effective_level": "all_messages"}


# ---------------------------------------------------------------------------
# Channel PATCH (R1, R3, R4, R5)
# ---------------------------------------------------------------------------


def test_channel_patch_empty_body(http_client, test_session, test_channel):
    response = http_client.patch(_channel_url(test_channel.id), headers=_auth(test_session))

    assert response.status_code == 400


def test_channel_patch_bad_content_type(http_client, test_session, test_channel):
    response = http_client.patch(
        _channel_url(test_channel.id),
        content='{"level": "nothing"}',
        headers={**_auth(test_session), "Content-Type": "text/plain"},
    )

    assert response.status_code == 415


def test_channel_patch_unknown_channel(http_client, test_session):
    response = http_client.patch(
        _channel_url("999999"), json={"level": "nothing"}, headers=_auth(test_session)
    )

    assert response.status_code == 404


def test_channel_patch_category_is_valid(http_client, test_session, test_category):
    response = http_client.patch(
        _channel_url(test_category.id),
        json={"level": "nothing"},
        headers=_auth(test_session),
    )

    assert response.status_code == 204

    body = http_client.get(
        _channel_url(test_category.id), headers=_auth(test_session)
    ).json()

    assert body == {"level": "nothing", "effective_level": "nothing"}


def test_channel_patch_nothing_to_update(http_client, test_session, test_channel):
    response = http_client.patch(
        _channel_url(test_channel.id), json={}, headers=_auth(test_session)
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Nothing to update"


def test_channel_patch_invalid_level(http_client, test_session, test_channel):
    response = http_client.patch(
        _channel_url(test_channel.id),
        json={"level": "everyone"},
        headers=_auth(test_session),
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'level' is invalid"


def test_channel_patch_level_not_string(http_client, test_session, test_channel):
    response = http_client.patch(
        _channel_url(test_channel.id), json={"level": 3}, headers=_auth(test_session)
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'level' is not a string"


def test_channel_patch_roundtrip(http_client, test_session, test_channel):
    response = http_client.patch(
        _channel_url(test_channel.id),
        json={"level": "only_mentions"},
        headers=_auth(test_session),
    )

    assert response.status_code == 204

    body = http_client.get(
        _channel_url(test_channel.id), headers=_auth(test_session)
    ).json()

    assert body == {"level": "only_mentions", "effective_level": "only_mentions"}


# ---------------------------------------------------------------------------
# Inheritance chain: channel -> parent category -> guild (R4)
# ---------------------------------------------------------------------------


def _make_child_channel(http_client, test_guild, parent_id):
    return system_create_channel(
        http_client,
        test_guild.id,
        name="ChildChannel",
        parent_id=parent_id,
        admin_token=test_guild.admin_token,
    )


def test_channel_inherits_guild_level(
    http_client, test_session, test_guild, test_channel
):
    http_client.patch(
        _guild_url(test_guild.id),
        json={"level": "only_mentions"},
        headers=_auth(test_session),
    )

    body = http_client.get(
        _channel_url(test_channel.id), headers=_auth(test_session)
    ).json()

    assert body == {"level": "inherit", "effective_level": "only_mentions"}


def test_channel_inherits_parent_category_level(
    http_client, test_session, test_guild, test_category
):
    # The guild says "all messages", but the category overrides to "nothing";
    # a text channel in the category with inherit must resolve to "nothing".
    http_client.patch(
        _guild_url(test_guild.id),
        json={"level": "all_messages"},
        headers=_auth(test_session),
    )
    http_client.patch(
        _channel_url(test_category.id),
        json={"level": "nothing"},
        headers=_auth(test_session),
    )

    child = _make_child_channel(http_client, test_guild, test_category.id)

    body = http_client.get(
        _channel_url(child.id), headers=_auth(test_session)
    ).json()

    assert body == {"level": "inherit", "effective_level": "nothing"}


def test_channel_explicit_level_overrides_category(
    http_client, test_session, test_guild, test_category
):
    http_client.patch(
        _channel_url(test_category.id),
        json={"level": "nothing"},
        headers=_auth(test_session),
    )

    child = _make_child_channel(http_client, test_guild, test_category.id)
    http_client.patch(
        _channel_url(child.id),
        json={"level": "all_messages"},
        headers=_auth(test_session),
    )

    body = http_client.get(
        _channel_url(child.id), headers=_auth(test_session)
    ).json()

    assert body == {"level": "all_messages", "effective_level": "all_messages"}


def test_channel_category_inherit_falls_back_to_guild(
    http_client, test_session, test_guild, test_category
):
    # A category has no parent, so its inherit resolves straight to the guild.
    http_client.patch(
        _guild_url(test_guild.id),
        json={"level": "only_mentions"},
        headers=_auth(test_session),
    )

    body = http_client.get(
        _channel_url(test_category.id), headers=_auth(test_session)
    ).json()

    assert body == {"level": "inherit", "effective_level": "only_mentions"}


def test_channel_patch_stored_in_db(
    http_client, db_conn, test_session, test_user, test_channel
):
    http_client.patch(
        _channel_url(test_channel.id),
        json={"level": "nothing"},
        headers=_auth(test_session),
    )

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT level FROM app.channel_notification_settings"
            " WHERE user_id = %s AND channel_id = %s",
            (test_user.id, test_channel.id),
        )
        row = cur.fetchone()

    assert row == {"level": 3}
