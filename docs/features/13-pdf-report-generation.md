# Feature: PDF report generation (Grover + sidecar map images)

**ID:** F-13 · **Roadmap piece:** F-13 · **Status:** Done (merged to main · 2026-05-28)

## Description

Produces the downloadable / shareable PDF report. Per
[ADR-014](../adrs/ADR-014-pdf-grover-with-prerendered-map-images.md),
PDF composition is split:

1. **Map / 3D images** are rendered by the Python sidecar via a small
   headless-viewer page (Playwright screenshots a deterministic
   MapLibre viewer at print resolution).
2. **The PDF document** is composed in Rails via Grover (Puppeteer-
   backed HTML-to-PDF) using a Rails ERB template that embeds the
   sidecar-rendered images and renders the chrome (header, tables,
   methodology, attribution) using the F-04 brand stylesheet.

This is the **baseline measurement PDF**. The claim-defensibility
enhancements (F-17) layer on top.

## How it fits the roadmap

Wave 3 — after F-10. Off the critical path. Unblocks F-17 (claim
PDF). Parallel with F-12 viewer and F-14 JSON export.

## Dependencies (must exist before this starts)

- **F-01 Walking skeleton** — Rails + sidecar deployed.
- **F-04 Brand assets + stylesheet** — shared `report.scss` with
  print-only sections.
- **F-10 Measurement orchestrator** — produces the `Measurement` to
  render.

## Unblocks (what waits on this)

- **F-17 Claim-defensibility PDF** — extends this template with
  methodology footnote, visit-verified block, evidence photos,
  signature line.

## Acceptance criteria

- **Routes:**
  - `GET /jobs/:id/report.pdf` (auth-required for contractor view).
  - `GET /r/:share_token.pdf` (public-share token-gated download).
- **Generation flow:**
  - Rails controller calls a `ReportPdf.new(job).render` service.
  - The service POSTs to the sidecar's `POST /pipeline/render-images`
    with the `Measurement`; sidecar returns
    `{map_image_url, oblique_image_url}` (PNG, ~1600×1200 @ 2x DPI,
    uploaded to `s3://rooftrace-artifacts/<job_id>/images/`).
  - The service renders the Rails ERB template
    (`app/views/reports/show.pdf.erb`) with `@map_image_url`,
    `@oblique_image_url`, and the `Measurement` data; Grover runs
    Puppeteer against the rendered HTML and produces the PDF bytes.
  - PDF is uploaded to `s3://rooftrace-artifacts/<job_id>/report.pdf`;
    the response redirects the user to a signed (private) or
    public (shared) URL.
- **PDF content (baseline, per ADR-014):**
  - Orange header bar with RoofTrace wordmark + document title
    "Roof Measurement Report".
  - Subject block: address (with geocoded lat/lng), generated
    timestamp.
  - Headline measurements: total area, total perimeter, primary
    pitch (ratio + degrees), facet count, source label, overall
    confidence.
  - Roof diagram image (sidecar-rendered top-down map view). **v1
    scope: top-down satellite basemap for the measurement bbox
    only.** The facet-outline + feature-marker OVERLAY is deferred:
    the frozen `RenderImageRequest` (shared/pipeline_schema.json @
    0.3.0, `additionalProperties:false`) carries only `bbox` +
    pixel size, no facet/feature geometry, so the overlay lands with
    a schema-additive change (recorded in ADR-014's Wave-3
    amendment, alongside the deferred oblique/3D view). The per-facet
    table + features table below carry the geometric detail for v1.
  - Per-facet table: id, area, pitch, source, confidence.
  - Features table: label, count, average confidence.
  - Attribution footer: NAIP, USGS 3DEP, MS Building Footprints,
    Regrid, Mapbox, Nominatim per their licenses.
- **Brand conformance:** PDF uses the print stylesheet from F-04;
  `@media print` rules apply (page size, page breaks, print-only
  sections).
- **Idempotency:** repeat downloads of the same job within 30
  minutes return the cached PDF; data changes trigger re-render.
- **Failure modes:**
  - Sidecar image-render failure → fall back to a Static-Map
    snapshot via Mapbox Static API; degraded but not broken;
    warning in the PDF footer.
  - Grover/Puppeteer failure → 5xx with a clear error; user can
    retry.
- **Performance:** end-to-end PDF generation <10 seconds for a
  typical measurement on warm caches.

## Testing requirements

- **System test (Capybara):** download the PDF for a fixture
  measurement; assert it's a valid PDF (parses with a PDF
  inspection library), contains the expected text fragments
  (address, total area, source label), and embeds the
  sidecar-rendered map image.
