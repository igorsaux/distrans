#!/usr/bin/env python3
"""Wipe all Distrans data from the configured database.

Drops the `app` and `_migration` schemas (all tables, triggers, functions and
the migration history), so the server recreates everything from ``migrations/``
on the next start. This is destructive: use it only for a development or
disposable database, with the server stopped.

Usage:
    cleandb.py [-c config.json] [--yes]

The database name printed by the script must be typed back to confirm the wipe
unless ``--yes`` is passed (required when stdin is not a TTY). The server's
connection settings come from ``db.conninfo`` in the config.
"""
import argparse

import psycopg
from psycopg import sql

from _common import (
    EXIT_OK,
    add_config_arg,
    configure_interactivity,
    fail,
    is_interactive,
    load_config,
)

SCHEMAS = ("app", "_migration")
LOCK_TIMEOUT = "5s"


def parse_args():
    parser = argparse.ArgumentParser(
        prog="cleandb",
        description="Drop the app and _migration schemas of the configured database.",
    )
    add_config_arg(parser)
    parser.add_argument(
        "--yes",
        action="store_true",
        help="skip the confirmation prompt",
    )
    return parser.parse_args()


def confirm(database_name):
    if not is_interactive():
        fail("refusing to wipe the database without confirmation (pass --yes)")

    answer = input(f'Type the database name "{database_name}" to wipe it: ').strip()

    if answer != database_name:
        fail("database name does not match, nothing was dropped")


def drop_schemas(conn):
    with conn.cursor() as cur:
        cur.execute(sql.SQL("SET lock_timeout = {}").format(sql.Literal(LOCK_TIMEOUT)))

        for schema in SCHEMAS:
            cur.execute(
                sql.SQL("DROP SCHEMA IF EXISTS {} CASCADE").format(
                    sql.Identifier(schema)
                )
            )
            print(f"dropped schema {schema}")


def main():
    args = parse_args()
    configure_interactivity(args.non_interactive)

    config = load_config(args.config)
    conninfo = (config.get("db") or {}).get("conninfo")

    if not conninfo:
        fail("'db.conninfo' is missing in the config")

    try:
        with psycopg.connect(conninfo) as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT current_database()")
                database_name = cur.fetchone()[0]

            if not args.yes:
                confirm(database_name)

            try:
                drop_schemas(conn)
            except psycopg.Error as e:
                fail(
                    f"failed to wipe database {database_name}: {e} "
                    "(is the server still running?)"
                )
    except psycopg.OperationalError as e:
        fail(f"failed to connect to the database: {e}")

    print("database cleaned: migrations will be re-applied on the next server start")

    return EXIT_OK


if __name__ == "__main__":
    raise SystemExit(main())
