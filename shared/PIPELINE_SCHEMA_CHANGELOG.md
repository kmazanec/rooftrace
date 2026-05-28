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

## 0.2.0 — 2026-05-28 (F-05–F-09)

Additive: the per-stage request/response **envelopes** the geospatial pipeline
track exchanges with the sidecar. The 0.1.0 entities (`Polygon`, `LiDARResult`,
`Facet`, `Feature`, `GeometrySource`, `Confidence`) are reused unchanged; these
new `$defs` wrap them per stage:

- `SourceAttribution` — the honest-attribution block (name/license/url/
  retrieved_at) every external-data stage returns; replaces the ad-hoc `sources`
  blobs the feature specs sketched. Cross-cutting per ROADMAP "License & attribution".
- F-05: `ResolveAddressRequest` / `ResolveAddressResponse`.
- F-06: `IngestLidarRequest` / `IngestLidarResponse` (wraps `LiDARResult`, adds
  `utm_zone` + `bounds_utm`).
- F-07: `RefineOutlineRequest` / `RefineOutlineResponse`.
- F-08: `FitPlanesRequest`, `FallbackMeasurementRequest`, `MeasurementGeometry`.
- F-09: `DetectFeaturesRequest` / `DetectFeaturesResponse`.

Two decisions that resolve drift between the feature specs and the contract,
made here at the source of truth (nothing is deployed, so we picked the right
shape rather than preserving the specs' sketches):

1. **Blobs cross by reference, not URL.** Point clouds and image tiles are
   referenced by a Spaces object key (`point_array_ref`, `image_tile_ref`) in the
   one prefixed bucket (ADR-010), never a raw `s3://…` URL. The orchestrator
   (F-10) mints a short-lived signed URL when a stage must fetch one — that's an
   internal detail, not contract surface. (Supersedes the F-06 spec's
   `point_array_url` + `s3://rooftrace-cache/…`.)
2. **Model identity is not geometry provenance.** A detected `Feature.source`
   stays the `GeometrySource` enum (`imagery` for a VLM detection on a satellite
   tile); the model that produced it lives in the response-level `detector`
   field. (Supersedes the F-09 spec's `source: "vlm:gemini-flash-…"`, which would
   have polluted the provenance enum.)

No 0.1.0 field changed type or requiredness, so this is a minor bump; the
sidecar's major-version gate still accepts 0.1.x and 0.2.x callers.

## 0.1.0 — 2026-05-28 (F-02)

Initial release. Defines the entity shapes the pipeline track (F-05–F-10) and
the app/iOS/stretch features (F-14, F-16, F-18) build against:

- `Confidence`, `GeometrySource` — shared honest-uncertainty primitives.
- `JobSpec`, `Address`, `Polygon` (GeoJSON/WGS84).
- `LiDARResult` (status enum `LIDAR_AVAILABLE`/`LIDAR_MISSING`, point-array ref,
  USGS work-unit metadata).
- `Facet` (vertices, pitch ratio + degrees, area sq ft, source, confidence).
- `Feature` (label enum, `bbox_norm`, verified, source, confidence).
- `Measurement` (composes the above).
- `PipelineRequest` / `PipelineResponse`.
- `RenderImageRequest` / `RenderImageResponse` (ADR-014 PDF prerender).
- `FuseCaptureRequest` / `FuseCaptureResponse` (F-16 ICP fusion).
- `ProjectPhotoRequest` / `ProjectPhotoResponse` (F-18 AR overlay).

Boundary convention: all coordinates WGS84 (EPSG:4326), GeoJSON [lon, lat]
order. Local UTM (ADR-003) is internal to the sidecar and never crosses the
contract.
