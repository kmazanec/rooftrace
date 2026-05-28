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
- [x] **C2 — Sidecar (FastAPI) service + tests + Dockerfile.**
  `sidecar/app/main.py` (`GET /health`, `POST /skeleton`), `app/auth.py`
  shared-secret bearer check (per ADR-008), pytest for both,
  `sidecar/Dockerfile` (Python 3.12 slim + uvicorn). Standalone test passes.

  **Verification (live uvicorn):**
  ```
  $ curl -sS http://127.0.0.1:8765/health
  {"status":"ok","sidecar_version":"0.1.0"}

  $ curl -sS -X POST .../skeleton (no auth)   → HTTP 401
  {"detail":"Missing or malformed Authorization header"}

  $ curl -sS -X POST .../skeleton -H "Authorization: Bearer test-shared-secret" -d {...}
  {"job_id":"abc","received_at":"2026-05-28T02:15:22.572846Z",
   "echo_payload":"hello from sidecar","sidecar_version":"0.1.0"}
  ```
  pytest: 5/5 passed (health, happy-path, missing-bearer, wrong-bearer,
  malformed-Authorization-header).
- [x] **C3 — Rails app generated at repo root + Dockerfile + Gemfile.**
  `rails new . --database=postgresql --skip-jbuilder --skip-action-mailbox
  --skip-action-text --css=tailwind` at repo root. Add gems `aws-sdk-s3`,
  `rspec-rails`, `factory_bot_rails`, `dotenv-rails`. Configure generators
  for uuid primary keys. Use Rails-8-default Dockerfile.
- [x] **C4 — Postgres + PostGIS + SkeletonPing model (via generators).**
  `bin/rails g migration EnablePostgis` (edit to `enable_extension "postgis"`),
  `bin/rails g model SkeletonPing job_id:string rails_sent_at:datetime
  sidecar_received_at:datetime rails_received_at:datetime rtt_ms:integer
  sidecar_payload:jsonb`, `bin/rails db:create db:migrate`. *(Verifies: AC
  "Postgres runs with PostGIS extension enabled".)*
