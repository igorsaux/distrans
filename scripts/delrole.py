#!/usr/bin/env python3
import argparse

from _common import (
    EXIT_OK,
    add_config_arg,
    configure_interactivity,
    expect_status,
    get_system_token,
    load_config,
    make_connection,
    parse_decimal_id,
    report_deleted,
    system_request,
)


def parse_args():
    parser = argparse.ArgumentParser(
        prog="delrole",
        description="Delete a guild role via the system API "
        "(reads the server config for the token and socket settings).",
    )
    add_config_arg(parser)
    parser.add_argument(
        "--guild-id",
        required=True,
        help="guild id (decimal)",
    )
    parser.add_argument(
        "--role-id",
        required=True,
        help="role id (decimal); the @everyone role cannot be deleted",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    configure_interactivity(args.non_interactive)

    config = load_config(args.config)
    system_token = get_system_token(config)

    guild_id = parse_decimal_id(args.guild_id, "--guild-id")
    role_id = parse_decimal_id(args.role_id, "--role-id")

    connection = make_connection(config)
    status, parsed = system_request(
        connection,
        "DELETE",
        f"/api/system/guilds/{guild_id}/roles/{role_id}",
        system_token,
    )
    connection.close()

    expect_status(
        status, parsed, 204, f"/api/system/guilds/{guild_id}/roles/{role_id}"
    )

    report_deleted("Role", role_id)

    return EXIT_OK


if __name__ == "__main__":
    raise SystemExit(main())
