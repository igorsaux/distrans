#!/usr/bin/env python3
"""Closed-loop HTTP load harness for distrans.

Each worker issues requests back-to-back for the duration, so the number of
workers equals the request concurrency. Latency is measured per request with a
monotonic clock; throughput is derived from completed requests. The server
process (by --pid) is sampled for CPU time and RSS during the measured window.

Examples:
    .venv/bin/python bench/load.py --pid <server_pid> \
        --scenarios limits,guilds,channels,messages50 \
        --concurrency 1,8,32,64,128 --duration 5 --tag baseline

    .venv/bin/python bench/load.py --pid <pid> --scenarios post_message --concurrency 32
"""

import argparse
import asyncio
import json
import os
import subprocess
import time
from pathlib import Path

import aiohttp

ROOT = Path(__file__).resolve().parent.parent
CONFIG_PATH = Path(os.environ.get("BENCH_CONFIG", ROOT / "config.bench.json"))
SEED_PATH = ROOT / "bench" / "seed.json"

with CONFIG_PATH.open() as f:
    CONFIG = json.load(f)

bind = CONFIG["socket"]["bind"]
host = bind["host"]
if ":" in host:
    host = f"[{host}]"
BASE_URL = f"http://{host}:{bind['port']}"
SYSTEM_HEADERS = {"Authorization": f"Bearer {CONFIG['system']['token']}"}

ADMIN_USERNAME = "bench_admin"
ADMIN_PASSWORD = os.environ.get("BENCH_ADMIN_PASSWORD", "benchpass123")

OK_STATUS = {200, 201, 204}


def load_ctx():
    with SEED_PATH.open() as f:
        seed = json.load(f)
    channels = seed["channel_ids"]
    return {
        "guild_id": seed["guild_id"],
        "read_channel": channels[0],
        "write_channel": channels[1],
        "react_channel": channels[2],
        "message_id": None,  # filled in prepare()
        "token": seed["admin_token"],
    }


async def login(session):
    async with session.post(
        "/api/auth/token",
        json={"grant_type": "password", "username": ADMIN_USERNAME, "password": ADMIN_PASSWORD},
    ) as r:
        r.raise_for_status()
        return (await r.json())["access_token"]


async def prepare(ctx):
    """Resolve one message id for get/react scenarios."""
    async with aiohttp.ClientSession(base_url=BASE_URL) as session:
        ctx["token"] = await login(session)
        headers = {"Authorization": f"Bearer {ctx['token']}"}
        async with session.get(
            f"/api/channels/{ctx['read_channel']}/messages",
            params={"limit": "1"}, headers=headers,
        ) as r:
            r.raise_for_status()
            body = await r.json()
            msgs = body["messages"] if isinstance(body, dict) else body
            ctx["message_id"] = msgs[0]["id"]


# --- scenarios: each returns (method, path, kwargs) -------------------------
# kwargs are passed straight to aiohttp's request(); json bodies use "json".

def sc_limits(ctx):
    return "GET", "/api/limits", {}


def sc_guilds(ctx):
    return "GET", "/api/guilds", {}


def sc_channels(ctx):
    return "GET", f"/api/guilds/{ctx['guild_id']}/channels", {}


def sc_messages50(ctx):
    return "GET", f"/api/channels/{ctx['read_channel']}/messages", {"params": {"limit": "50"}}


def sc_messages1(ctx):
    return "GET", f"/api/channels/{ctx['read_channel']}/messages", {"params": {"limit": "1"}}


def sc_message_get(ctx):
    return "GET", f"/api/messages/{ctx['message_id']}", {}


def sc_users(ctx):
    return "GET", "/api/users", {"params": {"limit": "100"}}


def sc_me(ctx):
    return "GET", "/api/users/@me", {}


def sc_search(ctx):
    return (
        "GET",
        f"/api/guilds/{ctx['guild_id']}/messages/search",
        {"params": {"content": "benchsearchtoken", "limit": "50"}},
    )


def sc_roles(ctx):
    return "GET", f"/api/guilds/{ctx['guild_id']}/roles", {}


def sc_audit(ctx):
    return "GET", f"/api/guilds/{ctx['guild_id']}/audit-log", {}


def _make_writer(counter):
    def fn(ctx):
        counter[0] += 1
        content = f"bench load message {counter[0]} {os.getpid()}"
        return "POST", f"/api/channels/{ctx['write_channel']}/messages", {"json": {"content": content}}
    return fn


def sc_patch_me(ctx):
    return (
        "PATCH",
        "/api/users/@me",
        {"json": {"display_name": "Bench Admin", "current_password": ADMIN_PASSWORD}},
    )


def sc_auth_token(ctx):
    return (
        "POST",
        "/api/auth/token",
        {"json": {"grant_type": "password", "username": ADMIN_USERNAME,
                  "password": ADMIN_PASSWORD}},
    )


