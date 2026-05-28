# Feature: LiDAR ingest (USGS 3DEP via COPC + PDAL)

**ID:** F-06 · **Roadmap piece:** F-06 · **Status:** Built (pending batch MR) · 2026-05-28 · MR !7: https://labs.gauntletai.com/keithmazanec/rooftrace/-/merge_requests/7

## Build plan (checklist)

- [x] C1 — CRS helpers (`crs.py`): local-UTM-zone selection + pyproj reprojection.
- [x] C2 — WESM coverage index (`wesm.py`): injectable interface; fixture-JSON
  backend (tests/demo) + GeoPackage/GDAL backend (live `LIDAR_LIVE=1`).
- [x] C3 — Ingest core (`ingest.py`): 5-hop coverage→crop→class-6→UTM→cache;
  `PdalCropper` (conda-only, guarded) + injectable `Cropper` for tests.
- [x] C4 — Endpoint (`router.py`): `IngestLidarRequest`→`IngestLidarResponse`,
  bearer + version gate, 5xx-with-generic-detail on PDAL/S3 failure.
- [x] C5 — Tests: coverage hit/gap(<2s)/CRS(→32614)/class-6-only/cache-determinism/
  stale-warning/no-building-points + endpoint schema-validation (available+missing).

## Description

Streams the LiDAR point cloud for an address from the USGS 3DEP
collection (anonymous S3 reads), crops to the building polygon,
filters to ASPRS classification 6 (building), reprojects into the
appropriate local UTM zone, and returns a NumPy point array plus
work-unit metadata. **This is the longest single feature in the
pipeline track — the schedule-determining feature on the critical
path.**

Per [ADR-003](../adrs/ADR-003-lidar-source-usgs-3dep-copc.md), the
feature uses COPC (Cloud-Optimized Point Cloud) streamed via PDAL,
indexed by the WESM (Work Unit Extent Spatial Metadata) GeoPackage
for coverage lookup. The architecture's hardest plumbing problem —
five hops through different CRSes and indexes from address to point
cloud — lives in this feature.

## How it fits the roadmap

Wave 2 — geospatial pipeline track. Parallel with F-05, F-07, F-08, F-09.
**On the critical path.** Unblocks the orchestrator (F-10).

## Dependencies (must exist before this starts)

- **F-01 Walking skeleton** — deployed sidecar container with PDAL
  installed (use the `postgis/postgis`-style trick with a
  PDAL-preinstalled base image).
- **F-02 Pipeline JSON Schema** — defines the `LiDARResult` shape.

## Unblocks (what waits on this)

- **F-10 Measurement orchestrator** — consumes the point array and
  WESM metadata.
- **F-08 Plane fit + measurement** consumes the cropped point array
  (integration via F-10).
- **F-16 iOS fusion** ICP-aligns the ARKit mesh to this point cloud
  (integration via F-10 → F-16).

## Acceptance criteria

- Sidecar exposes `POST /pipeline/ingest-lidar` taking `{building_polygon:
  GeoJSON, parcel_polygon: GeoJSON | null}` and returning either:
  - `{status: "LIDAR_AVAILABLE", point_array_url: "s3://...",
    point_count, work_unit: {project_name, ql, acquired_at,
    copc_url}, utm_zone, bounds_utm, sources}`
  - OR `{status: "LIDAR_MISSING", reason: string, work_unit_metadata:
    null | partial}`
  — schema-validated against `shared/pipeline_schema.json`.
- **Coverage check first:** before any data fetch, query the WESM
  GeoPackage for the building polygon's bounding box; return
  `LIDAR_MISSING` immediately if no work unit covers it (this is the
  fast-fail path that protects the 5-min latency budget).
- **CRS handling:** WGS84 inputs reprojected to the work unit's
  native CRS (often state plane or UTM); output point array is in
  the appropriate local UTM zone for the address, in meters; the
  UTM zone is part of the response.
- **PDAL pipeline:** reads COPC via `readers.copc` (or `readers.ept`
  for older work units); filters by classification (class 6 ==
  building); crops to building polygon (with optional 1 m buffer
  for eave overhang); writes the result as a `.las` or `.npy` to
  `s3://rooftrace-cache/lidar/<address_hash>.npy`; returns a signed
  URL valid for 1 hour.
- **WESM** GeoPackage is downloaded once and cached locally;
  refresh policy documented (quarterly).
- **Acquisition-date warning:** if the work unit's `acquired_at` is
  > 5 years old, include a `stale_lidar` warning in the response.
- **Performance:** end-to-end <60 seconds for a typical residential
  parcel on a warm cache (WESM index already loaded); <90s cold.
- **Failure modes:**
  - Address in a 3DEP gap → `LIDAR_MISSING` with `reason: "no_coverage"`.
  - PDAL pipeline error → 5xx with the PDAL error message logged.
  - S3 read timeout → retry once, then 5xx.

## Testing requirements

- **Coverage test:** on 5 known-coverage addresses (Lincoln NE,
  Chicago, San Francisco, Seattle, Boston), verify
  `LIDAR_AVAILABLE` + plausible point count (>100 points for a
  typical residential building).
