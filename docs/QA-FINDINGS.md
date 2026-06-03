# QA Findings — RoofTrace web app walkthrough

**Date:** 2026-06-02 · **Reviewer:** QA agent · **Against:** the project brief
(`../01-precision-roof-measurement.md`) as top-level truth, then
`docs/ARCHITECTURE.md` + ADRs (there is **no `docs/PRD.md`** — see F-DOC-1).

Method: drove the running local stack (Rails on :3000 via `bin/dev`, sidecar
container `rooftrace-sidecar-dev` on :8001) in a real browser, submitted a real
address job, traced each pipeline stage against its real external service.

---

## TL;DR — outcome

**At the start, the core promise (address → measured roof report) did not work:**
every job 502'd at the SAM2 stage, and even past that, LiDAR was 100% dead, so
no report was ever produced. **After this pass, the full pipeline completes
end-to-end with real public-LiDAR fusion** — a verified Champlin MN job returns
`source=fusion`, ~25k sq ft, perimeter 240 ft, 24 facets, with a satellite-backed
3D viewer, a styled branded PDF, JSON export, public share link, and the mobile
JSON API all working.

**Fixed (with tests, all suites green — sidecar 389, Rails services/helpers 369,
relevant requests 77):**
- **B-1** SAM2 crashed on the removed `modal.Function.lookup` API → `from_name`.
- **B-4** WESM coverage lookup `KeyError` (wrong gpkg field names) → robust `_field`.
- **B-5** real LiDAR fetch never worked (WESM `lpc_link` is a directory) → resolve
  USGS **EPT** by work-unit name + `readers.ept` + **height-above-ground roof
  extraction** for the common no-class-6 collections.
- **B-6** SAM2 failure hard-failed the job → degrade to the prior outline + warning.
- **M-1** Regrid parcel lookup hit a dead v1 endpoint (404) → v2 `parcels/point.json`.
- **M-2** sidecar swallowed errors with no log → log cause + traceback before 502.
- **V-1** viewer satellite basemap 403 → resolved (Keith re-issued the Mapbox pk token).
- **V-2** total perimeter always null → implemented union-boundary perimeter.
- **V-4** PDF rendered unstyled + mojibaked + broken logo (print layout never
  applied to the `:pdf` format) → `report_print.pdf.erb` + inlined CSS + inlined SVG.

