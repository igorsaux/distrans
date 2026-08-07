import dataclasses
import json
import sys
import time
from pathlib import Path

import httpx
import psycopg
import psycopg.rows
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent / "api" / "files"))
sys.path.insert(0, str(Path(__file__).resolve().parent / "api" / "notifications"))

import mock_push
import mock_s3

CONFIG_PATH = Path(__file__).resolve().parent.parent / "config.tests.json"

with CONFIG_PATH.open() as f:
    CONFIG = json.load(f)

DB_URL = CONFIG["db"]["conninfo"]

bind = CONFIG["socket"]["bind"]
assert bind["type"] == "inet", "httpx requires an inet socket"
host = bind["host"]
if ":" in host:  # IPv6 literal must be bracketed in URLs
    host = f"[{host}]"
BASE_URL = f"http://{host}:{bind['port']}"

SYSTEM_TOKEN = CONFIG["system"]["token"]
SYSTEM_HEADERS = {"Authorization": f"Bearer {SYSTEM_TOKEN}"}


@pytest.fixture
def system_headers():
    return dict(SYSTEM_HEADERS)


TABLES_TO_TRUNCATE = [
    "app.users",
    "app.guilds",
    "app.roles",
    "app.channels",
    "app.messages",
    "app.message_attachments",
    "app.message_reactions",
    "app.emojis",
    "app.files",
    "app.bot_tokens",
    "app.refresh_tokens",
    "app.webhooks",
    "app.audit_log",
]


@pytest.fixture(scope="session")
def db_conn():
    with psycopg.connect(
        DB_URL, row_factory=psycopg.rows.dict_row, autocommit=True
    ) as conn:
        yield conn


@pytest.fixture(scope="session", autouse=True)
def s3_mock():
    # The server under test connects to this on demand (at upload time), so it
    # only has to be up before the first upload — no ordering against the
    # externally started server is needed.
    mock_s3.start()

    yield mock_s3.mock_s3

    mock_s3.stop()


@pytest.fixture(autouse=True)
def _reset_s3(s3_mock):
    yield
    s3_mock.reset()


@pytest.fixture(scope="session", autouse=True)
def push_mock():
    # Like the S3 mock: the server connects on demand when a notification is
    # delivered, so the mock only has to be up before the first send.
    mock_push.start()

    yield mock_push.mock_push

    mock_push.stop()


@pytest.fixture(autouse=True)
def _reset_push(push_mock):
    yield
    push_mock.reset()


@pytest.fixture(scope="session")
def http_client():
    with httpx.Client(base_url=BASE_URL, timeout=10.0) as client:
        yield client


@pytest.fixture(autouse=True)
def clean_db(db_conn):
    yield
    tables = ", ".join(TABLES_TO_TRUNCATE)
    query = f"TRUNCATE TABLE {tables} RESTART IDENTITY CASCADE;"

    # The server may briefly hold locks on these tables from a finished
    # request; a deadlock (which aborts the TRUNCATE) is possible, retry.
    for attempt in range(10):
        try:
            with db_conn.cursor() as cur:
                cur.execute(query)
            break
        except psycopg.errors.DeadlockDetected:
            db_conn.rollback()

            if attempt == 9:
                raise

            time.sleep(0.1 * (attempt + 1))


def system_create_user(
    http_client, username, password="12345678", display_name=None
):
    payload = {"username": username, "password": password}

    if display_name is not None:
        payload["display_name"] = display_name

    response = http_client.post(
        "/api/system/users", json=payload, headers=SYSTEM_HEADERS
    )
    assert response.status_code == 201

    return response.json()


def system_create_guild(http_client, name):
    payload = {"name": name}

    response = http_client.post(
        "/api/system/guilds", json=payload, headers=SYSTEM_HEADERS
    )
    assert response.status_code == 201

    body = response.json()

    return TestGuild(id=body["id"], name=name, admin_token="")


def system_create_channel(
    http_client, guild_id, name, kind="channel", parent_id=None, topic=None, admin_token=None
):
    payload = {"name": name, "kind": kind}

    if parent_id is not None:
        payload["parent_id"] = parent_id

    if topic is not None:
        payload["topic"] = topic

    headers = (
        {"Authorization": f"Bearer {admin_token}"} if admin_token else SYSTEM_HEADERS
    )

    response = http_client.post(
        f"/api/guilds/{guild_id}/channels", json=payload, headers=headers
    )
    assert response.status_code == 201

    body = response.json()

    return TestChannel(id=body["id"], name=name)


