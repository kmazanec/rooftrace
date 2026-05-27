# Feature: LiDAR ingest (USGS 3DEP via COPC + PDAL)

**ID:** F-06 · **Roadmap piece:** F-06 · **Status:** Not started

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

> The agent implementing this feature records its implementation
> decisions and rationale here as it builds — chosen libraries/patterns
> within the architecture's constraints, trade-offs made, deviations
> from assumptions and why, and anything the next agent or the
> integrator needs to know. This section starts empty and is owned by
> the builder, not the planner. Cross-cutting discoveries that affect
> other features must also be propagated to ROADMAP.md or the
> architecture doc, not just left here.