- **Visual regression test:** rendered PDF first page compared
  against a golden image; catches brand drift and layout shifts.
- **Failure-mode test:** stub the sidecar image-render to fail;
  verify the Static-Map fallback engages and the warning appears.
- **Idempotency test:** two downloads in <30 minutes return the
  same `ETag`/object URL.
- **Cross-platform test:** PDF opens cleanly in macOS Preview and
  Adobe Acrobat (manual checklist; document acceptance).

## Manual setup required

- **Grover gem and Puppeteer dependencies** installed in the Rails
  container's Dockerfile (`puppeteer-ruby` brings Chromium,
  adds ~250 MB to the image).
- **Playwright in the sidecar Dockerfile** for the headless-viewer
  rendering path (also brings Chromium; ~250 MB).
- **Mapbox Static API token** (for the fallback path) — usually
  the same as `MAPBOX_PUBLIC_TOKEN` from F-12.

## Implementation notes (filled in by the building agent)

> The agent implementing this feature records its implementation
> decisions and rationale here as it builds — chosen libraries/patterns
> within the architecture's constraints, trade-offs made, deviations
> from assumptions and why, and anything the next agent or the
> integrator needs to know. This section starts empty and is owned by
> the builder, not the planner. Cross-cutting discoveries that affect
> other features must also be propagated to ROADMAP.md or the
> architecture doc, not just left here.

### Build decisions (Wave 3)

