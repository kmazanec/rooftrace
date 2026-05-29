# Feature: Stretch — Claim-defensibility PDF enhancements

**ID:** F-17 · **Roadmap piece:** F-17 · **Status:** Planned (iteration `wave5-stretches`) · **Type:** Stretch

## Description

Extends the baseline PDF report (F-13) to be an
**adjuster-filable insurance supplement** per
[ADR-018](../adrs/ADR-018-stretch-insurance-claim-pdf.md). The PDF
ships as a construction-document-aesthetic artifact with methodology
footnote (named data sources + acquisition dates), GPS-verified
site-visit block (when an iOS session exists, from F-16), 2–4
evidence photos thumbnailed from the iOS capture session,
limitations & confidence section, and a signature line.

The strategic reframe: *we're not selling measurement; we're selling
claim-defensibility.* This is the architectural framing that earns
the CTO's strategic interest, not just their technical respect.

## How it fits the roadmap

Wave 5 — first stretch. Depends on baseline PDF (F-13) and iOS
integration (F-16). Off the critical path; parallel with F-18 (AR
overlay stretch).

## Dependencies (must exist before this starts)

- **F-04 Brand assets + stylesheet** — extends the F-04 print
  stylesheet with claim-document-specific sections.
- **F-13 PDF report generation** — extends the baseline PDF
  template.
- **F-16 iOS capture ingest + ICP fusion** — provides the visit
  timestamps + evidence photos for the visit-verified block (when
  available).

## Unblocks (what waits on this)

- **None** — terminal stretch.

## Acceptance criteria

- **PDF sections** (in addition to F-13 baseline content), per ADR-018:
  - **Methodology footnote** at the bottom of the first page,
    naming each data source and its acquisition date:
    *"Imagery: USDA NAIP, flown 2024-08-12. LiDAR: USGS 3DEP work
    unit NE_Southeast_2021_D21, captured 2021-04-15. Geometry:
    RANSAC plane fitting on classified-building points. Feature
    detection: Gemini Flash 2.0 with verification pass. On-site
    capture: ARKit world-mesh + LiDAR depth, ICP-aligned RMSE
    0.09 m."* The text is generated from the `provenance` fields
    in the `Measurement`, not hard-coded.
  - **GPS-verified site-visit block** (rendered only when a
    completed CaptureSession exists for the job): *"Site visit
    verified by GPS at 2026-05-27 10:14 CDT; 8 photos captured at
    the property (within 12 m of geocoded address)."*
  - **Evidence photos block** (when CaptureSession exists): 2–4
    photos thumbnailed (sidecar-pre-rendered to consistent size +
    aspect), with caption "Captured during site visit
    YYYY-MM-DD HH:MM".
  - **Limitations & confidence section**: a plain-language
    paragraph per the COMPANY.md voice rules; uses provenance-
    derived facts not boilerplate.
  - **Signature line**: "Reviewed by ___________________
    Date _______" placed near the end of the document.
  - **Construction-document chrome**: orange header bar with
    wordmark (using F-04 brand tokens), monospace measurements
    table, page numbers ("Page 1 of N").
- **Conditional rendering:** sections that require iOS data render
  cleanly when no CaptureSession exists; no awkward empty blocks
  or "N/A" placeholders.
- **Brand mark distinction:** the PDF uses the RoofTrace wordmark
  from F-04, *not* the literal CompanyCam wordmark, per the ADR's
  brand-mimicry-concerns guidance.
- **Reproducibility:** generating the same job's PDF twice
  produces a byte-identical document (modulo timestamps in the
  generated_at footer); critical for evidence-package
  reproducibility.
- **Adjuster usability test:** an actual insurance adjuster (or
  someone roleplaying one) can read the PDF and identify: the
  measurement, the methodology, the visit timestamp, and where
  to file a counter-claim if they disagree. Document the
  manual-test outcome in the writeup.

## Testing requirements

- **Visual regression test:** golden-image diff of the rendered PDF
  on a fixture measurement with iOS capture, and one without —
  both must pass.
- **Conditional-rendering test:** asserts the visit-verified block
  appears when CaptureSession exists and is absent when not (no
  empty placeholder).
- **Methodology-text-generation test:** asserts the methodology
  footnote text contains the provenance fields from the
  Measurement (acquisition dates, model versions).
- **Manual adjuster review:** documented in the writeup. Not
  automatable; counts as a deliverable acceptance gate.

## Manual setup required

- **No new external dependencies** — extends F-04 brand assets and
  F-13 PDF generation.
- **Manual review by an actual insurance adjuster** (or a
  knowledgeable roleplayer) for one fixture PDF; document outcome
  in `docs/CLAIM_PDF_REVIEW.md`.

## Build plan (approved)

> Planned by the plan-iteration step for the `wave5-stretches` iteration;
> consumed by the build step. Model tier: **sonnet** (Rails
> views/CSS/PORO over existing PDF infrastructure). Shared contracts are
> frozen in `docs/BUILD-PLAN.md` — this feature builds against them.

**Approach:** Extend the existing PDF (`ReportPdf` + `show.pdf.erb` +
`report.css` `@media print`) with claim-document sections via conditional
ERB partials and print CSS only — no new pipeline code on the critical
path. Methodology footnote, limitations paragraph, and the GPS-verified
visit block are **generated from `Measurement.provenance`** and
`CaptureSession` fields, never hardcoded. The evidence-photo block is
built around the **frozen on-site-visualization seam** (see
`docs/BUILD-PLAN.md`): the PDF must not read `uploads/` directly (no
minter; non-reproducible under Grover), so a new sidecar
`render-evidence-thumbnails` endpoint reads `uploads/` photos and writes
sign-able thumbnails to `artifacts/<job_id>/evidence/`. F-18 later fills
the same seam with projected composites. Brand uses the RoofTrace
wordmark; orange confined to the header bar.

