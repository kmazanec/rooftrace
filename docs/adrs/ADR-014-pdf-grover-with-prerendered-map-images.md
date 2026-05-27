# ADR-014: Compose PDF reports in Rails with Grover (Puppeteer) using sidecar-rendered map/3D images

**Status:** Accepted · **Date:** 2026-05-27 · **Stretch:** no
**Supersedes:** none · **Superseded by:** none

## Context

The brief requires "shareable links or PDFs with measurements,
annotations, and roof diagrams." The PDF is the
**claim-defensibility** artifact from the COMPANY.md design contract:
adjusters file it, contractors hand it to homeowners, it has to look
like a construction document (orange CompanyCam header, sober
measurements table, methodology footnote, signature line).

Composing this PDF requires two qualitatively different things:

- **Map / 3D visualization images** — a top-down map view with the
  roof polygon + facet outlines + feature pins, plus optionally a
  tilted 3D facet view. These are pixel-faithful to the interactive
  viewer (ADR-013) and need the same geospatial state to render
  identically.
- **Document layout** — fixed header with the wordmark, address
  block, methodology line, per-facet measurements table, features
  list, attribution footer. Pure typography + chrome.

The image part is *naturally* a job for headless Chrome — either via
the Python sidecar (using Playwright, which is already a sensible
dependency for SfM-related debugging) or via Rails-side Puppeteer
(via Grover). The document layout part is *naturally* a job for the
Rails view layer — ERB + print CSS gives us the templating ergonomics
and CompanyCam's brand assets are already in the Rails asset pipeline.

The previous draft of this ADR proposed Playwright rendering the
*entire* PDF in the sidecar (the full report HTML, including its
typography). The user pushed back: that puts presentation logic in
the wrong service, fragments the brand-asset story across two
services, and gives up Rails templating's natural fit for document
layout. The better split is **images in the sidecar, document in
Rails**.

## Options considered

**A. Sidecar pre-renders map/3D images → Rails composes the PDF
with Grover.** Python sidecar runs Playwright against a tiny
*headless viewer page* it serves internally, capturing PNG/SVG
screenshots of the map and (optional) 3D view at print resolution
(e.g., 1600×1200, 2x DPI). Rails view renders an ERB report
template (HTML + print CSS) with `<img>` tags pointing at the
sidecar-rendered images; Grover runs Puppeteer against this
rendered HTML to produce the PDF.
*Tradeoff:* two services involved, but each owns what it's best at;
brand assets and templating stay Rails-side; image rendering uses
the existing geospatial state in the sidecar.

**B. Grover renders the entire PDF, sidecar provides only the
geospatial result data.** Rails view embeds MapLibre via a static
HTML page, Grover-Puppeteer renders it. Skip the sidecar.
*Tradeoff:* the headless Puppeteer instance needs the Mapbox basemap
tiles + the geospatial state available client-side; works for v1
but couples PDF rendering to network calls Puppeteer must make
during render. Larger surface for "the PDF render flaked because a
tile fetch timed out."

**C. Playwright renders the whole PDF in the Python sidecar.**
Sidecar owns presentation too.
*Tradeoff:* simpler service boundary; gives up Rails templating
ergonomics; brand assets / typography mgmt awkward in the sidecar.

**D. Prawn (pure Ruby PDF DSL) composes the PDF.** No HTML; place
images and text on the page programmatically.
*Tradeoff:* full control over layout but every chrome element is
hand-coded; CSS-styled tables impossible; not the right fit for a
report-with-images shape.

**E. WeasyPrint (Python HTML-to-PDF).** Python-side, simpler than
Playwright.
*Tradeoff:* less faithful to modern CSS than headless Chrome;
loses the brand-asset alignment with Rails.

## Decision

**A — sidecar pre-renders map/3D images; Rails composes the final
PDF via Grover.** Specifically:

- **Sidecar** exposes a small internal endpoint
  `POST /pipeline/render-images` that takes the measurement result
  and returns one or more PNG images (top-down map view, optional
  3D oblique view) rendered via Playwright against a minimal
  headless viewer page the sidecar serves. Images are written to
  `rooftrace-artifacts/<job_id>/images/` in the DO Space (ADR-010).
