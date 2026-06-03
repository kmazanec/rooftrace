# LiDAR EPT resolution + honest pitch — design

**Date:** 2026-06-03
**Status:** Approved (design); pending implementation plan
**Author:** Keith + Claude

## Problem

Two compounding bugs, found while reviewing a report for *5859 N Winthrop Ave,
Chicago, IL*:

1. **Missing LiDAR for a well-covered address.** The report shows
   `lidar_missing: no_ept_resource`. Chicago/Cook County is densely covered by
   USGS 3DEP, and the `no_ept_resource` reason is only reachable *after* WESM
   coverage succeeds — so coverage was found and we still failed to fetch the
   point cloud. Root cause: `ept_url_for(work_unit_name)`
   (`sidecar/app/lidar/ingest.py:58-60`) blindly interpolates the WESM
   work-unit *name* into the public bucket URL. When `usgs-lidar-public`
   publishes that collect under a different key, the read 404s
   (`NoSuchKey → EptNotFound → no_ept_resource`). This is a resolver bug, not a
   dataset hole — already documented as the unfinished follow-up in
   `docs/QA-FINDINGS.md` B-7.

2. **Fabricated pitch on the imagery-only fallback.** With LiDAR missing, the
   orchestrator routes to `fallback_stage`
   (`app/services/measurement_orchestrator.rb:280`) and passes a hardcoded
   `DEFAULT_INFERRED_PITCH_DEGREES = 26.57` (`:278`). The sidecar echoes it back
   as a measured-looking `6:12 (26.6°)`. Every LiDAR-less address gets the
   identical pitch because **no pitch is measured at all** on this path — the
   number is a residential-average placeholder dressed up as a measurement, and
   it propagates into the persisted measurement and the downloaded JSON.

The two interact: the resolver miss forces the imagery fallback, and the
imagery fallback fabricates the pitch.

## Goals

- Recover real LiDAR (and therefore real measured pitch) for addresses that are
  covered by 3DEP but whose WESM work-unit name doesn't match the published EPT
  resource key.
- Stop surfacing a fabricated pitch when we did not measure one. Represent
  "unknown" honestly, end-to-end (data model → web report → JSON → PDF →
  viewer).

## Non-goals

- Estimating pitch from imagery (e.g. a vision model). Out of scope; the
  imagery path reports pitch as unknown.
- Reworking the LiDAR plane-fit path, which already produces real per-facet
  pitch.
- Changing the public export schema (it already permits null pitch).

## Decisions (locked with the user)

1. **EPT resolution: spatial query of the entwine boundaries.** Resolve which
   *published* EPT resource covers the bbox, independent of the WESM name —
   rather than name-normalization guessing or fetching a name-keyed index.
   Chosen for robustness against name drift.
2. **Unknown pitch is displayed as unknown.** On the imagery-only path the
   primary pitch and per-facet pitch are `null`; the report shows `—` / "pitch
   unknown", never a measured-looking `6:12`.
3. **Area stays slope-corrected, labeled estimated.** The `6:12` assumption
   survives **only** as the internal `1/cos(pitch)` area-inflation factor, never
   as a displayed pitch. Contractors keep a usable roof-surface figure; it is
   explicitly labeled an estimate.
4. **Honesty propagates through the data model**, not just the display layer —
   the persisted measurement and the downloaded JSON must not carry a pitch of
   `6` that implies measurement.

---

## Section 1 — EPT resolution via entwine boundaries (LiDAR recovery)

### Current flow (`sidecar/app/lidar/ingest.py`, `ingest_lidar`)

- **Hop 1 — coverage:** `index.query(bbox)` against WESM (`WESM.gpkg`). Empty →
  `no_coverage` (genuine gap).
- **Hop 2 — fetch:** loop covering WESM work units, for each build
  `…/usgs-lidar-public/{work_unit_name}/ept.json` and `cropper.crop`. If all
  raise `EptNotFound` → `no_ept_resource`. **This is the bug:** the URL is a
  blind name interpolation; no reconciliation against the real published keys.

### New design

Introduce an **EPT resource index resolved by spatial coverage**, in a new
isolated unit:

