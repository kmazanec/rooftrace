# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

RoofTrace — a roof-measurement system for CompanyCam contractors. A contractor
enters an address and gets a roof report (area, per-facet pitch, detected
features) from satellite + public-LiDAR fusion, optionally augmented by a guided
iOS photo capture. See `docs/ARCHITECTURE.md` for the full system design.

The repo is at the **walking-skeleton** stage: the deployed end-to-end plumbing
exists (`/health`, `/skeleton`) but the real geospatial pipeline is not built
yet. Work proceeds feature-by-feature against `docs/ROADMAP.md`.

## Two-language layout (read before navigating)

The **Rails 8 app lives at the repo root** — `app/`, `config/`, `db/`,
`Gemfile`, `bin/` are at the top level, NOT under a `rails/` subdir. Non-Rails
components are siblings of the Rails tree:

- `sidecar/` — Python **FastAPI** service for geospatial numerics (PDAL,
  SAM2, RANSAC, ICP). Stateless; no DB access. Has its own `pyproject.toml` /
  `uv.lock` / `Dockerfile`. Managed with **uv**.
- `ios/` — iOS capture app (placeholder).
- `shared/` — cross-language artifacts (the pipeline JSON schema lives here).
- `ops/` — deploy config (compose, Caddy fragment, smoke script, runbook).
- `infra/` — `deploy.sh` (the production deploy script).
- `docs/` — architecture, ADRs, feature specs, research.

`config/application.rb` tells the Rails autoloader to **ignore** `sidecar/`,
`ios/`, `ops/`, `shared/`, `docs/`.

**Rails ↔ sidecar boundary** (ADR-008): Rails owns HTTP/auth/persistence/jobs;
the Python sidecar owns geometry. They talk HTTP/JSON over the internal Docker
network, guarded by a shared-secret bearer (`SIDECAR_SHARED_SECRET`). The sidecar
is internal-only. `app/services/sidecar_client.rb` is the Rails-side client.

## Commands

### Rails (run from repo root)

Tests need a **PostGIS** database (plain `postgres` won't work). Start the local
throwaway container once:

```bash
docker run -d --name rt-pg -e POSTGRES_PASSWORD=devpassword \
  -e POSTGRES_USER=rooftrace -e POSTGRES_DB=rooftrace_test \
  -p 5433:5432 postgis/postgis:17-3.5
```

`config/database.yml` **defaults** dev/test to this container (localhost:5433,
rooftrace/devpassword), so the standard Rails commands work with **no exported
env vars** — just run them:

```bash
bin/rails db:test:prepare
bundle exec rspec                              # full suite
bundle exec rspec spec/requests/skeleton_spec.rb   # one file
bundle exec rspec spec/models/skeleton_ping_spec.rb:10   # one example by line
bin/rubocop      # lint (omakase; CI-gating)
bin/brakeman     # security scan (CI-gating)
```

**NEVER prefix these commands with `DATABASE_*` / `PGPASSWORD` (exported or
inline `env ...`).** Run them bare. Credentials on the command line are a config
smell; if a command seems to need them, the bug is in `database.yml`'s defaults —
fix that, don't pass env vars. (CI and other hosts override the defaults via the
`DATABASE_*` env vars; you never set those locally.)

**Don't run ad-hoc `Job.create!` / mutating `bin/rails runner` against this DB** —
committed rows leak into the test DB and can make data-sensitive specs spuriously
fail. Use `rails console --sandbox` or wrap experiments in a rolled-back transaction.

The `/skeleton` request spec boots the **real** Python sidecar as a `uv run
uvicorn` subprocess (see `spec/support/real_sidecar.rb`) — no mocks, by design
(the IPC boundary is exercised for real). So Rails specs need `uv` available and the sidecar
deps synced (`cd sidecar && uv sync`). `SKIP_REAL_SIDECAR=1` skips booting it —
but then the `/skeleton` + pipeline-round-trip specs that need the live sidecar
fail, so **don't use it for a full-suite run** (it's for iterating on unrelated
specs only).

### Sidecar (run from `sidecar/`)

```bash
cd sidecar
uv sync
SIDECAR_SHARED_SECRET=test-shared-secret uv run pytest -v
```

### Full stack locally (docker-compose)

```bash
docker compose -f ops/compose.yaml up --build
curl http://localhost:3000/health
curl http://localhost:3000/skeleton
```

## Conventions that aren't obvious from the code

- **Migrations: always via `bin/rails generate migration ...`** — never
  hand-write a file in `db/migrate/`. Edit the generated file only for clauses
  the generator can't express (e.g. `enable_extension "postgis"`).
- **Schema is dumped as SQL** (`config.active_record.schema_format = :sql`,
  `db/structure.sql`) because PostGIS's internal tables break Rails' Ruby schema
  dumper. There is no `db/schema.rb`. Loading the schema needs `psql` + Postgres 17+.
- **UUID primary keys** by default (set in `config/application.rb` generators).
- **`/health` is public + unauthenticated** — it must never leak raw exception
  detail (AWS errors carry access keys / bucket names). It does a Postgres +
  DigitalOcean Spaces probe and returns 503 on any failure (so the deploy gate
  fast-fails). `/up` is the cheap liveness check (no DB/Spaces); it's the
  container healthcheck target. Keep that liveness-vs-readiness split.
