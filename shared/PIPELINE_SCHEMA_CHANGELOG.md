# Pipeline schema changelog

The contract in `shared/pipeline_schema.json` is the source of truth for the
Rails↔sidecar boundary (ADR-008). It is versioned by the top-level `$id` and the
`pipelineSchemaVersion` field. Both languages validate the same fixture corpus
(`spec/fixtures/pipeline/`), so any change here must keep both sides green.

Versioning: semver. Bump **minor** for additive, backward-compatible changes
(new optional field, new `$def`); bump **major** for breaking changes (removed
or renamed field, tightened required set, changed type). The sidecar's
`/pipeline/run-validate` rejects a request whose `pipelineSchemaVersion` major
differs from its own.

## 0.6.0 — 2026-06-04 (LiDAR roof-model diagnostics)

Additive (minor bump): the LiDAR plane-fit response can now include optional
roof-model diagnostics. Existing `MeasurementGeometry` fields remain stable:
`facets` still carry WGS84 boundaries and true slope-adjusted `area_sq_ft`, and
fallback measurements may return `roof_model: null`.

New `$defs`:

- `RoofModelDiagnostics` — model version, plane/facet/edge counts, plan-view
  coverage ratio, area/boundary methods, and model warnings for the internal
  LiDAR roof model used to derive the legacy facet list.

Amended `$defs`:

- `MeasurementGeometry` — added optional nullable `roof_model`.
- `FuseCaptureRequest` — added optional nullable `refined_polygon`, allowing
  capture fusion to constrain re-fit facets through the same roof model when
  Rails has a prior refined outline.

## 0.5.0 — 2026-06-03 (interactive LiDAR point-cloud overlay)

Additive (minor bump): a browser-facing stage that turns a cached cropped LiDAR
array into renderable points for the interactive report overlay (ADR-013). No
0.1.x–0.4.x field changed type or requiredness, so the sidecar's major-version
gate still accepts 0.1.x–0.5.x callers.

New `$defs`:

- `LidarPointsRequest` / `LidarPointsResponse` — decode the `point_array_ref` a
  prior `IngestLidarResponse` produced, uniformly downsample to a cap, reproject
  x,y from local UTM back to WGS84, and convert z meters→feet. Returns `points`
  as `[lon, lat, elevation_ft]`. The request carries the `building_polygon` (the
  same footprint the ingest used); the sidecar derives the local UTM zone from
  its centroid — the deterministic function the ingest used to reproject the
  points — so the zone need not be persisted Rails-side. UTM stays internal
  (ADR-003); only WGS84 crosses the contract. Rails proxies this to the report
  viewer (the sidecar is internal-only) on both the contractor and token-gated
  public paths.

## 0.4.0 — 2026-05-29 (on-site evidence + AR photo-projection contract surface)

Additive (minor bump): two stretch surfaces — report on-site evidence and the
AR photo-projection overlay — land their contract shapes ahead of their build.
No 0.1.x–0.3.x field changed type or requiredness, so the sidecar's
major-version gate still accepts 0.1.x–0.4.x callers.

New `$defs`:

- `RenderEvidenceThumbnailsRequest` / `RenderEvidenceThumbnailsResponse` — the
  report-side stage that renders normalized evidence thumbnails from a job's
  capture photos. Source photos are `uploads/` keys; thumbnails are written under
  the `artifacts/<job_id>/evidence/` prefix and returned in `sequence_index`
  order.

Amended `$defs` (all new fields OPTIONAL — existing 0.1.x–0.3.x payloads stay
valid; `additionalProperties: false` is preserved everywhere):

- `FuseCaptureResponse` — added `arkit_to_utm` ([16] row-major 4x4, or null) and
  `utm_epsg` (int, or null): the SOLVED fusion transform (ARKit capture frame ->
  local UTM) and its CRS, returned on ICP convergence so a later photo-projection
  stage reuses it rather than re-solving.
- `ProjectPhotoRequest` — added `world_mesh_ref` (recompute-from-mesh fallback),
  `arkit_to_utm` ([16] or null), `utm_epsg`, `pose_confidence`, and `features`
  (project detected features alongside facets).
- `ProjectPhotoResponse` — added `composite_ref` (photo+overlay composite),
  `overlay_svg_ref` (vector overlay), `pose_confidence`, and `occluded_facet_ids`
  (facets fully behind a nearer surface in the z-buffer). The projected artifacts
  live under the `artifacts/<job_id>/projected/` prefix — disjoint from the
  `evidence/` prefix above, so the two never collide.

## 0.3.0 — 2026-05-28 (iOS capture-bundle fusion — implemented, no version bump)

The `FuseCaptureRequest` / `FuseCaptureResponse` `$defs` reserved at 0.1.0 are
now **implemented** end-to-end at 0.3.0 (Rails `SidecarClient#fuse_capture` +
the `POST /pipeline/fuse-capture` sidecar stage). **No `pipeline_schema.json`
version bump** — both entities already exist in the 0.1.0/0.2.0/0.3.0 schema and
their shapes are unchanged, so this is purely turning on reserved surface.

- `FuseCaptureRequest` carries `capture_mesh_ref`, the Spaces `uploads/` key of
  the ARKit world mesh. The mesh format is **Wavefront OBJ**, always at
  `uploads/<job_id>/arkit_mesh.obj` (so `capture_mesh_ref` ends in
  `arkit_mesh.obj`). The committed fixture `spec/fixtures/pipeline/
  fuse_capture_request.valid.json` reflects this (its `capture_mesh_ref` was
  corrected from a `.bin` placeholder to `.obj`).
