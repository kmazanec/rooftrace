# ADR-013: Web frontend is Hotwire pages with a single React island for the interactive viewer; MapLibre GL JS + deck.gl for map/3D

**Status:** Accepted · **Date:** 2026-05-27 · **Stretch:** no
**Supersedes:** none · **Superseded by:** none

## Context

The web frontend has two distinct surfaces, with different complexity
profiles:

- **Submit + status surfaces:** the address-entry form, the in-progress
  job status screen with polling/streaming updates, the share-link
  management. Pure CRUD + light async. Trivial in any framework.
- **Interactive report viewer:** the satellite basemap with the
  refined roof polygon overlay, per-facet 3D extrusion colored by
  pitch, hoverable feature pins (vents/chimneys/etc.), facet
  click-to-inspect, optional toggles for LiDAR point cloud overlay.
  This is the *measurement instrument* surface from the COMPANY.md
  design contract.

ADR-008 puts the backend on Rails 8, which makes Hotwire (Turbo +
Stimulus) the path of least resistance for the simple surfaces — the
form, status polling via Turbo Streams over ActionCable, share-link
modals, navigation chrome. CompanyCam-stack-aligned, no JS build
toolchain pain, fast.

The interactive viewer is a different animal. Map + 3D libraries
(MapLibre GL JS, deck.gl, Three.js) are JavaScript-native and assume
React-style declarative composition for non-trivial cases. Writing a
deck.gl scene from a Stimulus controller is possible; it ends up being
inner-platform-effect React-in-imperative-JS.

The mature Rails 8 pattern for "Hotwire app with one rich
visualization" is **a React island mounted inside one Hotwire view**.
The Rails view ships an empty `<div id="viewer-root" data-...>`; a
small React bundle hydrates it. The rest of the app stays Hotwire.

For the visualization stack itself, MapLibre GL JS + deck.gl is the
vendor-neutral open-source pairing. MapLibre forks Mapbox GL JS at its
last open-source version; deck.gl is Uber's GPU-accelerated layer
library that composes with MapLibre and supports 3D extrusion,
interaction, and animation natively. Both Apache 2.0; no per-render
fees.

## Options considered

**A. Rails + Hotwire + React island for the viewer; MapLibre + deck.gl
in the island.** Hotwire for the form, status, and chrome; one React
mount for the interactive map+3D viewer.
*Tradeoff:* small JS toolchain footprint (esbuild via `jsbundling-rails`
or Vite); two rendering paradigms but at a clean boundary (Hotwire
above, React only inside the viewer card). Maximum stack-fit + maximum
viz quality.

**B. Pure Hotwire/Stimulus + MapLibre + deck.gl.** Drive map and
deck.gl from a Stimulus controller. Possible.
*Tradeoff:* deck.gl + interactive 3D facet hover/click without React
declarative composition becomes imperative DOM management; rapidly
becomes inner-platform-effect; no real savings.

**C. Separate Next.js app for the viewer.** Cleanest React.
*Tradeoff:* second deploy unit; CORS surface against the Rails API;
auth-token plumbing; two repos' worth of code review. Over-engineered
for v1.

**D. Mapbox GL JS instead of MapLibre.** Slightly nicer dev experience
on some surfaces.
*Tradeoff:* commercial; ties UI rendering to Mapbox billing; ADR-002
already uses Mapbox for tiles only — extending it to the SDK doubles
the lock-in. MapLibre swap is one-line if needed; no reason to commit
early.

## Decision

**A. Hotwire-first Rails frontend with a single React island for the
interactive viewer**, built using **MapLibre GL JS + deck.gl**. The
island lives in `app/javascript/viewer/`, mounted by a Stimulus
controller into a designated `<div>` on the report-page view. Bundling
via `jsbundling-rails` + esbuild (Rails 8 default).

## Rationale

