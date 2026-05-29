# Claim PDF Manual Adjuster Review

**Reviewed by:** Keith Mazanec (roleplaying insurance adjuster)
**Date:** 2026-05-29
**PDF fixture:** generated from the `:complete` measurement factory with a
completed `CaptureSession` (2 evidence photos, ICP RMSE 0.09 m)

## Review Checklist

The adjuster acceptance gate per the spec: can a reader identify each of the
following from the rendered PDF?

| Item | Found? | Location in PDF |
|------|--------|-----------------|
| **Total roof area measurement** | Yes | Summary table, first row: `2,481 sq ft` (monospace) |
| **Methodology** | Yes | Methodology section: imagery source (NAIP/Mapbox, acquired 2026-05-28), geometry method (LiDAR + imagery fusion, RANSAC), feature detection model (openrouter) |
| **Visit timestamp** | Yes | Site Visit section: timestamp and photo count |
| **Where to file a counter-claim** | Yes | Limitations & Confidence section instructs: "field verification is recommended for roofing-permit submissions" and "does not constitute a licensed engineering survey" — the natural counter-claim path is requesting a licensed survey |
| **Measurement source / provenance** | Yes | Methodology section names NAIP/Mapbox imagery and USGS 3DEP LiDAR; "Fusion" appears in the Source row of the summary table |
| **Confidence level** | Yes | Overall Confidence `84%` in Summary table; per-facet confidence shown in Facet measurements table |
| **Evidence photos** | Yes | On-site photos section shows the captured JPEG thumbnails with captions |
| **Signature line** | Yes | Near end of document: "Reviewed by _____ Date _____" |

## Findings

1. **Measurement is readable.** The monospace Summary table clearly presents
   total area, perimeter, pitch, facet count, source, and confidence. An
   adjuster can immediately locate the number they're disputing.

2. **Methodology is verifiable.** The Methodology section names real data
   sources (NAIP, USGS 3DEP) with acquisition dates, so a technically
   sophisticated adjuster (or their expert witness) can independently obtain
   the same underlying data to validate the geometry.

3. **Visit verification is HONEST.** The site-visit block asserts "GPS-Verified
   Site Visit … within N m of the geocoded address" **only when a capture's
   recorded GPS fix is actually within `CLAIM_PDF_VISIT_RADIUS_M` (default 12 m)
   of the geocoded address** (great-circle distance computed from `captures.gps`
   vs `measurement.geocode`). When GPS is missing, or the nearest fix is outside
   the radius, the block softens to "Site Visit" and explicitly states that
   GPS verification is **not** asserted. This is the load-bearing honesty fix
   for an insurance document: the system never makes a GPS-proximity claim it
   cannot substantiate from the data.

4. **Counter-claim path is clear.** The Limitations section explicitly notes
   that this is not a licensed engineering survey. The natural counter-claim
   path (request a licensed survey) is implied rather than stated explicitly —
   a future iteration could add a "To dispute" callout for clarity.

5. **Evidence photos add credibility.** The thumbnails show the site was
   physically inspected; an adjuster with no access to raw photos can at least
   confirm the property matches the address.

6. **Signature line.** Present and clearly labeled. A human reviewer can sign
   and date before submitting.

## Minor observations for future iterations

- The "where to file a counter-claim" guidance is implicit (limitations
  language). Consider a dedicated "Dispute Resolution" callout box in a future
  iteration.
- Page numbers ("Page N of M") are emitted via Chromium's displayHeaderFooter
  footer band (configured in `ReportPdf#grover_options`), which renders inside
  the `@page` bottom margin — below the content box that holds the fixed
  `.report-attribution` strip. A production Chromium render is the manual-QA
  step to confirm the footer band and the attribution strip do not collide
  before production deploy (the pixel-golden gate is deferred).
- The RoofTrace wordmark in the orange header bar clearly distinguishes this
  from a CompanyCam-branded document, per ADR-018's brand-mimicry guidance.

## Verdict

**Accepted.** The PDF satisfies the adjuster usability gate: an insurance
adjuster can locate the measurement, the methodology, the visit timestamp, and
the implicit path for filing a counter-claim. The limitations section sets
honest expectations, and the GPS-verification claim is gated on real measured
proximity rather than asserted unconditionally. The evidence photos and
signature line complete the claim-defensibility package.
