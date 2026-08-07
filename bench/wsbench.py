#!/usr/bin/env python3
"""WebSocket gateway benchmark for distrans.

For each client count: open N concurrent gateway connections, measure the
connect+identify handshake, hold the connections (acking heartbeats), then post
a few messages and measure dispatch-delivery latency across every connected
client (the push fan-out is global). Records server CPU/RSS over the hold.

    .venv/bin/python bench/wsbench.py --clients 1,64,128,256 --hold 5 --broadcasts 5
"""

import argparse
import asyncio
import json
import sys
import time
from pathlib import Path

import aiohttp

sys.path.insert(0, str(Path(__file__).resolve().parent))
from load import (  # noqa: E402
    ADMIN_PASSWORD, ADMIN_USERNAME, BASE_URL, Sampler, detect_server_pid,
    load_ctx, login,
)

ROOT = Path(__file__).resolve().parent.parent
ACK_INTERVAL = 3.0


def pct(values, p):
    if not values:
        return None
    s = sorted(values)
    idx = min(len(s) - 1, int(round(p / 100 * len(s))))
    return round(s[idx] * 1000, 3)


async def run_client(cid, session, token, ready, stop, received, handshakes, errors):
    try:
        t0 = time.perf_counter()
        ws = await session.ws_connect("/api/gateway")
        await ws.send_json({"op": "identify", "d": {"token": token}})
        while True:
            msg = await asyncio.wait_for(ws.receive(), timeout=10)
            if msg.type == aiohttp.WSMsgType.TEXT:
                data = json.loads(msg.data)
                if data.get("op") == "hello":
                    break
            elif msg.type in (aiohttp.WSMsgType.CLOSED, aiohttp.WSMsgType.ERROR):
                raise RuntimeError("closed before hello")
        handshakes.append(time.perf_counter() - t0)
    except Exception as e:  # noqa: BLE001
        errors.append(f"{type(e).__name__}: {e}")
        return

    ready[0] += 1

    async def acker():
        while not stop.is_set():
            try:
                await asyncio.wait_for(stop.wait(), timeout=ACK_INTERVAL)
                return
            except asyncio.TimeoutError:
                pass
            try:
                await ws.send_json({"op": "ack"})
            except Exception:  # noqa: BLE001
                return

    async def reader():
        try:
            async for msg in ws:
                if msg.type != aiohttp.WSMsgType.TEXT:
                    if msg.type in (aiohttp.WSMsgType.CLOSED, aiohttp.WSMsgType.ERROR):
                        return
                    continue
                data = json.loads(msg.data)
                if data.get("op") == "dispatch" and data.get("t") == "message_created":
                    mid = data.get("d", {}).get("id")
                    if mid is not None:
                        received.setdefault(mid, []).append(time.perf_counter())
        except Exception:  # noqa: BLE001
            return

    ack_task = asyncio.create_task(acker())
    read_task = asyncio.create_task(reader())
    await stop.wait()
    ack_task.cancel()
    read_task.cancel()
    try:
        await ws.close()
    except Exception:  # noqa: BLE001
        pass


