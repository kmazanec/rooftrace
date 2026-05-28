# Feature: Web report viewer (Hotwire + React island; MapLibre + deck.gl)

**ID:** F-12 · **Roadmap piece:** F-12 · **Status:** Planned (build plan approved-pending · 2026-05-28)

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

---

## Build plan (approved) — planned 2026-05-28

> Generated by the plan-iteration pass and reconciled into the shared
> contract manifest in [`../BUILD-PLAN.md`](../BUILD-PLAN.md). The frozen
> contracts + shared barrier in that manifest take precedence over any
> step below if they disagree. **Approve before building.**

> **Human resolutions (2026-05-28) — accept these v1 scope cuts:**
> - Flat facets (elevation 0; 3D extrusion deferred to v1.5).
> - Feature pins anchored near the roof-outline centroid (no per-feature lon/lat exists).
> - **LiDAR point-cloud toggle ships DISABLED with a "point overlay coming soon" tooltip** — a labeled affordance, not a bare greyed-out dead control.
> - Side panel is static ERB (no React↔ERB click-highlight sync in v1).
> - Visual-regression is a manual reviewer comparison vs the F-04 `_demo` scaffold (no Percy/Chromatic).

**Recommended build model tier:** `opus` — JS toolchain bootstrap from zero (esbuild+React+MapLibre+deck.gl+TS alongside importmap), WebGL/Turbo lifecycle, the shared Report/token contract, and a serializer that must not invent fields — high coordination + correction load.

### Summary

