# ADR-004: Use Microsoft Building Footprints + Regrid for the building polygon prior

**Status:** Accepted (amended 2026-05-30) · **Date:** 2026-05-27 · **Stretch:** no
**Supersedes:** none · **Superseded by:** none

## Context

Every step downstream of "address → lat/lng" needs a **polygon to crop
to**. The LiDAR ingest (ADR-003) needs to mask the point cloud to the
building; the imagery pipeline (ADR-002) needs the same crop for visual
context; the SAM2 outline refinement uses the polygon as a prior to
prevent it from wandering onto the neighbor's roof.

Two distinct polygons can do this job, and they're not the same thing:

- A **building footprint** — the outline of the structure itself (the
  thing we want to measure).
- A **parcel boundary** — the legal property boundary (the lot the
  building sits inside).

We need *both*: the building footprint to seed the measurement, and the
parcel boundary to disambiguate when the same address has multiple
structures (house + detached garage + shed), to filter out
neighboring buildings the satellite tile catches, and to give the
contractor "this is the property" context in the UI.

Polygon sources surveyed:

| Source | What it gives | Cost | Coverage | Quality | Notes |
|---|---|---|---|---|---|
| **MS Building Footprints** | Building outlines, ML-derived from Bing | Free, ODbL license | US-wide; global available | ~80% IoU with manual labels typical; high recall, occasional artifacts | The de facto open building-footprint dataset |
| **OpenStreetMap buildings** | Building outlines, human-traced | Free, ODbL | Urban: great; rural: missing or sparse | Highly variable | Strong in major metros, gaps everywhere else |
| **Google Open Buildings** | Building outlines, ML-derived | Free | Global South focused; some US | Good where it exists | Coverage doesn't help US contractors |
| **Regrid (formerly Loveland)** | Parcel polygons + owner/zoning | Free tier for low-volume; paid above | Nationwide US | Authoritative — sourced from county records | The pragmatic parcel choice |
| **ReportAll USA / ATTOM** | Parcel + assessor data | Paid | Nationwide US | High | Heavier integration, not justified for v1 |
| **County GIS portals** | Parcel polygons, varying schemas | Free | Per-county | High but per-county | Every county is custom; non-starter for nationwide |

The brief specifies "parcel data" as one of the inputs, which makes
including a parcel source non-optional. The building footprint source is
required separately by the geometry pipeline.

## Options considered

**A. MS Building Footprints + Regrid free tier.** Two-layer polygon
stack: MS for the building outline (the measurement target), Regrid for
the parcel boundary (the disambiguation context). Both free at our
volume.
*Tradeoff:* two integrations instead of one; Regrid free tier has rate
limits that could matter under load (re-verify at build time).

**B. MS Building Footprints only.** Skip parcels entirely. Works fine
for the common case of one building per address.
*Tradeoff:* falls apart on multi-building parcels (house + garage),
shared-wall townhouses, and addresses where the satellite tile catches
a neighboring building close to the property line. Also walks back on
the brief's explicit "parcel data" requirement, which is a CTO red
flag.

**C. OpenStreetMap buildings only.** Pure-open, single-source.
*Tradeoff:* rural / suburban gaps are real; demo addresses outside
major metros will silently fail. Quality variance is the kind of
thing the demo gods punish.

**D. County GIS portals.** Authoritative.
*Tradeoff:* "nationwide" becomes "the 3 counties we hand-integrated."
Per-county schemas vary; non-starter for the demo's "type any
address" promise.

## Decision

**A. MS Building Footprints for the building polygon + Regrid free tier
for the parcel boundary.** Geocoder is **Nominatim** (free, OSM-backed)
for the address → lat/lng hop, with an option to swap to AWS Location
Service if we end up on AWS for other reasons.

## Rationale

The two polygons answer two different questions, and conflating them is
how the demo silently breaks on the first multi-building parcel a
reviewer types in. MS Building Footprints gives us the outline of *the
building* — the thing we measure. Regrid gives us the outline of *the
lot* — the disambiguation context that tells us which building on this
lot to measure, and prevents the LiDAR crop from grabbing the
neighbor's chimney.

The cost story matters here too: both sources are free at our volume,
both are nationwide, both are queryable by lat/lng, and the integration
is a couple of HTTP / S3 calls. The marginal complexity of "two
polygons instead of one" is repaid the first time someone types in a
townhouse address.

MS Building Footprints' ML-derived nature is a known caveat — it
occasionally hallucinates buildings or merges adjacent ones — and we
mitigate that by treating it as a **prior** that SAM2 refines using
NAIP imagery (forthcoming ADR on segmentation), not as ground truth. A
prior is forgiving; a truth claim isn't.

Nominatim handles the geocode hop without any vendor lock-in or quota
cliff at our scale; if rate limits become an issue we self-host (a few
GB of OSM data + a Docker container). This keeps the entire address →
polygon → measurement chain on free, open, defensible data.

## Amendment (2026-05-30): address-entry autocomplete uses Mapbox Search Box

