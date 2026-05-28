# Feature: Address & polygon resolver

**ID:** F-05 · **Roadmap piece:** F-05 · **Status:** Built (pending batch MR) · 2026-05-28

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

### Files added

- `sidecar/app/resolve_address/nominatim.py` — Nominatim client with 1-RPS threading
  rate limiter (`_rps_lock`), NFC address normalization for cache keys, and a
  `GeocodeError` exception type. Live calls gated on `NOMINATIM_USER_AGENT` env.
- `sidecar/app/resolve_address/ms_footprints.py` — MS Building Footprints client.
  Uses the Bing Maps quadkey tile scheme (zoom 9) to locate the tile, downloads
  gzip-compressed GeoJSON-lines from the anonymous Azure Blob endpoint, and filters
  with Shapely. Fallback: 50 m buffer in degrees (lat-corrected) when no parcel.
- `sidecar/app/resolve_address/regrid.py` — Regrid free-tier client. Returns `None`
  immediately when `REGRID_API_KEY` is absent (graceful degradation). `RegridError`
  raised on HTTP 4xx/timeout.
- `sidecar/app/resolve_address/cache.py` — In-process TTL cache with a `CacheBackend`
  Protocol for future injection. TTLs: geocode 7 d, parcel 7 d, footprints 30 d.
  Module-level singletons `geocode_cache`, `parcel_cache`, `footprint_cache`.
- `sidecar/app/resolve_address/service.py` — Orchestration: geocode → parcel →
  footprints, cache reads/writes, graceful Regrid degradation, HTTPException 422 on
  hard failures.
- `sidecar/app/resolve_address/router.py` — Filled in from the 501 stub. Schema-
  version major-mismatch guard (409), delegates to `service.resolve()`.
- `sidecar/tests/test_resolve_address.py` — 44 tests, all offline (httpx
  MockTransport with base_url injection).

### Design decisions

- **httpx MockTransport over vcrpy**: chose `httpx.BaseTransport` subclasses over
  vcrpy cassettes because there are no real network calls to record (the MS tile URL
  is deterministic from the quadkey, not a real response we can record offline). The
  mock transports are equivalent to recorded fixtures for CI purposes.

- **MS tile URL is absolute, not relative**: `ms_footprints.py` builds the full
  `https://minedbuildings.../{quadkey}.geojsonl.gz` URL and calls `client.get(url)`
  directly. Tests inject an `httpx.Client(base_url=..., transport=MockMSTransport())`
  — the absolute URL is used verbatim regardless of client base_url; the transport
  intercepts all requests.

- **Cache stores raw coordinate lists, not Pydantic models**: to avoid coupling the
  cache layer to the contract, `geocode_cache` stores `GeocodedLocation` objects and
  the footprint/parcel caches store raw GeoJSON coordinate lists. Conversion to
  contract `Polygon`/`Address` happens in `service.py`.

- **Rails PostGIS cache deferred (F-10)**: the sidecar's cache is in-process only
  (module-level `InMemoryTTLCache`). The `CacheBackend` Protocol in `cache.py` is
  the injection point: when F-10 lands, a `PostgresCacheBackend` satisfying that
  protocol can be injected via FastAPI dependency override without touching the
  service logic.

- **GeometrySource for geocoded results**: Nominatim/OSM results are tagged
  `source=GeometrySource.IMAGERY` (satellite/aerial-derived) as the closest match
  in the enum to "external reference data". The enum does not have an `osm` or
  `geocode` member — this is a minor contract gap worth noting but not worth changing
  the frozen contract for.

### Contract gap (not changed)

`GeometrySource` has no `geocode` or `osm` value; geocoded `Address.source` is set
to `GeometrySource.IMAGERY` as the best available proxy. If F-10 needs to
distinguish geocode provenance from imagery provenance, a new enum member would be
warranted — flag for the contract owner.

### Live-call gating

- Nominatim: always runs live when `nominatim_client` is not injected. Tests inject
  a mock client, so CI is always offline.
- MS Footprints: always runs live when `ms_client` is not injected. Tests inject.
- Regrid: gated on `REGRID_API_KEY` being set. When absent, `parcel_polygon=null`
  and a warning is added. Tests inject both the client and `regrid_api_key="test-key"`.

### Test command

```bash
cd sidecar && SIDECAR_SHARED_SECRET=test-shared-secret uv run pytest tests/test_resolve_address.py -q
# 44 passed in 0.29s
```
