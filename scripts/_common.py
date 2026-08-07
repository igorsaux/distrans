import getpass
import http.client
import json
import socket
import sys

DEFAULT_CONFIG_PATH = "config.json"
REQUEST_TIMEOUT_S = 10.0

EXIT_OK = 0
EXIT_ERROR = 1
EXIT_API_ERROR = 2

_NON_INTERACTIVE = False


def fail(message, code=EXIT_ERROR):
    print(f"error: {message}", file=sys.stderr)
    sys.exit(code)


def configure_interactivity(non_interactive):
    """Apply the `--non-interactive` flag for the current process."""
    global _NON_INTERACTIVE
    _NON_INTERACTIVE = bool(non_interactive)


def is_interactive():
    """True only when prompts are both allowed and possible (a TTY)."""
    if _NON_INTERACTIVE:
        return False

    try:
        return sys.stdin.isatty()
    except ValueError:
        return False


def add_config_arg(parser):
    parser.add_argument(
        "-c",
        "--config",
        default=DEFAULT_CONFIG_PATH,
        metavar="PATH",
        help=f"path to the server config JSON file (default: {DEFAULT_CONFIG_PATH})",
    )
    parser.add_argument(
        "--non-interactive",
        action="store_true",
        help="never prompt; missing values are an error (useful for CI/cron)",
    )


def load_config(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            config = json.load(f)
    except FileNotFoundError:
        fail(f"config file not found: {path}")
    except json.JSONDecodeError as e:
        fail(f"config file is not valid JSON: {path}: {e}")
    except OSError as e:
        fail(f"failed to read config file {path}: {e}")

    if not isinstance(config, dict):
        fail(f"config root must be a JSON object: {path}")

    return config


def parse_decimal_id(value, flag):
    value = value.strip() if value else ""

    if not value or not value.isdigit():
        fail(f"{flag} must be a decimal number")

    return value


def get_system_token(config):
    system = config.get("system")
    token = system.get("token") if isinstance(system, dict) else None

    if not isinstance(token, str) or not token:
        fail("'system.token' is missing or empty in the config")

    return token


def get_max_password_len(config):
    auth = config.get("auth")
    password = auth.get("password") if isinstance(auth, dict) else None
    value = password.get("max_password_len") if isinstance(password, dict) else None

    if isinstance(value, int) and value > 0:
        return value

    return None


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, path, timeout=REQUEST_TIMEOUT_S):
        super().__init__("localhost", timeout=timeout)
        self.unix_socket_path = path

    def connect(self):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        sock.connect(self.unix_socket_path)
        self.sock = sock


def make_connection(config):
    sock_cfg = config.get("socket")
    bind = sock_cfg.get("bind") if isinstance(sock_cfg, dict) else None

    if not isinstance(bind, dict):
        fail("'socket.bind' is missing in the config")

    bind_type = bind.get("type")

    if bind_type == "inet":
        host = bind.get("host")
        port = bind.get("port")

        if not isinstance(host, str) or not host:
            fail("'socket.bind.host' is missing or empty in the config")

        if not isinstance(port, str) and not isinstance(port, int):
            fail("'socket.bind.port' is missing in the config")

        try:
            port_num = int(port)
        except (TypeError, ValueError):
            fail(f"'socket.bind.port' is not a number: {port!r}")

        return http.client.HTTPConnection(host, port_num, timeout=REQUEST_TIMEOUT_S)

    if bind_type == "unix":
        path = bind.get("path")

        if not isinstance(path, str) or not path:
            fail("'socket.bind.path' is missing or empty in the config")

        return UnixHTTPConnection(path)

    fail(f"unsupported 'socket.bind.type' in the config: {bind_type!r}")


