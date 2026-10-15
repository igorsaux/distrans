# Tests for POST /api/webhooks/{webhook_id}/{token}/github (GitHub-compatible).
#
# Requirement numbering mirrors src/route/webhooks/id/github.zig.
#
#   R1 - the webhook exists, is live and the token hashes to token_hash (404)
#   R2 - the X-GitHub-Event header must be present (400)
#   R3 - body non-empty, application/json or form-encoded (415), bounded by
#        api.github.max_body_bytes (413)
#   R4 - the JSON payload is the body or the `payload` form field (400 on error)
#   R5 - the event is rendered to one embed and posted; ignored events post
#        nothing
#   R6 - success is 204 No Content

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # tests/api

from webhooks_common import (  # noqa: E402
    create_webhook,
    delete_webhook,
    get_messages,
)

GITHUB_PATH = "/api/webhooks/{webhook_id}/{token}/github"


def execute_github(http_client, webhook_id, token, event, payload, form=False):
    headers = {}
    if event is not None:
        headers["X-GitHub-Event"] = event

    if form:
        return http_client.post(
            GITHUB_PATH.format(webhook_id=webhook_id, token=token),
            data={"payload": json.dumps(payload)},
            headers=headers,
        )

    return http_client.post(
        GITHUB_PATH.format(webhook_id=webhook_id, token=token),
        json=payload,
        headers=headers,
    )


def execute_github_raw(http_client, webhook_id, token, event, body, content_type):
    headers = {"Content-Type": content_type}
    if event is not None:
        headers["X-GitHub-Event"] = event

    return http_client.post(
        GITHUB_PATH.format(webhook_id=webhook_id, token=token),
        content=body,
        headers=headers,
    )


def repo(name="distrans"):
    return {
        "name": name,
        "full_name": f"octocat/{name}",
        "html_url": f"https://github.com/octocat/{name}",
    }


def sender(login="octocat"):
    return {
        "login": login,
        "html_url": f"https://github.com/{login}",
        "avatar_url": "https://avatars.githubusercontent.com/u/1?v=4",
    }


def push_payload():
    return {
        "ref": "refs/heads/main",
        "compare": "https://github.com/octocat/distrans/compare/a...b",
        "repository": repo(),
        "sender": sender(),
        "commits": [
            {
                "id": "abcdef1234567890abcdef1234567890abcdef12",
                "url": "https://github.com/octocat/distrans/commit/abcdef1234567890abcdef1234567890abcdef12",
                "message": "Fix the thing",
                "author": {"name": "Mona"},
            }
        ],
    }


def issue_payload(action="opened", title="Something broke", body="It is broken"):
    return {
        "action": action,
        "repository": repo(),
        "sender": sender(),
        "issue": {
            "number": 7,
            "title": title,
            "body": body,
            "html_url": "https://github.com/octocat/distrans/issues/7",
        },
    }


def create_hook(http_client, test_guild, test_channel):
    return create_webhook(
        http_client, test_guild.admin_token, test_channel.id, name="GitHub"
    )


# R1 - an unknown webhook is 404
def test_github_unknown_webhook(http_client):
    response = execute_github(http_client, 1, "sometoken", "push", push_payload())

    assert response.status_code == 404
    assert response.json()["message"] == "Webhook not found"


# R1 - a wrong token is 404
def test_github_wrong_token(http_client, test_guild, test_channel):
    created = create_hook(http_client, test_guild, test_channel)

    response = execute_github(http_client, created["id"], "wrong-token", "push", push_payload())

    assert response.status_code == 404


# R1 - a soft-deleted webhook cannot execute
def test_github_after_delete(http_client, test_guild, test_channel):
    created = create_hook(http_client, test_guild, test_channel)
    delete_webhook(http_client, test_guild.admin_token, created["id"])

    response = execute_github(http_client, created["id"], created["token"], "push", push_payload())

    assert response.status_code == 404


# R2 - the event header is required
def test_github_missing_event(http_client, test_guild, test_channel):
    created = create_hook(http_client, test_guild, test_channel)

    response = execute_github(http_client, created["id"], created["token"], None, push_payload())

    assert response.status_code == 400
    assert response.json()["message"] == "Missing event"


# R3 - an empty body is 400
def test_github_empty_body(http_client, test_guild, test_channel):
    created = create_hook(http_client, test_guild, test_channel)

    response = execute_github_raw(
        http_client, created["id"], created["token"], "push", b"", "application/json"
    )

    assert response.status_code == 400


