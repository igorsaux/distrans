#!/usr/bin/env python3
"""Consolidate bench/results/*.json into a CSV + printed tables.

    .venv/bin/python bench/summarize.py
"""

import csv
import json
from pathlib import Path

RESULTS = Path(__file__).resolve().parent / "results"


def load(name):
    p = RESULTS / name
    return json.loads(p.read_text()) if p.exists() else None


def main():
    rows = []

    wrk = load("wrk.json")
    if wrk:
        for r in wrk["results"]:
            rows.append({
                "source": "wrk", "scenario": r["scenario"], "metric": "rps",
                "value": round(r["rps"]), "connections": r["connections"],
                "p50_ms": r["latency_ms"]["50"], "p99_ms": r["latency_ms"]["99"],
                "cpu_pct": r["server"].get("cpu_percent_of_one_core"),
                "rss_kb": r["server"].get("rss_kb_avg"),
            })

    cpu = load("cpu.json")
    if cpu:
        for r in cpu["results"]:
            rows.append({
                "source": "harness", "scenario": r["scenario"], "metric": "rps",
                "value": r["rps"], "connections": r["concurrency"],
                "p50_ms": r["latency_ms"]["p50"], "p99_ms": r["latency_ms"]["p99"],
                "cpu_pct": r["server"].get("cpu_percent_of_one_core"),
                "rss_kb": r["server"].get("rss_kb_avg"),
            })

    ws = load("ws.json")
    if ws:
        for r in ws["results"]:
            rows.append({
                "source": "ws", "scenario": "gateway", "metric": "clients",
                "value": r["connected"], "connections": r["clients"],
                "p50_ms": r["handshake_ms"]["p50"], "p99_ms": r["handshake_ms"]["p99"],
                "delivery_p50_ms": r["delivery_ms"]["p50"],
                "delivery_p99_ms": r["delivery_ms"]["p99"],
                "cpu_pct": r["server"].get("cpu_percent_of_one_core"),
                "rss_kb": r["server"].get("rss_kb_avg"),
            })

    out = RESULTS / "summary.csv"
    fields = ["source", "scenario", "metric", "value", "connections", "p50_ms",
              "p99_ms", "delivery_p50_ms", "delivery_p99_ms", "cpu_pct", "rss_kb"]
    with out.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        for row in rows:
            w.writerow(row)
    print(f"wrote {out} ({len(rows)} rows)")

    if wrk:
        print("\nwrk throughput (best of runs), rps:")
        eps = []
        for r in wrk["results"]:
            if r["scenario"] not in eps:
                eps.append(r["scenario"])
        conns = sorted({r["connections"] for r in wrk["results"]})
        print("  endpoint     " + "".join(f"c={c:<10d}" for c in conns))
        for e in eps:
            line = f"  {e:12s} "
            for c in conns:
                m = next((r for r in wrk["results"]
                          if r["scenario"] == e and r["connections"] == c), None)
                line += f"{round(m['rps']):<12d}" if m else f"{'':<12s}"
            print(line)

    if cpu:
        print("\nargon2 / password path (harness), rps by concurrency:")
        for r in cpu["results"]:
            print(f"  {r['scenario']:12s} c={r['concurrency']:<4d} "
                  f"rps={r['rps']:>7.1f} p50={r['latency_ms']['p50']}ms "
                  f"cpu={r['server'].get('cpu_percent_of_one_core')}%")

    if ws:
        print("\nWebSocket gateway:")
        for r in ws["results"]:
            print(f"  clients={r['connected']:<5d} handshake_p50={r['handshake_ms']['p50']}ms "
                  f"delivery_p50={r['delivery_ms']['p50']}ms "
                  f"delivery_p99={r['delivery_ms']['p99']}ms "
                  f"cpu={r['server'].get('cpu_percent_of_one_core')}% rss={r['server'].get('rss_kb_avg')}KB")


if __name__ == "__main__":
    main()
