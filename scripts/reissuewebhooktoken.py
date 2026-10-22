#!/usr/bin/env python3
"""Reissue (rotate) a webhook execute token.

The plaintext execute token is only known when it is issued: the database keeps
just its sha256 in ``app.webhooks.token_hash``. This script generates a new
token, replaces the stored hash and prints the plaintext token once.

Because no system API endpoint exposes the token, the update is written
directly to the configured database (``db.conninfo``); the server does not need
to be stopped, since it reads the hash on every execute request. The old token
stops working immediately.

Usage:
    reissuewebhooktoken.py -c config.json --id <webhook_id>
"""
import argparse
import hashlib
import secrets

import psycopg

from _common import (
    EXIT_OK,
    add_config_arg,
    configure_interactivity,
    fail,
    load_config,
    parse_decimal_id,
)

WEBHOOK_TOKEN_BYTES = 32


def parse_args():
    parser = argparse.ArgumentParser(
        prog="reissuewebhooktoken",
        description="Reissue a webhook execute token by replacing its stored "
        "sha256 in the database (reads db.conninfo from the server config).",
    )
    add_config_arg(parser)
    parser.add_argument(
        "--id",
        required=True,
        help="id of a live (not soft-deleted) webhook (decimal)",
    )
    return parser.parse_args()


def get_conninfo(config):
    db = config.get("db")
    conninfo = db.get("conninfo") if isinstance(db, dict) else None

    if not isinstance(conninfo, str) or not conninfo:
        fail("'db.conninfo' is missing in the config")

    return conninfo


def reissue_token(cursor, webhook_id):
    """Replace the webhook's token hash; return ``(token, channel_id, name)``.

    Returns ``None`` when no live webhook has that id.
    """
    token = secrets.token_urlsafe(WEBHOOK_TOKEN_BYTES)
    token_hash = hashlib.sha256(token.encode("utf-8")).digest()

    cursor.execute(
        "UPDATE app.webhooks"
        " SET token_hash = %s"
        " WHERE id = %s"
        "   AND deleted_at IS NULL"
        " RETURNING channel_id, name",
        (token_hash, int(webhook_id)),
    )

    row = cursor.fetchone()

    if row is None:
        return None

    return token, row[0], row[1]


def main():
    args = parse_args()
    configure_interactivity(args.non_interactive)

    config = load_config(args.config)
    conninfo = get_conninfo(config)

    webhook_id = parse_decimal_id(args.id, "--id")

    try:
        with psycopg.connect(conninfo) as connection:
            with connection.cursor() as cursor:
                result = reissue_token(cursor, webhook_id)
    except psycopg.Error as e:
        fail(f"failed to reissue the webhook token: {e}")

    if result is None:
        fail(f"webhook not found or soft-deleted: {webhook_id}")

    token, channel_id, name = result

    print(f"Webhook token reissued successfully (id: {webhook_id})")
    print(f"channel_id: {channel_id}")
    print(f"name: {name}")
    print("token:")
    print(token)

    return EXIT_OK


if __name__ == "__main__":
    raise SystemExit(main())
