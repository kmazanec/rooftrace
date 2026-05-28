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

### Approved plan (Step 4 — persisted from plan-mode approval)

User decisions confirmed in Step 3:

- **TLS routing:** host-Caddy terminates TLS directly to Rails via a
  `/etc/caddy/conf.d/rooftrace.caddyfile` drop-in. Kamal's bundled proxy is
  disabled. Matches existing droplet convention.
- **Deploy target:** full live deploy to the `gauntlet` droplet as part of
  this MR (user explicitly authorized prod mutations on the shared host).
- **Container build:** Kamal `builder: { remote: ssh://gauntlet }` — builds
  directly on the droplet's Docker daemon; no registry, no push, no creds.
- **DO Spaces:** user provisions the four buckets manually; F-01 wires
  ActiveStorage + a write+read+delete health check.
- **Git remote:** GitLab (`labs.gauntletai.com:.../rooftrace.git`); MR opened
  via `glab mr create`.
- **Rails layout (overrides ADR-008):** Rails app at the **repo root**, not
  in a `rails/` subdirectory. `sidecar/`, `ios/`, `shared/`, `ops/` live as
  siblings of `app/` / `config/` / `db/` at the Rails root. ADR-008's layout
  section will be amended in the retro to match shipped reality.
- **Migrations:** **always** via `bin/rails generate migration ...` — never
  hand-written.

### Plan checklist

Each chunk is a coherent build+test slice; tickable as completed.

- [x] **C1 — Worktree + branch + base scaffolding.** Worktree
  `worktrees/f-01-walking-skeleton/` on branch `feat/f-01-walking-skeleton`
  from `main`. Top-level `.gitignore`, `.dockerignore`, `README.md` stub,
  `LICENSES.md` with NAIP/3DEP/MS/Regrid/Mapbox/Nominatim placeholder
  sections, `ios/.gitkeep`, `shared/.gitkeep`, `ops/` dir. *(Verifies:
  "LICENSES.md exists", "repo structure matches ADR-008 — with documented
  layout deviation".)*
- [ ] **C2 — Sidecar (FastAPI) service + tests + Dockerfile.**
  `sidecar/app/main.py` (`GET /health`, `POST /skeleton`), `app/auth.py`
  shared-secret bearer check (per ADR-008), pytest for both,
  `sidecar/Dockerfile` (Python 3.12 slim + uvicorn). Standalone test passes.
- [ ] **C3 — Rails app generated at repo root + Dockerfile + Gemfile.**
  `rails new . --database=postgresql --skip-jbuilder --skip-action-mailbox
  --skip-action-text --css=tailwind` at repo root. Add gems `aws-sdk-s3`,
  `rspec-rails`, `factory_bot_rails`, `dotenv-rails`. Configure generators
  for uuid primary keys. Use Rails-8-default Dockerfile.
- [ ] **C4 — Postgres + PostGIS + SkeletonPing model (via generators).**
  `bin/rails g migration EnablePostgis` (edit to `enable_extension "postgis"`),
  `bin/rails g model SkeletonPing job_id:string rails_sent_at:datetime
  sidecar_received_at:datetime rails_received_at:datetime rtt_ms:integer
  sidecar_payload:jsonb`, `bin/rails db:create db:migrate`. *(Verifies: AC
  "Postgres runs with PostGIS extension enabled".)*
- [ ] **C5 — SidecarClient + /skeleton endpoint + request spec (real IPC).**
  `bin/rails g controller Skeleton show`, `app/services/sidecar_client.rb`
  (`Net::HTTP` + bearer), `SkeletonController#show` round-trips + persists.
  Request spec boots the **real** sidecar process (subprocess or docker
  compose service) — no mocks, per feature spec. *(Verifies: AC "/skeleton
  triggers Rails → sidecar → Postgres round-trip with persisted row".)*
- [ ] **C6 — SpacesHealth + /health endpoint + request spec.**
  `bin/rails g controller Health show`, `app/services/spaces_health.rb`
  (write+read+delete marker on all 4 buckets), `HealthController#show`
  composes full payload (rails_version, git_sha, time, postgres ok +
  postgis_version, spaces results). Returns 503 if any component fails.
  Request spec stubs Spaces. *(Verifies: ACs "/health returns 200 with
  identifying JSON" + "Spaces connectivity test".)*
- [ ] **C7 — Local docker-compose stack works end-to-end.**
  `ops/compose.yaml` (rails + sidecar + postgres on shared network).
  `docker compose up --build` → `curl localhost:3000/health` and `/skeleton`
  both return expected JSON. *(Verifies: full stack works before touching
  the droplet.)*
- [ ] **C8 — Kamal config (`ops/deploy.yml`) + secrets template + ops/README.md.**
  Full deploy.yml (build-on-droplet, server `gauntlet`, accessories postgres
  + sidecar, healthcheck, proxy disabled). `.kamal/secrets` template
  documented; real secrets gitignored. `ops/README.md` runbook. No deploy
  yet. *(Verifies: infra config exists and is reviewable.)*
- [ ] **C9 — Live droplet: DNS + Caddy fragment + Kamal secrets + first deploy.**
  Confirm `rooftrace.biograph.dev` DNS A-record points to the droplet;
  install `ops/rooftrace.caddyfile` into `/etc/caddy/conf.d/`; `caddy
  validate` then `caddy reload`; populate `.kamal/secrets` with real values;
  `kamal setup` then `kamal deploy`. Verify `kamal app containers` shows
  rails+sidecar+postgres healthy. *(Verifies: AC "`kamal deploy` succeeds
  with zero downtime".)*
- [ ] **C10 — Live smoke (`ops/smoke.sh`) + restart persistence test.**
  smoke.sh curls live `/health` and `/skeleton`, asserts 200 + JSON shape.
  Then `kamal app restart`, re-curl, and verify previous row id still
  readable via `kamal app exec`. *(Verifies: ACs "https://...biograph.dev
  endpoints return 200", "container restart preserves Postgres data".)*
- [ ] **C11 — CI workflow file (`.gitlab-ci.yml`).** Runs RSpec + sidecar
  pytest against a compose-up stack. If GitLab runner not yet enabled,
  mark "runner enablement deferred to user."
- [ ] **C12 — Quote live evidence into this section.** Actual smoke.sh
  output, actual live `/health` JSON, restart-then-readback evidence —
  copy-pasted here before opening the MR.

### Deviations from spec / ADRs

- **Repo layout** — diverges from ADR-008's `rails/`-subdir layout. Rails is
  at repo root. Reason: user preference for Rails-at-root ergonomics
  (standard `bin/rails`, `Gemfile`, IDE detection without `cd rails/`).
  Propagation: amend ADR-008 in Step 6.5 retro.

### Decisions log

*(Populated as chunks complete.)*
