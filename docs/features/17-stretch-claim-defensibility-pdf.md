# Feature: Stretch — Claim-defensibility PDF enhancements

**ID:** F-17 · **Roadmap piece:** F-17 · **Status:** Not started · **Type:** Stretch

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

## Implementation notes (filled in by the building agent)

> The agent implementing this feature records its implementation
> decisions and rationale here as it builds — chosen libraries/patterns
> within the architecture's constraints, trade-offs made, deviations
> from assumptions and why, and anything the next agent or the
> integrator needs to know. This section starts empty and is owned by
> the builder, not the planner. Cross-cutting discoveries that affect
> other features must also be propagated to ROADMAP.md or the
> architecture doc, not just left here.