- **`sidecar/app/lidar/ept_index.py`**
  - Fetches the `usgs-lidar-public` entwine **boundaries/resources** index
    (GeoJSON of every published EPT resource's footprint + its real resource
    key).
  - Caches it: in-process for the process lifetime, plus the Spaces `cache/`
    prefix with a TTL (one fetch serves many jobs; survives restarts).
  - `resolve_ept_resources(bbox) -> list[EptResource]` returns published
    resources whose footprint intersects the bbox, ordered by best spatial fit
    / recency. `EptResource` carries the **real** resource key (not a guessed
    name) plus its footprint.
  - This is the authoritative *resolvable-resource* source.

- **`ingest.py` Hop 2 rewrite.** Instead of looping WESM names and guessing a
  URL each, get candidate `EptResource`s from `resolve_ept_resources(bbox)` and
  try each **real** key via the cropper. WESM remains the **Hop-1 coverage +
  recency (`year`/`stale_lidar`) source**; the entwine index becomes the
  resolver. Where a chosen resource lines up with a WESM unit by name we keep
  the WESM year; otherwise we still proceed (name match no longer required).

- **Semantics of `no_ept_resource` after the change:** "the entwine index has no
  published resource covering this bbox" — a genuinely honest gap. WESM
  name-drift misses (the Chicago case) no longer reach it.

### Real-default / fixture polarity (project rule)

The entwine index uses the **live USGS boundary by default in dev + prod**,
boot-checked. Tests opt down via a new `EPT_INDEX_FIXTURE` flag, registered in
`sidecar/app/flags.py` + `sidecar/app/boot_checks.py`, set in
`sidecar/tests/conftest.py`. **No `*_FIXTURE` in any dev/prod `.env`.**

---

## Section 2 — Stop fabricating a measured pitch (imagery-only path)

### The seam: split one number into two roles

Today `inferred_pitch_degrees = 26.57` drives the facet pitch, the primary
pitch, *and* the area inflation. Split it:

- **Internal area assumption (stays):** `inferred_pitch_degrees` keeps driving
  the `1/cos(pitch)` area inflation in
  `sidecar/app/planefit/geometry.py:fallback_measurement_from_polygon` (`:363`).
- **Displayed measured pitch (goes null):** `MeasurementGeometry.primary_pitch_ratio`
  / `primary_pitch_degrees` become `null` on this path; the facet carries
  `pitch_ratio = null` / `pitch_degrees = null` but keeps its `area_sq_ft`. The
  `6:12` never appears as a pitch.

### Schema changes (gating)

In **both** `shared/pipeline_schema.json` and
`sidecar/contracts/pipeline.py`:

- `Facet.pitch_ratio` / `pitch_degrees` → `["number", "null"]`; removed from
  `required` (`pipeline_schema.json:157-167,176`; `pipeline.py:90-97`).
- `MeasurementGeometry.primary_pitch_ratio` / `primary_pitch_degrees` →
  `["number", "null"]`; removed from `required`
  (`pipeline_schema.json:753-758,767`; `pipeline.py:336-337`).
- `FallbackMeasurementRequest.inferred_pitch_degrees` **stays required** — it is
  the area assumption, not a pitch claim (`pipeline_schema.json:794`;
  `pipeline.py:353`).
- `shared/json_export.schema.json` already permits null — **no change**.
- `Measurement.predominant_pitch_ratio` already nullable — **no change**.
- DB: `predominant_pitch_ratio` column already nullable; per-facet pitch is
  `jsonb` content — **no migration**.

### Disclosure carrier

Add a warning `area_estimated_no_pitch` (alongside the existing
`no_lidar_fallback`) emitted when the area assumption is substituted, so every
surface renders "pitch unknown · area estimated" from **data**, not by inferring
it off the source string.

### Rails (mostly already nil-safe)

Verified already render `—`/null: `PitchMath.degrees` (`pitch_math.rb:10-14`),
`reports_helper#pitch_display`/`facet_pitch_label`, `job_export_serializer.rb`,
`measurement_viewer_serializer.rb`, `show.pdf.erb`, `_side_panel.html.erb`,
`pdf_report_presenter.rb`. Real changes:

- **`app/views/reports/_limitations.html.erb:24`** — the unconditional *"Pitch
  values are derived from the point cloud"* is **false on the imagery path**.
  Move it into the LiDAR branch; add an imagery-branch sentence: pitch not
  measured; area is a flat-assumption estimate.
- **Area label** — surface "estimated" next to the area figure on the imagery
  path, driven by the `area_estimated_no_pitch` warning + source (label seam in
  `reports_helper.rb`).

### React viewer (latent bug — must fix)

- `app/javascript/viewer/utils/colorByPitch.ts:17` coerces `null → 0/12`
  (renders a real-looking flat facet). Fix: explicit **"unknown" color**
  (distinct neutral, not the 0/12 bucket).
- `app/javascript/viewer/RoofViewer.tsx:345` tooltip prints `null:12`. Fix:
  "pitch unknown".
- `app/javascript/viewer/types.ts:7-8` types pitch as non-null. Fix:
  `number | null`.

---

## Section 3 — Error handling & testing

### Error handling

- **Entwine index fetch failure** (network/parse) is **infra, not a coverage
  gap** — it must not masquerade as `no_ept_resource`. On fetch failure, fall
  back to the current name-guess path (never worse than today); if that also
  misses, return `no_ept_resource`. Index-fetch errors are logged, not fatal —
  the job completes via imagery. A successful index is cached so one fetch
  serves many jobs.
- **Null-pitch containment:** loosening the schema to allow null pitch must not
  let null leak onto the **LiDAR** path — that path still asserts measured
  pitch. Null is only ever produced by the fallback.

### Testing (TDD — failing tests first, per debugging Phase 4)

- **`ept_index.py`** (sidecar pytest): fixture boundary GeoJSON — bbox
  intersects one / many / no resources; real-key extraction; cache hit.
- **`ingest_lidar`** (sidecar pytest): a *covering-WESM-but-name-mismatch* case
  (the Chicago regression) now **resolves via the boundary index** instead of
  returning `no_ept_resource`; genuine no-coverage still returns `no_coverage`;
  index-fetch failure degrades to the name-guess path, then honest
  `no_ept_resource`.
- **Fallback geometry** (sidecar pytest): asserts `primary_pitch_ratio is None`
  and facet `pitch_ratio is None`, while `area_sq_ft` is still inflated above
  the planimetric footprint and `area_estimated_no_pitch` is present.
- **Rails** (RSpec): assembler accepts + validates a null-pitch geometry;
  report / JSON / PDF render `—` / null (never `0` / `6`); `_limitations` shows
  the imagery copy and no longer claims point-cloud-derived pitch.
- **JS** (vitest): `colorByPitch(null)` → unknown color (not the 0/12 bucket);
  tooltip shows "pitch unknown".
- The `/skeleton` real-sidecar round-trip stays green.

## Affected files (map)

**Sidecar:** `sidecar/app/lidar/ept_index.py` (new), `sidecar/app/lidar/ingest.py`,
`sidecar/app/planefit/geometry.py`, `sidecar/contracts/pipeline.py`,
`sidecar/app/flags.py`, `sidecar/app/boot_checks.py`,
`sidecar/tests/conftest.py` (+ new tests).
**Shared:** `shared/pipeline_schema.json`.
**Rails:** `app/services/measurement_orchestrator.rb` (warning wiring),
`app/views/reports/_limitations.html.erb`, `app/helpers/reports_helper.rb`
(area-estimated label) (+ specs).
**JS:** `app/javascript/viewer/types.ts`,
`app/javascript/viewer/utils/colorByPitch.ts`,
`app/javascript/viewer/RoofViewer.tsx` (+ vitest).
**Docs:** `docs/QA-FINDINGS.md` B-7 (mark follow-up done), and any cross-cutting
ADR note on the entwine-index resolver if architecture-level.

## Open questions

None blocking. Resolver ordering heuristic (spatial-fit vs recency tiebreak)
will be finalized in the plan against the fixture data.
