#!/usr/bin/env python3
import argparse

from _common import (
    EXIT_API_ERROR,
    EXIT_OK,
    add_config_arg,
    configure_interactivity,
    expect_status,
    fail,
    get_system_token,
    load_config,
    make_connection,
    parse_decimal_id,
    report_created,
    system_request,
)


def parse_args():
    parser = argparse.ArgumentParser(
        prog="addsuperuser",
        description="Create a superuser role (grant a user full permissions in a "
        "guild) via the system API "
        "(reads the server config for the token and socket settings).",
    )
    add_config_arg(parser)
    parser.add_argument(
        "--guild-id",
        required=True,
        help="guild id (decimal)",
    )
    parser.add_argument(
        "--user-id",
        required=True,
        help="user id (decimal)",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    configure_interactivity(args.non_interactive)

    config = load_config(args.config)
    system_token = get_system_token(config)

    guild_id = parse_decimal_id(args.guild_id, "--guild-id")
    user_id = parse_decimal_id(args.user_id, "--user-id")

    connection = make_connection(config)
    status, parsed = system_request(
        connection,
        "POST",
        "/api/system/superuser",
        system_token,
        {"guild_id": guild_id, "user_id": user_id},
    )
    connection.close()

    expect_status(status, parsed, 201, "/api/system/superuser")

    if not isinstance(parsed, dict) or "id" not in parsed:
        fail(
            f"unexpected response from /api/system/superuser: {parsed!r}",
            code=EXIT_API_ERROR,
        )

    report_created(
        "Superuser role",
        parsed["id"],
        [("guild_id", guild_id), ("user_id", user_id)],
    )

    return EXIT_OK


if __name__ == "__main__":
    raise SystemExit(main())
