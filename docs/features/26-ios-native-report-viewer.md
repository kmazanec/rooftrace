# Feature: iOS native report viewer (MapKit + SwiftUI)

**ID:** F-26 · **Roadmap piece:** F-26 · **Status:** Not started

## What this delivers (before → after)

**Before:** A finished report can only be viewed on the web (or by opening the
share link in a browser). The app has no report surface.

**After:** A ready job's report renders **natively** — a MapKit map with the roof
footprint and per-facet polygons, the measurement tables (area, perimeter, pitch,
features, confidence, warnings, attributions) in SF Mono, and a native share
action for the `/r/:token` link.

## How it fits the roadmap

The native report — the contractor's payoff surface. Depends on F-21 + F-20's
bearer pass-through to `GET /api/v1/jobs/:id.json`. Because the
`json_export.schema.json` contract (ADR-015) is **already shipped**, this can be
built early against the frozen schema (independent of the F-22→F-25 chain).

## Requirements traced (from the PRD)

"When the report is ready, they can view it in the app, the same as they do on the
web." Fully native (MapKit + SwiftUI) per the locked decision.

## Dependencies (must exist before this starts)

- **F-21 iOS foundation + login** — design system (`Color.Brand.*`), `APIClient`,
  nav.
- **F-20** — bearer access to `GET /api/v1/jobs/:id.json` (the report payload). The
  decode can be built + tested against the **committed JSON fixture** before F-20
  lands.

## Unblocks (what waits on this)

- **None directly** — terminal node.

## Contracts touched

- **iOS report decode: facet-vertex `[lat,lng]` flip** (source:
  `shared/json_export.schema.json` v1.1.0 + ADR-015) — *consumes*: facet
  `vertices` are `[lat,lng]` (flipped) while `roof_outline`/`footprint` GeoJSON are
  `[lng,lat]`; interpreted through TWO distinct, unit-tested functions
  (`coordFromFacetVertex` vs `coordFromGeoJSON`). A `200` with `null` measurement
  degrades to a not-ready state.
- **iOS API client contract** (ADR-007 amendment) — *extends*: `Endpoint.report(id)`
  + the `RoofExport` DTO mirroring the frozen schema (pinned `schema_version`).
- **iOS native design system** (ADR-020) — *extends*: this is the **report
  surface** — `Color.Brand.*` only (no `cc-*`); the giant mono area number; muted
  single-hue facet fills (NOT a rainbow); the muted-gray confidence system; the
  one Brand-orange share CTA.
- **Confidence-aware artifact propagation** (ADR-015) — source + confidence are
  shown on every measurement, never dropped.

## Acceptance criteria (product behavior)

- A ready job's report fetches `GET /api/v1/jobs/:id.json` (app bearer) and renders:
  a **MapKit map** with the roof **footprint** (from GeoJSON `[lng,lat]`) and
  **per-facet polygons** (from facet `[lat,lng]` vertices) filled in a **muted
  single-hue, instrument** style (not pitch-rainbow), white-stroked, with the
  selected facet emphasized; and **SF-Mono measurement tables**: total area
  (the hero number), perimeter, predominant pitch (ratio + degrees), a per-facet
  breakdown, detected features, **confidence in muted grays** (always paired with
  the word + a shape cue, never color-only), warnings, and source attributions.
- The **facet-vertex flip is consumed correctly** via the two named converters;
  a malformed/`null` vertex drops out rather than crashing; the map fits the roof
  bounds.
- **Feature pins are NOT placed on the map** (the export carries only image-space
  `bbox_norm`, no geo-coordinate — the documented v1 limitation); features are
  listed in a table instead.
- A **share action** (`ShareLink`) presents the public `/r/:token` URL (from the
  report locator); it is the only Brand-orange CTA on the screen.
- A **`200` with `null` measurement** (token/report predates a measurement)
  degrades to a clean "report not ready" state; a fetch/auth error shows a
  recoverable state — **never a crash or a 500-style dead screen**.
- **Accessibility:** measurement rows are combined VoiceOver elements ("North
  facet, 1,204 square feet, pitch 6 in 12, confidence high"); the map exposes a
  summary + per-facet elements; the report is the VoiceOver source of truth for the
  numbers.

## Testing requirements

- **Unit tests** (against the committed `json_export` fixture, no backend needed):
  `RoofExport` decodes the frozen schema; **`coordFromFacetVertex` vs
  `coordFromGeoJSON`** each map a known fixture coordinate to the correct
  `CLLocationCoordinate2D` (the single highest-value test — guards the
  transpose-into-the-ocean failure); a `null`-measurement payload yields the
  not-ready state; malformed vertices are dropped.
- **Manual/snapshot:** the map facet rendering + table layout in light mode, and
  VoiceOver over the tables, in the manual test plan.

## Manual setup required

- None beyond F-21. (MapKit needs no API key; the basemap is Apple Maps.)

## Implementation notes (filled in by the building agent)

> Owned by the builder. Starts empty.
