# BUILD-PLAN — Iteration `wave5-stretches`

**Status:** APPROVED (Keith, 2026-05-29) · **Date:** 2026-05-29 ·
**Planner:** kmaz-plan-iteration · **Consumed by:** kmaz-build-iteration

> Iteration-scoped manifest (the prior `docs/BUILD-PLAN.md` is the
> already-built Wave-4 plan — left untouched). This is the reviewable plan
> for building **Wave 5 (the two stretch features)** in parallel. Approve
> this file + the per-spec **"Build plan (approved)"** sections in
> `docs/features/17-*.md` and `docs/features/18-*.md`, then launch the
> build. The build step scopes all its artifacts to the iteration slug below.

## Iteration

| Field | Value |
|---|---|
| **Iteration slug** | `wave5-stretches` |
| **Branch** | `build/wave5-stretches` |
| **Worktrees** | `.claude/worktrees/wave5-stretches/<feature>/` |
| **Convergence report** | `CONVERGENCE-wave5-stretches.md` |
| **Features** | F-17 (claim-defensibility PDF), F-18 (server-side AR overlay) |
| **Dependencies** | F-16 (iOS ingest + ICP fusion) — **merged to `main`**; F-04/F-12/F-13/F-14 surfaces — present |

Both features are Wave 5 in `docs/ROADMAP.md`. F-01–F-16 and F-19 are
already built and on `main`; these two stretches are the only unbuilt
roadmap pieces.

## Features & model tiers

| Feature | Title | Tier | Why |
|---|---|---|---|
| **F-17** | Claim-defensibility PDF | **sonnet** | Rails views/CSS/PORO over existing PDF infra (`ReportPdf`, `show.pdf.erb`, `report.css`); one small new sidecar thumbnail endpoint. Well-specified, low coordination. |
| **F-18** | Server-side AR overlay | **opus** | Cross-language projection math (Python) + a multi-entity contract amendment touching both clients **and** fusion + three coupled surfaces (viewer/PDF/JSON). High correctness + coordination risk. |
| **(barrier)** | Frozen shared contracts | **opus** | It *is* the contract — the most collision-prone work. |

> F-18 was escalated to a **3-draft panel** (math-first / contract-first /
> risk-first) during planning, then synthesized — it is the high-uncertainty
> feature (new geometry + contract + 3 surfaces).

## Build DAG

```
PHASE 0 — CONTRACT BARRIER  (one commit on build/wave5-stretches, before any fan-out)
  └─ merged pipeline_schema 0.4.0 (3 deltas) + both clients
     + fusion arkit→UTM transform persisted to provenance
     + ProjectedOverlay migration/model
     + frozen _evidence_photos seam interface + ReportPdf list-builder skeleton

PHASE 1 — PARALLEL FAN-OUT  (two worktree-isolated workstreams)
  ├─ W-17  F-17 claim PDF      (sonnet)  ── builds against the frozen seam
  └─ W-18  F-18 AR overlay     (opus)    ── builds against the frozen seam + 0.4.0

CONVERGENCE
  └─ a job WITH projections renders composites in PDF/viewer/JSON;
     a job WITHOUT renders F-17 thumbnails. One MR.
```

The seam between the two features (the PDF evidence block) is **frozen as
an interface in Phase 0**, so W-18 codes against it without waiting for
W-17's partial implementation. Neither workstream edits
`shared/pipeline_schema.json` after fan-out.

## Frozen shared contracts

### 1. `pipeline_schema` 0.3.0 → **0.4.0** (single merged bump — BARRIER)

Additive. `additionalProperties: false` everywhere. Both clients move
together (`sidecar/contracts/pipeline.py` Pydantic + Rails `PipelineSchema`
/ `SidecarClient`); one `PIPELINE_SCHEMA_CHANGELOG.md` entry; drift spec
updated.

- **NEW** `RenderEvidenceThumbnailsRequest` `{pipelineSchemaVersion, job_id, photos:[{sequence_index:int, photo_ref:str(uploads/), captured_at:str}]}`
  → `RenderEvidenceThumbnailsResponse` `{pipelineSchemaVersion, job_id, thumbnails:[{sequence_index:int, ref:str(artifacts/), captured_at:str}]}` *(F-17)*
