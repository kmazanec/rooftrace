# ADR-008: Rails monolith for the application backend with a Python sidecar for geospatial processing

**Status:** Accepted · **Date:** 2026-05-27 · **Stretch:** no
**Supersedes:** none · **Superseded by:** none

## Context

The backend has two distinct workloads that pull in opposite directions on
language choice:

- **Application backend** — API endpoints, auth, file uploads from the iOS
  app (ADR-007), job orchestration, VLM calls (ADR-006), persistence
  (ADR-009 forthcoming), PDF rendering, public share links. This is
  classic Rails-shaped work. CompanyCam's stack is Ruby on Rails
  (COMPANY.md); their preferred LLM client is **RubyLLM**; their AI-
  features architecture explicitly is "call provider APIs from Rails."
- **Geospatial processing** — PDAL pipelines (ADR-003), Shapely/GeoPandas
  polygon arithmetic (ADR-004), pyproj CRS reprojection, NumPy point-cloud
  manipulation, RANSAC plane fitting (ADR-005), ICP alignment of ARKit
  meshes to public LiDAR (ADR-007), SAM2 inference (ADR-005). **Every
  one of these libraries is Python-native;** the Ruby equivalents are
  thin (`pdal-ruby`) or non-existent.

A pure-Rails backend forces us to either reimplement PDAL filters and
RANSAC by hand in 4 days (wrong fight) or shell out via subprocess to
Python anyway (uglier than just running a proper Python service).

A pure-Python backend gives up the strongest cultural-fit signal we have
with CompanyCam — and Keith's #1 language is Ruby (partner brief), so the
Rails productivity is real, not hypothetical.

The honest answer is **both, with a clean boundary at the
geospatial-pipeline API.**

## Options considered

**A. Rails monolith + Python sidecar at the geospatial-pipeline boundary.**
Rails owns: HTTP API, auth, ActiveStorage for uploads, Solid Queue for
async orchestration, RubyLLM for VLM calls (ADR-006), report rendering,
share links. Python sidecar owns: PDAL pipelines, polygon arithmetic,
SAM2 inference, RANSAC, ICP, anything geometric. Rails enqueues a
geometry job; a worker shells out to the Python service (HTTP over the
Docker network) and parses the result.
*Tradeoff:* two languages, two processes, one IPC boundary. The IPC
boundary is *minimal* — Rails sends a job spec JSON, Python returns a
result JSON — but it's real. Buys maximum stack-fit + best-of-breed
libraries.

**B. Pure Python (FastAPI + RQ/Celery).** One language; geospatial libs
are first-class.
*Tradeoff:* faster to build if Rails 8 isn't muscle-memory, but
under-uses Keith's Rails strength and gives up the CompanyCam
stack-fit story. Defensible as "I chose the language the libraries are
in" but weaker than (A) at this candidate's particular interview.

**C. Pure Rails (no Python).** Maximum mirror; reimplement PDAL +
RANSAC in Ruby.
*Tradeoff:* the wrong fight in 4 days. The geospatial Ruby ecosystem is
not there.

**D. Rails + Python in the same OS process via embedded Python (e.g.,
`pycall`).** Cute, but adds runtime fragility and unusual deploy story;
no real benefit over a sidecar service that's already a Docker container
on the same host.

## Decision

**A — Rails monolith + Python sidecar.** Specifically:

- **Rails 8** for the application backend. Solid Queue for jobs, Active-
  Storage for uploads (S3-compatible backend per ADR-010), ActionCable
  for the in-browser job-status updates, RubyLLM for VLM detection
  (ADR-006).
- **Python sidecar** runs FastAPI as a small service exposing one main
  endpoint: `POST /pipeline/run` accepting `{job_id, address,
  building_polygon, parcel_polygon, ios_session_id?}` and returning
  `{measurement, facets, source, confidence, warnings}`. Internally it
  runs the geospatial pipeline (geocode-time inputs were resolved Rails-
  side; this service does PDAL → SAM2 → plane fit → ICP → outputs).
- **Communication:** HTTP/JSON over the internal Docker network between
  the Rails and Python containers, both running on the same DigitalOcean
  droplet via Kamal (ADR-011). No queueing on the Python side — the
  Solid Queue Rails worker blocks on the synchronous Python call inside
  its own job. (A single droplet, one tenant; no need for distributed
  job semantics yet.)

## Rationale

This split puts each language exactly where its libraries and ecosystem
are strongest, and it draws the boundary at a **natural interface**: the
geometric pipeline takes a job spec in and emits a measurement out. That
boundary is the same one a CTO at CompanyCam would draw on a whiteboard
in 30 seconds — Rails for the world they know and ship, Python for the
specialized numerics no Ruby gem covers credibly.

