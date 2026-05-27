# Feature: Address & polygon resolver

**ID:** F-05 · **Roadmap piece:** F-05 · **Status:** Not started

## Description

Given an address string, this feature produces the geocoded location
plus the building polygon(s) and parcel boundary needed by every
downstream pipeline stage. It is the first hop of the geospatial
pipeline and the only stage that talks to three external data
sources: Nominatim (geocode), Microsoft Building Footprints (building
outlines), and Regrid (parcel boundaries). Results are cached in
PostGIS via Rails so repeat lookups for the same address are
sub-second.

Per [ADR-004](../adrs/ADR-004-footprint-source-ms-building-footprints-regrid.md),
MS Building Footprints provides the building outline (the measurement
target) and Regrid provides the parcel boundary (used for
disambiguation on multi-building lots and for trimming the satellite/
LiDAR crop to the right property).

## How it fits the roadmap

Wave 2 — geospatial pipeline track. Parallel with F-06, F-07, F-08, F-09.
Off the critical path (F-06 LiDAR is longer). Unblocks the orchestrator
integration feature (F-10).

## Dependencies (must exist before this starts)

- **F-01 Walking skeleton** — needs the deployed stack with PostGIS.
- **F-02 Pipeline JSON Schema** — produces the `Polygon` and
  `Address` types this feature emits.

## Unblocks (what waits on this)

- **F-10 Measurement orchestrator** — consumes geocoded location +
  building polygons + parcel polygon to drive the rest of the
  pipeline.
- **F-06 LiDAR ingest** consumes the building polygon for cropping
  (technically a sibling, but they integrate via the orchestrator).
- **F-07 Outline refinement** consumes the building polygon as the
  SAM2 prior.

## Acceptance criteria

- Sidecar exposes `POST /pipeline/resolve-address` that takes
  `{address: string}` and returns
  `{geocode: {lat, lng, formatted_address, source},
    parcel_polygon: GeoJSON Polygon | null,
    building_polygons: GeoJSON Polygon[],
    sources: {geocode, parcel, building}}` — schema-validated
  against `shared/pipeline_schema.json`.
- **Geocoder:** Nominatim is the default; respects the 1 RPS polite-
  use limit; caches results in PostGIS keyed by a normalized address
  string.
- **Building footprints:** uses Microsoft Building Footprints; returns
  the building polygon(s) inside the parcel boundary (if parcel
  available) or within a 50 m radius of the geocoded point (fallback);
  caches by H3 cell.
- **Parcel boundary:** Regrid free tier; cached by parcel ID;
  returns `null` (with a logged warning) if Regrid is unavailable or
  the address isn't covered, and the downstream consumers degrade
  gracefully.
- **Multi-building parcels:** when more than one building polygon
  intersects the parcel, the response returns all of them; the
  orchestrator decides which to use (or surfaces a picker — handled
  by F-10).
- **CRS:** all polygons returned in WGS84 (EPSG:4326), GeoJSON
  format.
- **Failure modes:** geocode fails → 422 with reason; parcel fails →
  200 with `parcel_polygon: null` + warning in response; building
  footprint missing → 422 (can't proceed without a polygon).
- **Caching:** repeat lookups of the same address hit the cache and
  return in <100ms; cache keys documented; TTL per the ADR (geocode
  7d, parcel 7d, building footprints 30d).
- **Attribution:** response includes a `sources` block naming
  Nominatim/OSM, Microsoft Building Footprints, Regrid for downstream
  surfaces to render attribution.

## Testing requirements

- **Unit tests** for each external client (Nominatim, MS Footprints,
  Regrid) using recorded HTTP fixtures (VCR or equivalent).
- **Integration test** end-to-end on 5 fixture addresses spanning:
  single-family residential (urban), single-family rural,
  townhouse, multi-building parcel (house + detached garage), known-
  gap address.
- **Cache test:** first-call vs. cache-hit latency assertion.
- **Failure-mode tests:** geocode 4xx, Regrid timeout, MS Footprints
  empty result.
- **Schema validation:** every test response validates against
  `shared/pipeline_schema.json`.

## Manual setup required

- **Set `NOMINATIM_USER_AGENT` env var** (Nominatim TOS requires a
  meaningful UA naming the project + contact email).
- **Provision Regrid free-tier API key**; inject via Kamal secrets
  as `REGRID_API_KEY`.
- **No setup for MS Building Footprints** — anonymous S3 reads from
  the public bucket.
- **Document Nominatim TOS** in `LICENSES.md`; commit to self-
  hosting if traffic exceeds 1 RPS.

## Implementation notes (filled in by the building agent)

> The agent implementing this feature records its implementation
> decisions and rationale here as it builds — chosen libraries/patterns
> within the architecture's constraints, trade-offs made, deviations
> from assumptions and why, and anything the next agent or the
> integrator needs to know. This section starts empty and is owned by
> the builder, not the planner. Cross-cutting discoveries that affect
> other features must also be propagated to ROADMAP.md or the
> architecture doc, not just left here.