- **AMEND** `ProjectPhotoRequest`: add `world_mesh_ref:str(uploads/)`,
  `arkit_to_utm:[16 floats]`, `utm_epsg:int`, `features:[Feature]`,
  `pose_confidence:float`; keep `photo_ref`,
  `camera_pose{intrinsics[9], extrinsics[16]}`, `facets:[Facet]`. *(F-18)*
- **AMEND** `ProjectPhotoResponse`: replace lone `overlay_ref` with
  `composite_ref:str(artifacts/)`, `overlay_svg_ref:str(artifacts/)`,
  `pose_confidence:float`, `occluded_facet_ids:[str]`. *(F-18)*
- **AMEND** `FuseCaptureResponse`: add `arkit_to_utm:[16 floats]`,
  `utm_epsg:int` (so the ICP transform escapes fusion). *(F-18/barrier)*

### 2. `Measurement.provenance` fusion-transform fields (BARRIER)

`fused_provenance` adds `fusion_arkit_to_utm_4x4:[16]` + `fusion_utm_epsg:int`.
Additive to the free-form jsonb; json_export `provenance` is
`additionalProperties:true`, so no export-schema break.

### 3. PDF evidence / on-site-visualization seam (F-17 builds, F-18 fills)

`app/views/reports/_evidence_photos.html.erb` consumes an ordered
`Array<{image_url, caption, kind:'thumbnail'|'composite'}>` (cap 4).
`ReportPdf` prefers `artifacts/<job_id>/projected/` composites (ordered
`pose_confidence` DESC) when present, else `artifacts/<job_id>/evidence/`
thumbnails (ordered `sequence_index`). Partial is kind-agnostic; F-18
never edits it; the seam tolerates missing `pose_confidence`.

### 4. `artifacts/` subprefix reservation

F-17 → `artifacts/<job_id>/evidence/<seq>.jpg`; F-18 →
`artifacts/<job_id>/projected/<seq>.(png|svg)`. Both signed by
`ArtifactUrlMinter` (artifacts/-locked). Disjoint — no collision.

### 5. SidecarClient methods (each feature adds its own)

- F-17: `#render_evidence_thumbnails(job_id:, photos:)` + `EVIDENCE_THUMBNAILS_TIMEOUT_SECONDS`
- F-18: `#project_photo(job_id:, photo_ref:, world_mesh_ref:, camera_pose:, facets:, features:, arkit_to_utm:, utm_epsg:, pose_confidence:)` + `PROJECT_PHOTO_TIMEOUT_SECONDS`

### 6. `ProjectedOverlay` model (new table, F-18, in BARRIER)

UUID PK; `capture_id` FK + **unique** index (one overlay per capture);
`composite_ref`, `overlay_svg_ref`, `pose_confidence`,
`low_pose_confidence:boolean`, `occluded_facet_ids:jsonb`, timestamps.
`belongs_to :capture`; `Capture has_one :projected_overlay`. Migration via
`bin/rails generate migration`.

### 7. `ViewerPayload.on_site_visualizations` (F-18)

`MeasurementViewerSerializer#as_json` + `viewer/types.ts` add
`on_site_visualizations:[{composite_url, overlay_svg_url, pose_confidence, low_pose_confidence, caption}]`.

### 8. `json_export` 1.0.0 → **1.1.0** (F-18, additive)

`JobExportSerializer#to_h` adds
`on_site_visualizations:[{photo_url, composite_url, overlay_svg_url, pose_confidence}]`;
`shared/json_export.schema.json` extended additively + const bump;
`JSON_EXPORT_CHANGELOG.md` + drift spec. Auth + public routes identical
(ADR-015 parity).

## Barrier work (one commit, before fan-out)

1. `shared/pipeline_schema.json` → 0.4.0 (all three deltas) + changelog + drift spec.
2. `sidecar/contracts/pipeline.py` Pydantic models for all 0.4.0 entities.
3. Rails `PipelineSchema` (version + entities) + `SidecarClient` stubs for both new methods.
4. `fusion_orchestrator.rb#fused_provenance` persists `fusion_arkit_to_utm_4x4` + `fusion_utm_epsg` (and the `fuse-capture` sidecar router returns them).
5. `ProjectedOverlay` migration + model + `Capture has_one`.
6. `_evidence_photos.html.erb` frozen interface + `ReportPdf` evidence-list-builder skeleton.