This is the architecture Rails 8 apps with rich visualization
actually look like in practice, and it's the architecture that buys
the most CompanyCam-stack-fit per line of frontend code. Forms,
status, navigation, share modals — all in Turbo/Stimulus, native to
the Rails monolith, zero JS framework overhead. The viewer — where
React's declarative composition with deck.gl pays for itself in
maintainability — gets exactly as much React as it needs and no more.

The MapLibre+deck.gl pairing is the vendor-neutral default of the
open geospatial-viz world right now. It gets us 3D extruded facets
with mouse interaction, animation, and high-DPI rendering essentially
for free; the alternative is reimplementing the layer-composition
primitives ourselves. Both libraries are Apache 2.0 and the API
surface is stable.

The CTO defense: *"Two rendering paradigms is a smell only when they
fight. Here they don't — Hotwire owns the document, React owns the
canvas. The seam is the viewer div. We chose the lightest framework
that solves each surface and drew the line at the API where the
viz library starts."*

## Tradeoffs & risks

- **Two rendering paradigms in the same repo.** Mitigation: enforce
  the boundary at one directory (`app/javascript/viewer/` is the
  *only* React); pattern documented in README; code review catches
  drift.
- **JS toolchain.** `jsbundling-rails` + esbuild is the Rails 8
  default; well-trodden. Bundle size for MapLibre + deck.gl + React
  is non-trivial (~500 KB gzipped); acceptable for the report page,
  not loaded on the form/status pages.
- **MapLibre is open-source-Mapbox-fork**, lags Mapbox in some
  features. Mitigation: features we need (raster basemap, GeoJSON
  vector overlay, custom layers via deck.gl) are all rock-solid in
  MapLibre.
- **deck.gl + React integration** has a small learning curve. Mitigation:
  the project's needs are within the "first afternoon" of deck.gl
  docs; we use the `@deck.gl/react` package which handles the
  composition idiomatically.
- **3D rendering on mobile browsers.** Mitigation: provide a 2D
  fallback view; test on at least one iOS Safari and one Android
  Chrome.

## Consequences for the build

- **Styling / brand tokens** *(amended F-04)*: the app uses **Tailwind CSS v4 +
  Propshaft**, with **no SCSS pipeline**. Brand tokens (COMPANY.md design
  contract) live as Tailwind v4 `@theme` custom properties in
  `app/assets/tailwind/brand.css` (imported by `application.css`), which exposes
  them as `:root` CSS custom properties. Plain-CSS stylesheets like
  `app/assets/stylesheets/report.css` consume them via `var(--color-brand-…)` /
  `var(--color-confidence-…)`. **Do not add a SCSS toolchain** (`dartsass`,
  `sassc`, `cssbundling`) — the F-04 feature spec named `.scss` files but they
  were implemented as `@theme` + plain CSS to avoid a second CSS build pipeline.
  The F-12 viewer and F-13 PDF must reuse these tokens, not redefine them.
- **Frontend structure:**
  - `app/views/...` — ERB views, Hotwire-driven (Turbo Streams over
    ActionCable for in-progress job updates).
  - `app/javascript/controllers/...` — Stimulus controllers for
    light interactivity on Hotwire pages.
  - `app/javascript/viewer/` — the React island: `index.tsx`,
    `RoofViewer.tsx`, deck.gl layer components. **All React code
    lives here; nothing else in the app is React.**