- **Rails** has an `app/views/reports/show.pdf.erb` template (or a
  dedicated `ReportPdf` view object) that produces the full HTML
  report — header, address, methodology, facet table, features,
  attribution — with `<img>` tags pointing at the sidecar-rendered
  images.
- **Grover** runs Puppeteer against the rendered HTML to produce
  the PDF, written to `rooftrace-artifacts/<job_id>/report.pdf`.
- **Public share link** serves the PDF via signed URL (or public-read
  prefix per ADR-010).

## Rationale

This split puts each piece of the PDF in the service whose tools and
state it naturally lives next to. The map images need the geospatial
result and MapLibre's deterministic-render context — the sidecar already
has both. The document layout needs the brand assets, typography, and
templating ergonomics that Rails was designed for. Crossing those
once at the image boundary is a small, well-defined hop; mixing them
in one service forces a bad compromise on either presentation or
geospatial state.

The CTO defense lands cleanly: *"Construction-document chrome belongs
in the Rails view layer where the brand assets and typography
already live. The map screenshots come from the service that
generated the geospatial state — no need to re-acquire it. Grover
composes the two; the resulting PDF is byte-identical to the
in-browser report."*

Grover specifically (over WeasyPrint, over Prawn) because it's the
current Rails-community-recommended HTML-to-PDF gem, Puppeteer-backed
(handles modern CSS faithfully), and it fits the "report is a Rails
view" mental model the rest of the app uses.

## Tradeoffs & risks

- **Two-service hop per PDF.** Mitigation: image render is bounded
  (<5s); Grover Puppeteer pass is bounded (<3s); combined well
  inside the 5-min latency budget; the second hop is local Docker
  network only.
- **Puppeteer / headless Chrome image** in the Rails container is
  ~250 MB extra. Mitigation: acceptable; alternative is a third
  service which is worse.
- **Image render reproducibility** — Playwright headless Chrome on
  the sidecar must produce stable screenshots run-to-run. Mitigation:
  pin Playwright + Chrome versions in the sidecar Dockerfile;
  golden-image diff test in CI.
- **Brand asset duplication** — the print CSS for the PDF mostly
  overlaps with the web viewer's screen CSS. Mitigation: share a
  CSS file between the screen view (ADR-013's viewer + chrome) and
  the PDF view, with a print stylesheet adding page-break + sizing
  rules.
- **Map tile availability during render.** The sidecar's image
  render fetches Mapbox tiles via Playwright. Mitigation: tile
  fetches are bounded and rate-limited; on failure, retry once,
  then fall back to NAIP tiles for the basemap.

## Consequences for the build

- **Rails:**
  - `Gemfile`: add `grover` and (transitive) `puppeteer-ruby`.
  - `app/views/reports/show.pdf.erb` — the PDF template; references
    `@map_image_url`, `@oblique_image_url`, etc.
  - `app/controllers/reports_controller.rb#download` calls
    `ReportPdf.new(job).render` which orchestrates: sidecar image
    request → Grover compose → upload to Spaces → respond with
    signed URL.
  - Brand assets (CompanyCam-orange header, wordmark SVG) in
    `app/assets/images/brand/`.
  - Shared `app/assets/stylesheets/report.scss` used by both the
    screen view and the PDF template; `@media print` rules at the
    bottom handle page sizing.
- **Sidecar:**
  - `sidecar/render/headless_viewer.py` — small internal Flask/
    FastAPI page served on a non-public port; takes geospatial
    state via URL params and renders a minimal MapLibre viewer.
  - `sidecar/render/image_renderer.py` — Playwright wrapper that
    navigates to the headless viewer page and screenshots specific
    DOM elements; returns PNG bytes; uploads to Spaces.
  - `POST /pipeline/render-images` endpoint takes `{job_id,
    measurement}` and returns `{map_image_url, oblique_image_url}`.
- **PDF artifact** stored at
  `s3://rooftrace-artifacts/<job_id>/report.pdf`; public-read
  prefix for share-linked artifacts; signed URLs otherwise.
- **JSON export** (ADR-015 forthcoming) generated alongside the
  PDF from the same Rails service and stored next to it.
