#!/usr/bin/env python3
import argparse

import psycopg

from _common import (
    EXIT_OK,
    add_config_arg,
    configure_interactivity,
    expect_status,
    fail,
    get_system_token,
    is_interactive,
    load_config,
    make_connection,
    parse_decimal_id,
    report_deleted,
    system_request,
)


def parse_args():
    parser = argparse.ArgumentParser(
        prog="delguild",
        description="Delete a guild via the system API "
        "(reads the server config for the token, conninfo and socket settings).",
    )
    add_config_arg(parser)
    parser.add_argument(
        "--id",
        required=True,
        help="guild id (decimal)",
    )
    parser.add_argument(
        "--confirm",
        default=None,
        metavar="NAME",
        help="guild name, required as confirmation when stdin is not a TTY "
        "(asked interactively otherwise)",
    )
    return parser.parse_args()


def get_conninfo(config):
    db = config.get("db")
    conninfo = db.get("conninfo") if isinstance(db, dict) else None

    if not isinstance(conninfo, str) or not conninfo:
        fail("'db.conninfo' is missing in the config")

    return conninfo


def fetch_guild_name(conninfo, guild_id):
    try:
        with psycopg.connect(conninfo) as connection:
            with connection.cursor() as cursor:
                cursor.execute(
                    "SELECT name FROM app.guilds WHERE id = %s",
                    (int(guild_id),),
                )
                row = cursor.fetchone()
    except psycopg.Error as e:
        fail(f"database lookup failed: {e}")

    if row is None:
        fail(f"guild not found: {guild_id}")

    return row[0]


def confirm_deletion(name, confirm_flag):
    if confirm_flag is not None:
        if confirm_flag.strip() != name:
            fail(f'confirmation does not match: expected "{name}"')

        return

    if not is_interactive():
        fail("confirmation required: pass --confirm NAME (stdin is not a TTY)")

    try:
        answer = input("Type the guild name to confirm deletion: ")
    except EOFError:
        print()
        fail(f'confirmation does not match: expected "{name}"')

    if answer.strip() != name:
        fail(f'confirmation does not match: expected "{name}"')


def main():
    args = parse_args()
    configure_interactivity(args.non_interactive)

    config = load_config(args.config)
    system_token = get_system_token(config)
    conninfo = get_conninfo(config)

    guild_id = parse_decimal_id(args.id, "--id")
    name = fetch_guild_name(conninfo, guild_id)

    print(f'Guild: "{name}" (id: {guild_id})')

    confirm_deletion(name, args.confirm)

    connection = make_connection(config)
    status, parsed = system_request(
        connection,
        "DELETE",
        f"/api/system/guilds/{guild_id}",
        system_token,
    )
    connection.close()

    expect_status(status, parsed, 204, f"/api/system/guilds/{guild_id}")

    report_deleted("Guild", guild_id)

    return EXIT_OK


if __name__ == "__main__":
    raise SystemExit(main())