> **Why fusion is in the barrier:** the `FuseCaptureResponse` +
> `fused_provenance` change *feels* like F-18 work, but putting it in the
> barrier keeps W-18 from editing fusion code the schema also touches —
> avoiding a parallel-build collision. W-18's only remaining fusion edit is
> the one-line `ProjectionJob.perform_later` enqueue.

## Coordinate-frame decision (F-18, load-bearing)

Project in **`arkit_session_local`** (camera extrinsics + occlusion mesh
are native to it). Facets (WGS84) are transformed *in*: WGS84 → local UTM →
(inverse ICP) → arkit-local. The ICP arkit→UTM transform is persisted to
provenance during fusion (barrier item 4); fallback is recompute from
`world_mesh_ref` + lidar inside `project-photo`. Occlusion uses **trimesh
ray-cast (not pyrender)** — CI-friendly, no OSMesa/EGL.

## Resolved decisions (Keith, 2026-05-29 — recommended defaults)

1. **Schema-version coordination** *(both features)* — **DECIDED: one
   merged `0.4.0` barrier** (single version, single changelog entry, all
   deltas; both clients move once). Neither workstream edits
   `shared/pipeline_schema.json` after fan-out.
2. **ICP-transform delivery** *(F-18)* — **DECIDED: persist `arkit_to_utm`
   to `Measurement.provenance` during fusion** (one source of truth). The
   recompute-from-mesh+lidar path remains only as the fallback for
   measurements predating the field.
3. **Visual-regression artifact** *(F-18)* — **DECIDED: SVG is the primary
   regression artifact** (vector, byte-stable across hosts); PNG composites
   are checked with a **tolerance-based** image diff, not exact bytes.
4. **`pose_confidence`** *(F-18)* — **DECIDED: default threshold `0.7`, env
   var `PROJECTION_POSE_CONFIDENCE_MIN`.** Formula: Rails-derived from
   `icp_rmse_m` (session-level) combined with a per-photo extrinsics
   sanity check (finite, orthonormal-ish rotation, plausible translation);
   **Rails is the single authority** and gates pre-call — the sidecar may
   only *narrow* (never raise) the value it returns. Exact weighting is a
   builder detail, monotonic-decreasing in `icp_rmse_m`.
5. **Page-number approach** *(F-17)* — **DECIDED: Grover `footerTemplate`**
   (`displayHeaderFooter`), and the existing fixed `.report-attribution`
   footer is reconciled into / given clearance below the page footer (the
   golden catches a collision).
6. **Visit-block distance threshold** *(F-17)* — **DECIDED: `12 m`,
   env-configurable** via `CLAIM_PDF_VISIT_RADIUS_M` (mirrors the F-18
   threshold-as-env pattern).
7. **Facet↔gallery cross-highlight** *(F-18)* — **DECIDED: v1 scope.** The
   gallery + the bidirectional facet↔photo highlight ship together (it is
   the demo's "magic moment"); if it proves to overrun, it is the
   designated descope, not a planned cut.

## Acceptance (from the specs)

- **F-17:** golden-PDF visual regression (with/without iOS); conditional
  rendering (no empty placeholders); provenance-driven methodology text;
  byte-reproducible PDF; `docs/CLAIM_PDF_REVIEW.md` adjuster review.
- **F-18:** ±2px projection math; occlusion dashed/omitted; pose-confidence
  gate + warning; end-to-end fixture composites in
  `spec/fixtures/projections/`; 8 photos < 30s; both drift specs green.

---

### Planning provenance

F-17's plan was produced by the opus planning pass and recovered intact.
The F-18 3-draft panel completed its analysis but hit a structured-output
size limit on emit; its load-bearing findings (the trapped ICP transform /
arkit-local frame decision; `parse_obj` returns verts-only so occlusion
needs a faces-aware trimesh load) were salvaged from the draft transcripts
and synthesized into the F-18 plan + these contracts. No reasoning was lost.