It also matches what CompanyCam itself almost certainly does internally
for their CV work (their open ML-Engineer-CV role implies a Python tier
exists alongside the Rails monolith). Saying "I built it the way you'd
build it" is the highest-strength defense of an architectural choice.

The IPC overhead is negligible compared to the pipeline's actual work:
a typical job is dominated by network fetches (NAIP tile, COPC chunk)
and GPU inference; the HTTP round-trip between Rails and the Python
container on the same host is sub-ms.

RubyLLM specifically gets to handle the VLM calls (ADR-006), which is
the highest-visibility piece of "the AI part" — keeping that in Rails
means the CTO sees us using their preferred tool for the feature they
just funded.

## Tradeoffs & risks

- **Two languages = two dependency manifests, two test setups, two
  deploy pipelines.** Mitigation: Kamal (ADR-011) handles both as
  Docker services on the same droplet; one `compose` file, one deploy
  command.
- **Schema discipline at the IPC boundary.** Mitigation: define the
  request/response as JSON Schema in `shared/pipeline_schema.json`;
  generate Ruby and Python types from it. v1 can hand-keep them in
  sync with tests; v2 codegen.
- **Debugging across the boundary.** A Rails-side job that fails into
  the sidecar requires looking at two log streams. Mitigation: include
  the Rails `job_id` in every Python log line; correlation by id.
- **Keith may want to default to Python for new geospatial code that
  could reasonably live in Rails.** Mitigation: rule of thumb — if the
  code needs PDAL, GDAL, Shapely, NumPy, or PyTorch, it goes in the
  sidecar; otherwise it goes in Rails. Only the geospatial pipeline
  itself is in the sidecar; persistence/orchestration/HTTP/auth are
  Rails.
- **The sidecar is a single point of failure during a job.** Mitigation:
  acceptable for v1 (single droplet, demo scale). Rails retries the
  job on Python-side error; surface persistent failures to the user
  with a "we couldn't measure this address — here's why" message.

## Consequences for the build

- **Repo layout** *(amended F-01: Rails lives at the repo ROOT, not in a
  `rails/` subdir; the other components are siblings of the Rails tree)*:
  ```
  ./            — Rails 8 application AT REPO ROOT (app/, config/, db/,
                  Gemfile, bin/, Dockerfile, spec/, ...)
  sidecar/      — FastAPI Python service (PDAL, SAM2, ICP, etc.)
  ios/          — Xcode project (ADR-007)
  shared/       — pipeline_schema.json + brand assets
  ops/          — deploy config, Dockerfiles, compose files, Caddy fragment
  docs/         — this folder
  ```
  Rationale for root (not `rails/`): standard Rails tooling (`bin/rails`,
  `bundle`, IDE detection) works without a `cd rails/` prefix; the non-Rails
  siblings coexist fine (the autoloader is told to ignore them in
  `config/application.rb`).
- **The pipeline contract** (`shared/pipeline_schema.json`) is the
  single source of truth for request and response shapes between
  Rails and the sidecar. *(Amended F-02: published as v0.1.0, JSON Schema
  draft 2020-12, validated on both sides — `app/services/pipeline_schema.rb`
  via `json_schemer`, and `sidecar/contracts/pipeline.py` via Pydantic —
  against a shared fixture corpus in `spec/fixtures/pipeline/`. **Wire-format
  rule:** absent optional nested-object fields are OMITTED from the JSON, never
  sent as `null` (the strict schema declares them non-nullable; only scalar
  fields the schema explicitly types nullable may be `null`). The sidecar
  enforces this with `response_model_exclude_none`. The sidecar rejects a
  request whose `pipelineSchemaVersion` MAJOR differs from its own with 409;
  see `shared/PIPELINE_SCHEMA_CHANGELOG.md`.)*
- **Rails-side job code** (`app/jobs/geometry_job.rb`) calls
  `Sidecar::Pipeline.run(spec)`; the client wraps `Net::HTTP` against
  the sidecar URL (env-configurable).
- **No direct DB access from the sidecar.** All Postgres reads/writes
  go through Rails; the sidecar is stateless. Inputs come on the
  request; outputs come on the response.
- **VLM calls (ADR-006) stay in Rails / RubyLLM**, NOT in the sidecar.
  The Python sidecar is "geospatial numerics only"; the AI-feature
  call is application-level and cultural-fit-aligned in Rails.
- **Auth between Rails and the sidecar** is a shared secret env var
  validated on every sidecar request; the sidecar is not internet-
  exposed (Docker network only).