The decision above stands for the **authoritative geocode**: the address→lat/lng
hop that the pipeline runs and whose result it caches stays on **Nominatim**,
whose ODbL terms permit that cache.

That same geocoder cannot drive a **per-keystroke typeahead**, though — the
Nominatim public-instance policy caps polite use at 1 req/s and forbids
high-volume use (the "Tradeoffs & risks" item below), and an autocomplete fires
a request per keystroke. So the address-entry screen's autocomplete uses the
**Mapbox Search Box `/suggest` endpoint** instead, under limits drawn so this
ADR's geocoder choice is unaffected:

- **Suggest-only.** We call `/suggest` and never `/retrieve`, so we never obtain
  Mapbox coordinates and never store a Mapbox geocode. (Mapbox's standard terms
  restrict storing geocoding *results*; calling only `/suggest` and discarding
  everything but the display text keeps us clear of that.)
- **In-session, non-persisted.** Suggestions are ephemeral browser UI state. When
  the contractor picks one, only its **address text** is submitted through the
  existing form; the pipeline re-geocodes that clean string with **Nominatim**,
  unchanged. Nothing about the pipeline's caching or attribution changes.
- **Token stays server-side.** A same-origin Rails proxy (`/address_suggestions`,
  gated by the demo login) injects `MAPBOX_PRIVATE_TOKEN` — the single server-side
  Mapbox token shared with the imagery/render/PDF paths (ADR-002); the browser
  never sees it. (The browser-only viewer basemap uses `MAPBOX_PUBLIC_TOKEN`
  instead — the split is by exposure, not by feature.) Input reaches Mapbox only
  as query-string params against a fixed host, so there is no SSRF surface.
- **Progressive enhancement.** With no token, JS off, or any Mapbox error, the
  field is a plain text input and the form works exactly as before. The token is
  therefore warn-only at boot (never fail-fast), unlike the load-bearing imagery
  token (ADR-002).

Net: better input quality and fewer geocode 422s, no second *authoritative*
geocoder, no conflict with the storage terms or the polite-use limit above.
Implemented by `MapboxSuggest`, `AddressSuggestionsController`, and the
`address-autocomplete` Stimulus controller.

## Tradeoffs & risks

- **MS Building Footprints staleness / ML artifacts.** Some buildings
  are missing, merged, or hallucinated. Mitigation: SAM2 refinement
  pass on NAIP imagery using MS as a prior, not a label. The refined
  polygon is what flows downstream.
- **Regrid free-tier limits.** Free tier covers low-volume use; under
  load we'd hit a wall. Mitigation: cache parcel polygons aggressively
  (a parcel boundary doesn't change between requests for the same
  address); for v1 demo volume the free tier is sufficient. If
  commercialization happens, paid tier is the line item.
- **Parcels for townhouses / condos are tricky** (one parcel,
  many roofs). Mitigation: use the MS Building Footprints polygon
  *intersected* with parcel as the measurement boundary; if the result
  contains multiple disjoint polygons, ask the user to pick (UI
  affordance), don't guess.
- **Nominatim TOS** has a 1 rps polite-use limit and forbids
  high-volume use without self-hosting. Mitigation: cache geocode
  results; self-host if v1 sees real traffic; AWS Location Service is
  the easy swap-in if we're already on AWS.
- **License compatibility.** MS Building Footprints is ODbL, Regrid is
  proprietary-with-free-tier, NAIP is public domain, OSM (Nominatim)
  is ODbL. We need a `LICENSES.md` listing each and any attribution
  required in the report/PDF.

## Consequences for the build

- **Address → polygons pipeline:**
  1. `geocode(address)` → `(lat, lng)` via Nominatim.
  2. `get_parcel(lat, lng)` → parcel polygon via Regrid.
  3. `get_building_polygon(parcel)` → MS Building Footprints polygons
     intersected with the parcel; if multiple, surface a
     selection UI.
  4. The selected building polygon is the input to **both** the LiDAR
     crop (ADR-003) and the SAM2 imagery refinement (forthcoming ADR).
- **CRS discipline:** all polygons normalized to **WGS84 (EPSG:4326)**
  for storage and transport; reprojected to the local UTM zone for
  area computation in the geometry pipeline. This boundary is the same
  one ADR-003 enforces.
- **Caching:** parcel polygons cache by parcel ID (Regrid returns
  one); building footprints cache by H3 cell or bounding box; geocode
  results cache by normalized address string. All caches live in
  Postgres for persistence across job runs (consistent with later
  persistence ADR).
- **`LICENSES.md`** lists MS Building Footprints (ODbL with attribution),
  Regrid (commercial terms — link), Nominatim (ODbL with usage policy),
  NAIP (public domain), Mapbox (commercial — link). Report and PDF
  include attribution where required.
- **No reliance on county-specific portals** in v1. If a v2 wants
  higher-fidelity parcels in specific markets, that's an
  enrichment layer added under the same polygon module.