SIMPLE_SCENARIOS = {
    "limits": sc_limits, "guilds": sc_guilds, "channels": sc_channels,
    "messages50": sc_messages50, "messages1": sc_messages1,
    "message_get": sc_message_get, "users": sc_users, "me": sc_me,
    "search": sc_search, "roles": sc_roles, "audit": sc_audit,
    "patch_me": sc_patch_me, "auth_token": sc_auth_token,
}

AUTH_EXEMPT = {"limits", "auth_token"}


def build_scenarios(names):
    scenarios = {}
    for name in names:
        if name == "post_message":
            scenarios[name] = _make_writer([0])
            scenarios[name].requires_auth = True
        elif name in SIMPLE_SCENARIOS:
            fn = SIMPLE_SCENARIOS[name]
            fn.requires_auth = name not in AUTH_EXEMPT
            scenarios[name] = fn
        else:
            raise SystemExit(f"unknown scenario: {name}")
    return scenarios


# --- server process sampling -------------------------------------------------

def parse_ps_time(s):
    s = s.strip()
    if not s:
        return 0.0
    days = 0
    if "-" in s:
        d, s = s.split("-", 1)
        days = int(d)
    parts = s.split(":")
    parts = [float(p) for p in parts]
    while len(parts) < 3:
        parts.insert(0, 0.0)
    return days * 86400 + parts[0] * 3600 + parts[1] * 60 + parts[2]


def detect_server_pid():
    """The server may run under a shell wrapper; prefer the exact process name."""
    for pattern in (["pgrep", "-x", "distrans"], ["pgrep", "-f", "zig-out/bin/distrans"]):
        out = subprocess.run(pattern, capture_output=True, text=True).stdout.split()
        if out:
            return int(out[0])
    return None


def read_cpu_seconds(pid):
    out = subprocess.run(["ps", "-o", "time=", "-p", str(pid)],
                         capture_output=True, text=True).stdout
    return parse_ps_time(out)


def read_rss_kb(pid):
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)],
                         capture_output=True, text=True).stdout
    out = out.strip()
    return int(out) if out else 0


class Sampler:
    def __init__(self, pid):
        self.pid = pid
        self.rss = []
        self.cpu0 = None
        self.t0 = None

    def start(self):
        if not self.pid:
            return
        self.cpu0 = read_cpu_seconds(self.pid)
        self.t0 = time.monotonic()

    def sample(self):
        if not self.pid:
            return
        try:
            self.rss.append(read_rss_kb(self.pid))
        except Exception:
            pass

    def stop(self):
        if not self.pid or self.cpu0 is None:
            return {}
        elapsed = time.monotonic() - self.t0
        cpu1 = read_cpu_seconds(self.pid)
        ncpu = os.cpu_count() or 1
        cpu_pct = (cpu1 - self.cpu0) / elapsed * 100 if elapsed else 0
        return {
            "cpu_seconds": round(cpu1 - self.cpu0, 3),
            "cpu_percent_of_one_core": round(cpu_pct, 1),
            "cpu_percent_of_machine": round(cpu_pct / ncpu, 1),
            "rss_kb_avg": round(sum(self.rss) / len(self.rss)) if self.rss else None,
            "rss_kb_max": max(self.rss) if self.rss else None,
        }


# --- runner ------------------------------------------------------------------

async def run_worker(session, scenario_fn, ctx, requires_auth, deadline, lat, statuses, counter):
    headers = {"Authorization": f"Bearer {ctx['token']}"} if requires_auth else {}
    while time.monotonic() < deadline:
        method, path, kwargs = scenario_fn(ctx)
        kwargs = dict(kwargs)
        if requires_auth:
            kwargs.setdefault("headers", headers)
        t0 = time.perf_counter()
        try:
            async with session.request(method, path, **kwargs) as r:
                await r.read()
                status = r.status
        except Exception as e:  # noqa: BLE001
            status = f"exc:{type(e).__name__}"
        dt = time.perf_counter() - t0
        lat.append(dt)
        statuses[status] = statuses.get(status, 0) + 1
        counter[0] += 1