**Needs you (can't be done from code / this environment):**
- **B-2** deploy the Modal SAM2 app: `modal deploy sidecar/app/outline/sam2_modal.py`
  (now documented in `ops/README.md`). Until then, outlines use the unrefined
  footprint (honest `outline_unrefined` warning), which inflates area + facet
  count — re-validate accuracy (**V-3**) after deploying.
- **M-1 residual** the free-tier Regrid token returns no parcel geometry; upgrade
  the plan if real parcel cropping is wanted (parcels are optional per the brief).

---

## Severity: BLOCKER — the core promise does not work end-to-end

### B-1 · SAM2 outline-refinement stage crashes on a removed Modal API → every job fails

- **Symptom:** Submitting any address runs geocode → imagery → LiDAR → then the
  status page shows **"Pipeline stage failed: Sidecar returned 502"**. No report
  is ever produced. The brief's entire headline ("type an address → measured
  roof report in ~90 s") is non-functional.
- **Root cause:** `sidecar/app/outline/segmenter.py::_run_modal` calls
  `modal.Function.lookup("rooftrace-sam2", "segment_roof")`. The installed Modal
  SDK is **1.4.3**, which **removed `Function.lookup`** →
  `AttributeError: type object 'Function' has no attribute 'lookup'`. The outline
  router's generic `except Exception` maps it to HTTP 502.
- **Why it's fatal (not degraded):** `MeasurementOrchestrator#lidar_stage`
  rescues sidecar 5xx and degrades to LiDAR-missing (good), but
  `#refine_stage` has **no rescue** — its 502 bubbles to the top and hard-fails
  the job.
- **Fix:** `modal.Function.lookup(app, name)` → `modal.Function.from_name(app, name)`
  (verified the correct 1.4.3 API and signature in-container).

### B-2 · The Modal SAM2 app is not deployed

- **Symptom:** Even with B-1 fixed, `fn.remote(...)` raises
  `modal.exception.NotFoundError: App 'rooftrace-sam2' not found in environment 'main'`.
- **Cause:** `sidecar/app/outline/sam2_modal.py` was never `modal deploy`-ed to
  the configured Modal account (tokens ARE present and valid).
- **Disposition:** deploying to Modal needs the account + GPU — likely a **human
  step**. BUT see B-3: the architecture promises a local fallback that should
  let the pipeline survive this.

### B-3 · The "local-CPU SAM2 fallback" promised by ADR-012 does not exist

- **Tension with architecture:** ADR-012 states plainly: *"if Modal is
  unavailable… the sidecar falls back to local CPU SAM2… the SAM2 model weights
  are baked into the sidecar Docker image so the fallback works without external
  dependencies."* The brief likewise lists "local-CPU SAM2 fallback if Modal
  flakes" as a committed latency/risk mitigation.
- **Reality:** the `SAM2_BACKEND=local` path (`segmenter.py::_stub_segmenter`)
  is a **test stub that erodes the prior mask** — not real SAM2, no baked
  weights. And there is **no automatic Modal→local fallback**: a Modal failure
  hard-502s instead of degrading. So the resilience the architecture claims is
  absent, and a Modal outage takes the whole product down.

---

### B-4 · WESM coverage lookup crashes on every job (KeyError) — FIXED

- **Symptom (surfaced only after M-2 logging):** `ingest-lidar` 502s with
  `KeyError: 'Illegal field requested in GetField()'` at `wesm.py:113`.
- **Root cause:** OGR's `Feature.GetField(name)` **raises** for a column absent
  from the layer schema (it does not return None). The code used
  `GetField("copc_url") or GetField("lpc_link")` etc., but the real `WESM.gpkg`
  schema has `lpc_link` / `horiz_crs` / `collect_end` — **not** `copc_url` /
  `epsg` / `year`. The first absent-field probe threw, so **every** coverage
  query failed → LiDAR was 100% dead → every job silently became imagery-only
  (then died at SAM2). This nullified the brief's headline LiDAR differentiator.
- **Fix:** added a `_field(feat, name)` helper that checks `GetFieldIndex()` and
  returns None for absent/empty columns. Verified the fixed query returns 2 real
  work units for Champlin MN (QL1 2022 @ EPSG:6344; QL3 2011). FIXED.

### B-5 · WESM `lpc_link` is a directory, not a COPC URL — real LiDAR fetch still can't run

- **Found while validating B-4.** `ingest.py:94` feeds `work_unit.copc_url`
  (which is the WESM `lpc_link`, a USGS *staged-products folder* URL) straight
  into PDAL `readers.copc filename=...`. That folder is not a COPC file, so the
  real fetch fails.
- **The correct source** (confirmed live): USGS public **EPT** keyed by work-unit
  name — `https://s3-us-west-2.amazonaws.com/usgs-lidar-public/<workunit>/ept.json`
  returns valid Entwine Point Tiles; PDAL `readers.ept` reads it (verified the
  reader executes against the real endpoint in-container).
- **Disposition:** this is an unfinished pipeline hop (WESM work-unit →
  EPT/COPC endpoint + `readers.ept`), not a one-line bug. Plus a PROJ-data
  warning (`Open of /opt/conda/share/proj failed`) appears during EPT
  reprojection and must be resolved for correct CRS transforms. **Pending a
  scope decision** (see below) — flagged, not yet fixed.

---

### B-7 · WESM work-unit names don't always match the public EPT key → now resolved spatially (LiDAR recovered) — FIXED

- **Found after the Modal deploy, testing a Lincoln NE address.** Its WESM unit
  `NE_Eastern_UA_2016` has **no `usgs-lidar-public/NE_Eastern_UA_2016/ept.json`**
  (S3 `NoSuchKey`) — the EPT bucket doesn't publish every WESM work-unit name
  verbatim. The job still completed (degraded to imagery, ~2,032 sq ft, 1 facet)
  but logged a scary 502 traceback and reported the gap as a transport error.
- **Fix:** `PdalCropper` now maps an S3 NoSuchKey/404 to a typed `EptNotFound`;
  `ingest_lidar` tries each covering work unit in turn and, if none resolve,
  returns `LIDAR_MISSING` (reason `no_ept_resource`) — a graceful, honest
  coverage gap, not a 502. Report warning reads `lidar_missing: no_ept_resource`.
- **Follow-up (DONE):** `ingest_lidar` now resolves the EPT resource by SPATIAL
  coverage, not by name. A new `lidar/ept_index.py` fetches the entwine boundaries
  index (`https://usgs.entwine.io/boundaries/resources.geojson`) and returns the
  published resources whose footprint covers the building bbox; Hop 2 tries those
  real keys first, degrades to the legacy WESM-name guess if the index is
  unavailable, and only then returns the honest `no_ept_resource`. This recovers
  LiDAR for name-mismatched-but-covered addresses (e.g. the Chicago case) instead
  of falling back to imagery.

### B-6 · SAM2 failure hard-failed the whole job — now degrades to the prior — FIXED

- The orchestrator's `refine_stage` had no rescue, so a SAM2 502 (B-1/B-2) was
  fatal. The stage only *refines* the MS-footprint prior, and the sidecar
  already falls back to the prior on low IoU, so a transport/5xx failure now
  degrades to the unrefined prior with an honest `outline_unrefined: <class>`
  warning (surfaced in the report) — mirroring `lidar_stage` (ADR-001). A
  `SchemaError` still hard-fails (contract drift = loud). FIXED + specs added.

---

## Severity: MEDIUM

### V-1 · Web report viewer basemap: every Mapbox satellite tile 403s (public token) — RESOLVED

**Resolved:** the public token (`MAPBOX_PUBLIC_TOKEN`) was URL/scope-restricted.
Keith issued a new public token; after restarting puma so it re-read `.env`, the
viewer's satellite basemap renders with zero console errors. (Note for ops: the
long-lived `bin/dev` puma caches `.env` at boot — a token change needs a dev
restart; documented behavior, not a bug.)

