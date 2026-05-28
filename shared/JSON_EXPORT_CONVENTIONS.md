# JSON export — field conventions

The public JSON export (`shared/json_export.schema.json`, ADR-015) is the
integration contract downstream consumers (insurance estimating tools,
Xactimate, JobNimbus, EagleView-style workflows) script against. It is
**independent** of the internal pipeline schema (`shared/pipeline_schema.json`):
it has its own `schema_version` (`1.0.0`), versioned per semver.

This document records the field-naming rationale and — critically — the points
where the **public export shape deliberately diverges from how the data is
stored internally**. Those divergences are the entire reason a serializer
(`app/serializers/job_export_serializer.rb`) exists.

## Field-naming choices

| Field | Convention | Why |
| --- | --- | --- |
| `*_sq_ft` (`total_area_sq_ft`, `area_sq_ft`) | Square feet, not m². | Roofing/insurance work in imperial; sq ft is the Xactimate/EagleView presentation unit. Metric math stays internal (local-UTM); units are converted only at this export boundary (CRS-discipline rule). |
| `*_perimeter_ft` | Linear feet. | Same rationale. |
| `pitch_ratio` | Number, rise per 12 of run (e.g. `6.0` ⇒ a 6/12 roof). | Pitch is universally quoted as "N in 12" in US roofing. **Stored and exported as a number, not the "6/12" string** — the schema is frozen on the numeric form, which is unambiguous to parse and lets consumers format it however they like. |
| `pitch_degrees` | Decimal degrees. | Convenience for tools that want slope angle directly; derived, see below. |
| coordinates | `[lat, lng]` decimal degrees. | Insurance/mapping tools expect lat-first. **The internal store is GeoJSON `[lon, lng]` (= `[lon, lat]`); the export FLIPS to `[lat, lng]`.** See the footgun note below. |
| `confidence` | Number in `[0, 1]`. | Honest-uncertainty rule — every measured value carries its confidence and `source`; neither is ever dropped. |
| `source` | `GeometrySource` enum (`lidar` \| `imagery` \| `fusion` \| `capture` \| `manual`). | Mirrors the internal provenance enum so a consumer can tell LiDAR-grade from imagery-only geometry. |

## Divergences from internal storage (the serializer's job)

1. **Coordinate order is FLIPPED.** Internally, `Facet#vertices` are WGS84
   `[lon, lat]` (GeoJSON order). The export emits `[lat, lng]`. This is a
   silent-bug footgun: both orders are arrays of two numbers, so a missing flip
   ships subtly-wrong coordinates that still pass schema validation. The
   serializer has an explicit test asserting the flip; do not "simplify" it away.
   The optional internal elevation (a possible 3rd vertex component) is dropped —
   the export carries only the two horizontal components.

2. **`predominant_pitch_degrees` is DERIVED, not stored.** Only the ratio is
   persisted (`Measurement#predominant_pitch_ratio`). The export computes
   `atan(ratio / 12)` in degrees. Likewise per-facet `pitch_degrees` passes
   through from storage (it *is* stored per facet).

3. **`geocode` is renamed.** Internally the geocode is an `Address`
   (`{raw, normalized, lon, lat, source, confidence}`). The export emits
   `{lat, lng, confidence}` — `lon` renamed to `lng`, raw/normalized/source
   omitted (the address string lives at `job.address`).

## Documented v1.0.0 limitations

- **No feature geographic position.** Detected features carry `bbox_norm`
  (normalized `[0,1]` **image space** against the satellite tile), not a
  geographic centroid. There is no tile georeference available to the Rails
  serializer, so a `position_lat_lng` would have to be **faked** — it is omitted
  entirely in v1.0.0. Additive in a later minor if the orchestrator starts
  emitting a geographic centroid.

- **Provenance is best-effort.** The orchestrator produces a **nested**
  provenance shape (`{attributions, retrieved_at, lidar_work_unit, detector,
  sam2_backend, pipeline_schema_version, generated_at}`), not a flat set of
  source/version fields. The schema marks every provenance field optional
  (`additionalProperties: true`) and the export passes the nested shape through
  best-effort — keys the orchestrator did not produce simply don't appear.

- **`artifacts.model_3d_url` is always `null`** (3D model export deferred).

- **`artifacts.pdf_url` is `null` until the PDF exists** in Spaces; the export
  links/probes, it never triggers PDF generation.

## Field-naming reference (manual setup)

These names were **locked by tech-lead fiat** per ADR-015, not chased against a
proprietary sample. Authoritative Xactimate/EagleView JSON outputs are not freely
public (they sit behind vendor agreements). The locked names (`area_sq_ft`,
`pitch_ratio` rise-per-12, `pitch_degrees`, `[lat, lng]`) follow the widely-used
public conventions in those tools' human-facing reports and roofing-industry
usage. Because the schema is a **prototype with no external consumer locked in
yet** (ADR-015 amendment), v1.0.0 can change freely; a future authoritative
sample that contradicts these names would be reconciled in a `v2.0` break.

## Versioning philosophy

- **`v1.x` is additive-only** — new optional fields, no removals or shape
  changes to existing required fields.
- **`v2.x` is breaking** — required-field removals, renames, type changes.
- Any PR that edits `shared/json_export.schema.json` must add a
  `shared/JSON_EXPORT_CHANGELOG.md` entry and keep every `v1.0.0` required field
  required (the contract spec is the drift guard).