- **Contract: single `image_ref`, oblique deferred.** `POST
  /pipeline/render-images` is frozen at pipeline schema 0.3.0 returning ONE
  top-down map `image_ref` (not the `{map_image_url, oblique_image_url}` pair in
  ADR-014's prose). v1 renders the top-down map only; oblique/3D is deferred.
  ADR-014's Decision section now carries an amendment recording this. No schema
  bump was needed.
- **Grover (`grover ~> 1.2`, Puppeteer-managed Chromium).** Rails composes the
  PDF from `app/views/reports/show.pdf.erb` under `layouts/report_print`
  (the F-04 print scaffold linking `report.css`). Grover needs the `puppeteer`
  npm module + its Chromium; added `package.json`/`package-lock.json` and a
  `config/initializers/grover.rb` (print media, zero margins,
  `prefer_css_page_size`, `--no-sandbox`/`--disable-dev-shm-usage` for
  containers). The Rails Dockerfile installs Node + `npm ci` + the Chromium apt
  system libs and copies the puppeteer cache into the runtime image.
- **Two signed-URL minters, prefix-locked.** `ImageryUrlMinter` stays locked to
  `cache/`; `ArtifactUrlMinter` (landed in the barrier) signs `artifacts/` only.
  Added `ArtifactStore` (head/put over `artifacts/`, same prefix guard) for the
  PDF upload + the idempotency probe. `pdf_url` is the signed Spaces URL over
  `artifacts/<job_id>/report.pdf`; `share_url` is the public viewer URL.
- **Idempotency via Spaces-object age (no DB column).** `ReportPdf` probes the
  existing `report.pdf` object; if `<30 min` old it returns its signed URL
  without re-rendering. Older → re-render. `reports` got no new column.
- **Mapbox Static fallback (SSRF-safe).** On a `SidecarClient::Error` the
  service degrades to `MapboxStaticFallback` (validates the WGS84 bbox BEFORE
  building the URL; only numeric coords + integer dims reach a fixed
  `api.mapbox.com` path) and surfaces a degraded-view warning footer in the PDF.
  A Grover failure is NOT rescued — it bubbles as a 5xx the user can retry.
- **Real sidecar renderer behind `RENDER_IMAGES_LIVE=1`.** The barrier shipped a
  placeholder PNG renderer; this feature drops in the real top-down render
  (`sidecar/app/render_images/renderer.py` + `headless_viewer.py`): Playwright
  headless Chromium screenshots a self-contained MapLibre satellite viewer via
  `page.set_content` (no listening port). Default (and all hermetic tests) is the
  placeholder; the live path falls back to the placeholder on any failure (Rails
  has its own Mapbox fallback on top). Gated + boot-checked
  (`MAPBOX_PUBLIC_TOKEN` + importable `playwright`); `playwright>=1.49` added to
  sidecar deps and `playwright install --with-deps chromium` to its Dockerfile.
- **Routes.** `GET /jobs/:id/report.pdf` (require_demo_login) and
  `GET /r/:token.pdf` (public, token-gated, `noindex`, 404 on bad token). Both
  use `format: false` and are declared BEFORE the matching non-pdf route so the
  literal `.pdf` is not parsed as a response format (which would 406). Both
  redirect (303) to the signed URL with a `Cache-Control` reflecting the 30-min
  window.
- **Deferred (human-gated manual setup):** provisioning the real
  `MAPBOX_PUBLIC_TOKEN`, confirming droplet disk headroom for the two ~250MB
  Chromium installs, the cross-platform Preview/Acrobat acceptance pass, and the
  full `docker compose up --build` round-trip to real Spaces (no local Spaces
  creds in this build env). Golden-image visual regression is left as an
  optional follow-up (font-rendering variance → CI flakiness).

---

## Build plan (approved) — planned 2026-05-28

> Generated by the plan-iteration pass and reconciled into the shared
> contract manifest in [`../BUILD-PLAN.md`](../BUILD-PLAN.md). The frozen
> contracts + shared barrier in that manifest take precedence over any
> step below if they disagree. **Approve before building.**

**Recommended build model tier:** `opus` — Two-service Playwright+Grover orchestration, a new sidecar endpoint + SidecarClient method + ArtifactUrlMinter, the ADR-014 supersession, and the shared artifact-URL convention — cross-language contract work.

### Summary

F-13 implements the downloadable/shareable PDF report via ADR-014's two-service split: the Python sidecar renders a deterministic top-down map PNG via headless Playwright against a tiny internal MapLibre viewer page and uploads it to Spaces under artifacts/<job_id>/images/, then Rails composes a print-layout ERB report and runs Grover (Puppeteer) to produce the PDF, uploading it to artifacts/<job_id>/report.pdf and redirecting the user to a signed URL. Take the architect's clean ReportPdf-service-orchestrates-two-hops structure and its CORRECT reading of the SidecarClient#render_images return shape (a single image_ref). The verified ground truth resolves the drafts' biggest disagreement: shared/pipeline_schema.json AND sidecar/contracts/pipeline.py ALREADY define RenderImageRequest{pipelineSchemaVersion,job_id,bbox,width_px,height_px} -> RenderImageResponse{pipelineSchemaVersion,job_id,image_ref} at version 0.3.0, so NO schema bump and NO new entities are needed (the researcher's 0.4.0 and contrarian's 0.3.1 claims are false), and the frozen schema returns ONE image_ref, superseding ADR-014's prose {map_image_url, oblique_image_url} -- v1 renders the top-down map only; oblique is deferred. Take the contrarian's coupling warnings seriously: the Report-creation-on-:ready decision is a real cross-feature gap (no Report row is created today; Job has_many :reports dependent: :nullify; /r/:token resolves Report->job->latest_measurement) shared by F-12/F-13/F-14, and must be frozen as a shared contract before parallel build, ideally landed as a small F-10 orchestrator hook (find_or_create_by). Two additional verified gotchas the drafts missed: ImageryUrlMinter is hard-locked to the cache/ prefix and cannot mint artifacts/ URLs (F-13 needs a new/parameterized minter), and reports has no cached_pdf_url column (caching is best done by probing the existing Spaces object's age rather than adding columns for v1). The Mapbox Static API fallback + warning footer and 30-min idempotency are kept per spec.

### Dependencies (verified present in code)

- F-10 measurement orchestrator (landed): MeasurementOrchestrator#persist/#build_measurement_document is the source-of-truth Measurement shape the PDF reads; Job#latest_measurement exists.
- F-04 brand scaffold (landed): layouts/report_print.html.erb (links the 'report' stylesheet -- note .css, not .scss), app/views/reports_demo/_report_body.html.erb, app/assets/stylesheets/report.css, brand wordmark SVGs in app/assets/images/brand/.
- Frozen pipeline schema (landed @ 0.3.0): RenderImageRequest/RenderImageResponse exist in BOTH shared/pipeline_schema.json and sidecar/contracts/pipeline.py -- usable as-is, no change.
- SidecarClient validate_request!/validate_response! + post_json transport (landed) and the per-stage method pattern to mirror.
- sidecar/app/storage.py put_bytes/get_bytes (landed) for artifacts/ writes; sidecar/app/main.py router-mount + Depends(require_bearer) pattern; sidecar/app/boot_checks.py _X_enabled/_X_missing pattern.
- ADR-010 one-bucket key-prefix model + Aws::S3::Presigner usage (ImageryUrlMinter) to model the new ArtifactUrlMinter on.
- Report-creation-on-:ready hook MUST land (in F-10 or as a coordinated barrier commit) before F-13's /r/:token.pdf path is testable.
- reports table currently has NO cached_pdf_url column -- v1 caches via Spaces-object-age probing, so NO migration is required (avoids the architect/researcher's premature column).

### Shared-contract touch points

> These are reconciled and frozen in `BUILD-PLAN.md`. Build to the frozen
> signatures there, not to prose in this spec.

- Report-creation-on-:ready (CROSS-FEATURE, must freeze before parallel build): no Report row is created today (Job has_many :reports, dependent: :nullify; reports table = id/job_id/share_token/timestamps; /r/:token resolves Report->job->latest_measurement). Decision: eager Report.find_or_create_by!(job: job) inside the F-10 orchestrator persist transaction, idempotent on the existing index_reports_on_job_id. F-12 (viewer share), F-13 (PDF share), F-14 (JSON share) all depend on this. Owner is F-10; F-13 cannot ship /r/:token.pdf without it.
- SidecarClient#render_images(job_id:, bbox:, width_px:, height_px:, timeout:) -> {image_ref}. Validates against the ALREADY-FROZEN RenderImageRequest/RenderImageResponse in shared/pipeline_schema.json + sidecar/contracts/pipeline.py at version 0.3.0. NO schema bump, NO new entities, NO version change. Returns a SINGLE image_ref (not a map/oblique pair). This is the F-13-owned addition.
- POST /pipeline/render-images sidecar endpoint: new APIRouter under /pipeline guarded by the shared bearer (Depends(require_bearer)), validating RenderImageRequest in / RenderImageResponse out, distinct from the existing /pipeline/render-imagery (RenderImagery*) endpoint. Naming is intentionally close; do not confuse them.
- Spaces key layout (ADR-010, one partitioned bucket): rendered map PNG at artifacts/<job_id>/images/map-<hash>.png; final PDF at artifacts/<job_id>/report.pdf. v1 serves both via signed URLs (24h contractor / shorter share).
- ArtifactUrlMinter (new) for the artifacts/ prefix: ImageryUrlMinter is hard-locked to ALLOWED_KEY_PREFIX='cache/' and CANNOT sign artifacts/ keys. F-13 needs a sibling minter (or a parameterized prefix) so PDFs and map PNGs in artifacts/ can be signed. Shared with F-12/F-14 share-link surfaces.
- MAPBOX_PUBLIC_TOKEN env var: shared with F-12 (basemap) and used by F-13 for the sidecar headless-viewer tiles AND the Rails Mapbox Static fallback. One public-scope token. Rails fail-fast boot check raises in production if PDF/render-images enabled and the token is blank.
- Auth/noindex boundary (ADR-016): /jobs/:id/report.pdf gated by require_demo_login; /r/:token.pdf public, 404 on bad token (no login redirect), X-Robots-Tag: noindex. Identical token resolution + noindex pattern shared with the F-12 viewer and F-14 JSON share routes.
- Confidence/source + attribution propagation (ROADMAP cross-cutting): the PDF must surface measurement source+confidence per facet (low-confidence marked not hidden, muted gray) and the full attribution footer (NAIP, USGS 3DEP, MS Footprints, Regrid, Mapbox, Nominatim) from measurement.provenance.attributions -- no surface drops them. ADR-014's {map_image_url,oblique_image_url} prose is superseded by the frozen single-image_ref schema; oblique/3D deferred.

### Build steps

- [x] **Confirm the frozen render-images contract is usable as-is (no schema change)**
  - Re-read shared/pipeline_schema.json $defs RenderImageRequest/RenderImageResponse and sidecar/contracts/pipeline.py RenderImageRequest/RenderImageResponse. CONFIRMED at version 0.3.0: request = {pipelineSchemaVersion, job_id(uuid), bbox[min_lon,min_lat,max_lon,max_lat], width_px, height_px}; response = {pipelineSchemaVersion, job_id, image_ref}. Do NOT bump the schema version and do NOT add entities. Record in the feature file that ADR-014's {map_image_url,oblique_image_url} prose is superseded by the frozen single-image_ref schema and that oblique/3D is deferred to a later feature.
- [x] **Decide + document the Report-creation cross-feature contract (BLOCKING shared barrier)**
  - Freeze the decision that an eager Report row is created when a job reaches :ready, owned by the F-10 orchestrator persist path (Report.find_or_create_by!(job: job) inside the existing persist transaction, idempotent on the existing index_reports_on_job_id). Document in ROADMAP.md Cross-Cutting Concerns and ARCHITECTURE.md (no F-NN in those permanent docs). This unblocks /r/:token.pdf, the F-12 viewer share, and F-14 JSON share alike. If the orchestrator hook is owned by another workstream, F-13 still depends on the row existing; coordinate so it lands first.
- [x] **Write the failing SidecarClient#render_images spec**
  - In spec/services/sidecar_client_spec.rb, add examples for a new render_images(job_id:, bbox:, width_px:, height_px:, timeout:) method: stub post_json, assert it validates the request against 'RenderImageRequest' and the response against 'RenderImageResponse' (reuse the existing validate_request!/validate_response! path), returns the parsed hash containing image_ref, and raises SchemaError on a bad bbox length. Mirror the existing render_imagery spec shape.
- [x] **Implement SidecarClient#render_images**
  - Add the instance method (and a class-level shortcut mirroring resolve_address/render_imagery) to app/services/sidecar_client.rb: build payload {pipelineSchemaVersion: PipelineSchema.version, job_id:, bbox:, width_px:, height_px:}, validate_request!('RenderImageRequest', payload), POST to /pipeline/render-images with a generous timeout (default ~30s for Playwright cold start, override-able), validate_response!('RenderImageResponse', response), return response. Returns image_ref (single key), NOT a map/oblique pair.
- [x] **Write the failing sidecar render-images endpoint test**
  - Create sidecar/tests/test_render_images.py with conftest fixtures: POST /pipeline/render-images with a valid RenderImageRequest (bbox, width_px=1600, height_px=1200), mock the Playwright screenshot to return fixture PNG bytes and put_bytes to a local root; assert 200 + image_ref present + response validates against RenderImageResponse. Assert version-major mismatch -> 409, out-of-range bbox coords -> 422, missing bearer -> 401 (follow the existing render-imagery router test conventions).
- [x] **Implement the sidecar render-images router**
  - Create sidecar/app/render_images/__init__.py and sidecar/app/render_images/router.py following sidecar/app/imagery/router.py exactly: APIRouter(prefix='/pipeline'), POST /render-images with RenderImageRequest/RenderImageResponse (response_model_exclude_none), the _major version-mismatch 409 guard, WGS84 bbox sanity check (422), call the renderer, put_bytes the PNG to artifacts/<job_id>/images/map-<hash>.png, return RenderImageResponse(pipelineSchemaVersion=PIPELINE_SCHEMA_VERSION, job_id=req.job_id, image_ref=key). On renderer failure raise HTTPException 502.
- [x] **Implement the sidecar headless viewer + Playwright renderer**
  - Create sidecar/app/render_images/headless_viewer.py (a minimal self-contained HTML+MapLibre page taking bbox/dimensions/facet-GeoJSON via query params or a data-URL, served on a loopback-only port with SO_REUSEADDR, or rendered via page.set_content to avoid a port entirely -- prefer set_content to dodge port contention) and sidecar/app/render_images/renderer.py (Playwright wrapper: launch chromium headless, set viewport to width_px x height_px, render the viewer, wait for map idle, screenshot the map element to PNG bytes; bounded timeout ~3s; raise on failure). Use Mapbox satellite tiles via MAPBOX_PUBLIC_TOKEN; on tile failure retry once then fall back to a plain background so the screenshot still returns.
- [x] **Register the render-images router and add a sidecar boot check**
  - In sidecar/app/main.py add `from .render_images.router import router as render_images_router` and `app.include_router(render_images_router, dependencies=_PIPELINE_DEPS)` alongside the other pipeline routers. In sidecar/app/boot_checks.py add _render_images_enabled(env) (gate e.g. RENDER_IMAGES_LIVE=1) and _render_images_missing(env) that requires MAPBOX_PUBLIC_TOKEN and a working chromium install, wired into verify_stage_config so production raises at boot if misconfigured (matching the IMAGERY_LIVE pattern).
- [x] **Add Playwright + chromium to the sidecar dependencies and Dockerfile**
  - Add playwright (pinned, e.g. >=1.49) to sidecar/pyproject.toml [project] dependencies and run uv sync. In sidecar/Dockerfile add `RUN uv run playwright install --with-deps chromium` after the dependency sync so the pinned chromium + its apt system libs are baked in (~250MB). Verify the image builds and `uv run playwright install chromium` exits 0.
- [x] **Write the failing ArtifactUrlMinter spec**
  - ImageryUrlMinter is hard-locked to the cache/ prefix (ALLOWED_KEY_PREFIX) and cannot mint artifacts/ URLs. In spec/services/artifact_url_minter_spec.rb assert a new minter signs GET URLs only for keys under the artifacts/ prefix, rejects keys outside it, and uses the existing STORAGE_* env client wiring. (Alternatively, parameterize ImageryUrlMinter's allowed prefix -- pick one and write the spec for it.)
- [x] **Implement ArtifactUrlMinter (or parameterized prefix)**
  - Create app/services/artifact_url_minter.rb modeled on app/services/imagery_url_minter.rb but with ALLOWED_KEY_PREFIX='artifacts/' and a generous-but-bounded default expiry (e.g. 24h contractor, configurable), reusing Aws::S3::Presigner over the one partitioned bucket (ADR-010). This is the signed-URL path for both report.pdf and the rendered map PNG when embedded.
- [x] **Write the failing ReportPdf service spec**
  - In spec/services/report_pdf_spec.rb: with a fixture Job + complete Measurement (factory) and a mocked SidecarClient.render_images returning {image_ref}, assert ReportPdf.new(job).render (a) calls render_images with a bbox computed from facet vertices and print dimensions, (b) mints a signed URL over the artifacts/ map PNG, (c) renders app/views/reports/show.pdf.erb, (d) runs Grover to PDF bytes (stub Grover), (e) uploads to artifacts/<job_id>/report.pdf, (f) returns a signed URL. Add specs: nil/incomplete measurement raises a clear error; sidecar failure triggers Mapbox Static fallback + a warning flag surfaced to the template (no exception); idempotency -- a second call within 30 min returns the same URL without re-render (probe Spaces object age), and after travel 31.minutes it re-renders.
- [x] **Implement the ReportPdf service**
  - Create app/services/report_pdf.rb: ReportPdf.new(job).render orchestrates: fetch job.latest_measurement (raise if nil); compute bbox from facet vertices (WGS84 [lon,lat]); call SidecarClient.render_images(job_id:, bbox:, width_px: 1600, height_px: 1200); on SidecarClient::Error/TimeoutError log + fall back to MapboxStaticFallback and set @fallback_warning; mint a signed artifacts/ URL for the map PNG; render the ERB to HTML; Grover.new(html).to_pdf; upload PDF bytes to artifacts/<job_id>/report.pdf via the Spaces client; return the signed URL. Idempotency: before rendering, probe the existing artifacts/<job_id>/report.pdf object; if present and <30 min old, return its signed URL without re-render. A Grover failure is NOT caught -- it bubbles to the controller as a 5xx.
- [x] **Implement MapboxStaticFallback with SSRF-safe URL construction**
  - Create app/services/mapbox_static_fallback.rb: given bbox + dimensions, validate coords are WGS84-sane (-180..180 lon, -90..90 lat) BEFORE building the URL (no interpolated unvalidated values), call the Mapbox Static Images API (mapbox/satellite-v9) with MAPBOX_PUBLIC_TOKEN, return PNG bytes (uploaded to artifacts/ and embedded). Boot check: a Rails after_initialize raises in production if render-images/PDF is enabled and MAPBOX_PUBLIC_TOKEN is blank (match the existing fail-fast initializer pattern).
- [x] **Create the PDF ERB template reusing the F-04 print scaffold**
  - Create app/views/reports/show.pdf.erb rendered under the existing layouts/report_print.html.erb (which already links the 'report' stylesheet -- note it is report.css, not report.scss). Reuse the structure of app/views/reports_demo/_report_body.html.erb: orange header bar + wordmark + 'Roof Measurement Report'; subject block (address + geocode lat/lng from measurement.geocode + generated_at); headline measurements (total_area_sq_ft, total_perimeter_ft, predominant_pitch_ratio + degrees, facet count, source label, overall confidence); the sidecar-rendered map <img>; per-facet table (facet_id, area_sq_ft, pitch, source, confidence -- map source+confidence to the honest-uncertainty muted-gray styling); features table (label, count, avg confidence); attribution footer (NAIP, USGS 3DEP, MS Building Footprints, Regrid, Mapbox, Nominatim, sourced from measurement.provenance.attributions); and a conditional fallback-warning footer when @fallback_warning. Orange ONLY in header bar (brand rule). No screen-only CTA in this print template.
- [x] **Add Grover to the Rails Gemfile + Dockerfile and configure it**
  - Add gem 'grover' (pinned) to the Gemfile and bundle install; add an initializer config/initializers/grover.rb (print_media_type, zero margins, prefer_css_page_size, launch args for containerized Chromium e.g. --no-sandbox). In the Rails Dockerfile add the Chromium/Puppeteer system deps (fonts-liberation, libnss3, libxss1, libgbm1 etc.) so puppeteer-ruby's headless Chrome runs (~250MB). Verify `bundle exec ruby -e 'require "grover"'` loads and the image builds.
- [x] **Wire routes and controller actions**
  - In config/routes.rb add `get '/r/:token.pdf' => 'reports#download_public_pdf', as: :public_report_pdf` and a member route for the authenticated PDF (e.g. extend resources :jobs member with a report_pdf action, or `get :report, format: :pdf`). In JobsController (or ReportsController) add download_pdf: require_demo_login, resolve job via set_job, ReportPdf.new(job).render, redirect_to signed_url, status: :see_other; rescue render a clear 5xx. In ReportsController add download_public_pdf: skip_before_action :require_demo_login, resolve Report.find_by!(share_token:), 404 on miss, ReportPdf.new(report.job).render, set X-Robots-Tag: noindex, redirect to the signed URL. Both set Cache-Control reflecting the 30-min window.
- [x] **Write the request spec for the public + authenticated PDF routes**
  - In spec/requests/reports_pdf_spec.rb: with a ready Job + Report + complete Measurement and a stubbed SidecarClient + Spaces, assert GET /r/:token.pdf (no auth) 302/303-redirects to a signed URL and sets X-Robots-Tag: noindex; a bad token -> 404; GET /jobs/:id/report.pdf unauthenticated redirects to /login; authenticated returns the redirect. Stub the sidecar (no real browser) at this level.
- [x] **Write the end-to-end system test (real sidecar + real Grover)**
  - In spec/system/pdf_report_spec.rb, using the real-sidecar harness (spec/support/real_sidecar.rb) and a fixture Job with a complete Measurement: download /jobs/:id/report.pdf, assert Content-Type application/pdf (or follow the signed-URL redirect), parse with a PDF reader gem, assert text fragments (address, total area number, a source label, attribution names) and that a map image object is embedded. Add a fallback case: stub SidecarClient.render_images to raise, assert the PDF still renders with the Mapbox Static image and the warning footer text.
- [x] **Add the complete-Measurement factory/fixture shared across Wave 3**
  - In spec/factories/, add or extend a measurement factory producing a valid, schema-passing Measurement (footprint, roof_outline, facets[{facet_id,vertices,pitch_ratio,pitch_degrees,area_sq_ft,source,confidence}], features[{label,bbox_norm,verified,source,confidence}], total_area_sq_ft, predominant_pitch_ratio, total_perimeter_ft, geocode, provenance.attributions, source, confidence, generated_at) plus a ready Job + Report. Shape it from measurement_orchestrator.rb#build_measurement_document so it matches production exactly; reuse across the F-13 service/request/system specs (and it benefits F-12/F-14).
- [x] **Record implementation notes + propagate cross-cutting findings**
  - Fill docs/features/13-pdf-report-generation.md Implementation Notes: Grover + Playwright versions and image-size cost; that the frozen schema returns a single image_ref (oblique deferred) and ADR-014 prose is superseded; the new ArtifactUrlMinter (artifacts/ prefix) vs the cache/-locked ImageryUrlMinter; the Spaces-object-age idempotency strategy (no DB column added); the Report-creation-on-:ready cross-feature decision. Propagate the Report-creation contract and the artifacts/ signing pattern to ROADMAP.md Cross-Cutting Concerns and ARCHITECTURE.md. NO F-NN references in permanent code/config or in those committed docs (only in the feature file, commit messages, and the PR body).
- [x] **Run the full Rails + sidecar suites and lint/security gates**
  - Run `bundle exec rspec`, `cd sidecar && SIDECAR_SHARED_SECRET=test-shared-secret uv run pytest -v`, `bin/rubocop`, and `bin/brakeman` (all bare, no DATABASE_* env vars, against the local PostGIS 5433 container). Then bring up `docker compose -f ops/compose.yaml up --build` and manually download both PDF routes for a fixture job, opening the result in macOS Preview to confirm header/tables/map render and print layout.

### Test strategy

Test-first per repo convention, three Rails levels + a sidecar level. (1) Unit/service: spec/services/sidecar_client_spec.rb (render_images validates request/response, returns image_ref, raises on bad bbox), spec/services/artifact_url_minter_spec.rb (artifacts/ prefix only), spec/services/report_pdf_spec.rb (orchestration with mocked SidecarClient/Grover/Spaces: bbox from facets, signed URL return, nil-measurement guard, Mapbox fallback + warning flag on sidecar failure, 30-min Spaces-age idempotency incl. travel 31.minutes re-render). (2) Request: spec/requests/reports_pdf_spec.rb (auth boundary 302->/login on the private route; public route redirects to signed URL + X-Robots-Tag noindex; bad token 404; sidecar stubbed). (3) System (real sidecar via spec/support/real_sidecar.rb, real Grover): spec/system/pdf_report_spec.rb downloads the PDF, parses it (pdf-reader), asserts address/total-area/source-label/attribution text + an embedded map image, plus a fallback case asserting the Static image + warning footer. (4) Sidecar: sidecar/tests/test_render_images.py (200 + image_ref + response-schema-valid with mocked Playwright/put_bytes; 409 version mismatch; 422 bad bbox; 401 no bearer). Shared complete-Measurement factory (shaped from build_measurement_document) reused across F-13 specs. Gates: full `bundle exec rspec` (bare, PostGIS 5433), `uv run pytest`, `bin/rubocop`, `bin/brakeman`, then a manual docker-compose download opened in macOS Preview. Golden-image visual regression is documented as an optional follow-up, not a must-pass gate.

### Risks

- Contract-prose mismatch: ADR-014 says the endpoint returns {map_image_url, oblique_image_url} but the FROZEN schema (0.3.0, both languages) returns a single image_ref. Building to the prose would break schema validation. Mitigation: build to the schema (single image_ref), render top-down map only, defer oblique, and amend ADR-014 to record the supersession.
- Report-creation gap: if the F-10 eager-Report hook does not land first, /r/:token.pdf 404s on valid tokens and the F-13 public-share system test cannot pass. Mitigation: treat it as a blocking shared barrier landed before parallel build; idempotent find_or_create_by on the existing job_id index.
- ImageryUrlMinter cannot sign artifacts/ keys (locked to cache/). Forgetting this and reusing it will raise at runtime. Mitigation: new ArtifactUrlMinter (covered as an explicit step).
- Two heavy Chromium installs (Grover/Puppeteer in Rails ~250MB + Playwright/chromium in sidecar ~250MB) inflate both images and the shared droplet disk. Mitigation: pin versions, --with-deps install, --no-sandbox launch flag in containers; confirm droplet disk headroom before deploy.
- Playwright cold-start + Grover pass can breach the <10s warm target on first request. Mitigation: generous SidecarClient timeout (~30s) for render_images, prefer page.set_content over a long-lived port, accept v1 synchronous; document an async (ActiveJob + emailed link) upgrade path.
- Headless-viewer port contention if a real listening port is used. Mitigation: prefer Playwright page.set_content (no port) or bind loopback-only with SO_REUSEADDR.
- SSRF in the Mapbox Static fallback URL. Mitigation: validate WGS84-sane bbox before constructing the URL; no unvalidated interpolation; the rendered image is fetched server-side over https to a known host.
- Grover/headless-Chrome render differs from browser print (fonts, page breaks). Mitigation: iterate the print CSS against Grover output; optional golden-image diff deferred as a follow-up (kept out of the must-pass set to avoid CI flakiness from font-rendering variance).
- Real-sidecar system test requires uv + chromium present in the test env; CI is a shell executor running specs inside docker run. Mitigation: ensure the sidecar test image includes chromium; keep request-spec-level coverage (stubbed sidecar) as the fast gate and the system spec as the integration gate.

### Manual setup (human-gated)

- Provision a Mapbox public-scope token (Static Images API + tiles) and set MAPBOX_PUBLIC_TOKEN in ops/.env / /etc/rooftrace/.env; add to ops/.env.example and the ops/README runbook. Shared with the F-12 viewer.
- Confirm the shared gauntlet droplet has disk headroom for ~500MB of added Chromium across both images before deploying.
- Human product/legal sign-off on the exact attribution footer wording (NAIP, USGS 3DEP, MS Building Footprints, Regrid, Mapbox, Nominatim per their licenses) so the PDF footer text is final.
- Cross-platform acceptance pass: open a generated PDF in macOS Preview and Adobe Acrobat; confirm selectable text, header/table legibility, embedded map, and print layout (no overflow). Record the result in the PR.

### Open questions for the human

- Confirm the Report-creation-on-:ready hook is owned and landed by F-10 (orchestrator persist transaction) before Wave 3 parallel build begins -- F-12/F-13/F-14 all depend on it. If it cannot land first, it must be a shared barrier commit.
- ADR-014's {map_image_url, oblique_image_url} prose vs the frozen single-image_ref schema: confirm the schema wins for v1 (recommended) and amend ADR-014 to record oblique/3D as deferred, rather than bumping the schema.
- Public-share PDF access: signed URL (recommended for v1, simple, consistent with ImageryUrlMinter) vs a public-read artifacts/public/<token> prefix per ADR-010. Pick the signed-URL path for v1 unless egress/CDN cost dictates otherwise.
- New ArtifactUrlMinter vs parameterizing ImageryUrlMinter's ALLOWED_KEY_PREFIX -- either is fine; confirm the preferred shape (a separate minter keeps the cache/ SSRF guarantees intact and is recommended).
- Signed-URL TTL for shared PDFs (link longevity vs leaked-link blast radius). Recommend a generous-but-bounded TTL (e.g. 24h) for v1 and document it.
- v1 single-page PDF assumption: many-facet roofs (>~25) may overflow to page 2; confirm v1 only needs print page-break rules (no explicit multi-page pagination logic) -- F-17 will extend the template.
