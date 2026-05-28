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
