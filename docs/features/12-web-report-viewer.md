# Feature: Web report viewer (Hotwire + React island; MapLibre + deck.gl)

**ID:** F-12 · **Roadmap piece:** F-12 · **Status:** Not started

## Description

The interactive measurement-instrument surface: a satellite basemap
with the refined roof polygon overlay, per-facet 3D extrusion colored
by pitch, hoverable feature pins (vents/chimneys/etc.), facet
click-to-inspect, optional LiDAR point-cloud overlay toggle, and the
download/share controls. Per
[ADR-013](../adrs/ADR-013-web-stack-hotwire-react-island.md), the
page is Hotwire (chrome + auth + share controls) with a single React
island mounting MapLibre GL JS + deck.gl for the interactive viz.

The viewer is the public-share recipient's first impression and the
contractor's daily-driver view. Per COMPANY.md it must feel like a
**measurement instrument** (Mapbox Light, Carto, topographic-survey
aesthetic), not a Google Earth video game.

## How it fits the roadmap

Wave 3 — after F-10 (orchestrator) and F-11 (submission flow) land.
Terminal node (nothing depends on it). Can run in parallel with
F-13, F-14, F-19.

## Dependencies (must exist before this starts)

- **F-01 Walking skeleton** — deployed Rails + asset pipeline.
- **F-03 Auth machinery** — `/r/:token` route for public share.
- **F-04 Brand assets + stylesheet** — palette tokens, screen CSS.
- **F-10 Measurement orchestrator** — produces the `Measurement`
  the viewer reads.
- **F-11 Job submission flow** — page is reached from `/jobs/:id`
  after status transitions to ready.

## Unblocks (what waits on this)

- **None directly** — terminal node. (The PDF F-13 is logically
  similar but does not consume the viewer; they share F-04 brand
  and F-10 measurement.)

## Acceptance criteria

- **Routes:**
  - `GET /jobs/:id/report` (auth-required) renders the viewer for
    the contractor.
  - `GET /r/:share_token` (public) renders the same viewer
    read-only, sets `X-Robots-Tag: noindex`.
- **Page structure:**
  - Hotwire-rendered header with the RoofTrace wordmark, address,
    "Generated" timestamp, attribution.
  - One `<div data-controller="viewer" data-viewer-job-id-value=
    "<id>">` that mounts the React island.
  - Hotwire-rendered side panel with: total area, total perimeter,
    primary pitch, source + confidence, per-facet breakdown table,
    features table.
  - Hotwire-rendered footer with download buttons (PDF, JSON),
    share-link generator (contractor view only), attribution.
- **React viewer behavior:**
  - MapLibre GL JS renders the basemap (Mapbox Satellite tiles
    per [ADR-002](../adrs/ADR-002-imagery-providers-naip-mapbox.md)).
  - deck.gl `PolygonLayer` with `extruded: true` renders per-facet
    extrusion; color encodes pitch (low pitch = lighter charcoal,
    high pitch = darker, per the brand's neutral-grays palette —
    not stoplight colors).
  - deck.gl `IconLayer` renders one icon per detected feature
    (chimney, vent, skylight, dormer, satellite_dish); icon style
    is workmanlike per the brand.
  - Hover over a facet shows a tooltip with area + pitch + source
    + confidence; click selects it and updates the side-panel
    detail.
  - Hover over a feature pin shows label + confidence + verified
    status.
  - Optional toggle "Show LiDAR points" overlays the point cloud
    (when `source` includes LiDAR) using a deck.gl `PointCloudLayer`.
- **Honest-uncertainty UX:** every measurement number has a
  source label adjacent ("from LiDAR", "from satellite imagery",
  "from on-site capture"); low-confidence facets render with a
  visual marker (e.g., dashed outline) per the brand rules in
  F-04.
- **Responsive:** on viewports <800px wide, the side panel
  collapses below the map; map remains usable on touch.
- **Performance:** report page loads JS bundle (<1 MB gzipped); map
  + facets render within 2s of bundle load on a typical residential
  measurement.
- **Public share view differences:** no "Generate share link"
  control; no download-restricted controls; same attribution and
  honest-uncertainty UX as the private view.
- **Brand conformance:** verified by visual regression test per F-04.

## Testing requirements

- **System test (Capybara):** loads the report page with a fixture
  `Measurement`; asserts the React mount renders without console
  errors; asserts side panel shows the expected numbers.
- **React component tests:** unit tests for the facet color
  encoding, tooltip rendering, public-vs-private affordance
  differences.
- **Visual regression test:** screenshot of the report page on a
  fixture measurement compared against a golden image.
- **Public-share test:** `/r/:token` renders without auth; missing
  controls confirmed; `X-Robots-Tag` header asserted.
- **Bundle-size test:** built React bundle <1 MB gzipped (catches
  accidental bloated imports).
- **Mobile-viewport test:** asserts the responsive collapse at
  <800px.

## Manual setup required

- **Mapbox public access token** (for Mapbox Satellite basemap
  tiles); provisioned as `MAPBOX_PUBLIC_TOKEN` env var. Free tier
  covers demo volume.
- **Verify color tokens render correctly across browsers** during
  build (Safari, Chrome, Firefox).
- **Build pipeline:** `jsbundling-rails` + `esbuild` produces the
  React bundle; configured in `package.json`.

## Implementation notes (filled in by the building agent)

> The agent implementing this feature records its implementation
> decisions and rationale here as it builds — chosen libraries/patterns
> within the architecture's constraints, trade-offs made, deviations
> from assumptions and why, and anything the next agent or the
> integrator needs to know. This section starts empty and is owned by
> the builder, not the planner. Cross-cutting discoveries that affect
> other features must also be propagated to ROADMAP.md or the
> architecture doc, not just left here.
