# Feature: iOS native report viewer (MapKit + SwiftUI)

**ID:** F-26 · **Roadmap piece:** F-26 · **Status:** Done

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

## Build plan (planned 2026-05-31 · iteration `ios-full-app` · see `docs/BUILD-PLAN-ios-full-app.md`)

**Model tier:** Sonnet build → Opus review. Depends on F-21 (+ F-20 bearer); **∥ the
F-22→F-25 chain** (build early against the committed JSON fixture). **Owns** the two
coordinate converters + the `RoofExport` DTO (BUILD-PLAN §9.5).

### Architecture decisions
- **TWO named, separately unit-tested converters:** `coordFromFacetVertex([Double]) -> CLLocationCoordinate2D?` (facet `[lat,lng]`) and `coordFromGeoJSON([Double]) -> CLLocationCoordinate2D?` (`[lng,lat]`). One shared converter guarantees a transpose-into-the-ocean bug. Both return optional and drop malformed/`null` vertices.
- `measurement` decodes as **optional**; a `200` with `null` measurement degrades to a `.notReady` state, never a crash.
- **Report surface = `Color.Brand.*` ONLY**, never `cc-*` (ADR-020 palette-crossing rule; report components take only Brand styling).
- MapKit overlays via `MapPolygon` in a SwiftUI `Map`; facet fills a **muted single hue** (not pitch-rainbow), white-stroked, selected facet emphasized; map fits roof bounds via a computed `MKMapRect`.
- **Feature pins are NOT placed on the map** — `bbox_norm` is image-space only (documented v1 limitation); features render in a table.
- Confidence shown in muted grays + the word + a shape cue, never color-only.

### Adds
- View-model `ReportViewModel` (fetch, decode → `ReportState { loading / ready(RoofExport) / notReady / error }`, selected-facet, computed map bounds); view `ReportView`.
- Components (Brand-only): **`StatProbe`** (label + `MonoValue`), **`ConfidenceChip`** (gray dot + word + shape cue), **`FacetSwatch`**, **`SectionHeader`**. Hero number uses `monoXL`. The one Brand-orange CTA is the `ShareLink`.
- **Adds `Endpoint.report(id) -> RoofExport`** mirroring `shared/json_export.schema.json`, pinned `schema_version "1.1.0"`: `job`, `measurement?`, `provenance`, `artifacts{pdf_url, share_url, model_3d_url(null)}`. The `/r/:token` URL comes from `artifacts.share_url` / the report locator.

### Contrarian failure modes
- **The `[lat,lng]` vs `[lng,lat]` flip (highest-value test):** each converter has a unit test mapping a known fixture coordinate to the correct `CLLocationCoordinate2D`.
- `null` measurement → "report not ready", never a crash/500-style dead screen.
- Malformed/short vertex arrays drop out (converter returns `nil`, polygon skips), no index crash.
- Map must fit roof bounds from valid coords; an empty/degenerate set must not zoom to null-island or the whole globe.
- Feature pins NOT on the map (only `bbox_norm` exists) — table, not a guessed geo-pin.
- Confidence never color-only (`ConfidenceLow #9CA3AF` fails AA as small text → rides the word + shape).
- Pin `schema_version "1.1.0"`; an unexpected version surfaces, not silently mis-decodes.
- VoiceOver: measurement rows are **combined** elements ("North facet, 1,204 square feet, pitch 6 in 12, confidence high").

### Ordered build steps (test-first)
- [x] Write `coordFromFacetVertex`/`coordFromGeoJSON` + unit tests vs the committed `json_export` fixture (the flip test) + malformed-vertex drop.
- [x] Implement the two converters.
- [x] Define `RoofExport` DTO (pinned `schema_version`) + decode test vs the fixture; `null`-measurement → `.notReady` test.
- [x] Add `Endpoint.report(id)` + `report(id:)` wrapper.
- [x] `ReportViewModel` tests: decode→ready; null→notReady; fetch error→error; map-bounds from valid coords; malformed dropped.
- [x] Implement `ReportViewModel`.
- [x] Build `StatProbe`, `ConfidenceChip` (gray+word+shape), `FacetSwatch`, `SectionHeader` (Brand-only).
- [x] Build `ReportView`: MapKit map + footprint (GeoJSON) + facet polygons (facet vertices), selected-facet emphasis, fit-to-bounds.
- [x] Build the SF-Mono tables: hero area (`monoXL`), perimeter, predominant pitch (ratio + degrees), per-facet breakdown, features table, confidence, warnings, attributions.
- [x] Add `ShareLink` for `/r/:token` (the one Brand-orange CTA).
- [x] VoiceOver combined elements for rows + map summary.

### Test list
- **Unit (committed fixture, no backend):** `RoofExport` decodes; **`coordFromFacetVertex` vs `coordFromGeoJSON`** each map a known coord correctly (the transpose guard); `null`-measurement→notReady; malformed dropped; fetch/auth error→recoverable.
- **Manual/snapshot (device):** map facet rendering + table layout in light mode; VoiceOver over tables + map summary; fit-to-bounds.

### Contract touchpoints frozen
Owns `coordFromFacetVertex` + `coordFromGeoJSON` (no third converter anywhere); adds
`Endpoint.report(id)` + the `RoofExport` DTO (pinned `schema_version "1.1.0"`); owns the
report-surface palette boundary (`Brand.*` only) + `StatProbe`/`ConfidenceChip`/`FacetSwatch`/`SectionHeader`.

## Implementation notes (filled in by the building agent)

- Implemented native report decode in `RoofExport`, pinned to `schema_version`
  `1.1.0`; unexpected schema versions throw during decode. The DTO keeps
  `measurement` optional so `200` + `null` renders as `.notReady`.
- Added the two named coordinate converters exactly as frozen:
  `coordFromFacetVertex([Double])` for facet `[lat,lng]` and
  `coordFromGeoJSON([Double])` for GeoJSON `[lng,lat]`. Both are optional and
  reject malformed/out-of-range values; facet decoding is lossy so bad vertices
  drop without crashing.
- Added `Endpoint.report(id) -> RoofExport` plus `APIClientProtocol.report(id:)`,
  and wired `.report(jobID:)` in the authenticated app root to `ReportRouteView`.
- Built `ReportViewModel` with `loading`, `ready`, `notReady`, and recoverable
  `error` states, selected facet state, and pure map-bounds helpers.
- Built Brand-only report components (`StatProbe`, `ConfidenceChip`,
  `FacetSwatch`, `SectionHeader`) and the SwiftUI report screen with MapKit
  polygons, muted single-hue facet styling, selected-facet emphasis,
  SF-Mono measurement rows, feature table only (no feature pins), warnings,
  attributions, and the single Brand-orange `ShareLink`.
- The committed `json_export` schema/fixture currently do not include
  `footprint` or `roof_outline` GeoJSON fields. The DTO/view tolerate those
  fields if they become additive later; until then the map outline and bounds
  are derived from valid facet coordinates.
- Added iOS unit coverage for fixture decode, both coordinate converters,
  malformed vertex drops, null-measurement not-ready behavior, view-model
  ready/not-ready/error states, and map bounds.
- Validation: `python3 gen_pbxproj.py`; `xcodebuild test -scheme RoofTrace
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6'` passed
  96 tests with 0 failures. The requested iPhone 15 simulator was not
  installed, so validation used an installed iPhone 16 simulator.
