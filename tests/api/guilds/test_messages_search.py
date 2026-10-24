import hashlib
import sys
from pathlib import Path

import pytest

from conftest import SYSTEM_HEADERS, seed_role, system_create_channel

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from permissions import READ_MESSAGES

MAX_FILTER_IDS = 50


def _auth(test_session):
    return {"Authorization": f"Bearer {test_session.access_token}"}


def _search(http_client, test_session, guild_id, **params):
    return http_client.get(
        f"/api/guilds/{guild_id}/messages/search",
        headers=_auth(test_session),
        params=params,
    )


def _ids(response):
    return [message["id"] for message in response.json()["messages"]]


def _envelope(response):
    body = response.json()

    assert set(body) == {"messages", "total"}

    return body


def _mask(bits):
    return int(bits).to_bytes(16, "big")


def _set_everyone_permissions(db_conn, guild_id, permissions):
    with db_conn.cursor() as cur:
        cur.execute(
            "UPDATE app.roles SET permissions = %s WHERE id = %s",
            (_mask(permissions), guild_id),
        )


def _deny_read_messages(db_conn, guild_id, channel_id):
    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.overwrites"
            " (guild_id, channel_id, target_type, role_id, deny)"
            " VALUES (%s, %s, 0, %s, %s)",
            (guild_id, channel_id, guild_id, _mask(READ_MESSAGES)),
        )


def _allow_read_messages(db_conn, guild_id, channel_id):
    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.overwrites"
            " (guild_id, channel_id, target_type, role_id, allow)"
            " VALUES (%s, %s, 0, %s, %s)",
            (guild_id, channel_id, guild_id, _mask(READ_MESSAGES)),
        )


def _insert_message(
    db_conn,
    *,
    message_id,
    guild_id,
    channel_id,
    author_id=None,
    webhook_id=None,
    content="hi",
    pinned=False,
    created_at=None,
    mention_everyone=False,
    mention_user_ids=None,
    mention_role_ids=None,
):
    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.messages"
            " (id, channel_id, guild_id, author_id, webhook_id, content, pinned, created_at,"
            "  mention_everyone, mention_user_ids, mention_role_ids)"
            " VALUES (%s, %s, %s, %s, %s, %s, %s, COALESCE(%s::timestamptz, now()), %s, %s, %s)",
            (
                str(message_id),
                channel_id,
                guild_id,
                author_id,
                webhook_id,
                content,
                pinned,
                created_at,
                mention_everyone,
                mention_user_ids or [],
                mention_role_ids or [],
            ),
        )


def _insert_file(db_conn, file_id, hash_seed):
    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.files (id, name, hash, size, content_type)"
            " VALUES (%s, %s, %s, %s, %s)",
            (file_id, "file.txt", hash_seed, 1, "text/plain"),
        )


def _attach(db_conn, message_id, file_id):
    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.message_attachments (message_id, file_id, position)"
            " VALUES (%s, %s, 0)",
            (message_id, file_id),
        )


def _insert_reaction(db_conn, message_id, user_id, unicode_emoji):
    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.message_reactions"
            " (message_id, user_id, emoji_kind, unicode_emoji)"
            " VALUES (%s, %s, 0, %s)",
            (message_id, user_id, unicode_emoji),
        )


def _create_webhook(db_conn, webhook_id, guild_id, channel_id, name="hook"):
    token_hash = hashlib.sha256(str(webhook_id).encode()).digest()

    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.webhooks (id, guild_id, channel_id, name, token_hash)"
            " VALUES (%s, %s, %s, %s, %s)",
            (webhook_id, guild_id, channel_id, name, token_hash),
        )


def _create_bot(http_client, username):
    response = http_client.post(
        "/api/system/users",
        json={"username": username, "is_bot": True},
        headers=SYSTEM_HEADERS,
    )

    assert response.status_code == 201

    return response.json()["id"]


# ---------------------------------------------------------------------------
# R1: user must be logged
# ---------------------------------------------------------------------------


def test_search_unauthorized(http_client, test_guild):
    response = http_client.get(f"/api/guilds/{test_guild.id}/messages/search")

    assert response.status_code == 401


# ---------------------------------------------------------------------------
# R2: the guild exists
# ---------------------------------------------------------------------------


