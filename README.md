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

See [ops/README.md](ops/README.md) for the runbook (compose up, kamal deploy,
smoke tests).

## Production

Deployed at https://rooftrace.biograph.dev via Kamal to the shared `gauntlet`
DigitalOcean droplet. Host-Caddy terminates TLS and reverse-proxies to the
Rails container.
