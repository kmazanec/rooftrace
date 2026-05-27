# ADR-011: Deploy as Docker containers to a DigitalOcean droplet via Kamal

**Status:** Accepted · **Date:** 2026-05-27 · **Stretch:** no
**Supersedes:** none · **Superseded by:** none

## Context

The system has at least three long-running services (Rails, Python
sidecar, Postgres) plus a Solid Queue worker process. Hosting choices
for a 4-day take-home where the user already has a DigitalOcean
droplet in their workspace (per CLAUDE.md):

- A managed PaaS (Render, Fly, Railway, Heroku) — fast onboarding,
  hidden infra, less of a control story.
- A serverless platform (Vercel/Netlify for frontend + Fargate/Cloud Run
  for backend) — auto-scaling, opaque, complicates the multi-process
  Rails-and-sidecar story.
- A **single Linux VM running Docker, orchestrated with Kamal** —
  classic, transparent, the Rails-8-default deploy story DHH has been
  pushing.

The user has selected the droplet + Kamal path explicitly. Kamal is
the right deployment tool for it: it's the official Rails 8 deploy
companion, treats Docker containers on plain Linux hosts as the
primitive, handles zero-downtime restarts, manages secrets, and
expects exactly the multi-service shape we have.

## Options considered

**A. DigitalOcean droplet + Kamal + Docker Compose** (declared in
Kamal's accessories model). One host, three services, one deploy
command. Postgres data on the droplet's local disk.
*Tradeoff:* single-host = single point of failure; manual scaling.
Acceptable for v1.

**B. Render / Fly.io / Railway PaaS.** Lower ops burden; managed TLS,
metrics, scaling.
*Tradeoff:* hides the infra story; the multi-service Rails + Python +
Postgres shape doesn't map as cleanly; vendor lock-in. Loses the
"Kamal is the Rails-native answer" CTO-defense.

**C. DigitalOcean Kubernetes (DOKS).** Real orchestration; future-
scale-ready.
*Tradeoff:* massive over-engineering for v1; eats build time on
manifests; not Rails-shop-aligned.

**D. AWS ECS / Fargate.** Stack-mirror to CompanyCam.
*Tradeoff:* same shape as (C) in cost-of-complexity; AWS cold-start
is its own learning surface; loses simplicity of the user's existing
droplet.

## Decision

**A — DigitalOcean droplet + Kamal + Docker containers.** Specifically:

- One DigitalOcean droplet, provisioned at `s-4vcpu-8gb` or larger
  (sized for Postgres + Rails + Python sidecar working set).
- **Kamal 2** (or current stable) drives deploys. `config/deploy.yml`
  declares: the Rails app service, the Python sidecar accessory, the
  Postgres accessory (with PostGIS image per ADR-009), a Solid Queue
  worker process, and a Traefik proxy fronting Rails for TLS.
- **Caddy or Traefik** for TLS termination + reverse proxy. Kamal 2
  ships with Traefik by default; we use it.
- **Coexists with the other Gauntlet projects on the droplet**
  (CLAUDE.md notes the droplet already hosts several biograph.dev
  subdomains via Caddy). The subdomain `rooftrace.biograph.dev`
  routes to this stack via the existing Caddy proxy on the host.

## Rationale

This is the deployment model **CompanyCam's stack actively endorses
(DHH/Rails 8 ships Kamal as the default deploy story)** and the one
the user already has infrastructure for. Picking it costs us nothing
and earns multiple defense points:

- *Cultural fit:* Kamal is DHH-aligned, which COMPANY.md identifies
  as the cultural register CompanyCam respects.
- *Operational honesty:* "One droplet, three containers, Kamal deploy"
  is comprehensible to a CTO in 15 seconds and shippable in production
  for a real early-customer pilot — not just a demo facade.
- *Real-pilot ready:* unlike a PaaS demo, this can serve real traffic
  the day after the take-home is graded. The CTO knows that.

The "single point of failure" critique is the obvious one. The
counter-defense is **the same critique applies to a single AZ in
RDS or a single region in Render** at this scale; what matters is
having drawn the seam where the migration to HA happens. With Kamal,
that migration is a second droplet + a load balancer + a shared DB
(ADR-009 already names DO Managed Postgres as the migration target).

## Tradeoffs & risks

- **Single-host failure** kills the demo until manual recovery.
  Mitigation: droplet snapshots before each demo; Postgres `pg_dump`
  backed up offsite to the DO Space (ADR-010); recovery procedure
  documented.
- **Coexistence with other biograph.dev projects** means a noisy-
  neighbor risk on CPU/memory/disk. Mitigation: provision a
  generously-sized droplet; monitor; if RoofTrace becomes
  meaningfully loaded, split to its own droplet.
- **No auto-scaling.** Mitigation: a single droplet of the chosen
  size sustains demo and early-pilot traffic comfortably;
  documented scaling path is "Kamal + a second droplet + DO Load
  Balancer."
- **GPU work is off-host on Modal** (ADR-012). The droplet never
  touches GPU; this is by design.
- **Caddy + Traefik both?** The CLAUDE.md droplet already runs
  Caddy as the host-level proxy. Decision: Traefik runs *inside the
  Kamal stack* on a non-standard port (Kamal expects to own port
  80/443 on the host); the host-level Caddy proxies
  `rooftrace.biograph.dev` to that internal port. This keeps the
  per-project Kamal stacks isolated without disturbing the existing
  proxy setup. Alternative: skip Kamal's bundled Traefik and let
  host-level Caddy terminate TLS directly to the Rails container.
  Pick one when wiring up — both are acceptable.

## Consequences for the build

- **`ops/deploy.yml`** is the Kamal config: lists app + accessories,
  registry, env vars, secrets, health checks.
- **`ops/compose.yaml`** for local development matches the same
  service shape (Rails, sidecar, Postgres) so dev/prod parity is
  real, not aspirational.
- **Dockerfiles:**
  - `rails/Dockerfile` — Ruby 3.3 + Rails 8 + Solid Queue worker.
  - `sidecar/Dockerfile` — Python 3.12 + PDAL (via conda-forge) +
    SAM2 + FastAPI + uvicorn.
  - `postgres` uses the upstream `postgis/postgis:16-3.4` image.
- **Deploy command:** `kamal deploy` from the developer's machine
  builds, pushes to the configured registry (Docker Hub or DO
  Container Registry), and rolls the droplet.
- **Subdomain routing:** `rooftrace.biograph.dev` → host-level Caddy
  → Rails container's exposed port. TLS terminated at Caddy.
- **Secrets** (Mapbox token, RubyLLM provider keys, Modal token,
  Spaces credentials) live in 1Password / `.kamal/secrets`,
  injected into containers at deploy time.
- **Logs:** `kamal app logs` streams the Rails log; sidecar logs
  similarly. Aggregated logging is a v2 concern.
- **Documented migration path** (ADR scope: nothing built here):
  add a second droplet + DO Load Balancer + swap Postgres for DO
  Managed Postgres → multi-host Kamal deploy.
