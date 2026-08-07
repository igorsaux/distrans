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
    system_request,
)


def parse_args():
    parser = argparse.ArgumentParser(
        prog="addbottoken",
        description="Issue (or rotate) a static bot token via the system API "
        "(reads the server config for the token and socket settings).",
    )
    add_config_arg(parser)
    parser.add_argument(
        "--user-id",
        required=True,
        help="id of an existing bot user (decimal)",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    configure_interactivity(args.non_interactive)

    config = load_config(args.config)
    system_token = get_system_token(config)

    user_id = parse_decimal_id(args.user_id, "--user-id")

    connection = make_connection(config)
    status, parsed = system_request(
        connection, "PUT", f"/api/system/users/{user_id}", system_token
    )
    connection.close()

    expect_status(status, parsed, 200, f"/api/system/users/{user_id}")

    if not isinstance(parsed, dict) or "token" not in parsed:
        fail(
            f"unexpected response from /api/system/users/{user_id}: {parsed!r}",
            code=EXIT_API_ERROR,
        )

    print(f"Bot token for {user_id}:")
    print(parsed["token"])

    return EXIT_OK


if __name__ == "__main__":
    raise SystemExit(main())
