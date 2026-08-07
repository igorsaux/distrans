#!/usr/bin/env python3
import argparse

from _common import (
    EXIT_API_ERROR,
    EXIT_OK,
    add_config_arg,
    configure_interactivity,
    expect_status,
    fail,
    get_max_password_len,
    get_system_token,
    load_config,
    make_connection,
    parse_decimal_id,
    report_created,
    resolve_secret,
    resolve_text,
    system_request,
)


def parse_args():
    parser = argparse.ArgumentParser(
        prog="adduser",
        description="Create a user via the system API "
        "(reads the server config for the token and socket settings).",
    )
    add_config_arg(parser)
    parser.add_argument(
        "-u", "--username", help="username (asked interactively if omitted)"
    )
    parser.add_argument(
        "--password",
        help="password (asked interactively if omitted; "
        "passing it via the flag may leak it into the shell history); "
        "omit it (or answer empty) to create a user without a password",
    )
    parser.add_argument(
        "--is-bot",
        action="store_true",
        help="create a bot user (bots must not have a password)",
    )
    parser.add_argument(
        "--id", default=None, help="optional user id (decimal, generated if omitted)"
    )
    parser.add_argument("--display-name", default=None, help="optional display name")
    return parser.parse_args()


def main():
    args = parse_args()
    configure_interactivity(args.non_interactive)

    config = load_config(args.config)
    system_token = get_system_token(config)
    max_password_len = get_max_password_len(config)

    username = resolve_text(args.username, "Username")

    if args.is_bot:
        password = None
    else:
        password = resolve_secret(
            args.password,
            "Password (empty for no password)",
            max_len=max_password_len,
            allow_empty=True,
        )

    display_name = resolve_text(
        args.display_name, "Display name (optional)", required=False
    )

    payload = {"username": username}

    if args.id is not None:
        payload["id"] = parse_decimal_id(args.id, "--id")

    if password:
        payload["password"] = password

    if args.is_bot:
        payload["is_bot"] = True

    if display_name:
        payload["display_name"] = display_name

    connection = make_connection(config)
    status, parsed = system_request(
        connection, "POST", "/api/system/users", system_token, payload
    )
    connection.close()

    expect_status(status, parsed, 201, "/api/system/users")

    if not isinstance(parsed, dict) or "id" not in parsed:
        fail(
            f"unexpected response from /api/system/users: {parsed!r}",
            code=EXIT_API_ERROR,
        )

    report_created("User", parsed["id"], [("username", username)])

    return EXIT_OK


if __name__ == "__main__":
    raise SystemExit(main())