- [ ] **Freeze the evidence-thumbnail source.** Add sidecar
  `POST /pipeline/render-evidence-thumbnails` (reads `uploads/` via
  `storage.get_bytes`, pillow-resizes to a fixed box, EXIF-stripped +
  fixed encode for byte-stability, writes `artifacts/<job_id>/evidence/<seq>.jpg`).
  Pydantic req/resp in `sidecar/contracts/pipeline.py`; part of the
  merged `pipeline_schema` **0.4.0** bump (see manifest barrier).
- [ ] **Add `SidecarClient#render_evidence_thumbnails(job_id:, photos:)`**
  (+ `EVIDENCE_THUMBNAILS_TIMEOUT_SECONDS`), following `render_images`.
  `ReportPdf` mints refs via `ArtifactUrlMinter`. On `SidecarClient::Error`,
  degrade: omit the evidence block (never 5xx, never empty block),
  mirroring `map_image_url_for`.
- [ ] **Build the methodology generator** `app/services/report_methodology.rb`
  (PORO, `ReportMethodology.call(measurement) -> [String]`). Compose from
  provenance: imagery source + `retrieved_at.imagery`; LiDAR
  `lidar_work_unit{name,year,quality_level}` + `retrieved_at.lidar`;
  geometry source; detector + `sam2_backend`; on-site sentence **only**
  when `fusion_icp_rmse_m` present. Must handle partial provenance
  (imagery-only omits the LiDAR + on-site sentences, no `N/A`).
- [ ] **Replace the hardcoded methodology `<p>`** in `show.pdf.erb` with a
  `_methodology.html.erb` partial driven by the generator.
- [ ] **GPS-verified visit block** `_visit_verification.html.erb`,
  rendered only when a completed `CaptureSession` exists (timestamp,
  photo count, within-N-m-of-geocode line). **N = `12 m`, env-configurable
  via `CLAIM_PDF_VISIT_RADIUS_M`.**
- [ ] **Evidence-photo block** `_evidence_photos.html.erb` around the
  **frozen seam**: consumes an ordered `[{image_url, caption, kind}]`
  array, cap 4; kind-agnostic (renders `thumbnail` today, `composite`
  when F-18 fills it). `ReportPdf` builds the list (prefer
  `artifacts/<job_id>/projected/` composites ordered by `pose_confidence`
  desc, else `evidence/` thumbnails ordered by `sequence_index`).
- [ ] **Signature line + page-number chrome.** Reuse the existing
  print-only `.report-signature-block`; add page numbers via Grover
  `displayHeaderFooter` + `footerTemplate` **(decided)** — reconcile the
  existing fixed `.report-attribution` footer into / below the page footer
  so they don't collide (the golden catches it).
- [ ] **Limitations & confidence section** `_limitations.html.erb`,
  provenance-derived, COMPANY.md voice (factual not apologetic).
- [ ] **Extend `report.css` `@media print`** for the new section classes
  (consume `var(--color-brand-*)` tokens; do not redefine them).
- [ ] **Wire assigns** through `ReportPdf#render_html`.
- [ ] **Fixtures + golden PDFs** under `spec/fixtures/pdfs/` (one with
  iOS capture, one without), offline-deterministic (real sidecar in
  local-root mode or stubbed thumbnails).
- [ ] **Test suite:** visual-regression golden (both fixtures);
  conditional-rendering (visit + evidence blocks present iff
  `CaptureSession`, absent with no placeholder); methodology-text-generation
  unit (full vs imagery-only provenance); reproducibility (two renders
  byte-identical modulo `generated_at`); evidence-seam (thumbnails order
  by sequence; simulated composites replace + order by `pose_confidence`);
  sidecar pytest for `render-evidence-thumbnails` (byte-stable, 422/409);
  `pipeline_schema` 0.4.0 drift spec.
- [ ] **Author `docs/CLAIM_PDF_REVIEW.md`** — manual adjuster review
  (deliverable acceptance gate).

**Risks:** Grover reproducibility (page numbers, AA, fonts) beyond
`generated_at`; page-footer vs `.report-attribution` collision; the
`uploads/` read gap (resolved by the sidecar-prerender decision, but adds
a degradable round-trip); partial provenance producing empty fragments;
**`pipeline_schema` 0.4.0 collision with F-18** — both bump it, so the
manifest merges both deltas into one barrier commit; brand mimicry
(RoofTrace mark, not CompanyCam).

**Decisions** (resolved by Keith — see
`docs/BUILD-PLAN-wave5-stretches.md` "Resolved decisions"): one merged
`pipeline_schema` 0.4.0 barrier; Grover `footerTemplate` for page numbers
(reconcile the attribution footer); visit radius `12 m` via
`CLAIM_PDF_VISIT_RADIUS_M`.

## Implementation notes (filled in by the building agent)

> The agent implementing this feature records its implementation
> decisions and rationale here as it builds — chosen libraries/patterns
> within the architecture's constraints, trade-offs made, deviations
> from assumptions and why, and anything the next agent or the
> integrator needs to know. This section starts empty and is owned by
> the builder, not the planner. Cross-cutting discoveries that affect
> other features must also be propagated to ROADMAP.md or the
> architecture doc, not just left here.
