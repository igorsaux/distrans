# Distrans

Community-first, self-hosted real time chat backend for independent communities.

Distrans is not a full-scale copy of a chat backend for millions of active users, and it doesn't even try to be that. Instead, it's more like a decentralized solution for individual communities, so they can have their own experience with their own rules, local laws, and moderation. This is what everyone really needs, not the need to support the infrastructure of an international company just for thousands of users in prime time.

The backend is ready and tested on a guild with more than 8 years of history, more than 20 million messages and thousands of members. I don't think there will be any major changes, but there will probably be some optimization and refinement.

## Features

### Pros

- Simple to deploy and maintain - only one executable file and a few system-wide library dependencies. (Yes, it's possible to create a software without TONS of mandatory bloat services, but that's lost knowledge.)
- Apache-2.0 license - truly libre implementation, feel free to fork and do whatever you want.
- Built for minimal and controllable resource usage, with fail-safe and safety in mind, you can tweak how much resource will be used. Modest VPS with 1 vCPU, 2 GB RAM, and 30 GB NVMe with a database on the same machine are enough to serve hundreds if not thousands of active users.
- Only essential functionality - no enforced registration scheme, guild creation and ownership, but all you may need from a chat are here: guilds, channels, categories, custom emojis and reactions, file uploads, roles, bots, webhooks, push notifications.
- No Rust-slop - the code is written in one of the clearest and easiest languages, Zig. It's straightforward and without any hidden logic. You can easily add or remove features without struggling with an overly complicated language with no gain. If you don't want to touch the code, that's okay - LLMs can work with the codebase and create features by assembling tested and solid components.
- Over 1k end-to-end tests, it's pretty hard to break some functionality without even noticing it.

### Cons

- There are no voice and video streaming features.

## Requirements

- [Zig](https://ziglang.org/) 0.16.0
- PostgreSQL
- Native libraries: `libpq`, FFmpeg (`libavformat`/`libavcodec`/`libavutil`/`libswscale`),
  `libwebp`/`libwebpdemux`, `libcurl`

On Debian/Ubuntu the dev packages are, e.g.:

```sh
apt install libpq-dev libavformat-dev libavcodec-dev libavutil-dev libswscale-dev libwebp-dev libcurl4-openssl-dev
```

## Quick start

### Run the server

```sh
cp config.example.json config.json
zig build run -- config.json
```

The server listens on the configured HTTP address (default `http://localhost:8080`).

### Generate Web Push keys

`zig build run -- --gen-vapid` prints a ready-to-paste `push` configuration block and exits.

### Bootstrap users and a guild

The dependency-free scripts in `scripts/` read the `system.token` and socket bind from
the same config file. Run them from the repository root:

```sh
python3 scripts/adduser.py -c config.json -u admin
python3 scripts/addguild.py -c config.json -n "My Guild"
python3 scripts/addsuperuser.py -c config.json --guild-id <id> --user-id <id>
```

Use the IDs printed by the first two commands when granting superuser permissions.

For a bot, create the user with `--is-bot`, then issue its token:

```sh
python3 scripts/adduser.py -c config.json -u bot --is-bot
python3 scripts/addbottoken.py -c config.json --user-id <id>
```

`edituser.py`, `deluser.py`, `delguild.py`, and `delrole.py` provide related
maintenance operations; all scripts accept `-c`/`--config`.

## Legal pages

The legal texts served at `GET /api/terms` and `GET /api/privacy` are in
`src/route/legal/terms.md` and `src/route/legal/privacy.md`. They are embedded in
the binary with `@embedFile`. Fill in the `[operator name]`, `[contact]`, provider,
and retention placeholders, update the version/date line, then rebuild and
redeploy to publish changes.

## Configuration

All settings, including the DB `conninfo` and secrets, come from a single JSON config parsed by
`src/config.zig` (`Options`/`parseConfig`). The config path is the first CLI argument and defaults
to `config.json`. Unknown keys are ignored.

`config.example.json` is the template; `config.tests.json` is used by the test suite.

## Tests

```sh
zig build test
```

API tests need a running server and a reachable test database (see `config.tests.json`):

```sh
zig build run -- config.tests.json
uv run pytest
```

Socket abuse tests live in `tests/net/` and boot their own servers; run them separately.

## Documentation

- [`docs/openapi.yml`](docs/openapi.yml) - API contract (endpoints, schemas, errors, wire rules).
- [`AGENTS.md`](AGENTS.md) - architecture, module boundaries, conventions, and development checks.

## Performance

The following are indicative results reported from earlier tests on a MacBook Air
with an M3 chip while it was also doing other work. The exact dataset, build settings,
and test commands for those measurements were not recorded, so treat them as
historical observations rather than reproducible guarantees:

- Up to **8,000 simultaneous connections**, at approximately **35 KB of server
  memory per connection**, without errors or stalls in that test.
- User and channel listings: thousands of requests per second; message history:
  several thousand requests per second. History throughput depends heavily on the
  database.
- Message search: approximately **430 requests per second**.
- Password checks: approximately **68 logins per second**. Password verification is
  deliberately expensive, and checks share a worker.

Actual capacity depends on hardware, PostgreSQL, configuration, workload, and
concurrency. Use the benchmark tools below to measure a particular deployment.

## Benchmarking

The scripts in `bench/` provide ad-hoc HTTP throughput and latency tests, WebSocket
connection and delivery tests, and result summaries. Run them against a dedicated,
disposable benchmark database and a separate config (for example,
`config.bench.json`, based on `config.example.json`). The seeder truncates the
`app.*` tables; **never point it at a development or production database**.

Create a disposable PostgreSQL database (for example, `distrans_bench`) and a
separate `config.bench.json` copied from `config.example.json`. Point it only at
that database, use a separate port (for example, `8090`), set `files.type` to
`"none"`, and leave `push.enabled` false. The benchmark scripts require the project Python
dependencies and `wrk` for the throughput sweep (`uv sync` installs the Python
dependencies).

Build and start the release server in one terminal:

```sh
zig build -Doptimize=ReleaseFast
zig-out/bin/distrans config.bench.json
```

In another terminal, from the repository root, seed data and run sample sweeps:

```sh
.venv/bin/python bench/seed.py
.venv/bin/python bench/load.py \
  --scenarios limits,guilds,channels,messages50,users,search \
  --concurrency 1,8,32,64 --duration 5 --tag baseline
.venv/bin/python bench/wrkbench.py --connections 8,32,64,128 --duration 6 --repeat 2
.venv/bin/python bench/wsbench.py --clients 1,64,128,256 --hold 5 --broadcasts 5
.venv/bin/python bench/summarize.py
```

`BENCH_CONFIG` can select a config at another path. By default, the seeder creates
5,000 users, 60 text channels, and 2,000 messages per channel; the `BENCH_USERS`,
`BENCH_CHANNELS`, and `BENCH_MESSAGES_PER_CHANNEL` environment variables adjust
the dataset size. Results are written under the git-ignored `bench/results/`;
`bench/seed.json` contains generated benchmark credentials and is also ignored.
Keep these files private and do not commit them.

HTTP and WebSocket traffic share the server's event loop and the configured
`general.max_peers` limit. Background service queues and the database can become
the bottleneck before the load generator does; record the hardware, dataset, build
mode, and command line when publishing or comparing results.
