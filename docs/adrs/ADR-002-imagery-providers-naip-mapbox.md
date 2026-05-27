# ADR-002: Use NAIP (AWS Open Data) for production imagery + Mapbox Satellite for demo polish

**Status:** Accepted · **Date:** 2026-05-27 · **Stretch:** no
**Supersedes:** none · **Superseded by:** none

## Context

The geometry architecture (ADR-001) consumes satellite/aerial imagery in
two distinct ways:

1. **As a measurement input** — orthorectified nadir imagery feeds the
   SAM2 outline refinement, the visual cross-check on the LiDAR-derived
   facets, and the VLM-based feature inference. This use needs imagery
   that is **legally re-usable**, georeferenced precisely, and
   high-enough-resolution to see chimneys and skylights (≤ ~30 cm GSD).
2. **As a UI background** — the interactive web viewer shows the roof
   model overlaid on satellite tiles for context. This use needs imagery
   that is **visually polished** (recent, color-balanced, seamless) more
   than it needs to be legally redistributable.

These two needs have different best answers, and conflating them either
makes the demo ugly (NAIP is older and less color-tuned than Mapbox) or
opens a TOS exposure (Google/Mapbox imagery for ML training is
contractually fraught).

Imagery options surveyed:

| Provider | GSD | Cost | Licensing fit | Notes |
|---|---|---|---|---|
| **NAIP** (USDA, via AWS Open Data) | 60 cm (→ 30 cm rolling out) | Free | **Public domain** | Slightly stale (~2-yr refresh); perfect georef; the only legally clean choice for ML/derivative work |
| **USGS HRO** | 7.5–30 cm | Free, public domain | Public domain | Coverage spotty — major metros only |
| **Mapbox Satellite** | ~30–60 cm | Free tier 50k tiles/mo | Terms allow derivative use in some contexts | Best free-tier visual quality for UI; verify license at quote time |
| **Google Maps Static** | ~15 cm urban US | Paid; restrictive | **TOS forbids ML training / derivative measurements** | Tolerated for prototypes, but cannot be the production answer |
| **Bing Maps Imagery** | ~30 cm typical | Free tier | Generous license | Workable backup |
| **Nearmap / Maxar / Planet** | 5–50 cm | Paid, expensive | Paid commercial | Out of budget for a 4-day demo |

The 4-day window forecloses the paid commercial providers and the brief's
"production quality" expectation forecloses leaning on Google's TOS.

## Options considered

**A. NAIP only.** Purist play: public domain for both ML and UI, no
third-party TOS surface, one provider to integrate.
*Tradeoff:* the demo looks visibly older and more washed-out than what
the CTO sees on Google Maps every day; some addresses have 2-year-old
imagery that doesn't show recent construction. Real risk that the demo
"feels" less impressive than the engineering deserves.

**B. NAIP for production work + Mapbox Satellite for the demo UI
background only.** Two providers, clear separation: NAIP is what the
pipeline measures from; Mapbox is what the user sees in the viewer
context.
*Tradeoff:* slight integration cost (two clients, two attribution
notices); the cleanest "I can defend this" story for a CTO.

**C. Mapbox-only end-to-end.** Faster integration, prettier everywhere.
*Tradeoff:* even where Mapbox's TOS permits ML use, leaning on a
commercial third party as the production imagery layer is a known
fragility; the candidate has to caveat it. The cost-at-scale story
("what happens at 100k contractors × 10 measurements each?") is
unanswerable on this option.

## Decision

**B. NAIP via AWS Open Data for all measurement/ML use; Mapbox Satellite
tiles for the web viewer's basemap UI only.** Mapbox's free tier covers
the demo and any near-term pilot; if the product ships, the basemap is a
swappable layer.

## Rationale

Separating the *measurement input* from the *UI backdrop* lets each
choice win on its own merits. NAIP is the only imagery in the survey
that is unambiguously legal to feed an ML pipeline at any scale, has
correct georeferencing, and is free forever — which is exactly the
defensible-at-scale story CompanyCam's "bundle into the seat price" 
thesis demands. Mapbox in the UI is a one-line basemap configuration
that makes the demo look like the rest of the contractor's world; if
the CTO asks "what if Mapbox changes pricing?" the honest answer is
"we swap to NAIP tiles in the viewer too — the measurement pipeline is
untouched."

This split also matches how every mature geospatial product works:
authoritative public imagery underneath the analytics, commercial
imagery in the chrome. The candidate gets to demonstrate the same
discipline.

## Tradeoffs & risks

- **NAIP staleness.** Imagery is 1–2 years old in most coverage; recent
  construction or storm damage will be missing. Mitigation: surface the
  acquisition date in the report so the user sees "imagery flown 2024-08-12";
  prioritize LiDAR (ADR-003) for surface geometry where they conflict.
- **NAIP resolution at the low end** (60 cm) is borderline for detecting
  small features (a 16″ vent is ~0.4 m). Mitigation: this is a feature-
  detection problem (Round 2), not a measurement problem — measurement
  uses LiDAR. The 30 cm NAIP rollout closes the gap further.
- **Mapbox TOS / pricing drift.** Free tier limits and license terms
  change. Mitigation: keep the basemap behind a single config; verify
  current terms before any commercial deployment; have a NAIP-tile
  fallback ready.
- **Two-provider integration overhead.** Minor — both are HTTP tile
  endpoints. Code complexity cost is one extra config block.

## Consequences for the build

- **Imagery client** is a single internal module with two backends
  (`NAIPClient`, `MapboxBasemapClient`) and a clear boundary: only NAIP
  is read into model inputs; only Mapbox is shipped to the browser as a
  basemap tile URL.
- **Attribution** for both providers must appear in the web UI and PDF
  export, per their licenses. Bake this into the report renderer.
- **NAIP access path:** anonymous S3 reads from `s3://naip-source/` (AWS
  Open Data; no AWS account required to read public objects). Cache
  fetched tiles to local disk for the duration of a job.
- **Mapbox setup:** standard Mapbox public access token; rate-limit per
  the free tier; mounting documented in README.
- **No Google / Bing / Nearmap / Maxar code paths** in v1 to keep the
  TOS story clean.