F-12 is the interactive measurement-instrument viewer: a Hotwire page (header, side panel, footer, share/download controls, all honest-uncertainty UX) wrapping ONE React island (app/javascript/viewer/) that renders a MapLibre GL JS Mapbox-Satellite basemap with deck.gl layers — a flat PolygonLayer of facets color-encoded by pitch using the brand neutral-gray confidence palette (ADR-013 fixes elevation at 0 for v1; 3D extrusion is v1.5), an IconLayer of detected-feature pins, and an optional LiDAR PointCloudLayer toggle. It serves both the contractor route GET /jobs/:id/report (session-gated, replaces the stub in JobsController#report) and the public GET /r/:token (no auth, X-Robots-Tag: noindex, replaces the stub in ReportsController#show_public), differing only in chrome affordances. The big first-time cost is bootstrapping the JS toolchain (jsbundling-rails + esbuild + React + maplibre-gl + @deck.gl/* + TypeScript) from zero — importmap-rails is what exists today. The single most important correction to all three drafts: the measurement JSON API endpoint /api/v1/jobs/:id.json and /r/:token.json belong to F-14 (ADR-015, json_export.schema.json), which runs in parallel with NO interdependency on F-12 — so F-12 MUST NOT build that endpoint and MUST NOT depend on it. Instead the server-rendered Hotwire view serializes the latest Measurement into a data attribute the React island reads on connect (no second request; works identically for the unauthenticated public view; sidesteps both the endpoint collision and the public-CORS-endpoint security question). The drafts also invented facet fields that do not exist: the frozen Facet schema is {facet_id, vertices (already WGS84 [lon,lat]), pitch_ratio, pitch_degrees, area_sq_ft, source, confidence} — there is no `id`, no `vertices_wgs84`, and pitch_degrees IS stored per-facet (no conversion needed). Features carry bbox_norm (image-space [0,1] against the satellite tile) with NO geographic center — placing IconLayer pins in map space is a genuine gap (the orchestrator does not emit lon/lat for features), so v1 anchors feature pins at the roof-outline centroid / footprint and surfaces the feature inventory primarily in the side-panel features table, documenting the limitation. Report rows have no creator anywhere today (orchestrator never makes one); F-12 freezes lazy find_or_create_by(job_id:) on the contractor page plus the token->report.job->latest_measurement resolution as the shared path for F-13/F-14.

### Dependencies (verified present in code)

- F-04 brand scaffold (VERIFIED present): app/assets/tailwind/brand.css with confidence/gray/orange tokens, app/assets/stylesheets/report.css with .report-confidence/.report-source classes, the rooftrace-wordmark SVG assets, and app/views/reports_demo/_report_body.html.erb as a styling reference.
- F-10 orchestrator (VERIFIED present): MeasurementOrchestrator persists a Measurement row (facets/features jsonb verbatim from the frozen schema, total_area_sq_ft, predominant_pitch_ratio, total_perimeter_ft, geocode, source, confidence, provenance.attributions) and flips Job to :ready. Job#latest_measurement (VERIFIED) returns the newest by generated_at.
- F-03 auth (VERIFIED present): ApplicationController#require_demo_login, ReportsController#show_public stub with the find_by! + noindex + 404 behavior, Report model with has_secure_token :share_token and to_param.
- Routes (VERIFIED present): GET /jobs/:id/report (member, currently a stub in JobsController#report) and GET /r/:token (reports#show_public). No new routes needed.
- PipelineSchema validator (VERIFIED present): json_schemer-backed PipelineSchema.errors_for used to assert the factory facets/features match the frozen Facet/Feature $defs.
- PostGIS test DB on localhost:5433 and uv-available sidecar per CLAUDE.md (run all Rails commands bare, no DATABASE_* env vars). The viewer system/request specs do not need a live sidecar.

### Shared-contract touch points

> These are reconciled and frozen in `BUILD-PLAN.md`. Build to the frozen
> signatures there, not to prose in this spec.

- Report creation + resolution path (CRITICAL, shared with F-13 + F-14): lock in an ADR-016 amendment — Report rows are created LAZILY via Report.find_or_create_by(job_id:) on the authenticated contractor /jobs/:id/report page; ALL public/PDF/JSON surfaces resolve token -> Report.find_by!(share_token:) -> report.job -> job.latest_measurement; nil job or no-measurement renders a not-ready state, never a 500. Every surface uses Job#latest_measurement (live, not a snapshot).
- Ownership of the public measurement JSON endpoints: /api/v1/jobs/:id.json and /r/:token.json belong to F-14 (ADR-015, shared/json_export.schema.json), NOT F-12. F-12 must NOT create these routes or a competing serializer endpoint. F-12 bakes a viewer-specific serialized payload into a data attribute in the server-rendered HTML instead, so it has zero runtime dependency on F-14 (the two run in parallel).
- Frozen Facet shape the viewer consumes (pipeline_schema.json $defs/Facet): {facet_id, vertices ([lon,lat] WGS84 — already projected, NO vertices_wgs84 field), pitch_ratio, pitch_degrees, area_sq_ft, source, confidence}. There is no `id` field and pitch_degrees is present per-facet (no conversion needed in the viewer).
- Frozen Feature shape: {label (vent|chimney|dormer|skylight|satellite_dish|other), bbox_norm ([x0,y0,x1,y1] in [0,1] image-space against the satellite tile), verified, source, confidence}. NO geographic center is emitted — feature pins cannot be precisely geolocated on the map without an orchestrator change; this is a documented v1 limitation and a proposed cross-cutting follow-up (orchestrator emits feature lon/lat).
- Measurement row roll-ups available to the serializer: total_area_sq_ft, predominant_pitch_ratio (NOTE: only the ratio is stored; pitch_degrees for the predominant pitch must be derived in the serializer), total_perimeter_ft, geocode {lon,lat,confidence}, source, confidence, warnings, provenance.attributions (the attribution source list the footer renders).
- Brand tokens (F-04, ADR-013): the React island and viewer.css consume the existing CSS custom properties from app/assets/tailwind/brand.css (--color-confidence-high/medium/low #374151/#6B7280/#9CA3AF, --color-brand-orange, --color-brand-charcoal, gray scale). NO new tokens, NO redefinition, NO SCSS pipeline. Orange only on the primary CTA. F-13/F-19 must reuse the same tokens.
- JS toolchain scope (ADR-013): jsbundling-rails + esbuild + React + maplibre-gl + @deck.gl/core/layers/mapbox/react + TypeScript ONLY. importmap-rails stays for Hotwire/Stimulus pages. No Webpack/Vite/Redux/router/CSS-in-JS. app/javascript/viewer/ is the ONLY React in the app and viewer_controller.js is the ONLY new Stimulus controller. Bundle <1MB gzipped, loaded only on the report page.
- Auth boundary (ADR-016): /jobs/:id/report require_demo_login; /r/:token public + X-Robots-Tag noindex + 404 (not redirect) on bad token. Because the measurement payload is baked into the HTML, the public view needs NO unauthenticated data endpoint — closing the CORS/SSRF question that a public JSON-fetch endpoint would open (that surface is F-14's to harden).
- Attribution surfaces: viewer footer must list NAIP, USGS 3DEP, Microsoft Building Footprints, Regrid, Mapbox, Nominatim, sourced from provenance.attributions with a static full-list fallback. Same source list must appear in F-13 PDF and F-14 JSON provenance (lock the canonical text in LICENSES.md).
- MAPBOX_PUBLIC_TOKEN env var: front-end-only (sidecar uses NAIP, not Mapbox). Provisioned per ADR-002, fail-fast-at-boot initializer (raise in prod / warn in dev-test) per the repo convention, documented in ops/.env.example.

### Build steps

- [ ] **Consume the shared Report-creation + token-resolution contract (do NOT re-implement it)**
  - ⚠️ **RECONCILED — overrides this feature's original draft.** The draft proposed *lazy* `Report.find_or_create_by(job_id:)` on the contractor page. The shared-contract reconciliation moved this to **EAGER** creation inside `MeasurementOrchestrator#persist` (barrier step 1, landed before fan-out) so the public `/r/:token` paths work for jobs whose contractor page was never visited. See `BUILD-PLAN.md` → Shared barrier + the "Report-creation-on-ready + token resolution" frozen contract. **This feature does not own that work** — it consumes the resolver verbatim: contractor view at `/jobs/:id/report` resolves `@job.latest_measurement` directly; the share-link control + public view use `token -> Report.find_by!(share_token:) -> report.job -> job.latest_measurement`, rendering a not-ready state (never 500) on nil job/measurement and a 404 (not redirect) on a bad token. The viewer always shows the live `job.latest_measurement`, not a snapshot.
- [ ] **Bootstrap the JS toolchain: add jsbundling-rails, generate esbuild config, pin deps in package.json**
  - Add gem 'jsbundling-rails' to the main Gemfile group; bundle install. Run bin/rails javascript:install:esbuild (Rails 8 scaffold) which writes package.json, app/javascript/application.js, an esbuild build:js script, and a Procfile.dev wiring 'js: yarn build --watch' alongside the Rails/tailwind watchers. Keep importmap-rails for the existing Hotwire/Stimulus pages — do NOT rip it out (status/form pages depend on it). Pin EXACT versions in package.json: react, react-dom, maplibre-gl, @deck.gl/core, @deck.gl/layers, @deck.gl/react, @deck.gl/mapbox (the MapLibre interleave), typescript, esbuild, @types/react, @types/react-dom. Do NOT add react-router, redux, lodash, date-fns, or any CSS-in-JS — keep the island lean for the <1MB-gzip budget. Add node_modules/ and app/assets/builds/*.js to .gitignore (keep app/assets/builds/.keep). Add tsconfig.json (jsx: react-jsx, target es2020, moduleResolution bundler, strict). Run yarn build once and confirm it emits app/assets/builds/viewer.js with no errors.
- [ ] **Write a failing system spec for the contractor viewer page (test-first)**
  - spec/system/report_viewer_spec.rb (uses the existing Capybara+selenium setup). Build a Job + a realistic Measurement via the factory trait added below; log in (reuse the demo-login helper from spec/support if present, else set session). Visit job_report_path(job). Assert: HTTP 200; the div[data-controller='viewer'][data-viewer-measurement-value] is present and its value parses to JSON with the expected facet count and total area; the side-panel renders total_area_sq_ft, primary pitch, source label and confidence; no JS console errors (page.driver.browser.logs if available, else assert the viewer root has a mounted child). This drives steps 4-11. Tag it :js so it runs under a JS-capable driver.
- [ ] **Add a realistic Measurement factory trait with schema-valid facets and features**
  - Extend spec/factories/measurements_factory.rb with a trait :with_geometry (or a :complete factory) that sets facets to 2-3 hashes EXACTLY matching the frozen Facet schema {facet_id:'F1', vertices:[[lon,lat],...closed ring of >=3], pitch_ratio:6.0, pitch_degrees:26.57, area_sq_ft:842.0, source:'lidar', confidence:0.9}, features to 1-2 hashes {label:'chimney', bbox_norm:[0.4,0.3,0.5,0.45], verified:true, source:'imagery', confidence:0.8}, total_area_sq_ft, predominant_pitch_ratio, total_perimeter_ft, geocode:{lon:,lat:,confidence:}, provenance with attributions. Validate the assembled facets/features against PipelineSchema in a model/contract spec so the fixture can never drift from the real orchestrator output.
- [ ] **Create the MeasurementViewerSerializer (server-side, NOT an API endpoint)**
  - app/services/measurement_viewer_serializer.rb (plain PORO, takes a Measurement, returns a Hash). Emits ONLY what the React island needs, derived from the real row: {address (from job), generated_at (iso8601), source, confidence, total_area_sq_ft, total_perimeter_ft, primary_pitch_ratio, primary_pitch_degrees (computed via Math.atan(ratio/12) in degrees since the row stores only predominant_pitch_ratio), bounds ([minLon,minLat,maxLon,maxLat] computed from all facet vertices + roof_outline + footprint, for the map's initial fitBounds), facets:[{facet_id, vertices, pitch_ratio, pitch_degrees, area_sq_ft, source, confidence}], features:[{label, bbox_norm, verified, source, confidence}], roof_outline (GeoJSON Polygon or null), footprint (or null), warnings, attributions (flattened from provenance.attributions for the footer)}. This is consumed inline by the view (to_json into a data attribute) — it is deliberately NOT a route, so it cannot collide with F-14's /api/v1/jobs/:id.json public-contract endpoint. Unit-spec it round-tripping a factory Measurement and assert every field; assert primary_pitch_degrees derivation and bounds computation.
- [ ] **Replace JobsController#report stub with the real lazy-creating action; wire ReportsController#show_public to the shared view**
  - JobsController#report: keep set_job; render 'reports/show' (shared template). Compute @measurement = @job.latest_measurement; if nil, render a 'measurement not ready' state (not a 500). Create the Report lazily: Report.find_or_create_by!(job: @job) so the contractor footer can show the share link. Set @viewer_payload = MeasurementViewerSerializer.new(@measurement).as_json and @public = false. ReportsController#show_public: resolve @report (already does find_by! + noindex), then @job = @report.job (guard nil -> 404/not-ready), @measurement = @job&.latest_measurement, @viewer_payload = serializer, @public = true; render 'reports/show'. Both actions render the SAME template; the @public flag gates contractor-only chrome. Do not add any new route to config/routes.rb (both /jobs/:id/report and /r/:token already exist).
- [ ] **Build the shared Hotwire report view + chrome partials reusing F-04 brand tokens**
  - app/views/reports/show.html.erb plus partials _report_header, _side_panel, _report_footer. Header: rooftrace-wordmark.svg (reuse the F-04 asset already used in _report_body), address, 'Generated <timestamp>'. The viewer mount: <div data-controller='viewer' data-viewer-measurement-value='<%= @viewer_payload.to_json %>' data-viewer-mapbox-token-value='<%= ENV["MAPBOX_PUBLIC_TOKEN"] %>' data-viewer-public-value='<%= @public %>'></div>. Side panel (Hotwire-rendered, STATIC for v1 — no React<->ERB two-way binding): total area, total perimeter, primary pitch as both ratio and degrees, overall source + confidence, a per-facet table (facet_id, area, pitch, source label, confidence) reusing the .report-confidence[data-level] / .report-source classes and confidence-gray tokens from report.css, low-confidence rows get the dashed-outline marker, and a features inventory table (label, count, confidence, verified). Footer: download buttons (PDF, JSON — link to the F-13/F-14 routes; render as disabled/'coming soon' if those routes are absent at build time, NEVER hardcode an F-NN string in the markup), 'Generate share link' / copyable /r/:token URL shown only when !@public, and the attribution line (NAIP, USGS 3DEP, Microsoft Building Footprints, Regrid, Mapbox, Nominatim) sourced from @viewer_payload[:attributions] with a static full-list fallback. Responsive: flex row that becomes flex-column with the side panel below the map at <800px (app/assets/stylesheets/viewer.css, brand tokens only, no new colors). Load the esbuild bundle only here via a per-page javascript_include_tag 'viewer' (not on form/status pages).
- [ ] **Create the Stimulus viewer_controller that mounts the React island**
  - app/javascript/controllers/viewer_controller.js (the FIRST and ONLY Stimulus controller F-12 adds). Register it in app/javascript/controllers/index.js (create the controllers manifest if the esbuild scaffold did not). static values = { measurement: Object, mapboxToken: String, public: Boolean }. connect() lazy-imports ./viewer/index and calls mountRoofViewer(this.element, this.measurementValue, this.mapboxTokenValue, this.publicValue). disconnect() unmounts (React 18 root.unmount) so Turbo navigations do not leak map/WebGL contexts — this is load-bearing for Turbo + deck.gl. Guard: if no measurement payload, render a static 'not available' message instead of mounting.
- [ ] **Build the React island entry, RoofViewer, and the pitch->gray color utility (test-first on the utility)**
  - app/javascript/viewer/index.tsx exports mountRoofViewer(el, measurement, token, isPublic) -> createRoot(el).render(<RoofViewer .../>); return the root for unmount. utils/colorByPitch.ts: pure function pitch_ratio (rise/12) -> RGBA tuple interpolating the brand confidence grays (low pitch ~ light gray #9CA3AF, high pitch ~ dark gray #374151), with explicit documented bucket boundaries (0-2/12 lightest ... >=10/12 darkest) since the spec leaves the scale to this feature; read the gray hex values from a small constants module mirroring brand.css (NOT hardcoded ad-hoc). utils/confidenceLabel.ts: 0-1 -> 'high'|'medium'|'low' matching report.css thresholds. RoofViewer.tsx: holds local React state (selectedFacetId, hoverInfo, showLidar); composes <DeckGL> + MapLibre via @deck.gl/mapbox interleaved layers; uses useMemo for layer data keyed on measurement to avoid re-renders. Write Jest/RTL specs FIRST for colorByPitch and confidenceLabel (pure, no DOM/WebGL) — these are the unit tests the spec demands and they need no GPU.
- [ ] **Implement the deck.gl layers: flat FacetLayer (PolygonLayer), FeatureLayer (IconLayer), and the LiDAR PointCloudLayer toggle**
  - layers/FacetLayer.ts: deck.gl PolygonLayer, getPolygon = facet.vertices (already WGS84 [lon,lat] — DO NOT look for vertices_wgs84), extruded:false getElevation:0 (ADR-013 fixes flat for v1), getFillColor = colorByPitch(facet.pitch_ratio) with reduced alpha, getLineColor dashed/lighter for confidence<0.6 (the low-confidence visual marker), pickable, onHover sets {area_sq_ft, pitch_ratio, source, confidence} tooltip, onClick sets selectedFacetId. layers/FeatureLayer.ts: IconLayer; because Feature carries only bbox_norm (image-space, NO geographic center), v1 anchors all feature pins at a single point near the roof centroid (computed from outline/footprint bounds) with a small fan-out, hover shows {label, confidence, verified}; document in the implementation notes that precise feature geolocation requires the orchestrator to emit feature lon/lat (flag as a cross-cutting follow-up, do NOT silently fake per-feature coordinates). layers/PointCloudLayer.ts: only constructed when measurement.source includes lidar AND a point reference is present; for v1, since the Measurement row does not expose a browser-fetchable point array (point_array_ref is a Spaces cache key, not a signed URL, and minting one is out of F-12 scope), render the toggle DISABLED with an explanatory tooltip rather than fetching — document this scope cut. Tooltips rendered as a plain absolutely-positioned div (touch-friendly: also shown on tap/click, not hover-only).
- [ ] **Implement honest-uncertainty UX end-to-end and the public-vs-contractor affordance differences**
  - Every measurement number in the side panel carries its source label ('from LiDAR'/'from satellite imagery'/'from on-site capture' mapped from the GeometrySource enum) and a confidence indicator in muted gray (never stoplight, never hidden). Low-confidence facets: dashed outline both in the map (FacetLayer line) and the side-panel row. Map tooltips include source + confidence. Public view (@public true): no 'Generate share link' control, no contractor-only controls; identical header/map/side-panel/footer/attribution; X-Robots-Tag already set by the controller. Verify the same React bundle runs in both contexts (no auth-dependent fetch — the payload is baked into the data attribute, so the unauthenticated public page needs zero API access).
- [ ] **Add the public-share request/system spec and the mobile-viewport spec**
  - spec/requests/reports_spec.rb (or system): GET /r/:bad_token -> 404 (head :not_found, no login redirect); GET /r/:valid_token -> 200, response header X-Robots-Tag == 'noindex', no login redirect; the rendered HTML contains the viewer div with a measurement payload and does NOT contain the 'Generate share link' control. spec/system: at 600px and 799px viewport the side panel stacks below the map; at 1024px it sits beside the map. Assert a Report with a nil job, or a job with no measurement, renders the not-ready state (no 500).
- [ ] **Add the bundle-size guard and wire MAPBOX_PUBLIC_TOKEN config**
  - Add an npm/CI check (script in package.json + an assertion runnable in CI, e.g. node esbuild then gzip-size) asserting app/assets/builds/viewer.js gzipped < 1,000,000 bytes; fail loudly if exceeded (prune to @deck.gl/layers + @deck.gl/core + @deck.gl/mapbox only, never @deck.gl/all). Add config/initializers presence handling for MAPBOX_PUBLIC_TOKEN following the repo's fail-fast-at-boot convention (raise in production, warn in dev/test) — reuse the existing initializer pattern in config/initializers/pipeline_schema.rb. Document MAPBOX_PUBLIC_TOKEN in ops/.env.example and ops README. If the token is blank the viewer falls back to a neutral basemap style and shows a small notice rather than a blank map.
- [ ] **Run the full gate and record implementation notes + cross-cutting follow-ups**
  - Run yarn build, bundle exec rspec (the JS-tagged system specs need the JS driver + the real sidecar is NOT required for these view specs, but run bare per the DB convention — no DATABASE_* env vars), the Jest unit suite, bin/rubocop, bin/brakeman. Fill the feature spec's Implementation notes: chosen library versions, achieved gzip size, the THREE cross-cutting decisions to propagate (lazy Report creation + token resolution path locked in ADR-016; the viewer reads a baked-in serialized payload NOT an API endpoint so F-14 owns /api/v1/jobs/:id.json cleanly; feature pins lack geographic coordinates so the orchestrator should emit feature lon/lat in a future iteration), and the v1 scope cuts (flat facets per ADR-013, LiDAR toggle disabled pending a browser-fetchable point ref). Propagate the ADR-016 amendment and the orchestrator follow-up to ARCHITECTURE.md/ROADMAP per the 'amend at source' convention.

### Test strategy

Test-first where it pays: (1) Pure TypeScript units (Jest/RTL via the esbuild/node toolchain) for colorByPitch (pitch_ratio -> brand-gray RGBA with documented bucket boundaries) and confidenceLabel (0-1 -> high/medium/low) written BEFORE the layers — no WebGL needed. (2) RSpec service spec for MeasurementViewerSerializer round-tripping a factory Measurement: asserts every emitted field, primary_pitch_degrees derivation from predominant_pitch_ratio, bounds computation from vertices, and attribution flattening. (3) A contract spec asserting the factory's facets/features validate against the frozen PipelineSchema Facet/Feature $defs (prevents fixture drift from real orchestrator output). (4) Capybara system spec (:js) for the contractor viewer: page 200, viewer div mounts with a parseable measurement payload, side-panel numbers match the fixture, no console errors, responsive collapse at 600/799px vs 1024px. (5) Request/system spec for the public share: /r/:bad_token -> 404 no redirect; /r/:valid_token -> 200 + X-Robots-Tag noindex, no 'Generate share link' control, payload present; nil-job / no-measurement Report -> not-ready state not 500. (6) Bundle-size CI guard: gzipped app/assets/builds/viewer.js < 1,000,000 bytes. Run everything bare per CLAUDE.md (no DATABASE_* env vars); bin/rubocop + bin/brakeman gate. Visual regression is a manual reviewer check against the F-04 _demo scaffold for v1.

### Risks

- JS toolchain bootstrap from zero in a constrained window: package.json + esbuild + React + MapLibre + deck.gl + TypeScript all new alongside importmap-rails. Mitigation: use the Rails 8 javascript:install:esbuild scaffold verbatim, pin exact dep versions, build before writing much code. Risk of importmap/jsbundling coexistence confusion — keep importmap for Hotwire, esbuild only for the viewer bundle.
- Bundle size: maplibre-gl (~250KB gz) + deck.gl core+layers+mapbox (~300KB gz) + react (~45KB gz) is ~600KB gz before app code — close to the 1MB ceiling. Mitigation: import only @deck.gl/core,@deck.gl/layers,@deck.gl/mapbox,@deck.gl/react (never @deck.gl/all), no helper libs, esbuild --minify; CI gzip guard fails loudly.
- Feature-pin geolocation gap (CONFIRMED real): Feature carries only bbox_norm (image-space [0,1] against the satellite tile) with no geographic center, and the orchestrator does not emit one. v1 anchors pins near the roof centroid and surfaces features mainly in the side-panel table; do NOT fabricate per-feature lon/lat. Propose orchestrator emitting feature lon/lat as a cross-cutting follow-up.
- LiDAR PointCloudLayer: the Measurement row exposes point_array_ref only as a Spaces cache key (not a browser-fetchable signed URL), and minting one is out of F-12 scope. v1 ships the toggle DISABLED with an explanatory notice rather than a half-working fetch. Documented scope cut.
- deck.gl + MapLibre + Turbo lifecycle leaks: Turbo navigations that don't unmount React leak WebGL contexts and map instances. Mitigation: Stimulus disconnect() must root.unmount() and remove the map.
- Touch interactions: hover-only tooltips fail on mobile. Mitigation: tooltips also open on tap/click; map pan/zoom is native to MapLibre/deck.gl.
- All three input drafts invented non-existent fields (vertices_wgs84, facet.id, primary_pitch_degrees column, an /api/v1/jobs/:id endpoint owned by F-12). A builder following a draft literally would produce a broken serializer and a route that collides with F-14. The plan corrects each against the verified schema/ADRs; the builder must trust the frozen shapes here, not the drafts.
- System tests need a JS-capable Capybara driver (selenium-webdriver is present); headless Chrome must be available in CI. Pure-logic unit coverage (colorByPitch, confidenceLabel, serializer) is intentionally GPU-free so the core logic is tested without a browser.
- Visual-regression 'golden image' from the spec has no framework in-repo. Mitigation: treat visual regression as a manual reviewer check against the F-04 _demo scaffold for v1; do not block on Percy/Chromatic infra.

### Manual setup (human-gated)

- Provision MAPBOX_PUBLIC_TOKEN (Mapbox public access token scoped for Satellite/raster basemap tiles; free tier covers demo volume) in dev/test/CI/prod env. Add to ops/.env.example and /etc/rooftrace/.env on the droplet.
- Ensure headless Chrome + a working selenium-webdriver are available in the CI verify stage so the :js system specs run (the GitLab shell-executor runs specs inside docker run — confirm the image has Chrome).
- Node/yarn available in the build + CI image for jsbundling-rails esbuild (yarn install + yarn build); confirm the deploy build step (infra/deploy.sh / Dockerfile) runs the JS build so the viewer bundle is present in the release.
- Confirm the rooftrace-wordmark SVG assets delivered by F-04 (rooftrace-wordmark.svg / rooftrace-wordmark-onorange.svg) resolve via Propshaft on the report view.
- Cross-browser color-token spot check (Safari, Chrome, Firefox) per the feature spec's manual setup item.

### Open questions for the human

- Confirm the ADR-016 amendment locking lazy Report creation + token->report.job->latest_measurement resolution is acceptable to the F-13/F-14 owners before parallel build starts — this is the one decision that, if it diverges across the three surfaces, becomes a bug. (Recommended: lazy creation on the contractor page.)
- Confirm F-14 (not F-12) owns GET /api/v1/jobs/:id.json and GET /r/:token.json, and that F-12 baking the serialized payload into the HTML data attribute is the agreed approach (it must be, since F-12 and F-14 run in parallel with no interdependency).
- Accept the v1 scope cuts: flat facets (ADR-013 already fixes elevation 0; 3D extrusion is v1.5), feature pins anchored near roof centroid rather than precisely geolocated (orchestrator emits no feature lon/lat), and the LiDAR point-cloud toggle shipped disabled (no browser-fetchable point reference). Or: is emitting feature lon/lat + a signed point-array URL in the orchestrator worth pulling into this wave?
- Side panel is static ERB for v1 (no React->ERB facet-selection highlight sync). Confirm a click-to-highlight side-panel row is out of v1 scope (keeps the Hotwire/React boundary clean).
- Visual-regression tooling: accept a manual reviewer comparison against the F-04 _demo scaffold for v1, or stand up Percy/Chromatic? (Recommended: manual for v1.)
- Should the JSON/PDF download buttons render as disabled 'coming soon' if the F-13/F-14 routes are not yet merged at F-12 build time, or be omitted entirely until those land?
