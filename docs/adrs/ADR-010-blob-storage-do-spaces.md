# ADR-010: Use DigitalOcean Spaces (S3-compatible) for blob storage

**Status:** Accepted · **Date:** 2026-05-27 · **Stretch:** no
**Supersedes:** none · **Superseded by:** none

## Context

The system has multiple blob-shaped workloads:

- **NAIP tile cache** — fetched from `s3://naip-source/` (AWS Open
  Data, anonymous reads) once per region, cached for re-use within and
  across jobs to avoid re-fetching.
- **USGS 3DEP COPC chunks cache** — same shape: streamed once, reused.
- **iOS upload bundles** (ADR-007) — multipart POSTs containing
  photos, per-frame depth maps, ARKit world mesh, GPS/IMU. Tens of MB
  per session.
- **Generated artifacts** — PDF reports, JSON exports, 3D model
  glTFs for the web viewer.
- **Postgres backups** (ADR-009) — nightly `pg_dump` gzip dumps.

Storage choices:

| Option | S3-compatible? | Egress cost | Co-located with droplet | Setup overhead |
|---|---|---|---|---|
| **DigitalOcean Spaces** | Yes | Cheap, generous bundle | Same region as droplet (free intra-region) | Same provider as the droplet → one bill, one console |
| **AWS S3** | Native | Per-GB egress | Cross-cloud → egress costs and latency | Separate AWS account + IAM |
| **Cloudflare R2** | Yes | **Zero egress** | Independent | Separate account; great for public-shared PDFs |
| **MinIO on-droplet** | Yes | None (on disk) | Same droplet | Adds a service; competes with Postgres for disk |

The user has selected **DigitalOcean Spaces** as the storage answer.
That decision is correct on multiple axes: same provider as the
droplet (one bill, one console, one auth), S3-compatible (every
relevant library — AWS SDK, ActiveStorage's `aws` adapter, `aws-sdk-s3`
for Python — works against it unchanged), free intra-region transfer
to/from the droplet, and pricing that bundles storage + egress in one
predictable line item.

## Options considered

**A. DO Spaces for everything.** One bucket, one IAM, one S3-compatible
endpoint. Both Rails (ActiveStorage `:amazon` adapter pointed at the
DO Spaces endpoint) and the Python sidecar (`boto3` with custom
endpoint) write to it.
*Tradeoff:* not as battle-tested for huge scale as AWS S3, but for
v1 demo + early-pilot volumes (single-digit GB), the difference is
academic.

**B. Split: DO Spaces for app uploads, AWS S3 for NAIP cache.**
Justified only if cross-bucket transfer cost were a concern; for
v1 it isn't.
*Tradeoff:* fragments storage for no win.

**C. MinIO container on-droplet.** Self-hosted, no third-party
billing.
*Tradeoff:* competes with Postgres for the droplet's local disk;
adds a service; loses the offsite-backup property that makes Spaces
useful for `pg_dump` archives (the whole point of offsite backup is
that it's *not* on the droplet).

**D. Cloudflare R2.** Zero egress is genuinely attractive for
publicly-shared report PDFs.
*Tradeoff:* extra vendor surface; the saving doesn't matter at v1
volume; can be added later as a CDN-tier optimization if
publicly-shared reports become a meaningful cost line.

## Decision

**A — DigitalOcean Spaces for all blob storage**, organized into a
small set of well-named buckets:

- `rooftrace-uploads/` — iOS capture sessions (multipart bundles,
  extracted photos, depth maps, world mesh files).
- `rooftrace-cache/` — NAIP tiles, COPC chunks, fetched parcel/footprint
  responses.
- `rooftrace-artifacts/` — generated PDF reports, JSON exports, 3D
  model glTFs.
- `rooftrace-backups/` — nightly Postgres dumps from ADR-009.

ActiveStorage is configured to use the Spaces endpoint as its
S3-compatible service for application-level uploads. The Python
sidecar uses `boto3` with the same endpoint when it needs to read
cached tiles or write a generated artifact.

## Rationale

Same-provider co-location is the right answer when (a) you're already
on DO for compute, (b) the storage is S3-compatible, and (c) intra-
region transfer is free. The marginal cost of adding AWS S3 or
Cloudflare R2 is one more account, one more credential store, one
more place for the demo to break — and the marginal *benefit* is
near-zero at v1 volumes.

S3-compatibility means we get the full ecosystem (AWS SDK, ActiveStorage,
boto3) without writing custom client code. If we ever migrate to AWS
S3 (the obvious move if/when CompanyCam adopts this), it's an endpoint
+ credentials swap, not a refactor.

The four-bucket split exists so that **cache eviction, backup
retention, and public-share rules differ per bucket** without coding
those rules into application logic. Cache can be aggressively expired;
backups have time-based retention; artifacts may be served via public
read URLs for share links; uploads stay private with signed URLs.

## Tradeoffs & risks

- **DO Spaces is less battle-tested at huge scale** than S3.
  Mitigation: not a v1 concern; migration to S3 is an endpoint swap.
- **Per-bucket public-read configuration** must be explicit; an
  accidentally-public `rooftrace-uploads` bucket would leak
  homeowner property data. Mitigation: bucket creation in
  Terraform / DO console with explicit ACLs; audit before deploy;
  signed-URL pattern for all upload reads from clients.
- **Egress is bundled but not infinite.** Mitigation: monitor
  monthly egress; cache-Control headers on artifact files for CDN
  efficiency if/when traffic warrants.
- **DO Spaces lacks some S3 features** (e.g., S3 Object Lambda,
  some advanced lifecycle rules). Mitigation: none needed at v1.
- **Credential management.** Spaces access keys live in env vars
  consumed by Rails and the sidecar via Kamal's secret support.

## Consequences for the build

- **`STORAGE_ENDPOINT`**, **`STORAGE_REGION`**,
  **`STORAGE_ACCESS_KEY`**, **`STORAGE_SECRET_KEY`** env vars
  consumed by both services. Spaces credentials provisioned out of
  band; injected via Kamal.
- **Rails `config/storage.yml`** defines `:spaces` service using the
  `aws` adapter with the DO endpoint; **ActiveStorage** uses it for
  all uploads.
- **Python sidecar** uses `boto3` with `endpoint_url=STORAGE_ENDPOINT`
  for cache reads/writes and artifact writes.
- **Public-share artifacts** (PDFs, JSON exports linked from a
  share URL) live in `rooftrace-artifacts/public/<share_token>/...`
  with bucket-policy `public-read` on that prefix only.
- **Private uploads** (iOS capture bundles) live in
  `rooftrace-uploads/<job_id>/...` and are read via 15-min signed
  URLs.
- **Cache TTL:** NAIP tiles cached 30 days; COPC chunks cached 30
  days; parcel/footprint responses cached 7 days. Implementation:
  filename includes a content-hash; ad-hoc cron deletes objects
  older than the TTL.
- **Backups:** ADR-009's nightly `pg_dump` writes to
  `s3://rooftrace-backups/postgres/<YYYY-MM-DD>.sql.gz`; 7 daily +
  4 weekly retention via cron.
- **Migration path to AWS S3** (documented, not built): change
  `STORAGE_ENDPOINT`/`STORAGE_REGION` env vars; re-create buckets;
  one-time `aws s3 sync` to migrate.
