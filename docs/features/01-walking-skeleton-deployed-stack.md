# Feature: Walking Skeleton — Deployed stack on the droplet

**ID:** F-01 · **Roadmap piece:** F-01 · **Status:** Not started

## Description

This is the **Walking Skeleton**: the thinnest possible end-to-end
slice of the production architecture, deployed to the actual production
host on day one. It establishes the full deploy story (Kamal → DO
droplet → Docker containers → subdomain TLS) and the inter-service
plumbing (Rails ↔ Python sidecar ↔ Postgres ↔ DigitalOcean Spaces)
with no real business logic — just one trivial round-trip that proves
the wires are connected.

Why it exists: every subsequent feature plugs into a real, running,
deployed system from day one. The biggest schedule risks in this
project — getting Kamal up on a host that already runs other services,
getting the Rails/Python IPC working through Docker networking,
provisioning the right DO services with the right secrets — surface
immediately, not at the end of the build window when they would derail
the demo.

## How it fits the roadmap

**Wave 0; the only blocker for everything else.** Every other feature
depends on F-01 directly or transitively. F-01 is itself the critical
path's first node; landing it quickly enables three parallel Wave 1
features (F-02 contract, F-03 auth, F-04 brand) to start at once.

## Dependencies (must exist before this starts)

- **External: DigitalOcean droplet** that already exists per CLAUDE.md
  (hostname `gauntlet-1`, SSH via `ssh gauntlet`); needs adequate
  resources (recommend `s-4vcpu-8gb` or larger).
- **External: DigitalOcean Spaces** account + an empty Space (or four:
  `rooftrace-uploads`, `rooftrace-cache`, `rooftrace-artifacts`,
  `rooftrace-backups`); access key + secret.
- **External: Docker registry credentials** (Docker Hub or DO Container
  Registry).
- **External: Caddy host-level config** on the droplet already
  proxies to per-project Docker stacks; subdomain
  `rooftrace.biograph.dev` needs DNS + a Caddy entry routing to the
  Kamal-internal port.

## Unblocks (what waits on this)

- **F-02 Pipeline JSON Schema** — needs the deployed sidecar to
  validate the schema round-trip works.
- **F-03 Auth machinery** — needs the deployed Rails app to add auth
  controllers/filters into.
- **F-04 Brand assets** — needs the deployed Rails asset pipeline.
- **Every other feature** transitively.

## Acceptance criteria

- Running `kamal deploy` from a developer machine builds the Rails
  and sidecar images, pushes them to the registry, and rolls them on
  the droplet with zero downtime.
- `https://rooftrace.biograph.dev/health` returns HTTP 200 with a
  JSON body identifying the Rails app version, the deployed git SHA,
  and the current time.
- `https://rooftrace.biograph.dev/skeleton` triggers a request that
  Rails forwards to the sidecar's `POST /skeleton` endpoint over the
  internal Docker network; the sidecar returns a hardcoded payload;
  Rails persists one row to Postgres recording the round-trip; the
  response includes the persisted row id. **This proves the full
  stack works end-to-end.**
- Postgres runs as a sibling container with PostGIS extension enabled
  (verified by `SELECT postgis_version()` returning a version
  string).
- A test object can be written to and read from each of the four DO
  Spaces buckets via the configured S3-compatible client from inside
  the Rails container.
- The Rails container can be restarted via Kamal without losing
  Postgres data (Postgres data volume is on a Kamal-declared named
  volume that survives container replacement).
- `LICENSES.md` exists at the repo root with placeholder sections
  for the providers that will be added by later features (NAIP,
  USGS 3DEP, MS Footprints, Regrid, Mapbox, Nominatim).
- The repo structure matches [ADR-008](../adrs/ADR-008-backend-rails-with-python-sidecar.md):
  `rails/`, `sidecar/`, `ios/` (placeholder), `shared/`, `ops/`,
  `docs/`.

## Testing requirements

- **Integration test (run in CI):** a Rails request spec that hits
  `/skeleton` and verifies the round-trip persists a row and returns
  it. The sidecar in CI runs as a sibling docker-compose service so
  the test exercises the real IPC boundary, not a mock.
- **Smoke test against the live deploy:** a small shell script
  (`ops/smoke.sh`) that curls `/health` and `/skeleton` against
  `rooftrace.biograph.dev` and asserts both succeed; run as a
  post-deploy step.
- **DB persistence test:** restart the Rails container via Kamal
  during smoke testing; verify the previously-persisted row is
  still readable. This catches volume-mount misconfiguration that
  the architecture explicitly worries about.
- **Spaces connectivity test:** part of `/health`'s body should
  report write+read success against each bucket (so deploy fails
  fast if credentials drift).

## Manual setup required

- **Provision the DigitalOcean droplet** (or confirm the existing
  `gauntlet-1` has capacity); install Docker.
- **Provision four DigitalOcean Spaces** and capture access
  credentials.
- **Set up Docker registry credentials** (Docker Hub free tier is
  fine for v1).
- **Add DNS A-record** for `rooftrace.biograph.dev` pointing to the
  droplet.
- **Edit host-level Caddyfile** on the droplet to proxy
  `rooftrace.biograph.dev` to the Kamal-internal port; coordinate
  with the other biograph.dev projects already on the host (per
  CLAUDE.md).
- **Configure Kamal secrets** with: registry creds, Spaces creds,
  Postgres password.
- **Verify SSH access** via `ssh gauntlet`.

## Implementation notes (filled in by the building agent)

> The agent implementing this feature records its implementation
> decisions and rationale here as it builds — chosen libraries/patterns
> within the architecture's constraints, trade-offs made, deviations
> from assumptions and why, and anything the next agent or the
> integrator needs to know. This section starts empty and is owned by
> the builder, not the planner. Cross-cutting discoveries that affect
> other features must also be propagated to ROADMAP.md or the
> architecture doc, not just left here.
