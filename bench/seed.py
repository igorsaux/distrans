#!/usr/bin/env python3
"""Seed distrans_bench with a deterministic synthetic dataset for benchmarking.

Run with the project venv:
    .venv/bin/python bench/seed.py

Creates: 1 guild, 1 category + N text channels, one admin superuser (login-able),
N bulk users, M messages with reactions and attachments, and a small file pool.
Existing app.* data is truncated first (CASCADE), so the script is re-runnable.
Prints a JSON summary to stdout (and writes bench/seed.json).
"""

import json
import os
import random
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import httpx
import psycopg

ROOT = Path(__file__).resolve().parent.parent
CONFIG_PATH = Path(os.environ.get("BENCH_CONFIG", ROOT / "config.bench.json"))

with CONFIG_PATH.open() as f:
    CONFIG = json.load(f)

DB_URL = CONFIG["db"]["conninfo"]
SYSTEM_TOKEN = CONFIG["system"]["token"]
ADMIN_PASSWORD = os.environ.get("BENCH_ADMIN_PASSWORD", "benchpass123")

bind = CONFIG["socket"]["bind"]
host = bind["host"]
if ":" in host:
    host = f"[{host}]"
BASE_URL = f"http://{host}:{bind['port']}"
SYSTEM_HEADERS = {"Authorization": f"Bearer {SYSTEM_TOKEN}"}

TARGET_USERS = int(os.environ.get("BENCH_USERS", "5000"))
TEXT_CHANNELS = int(os.environ.get("BENCH_CHANNELS", "60"))
MESSAGES_PER_CHANNEL = int(os.environ.get("BENCH_MESSAGES_PER_CHANNEL", "2000"))
REACTION_EVERY = int(os.environ.get("BENCH_REACTION_EVERY", "5"))
ATTACHMENT_EVERY = int(os.environ.get("BENCH_ATTACHMENT_EVERY", "25"))
FILE_POOL = 50

USER_BASE = 100_000_000_000_000_000
CHANNEL_BASE = 200_000_000_000_000_000
MESSAGE_BASE = 300_000_000_000_000_000

UNICODE_EMOJIS = ["\U0001f600", "\U0001f602", "\U0001f44d", "\U0001f525", "\U0001f389",
                  "\u2764\ufe0f", "\U0001f680", "\U0001f440", "\U0001f4af", "\U0001f642"]

WORDS = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel",
         "india", "juliet", "kilo", "lima", "mike", "november", "oscar", "papa",
         "quebec", "romeo", "sierra", "tango", "uniform", "victor", "whisky",
         "xray", "yankee", "zulu", "benchmark", "message", "channel", "guild"]

DATE_START = datetime(2024, 1, 1, tzinfo=timezone.utc)
DATE_SPAN = timedelta(days=365 * 2)


def log(msg):
    print(f"[seed] {msg}", file=sys.stderr, flush=True)


def api_login(client, username, password):
    r = client.post("/api/auth/token", json={
        "grant_type": "password", "username": username, "password": password,
    })
    r.raise_for_status()
    return r.json()["access_token"]


def make_http_client():
    # The server may still be starting right after a fresh boot.
    client = httpx.Client(base_url=BASE_URL, timeout=30.0)
    for attempt in range(60):
        try:
            if client.get("/api/limits").status_code == 200:
                return client
        except httpx.TransportError:
            pass
        time.sleep(0.25)
    raise SystemExit(f"server not reachable at {BASE_URL}")


def system_setup(client):
    """Create guild, admin user, grant superuser, return summary dict."""
    guild = client.post("/api/system/guilds", json={"name": "BenchGuild"},
                        headers=SYSTEM_HEADERS)
    guild.raise_for_status()
    guild_id = int(guild.json()["id"])

    admin = client.post("/api/system/users",
                        json={"username": "bench_admin", "password": ADMIN_PASSWORD},
                        headers=SYSTEM_HEADERS)
    admin.raise_for_status()
    admin_id = int(admin.json()["id"])

    su = client.post("/api/system/superuser",
                     json={"guild_id": str(guild_id), "user_id": str(admin_id)},
                     headers=SYSTEM_HEADERS)
    su.raise_for_status()

    token = api_login(client, "bench_admin", ADMIN_PASSWORD)
    return guild_id, admin_id, token


def truncate(conn):
    with conn.cursor() as cur:
        cur.execute(
            "TRUNCATE app.users, app.guilds, app.roles, app.channels, app.messages,"
            " app.files, app.emojis RESTART IDENTITY CASCADE;"
        )


def seed_users(conn, start_index, count):
    """Bulk users with NULL password_hash (not login-able, fine for listing)."""
    with conn.cursor() as cur:
        with cur.copy(
            "COPY app.users (id, username, display_name, created_at) FROM STDIN"
        ) as copy:
            base_day = DATE_START
            for i in range(count):
                uid = USER_BASE + start_index + i
                created = base_day + timedelta(minutes=i % 5000)
                copy.write_row((uid, f"bench_user_{start_index + i:06d}",
                                f"Bench User {start_index + i}", created))