- **Spaces is ONE bucket partitioned by key prefix** (`uploads/` `cache/`
  `artifacts/` `backups/`), not four buckets (ADR-010 as amended).
- **Fail fast at boot on misconfiguration, don't fail silently at request time.**
  Required external config (env vars, the pipeline schema file, etc.) is checked
  in an `after_initialize` initializer that **raises in production** (warns in
  dev/test) when missing — so a bad deploy dies on boot with a clear message
  instead of leaving `/health` green while every affected request 500s or
  silently rejects. See `config/initializers/pipeline_schema.rb` and
  `config/initializers/demo_login.rb`.
- **Opaque tokens use Rails' `has_secure_token`** — `has_secure_token :col,
  length: 32, on: :create` (`SecureRandom.base58`, ~187 bits). Back it with a DB
  **unique index** on the column; that's the safeguard against the (astronomically
  unlikely) collision — do NOT hand-roll a regenerate-and-retry loop. Use this for
  any new bearer/share token (see `Job#capture_token`, `Report#share_token`).
- **The running product always uses REAL data; fixtures are a TEST-ONLY opt-down.**
  Every geospatial stage's real path (NAIP imagery, 3DEP/PDAL LiDAR, Modal SAM2,
  Mapbox map render, OpenRouter VLM, live Spaces) is the DEFAULT in dev AND prod.
  There is NO silent fixture fallback in the running app — a missing real-path
  prerequisite fails LOUD (at `bin/setup` and at sidecar boot), never degrades to a
  placeholder. Fixtures/stubs are reachable ONLY via explicit opt-down flags that
  the automated test suites set: `IMAGERY_FIXTURE` / `LIDAR_FIXTURE` /
  `RENDER_IMAGES_FIXTURE` / `PROJECT_PHOTO_FIXTURE` / `SAM2_BACKEND=local` /
  `STORAGE_LOCAL_ROOT`. The flag
  polarity lives in one place — `sidecar/app/flags.py` + `sidecar/app/boot_checks.py`;
  the suites opt down in `sidecar/tests/conftest.py` and `spec/support/real_sidecar.rb`.
  Locally, `bin/dev` runs the sidecar as its DOCKER IMAGE (which carries the real
  conda geo stack) so the host needs no conda; the test suites still boot the
  sidecar via `uv run` on the fixture opt-down. NEVER set a `*_FIXTURE` flag in a
  dev/prod `.env`. When adding a stage with a real/fixture split, follow this
  polarity: real default, `*_FIXTURE` opt-down, boot-check the real prerequisite.

## Architecture decisions live in ADRs

`docs/adrs/ADR-0NN-*.md` are the source of truth for *why* the system is built
the way it is. **Do not make architectural decisions inline** — if implementation
forces a decision to change, amend the relevant ADR (and `ROADMAP.md` /
`ARCHITECTURE.md` if cross-cutting) rather than diverging silently. Several ADRs
already carry early-iteration amendments (008 layout, 009 image/schema-format,
010 one bucket, 011 compose-not-Kamal) — match that "amend at source" pattern.

`docs/features/NN-*.md` are per-feature specs with acceptance criteria; each is
the contract + living progress tracker for that feature.

- **NEVER reference transient feature files (`F-NN` / `docs/features/NN-*.md`)
  in anything permanent** — code comments, config, prompts, committed docs like
  this file or `LICENSES.md`. Feature specs are temporary work-tracking
  artifacts; they get archived and their `F-NN` IDs become dangling noise. A
  comment must either stand on its own or reference **long-lived documentation
  only** — an ADR (`ADR-0NN`), `ARCHITECTURE.md`, or a stable schema file.
  Referencing `F-NN` in a **commit message** is fine (commits are themselves a
  transient, point-in-time record). Describing the docs *structure* in the
  abstract (as this section does) is fine; naming a specific live `F-NN` as a
  pointer is not.

## Deploy (production)

RoofTrace runs as three containers (`rooftrace-web`, `rooftrace-sidecar`,
`rooftrace-postgres`) on the shared `gauntlet` DigitalOcean droplet, behind a
**containerized Caddy** (`openemr-caddy-1`) that routes `rooftrace.biograph.dev`
to `rooftrace-web` **by container name** over the shared `openemr_default`
network. **Deploy is docker-compose + a release-symlink script, NOT Kamal**
(ADR-011 amended — the droplet's shared-Caddy topology and Kamal's registry/
proxy requirements made compose the right call).

- `infra/deploy.sh` — the release-symlink deploy (rsync checkout →
  `/srv/rooftrace/releases/<sha>/`, atomic `current` swap, build+recreate,
  health-check the public `/up`, rollback on failure, prune). Runs in GitLab CI
  on push to `main`, or by hand on the droplet.
- `ops/compose.prod.yaml` — production compose (absolute build contexts at
  `/srv/rooftrace/current`; secrets via `env_file: /etc/rooftrace/.env`).
- `ops/README.md` — the full deploy runbook + one-time droplet setup.
- `.gitlab-ci.yml` — `verify` (sidecar pytest + Rails RSpec, run inside
  `docker run` because the runner is a **shell executor**) → `deploy` (main only).
  Build work must NOT write into the persistent checkout dir (mount read-only,
  copy into the container) or the next run's `get_sources` fails on root-owned
  leftovers.

See the workspace-level `../../INFRA.md` for the droplet's shared conventions.