def test_search_unknown_guild(http_client, test_session):
    response = _search(http_client, test_session, "1")

    assert response.status_code == 404
    assert response.json()["message"] == "Guild not found"


def test_search_wrong_method(http_client, test_guild, test_session):
    response = http_client.post(
        f"/api/guilds/{test_guild.id}/messages/search",
        headers=_auth(test_session),
    )

    assert response.status_code == 405
    assert "GET" in response.headers["allow"]


def test_search_missing_search_segment_is_not_found(
    http_client, test_guild, test_session
):
    response = http_client.get(
        f"/api/guilds/{test_guild.id}/messages", headers=_auth(test_session)
    )

    assert response.status_code == 404


# ---------------------------------------------------------------------------
# Parameter validation
# ---------------------------------------------------------------------------


def test_search_unknown_parameter(http_client, test_guild, test_session):
    response = _search(http_client, test_session, test_guild.id, foobar="1")

    assert response.status_code == 400
    assert response.json()["message"] == "Unknown parameter"


def test_search_cursor_is_unknown_parameter(http_client, test_guild, test_session):
    response = _search(http_client, test_session, test_guild.id, cursor="2003")

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
        ("after", "foo"),
        ("before", "foo"),
        ("authors", ""),
        ("channels", ""),
        ("mentions", ""),
        ("mention_roles", ""),
        ("authors", "1,"),
        ("channels", "a,b"),
        ("has_attachments", "yes"),
        ("pinned", "1"),
        ("author_types", ""),
        ("author_types", "alien"),
        ("content", "a"),
        ("content", "x" * 101),
    ],
)
def test_search_bad_parameter(
    http_client, test_guild, test_session, param_key, param_value
):
    response = _search(
        http_client, test_session, test_guild.id, **{param_key: param_value}
    )

    assert response.status_code == 400
    assert response.json()["message"] == f"Bad '{param_key}' parameter"


