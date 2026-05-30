# ADR-002: Use Mapbox Satellite as the sole imagery source (measurement + UI)

**Status:** Accepted (amended 2026-05-29) · **Date:** 2026-05-27 · **Stretch:** no
**Supersedes:** none · **Superseded by:** none

> **Amendment summary (2026-05-29).** The original decision was option **B** —
> NAIP (USDA, via AWS Open Data) for the measurement/ML path + Mapbox Satellite
> for the UI basemap. That decision rested on NAIP being free and *anonymously*
> readable from AWS Open Data, which turned out to be false (every NAIP S3 bucket
> is Requester Pays). The decision is now option **C**: **Mapbox Satellite is the
> sole imagery source for BOTH the measurement pipeline AND the UI; NAIP is
> dropped.** The original option-B context, options, rationale, and consequences
> are preserved below for the record, struck through where they no longer hold,
> with the current state in the Decision section. The filename keeps `naip` for
> historical reasons (the ADR slug and `sidecar/app/imagery/naip.py`).

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

> **Amended 2026-05-29 — Mapbox Satellite is the imagery source for BOTH the
> measurement pipeline AND the UI; NAIP is dropped.**
>
> The original decision (B, below) rested on NAIP being *free and anonymously
> readable* via AWS Open Data. That premise was false: **every NAIP S3 bucket
> (`naip-analytic` / `naip-visualization` / `naip-source`) is Requester Pays** —
> anonymous reads return `AccessDenied`, and authenticated requester-pays access
> needs an AWS account + credentials and bills egress outside `us-east-1`. The
> sidecar's NAIP fetcher had only ever run on the fixture path, so this surfaced
> the moment real imagery became the default (see the real-data inversion).
>
> Rather than add an AWS account + a second imagery credential for marginal
> resolution gain, the geometry pipeline now fetches from the **Mapbox Static
> Images API** (`mapbox/satellite-v9`, bbox form → an exact-bbox georeferenced
> PNG) — the SAME vendor the viewer/PDF already use. (Server-side it reads
> `MAPBOX_PRIVATE_TOKEN`; only the browser viewer basemap uses the public token —
> see the token-split note in Consequences.) One imagery source, one vendor.
> Implementation: `sidecar/app/imagery/naip.py`
> (`fetch_satellite_png`; file name kept to limit import churn). The ML/TOS
> consideration that argued for NAIP is noted in Tradeoffs below.

**(superseded) B. NAIP via AWS Open Data for all measurement/ML use; Mapbox
Satellite tiles for the web viewer's basemap UI only.** Mapbox's free tier covers
the demo and any near-term pilot; if the product ships, the basemap is a
swappable layer.

## Rationale

> *(Superseded 2026-05-29.) The rationale below argued for splitting NAIP
> (measurement) from Mapbox (UI). It no longer holds: NAIP was not anonymously
> readable, so the split collapsed to Mapbox-only. The "defensible at scale" /
> ML-licensing argument for NAIP is now carried as an explicit accepted risk in
> Tradeoffs (Mapbox-for-ML TOS exposure), with the single-function fetch seam
> noted as the cheap path back to a clean-licensed source if needed.*

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

*(Amended 2026-05-29, alongside the Decision amendment — Mapbox is now the sole
imagery source.)*
- **Mapbox imagery for ML/derivative use — TOS exposure.** The original reason to
  prefer NAIP for the *measurement* path was that NAIP is public domain and
  unambiguously legal to feed an ML pipeline at scale, whereas commercial imagery
  TOS may restrict derivative/ML use. Using Mapbox for the measurement pipeline
  inherits that exposure. Mitigation: verify Mapbox's current terms for
  measurement/derivative use before any commercial deployment; the fetch is a
  single function (`fetch_satellite_png`), so swapping the source (e.g. to a
  credentialed NAIP/requester-pays path or another provider) is localized if the
  TOS or accuracy needs demand it. This is the deliberate trade for "one imagery
  vendor, one credential, and a path that actually works without an AWS account."
- **Resolution / not-true-ortho.** Mapbox satellite is Web-Mercator raster, not
  NAIP's nadir ortho; slightly lower effective resolution and not orthorectified.
  Acceptable because surface *geometry* comes from LiDAR (ADR-003); imagery feeds
  outline refinement + feature detection, which tolerate this.

## Consequences for the build

*(Amended 2026-05-29 to the Mapbox-only reality. The original option-B
consequences are struck through; the current consequences follow each.)*

- ~~**Imagery client** is a single internal module with two backends
  (`NAIPClient`, `MapboxBasemapClient`) and a clear boundary: only NAIP
  is read into model inputs; only Mapbox is shipped to the browser as a
  basemap tile URL.~~ → **One Mapbox-backed imagery path.** The sidecar's
  measurement-imagery fetch (`sidecar/app/imagery/naip.py`,
  `fetch_satellite_png` → Mapbox Static Images, bbox form) and the
  browser basemap (MapLibre) and the server-side PDF map render all use
  Mapbox Satellite. No NAIP code path remains.
- **Two tokens, split by EXPOSURE (not feature).** `MAPBOX_PUBLIC_TOKEN`
  is browser-only — shipped to the client in the report-viewer page so
  MapLibre can fetch tiles (a `pk.*` token, URL-restricted to our domains;
  not a secret). `MAPBOX_PRIVATE_TOKEN` is server-only — every server-side
  Mapbox call reads it: the sidecar's measurement-imagery fetch + PDF map
  render, and Rails' PDF static-image fallback + the address-entry
  autocomplete (Search Box `/suggest`, ADR-004). The principle is least
  privilege on the one token that must reach the browser; everything
  server-side shares a single private token that never leaves the backend.
  (Earlier iterations used `MAPBOX_PUBLIC_TOKEN` server-side too; tightened
  to this split.)
- **Attribution.** Mapbox's ToS requires the Mapbox + imagery-provider
  (Maxar) credit on every surface that shows a tile — the web viewer, the
  PDF, and the JSON export's provenance. The imagery stage emits
  `name: "Mapbox", license: "© Mapbox © Maxar"`; the report renderer must
  surface it (do **not** claim public domain).
- ~~**NAIP access path:** anonymous S3 reads from `s3://naip-source/` (AWS
  Open Data; no AWS account required to read public objects).~~ → **Dropped.**
  Every NAIP S3 bucket is Requester Pays, so anonymous reads return
  `AccessDenied`; this is the defect that triggered the amendment.
- **Mapbox setup:** two access tokens (rate-limit per the free tier;
  provisioning documented in `.env.example` / `ops/.env.example`). The
  sidecar fetch + PDF render + autocomplete use `MAPBOX_PRIVATE_TOKEN`
  (server-side); the browser basemap uses `MAPBOX_PUBLIC_TOKEN` (front-end).
- **No Google / Bing / Nearmap / Maxar code paths** in v1 to keep the
  TOS story clean. (Maxar appears only as Mapbox's imagery-provider credit
  in attribution, not as a separate integration.)