<details><summary>original finding</summary>

- **Symptom:** the report viewer's 3D model floats on a blank gray field; the
  browser console shows **58 errors**, all `403 Forbidden` from
  `https://api.mapbox.com/v4/mapbox.satellite/{z}/{x}/{y}@2x.png` using the
  **public** token (`MAPBOX_PUBLIC_TOKEN`, `pk.…`).
- **Diagnosis:** the `pk` token 403s on ALL Mapbox tile/imagery endpoints (v4
  raster AND styles raster tiles) but 200s on style *metadata* and introspects
  as `TokenValid`. The server-side `sk` token 200s on the same tiles. So the
  public token is **URL-restricted (allowlist excludes localhost) or lacks the
  tiles scope** — a Mapbox **account/token config** issue, not a code bug.
- **Two fixes:** (a) you fix the public token's URL allowlist / scopes in the
  Mapbox account; OR (b) code: proxy basemap tiles through Rails with the
  server-side `sk` token (mirrors the existing `address_suggestions` proxy),
  which makes the viewer work on any host regardless of `pk` restrictions.

</details>

### V-4 · PDF print layout never applied → unstyled, mojibaked, broken logo — FIXED

The biggest downstream finding. `ReportPdf#render_html` calls
`ApplicationController.render(template: "reports/show", formats: [:pdf], layout:
"report_print")`, but Rails **silently does not apply an `.html.erb` layout to a
`:pdf`-format render** — the layout was dropped, so Grover received a bare body
fragment with **no `<head>`, no charset, and no stylesheet**. Consequences seen
in the rendered PDF:

- **Mojibake:** `Total perimeter â€"` and `20.6Â°` — UTF-8 chars rendered as
  Latin-1 because no `<meta charset="utf-8">` reached Chromium.
- **Unstyled:** the whole report rendered in Chromium's default serif with no
  table/brand styling — `report.css` was never linked. (It *looked* partly
  styled only because the orange header is baked into the wordmark SVG itself.)
- **Broken wordmark:** `<img src="/assets/brand/…svg">` showed as alt text —
  Grover has no base URL to resolve `/assets` against.

**Fixes (all behind new tests):**
1. Added `app/views/layouts/report_print.pdf.erb` (a `:pdf`-format layout Rails
   *will* find for this render) with `<meta charset="utf-8">`.
