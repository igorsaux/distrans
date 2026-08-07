# Tests for the `embeds` field of POST /api/channels/{channel_id}/messages and
# its projection in GET /api/channels/{channel_id}/messages.
#
# POST - R8 optional "embeds" must be null or an array of at most
#        api.messages.max_embeds valid rich embeds.

import pytest


def _post_message(http_client, test_session, channel_id, payload):
    return http_client.post(
        f"/api/channels/{channel_id}/messages",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
        json=payload,
    )


def _get_messages(http_client, test_session, channel_id):
    response = http_client.get(
        f"/api/channels/{channel_id}/messages",
        headers={"Authorization": f"Bearer {test_session.access_token}"},
    )

    assert response.status_code == 200

    return response.json()


def _embeds_of(http_client, test_session, channel_id, message_id):
    for message in _get_messages(http_client, test_session, channel_id):
        if message["id"] == message_id:
            return message["embeds"]

    raise AssertionError(f"message {message_id} not found")


def _post_with_embeds(http_client, test_session, channel_id, embeds, content="with embed"):
    response = _post_message(
        http_client,
        test_session,
        channel_id,
        {"content": content, "embeds": embeds},
    )

    assert response.status_code == 201

    return response.json()["id"]


# R8 - success path and wire shape


def test_post_message_minimal_embed_shape(http_client, test_channel, test_session):
    message_id = _post_with_embeds(
        http_client, test_session, test_channel.id, [{"title": "Hello"}]
    )

    assert _embeds_of(http_client, test_session, test_channel.id, message_id) == [
        {
            "type": "rich",
            "title": "Hello",
            "description": None,
            "url": None,
            "timestamp": None,
            "color": None,
            "footer": None,
            "image": None,
            "thumbnail": None,
            "video": None,
            "author": None,
            "fields": [],
        }
    ]


def test_post_message_full_embed_round_trip(http_client, test_channel, test_session):
    embed = {
        "type": "rich",
        "title": "Title",
        "description": "Description",
        "url": "https://example.com/embed",
        "timestamp": 1700000000000,
        "color": 16711680,
        "footer": {"text": "footer", "icon_url": "https://example.com/footer.png"},
        "image": {"url": "https://example.com/image.png"},
        "thumbnail": {"url": "https://example.com/thumb.png"},
        "video": {"url": "https://example.com/video.mp4"},
        "author": {
            "name": "author",
            "url": "https://example.com/author",
            "icon_url": "https://example.com/author.png",
        },
        "fields": [
            {"name": "field", "value": "value", "inline": True},
            {"name": "second", "value": "value", "inline": False},
        ],
    }

    message_id = _post_with_embeds(http_client, test_session, test_channel.id, [embed])

    stored = _embeds_of(http_client, test_session, test_channel.id, message_id)

    assert stored == [embed]


def test_post_message_embeds_default_type_rich(http_client, test_channel, test_session):
    message_id = _post_with_embeds(
        http_client, test_session, test_channel.id, [{"type": "rich", "title": "t"}]
    )

    stored = _embeds_of(http_client, test_session, test_channel.id, message_id)

    assert stored[0]["type"] == "rich"


def test_post_message_embeds_null_is_no_embeds(http_client, test_channel, test_session):
    message_id = _post_with_embeds(http_client, test_session, test_channel.id, None)

    assert _embeds_of(http_client, test_session, test_channel.id, message_id) is None


def test_post_message_embeds_empty_array_is_no_embeds(
    http_client, test_channel, test_session
):
    message_id = _post_with_embeds(http_client, test_session, test_channel.id, [])

    assert _embeds_of(http_client, test_session, test_channel.id, message_id) is None


def test_post_message_embeds_sanitizes_forbidden_codepoints(
    http_client, test_channel, test_session
):
    message_id = _post_with_embeds(
        http_client,
        test_session,
        test_channel.id,
        [{"title": "a\u200Bb\u202Ec\u2800d"}],
    )

    stored = _embeds_of(http_client, test_session, test_channel.id, message_id)

    assert stored[0]["title"] == "abcd"


def test_post_message_embeds_normalizes_text(http_client, test_channel, test_session):
    message_id = _post_with_embeds(
        http_client,
        test_session,
        test_channel.id,
        [{"title": "\uFF21\uFF22", "fields": [{"name": "\uFB01", "value": "x"}]}],
    )

    stored = _embeds_of(http_client, test_session, test_channel.id, message_id)

    assert stored[0]["title"] == "AB"
    assert stored[0]["fields"][0]["name"] == "fi"