def system_request(connection, method, path, system_token, payload=None):
    if payload is None:
        headers = {"Authorization": f"Bearer {system_token}"}
        body = None
    else:
        body = json.dumps(payload).encode("utf-8")
        headers = {
            "Authorization": f"Bearer {system_token}",
            "Content-Type": "application/json",
            "Content-Length": str(len(body)),
        }

    try:
        connection.request(method, path, body=body, headers=headers)
        response = connection.getresponse()
        status = response.status
        data = response.read()
    except (OSError, http.client.HTTPException) as e:
        fail(f"request to {path} failed: {e}")

    try:
        parsed = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        parsed = None

    return status, parsed


def api_error_message(status, parsed):
    if isinstance(parsed, dict):
        message = parsed.get("message")

        if isinstance(message, str) and message:
            return f"HTTP {status}: {message}"

    return f"HTTP {status}: unexpected response"


def expect_status(status, parsed, expected, path):
    """Fail with EXIT_API_ERROR unless `status` is in `expected`."""
    if isinstance(expected, int):
        expected = {expected}

    if status not in expected:
        fail(f"{path}: {api_error_message(status, parsed)}", code=EXIT_API_ERROR)


def _read_line(label, on_eof="fail"):
    try:
        return input(label)
    except EOFError:
        print()

        if on_eof == "empty":
            return ""

        fail(f"no input provided for '{label.rstrip(': ')}' (stdin is closed)")


def prompt(label, default=None):
    suffix = f" [{default}]" if default is not None else ""
    value = _read_line(f"{label}{suffix}: ", on_eof="empty").strip()

    if not value and default is not None:
        return default

    return value


def prompt_required(label):
    while True:
        value = _read_line(f"{label}: ", on_eof="fail").strip()

        if value:
            return value

        print("This value is required, please try again.")


def prompt_secret(label, max_len=None, allow_empty=False):
    while True:
        try:
            first = getpass.getpass(f"{label}: ")
        except EOFError:
            print()
            fail(f"no input provided for '{label}' (stdin is closed)")

        if not first:
            if allow_empty:
                return ""

            print("The password must not be empty, please try again.")
            continue

        if max_len is not None and len(first.encode("utf-8")) > max_len:
            print(f"The password is too long (max {max_len} bytes), please try again.")
            continue

        try:
            second = getpass.getpass(f"Repeat {label.lower()}: ")
        except EOFError:
            print()
            fail(f"no input provided for '{label}' (stdin is closed)")

        if first == second:
            return first

        print("Passwords do not match, please try again.")


def resolve_text(flag_value, label, default=None, required=True):
    """Resolve a text value from a flag, prompting only in a TTY.

    Never blocks when stdin is not a TTY: a missing required value is an
    error, a missing optional value is `default`.
    """
    if flag_value is not None:
        value = flag_value.strip()

        if not value:
            if required:
                fail(f"{label} must not be empty")

            return default

        return value

    if not is_interactive():
        if default is not None:
            return default

        if required:
            fail(f"missing required value: {label} (pass the matching flag or run interactively)")

        return None

    if required:
        return prompt_required(label)

    return prompt(label, default)


def resolve_secret(flag_value, label, max_len=None, allow_empty=False):
    """Resolve a password from a flag, prompting only in a TTY.

    `--password ""` (or an empty interactive answer) means "no password"
    when `allow_empty` is set; the returned value is then `None`.
    """
    if flag_value is not None:
        if not flag_value:
            if allow_empty:
                return None

            fail(f"{label} must not be empty")

        if max_len is not None and len(flag_value.encode("utf-8")) > max_len:
            fail(f"{label} is too long (max {max_len} bytes)")

        return flag_value

    if not is_interactive():
        if allow_empty:
            return None

        fail(f"missing required value: {label} (pass the matching flag or run interactively)")

    value = prompt_secret(label, max_len=max_len, allow_empty=allow_empty)

    return value or None


def report_created(kind, entity_id, extra_fields):
    print(f"{kind} created successfully (id: {entity_id})")

    for key, value in extra_fields:
        print(f"{key}: {value}")


def report_deleted(kind, entity_id):
    print(f"{kind} {entity_id} deleted successfully")