def seed_channels(conn, guild_id, count):
    ids = []
    with conn.cursor() as cur:
        cat_id = CHANNEL_BASE - 1
        cur.execute(
            "INSERT INTO app.channels (id, guild_id, parent_id, kind, name, position)"
            " VALUES (%s, %s, NULL, 1, %s, 0)",
            (cat_id, guild_id, "Bench Category"),
        )
        ids.append(cat_id)
        with cur.copy(
            "COPY app.channels (id, guild_id, parent_id, kind, name, position)"
            " FROM STDIN"
        ) as copy:
            for i in range(count):
                cid = CHANNEL_BASE + i
                copy.write_row((cid, guild_id, cat_id, 0, f"bench-{i:03d}", i))
                ids.append(cid)
    return ids


def seed_messages(conn, guild_id, channel_ids, author_ids):
    rng = random.Random(1234)
    senders = author_ids
    n_msgs = 0
    n_reactions = 0
    n_attachments = 0

    with conn.cursor() as cur:
        with cur.copy(
            "COPY app.messages (id, channel_id, guild_id, author_id, content,"
            " created_at, mention_everyone) FROM STDIN"
        ) as copy:
            mid = MESSAGE_BASE
            for c_idx, channel_id in enumerate(channel_ids):
                for m in range(MESSAGES_PER_CHANNEL):
                    created = DATE_START + timedelta(
                        seconds=(c_idx * MESSAGES_PER_CHANNEL + m) * 37
                    )
                    content = " ".join(
                        rng.choice(WORDS) for _ in range(rng.randint(3, 25))
                    )
                    if mid % 97 == 0:
                        content += " benchsearchtoken"
                    copy.write_row((mid, channel_id, guild_id, rng.choice(senders),
                                    content, created, False))
                    mid += 1
                    n_msgs += 1

        # Reactions: a deterministic slice of messages, 1-4 each.
        with cur.copy(
            "COPY app.message_reactions (message_id, user_id, emoji_kind,"
            " unicode_emoji, created_at) FROM STDIN"
        ) as copy:
            for k in range(0, n_msgs, REACTION_EVERY):
                msg_id = MESSAGE_BASE + k
                n = rng.randint(1, 4)
                # Distinct users per message keeps (message, user, emoji) unique.
                for user_id in rng.sample(senders, n):
                    copy.write_row((msg_id, user_id, 0,
                                    rng.choice(UNICODE_EMOJIS), DATE_START))
                    n_reactions += 1

        # A small file pool plus attachments on a slice of messages.
        files = []
        with cur.copy(
            "COPY app.files (id, name, hash, size, content_type) FROM STDIN"
        ) as copy:
            for i in range(FILE_POOL):
                fid = 400_000_000 + i
                copy.write_row((fid, f"bench-{i}.bin", f"{i:064x}", 1024,
                                "application/octet-stream"))
                files.append(fid)

        with cur.copy(
            "COPY app.message_attachments (message_id, file_id, position)"
            " FROM STDIN"
        ) as copy:
            for k in range(0, n_msgs, ATTACHMENT_EVERY):
                copy.write_row((MESSAGE_BASE + k, files[(k // ATTACHMENT_EVERY) % FILE_POOL], 0))
                n_attachments += 1

    with conn.cursor() as cur:
        cur.execute("ANALYZE;")

    return n_msgs, n_reactions, n_attachments


def main():
    log(f"config={CONFIG_PATH} db={DB_URL} base={BASE_URL}")
    client = make_http_client()
    try:
        with psycopg.connect(DB_URL, autocommit=True) as conn:
            log("truncating app.* ...")
            truncate(conn)

        log("creating guild/admin via system API ...")
        guild_id, admin_id, admin_token = system_setup(client)
        log(f"guild_id={guild_id} admin_id={admin_id}")

        with psycopg.connect(DB_URL, autocommit=True) as conn:
            log(f"seeding {TARGET_USERS - 1} bulk users ...")
            seed_users(conn, start_index=1, count=TARGET_USERS - 1)

            log(f"seeding 1 category + {TEXT_CHANNELS} text channels ...")
            channel_ids = seed_channels(conn, guild_id, TEXT_CHANNELS)

            log(f"seeding messages ({TEXT_CHANNELS} x {MESSAGES_PER_CHANNEL}) ...")
            author_ids = [admin_id] + [USER_BASE + i for i in range(1, min(TARGET_USERS, 500))]
            n_msgs, n_reactions, n_attachments = seed_messages(
                conn, guild_id, channel_ids[1:], author_ids
            )

            # Refresh the admin token (the copy/seed may have taken a while).
            admin_token = api_login(client, "bench_admin", ADMIN_PASSWORD)

            summary = {
                "base_url": BASE_URL,
                "guild_id": str(guild_id),
                "admin_id": str(admin_id),
                "admin_token": admin_token,
                "category_id": str(channel_ids[0]),
                "channel_ids": [str(c) for c in channel_ids[1:]],
                "users": TARGET_USERS,
                "channels": len(channel_ids),
                "messages": n_msgs,
                "reactions": n_reactions,
                "attachments": n_attachments,
            }
            (ROOT / "bench" / "seed.json").write_text(json.dumps(summary, indent=2))
            print(json.dumps({k: v for k, v in summary.items() if k != "admin_token" and k != "channel_ids"}, indent=2))
            log("done")
    finally:
        client.close()


if __name__ == "__main__":
    main()
