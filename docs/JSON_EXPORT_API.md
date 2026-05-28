# JSON export API

The roof measurement is available as a versioned, schema-validated JSON document
(ADR-015). It is a **public contract** — downstream consumers (insurance
estimating tools, Xactimate/JobNimbus-style workflows) script against it.

- **Authoritative schema:** [`shared/json_export.schema.json`](../shared/json_export.schema.json)
  (JSON Schema draft 2020-12, `schema_version` `1.0.0`).
- **Field conventions + divergences:** [`shared/JSON_EXPORT_CONVENTIONS.md`](../shared/JSON_EXPORT_CONVENTIONS.md).
- **Changelog / versioning:** [`shared/JSON_EXPORT_CHANGELOG.md`](../shared/JSON_EXPORT_CHANGELOG.md).

Both endpoints return the **identical** document — the only differences are how
access is granted and the CORS posture.

## `GET /api/v1/jobs/:id.json` — contractor (auth-required)

For the logged-in contractor. Locked down: **no CORS header**.

| Outcome | Status | Notes |
| --- | --- | --- |
| Not authenticated | **`401`** | `{"error":"authentication required"}`. **Not** a `302` redirect — downstream tools don't follow redirects, so this fails cleanly. No `Location` header. |
| Unknown job id | `404` | `head :not_found`. |
| Job not yet measured | `200` | Document with a `null` `measurement` and `null` artifact URLs (never a `500`). |
| Ready job | `200` | Full export document. |

```bash
# Authenticate via the dev-login session cookie, then fetch the export.
curl -b cookies.txt https://rooftrace.biograph.dev/api/v1/jobs/<job-id>.json
```

## `GET /r/:token.json` — public share (token-gated)

For sharing with an adjuster / homeowner / downstream tool. The 32-char share
token IS the access grant. Permissive CORS so browser-based tools can fetch it.

| Outcome | Status | Notes |
| --- | --- | --- |
| Unknown / bad token | `404` | `head :not_found` — never a redirect; never leaks app existence. |
| Job not yet measured | `200` | Document with a `null` `measurement` (never a `500`). |
| Valid token, ready job | `200` | Full export document. |

Response headers on success:

- `Access-Control-Allow-Origin: *` — browser-based estimating tools can fetch
  cross-origin (CORS is set in the controller; there is no rack-cors gem).
- `X-Robots-Tag: noindex` — the share token is a URL-borne bearer credential, so
  the document is kept out of search indexes.

```bash
curl https://rooftrace.biograph.dev/r/<share-token>.json
```

## Example payload

See [`spec/fixtures/json_export/sample.json`](../spec/fixtures/json_export/sample.json)
for a complete, schema-green example (one facet, one feature, full provenance,
`share_url` set with `pdf_url`/`model_3d_url` null). Abbreviated:

```json
{
  "schema_version": "1.0.0",
  "job": { "id": "0f8d6b1e-…", "address": "1600 Pennsylvania Ave NW", "status": "ready" },
  "measurement": {
    "total_area_sq_ft": 1200.0,
    "predominant_pitch_ratio": 6.0,
    "predominant_pitch_degrees": 26.57,
    "facets": [{ "facet_id": "F1", "vertices": [[38.8977, -77.0365]], "area_sq_ft": 600.0 }],
    "features": [{ "label": "chimney", "bbox_norm": [0.42, 0.31, 0.48, 0.39], "verified": true }],
    "geocode": { "lat": 38.8977, "lng": -77.0365, "confidence": 0.95 }
  },
  "provenance": { "detector": "openrouter", "sam2_backend": "modal" },
  "artifacts": { "pdf_url": null, "share_url": "https://rooftrace.biograph.dev/r/abc123", "model_3d_url": null }
}
```

Note: coordinates are `[lat, lng]` (flipped from the internal `[lon, lat]`),
areas in square feet, pitch as rise-per-12 plus derived degrees. See the
conventions doc for the full rationale and v1.0.0 limitations.