# R8 - failure paths


@pytest.mark.parametrize(
    "embeds,message",
    [
        ({}, "'embeds' is not an array"),
        ([1], "Bad embed: is not an object"),
        ([{"type": "video"}], "Bad embed: unknown 'type' value"),
        ([{"title": 1}], "Bad embed: field 'title' is not a string"),
        ([{"title": "a" * 257}], "Bad embed: field 'title' is too long"),
        ([{"description": "a" * 4097}], "Bad embed: field 'description' is too long"),
        ([{"url": "a" * 2049}], "Bad embed: field 'url' is too long"),
        (
            [{"timestamp": "tomorrow"}],
            "Bad embed: field 'timestamp' is not an integer",
        ),
        ([{"timestamp": -1}], "Bad embed: field 'timestamp' is invalid"),
        ([{"color": "red"}], "Bad embed: field 'color' is not an integer"),
        ([{"color": 16777216}], "Bad embed: field 'color' is invalid"),
        ([{"footer": "x"}], "Bad embed: field 'footer' is not an object"),
        ([{"footer": {}}], "Bad embed: field 'footer' is missing 'text'"),
        (
            [{"footer": {"text": "a" * 2049}}],
            "Bad embed: field 'text' of a footer is too long",
        ),
        ([{"image": {}}], "Bad embed: field 'image' is missing 'url'"),
        ([{"thumbnail": {}}], "Bad embed: field 'thumbnail' is missing 'url'"),
        ([{"video": {}}], "Bad embed: field 'video' is missing 'url'"),
        ([{"author": []}], "Bad embed: field 'author' is not an object"),
        ([{"author": {}}], "Bad embed: field 'author' is missing 'name'"),
        (
            [{"author": {"name": "a" * 257}}],
            "Bad embed: field 'name' of an author is too long",
        ),
        ([{"fields": {}}], "Bad embed: field 'fields' is not an array"),
        ([{"fields": [{"name": "n", "value": "v"}] * 26}], "Bad embed: too many fields"),
        ([{"fields": [1]}], "Bad embed: field is not an object"),
        ([{"fields": [{"value": "v"}]}], "Bad embed: field is missing 'name'"),
        ([{"fields": [{"name": "n"}]}], "Bad embed: field is missing 'value'"),
        (
            [{"fields": [{"name": "a" * 257, "value": "v"}]}],
            "Bad embed: field 'name' of a field is too long",
        ),
        (
            [{"fields": [{"name": "n", "value": "a" * 1025}]}],
            "Bad embed: field 'value' of a field is too long",
        ),
        (
            [{"fields": [{"name": "n", "value": "v", "inline": 1}]}],
            "Bad embed: field 'inline' of a field is not a bool",
        ),
        (
            [{"description": "a" * 4096, "fields": [{"name": "n", "value": "a" * 1024} ] * 2}],
            "Bad embed: content is too long",
        ),
    ],
)
def test_post_message_bad_embed(
    http_client, test_channel, test_session, embeds, message
):
    response = _post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": "hi", "embeds": embeds},
    )

    assert response.status_code == 400
    assert response.json()["message"] == message


def test_post_message_too_many_embeds(http_client, test_channel, test_session):
    response = _post_message(
        http_client,
        test_session,
        test_channel.id,
        {"content": "hi", "embeds": [{"title": "t"}] * 11},
    )

    assert response.status_code == 400
    assert response.json()["message"] == "'embeds' is too large"


def test_post_message_embeds_max_fields_ok(http_client, test_channel, test_session):
    fields = [{"name": f"n{i}", "value": "v"} for i in range(25)]

    message_id = _post_with_embeds(
        http_client, test_session, test_channel.id, [{"fields": fields}]
    )

    stored = _embeds_of(http_client, test_session, test_channel.id, message_id)

    assert len(stored[0]["fields"]) == 25


def test_post_message_embeds_max_count_ok(http_client, test_channel, test_session):
    message_id = _post_with_embeds(
        http_client,
        test_session,
        test_channel.id,
        [{"title": f"t{i}"} for i in range(10)],
    )

    assert len(_embeds_of(http_client, test_session, test_channel.id, message_id)) == 10