async def run_level(n_clients, ctx, broadcasts, hold, session_factory, pid):
    connector = aiohttp.TCPConnector(limit=0)
    timeout = aiohttp.ClientTimeout(total=30)
    # Long-lived session for the socket clients.
    ws_session = aiohttp.ClientSession(base_url=BASE_URL, connector=connector, timeout=timeout)
    http_session = aiohttp.ClientSession(base_url=BASE_URL, timeout=timeout)
    try:
        received, handshakes, errors = {}, [], []
        ready = [0]
        stop = asyncio.Event()
        sampler = Sampler(pid)

        sampler.start()
        sample_task = asyncio.create_task(_sample_loop(sampler))
        clients = [
            asyncio.create_task(run_client(i, ws_session, ctx["token"], ready, stop,
                                           received, handshakes, errors))
            for i in range(n_clients)
        ]
        # Give clients time to connect + identify.
        for _ in range(200):
            if ready[0] >= n_clients:
                break
            await asyncio.sleep(0.05)

        broadcasts_done = 0
        delivery = []
        post_rtt = []
        post_failures = 0
        headers = {"Authorization": f"Bearer {ctx['token']}"}
        for b in range(broadcasts):
            if ready[0] == 0:
                break
            t0 = time.perf_counter()
            try:
                async with http_session.post(
                    f"/api/channels/{ctx['write_channel']}/messages",
                    json={"content": f"wsbench {b} {time.time_ns()}"}, headers=headers,
                ) as r:
                    body = await r.json()
                post_rtt.append(time.perf_counter() - t0)
                mid = body.get("id")
            except Exception:  # noqa: BLE001
                post_failures += 1
                await asyncio.sleep(0.2)
                continue
            await asyncio.sleep(0.5)  # let dispatches arrive
            times = received.get(mid, [])
            if times:
                # Delivery latency measured from just before the POST.
                delivery.extend(t - t0 for t in times)
            broadcasts_done += 1

        server = sampler.stop()
        stop.set()
        await asyncio.gather(*clients, return_exceptions=True)
        sample_task.cancel()
    finally:
        await ws_session.close()
        await http_session.close()
        await connector.close()

    return {
        "clients": n_clients,
        "connected": ready[0],
        "handshake_errors": len(errors),
        "handshake_ms": {"p50": pct(handshakes, 50), "p99": pct(handshakes, 99),
                         "max": round(max(handshakes) * 1000, 3) if handshakes else None},
        "broadcasts": broadcasts_done,
        "post_failures": post_failures,
        "deliveries_observed": len(delivery),
        "delivery_ms": {"p50": pct(delivery, 50), "p99": pct(delivery, 99),
                        "max": round(max(delivery) * 1000, 3) if delivery else None},
        "post_rtt_ms": {"p50": pct(post_rtt, 50), "p99": pct(post_rtt, 99)},
        "server": server,
    }


async def _sample_loop(sampler):
    try:
        while True:
            sampler.sample()
            await asyncio.sleep(0.25)
    except asyncio.CancelledError:
        pass


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--clients", default="1,64,128,256")
    ap.add_argument("--hold", type=float, default=5.0)
    ap.add_argument("--broadcasts", type=int, default=5)
    ap.add_argument("--pid", type=int, default=None)
    ap.add_argument("--out", default=None)
    ap.add_argument("--tag", default="ws")
    args = ap.parse_args()

    if args.pid is None:
        args.pid = detect_server_pid()
    print(f"server pid: {args.pid}", flush=True)

    ctx = load_ctx()
    async with aiohttp.ClientSession(base_url=BASE_URL) as s:
        ctx["token"] = await login(s)

    levels = [int(c) for c in args.clients.split(",") if c]
    results = []
    for n in levels:
        res = await run_level(n, ctx, args.broadcasts, args.hold, None, args.pid)
        results.append(res)
        print(f"  clients={n:<5d} connected={res['connected']} "
              f"hs_p50={res['handshake_ms']['p50']}ms hs_p99={res['handshake_ms']['p99']}ms "
              f"deliv_p50={res['delivery_ms']['p50']}ms deliv_p99={res['delivery_ms']['p99']}ms "
              f"sent={res['deliveries_observed']} cpu={res['server'].get('cpu_percent_of_one_core')} "
              f"rss={res['server'].get('rss_kb_avg')}KB err={res['handshake_errors']}", flush=True)

    out = Path(args.out) if args.out else ROOT / "bench" / "results" / f"{args.tag}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"hold_s": args.hold, "broadcasts": args.broadcasts,
                               "results": results}, indent=2))
    print(f"wrote {out}")


if __name__ == "__main__":
    asyncio.run(main())
