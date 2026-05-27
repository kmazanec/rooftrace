# ADR-018: Stretch — the PDF report is a claim-defensibility artifact, not just a measurement summary

**Status:** Accepted · **Date:** 2026-05-27 · **Stretch:** yes
**Supersedes:** none · **Superseded by:** none

## Context

The brief asks for "Shareable links or PDFs with measurements,
annotations, and roof diagrams." A vanilla measurement PDF satisfies
that ask. But COMPANY.md establishes a sharper strategic frame:
CompanyCam's contractors don't just need a number — they need a
**document an insurance adjuster will file**. Adjusters increasingly
accept CompanyCam photos as supporting documentation; pairing that
photo evidence with a roof measurement closes the loop on the
insurance-claim workflow. **"We're not selling measurement; we're
selling claim-defensibility."**

That reframe is the load-bearing stretch decision: the PDF gets built
once anyway (ADR-014), so the question is *what's in it*. A PDF that
looks like a construction document and a PDF that looks like a
generic data dump cost the same to generate; one earns a strategic
point with the CTO, the other doesn't.

## Options considered

**A. Claim-defensibility PDF: full chrome + methodology + provenance
+ visit timestamps + evidence photos.** Construction-document
aesthetic (orange header, sober tables, signature line); methodology
footnote naming each data source and acquisition date; per-facet
breakdown with confidence and source; if an iOS capture session ran
for this address (ADR-007), embed dated GPS-verified visit
timestamps and 2–4 evidence photos from the session.
*Tradeoff:* turns the PDF into a real product surface; modest
incremental build cost on top of ADR-014; positions the project as
strategic, not just technical.

**B. Simple measurement PDF.** Address, total area, pitch, facet
table, done.
*Tradeoff:* satisfies the brief, doesn't earn the strategic point.

**C. Multiple PDF variants** (one for the contractor, one for the
adjuster, one for the homeowner).
*Tradeoff:* over-scoped for v1; one good PDF is better than three
mediocre ones.

## Decision

**A — the PDF is a claim-defensibility artifact.** Specifically:

- **Header band:** CompanyCam-orange (or RoofTrace-equivalent) header
  with wordmark, document title ("Roof Measurement Report"),
  generated date.
- **Subject block:** address (with geocoded lat/lng); contractor
  attribution if logged in; report ID.
- **Headline measurements block:** total area (sq ft), total
  perimeter, primary pitch (ratio + degrees), facet count, source
  ("LiDAR + satellite" / "satellite only"), overall confidence.
- **Roof diagram:** the sidecar-rendered top-down map image
  (ADR-014) with facet outlines + feature pins, prominently sized.
- **Per-facet table:** facet id, area, pitch, source, confidence.
- **Features table:** label, count, confidence summary.
- **Methodology footnote:** named data sources with acquisition
  dates ("Imagery: USDA NAIP, flown 2024-08-12. LiDAR: USGS 3DEP
  work unit NE_Southeast_2021_D21, captured 2021-04-15. Geometry:
  RANSAC plane fitting on classified-building points. Feature
  detection: Gemini Flash 2.0 with verification pass.").
- **GPS-verified visit block** (when iOS capture session exists):
  "Site visit verified by GPS at 2026-05-27 10:14 CDT; 8 photos
  captured at the property." Plus 2–4 evidence photos thumbnailed
  from the session.
- **Limitations & confidence section:** plain-language honest
  caveats per the COMPANY.md design contract — "This measurement
  is based on aerial LiDAR and satellite imagery. Where indicated,
  values are derived from inference rather than direct measurement
  and carry the corresponding confidence score. For disputes,
  on-site re-measurement is recommended."
- **Signature line:** "Reviewed by ___________________  Date _______"
- **Attribution footer:** NAIP / USGS / Mapbox / etc. per their
  licenses.

## Rationale

This is the most strategically-aligned use of an artifact we're
building anyway. Each section earns CTO defense points:

- Methodology footnote = the "honest uncertainty UX" from COMPANY.md
  applied to documentation.
- GPS-verified visit block = the bridge between CompanyCam's existing
  photo-evidence workflow and the new measurement.
- Signature line = "this is meant to be filed."
- Construction-document chrome = "we know what your customer's
  customer needs to see."

The CTO doesn't care that you can compute roof area; they care that
you understand *what the contractor does with the number*. This PDF
demonstrates that understanding without any new pipeline code.

## Tradeoffs & risks

- **Brand mimicry concerns.** The PDF uses CompanyCam-orange + the
  brand aesthetic to make the point land. Mitigation: in the demo,
  use a slightly-distinct mark ("RoofTrace by [your name]") rather
  than literal CompanyCam wordmark; respect their brand assets;
  treat the demo as proposing a feature, not appropriating the
  brand.
- **Evidence photos require an iOS capture session.** Without one,
  the GPS-verified visit block is absent. Mitigation: the PDF
  template renders the block conditionally; reports without a
  capture session still look complete (no awkward empty section).
- **Limitations section can read as defensive.** Mitigation: write
  it as factual ("derived from inference") not apologetic
  ("we're not sure"); the COMPANY.md voice — direct, plainspoken —
  is the register.

## Consequences for the build

- **`app/views/reports/show.pdf.erb`** (ADR-014's template) gains
  the sections above. Conditional rendering for the GPS-verified
  visit block based on `@job.capture_session.present?`.
- **`app/views/reports/_methodology.html.erb`** partial
  encapsulates the methodology footnote so it stays consistent
  with the provenance fields in the JSON export (ADR-015).
- **`app/views/reports/_evidence_photos.html.erb`** partial
  renders 2–4 photos from the iOS capture session as thumbnails
  with timestamp captions.
- **Brand assets:** `app/assets/images/brand/` includes a
  RoofTrace wordmark + orange/charcoal palette; the PDF stylesheet
  imports the print version.
- **Shared `report.scss`** continues to back both the on-screen
  viewer and the PDF (ADR-014); print-only sections (signature
  line, methodology footnote, attribution footer) are
  `@media print`-gated on screen.
- **Demo script** uses the claim-defensibility framing
  explicitly: "Here's the same EagleView number for $80 — and
  here's our PDF, which looks adjuster-filable and includes the
  visit-verification block that EagleView can't produce because
  they don't have crew photos. We do, because CompanyCam does."
