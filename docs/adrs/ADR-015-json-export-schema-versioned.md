# ADR-015: Treat the JSON export as a versioned public contract

**Status:** Accepted · **Date:** 2026-05-27 · **Stretch:** no
**Supersedes:** none · **Superseded by:** none

## Context

The brief specifies an "Optional JSON export for deeper integrations
(insurance, estimating tools)." That word *integrations* is the load-
bearing one: a JSON export the customer is going to script against
**is a contract**, not just a serialization. Insurance carriers,
Xactimate, JobNimbus, Roofr — any downstream consumer that parses
this JSON gets locked to its shape.

Therefore the JSON export needs:

1. **A versioned schema** so we can evolve without breaking consumers.
2. **A stable field naming convention** that matches industry norms
   (square feet, pitch as N/12, decimal-degree coordinates).
3. **Provenance metadata** — *which* imagery, *which* LiDAR work
   unit, *which* model versions produced this answer — because
   adjusters and insurers will ask "how do I know?"
4. **Linkable artifacts** rather than inline base64 blobs (the PDF
   and 3D model are referenced by URL, not embedded).

This ADR is mostly a documentation discipline ADR — there's no
real "should we have a schema" debate, but there is a "what level of
contract discipline" decision.

## Options considered

**A. Versioned schema, documented, treated as a public contract.**
JSON Schema (`shared/json_export.schema.json`) versioned via a
`schema_version` field in every export; CHANGELOG entries on bump;
backward-compat helper to upgrade old documents.
*Tradeoff:* up-front docs + test discipline; the right answer if any
real customer will integrate.

**B. Ad-hoc dump from internal models.** Whatever Rails `to_json`
emits.
*Tradeoff:* zero overhead now; pure pain when the first customer
integration breaks on a field rename.

**C. Hand-rolled per-customer formats.** Bespoke per integration.
*Tradeoff:* dies the moment we have two customers; not a v1 concern.

## Decision

**A. Versioned JSON Schema treated as a public contract**, with:

- `schema_version` field (semver) on every export.
- Schema lives at `shared/json_export.schema.json` and is the
  single source of truth.
- Rails serializer + schema test (validates one fixture export
  against the schema in CI).
- A `CHANGELOG.md` section dedicated to schema changes.

## Rationale

This is the lowest-cost discipline that prevents the highest-cost
failure: a customer who built a Xactimate pipeline on v1.0 of our
JSON and silently breaks when we rename a field in v1.1. Even at
v1 demo scale, shipping the schema *as documented contract* costs
us a JSON Schema file and one test; the alternative costs us
trust the first time we touch the format.

The CTO-defense framing is: *"The PDF is the human-facing artifact;
the JSON is the machine-facing artifact. The PDF can be redesigned
freely. The JSON is treated as a versioned public contract from
day one, because the moment a customer's Xactimate pipeline depends
on it, breaking changes cost trust."*

## Tradeoffs & risks

- **Naming bikeshed up front.** Mitigation: lift conventions from
  Xactimate / EagleView JSON outputs where they have analogues
  (square feet uses `area_sq_ft`; pitch reported both as `pitch_ratio`
  e.g. `"6/12"` and `pitch_degrees`).
- **Schema discipline can ossify.** Mitigation: semver lets us
  bump major version for breaking changes; document the deprecation
  window.
- **JSON Schema is verbose.** Mitigation: small, focused; v1 has
  ~40 fields total.

## Consequences for the build

- **Top-level shape:**
  ```json
  {
    "schema_version": "1.0.0",
    "job_id": "uuid",
    "generated_at": "2026-05-27T18:42:11Z",
    "address": { "raw": "...", "geocoded": {"lat": ..., "lng": ...} },
    "measurement": {
      "total_area_sq_ft": 2847.4,
      "total_perimeter_ft": 215.3,
      "primary_pitch_ratio": "6/12",
      "primary_pitch_degrees": 26.57,
      "facets": [
        {
          "id": "facet-1",
          "vertices_lat_lng": [[lat, lng], ...],
          "area_sq_ft": 614.2,
          "pitch_ratio": "6/12",
          "pitch_degrees": 26.57,
          "source": "lidar+imagery",
          "confidence": 0.92
        }
      ],
      "features": [
        {
          "id": "feat-1",
          "label": "chimney",
          "position_lat_lng": [lat, lng],
          "confidence": 0.88,
          "source": "vlm:gemini-flash-2.0",
          "verified": true
        }
      ]
    },
    "provenance": {
      "imagery_source": "NAIP",
      "imagery_acquired_at": "2024-08-12",
      "lidar_source": "USGS 3DEP",
      "lidar_work_unit": "NE_Southeast_2021_D21",
      "lidar_acquired_at": "2021-04-15",
      "sam2_version": "2.1",
      "vlm_model": "gemini-flash-2.0",
      "pipeline_version": "1.0.0"
    },
    "artifacts": {
      "pdf_url": "https://.../report.pdf",
      "model_3d_url": null,
      "share_url": "https://.../r/<token>"
    },
    "warnings": [
      "lidar_acquired_at is over 4 years old; verify recent construction"
    ]
  }
  ```
- **`shared/json_export.schema.json`** captures the full contract;
  imported by Rails (validate on serialize) and the sidecar
  (validate on receive if it ever produces this format).
- **`shared/JSON_EXPORT_CHANGELOG.md`** lists schema changes by
  semver; v1.0.0 = initial release.
- **Test:** a single fixture (`spec/fixtures/sample_export.json`)
  validates against the schema in CI.
- **Documentation:** the `/api/v1/jobs/:id.json` endpoint's
  OpenAPI spec links to the JSON Schema.
- **Backward compatibility:** v1.x changes are additive (new
  optional fields); v2.x reserved for breaking changes.

## Amendment (2026-05-28) — `model_3d_url` is JSON null in v1

Reconciliation discovered while building the v1 export schema:

- **`artifacts.model_3d_url` is typed as JSON `null` (`"type": "null"`),
  not a URL string, in schema version 1.0.0.** The 3D model export is
  **deferred** to a future schema bump; there is no `.glb` artifact in
  v1. The original example above showed `"model_3d_url":
  "https://.../roof.glb"`, which was written speculatively and does not
  reflect the shipped v1 contract — the example has been corrected to
  `model_3d_url: null` so the ADR and `shared/json_export.schema.json`
  agree.
- The field remains **present and required** (const-null) rather than
  omitted, so consumers can rely on its key existing; when 3D export
  lands it becomes a nullable URL string under a v1.x additive (or v2)
  schema change per the backward-compatibility policy above.