2. `inline_stylesheet` helper — inlines `report.css` into a `<style>` block
   (Grover can't fetch a `<link href="/assets/…">`). report.css uses only
   system-font fallbacks, so inlining fully styles it with no external fetch.
3. `inline_brand_svg` helper — inlines the wordmark SVG instead of `<img>`.

Verified by re-rendering: clean em-dash/degree glyphs, full table styling,
wordmark present. Specs: `report_pdf_spec` (complete-document regression) +
`reports_helper_spec` (both inline helpers).

### V-2 · `TOTAL PERIMETER` was empty on every report (stubbed in plane-fit) — FIXED

- **Root cause:** `sidecar/app/planefit/geometry.py` set `total_perimeter_ft=None`
  in all paths (`# not computed in this version`), so the schema field, JSON
  export, viewer, and PDF all showed blank — even though the architecture's
  schema defines it and the UI has a row for it.
- **Fix:** implemented `_total_perimeter_ft(facets)` — projects the facets'
  WGS84 plan-view rings to local UTM, unions them, and measures the EXTERIOR
  boundary length in feet (so shared ridge/valley edges aren't double-counted);
  wired into both the LiDAR/fusion (`assemble_measurement`) and no-LiDAR
  (`fallback_measurement_from_polygon`) paths. Verified end-to-end: a fresh
  Champlin job now reports `total_perimeter_ft=239.73`. Specs added
  (`TestTotalPerimeter`: single facet, adjacent-no-double-count, degenerate→None).

### V-5 · (RETRACTED) `/up` and the DB

Briefly suspected `/up` of touching the DB after seeing a `PG::ConnectionBad`
500 during a stack restart. **Retracted on verification:** with Postgres
stopped, `/up` still returns **200** — it is correctly DB-free (stock
`rails/health#show`, no `require_demo_login`, no query). The 500 I'd seen was a
restart-timing artifact from a different (DB-touching) request, not `/up`. The
liveness/readiness split holds as designed.

### V-3 · Over-segmentation / inflated area without SAM2 (consequence of B-2)

- The Champlin run produced **28 facets, 34,506 sq ft, pitches 7°–53°** — far too
  large/complex for a residential roof. Root cause is the unrefined footprint
  (Modal down, B-2) + height-extracted points: the outline isn't trimmed to the
  roof, so RANSAC fits many spurious planes over a too-large area. Expected to
  shrink dramatically once SAM2 (Modal) is deployed. Confidence correctly reads
  **low (0.27)**. Re-validate area/facets after the Modal deploy.

### M-1 · Regrid parcel lookup hit a dead v1 endpoint (404 on every job) — FIXED

- **Symptom:** `Regrid degraded: Regrid returned HTTP 404` on every resolve-address
  call → `parcel_polygon` always null → multi-building parcels never cropped
  (contributes to the inflated-area/over-segmentation in V-3).
- **Root cause:** the code called `GET /api/v1/parcel/point?lng=…`, which **404s
  and returns the Regrid marketing site as HTML**. The current API is
  `GET /api/v2/parcels/point.json?lon=…` (verified live: 200 + JSON
  `{"parcels":{"type":"FeatureCollection",…}}`).
- **Fix:** `sidecar/app/resolve_address/regrid.py` now targets the v2 path with a
  `lon` param; `_extract_parcel` updated (v2 docstring + MultiPolygon handling +
  `headline` address fallback). Spec added asserting the v2 path + `lon` param.
- **Residual (your side):** this **free-tier Regrid token returns an empty
  FeatureCollection** even on covered coords (Empire State Bldg, Chicago) — full
  parcel geometry is a paid Regrid plan. With the URL fixed, that's now an honest
  no-parcel degrade (null `parcel_polygon`), not a 404 error. Upgrade the Regrid
  plan if real parcel cropping is wanted; the brief lists parcels as optional.

### M-2 · Sidecar swallows real errors with no log line

- The lidar/outline 502 handlers raise `HTTPException(502, detail=type().__name__)`
  but **never log the exception/traceback**. Debugging required reproducing the
  call by hand inside the container. Charity-Majors-grade observability says: log
  the cause (warning + `exc_info`) before returning a generic 502. (The outline
  `_mask_to_polygon` fallback DOES log with `exc_info=True` — match that.)

---

## Severity: LOW / DOC

### F-DOC-1 · No `docs/PRD.md`

The task named `docs/PRD.md` as a requirements layer; it does not exist. The
requirement layers that DO exist are the brief + `docs/ARCHITECTURE.md` + ADRs +
per-feature specs.

### F-DOC-2 · `docs/ARCHITECTURE.md` links a dangling `../BRIEF.md`

The "Brief:" link points at `../BRIEF.md` (repo root), which does not exist. The
actual brief lives at `../01-precision-roof-measurement.md` (one level above repo).

---

## Confirmed WORKING

- Login (`demo` / `password`), session, gated surfaces.
- Address typeahead → Mapbox Search Box `/suggest` (real, returns suggestions).
- Job submit → Solid Queue enqueue → live status page (ActionCable/Turbo Streams
  advancing through stages).
- Pipeline stages that ran green before the SAM2 crash: resolve-address
  (Nominatim geocode + MS footprints), render-imagery (Mapbox), ingest-lidar
  (degrades cleanly on transport error).
- Graceful failure UI: a failed job shows a clear message + "Try another address".
- `/health` (Postgres+PostGIS ok; Spaces probe "skipped" locally — see below).
