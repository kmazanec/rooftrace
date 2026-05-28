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
- `ops/` — Kamal config, Docker compose, host-Caddy fragment, smoke tests
- `docs/` — architecture, ADRs, feature specs, research

## Local development

Tests need a **PostGIS** database. Start the local container once:

```bash
docker run -d --name rt-pg -e POSTGRES_PASSWORD=devpassword \
  -e POSTGRES_USER=rooftrace -e POSTGRES_DB=rooftrace_test \
  -p 5433:5432 postgis/postgis:17-3.5
```

`config/database.yml` defaults dev/test to this container, so run the standard
Rails commands directly — **no `DATABASE_*` / `PGPASSWORD` env vars**:

```bash
bin/rails db:test:prepare
bundle exec rspec                 # Rails suite (boots the real sidecar subprocess)
bin/rubocop                       # lint
bin/brakeman                      # security scan

cd sidecar && uv sync && SIDECAR_SHARED_SECRET=test-shared-secret uv run pytest
```

(Setting `DATABASE_*` on the command line is wrong — if a command seems to need
it, fix `database.yml`'s defaults instead.)

See [ops/README.md](ops/README.md) for the full runbook (compose up, deploy,
smoke tests).

## Production

Deployed at https://rooftrace.biograph.dev via Kamal to the shared `gauntlet`
DigitalOcean droplet. Host-Caddy terminates TLS and reverse-proxies to the
Rails container.