- **Gap test:** on a known-gap address (parts of rural Wyoming or
  Alaska), verify `LIDAR_MISSING` returned in <2s (no full pipeline
  attempted).
- **CRS test:** verify the returned point array is in the expected
  UTM zone (e.g., Lincoln NE → EPSG:32614, UTM zone 14N).
- **Classification test:** verify only class-6 points are in the
  output (no ground / vegetation contamination).
- **Caching test:** repeat call for the same address completes in
  <5 seconds (point array fetched from cache).
- **Schema validation:** every test response validates green.

## Manual setup required

- **No external account** required — USGS 3DEP is anonymous S3
  reads from `s3://usgs-lidar-public/`.
- **Pre-download the WESM GeoPackage** (~200 MB) as part of the
  sidecar image build or first-run init; document the URL.
- **PDAL install in the sidecar Dockerfile** — recommend
  `mambaforge` base image with `conda-forge::pdal` for a working
  install; alternative is the PDAL official Docker image.
- **Pre-pick 4–5 demo addresses with verified 3DEP coverage** using
  the WESM viewer at https://apps.nationalmap.gov/lidar-explorer/
  before any other pipeline development — these are the fixtures
  the rest of the team's tests will use.

## Implementation notes (filled in by the building agent)

**Contract.** Consumes `IngestLidarRequest`, returns `IngestLidarResponse`
(schema 0.2.0). The response wraps the existing `LiDARResult` and adds
`utm_zone` + `bounds_utm`. Per the batch contract decision, the cropped cloud
crosses by a **Spaces object key** (`point_array_ref` = `cache/lidar/<hash>.npy`,
one prefixed bucket per ADR-010), NOT a raw `s3://…` URL — the orchestrator
mints a signed URL if a later stage must fetch it. This supersedes the original
spec's `point_array_url` + `s3://rooftrace-cache/…`.

**The 5-hop plumbing** (the architecture's hardest single piece, ADR-003), each
hop isolated and unit-tested:
1. **Coverage (fast-fail).** WESM is queried for the building bbox *before any
   fetch*; no covering work unit → `LIDAR_MISSING reason=no_coverage` in <2s
   (asserted). This protects the 5-min latency budget against doomed streams.
2. **Fetch+crop.** PDAL `readers.copc` with the building polygon (reprojected
   into the work unit's native CRS, +1 m eave buffer) + `filters.range` class 6.
3. **Classify.** Keep only ASPRS class 6; a cloud with zero building points →
   `LIDAR_MISSING reason=no_building_points`.
4. **Reproject.** Native CRS → the building's **local UTM zone** (computed from
   the centroid; 326xx/327xx), meters, so F-08's metric geometry is well-posed.
5. **Cache.** Write `.npy` via the shared `app/storage.py` helper.

**PDAL/GDAL are conda-only, not pip deps** (the Dockerfile uses a micromamba base
with conda-forge `pdal`/`python-pdal`/`gdal`). So the real COPC read and the real
WESM GeoPackage read are isolated behind `PdalCropper` / `GeoPackageWesmIndex`
whose imports are **lazy** — the module loads (and the whole test suite runs)
without PDAL/GDAL installed. Tests inject a `FixtureCropper` (synthetic class-6
cloud in the work unit's native CRS, plus contaminating ground points to prove
the filter) and a `FixtureWesmIndex` (coverage from a small JSON). The live path
is gated by `LIDAR_LIVE=1` (+ `WESM_GPKG_PATH`); CI/local run fixture-backed.
This is the one place "green locally" ≠ "works in prod", so the PDAL image build
is exercised in the compose smoke, not the unit suite.

**Decisions:**
- `bounds_utm` is `[min_x, min_y, max_x, max_y]` of the *cropped* points (the
  extent F-08 plane-fit and F-16 ICP work within), not the COPC tile bounds.
- `stale_lidar` warning when the work unit's collection year is >5 years old
  (gate constant `CURRENT_YEAR`, bumped with the calendar).
- Endpoint maps any unexpected ingest exception (PDAL/S3/CRS) to a 502 with a
  **generic** detail (`lidar ingest failed: <ExcType>`) — never leaks COPC URLs /
  AWS internals, matching the project's `/health` no-leak rule.

**Verified (real app, TestClient against the mounted router):**
`lincoln(covered) 200 status=LIDAR_AVAILABLE utm=32614 pts=196` ·
`wyoming(gap) 200 status=LIDAR_MISSING utm=None warn=['no_coverage']`.
Unit suite: `11 passed` (`uv run pytest tests/test_lidar_ingest.py`).

**Deferred / env-gated:** live USGS 3DEP COPC streaming + the real 200 MB WESM
GeoPackage (behind `LIDAR_LIVE=1`); the demo addresses with verified 3DEP
coverage (F-19 owns the demo-set file). The Rails-side signed-URL minting for
`point_array_ref` lands with the orchestrator (F-10).