- `FuseCaptureResponse` carries the fused `Measurement` (source
  `GeometrySource.fusion`) on ICP convergence and is absent on failure;
  `icp_rmse_m` carries the alignment residual either way. New fixtures:
  `fuse_capture_response.valid.json` (full Measurement, `icp_rmse_m` 0.05) and
  `fuse_capture_response.no_measurement.valid.json` (no Measurement,
  `icp_rmse_m` 0.62).

Companion (out-of-band, not part of `pipeline_schema.json`): the iOS
**capture-bundle manifest** (`session.json`) is frozen at `manifest_version`
`1.0.0`, with its own machine-readable contract at
`shared/ios_session_schema.json` (JSON Schema 2020-12) and the frozen decisions
documented in ADR-007 (Amendment: capture-bundle manifest freeze). That manifest
is the iOS-upload contract, distinct from the Rails↔sidecar pipeline schema; the
sidecar reads `uploads/<job_id>/session.json` directly for the GPS seed rather
than carrying it on `FuseCaptureRequest`.

## 0.3.0 — 2026-05-28 (render-imagery)

Additive: the `render-imagery` sidecar stage envelope the orchestrator needs to
fetch a satellite tile for a building before SAM2 refine and VLM
detection run. Per ARCHITECTURE.md the sidecar owns all geospatial-data fetch
(satellite imagery), so the tile fetch lives in the sidecar as a new stage rather than in
Rails. New `$defs`:

- `RenderImageryRequest` — `building_polygon` (reuses `Polygon`), `size_px`
  (target edge size, ≥1), optional `target_gsd_m` (ground-sample-distance hint).
- `RenderImageryResponse` — `image_tile_ref` (Spaces `cache/` key for the stored
  PNG) + `image_geo_bounds` ([west, south, east, north] WGS84) + `attribution`
  (reuses `SourceAttribution`) + `warnings`. The `image_tile_ref` /
  `image_geo_bounds` pair matches `RefineOutlineRequest` / `DetectFeaturesRequest`
  inputs so the orchestrator passes them straight through.

No 0.1.x/0.2.x field changed type or requiredness, so this is a minor bump; the
sidecar's major-version gate still accepts 0.1.x/0.2.x/0.3.x callers.

## 0.2.0 — 2026-05-28

Additive: the per-stage request/response **envelopes** the geospatial pipeline
track exchanges with the sidecar. The 0.1.0 entities (`Polygon`, `LiDARResult`,
`Facet`, `Feature`, `GeometrySource`, `Confidence`) are reused unchanged; these
new `$defs` wrap them per stage:

- `SourceAttribution` — the honest-attribution block (name/license/url/
  retrieved_at) every external-data stage returns; replaces the ad-hoc `sources`
  blobs the feature specs sketched. Cross-cutting per ROADMAP "License & attribution".
- `ResolveAddressRequest` / `ResolveAddressResponse`.
- `IngestLidarRequest` / `IngestLidarResponse` (wraps `LiDARResult`, adds
  `utm_zone` + `bounds_utm`).
- `RefineOutlineRequest` / `RefineOutlineResponse`.
- `FitPlanesRequest`, `FallbackMeasurementRequest`, `MeasurementGeometry`.
- `DetectFeaturesRequest` / `DetectFeaturesResponse`.

Two decisions that resolve drift between the feature specs and the contract,
made here at the source of truth (nothing is deployed, so we picked the right
shape rather than preserving the specs' sketches):

1. **Blobs cross by reference, not URL.** Point clouds and image tiles are
   referenced by a Spaces object key (`point_array_ref`, `image_tile_ref`) in the
   one prefixed bucket (ADR-010), never a raw `s3://…` URL. The orchestrator
   mints a short-lived signed URL when a stage must fetch one — that's an
   internal detail, not contract surface. (Supersedes the earlier
   `point_array_url` + `s3://rooftrace-cache/…` sketch.)
2. **Model identity is not geometry provenance.** A detected `Feature.source`
   stays the `GeometrySource` enum (`imagery` for a VLM detection on a satellite
   tile); the model that produced it lives in the response-level `detector`
   field. (Supersedes the earlier `source: "vlm:gemini-flash-…"` sketch, which
   would have polluted the provenance enum.)

No 0.1.0 field changed type or requiredness, so this is a minor bump; the
sidecar's major-version gate still accepts 0.1.x and 0.2.x callers.

## 0.1.0 — 2026-05-28

Initial release. Defines the entity shapes the pipeline track and the
app/iOS/stretch features build against:

- `Confidence`, `GeometrySource` — shared honest-uncertainty primitives.
- `JobSpec`, `Address`, `Polygon` (GeoJSON/WGS84).
- `LiDARResult` (status enum `LIDAR_AVAILABLE`/`LIDAR_MISSING`, point-array ref,
  USGS work-unit metadata).
- `Facet` (vertices, pitch ratio + degrees, area sq ft, source, confidence).
- `Feature` (label enum, `bbox_norm`, verified, source, confidence).
- `Measurement` (composes the above).
- `PipelineRequest` / `PipelineResponse`.
- `RenderImageRequest` / `RenderImageResponse` (ADR-014 PDF prerender).
- `FuseCaptureRequest` / `FuseCaptureResponse` (ICP fusion).
- `ProjectPhotoRequest` / `ProjectPhotoResponse` (AR overlay).

Boundary convention: all coordinates WGS84 (EPSG:4326), GeoJSON [lon, lat]
order. Local UTM (ADR-003) is internal to the sidecar and never crosses the
contract.