def test_search_too_many_filter_ids(http_client, test_guild, test_session):
    response = _search(
        http_client,
        test_session,
        test_guild.id,
        authors=",".join(str(i) for i in range(1, MAX_FILTER_IDS + 2)),
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Bad 'authors' parameter"


# ---------------------------------------------------------------------------
# R4: results, ordering, offset pagination, total
# ---------------------------------------------------------------------------


def test_search_returns_messages_newest_first(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    for mid in ("1001", "1002", "1003"):
        _insert_message(
            db_conn,
            message_id=mid,
            guild_id=test_guild.id,
            channel_id=test_channel.id,
            author_id=test_user.id,
            content=f"msg-{mid}",
        )

    response = _search(http_client, test_session, test_guild.id)

    assert response.status_code == 200

    body = _envelope(response)
    assert [m["id"] for m in body["messages"]] == ["1003", "1002", "1001"]
    assert body["total"] == 3

    message = body["messages"][0]
    assert message["channel_id"] == test_channel.id
    assert message["content"] == "msg-1003"
    assert message["author_id"] == test_user.id
    assert message["attachments"] == []
    assert message["mentions"] == []
    assert message["mention_roles"] == []
    assert message["mention_everyone"] is False
    assert message["pinned"] is False


def test_search_sort_oldest(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    for mid in ("1051", "1052", "1053"):
        _insert_message(
            db_conn,
            message_id=mid,
            guild_id=test_guild.id,
            channel_id=test_channel.id,
            author_id=test_user.id,
        )

    response = _search(http_client, test_session, test_guild.id, sort="oldest")

    assert response.status_code == 200
    assert _ids(response) == ["1051", "1052", "1053"]
    assert response.json()["total"] == 3

    response = _search(http_client, test_session, test_guild.id, sort="newest")
    assert _ids(response) == ["1053", "1052", "1051"]


def test_search_default_limit_is_25(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    for i in range(30):
        _insert_message(
            db_conn,
            message_id=str(1100 + i),
            guild_id=test_guild.id,
            channel_id=test_channel.id,
            author_id=test_user.id,
        )

    response = _search(http_client, test_session, test_guild.id)

    assert response.status_code == 200

    body = _envelope(response)
    assert len(body["messages"]) == 25
    assert body["total"] == 30


def test_search_limit_and_offset(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    for mid in ("2001", "2002", "2003", "2004"):
        _insert_message(
            db_conn,
            message_id=mid,
            guild_id=test_guild.id,
            channel_id=test_channel.id,
            author_id=test_user.id,
        )

    response = _search(http_client, test_session, test_guild.id, limit=2)
    assert _ids(response) == ["2004", "2003"]
    assert response.json()["total"] == 4

    response = _search(http_client, test_session, test_guild.id, limit=2, offset=2)
    assert _ids(response) == ["2002", "2001"]
    assert response.json()["total"] == 4

    # The last, partial page is still correct.
    response = _search(http_client, test_session, test_guild.id, limit=3, offset=3)
    assert _ids(response) == ["2001"]
    assert response.json()["total"] == 4

    # `sort=oldest` paginates the mirrored order.
    response = _search(http_client, test_session, test_guild.id, sort="oldest", limit=2)
    assert _ids(response) == ["2001", "2002"]

    response = _search(
        http_client, test_session, test_guild.id, sort="oldest", limit=2, offset=2
    )
    assert _ids(response) == ["2003", "2004"]


def test_search_offset_beyond_last_page(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    _insert_message(
        db_conn,
        message_id="2101",
        guild_id=test_guild.id,
        channel_id=test_channel.id,
        author_id=test_user.id,
    )

    response = _search(http_client, test_session, test_guild.id, offset=10)

    assert response.status_code == 200

    body = _envelope(response)
    assert body["messages"] == []
    assert body["total"] == 1


def test_search_total_independent_of_page(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    for mid in ("2201", "2202", "2203"):
        _insert_message(
            db_conn,
            message_id=mid,
            guild_id=test_guild.id,
            channel_id=test_channel.id,
            author_id=test_user.id,
        )

    for params in (
        {},
        {"limit": 1},
        {"limit": 2, "offset": 1},
        {"limit": 1, "offset": 3},
        {"sort": "oldest", "limit": 1},
    ):
        response = _search(http_client, test_session, test_guild.id, **params)

        assert response.status_code == 200
        assert response.json()["total"] == 3


def test_search_channel_id_on_every_result(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    second = system_create_channel(
        http_client, test_guild.id, "Second", admin_token=test_guild.admin_token
    )

    _insert_message(
        db_conn,
        message_id="2301",
        guild_id=test_guild.id,
        channel_id=test_channel.id,
        author_id=test_user.id,
    )
    _insert_message(
        db_conn,
        message_id="2302",
        guild_id=test_guild.id,
        channel_id=second.id,
        author_id=test_user.id,
    )

    response = _search(http_client, test_session, test_guild.id)

    assert response.status_code == 200

    by_id = {m["id"]: m["channel_id"] for m in response.json()["messages"]}
    assert by_id == {"2301": test_channel.id, "2302": second.id}


# ---------------------------------------------------------------------------
# Filters
# ---------------------------------------------------------------------------


def test_search_by_author_multi(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    other_response = http_client.post(
        "/api/system/users",
        json={"username": "search_author_2", "password": "12345678"},
        headers=SYSTEM_HEADERS,
    )
    assert other_response.status_code == 201
    other = other_response.json()["id"]

    _insert_message(
        db_conn,
        message_id="3001",
        guild_id=test_guild.id,
        channel_id=test_channel.id,
        author_id=test_user.id,
    )
    _insert_message(
        db_conn,
        message_id="3002",
        guild_id=test_guild.id,
        channel_id=test_channel.id,
        author_id=other,
    )

    response = _search(http_client, test_session, test_guild.id, authors=test_user.id)
    assert _ids(response) == ["3001"]

    response = _search(
        http_client, test_session, test_guild.id, authors=f"{test_user.id},{other}"
    )
    assert _ids(response) == ["3002", "3001"]


def test_search_by_channel_multi(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    second = system_create_channel(
        http_client, test_guild.id, "Second", admin_token=test_guild.admin_token
    )

    _insert_message(
        db_conn,
        message_id="3101",
        guild_id=test_guild.id,
        channel_id=test_channel.id,
        author_id=test_user.id,
    )
    _insert_message(
        db_conn,
        message_id="3102",
        guild_id=test_guild.id,
        channel_id=second.id,
        author_id=test_user.id,
    )

    response = _search(http_client, test_session, test_guild.id, channels=second.id)
    assert _ids(response) == ["3102"]

    response = _search(
        http_client, test_session, test_guild.id, channels=f"{test_channel.id},{second.id}"
    )
    assert _ids(response) == ["3102", "3101"]


def test_search_by_mentions(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    _insert_message(
        db_conn,
        message_id="3201",
        guild_id=test_guild.id,
        channel_id=test_channel.id,
        author_id=test_user.id,
        mention_user_ids=[int(test_user.id)],
    )
    _insert_message(
        db_conn,
        message_id="3202",
        guild_id=test_guild.id,
        channel_id=test_channel.id,
        author_id=test_user.id,
    )

    response = _search(http_client, test_session, test_guild.id, mentions=test_user.id)
    assert _ids(response) == ["3201"]

    message = response.json()["messages"][0]
    assert message["mentions"] == [test_user.id]


def test_search_by_mention_roles(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    seed_role(db_conn, test_guild.id, "7000001", "mods")

    _insert_message(
        db_conn,
        message_id="3301",
        guild_id=test_guild.id,
        channel_id=test_channel.id,
        author_id=test_user.id,
        mention_role_ids=[7000001],
    )
    _insert_message(
        db_conn,
        message_id="3302",
        guild_id=test_guild.id,
        channel_id=test_channel.id,
        author_id=test_user.id,
    )

    response = _search(
        http_client, test_session, test_guild.id, mention_roles="7000001"
    )

    assert _ids(response) == ["3301"]
    assert response.json()["messages"][0]["mention_roles"] == ["7000001"]


def test_search_includes_inline_reactions(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    _insert_message(
        db_conn,
        message_id="3351",
        guild_id=test_guild.id,
        channel_id=test_channel.id,
        author_id=test_user.id,
        content="reactme",
    )
    _insert_reaction(db_conn, "3351", test_user.id, "\U0001F44D")

    response = _search(http_client, test_session, test_guild.id, content="reactme")

    assert _ids(response) == ["3351"]

    reactions = response.json()["messages"][0]["reactions"]
    assert reactions == [
        {
            "emoji_id": None,
            "unicode_emoji": "\U0001F44D",
            "count": 1,
            "me": True,
        }
    ]


def test_search_by_has_attachments(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    _insert_file(db_conn, "500001", "attach-hash-1")
    _insert_message(
        db_conn,
        message_id="3401",
        guild_id=test_guild.id,
        channel_id=test_channel.id,
        author_id=test_user.id,
    )
    _insert_message(
        db_conn,
        message_id="3402",
        guild_id=test_guild.id,
        channel_id=test_channel.id,
        author_id=test_user.id,
    )
    _attach(db_conn, "3401", "500001")

    response = _search(
        http_client, test_session, test_guild.id, has_attachments="true"
    )
    assert _ids(response) == ["3401"]

    response = _search(
        http_client, test_session, test_guild.id, has_attachments="false"
    )
    assert _ids(response) == ["3402"]


def test_search_by_pinned(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    _insert_message(
        db_conn,
        message_id="3501",
        guild_id=test_guild.id,
        channel_id=test_channel.id,
        author_id=test_user.id,
        pinned=True,
    )
    _insert_message(
        db_conn,
        message_id="3502",
        guild_id=test_guild.id,
        channel_id=test_channel.id,
        author_id=test_user.id,
    )

    response = _search(http_client, test_session, test_guild.id, pinned="true")
    assert _ids(response) == ["3501"]

    response = _search(http_client, test_session, test_guild.id, pinned="false")
    assert _ids(response) == ["3502"]


def test_search_by_date_range(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    _insert_message(
        db_conn,
        message_id="3601",
        guild_id=test_guild.id,
        channel_id=test_channel.id,
        author_id=test_user.id,
        created_at="2020-01-01T00:00:00+00:00",
    )
    _insert_message(
        db_conn,
        message_id="3602",
        guild_id=test_guild.id,
        channel_id=test_channel.id,
        author_id=test_user.id,
        created_at="2021-06-01T00:00:00+00:00",
    )
    _insert_message(
        db_conn,
        message_id="3603",
        guild_id=test_guild.id,
        channel_id=test_channel.id,
        author_id=test_user.id,
        created_at="2022-01-01T00:00:00+00:00",
    )

    # after = 2020-06-01 (ms), inclusive; before = 2021-12-01, exclusive.
    after = 1590969600000
    before = 1638316800000

    response = _search(http_client, test_session, test_guild.id, after=str(after))
    assert _ids(response) == ["3603", "3602"]

    response = _search(http_client, test_session, test_guild.id, before=str(before))
    assert _ids(response) == ["3602", "3601"]

    response = _search(
        http_client,
        test_session,
        test_guild.id,
        after=str(after),
        before=str(before),
    )
    assert _ids(response) == ["3602"]


def test_search_by_author_types(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    bot = _create_bot(http_client, "search_bot")

    _create_webhook(db_conn, "600001", test_guild.id, test_channel.id)

    _insert_message(
        db_conn,
        message_id="3701",
        guild_id=test_guild.id,
        channel_id=test_channel.id,
        author_id=test_user.id,
    )
    _insert_message(
        db_conn,
        message_id="3702",
        guild_id=test_guild.id,
        channel_id=test_channel.id,
        author_id=bot,
    )
    _insert_message(
        db_conn,
        message_id="3703",
        guild_id=test_guild.id,
        channel_id=test_channel.id,
        webhook_id="600001",
    )

    assert _ids(
        _search(http_client, test_session, test_guild.id, author_types="user")
    ) == ["3701"]
    assert _ids(
        _search(http_client, test_session, test_guild.id, author_types="bot")
    ) == ["3702"]
    assert _ids(
        _search(http_client, test_session, test_guild.id, author_types="webhook")
    ) == ["3703"]
    assert _ids(
        _search(http_client, test_session, test_guild.id, author_types="user,bot")
    ) == ["3702", "3701"]
    assert _ids(
        _search(
            http_client,
            test_session,
            test_guild.id,
            author_types="user,bot,webhook",
        )
    ) == ["3703", "3702", "3701"]


def test_search_content_substring_and_case_insensitive(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    for mid, content in (
        ("3801", "Hello World"),
        ("3802", "goodbye"),
        ("3803", "nothing here"),
    ):
        _insert_message(
            db_conn,
            message_id=mid,
            guild_id=test_guild.id,
            channel_id=test_channel.id,
            author_id=test_user.id,
            content=content,
        )

    response = _search(http_client, test_session, test_guild.id, content="hello")
    assert _ids(response) == ["3801"]

    response = _search(http_client, test_session, test_guild.id, content="worl")
    assert _ids(response) == ["3801"]


def test_search_short_content_with_empty_date_range(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    _insert_message(
        db_conn,
        message_id="3851",
        guild_id=test_guild.id,
        channel_id=test_channel.id,
        author_id=test_user.id,
        content="он вне диапазона",
        created_at="2020-01-01T00:00:00+00:00",
    )
    _insert_message(
        db_conn,
        message_id="3852",
        guild_id=test_guild.id,
        channel_id=test_channel.id,
        author_id=test_user.id,
        content="совпадений нет",
        created_at="2022-01-01T00:00:00+00:00",
    )

    response = _search(
        http_client,
        test_session,
        test_guild.id,
        content="он",
        after="1609459200000",
        before="1672531200000",
    )

    assert response.status_code == 200
    assert _envelope(response) == {"messages": [], "total": 0}


def test_search_content_escapes_like_wildcards(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    _insert_message(
        db_conn,
        message_id="3901",
        guild_id=test_guild.id,
        channel_id=test_channel.id,
        author_id=test_user.id,
        content="100% sure",
    )
    _insert_message(
        db_conn,
        message_id="3902",
        guild_id=test_guild.id,
        channel_id=test_channel.id,
        author_id=test_user.id,
        content="1000 sure",
    )

    response = _search(http_client, test_session, test_guild.id, content="0%")
    assert _ids(response) == ["3901"]


def test_search_combined_filters(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    _insert_message(
        db_conn,
        message_id="4001",
        guild_id=test_guild.id,
        channel_id=test_channel.id,
        author_id=test_user.id,
        content="keep me",
        pinned=True,
    )
    _insert_message(
        db_conn,
        message_id="4002",
        guild_id=test_guild.id,
        channel_id=test_channel.id,
        author_id=test_user.id,
        content="keep me too",
    )

    response = _search(
        http_client,
        test_session,
        test_guild.id,
        authors=test_user.id,
        pinned="true",
        content="keep",
    )

    assert _ids(response) == ["4001"]


# ---------------------------------------------------------------------------
# R3: read_messages enforcement
# ---------------------------------------------------------------------------


def test_search_excludes_channel_denied_by_overwrite(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    second = system_create_channel(
        http_client, test_guild.id, "Hidden", admin_token=test_guild.admin_token
    )

    _insert_message(
        db_conn,
        message_id="4101",
        guild_id=test_guild.id,
        channel_id=test_channel.id,
        author_id=test_user.id,
    )
    _insert_message(
        db_conn,
        message_id="4102",
        guild_id=test_guild.id,
        channel_id=second.id,
        author_id=test_user.id,
    )

    _deny_read_messages(db_conn, test_guild.id, second.id)

    response = _search(http_client, test_session, test_guild.id)

    assert response.status_code == 200
    assert _ids(response) == ["4101"]


def test_search_unreadable_channels_are_silently_excluded(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    _insert_message(
        db_conn,
        message_id="4201",
        guild_id=test_guild.id,
        channel_id=test_channel.id,
        author_id=test_user.id,
    )

    # Base permissions lose read_messages; with no channel overwrite the
    # channel becomes unreadable, and search returns an empty list (never 403).
    _set_everyone_permissions(db_conn, test_guild.id, 0)

    response = _search(http_client, test_session, test_guild.id, channels=test_channel.id)

    assert response.status_code == 200

    body = _envelope(response)
    assert body["messages"] == []
    assert body["total"] == 0


def test_search_allows_channel_by_overwrite_when_base_is_unreadable(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    second = system_create_channel(
        http_client, test_guild.id, "Visible", admin_token=test_guild.admin_token
    )

    _insert_message(
        db_conn,
        message_id="4301",
        guild_id=test_guild.id,
        channel_id=test_channel.id,
        author_id=test_user.id,
    )
    _insert_message(
        db_conn,
        message_id="4302",
        guild_id=test_guild.id,
        channel_id=second.id,
        author_id=test_user.id,
    )

    _set_everyone_permissions(db_conn, test_guild.id, 0)
    _allow_read_messages(db_conn, test_guild.id, second.id)

    response = _search(http_client, test_session, test_guild.id)

    assert response.status_code == 200
    assert _ids(response) == ["4302"]


def test_search_requires_exact_read_messages_on_base(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    _insert_message(
        db_conn,
        message_id="4401",
        guild_id=test_guild.id,
        channel_id=test_channel.id,
        author_id=test_user.id,
    )

    _set_everyone_permissions(db_conn, test_guild.id, 0)
    seed_role(
        db_conn,
        test_guild.id,
        "8000001",
        "readers",
        permissions=READ_MESSAGES,
    )

    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.member_roles (guild_id, role_id, user_id)"
            " VALUES (%s, %s, %s)",
            (test_guild.id, "8000001", test_user.id),
        )

    response = _search(http_client, test_session, test_guild.id)

    assert response.status_code == 200
    assert _ids(response) == ["4401"]


def test_search_scoped_to_guild(
    db_conn, http_client, test_guild, test_channel, test_user, test_session
):
    other_guild_response = http_client.post(
        "/api/system/guilds",
        json={"name": "OtherGuild"},
        headers=SYSTEM_HEADERS,
    )
    assert other_guild_response.status_code == 201
    other_guild = other_guild_response.json()["id"]

    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.channels (id, guild_id, name, kind) VALUES (%s, %s, %s, 0)",
            ("9000001", other_guild, "Elsewhere"),
        )

    other_channel = "9000001"

    _insert_message(
        db_conn,
        message_id="4501",
        guild_id=test_guild.id,
        channel_id=test_channel.id,
        author_id=test_user.id,
    )
    _insert_message(
        db_conn,
        message_id="4502",
        guild_id=other_guild,
        channel_id=other_channel,
        author_id=test_user.id,
    )

    response = _search(http_client, test_session, test_guild.id)

    assert _ids(response) == ["4501"]
