# ADR-009: Persist to Postgres + PostGIS running as a sibling container on the same droplet

**Status:** Accepted · **Date:** 2026-05-27 · **Stretch:** no
**Supersedes:** none · **Superseded by:** none

## Context

The system needs to persist:

- **Application data** — jobs, addresses, users, share-link tokens, audit
  log.
- **Geospatial data** — building polygons, parcel polygons, roof facets
  (geometry-typed columns), per-job ARKit session metadata.
- **Cached external lookups** — geocode results, parcel polygons from
  Regrid (ADR-004), MS Building Footprints by H3 cell, WESM coverage
  index.
- **Pipeline outputs** — measurement results, feature detections,
  computed JSON exports.

PostGIS is non-negotiable for the geospatial slice: ADR-003 and ADR-004
already commit to it (`ST_Area` on `geography` for accurate planimetric
area, `ST_Intersects` for polygon-against-parcel filtering, spatial
indexing on the WESM table). Postgres is non-negotiable for the rest;
the Rails 8 default + ecosystem maturity decide it without contest.

The hosting question is **where** Postgres runs. CompanyCam runs on
AWS at scale (COMPANY.md); this take-home runs on a DigitalOcean
droplet (per Round 4 user input), deployed with Kamal. That makes the
real choice between:

- Managed Postgres (DO Managed Database, Supabase, Neon) reachable from
  the droplet over the public network.
- A sibling **Postgres container on the same droplet**, deployed
  alongside the Rails and sidecar containers via the same Kamal config.

## Options considered

**A. Postgres container on the same droplet, deployed via Kamal.**
Single host, single deploy, one network namespace; the Rails and
sidecar containers reach Postgres at `postgres:5432` over the Docker
network. Data volume mounted on the droplet's local disk; snapshots
via DO droplet snapshots or `pg_dump` cron.
*Tradeoff:* simplest deploy + lowest latency + cleanest local-dev
parity (same `compose.yaml` works locally). One host's disk failure
kills the data; no managed backups out of the box. Acceptable for a
demo and a v1 pilot; not the answer at CompanyCam-scale.

**B. DigitalOcean Managed Postgres** (their managed-DB service) with
PostGIS extension enabled, droplet talks to it over the DO private
network.
*Tradeoff:* automated backups, point-in-time recovery, no ops burden;
extra cost ($15+/mo) and a separate provisioning step outside Kamal.

**C. Supabase / Neon / external managed Postgres.** Same shape as (B)
with potentially better dashboards / branching.
*Tradeoff:* extra service to wire up; data leaves the droplet's
network. Adds a vendor surface that doesn't earn its keep for a 4-
day demo on a single droplet.

**D. AWS RDS Postgres + PostGIS.** Stack-mirror to CompanyCam.
*Tradeoff:* introduces AWS into an otherwise pure-DO deploy; doubles
the infra story for the demo without making the demo any better. The
stack-mirror is *symbolic* not *load-bearing* in v1.

## Decision

**A — Postgres + PostGIS in a sibling container on the same droplet,
deployed via Kamal alongside Rails and the Python sidecar.** Data
volume on the droplet's local disk. Daily `pg_dump` to the DigitalOcean
Space (ADR-010) for offsite backup.

## Rationale

For v1 on a single droplet, the simplest deploy that satisfies the data
requirements is the right one. Running Postgres next to Rails on the
same host eliminates: an extra network hop, an extra vendor account, an
extra deploy step, an extra failure surface, an extra IAM mental model.
Kamal handles it natively as one more service in the compose file;
local dev and prod look structurally identical.

This is also the answer that respects the project's *scope honestly*:
the take-home is graded on the architecture's clarity and the
measurement quality, not on whether it has multi-AZ failover. Spending
budget on a managed DB to defend an answer no one is asking is the
wrong trade.

The CTO-defense framing is: *"On the droplet for the demo / v1 pilot,
because it's the simplest thing that works and Kamal makes it one
container. The migration path to DO Managed Postgres (then RDS at
CompanyCam scale) is a `database.yml` change plus `pg_dump | pg_restore`
— I've drawn the seam exactly there."* Naming the migration path is
what makes "simplest now" defensible.

## Tradeoffs & risks

- **Single point of failure.** If the droplet dies, the DB dies with
  it. Mitigation: daily `pg_dump` to the DO Space (ADR-010); document
  the restore procedure; for v1 demo this risk is accepted.
- **Local disk performance / size limits** on smaller droplets.
  Mitigation: provision the droplet on a tier with adequate SSD
  (DO's `s-4vcpu-8gb` or larger); attach a DO Volume if data grows.
- **PostGIS install in container** needs the right base image
  (`postgis/postgis:16-3.4` or equivalent — not the default
  `postgres` image). Mitigation: pin the image tag in the compose
  file; verified PostGIS at build time.
- **Backups are manual.** Mitigation: `pg_dump | gzip | s3cmd put`
  cron on the droplet writing to the DO Space nightly; retain 7
  daily + 4 weekly snapshots.
- **CompanyCam-stack-fit (RDS) is symbolic, not load-bearing, at v1.**
  Mitigation: call out the migration path explicitly in the writeup;
  this is a virtue (honest scoping), not a weakness, in front of a
  CTO worried about scope creep.

## Consequences for the build

- **One `compose.yaml`** containing `rails`, `sidecar`, `postgres`
  services on the same droplet, deployed via Kamal.
- **`postgres` service image:** `postgis/postgis:17-3.5` *(amended F-01;
  was 16-3.4 — bumped because psql 18 emits `transaction_timeout` in the
  dumped `db/structure.sql`, which a PG16 server rejects on load. PostGIS
  3.5 keeps the 3.4-era API surface; `postgis_version()` reports 3.5).*
- **Volume:** Postgres data on a host bind-mount at the droplet's local
  disk path (`/opt/rooftrace/postgres`), declared in the compose file so a
  redeploy/container-replacement never loses data. *(F-01 verified the row
  survives a `docker restart` of the web container.)*
- **PostGIS enabled** via a Rails migration: `enable_extension "postgis"`.
  **Schema dumps use SQL format** (`config.active_record.schema_format = :sql`,
  i.e. `db/structure.sql`) *(established F-01)* because PostGIS's internal
  tables (`spatial_ref_sys`, `tiger.*`, `topology.*`, geometry-typed columns)
  break Rails' Ruby schema dumper. Binding for all future migrations.
  Schema includes geometry-typed columns for all polygon storage; SRID 4326
  for storage, project on read for area math.
- **Backups:** Kamal accessory or a separate cron container runs
  `pg_dump` nightly, gzips, uploads to the DO Space at
  `s3://rooftrace-backups/postgres/`. 7-day rolling retention by
  filename convention.
- **Connection:** Rails uses `pg` adapter; Python sidecar (ADR-008)
  does **not** connect to Postgres directly — all reads/writes go
  through Rails per the boundary in ADR-008.
- **Migration path (documented in writeup, not built):** for v2,
  swap `compose.yaml`'s `postgres` service for a DO Managed Postgres
  connection string in `database.yml`; for CompanyCam-scale, the
  same swap to RDS.
