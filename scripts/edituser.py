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
    resolve_secret,
    system_request,
)


def parse_args():
    parser = argparse.ArgumentParser(
        prog="edituser",
        description="Edit a user via the system API "
        "(reads the server config for the token and socket settings).",
    )
    add_config_arg(parser)
    parser.add_argument(
        "--id", required=True, help="id of the user to edit (decimal)"
    )
    parser.add_argument("--username", default=None, help="new username")

    display_name = parser.add_mutually_exclusive_group()
    display_name.add_argument(
        "--display-name", default=None, help="set the display name"
    )
    display_name.add_argument(
        "--clear-display-name",
        action="store_true",
        help="clear the display name",
    )

    password = parser.add_mutually_exclusive_group()
    password.add_argument(
        "--password",
        default=None,
        help="set (or change) the password; forbidden for bots "
        "(passing it via the flag may leak it into the shell history)",
    )
    password.add_argument(
        "--clear-password",
        action="store_true",
        help="clear the password (makes the account passwordless)",
    )

    return parser.parse_args()


def main():
    args = parse_args()
    configure_interactivity(args.non_interactive)

    config = load_config(args.config)
    system_token = get_system_token(config)
    max_password_len = get_max_password_len(config)

    user_id = parse_decimal_id(args.id, "--id")

    payload = {}
    changed = []

    if args.username is not None:
        username = args.username.strip()

        if not username:
            fail("--username must not be empty")

        payload["username"] = username
        changed.append("username")

    if args.display_name is not None:
        payload["display_name"] = args.display_name
        changed.append("display_name")

    if args.clear_display_name:
        payload["display_name"] = None
        changed.append("display_name")

    if args.password is not None:
        password = resolve_secret(args.password, "Password", max_len=max_password_len)

        payload["password"] = password
        changed.append("password")

    if args.clear_password:
        payload["password"] = None
        changed.append("password")

    if not changed:
        fail(
            "no changes requested: pass at least one of "
            "--username, --display-name/--clear-display-name, "
            "--password/--clear-password"
        )

    connection = make_connection(config)
    status, parsed = system_request(
        connection, "PATCH", f"/api/system/users/{user_id}", system_token, payload
    )
    connection.close()

    expect_status(status, parsed, 204, f"/api/system/users/{user_id}")

    print(f"User {user_id} updated successfully ({', '.join(changed)})")

    return EXIT_OK


if __name__ == "__main__":
    raise SystemExit(main())