async def measure(scenario_name, scenario_fn, ctx, concurrency, duration, warmup, sampler):
    # One shared session per worker: keep-alive to the same server connection.
    connector = aiohttp.TCPConnector(limit=0, force_close=False)
    timeout = aiohttp.ClientTimeout(total=30)
    session = aiohttp.ClientSession(base_url=BASE_URL, connector=connector, timeout=timeout)
    try:
        # Warmup (not recorded).
        if warmup > 0:
            wl, ws, wc = [], {}, [0]
            wdeadline = time.monotonic() + warmup
            await asyncio.gather(*[
                run_worker(session, scenario_fn, ctx, getattr(scenario_fn, "requires_auth", True),
                           wdeadline, wl, ws, wc)
                for _ in range(concurrency)
            ])

        lat, statuses, counter = [], {}, [0]
        sampler.start()
        sample_task = asyncio.create_task(_sampler_loop(sampler))
        deadline = time.monotonic() + duration
        t_start = time.monotonic()
        await asyncio.gather(*[
            run_worker(session, scenario_fn, ctx, getattr(scenario_fn, "requires_auth", True),
                       deadline, lat, statuses, counter)
            for _ in range(concurrency)
        ])
        elapsed = time.monotonic() - t_start
        sample_task.cancel()
        proc = sampler.stop()
    finally:
        await session.close()
        await connector.close()

    lat.sort()
    n = len(lat)

    def pct(p):
        if not n:
            return None
        idx = min(n - 1, int(round(p / 100 * n)))
        return round(lat[idx] * 1000, 3)

    errors = sum(c for s, c in statuses.items() if not (isinstance(s, int) and s in OK_STATUS))
    result = {
        "scenario": scenario_name,
        "concurrency": concurrency,
        "duration_s": round(elapsed, 3),
        "requests": n,
        "rps": round(n / elapsed, 1) if elapsed else 0,
        "errors": errors,
        "error_rate": round(errors / n, 5) if n else 0,
        "status": {str(k): v for k, v in sorted(statuses.items(), key=lambda kv: str(kv[0]))},
        "latency_ms": {
            "mean": round(sum(lat) / n * 1000, 3) if n else None,
            "p50": pct(50), "p90": pct(90), "p99": pct(99),
            "max": round(lat[-1] * 1000, 3) if n else None,
        },
        "server": proc,
    }
    return result


async def _sampler_loop(sampler):
    try:
        while True:
            sampler.sample()
            await asyncio.sleep(0.25)
    except asyncio.CancelledError:
        pass


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scenarios", default="limits,guilds,channels,messages50,messages1,me,users,search")
    ap.add_argument("--concurrency", default="1,8,32,64,128")
    ap.add_argument("--duration", type=float, default=5.0)
    ap.add_argument("--warmup", type=float, default=1.0)
    ap.add_argument("--pid", type=int, default=None, help="server PID for CPU/RSS sampling")
    ap.add_argument("--out", default=None)
    ap.add_argument("--tag", default="baseline")
    ap.add_argument("--repeat", type=int, default=1)
    args = ap.parse_args()

    scenario_names = [s for s in args.scenarios.split(",") if s]
    concurrencies = [int(c) for c in args.concurrency.split(",") if c]
    scenarios = build_scenarios(scenario_names)

    if args.pid is None:
        args.pid = detect_server_pid()
    print(f"server pid: {args.pid}", flush=True)

    ctx = load_ctx()
    await prepare(ctx)

    out = Path(args.out) if args.out else ROOT / "bench" / "results" / f"{args.tag}.json"
    out.parent.mkdir(parents=True, exist_ok=True)

    def save(extra_error=None):
        payload = {"config": {"base_url": BASE_URL, "duration": args.duration,
                              "warmup": args.warmup, "repeat": args.repeat},
                   "results": all_results}
        if extra_error:
            payload["last_error"] = extra_error
        out.write_text(json.dumps(payload, indent=2))

    all_results = []
    for name in scenario_names:
        fn = scenarios[name]
        for conc in concurrencies:
            runs = []
            failed = None
            for rep in range(args.repeat):
                sampler = Sampler(args.pid)
                try:
                    res = await measure(name, fn, ctx, conc, args.duration, args.warmup, sampler)
                except Exception as e:  # keep the sweep alive and recorded
                    save(f"{name} c={conc}: {type(e).__name__}: {e}")
                    print(f"  {name:12s} c={conc:<4d} FAILED {type(e).__name__}: {e}", flush=True)
                    failed = {"scenario": name, "concurrency": conc,
                              "error": f"{type(e).__name__}: {e}"}
                    break
                res["repeat"] = rep
                res["tag"] = args.tag
                runs.append(res)
                print(f"  {name:12s} c={conc:<4d} rps={res['rps']:>9.1f} "
                      f"p50={res['latency_ms']['p50']} p99={res['latency_ms']['p99']} "
                      f"err={res['errors']} cpu={res['server'].get('cpu_percent_of_one_core')}",
                      flush=True)
            if failed is not None:
                best = failed
            else:
                # Median rps run is representative; keep the min/max spread.
                runs.sort(key=lambda r: r["rps"])
                best = runs[len(runs) // 2]
                best["rps_runs"] = [r["rps"] for r in runs]
                best["rps_spread_pct"] = round(
                    (runs[-1]["rps"] - runs[0]["rps"]) / runs[0]["rps"] * 100, 1
                ) if runs[0]["rps"] else None
            all_results.append(best)
            save()

    print(f"wrote {out}")


if __name__ == "__main__":
    asyncio.run(main())
