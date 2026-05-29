# JSON export schema — changelog

Tracks every released version of the public JSON export contract
(`shared/json_export.schema.json`, ADR-015). This schema is versioned
**independently** of the internal pipeline schema.

Semver rules:

- **major** (`2.0.0`) — breaking: a required field removed/renamed, a type
  narrowed, a `const` changed.
- **minor** (`1.1.0`) — additive: a new **optional** field; an enum value added.
- **patch** (`1.0.1`) — docs/examples/descriptions only; no shape change.

Any PR editing `shared/json_export.schema.json` MUST add an entry here and keep
every `1.0.0` required field required (the contract spec
`spec/contracts/json_export_schema_spec.rb` is the drift guard).

---

## 1.1.0 — 2026-05-29

Additive (minor bump): on-site visualizations. Every `1.0.0` required field stays
required; `additionalProperties: false` is preserved on the measurement object.

- _Added:_ `measurement.on_site_visualizations` — an array (optional; absent/empty
  when the job has no on-site capture). Each item:
  `{ photo_url (string|null), composite_url (string|null), overlay_svg_url
  (string|null), pose_confidence (number|null) }`, `additionalProperties: false`.
  Projected on-site visualizations: a capture photo with the measured roof
  projected onto it.
- _Changed:_ `schema_version` const `1.0.0` → `1.1.0`.

---

## 1.0.0 — 2026-05-28

Initial release.

**Top-level** (required: `schema_version`, `job`, `measurement`, `provenance`,
`artifacts`; `additionalProperties: false`):

- `schema_version` — `const "1.0.0"`.
- `job` — `{ id (req, string), address (string|null), status (req, string) }`.
- `measurement` — `object | null`; required `facets`, `features`. Fields:
  `generated_at`, `source`, `confidence`, `total_area_sq_ft`,
  `total_perimeter_ft`, `predominant_pitch_ratio` (rise-per-12),
  `predominant_pitch_degrees` (derived), `warnings` (string[]),
  `facets[]`, `features[]`, `geocode`.
  - `facets[]` — required `facet_id`, `vertices`; plus `pitch_ratio`,
    `pitch_degrees`, `area_sq_ft`, `source`, `confidence`. `vertices` are
    `[lat, lng]` (FLIPPED from the internal `[lon, lat]`).
  - `features[]` — required `label`, `bbox_norm`, `verified`; plus `source`,
    `confidence`. `bbox_norm` is `[x0, y0, x1, y1]` in `[0,1]` image space. No
    geographic position (documented v1 limitation).
  - `geocode` — `object | null`: `{ lat, lng, confidence }`.
- `provenance` — `object | null`, `additionalProperties: true`, every field
  optional/best-effort: `attributions`, `retrieved_at`, `detector`,
  `sam2_backend`, `lidar_work_unit`, `pipeline_schema_version`, `generated_at`.
- `artifacts` — required `pdf_url`, `share_url`, `model_3d_url`. `model_3d_url`
  is `const null` (3D export deferred). `pdf_url` is `null` until the PDF exists.

---

## Unreleased

_Template for the next entry — copy under a new version heading:_

- _Added:_ …
- _Changed:_ …
- _Deprecated/Removed:_ … (a removal ⇒ major bump)