# R3 - a non JSON/form content type is 415
def test_github_wrong_content_type(http_client, test_guild, test_channel):
    created = create_hook(http_client, test_guild, test_channel)

    response = execute_github_raw(
        http_client, created["id"], created["token"], "push", b"{}", "text/plain"
    )

    assert response.status_code == 415


# R3 - a body over max_body_bytes is 413
def test_github_body_too_large(http_client, test_guild, test_channel):
    created = create_hook(http_client, test_guild, test_channel)

    response = execute_github_raw(
        http_client,
        created["id"],
        created["token"],
        "push",
        b"x" * 5000,
        "application/json",
    )

    assert response.status_code == 413


# R4 - malformed JSON is 400
def test_github_malformed_json(http_client, test_guild, test_channel):
    created = create_hook(http_client, test_guild, test_channel)

    response = execute_github_raw(
        http_client, created["id"], created["token"], "push", b"{not json", "application/json"
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Bad JSON"


# R4 - a non-object payload is 400
def test_github_non_object_json(http_client, test_guild, test_channel):
    created = create_hook(http_client, test_guild, test_channel)

    response = execute_github_raw(
        http_client, created["id"], created["token"], "push", b"[]", "application/json"
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Expected an object"


# R4 - a form-encoded `payload` field is missing/unusable
def test_github_missing_form_payload(http_client, test_guild, test_channel):
    created = create_hook(http_client, test_guild, test_channel)

    response = http_client.post(
        GITHUB_PATH.format(webhook_id=created["id"], token=created["token"]),
        data={"other": "1"},
        headers={"X-GitHub-Event": "push"},
    )

    assert response.status_code == 400
    assert response.json()["message"] == "Bad JSON"


# R5 - a push renders one embed and posts one message
def test_github_push_creates_message(http_client, test_guild, test_channel, test_session):
    created = create_hook(http_client, test_guild, test_channel)

    response = execute_github(http_client, created["id"], created["token"], "push", push_payload())

    assert response.status_code == 204, response.content

    messages = get_messages(http_client, test_session.access_token, test_channel.id)
    assert len(messages) == 1

    message = messages[0]
    assert message["content"] == ""
    assert message["webhook_id"] == created["id"]
    assert message["author_id"] is None
    assert message["mentions"] == []

    embed = message["embeds"][0]
    assert embed["title"] == "[distrans:main] 1 new commit"
    assert embed["color"] == 0x7289DA
    assert embed["author"]["name"] == "octocat"
    assert "Fix the thing" in embed["description"]


# R5 - a form-encoded delivery works too
def test_github_form_encoded(http_client, test_guild, test_channel, test_session):
    created = create_hook(http_client, test_guild, test_channel)

    response = execute_github(
        http_client, created["id"], created["token"], "push", push_payload(), form=True
    )

    assert response.status_code == 204, response.content

    messages = get_messages(http_client, test_session.access_token, test_channel.id)
    assert len(messages) == 1
    assert messages[0]["embeds"][0]["title"] == "[distrans:main] 1 new commit"


# R5 - an issue gets its own title/color
def test_github_issue_opened(http_client, test_guild, test_channel, test_session):
    created = create_hook(http_client, test_guild, test_channel)

    response = execute_github(
        http_client, created["id"], created["token"], "issues", issue_payload()
    )

    assert response.status_code == 204

    messages = get_messages(http_client, test_session.access_token, test_channel.id)
    embed = messages[0]["embeds"][0]
    assert embed["title"] == "[octocat/distrans] Issue opened: #7 Something broke"
    assert embed["color"] == 0xEB4841
    assert embed["description"] == "It is broken"


@pytest.mark.parametrize("action,title", [("created", "New star added"), ("deleted", "Star removed")])
def test_github_star_actions(http_client, test_guild, test_channel, test_session, action, title):
    created = create_hook(http_client, test_guild, test_channel)
    payload = {
        "action": action,
        "repository": repo(),
        "sender": sender(),
        "starred_at": "2026-10-15T07:01:44Z" if action == "created" else None,
    }

    response = execute_github(http_client, created["id"], created["token"], "star", payload)

    assert response.status_code == 204
    messages = get_messages(http_client, test_session.access_token, test_channel.id)
    assert messages[0]["embeds"][0]["title"] == f"[octocat/distrans] {title}"


def test_github_watch_is_not_rendered_as_star(http_client, test_guild, test_channel, test_session):
    created = create_hook(http_client, test_guild, test_channel)
    payload = {"action": "started", "repository": repo(), "sender": sender()}

    response = execute_github(http_client, created["id"], created["token"], "watch", payload)

    assert response.status_code == 204
    embed = get_messages(http_client, test_session.access_token, test_channel.id)[0]["embeds"][0]
    assert embed["title"] == "[octocat/distrans] New repository watcher"


def test_github_issue_comment_identifies_pull_request(http_client, test_guild, test_channel, test_session):
    created = create_hook(http_client, test_guild, test_channel)
    payload = {
        "action": "created",
        "repository": repo(),
        "sender": sender(),
        "issue": {
            "number": 7,
            "title": "Improve the thing",
            "html_url": "https://github.com/octocat/distrans/pull/7",
            "pull_request": {"url": "https://api.github.com/repos/octocat/distrans/pulls/7"},
        },
        "comment": {
            "body": "Looks good",
            "html_url": "https://github.com/octocat/distrans/pull/7#issuecomment-1",
            "user": sender(),
        },
    }

    response = execute_github(http_client, created["id"], created["token"], "issue_comment", payload)

    assert response.status_code == 204
    embed = get_messages(http_client, test_session.access_token, test_channel.id)[0]["embeds"][0]
    assert embed["title"] == "[octocat/distrans] New comment on pull request #7: Improve the thing"


# R5 - a ping posts nothing
def test_github_ping_ignored(http_client, test_guild, test_channel, test_session):
    created = create_hook(http_client, test_guild, test_channel)

    response = execute_github(
        http_client, created["id"], created["token"], "ping", {"zen": "keep it logically awesome"}
    )

    assert response.status_code == 204
    assert get_messages(http_client, test_session.access_token, test_channel.id) == []


# R5 - an unsupported event posts nothing
def test_github_unsupported_event(http_client, test_guild, test_channel, test_session):
    created = create_hook(http_client, test_guild, test_channel)

    response = execute_github(
        http_client, created["id"], created["token"], "future_event", {"action": "created"}
    )

    assert response.status_code == 204
    assert get_messages(http_client, test_session.access_token, test_channel.id) == []


# R5 - an unsupported action on a supported event posts nothing
def test_github_unsupported_action(http_client, test_guild, test_channel, test_session):
    created = create_hook(http_client, test_guild, test_channel)

    response = execute_github(
        http_client, created["id"], created["token"], "issues", issue_payload(action="labeled")
    )

    assert response.status_code == 204
    assert get_messages(http_client, test_session.access_token, test_channel.id) == []


# R5 - a skipped check run posts nothing
def test_github_check_run_skipped(http_client, test_guild, test_channel, test_session):
    created = create_hook(http_client, test_guild, test_channel)

    payload = {
        "action": "completed",
        "repository": repo(),
        "sender": sender(),
        "check_run": {
            "name": "build",
            "check_suite": {
                "conclusion": "skipped",
                "head_sha": "abc",
                "head_branch": "main",
            },
        },
    }

    response = execute_github(http_client, created["id"], created["token"], "check_run", payload)

    assert response.status_code == 204
    assert get_messages(http_client, test_session.access_token, test_channel.id) == []


# R5 - long text is truncated with an ellipsis
def test_github_title_truncated(http_client, test_guild, test_channel, test_session):
    created = create_hook(http_client, test_guild, test_channel)

    payload = issue_payload(title="A" * 200)
    response = execute_github(
        http_client, created["id"], created["token"], "issues", payload
    )

    assert response.status_code == 204

    messages = get_messages(http_client, test_session.access_token, test_channel.id)
    title = messages[0]["embeds"][0]["title"]
    assert len(title) <= 70
    assert title.endswith("...")


# R5 - embed text never produces mentions
def test_github_no_mentions(http_client, test_guild, test_channel, test_session):
    created = create_hook(http_client, test_guild, test_channel)

    payload = issue_payload(title="ping <@123> @everyone", body="<@456>")
    response = execute_github(
        http_client, created["id"], created["token"], "issues", payload
    )

    assert response.status_code == 204

    messages = get_messages(http_client, test_session.access_token, test_channel.id)
    assert messages[0]["mentions"] == []
    assert messages[0]["mention_everyone"] is False


# Routing - GET on the github path is 405 with Allow
def test_github_wrong_method(http_client, test_guild, test_channel):
    created = create_hook(http_client, test_guild, test_channel)

    response = http_client.get(
        GITHUB_PATH.format(webhook_id=created["id"], token=created["token"])
    )

    assert response.status_code == 405
    assert response.headers["Allow"] == "POST"


# Routing - an unknown subroute is 404
def test_github_unknown_subroute(http_client, test_guild, test_channel):
    created = create_hook(http_client, test_guild, test_channel)

    response = http_client.post(
        f"/api/webhooks/{created['id']}/{created['token']}/notgithub",
        json=push_payload(),
        headers={"X-GitHub-Event": "push"},
    )

    assert response.status_code == 404