def seed_role(
    db_conn,
    guild_id,
    role_id,
    name,
    position=None,
    permissions=0,
    color=None,
    mentionable=True,
):
    """Insert a role with a unique position, mirroring the API's bottom insert.

    Role positions are unique per guild (`@everyone` is 0). A raw insert must
    therefore avoid collisions: roles at/above the target position are shifted
    up by one and the new role lands on `target` (1 when unset). This matches
    `POST /guilds/{id}/roles`, which always inserts at the bottom.
    """
    # `@everyone` (role id = guild id) is pinned to position 0.
    if int(role_id) == int(guild_id):
        target = 0
    else:
        target = 1 if position is None or int(position) < 1 else int(position)

    with db_conn.cursor() as cur:
        cur.execute(
            "UPDATE app.roles SET position = position + 1"
            " WHERE guild_id = %s AND id <> guild_id AND position >= %s",
            (guild_id, target),
        )
        cur.execute(
            "INSERT INTO app.roles"
            " (id, guild_id, name, position, permissions, color, mentionable)"
            " VALUES (%s, %s, %s, %s, %s, %s, %s)",
            (
                role_id,
                guild_id,
                name,
                target,
                int(permissions).to_bytes(16),
                color,
                mentionable,
            ),
        )


def system_login(http_client, username, password="12345678"):
    response = http_client.post(
        "/api/auth/token",
        json={"grant_type": "password", "username": username, "password": password},
    )

    assert response.status_code == 200

    body = response.json()
    access_token = body["access_token"]

    cookie = response.headers["set-cookie"]
    refresh_token = cookie.split("=")[1].split(";")[0]

    return access_token, refresh_token


@dataclasses.dataclass(frozen=True)
class TestUser:
    id: str
    username: str
    password: str


@pytest.fixture
def test_user(http_client):
    username = "anon"
    user = system_create_user(http_client, username=username)

    yield TestUser(
        id=user["id"],
        username=username,
        password="12345678",
    )


@dataclasses.dataclass(frozen=True)
class TestSession:
    access_token: str
    refresh_token: str


@pytest.fixture
def test_session(http_client, test_user):
    access_token, refresh_token = system_login(
        http_client, test_user.username, test_user.password
    )

    yield TestSession(access_token=access_token, refresh_token=refresh_token)


@dataclasses.dataclass(frozen=True)
class TestGuild:
    id: str
    name: str
    admin_token: str


@pytest.fixture
def test_guild(http_client):
    guild = system_create_guild(http_client, name="TestGuild")

    # A user with a superuser role (all permission bits) granted via
    # POST /api/system/superuser; use the token for endpoints requiring
    # guild-level rights (e.g. create_channels).
    admin = system_create_user(http_client, username=f"guild_admin_{guild.id}")

    response = http_client.post(
        "/api/system/superuser",
        json={"guild_id": guild.id, "user_id": admin["id"]},
        headers=SYSTEM_HEADERS,
    )
    assert response.status_code == 201

    access_token, _ = system_login(http_client, f"guild_admin_{guild.id}")

    yield TestGuild(id=guild.id, name=guild.name, admin_token=access_token)


@dataclasses.dataclass(frozen=True)
class TestChannel:
    id: str
    name: str


@pytest.fixture
def test_channel(http_client, test_guild):
    channel = system_create_channel(
        http_client,
        test_guild.id,
        name="TestChannel",
        admin_token=test_guild.admin_token,
    )

    yield TestChannel(id=channel.id, name=channel.name)


@dataclasses.dataclass(frozen=True)
class TestCategory:
    id: str
    name: str


@pytest.fixture
def test_category(http_client, test_guild):
    category = system_create_channel(
        http_client,
        test_guild.id,
        name="TestCategory",
        kind="category",
        admin_token=test_guild.admin_token,
    )

    yield TestCategory(id=category.id, name=category.name)


@dataclasses.dataclass(frozen=True)
class TestMessage:
    id: str
    content: str


@pytest.fixture
def test_message(db_conn, test_guild, test_channel, test_user):
    message = TestMessage(id="34661246", content="Test Message")

    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.messages (id, channel_id, guild_id, author_id, content)"
            " SELECT %s, c.id, c.guild_id, %s, %s FROM app.channels c WHERE c.id = %s",
            (message.id, test_user.id, message.content, test_channel.id),
        )

    yield message