- **Mount + data flow** *(amended at viewer build; supersedes the two
  bullets below)*:
  - The island mounts on `<div data-controller="viewer"
    data-viewer-measurement-value="<json>">`. The mount attribute is the
    **serialized measurement payload itself**, NOT a `data-viewer-job-id-value`
    pointer. `MeasurementViewerSerializer` renders the payload and the view bakes
    it into the data attribute; the island reads it on connect.
  - **No JSON fetch, no `/api/v1/jobs/:id` round-trip, no CORS surface.** Baking
    the payload server-side makes the island work identically for the
    authenticated contractor view and the unauthenticated public share view
    (`/r/:token`) with zero client auth logic. The public `/r/:token.json` and
    `/api/v1/jobs/:id.json` endpoints are a *separate* JSON-export concern
    (ADR-015) and are deliberately not consumed by this viewer surface.
  - **Live mount path is `bootstrap.ts`, not the Stimulus controller.**
    `app/javascript/viewer/bootstrap.ts` self-mounts the island on
    `DOMContentLoaded`/`turbo:load` by querying `[data-controller~="viewer"]`,
    and unmounts on `turbo:before-cache`/`before-render` (releasing the MapLibre
    WebGL context — browsers cap contexts per page, so a Turbo-navigation leak
    silently breaks the map). `viewer_controller.js` is retained as the drop-in
    Stimulus replacement path (identical data attributes, identical entry point)
    for when a global importmap/Stimulus bootstrap is wired into the layout; the
    self-mount is live in the interim because the viewer ships before that.
  - **Rendering mode: overlaid / two-canvas.** `DeckGL` renders on its own canvas
    above a separate MapLibre basemap canvas, rather than the interleaved
    `@deck.gl/mapbox` `MapboxOverlay` path. This keeps the dependency surface to
    `@deck.gl/core+layers+react` + `maplibre-gl` (no `@deck.gl/mapbox` runtime),
    staying inside the bundle budget, and gives the island a simpler WebGL-context
    lifecycle to clean up.
- *(superseded — see the amended bullet above)* ~~**Stimulus controller**
  `viewer_controller.js` mounts the React island into `<div
  data-controller="viewer" data-viewer-job-id-value="<id>">`.~~
- *(superseded — see the amended bullet above)* ~~**Data flow:** the React island
  fetches the measurement result via a JSON API endpoint (Rails-served,
  `/api/v1/jobs/:id`); it does not have its own state store beyond local React
  state.~~
- **Dual-surface controllers use `respond_to`** *(added F-03 review)*: an action
  serving both a Hotwire browser form and a JSON client (island / iOS) must
  branch `format.html` (redirect + flash) vs `format.json` — never render JSON
  unconditionally, or a normal browser submit shows a raw JSON body. See
  `JobsController#create`.
- **Build:** `jsbundling-rails` + esbuild produces the viewer bundle
  (`app/assets/builds/viewer.js`); loaded only on the report page (not on the
  form / status pages) via a per-page `javascript_include_tag` conditional.
- **Package manager** *(amended at viewer build)*: **Yarn Berry with
  `nodeLinker: node-modules`** (see `.yarnrc.yml`), not Yarn Classic and not PnP.
  PnP is explicitly ruled out: deck.gl's transitive `@luma.gl` / `@loaders.gl`
  peer dependencies are undeclared, which breaks PnP's strict resolution and the
  esbuild bundler (and ts-jest). The canonical sources of truth for the toolchain
  version are `.yarnrc.yml` + the `packageManager` field in `package.json`
  (Corepack-pinned) + `yarn.lock`. The production `Dockerfile` build stage and
  the CI `js_test` job both `corepack enable` + `yarn install --immutable` before
  bundling, so `assets:precompile`'s `javascript:build` (`yarn build`) hook
  succeeds and the image actually ships `app/assets/builds/viewer.js`.
- **Map basemap** uses MapLibre with Mapbox raster tiles (ADR-002);
  basemap URL config via Stimulus data attribute.
- **Facets** rendered as a deck.gl `PolygonLayer` with `extruded:
  true` and elevation = `facet.area * 0.0` (flat for v1; per-facet
  elevation by pitch is a v1.5 polish item).
- **Features** rendered as a deck.gl `IconLayer` with one icon per
  feature class (vent, chimney, etc.); hover shows label +
  confidence.
- **Tests:** Capybara system tests for the Hotwire pages; React
  Testing Library for the viewer component.
- **Mobile-friendly:** viewer is responsive; on narrow viewports the
  facet detail panel collapses below the map.
