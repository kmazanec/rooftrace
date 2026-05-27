# Feature: PDF report generation (Grover + sidecar map images)

**ID:** F-13 · **Roadmap piece:** F-13 · **Status:** Not started

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
  - Roof diagram image (sidecar-rendered top-down map view with
    facets + features).
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
