# Development Guide

## Architecture

Distrans is a Zig backend for realtime community chat, backed by PostgreSQL. HTTP
and WebSocket traffic runs through a single event loop; background workers handle
bounded jobs such as password hashing, media processing, file maintenance, and
push delivery. Keep hot-path work non-blocking and all queues, buffers, and
service workloads bounded by configuration.

Authenticated users are implicitly members of every guild. There is no guild
membership or owner model; permissions are computed from roles and channel
overwrites. Do not introduce behavior that assumes membership or ownership.

## Module Boundaries

- `src/router/` dispatches paths; `src/route/` implements endpoint behavior and
  owns outward HTTP DTOs.
- `src/repo/` contains database tasks and shared row types. Repository code must
  not depend on route handlers or wire DTOs.
- `src/services/` contains background and cross-cutting work; `src/db/`,
  `src/http/`, `src/net/`, and `src/el/` provide infrastructure.
- `src/types.zig` defines shared identifiers and persisted/domain types;
  `src/config.zig` defines options and configurable limits; `migrations/` is the
  schema source of truth.
- `docs/openapi.yml` is the API contract. Update it alongside externally
  observable endpoint or schema changes.

Preserve explicit allocator ownership and task/connection lifetimes. Prefer the
existing poll-based task and event-loop patterns over blocking work. Keep
resource limits configurable, and avoid unbounded buffering or fan-out.

## Requirements And Validation

Route requirements use paired R-markers: document each requirement as
`/// R<n> - <description>` near its handler and add `// R<n>` at the enforcing
code. Number markers per endpoint in enforcement order. When adding or changing
a requirement, update its markers and focused success/failure tests.

Follow nearby Zig formatting and naming conventions. Add or update focused tests
for behavior changes. Run `zig build` and `zig build test` for Zig changes; run
the relevant pytest/API tests when endpoint behavior or database integration
changes. API tests require the configured test database and server. Report checks
that could not be run rather than treating them as passed.

Load tests and other destructive benchmarks must use a dedicated disposable
database, never development or production data. The benchmark seeder truncates
the `app.*` tables.