- [x] **C5 — SidecarClient + /skeleton endpoint + request spec (real IPC).**
  `bin/rails g controller Skeleton show`, `app/services/sidecar_client.rb`
  (`Net::HTTP` + bearer), `SkeletonController#show` round-trips + persists.
  Request spec boots the **real** sidecar process (subprocess or docker
  compose service) — no mocks, per feature spec. *(Verifies: AC "/skeleton
  triggers Rails → sidecar → Postgres round-trip with persisted row".)*
- [x] **C6 — SpacesHealth + /health endpoint + request spec.**
  `bin/rails g controller Health show`, `app/services/spaces_health.rb`
  (write+read+delete marker on all 4 buckets), `HealthController#show`
  composes full payload (rails_version, git_sha, time, postgres ok +
  postgis_version, spaces results). Returns 503 if any component fails.
  Request spec stubs Spaces. *(Verifies: ACs "/health returns 200 with
  identifying JSON" + "Spaces connectivity test".)*
- [x] **C7 — Local docker-compose stack works end-to-end.**
  `ops/compose.yaml` (rails + sidecar + postgres on shared network).
  `docker compose up --build` → `curl localhost:3000/health` and `/skeleton`
  both return expected JSON. *(Verifies: full stack works before touching
  the droplet.)*

  **Verification (production-mode images via compose):**
  ```
  $ curl http://localhost:3000/health
  {"status":"ok","rails_version":"8.1.3","git_sha":"local-dev",
   "time":"2026-05-28T02:36:57Z",
   "postgres":{"ok":true,"postgis_version":"3.5 USE_GEOS=1 USE_PROJ=1 USE_STATS=1"},
   "spaces":{"uploads":"skipped","cache":"skipped","artifacts":"skipped","backups":"skipped"}}
  HTTP 200

  $ curl http://localhost:3000/skeleton
  {"ping_id":"c6b49f90-...","job_id":"9102c129-...",
   "sidecar_response":{"echo_payload":"hello from sidecar","sidecar_version":"0.1.0"},
   "db_row":{"id":"c6b49f90-...","created_at":"2026-05-28T02:36:57Z"}}
  HTTP 200

  $ psql -c "SELECT id, job_id, rtt_ms, sidecar_payload->>'echo_payload' FROM skeleton_pings;"
   c6b49f90-... | 9102c129-... | 8 | hello from sidecar   (1 row)
  ```
  The persisted row id matches the API response; rtt_ms=8 confirms a real
  cross-container HTTP round-trip over the compose network.
- [x] **C8 — Deploy config + secrets template + ops/README.md.**
  Active path: `ops/compose.prod.yaml` (rooftrace-web/postgres/sidecar
  joining the shared `openemr_default` network), `ops/rooftrace.caddyfile`
  (Caddy → rooftrace-web:80, matching sibling convention),
  `ops/.env.example` (secrets template; `ops/.env.production` gitignored),
  `ops/smoke.sh`, `ops/README.md` runbook. `ops/deploy.yml` (Kamal) kept as
  documented future/multi-host state, marked not-active. Prod compose
  validated with `docker compose config`. No live deploy yet.
  *(Verifies: infra config exists and is reviewable.)*
- [ ] **C9 — Live droplet: DNS + Caddy fragment + secrets + first deploy
  (via docker-compose, NOT Kamal — see deviation below).**
  Confirm `rooftrace.biograph.dev` DNS A-record points to the droplet;
  copy the repo to the droplet; populate `ops/.env.production` with real
  secrets; `docker compose -f ops/compose.prod.yaml up -d --build` on the
  droplet; install `ops/rooftrace.caddyfile` into `/etc/caddy/conf.d/`;
  reload the Caddy container. Verify all three rooftrace containers
  healthy. *(Verifies: AC "deploy succeeds; rolls on the droplet".)*
- [ ] **C10 — Live smoke (`ops/smoke.sh`) + restart persistence test.**
  smoke.sh curls live `/health` and `/skeleton`, asserts 200 + JSON shape.
  Then `docker compose restart rails`, re-curl, and verify previous row id
  still readable. *(Verifies: ACs "https://...biograph.dev endpoints
  return 200", "container restart preserves Postgres data".)*
- [x] **C11 — CI workflow file (`.gitlab-ci.yml`).** Two jobs: `sidecar_test`
  (pytest) and `rails_test` (RSpec incl. the real-IPC request spec against a
  postgis service + uvicorn-subprocess sidecar). Removed the Rails-generated
  GitHub Actions workflow (project is on GitLab). **GitLab runner enablement
  deferred to the user** — the pipeline file is correct but won't execute
  until a runner is attached to the project. Locally verified the exact
  commands CI runs: brakeman (0 warnings), rubocop (0 offenses), full RSpec
  (7/7) from a clean `db:test:prepare`.
- [ ] **C12 — Quote live evidence into this section.** Actual smoke.sh
  output, actual live `/health` JSON, restart-then-readback evidence —
  copy-pasted here before opening the MR.

### Deviations from spec / ADRs

- **Repo layout** — diverges from ADR-008's `rails/`-subdir layout. Rails is
  at repo root. Reason: user preference for Rails-at-root ergonomics
  (standard `bin/rails`, `Gemfile`, IDE detection without `cd rails/`).
  Propagation: amend ADR-008 in Step 6.5 retro.

- **Deploy via docker-compose, not Kamal** — diverges from ADR-011 (which
  mandates Kamal). Discovered during C8 that the droplet's reality makes
  Kamal the wrong tool for v1:
  1. **The host Caddy is a *container*** (`openemr-caddy-1`) on a shared
     `openemr_default` Docker network. Sibling apps (cats, context-shield)
     join that network and Caddy reverse-proxies to them *by container
     name* (`reverse_proxy cats-api:8400`), not via `localhost:port`.
  2. **Kamal 2 always requires a registry**, even with `builder.remote`
     (on-host build): it pushes the built image to a registry and pulls
     it back for the run step. A registry-less single-host deploy needs a
     local-registry workaround — friction for zero benefit here.
  3. **Kamal's default proxy binds host 80/443**, which the existing Caddy
     container already owns. Disabling it (`proxy: false`) is possible but
     then Kamal's network/naming model fights the shared-Caddy topology.
  4. **The siblings already deploy via plain docker-compose** joining
     `openemr_default`. That is the droplet's *established convention*.

  Decision (user-approved): deploy RoofTrace via docker-compose joining
  `openemr_default`, exactly like its neighbors. `ops/compose.prod.yaml`
  is the production compose; `ops/rooftrace.caddyfile` routes Caddy →
  `rooftrace-web:80`. `ops/deploy.yml` (Kamal) is kept in the repo as
  documentation of the *intended future/multi-host* state, clearly marked
  not-yet-active. **Propagation: amend ADR-011 in Step 6.5 retro** to
  record compose-for-v1 with Kamal as the documented scale-out path.

### Decisions log

- **C2** — sidecar bearer uses `hmac.compare_digest` (constant-time) and
  eager-fails if `SIDECAR_SHARED_SECRET` is unset, so a misconfigured
  deploy can't run permissively.
- **C4** — `schema_format = :sql` (db/structure.sql) because PostGIS
  internal tables break the Ruby schema dumper. Binding for all future
  migrations.
- **C4** — pinned local/prod Postgres to `postgis/postgis:17-3.5` (not
  16-3.4 as ADR-009 suggested) because psql 18 emits `transaction_timeout`
  in structure.sql, which PG16 rejects on load. PostGIS API surface is
  unchanged (`postgis_version()` reports 3.5). Minor — noted for ADR-009.
- **C6** — `/health` returns 503 (not 200) on any component failure so the
  deploy/health gate fast-fails on credential drift.
- **C6** — dotenv-rails autorestore in the test env clears env vars the
  test framework didn't set between request specs; spec/support/real_sidecar.rb
  re-establishes the sidecar contract in `before(:each)`.
