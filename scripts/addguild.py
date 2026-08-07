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
    resolve_text,
    system_request,
)


def parse_args():
    parser = argparse.ArgumentParser(
        prog="addguild",
        description="Create a guild via the system API "
        "(reads the server config for the token and socket settings).",
    )
    add_config_arg(parser)
    parser.add_argument(
        "-n", "--name", help="guild name (asked interactively if omitted)"
    )
    parser.add_argument(
        "--id", default=None, help="optional guild id (decimal, generated if omitted)"
    )
    return parser.parse_args()


def main():
    args = parse_args()
    configure_interactivity(args.non_interactive)

    config = load_config(args.config)
    system_token = get_system_token(config)

    name = resolve_text(args.name, "Guild name")

    payload = {"name": name}

    if args.id is not None:
        payload["id"] = parse_decimal_id(args.id, "--id")

    connection = make_connection(config)
    status, parsed = system_request(
        connection, "POST", "/api/system/guilds", system_token, payload
    )
    connection.close()

    expect_status(status, parsed, 201, "/api/system/guilds")

    if not isinstance(parsed, dict) or "id" not in parsed:
        fail(
            f"unexpected response from /api/system/guilds: {parsed!r}",
            code=EXIT_API_ERROR,
        )

    report_created("Guild", parsed["id"], [("name", name)])

    return EXIT_OK


if __name__ == "__main__":
    raise SystemExit(main())
