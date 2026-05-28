# RoofTrace

Roof-measurement and complexity-mapping system. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
for the system overview, [docs/ROADMAP.md](docs/ROADMAP.md) for the build plan,
and [docs/adrs/](docs/adrs/) for individual decisions.

## Layout

- Repo root — Rails 8 application (`app/`, `config/`, `db/`, `Gemfile`, etc.)
- `sidecar/` — Python FastAPI service for geospatial numerics (PDAL, SAM2,
  RANSAC, ICP)
- `ios/` — iOS capture app (Swift)
- `shared/` — cross-language artifacts (JSON schemas, brand tokens)
- `ops/` — docker-compose stacks, host-Caddy fragment, deploy + smoke scripts
- `infra/` — `deploy.sh` (production release-symlink deploy)
- `docs/` — architecture, ADRs, feature specs, research

## Local development

### Prerequisites

- **Ruby** (version pinned in [`.ruby-version`](.ruby-version)) + **Bundler**
- **Docker** — for the PostGIS database (and the full-stack compose run)
- **[`uv`](https://docs.astral.sh/uv/)** — manages the Python sidecar; the Rails
  test suite boots the real sidecar as a subprocess, so `uv` is needed even for
  Rails-only work

### First-time setup

```bash
bundle install                    # Rails gems
( cd sidecar && uv sync )         # Python sidecar deps

# PostGIS database (one throwaway container, reused across runs):
docker run -d --name rt-pg -e POSTGRES_PASSWORD=devpassword \
  -e POSTGRES_USER=rooftrace -e POSTGRES_DB=rooftrace_test \
  -p 5433:5432 postgis/postgis:17-3.5

bin/rails db:prepare              # create + load schema (dev + test)
```

`config/database.yml` **defaults** dev/test to that container, so every Rails
command below runs with **no `DATABASE_*` / `PGPASSWORD` env vars** — run them
bare. (Credentials on the command line are a config smell; if a command seems to
need them, the fix is in `database.yml`'s defaults, not an env prefix. CI and
other hosts override via those env vars; you never set them locally.)

### Run the app

```bash
bin/dev                           # Rails server + Tailwind watch on localhost:3000
```

`bin/dev` runs Rails only (it talks to a sidecar at `SIDECAR_URL`, default
`localhost:8000`). To run the **whole stack** (Rails + Python sidecar + Postgres)
the way production is wired:

```bash
docker compose -f ops/compose.yaml up --build
curl http://localhost:3000/health     # readiness (DB + Spaces probe)
curl http://localhost:3000/up         # liveness
```

### Tests, lint, security

```bash
bundle exec rspec                 # Rails suite (boots the real sidecar subprocess)
bin/rubocop                       # lint (CI-gating)
bin/brakeman                      # security scan (CI-gating)

( cd sidecar && uv run pytest )   # sidecar suite (self-contained; no env needed)
```

See [ops/README.md](ops/README.md) for the full deploy runbook and one-time
droplet setup.

## Production

Deployed at https://rooftrace.biograph.dev on the shared `gauntlet` DigitalOcean
droplet via **docker-compose + a release-symlink deploy** (`infra/deploy.sh`,
`ops/compose.prod.yaml`), run by GitLab CI on push to `main`. The droplet's
containerized Caddy terminates TLS and reverse-proxies to the Rails container by
name. (Kamal — `ops/deploy.yml` — is the documented future multi-host path, not
the v1 deploy; see [ADR-011](docs/adrs/ADR-011-deploy-kamal-do-droplet.md).)
