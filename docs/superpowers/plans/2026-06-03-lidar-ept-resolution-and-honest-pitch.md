# LiDAR EPT Resolution + Honest Pitch — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recover LiDAR for 3DEP-covered addresses whose WESM work-unit name doesn't match the published EPT key, and stop reporting a fabricated `6:12` pitch when no pitch was measured.

**Architecture:** Two coupled changes. (1) A new `ept_index.py` resolves EPT resources by **spatial query of the entwine boundaries** (not WESM-name interpolation); `ingest_lidar` Hop 2 consumes it, falling back to the old name-guess on index-fetch failure. (2) The imagery-only fallback emits **null** primary/facet pitch while keeping the slope-corrected area (the `6:12` survives only as an internal area-inflation factor, disclosed via a new `area_estimated_no_pitch` warning). Null pitch propagates honestly through schema → contract → DB (already nullable) → JSON/PDF (already nil-guarded) → React viewer (bug-fixed).

**Tech Stack:** Python (FastAPI sidecar, shapely, pydantic), Rails 8 (ERB, helpers), TypeScript (deck.gl viewer, vitest). Tests: pytest, RSpec, vitest.

**Design doc:** `docs/superpowers/specs/2026-06-03-lidar-ept-resolution-and-honest-pitch-design.md`

**Worktree note:** Implementation runs in an isolated worktree under `.claude/worktrees/` per the project's branch-isolation rule. All commands below are run from the worktree root unless noted. Sidecar commands run from `sidecar/`; Rails commands from repo root (bare — never prefix with `DATABASE_*`/`PGPASSWORD`).

---

## File Structure

**New files**
- `sidecar/app/lidar/ept_index.py` — fetch + cache the entwine boundaries index; spatial `resolve_ept_resources(bbox)`. One responsibility: name-independent EPT resource resolution.
- `sidecar/tests/lidar/test_ept_index.py` — unit tests over a fixture boundaries GeoJSON.
- `sidecar/tests/fixtures/ept_boundaries_sample.json` — small fixture: a few resources with footprints, incl. one covering the Chicago bbox.

**Modified files**
- `sidecar/app/lidar/ingest.py` — Hop 2 consumes `resolve_ept_resources`; degrade to name-guess on index failure.
- `sidecar/app/planefit/geometry.py` — `fallback_measurement_from_polygon` emits null pitch + `area_estimated_no_pitch`.
- `sidecar/contracts/pipeline.py` — `Facet`, `MeasurementGeometry` pitch fields optional.
- `shared/pipeline_schema.json` — same fields `["number","null"]`, dropped from `required`.
- `sidecar/app/flags.py`, `sidecar/app/boot_checks.py` — `EPT_INDEX_FIXTURE` flag + boot check.
- `sidecar/tests/conftest.py` — opt down to the fixture index.
- `app/views/reports/_limitations.html.erb` — move the point-cloud pitch claim into the LiDAR branch; add imagery-branch copy.
- `app/helpers/reports_helper.rb` — `area_estimated?` seam off the `area_estimated_no_pitch` warning.
- `app/javascript/viewer/types.ts` — pitch `number | null`.
- `app/javascript/viewer/utils/colorByPitch.ts` — explicit "unknown" color for null.
- `app/javascript/viewer/RoofViewer.tsx` — tooltip "pitch unknown" for null.
- `docs/QA-FINDINGS.md` — mark B-7 follow-up done.

---

## Task 1: Schema — allow null pitch in `Facet` and `MeasurementGeometry`

**Files:**
- Modify: `shared/pipeline_schema.json:157-167,176` (Facet), `:753-758,767` (MeasurementGeometry)
- Test: `sidecar/tests/test_pipeline_schema.py` (find existing schema test; if none, add `sidecar/tests/contracts/test_pitch_nullable.py`)

- [ ] **Step 1: Write the failing test**

Add to the sidecar contract tests (e.g. `sidecar/tests/contracts/test_pitch_nullable.py`):

```python
from contracts.pipeline import Facet, MeasurementGeometry, GeometrySource, SchemaVersion


def test_facet_allows_null_pitch():
    f = Facet(
        facet_id="f1",
        vertices=[[0.0, 0.0], [0.0, 1.0], [1.0, 1.0]],
        pitch_ratio=None,
        pitch_degrees=None,
        area_sq_ft=100.0,
        source=GeometrySource.IMAGERY,
        confidence=0.5,
    )
    assert f.pitch_ratio is None and f.pitch_degrees is None


def test_geometry_allows_null_primary_pitch():
    g = MeasurementGeometry(
        pipelineSchemaVersion=SchemaVersion.V1,
        facets=[],
        total_area_sq_ft=100.0,
        primary_pitch_ratio=None,
        primary_pitch_degrees=None,
        source=GeometrySource.IMAGERY,
        confidence=0.5,
    )
    assert g.primary_pitch_ratio is None
```

> NOTE: confirm the actual `SchemaVersion` member (e.g. `SchemaVersion.V1`) and `Confidence` typing by reading `sidecar/contracts/pipeline.py` top-of-file; adjust the literal if needed.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd sidecar && SIDECAR_SHARED_SECRET=test-shared-secret uv run pytest tests/contracts/test_pitch_nullable.py -v`
Expected: FAIL — pydantic `ValidationError` (None not a valid float).

- [ ] **Step 3: Make the pydantic fields optional**

In `sidecar/contracts/pipeline.py`, `Facet` (currently lines 93-94):

```python
    pitch_ratio: Annotated[float, Field(ge=0.0)] | None = None
    pitch_degrees: Annotated[float, Field(ge=0.0, le=90.0)] | None = None
```

`MeasurementGeometry` (currently lines 336-337):

```python
    primary_pitch_ratio: Annotated[float, Field(ge=0.0)] | None = None
    primary_pitch_degrees: Annotated[float, Field(ge=0.0, le=90.0)] | None = None
```

- [ ] **Step 4: Update the JSON schema**

In `shared/pipeline_schema.json`, `Facet.pitch_ratio` (line 157-161) and `pitch_degrees` (162-167):

```json
        "pitch_ratio": {
          "type": ["number", "null"],
          "minimum": 0.0,
          "description": "Rise-over-run, expressed as rise per 12 of run (e.g. 6.0 means 6/12). Null when not measured (imagery-only path)."
        },
        "pitch_degrees": {
          "type": ["number", "null"],
          "minimum": 0.0,
          "maximum": 90.0,
          "description": "Slope angle from horizontal, in degrees. Null when not measured."
        },
```

Facet `required` (line 176) — drop the two pitch keys:

```json
      "required": ["facet_id", "vertices", "area_sq_ft", "source", "confidence"],
```

`MeasurementGeometry.primary_pitch_ratio` (753-757) and `primary_pitch_degrees` (758):

```json
        "primary_pitch_ratio": {
          "type": ["number", "null"],
          "minimum": 0.0,
          "description": "Pitch (rise per 12) of the largest-area facet. Null when not measured (imagery-only path)."
        },
        "primary_pitch_degrees": { "type": ["number", "null"], "minimum": 0.0, "maximum": 90.0 },
```

`MeasurementGeometry` `required` (line 767) — drop the two primary-pitch keys:

```json
      "required": ["pipelineSchemaVersion", "facets", "total_area_sq_ft", "source", "confidence"],
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd sidecar && SIDECAR_SHARED_SECRET=test-shared-secret uv run pytest tests/contracts/test_pitch_nullable.py -v`
Expected: PASS.

- [ ] **Step 6: Run the full sidecar contract/schema suite to confirm no regression**

Run: `cd sidecar && SIDECAR_SHARED_SECRET=test-shared-secret uv run pytest -k "schema or contract" -v`
Expected: PASS (existing LiDAR-path tests still supply real pitch, so non-null still validates).

- [ ] **Step 7: Commit**

```bash
git add shared/pipeline_schema.json sidecar/contracts/pipeline.py sidecar/tests/contracts/test_pitch_nullable.py
git commit -m "feat(schema): allow null pitch in Facet and MeasurementGeometry"
```

---

## Task 2: Fallback geometry — null pitch, keep estimated area, add disclosure warning

**Files:**
- Modify: `sidecar/app/planefit/geometry.py:346-399` (`fallback_measurement_from_polygon`)
- Test: `sidecar/tests/planefit/test_fallback_geometry.py` (find the existing fallback test; if none, create it)

- [ ] **Step 1: Write the failing test**

```python
import math
from app.planefit.geometry import fallback_measurement_from_polygon

# A ~10m x 10m square near Chicago (lon, lat), CCW, closed.
_SQUARE = [[
    [-87.660, 41.990],
    [-87.660, 41.99009],
    [-87.65988, 41.99009],
    [-87.65988, 41.990],
    [-87.660, 41.990],
]]


def test_fallback_emits_null_pitch_but_estimated_area():
    g = fallback_measurement_from_polygon(_SQUARE, inferred_pitch_degrees=26.57, utm_zone=16)
    # Pitch is NOT reported — we did not measure it.
    assert g.primary_pitch_ratio is None
    assert g.primary_pitch_degrees is None
    assert g.facets[0].pitch_ratio is None
    assert g.facets[0].pitch_degrees is None
    # Area is still slope-inflated above the planimetric footprint (the 6:12
    # assumption survives only as an internal area factor).
    assert g.facets[0].area_sq_ft > 0
    # Disclosure warning present alongside the existing fallback marker.
    assert "no_lidar_fallback" in g.warnings
    assert "area_estimated_no_pitch" in g.warnings
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd sidecar && SIDECAR_SHARED_SECRET=test-shared-secret uv run pytest tests/planefit/test_fallback_geometry.py::test_fallback_emits_null_pitch_but_estimated_area -v`
Expected: FAIL — `primary_pitch_ratio` is `6.0`, not None; `area_estimated_no_pitch` missing.

- [ ] **Step 3: Edit `fallback_measurement_from_polygon`**

Keep the area math (lines 361-364 unchanged — the `inferred_pitch_degrees` still inflates area). REMOVE the displayed-pitch derivation and null out the pitch on the facet + geometry. Replace lines 366-399 with:

```python
    # The inferred pitch is used ONLY to inflate planimetric area by 1/cos(pitch)
    # above. We did NOT measure a pitch here, so we DO NOT report one: pitch is
    # null and the area carries an explicit "estimated" disclosure. (The 6:12
    # assumption never surfaces as a measured pitch — see ADR / design doc.)

    # Vertices: exterior ring of the polygon as-is (already WGS84).
    exterior = polygon_coords[0]
    # Remove closing duplicate if present. GeoJSON ring-close is always an exact
    # copy of the first vertex (same JSON number -> same float bits), so list
    # value equality is correct here; no epsilon needed.
    if exterior[0] == exterior[-1]:
        exterior = exterior[:-1]

    facet = Facet(
        facet_id=str(uuid.uuid4()),
        vertices=exterior,
        pitch_ratio=None,
        pitch_degrees=None,
        area_sq_ft=round(area_sq_ft, 2),
        source=GeometrySource.IMAGERY,
        confidence=0.5,  # lower confidence for no-LiDAR path
    )

    return MeasurementGeometry(
        pipelineSchemaVersion=PIPELINE_SCHEMA_VERSION,
        facets=[facet],
        total_area_sq_ft=round(area_sq_ft, 2),
        # Single plan-view facet: its boundary IS the building-outline perimeter.
        total_perimeter_ft=_total_perimeter_ft([facet]),
        primary_pitch_ratio=None,
        primary_pitch_degrees=None,
        source=GeometrySource.IMAGERY,
        confidence=0.5,
        warnings=["no_lidar_fallback", "area_estimated_no_pitch"],
    )
```

> Delete the now-unused `rise_per_12` / `pitch_ratio` lines (366-368). `math` is still used for the area `cos`. `_PITCH_STEP` may now be unused in this function — leave the module constant (other functions use it); only remove the local lines.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd sidecar && SIDECAR_SHARED_SECRET=test-shared-secret uv run pytest tests/planefit/test_fallback_geometry.py -v`
Expected: PASS.

- [ ] **Step 5: Run the planefit suite + any router test that asserts fallback shape**

Run: `cd sidecar && SIDECAR_SHARED_SECRET=test-shared-secret uv run pytest tests/planefit -v`
Expected: PASS. If an existing test asserted `primary_pitch_ratio == 6.0` on the fallback path, update it to assert `is None` + `area_estimated_no_pitch` (that assertion was encoding the bug).

- [ ] **Step 6: Commit**

```bash
git add sidecar/app/planefit/geometry.py sidecar/tests/planefit/test_fallback_geometry.py
git commit -m "feat(geometry): report null pitch on imagery fallback, keep area as disclosed estimate"
```

---

## Task 3: EPT boundaries index — `ept_index.py` (spatial resolution)

**Files:**
- Create: `sidecar/app/lidar/ept_index.py`
- Create: `sidecar/tests/fixtures/ept_boundaries_sample.json`
- Test: `sidecar/tests/lidar/test_ept_index.py`

- [ ] **Step 1: Create the fixture boundaries GeoJSON**

`sidecar/tests/fixtures/ept_boundaries_sample.json` — a FeatureCollection of published EPT resources with footprints. Include one covering the Chicago bbox (~ -87.66, 41.99), one elsewhere, and use a `name`/`id` property that DIFFERS from any WESM work-unit name (that mismatch is the bug we're fixing):

```json
{
  "type": "FeatureCollection",
  "features": [
    {
      "type": "Feature",
      "properties": { "name": "IL_Chicago_LiDAR_2017_published_key" },
      "geometry": {
        "type": "Polygon",
        "coordinates": [[[-88.0, 41.6], [-88.0, 42.1], [-87.4, 42.1], [-87.4, 41.6], [-88.0, 41.6]]]
      }
    },
    {
      "type": "Feature",
      "properties": { "name": "NE_Eastern_published_key" },
      "geometry": {
        "type": "Polygon",
        "coordinates": [[[-97.0, 40.0], [-97.0, 41.0], [-96.0, 41.0], [-96.0, 40.0], [-97.0, 40.0]]]
      }
    }
  ]
}
```

- [ ] **Step 2: Write the failing test**

`sidecar/tests/lidar/test_ept_index.py`:

```python
import json
from pathlib import Path

from app.lidar.ept_index import EptResourceIndex, EptResource

_FIXTURE = Path(__file__).parent.parent / "fixtures" / "ept_boundaries_sample.json"


def _index() -> EptResourceIndex:
    geojson = json.loads(_FIXTURE.read_text())
    return EptResourceIndex.from_geojson(geojson)


def test_resolve_returns_resource_covering_chicago_bbox():
    # bbox around 5859 N Winthrop Ave, Chicago
    bbox = (-87.661, 41.989, -87.659, 41.991)
    resources = _index().resolve(bbox)
    assert [r.key for r in resources] == ["IL_Chicago_LiDAR_2017_published_key"]


def test_resolve_returns_empty_for_uncovered_bbox():
    bbox = (-120.0, 35.0, -119.9, 35.1)  # nowhere in the fixture
    assert _index().resolve(bbox) == []


def test_resource_url_is_the_published_key_not_a_guess():
    r = EptResource(key="IL_Chicago_LiDAR_2017_published_key", geometry=None)
    assert r.ept_url() == (
        "https://s3-us-west-2.amazonaws.com/usgs-lidar-public/"
        "IL_Chicago_LiDAR_2017_published_key/ept.json"
    )
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd sidecar && SIDECAR_SHARED_SECRET=test-shared-secret uv run pytest tests/lidar/test_ept_index.py -v`
Expected: FAIL — `ModuleNotFoundError: app.lidar.ept_index`.

- [ ] **Step 4: Implement `ept_index.py`**

```python
"""Resolve USGS public EPT resources by SPATIAL coverage, not by WESM name.

WESM gives us coverage + collection year, but a WESM work-unit NAME is not
always the key the `usgs-lidar-public` bucket publishes the EPT under (casing,
suffix, project-vs-workunit naming). Guessing the URL from the name 404s and
looks like a coverage gap when the data is actually there. Instead we query the
entwine/USGS boundaries index — a GeoJSON of every PUBLISHED resource's footprint
plus its real key — and pick the resource(s) whose footprint covers the bbox.
"""

from __future__ import annotations

from dataclasses import dataclass

from shapely.geometry import box, shape
from shapely.geometry.base import BaseGeometry

# Same bucket base as ingest.ept_url_for, kept in sync intentionally.
USGS_EPT_BASE = "https://s3-us-west-2.amazonaws.com/usgs-lidar-public"

# Property keys the boundaries index may use for the resource name/key.
_KEY_PROPS = ("name", "id", "key")


@dataclass
class EptResource:
    key: str
    geometry: BaseGeometry | None

    def ept_url(self) -> str:
        return f"{USGS_EPT_BASE}/{self.key}/ept.json"


class EptResourceIndex:
    """A queryable set of published EPT resources with footprints."""

    def __init__(self, resources: list[EptResource]) -> None:
        self._resources = resources

    @classmethod
    def from_geojson(cls, geojson: dict) -> "EptResourceIndex":
        resources: list[EptResource] = []
        for feat in geojson.get("features", []):
            props = feat.get("properties") or {}
            key = next((props[k] for k in _KEY_PROPS if props.get(k)), None)
            geom = feat.get("geometry")
            if not key or geom is None:
                continue
            resources.append(EptResource(key=str(key), geometry=shape(geom)))
        return cls(resources)

    def resolve(self, bbox: tuple[float, float, float, float]) -> list[EptResource]:
        """Published resources whose footprint intersects the bbox, best-fit first.

        Ordering: largest intersection area first (a tight local collect beats a
        sprawling statewide one when both cover the building).
        """
        query = box(*bbox)
        hits: list[tuple[float, EptResource]] = []
        for r in self._resources:
            if r.geometry is not None and r.geometry.intersects(query):
                hits.append((r.geometry.intersection(query).area, r))
        hits.sort(key=lambda t: t[0], reverse=True)
        return [r for _area, r in hits]
```

> The live-fetch + cache wrapper is added in Task 4 (kept separate so this unit is pure/spatial and trivially testable).

- [ ] **Step 5: Run test to verify it passes**

Run: `cd sidecar && SIDECAR_SHARED_SECRET=test-shared-secret uv run pytest tests/lidar/test_ept_index.py -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add sidecar/app/lidar/ept_index.py sidecar/tests/lidar/test_ept_index.py sidecar/tests/fixtures/ept_boundaries_sample.json
git commit -m "feat(lidar): spatial EPT resource index (entwine boundaries)"
```

---

## Task 4: Live fetch + cache for the boundaries index, behind the real/fixture flag

**Files:**
- Modify: `sidecar/app/lidar/ept_index.py` (add `load_ept_index()`)
- Modify: `sidecar/app/flags.py` (add `ept_index_fixture()`)
- Modify: `sidecar/app/boot_checks.py` (boot-check the live index reachable when not fixture)
- Modify: `sidecar/tests/conftest.py` (set `EPT_INDEX_FIXTURE=1`, point at the fixture)
- Test: `sidecar/tests/lidar/test_ept_index.py` (add a loader test)

- [ ] **Step 1: Read the existing flag + boot-check pattern**

Run: `sed -n '1,80p' sidecar/app/flags.py; echo ---; sed -n '1,80p' sidecar/app/boot_checks.py`
Mirror the EXACT polarity of an existing flag (e.g. `lidar_fixture`): real is default; the `*_FIXTURE` env var opts down; boot-check raises in prod when the real prerequisite is missing.

- [ ] **Step 2: Write the failing loader test**

Add to `sidecar/tests/lidar/test_ept_index.py`:

```python
def test_load_ept_index_uses_fixture_under_flag(monkeypatch):
    from app.lidar import ept_index as mod
    monkeypatch.setenv("EPT_INDEX_FIXTURE", "1")
    monkeypatch.setenv("EPT_INDEX_FIXTURE_PATH", str(_FIXTURE))
    mod._cached_index.cache_clear()  # ensure no carryover
    idx = mod.load_ept_index()
    bbox = (-87.661, 41.989, -87.659, 41.991)
    assert [r.key for r in idx.resolve(bbox)] == ["IL_Chicago_LiDAR_2017_published_key"]
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd sidecar && SIDECAR_SHARED_SECRET=test-shared-secret uv run pytest tests/lidar/test_ept_index.py::test_load_ept_index_uses_fixture_under_flag -v`
Expected: FAIL — `load_ept_index` / `_cached_index` not defined.

- [ ] **Step 4: Add the flag**

In `sidecar/app/flags.py`, mirroring `lidar_fixture`:

```python
def ept_index_fixture() -> bool:
    return _truthy(os.environ.get("EPT_INDEX_FIXTURE"))
```

- [ ] **Step 5: Add the loader + cache to `ept_index.py`**

```python
import json
import os
from functools import lru_cache
from pathlib import Path
from urllib.request import urlopen

from app import flags

# The published entwine/USGS boundaries index (resource footprints + keys).
# (Verified live URL goes here at implementation time — see boot check.)
USGS_EPT_BOUNDARIES_URL = "https://usgs-lidar-public.s3-us-west-2.amazonaws.com/boundaries/resources.geojson"

_FIXTURE_ENV = "EPT_INDEX_FIXTURE_PATH"


@lru_cache(maxsize=1)
def _cached_index() -> EptResourceIndex:
    if flags.ept_index_fixture():
        path = os.environ.get(_FIXTURE_ENV)
        if not path:
            raise RuntimeError("EPT_INDEX_FIXTURE=1 but EPT_INDEX_FIXTURE_PATH unset")
        return EptResourceIndex.from_geojson(json.loads(Path(path).read_text()))
    with urlopen(USGS_EPT_BOUNDARIES_URL, timeout=20) as resp:  # noqa: S310 (fixed https URL)
        return EptResourceIndex.from_geojson(json.loads(resp.read()))


def load_ept_index() -> EptResourceIndex:
    """Process-cached boundaries index (fixture under the test opt-down)."""
    return _cached_index()
```

> Make `load_ept_index` raise/propagate on fetch failure — Task 5's caller catches it and degrades. The `_cached_index` name must match the test's `cache_clear()` call; expose it (lru_cache gives `.cache_clear()`).
> CONFIRM `USGS_EPT_BOUNDARIES_URL` against the live bucket at implementation time (a quick read-only `curl -sI`); if the canonical path differs, update this constant AND the boot check together.

- [ ] **Step 6: Add the boot check**

In `sidecar/app/boot_checks.py`, mirroring the LiDAR real-path check: when `not flags.ept_index_fixture()`, verify the boundaries URL is reachable (a HEAD/short GET), raising in prod, warning in dev — matching the file's existing raise/warn helper. Use the existing helper, do not invent a new logging style.

- [ ] **Step 7: Opt down in conftest**

In `sidecar/tests/conftest.py`, alongside the other `*_FIXTURE` setup, set:

```python
os.environ.setdefault("EPT_INDEX_FIXTURE", "1")
os.environ.setdefault("EPT_INDEX_FIXTURE_PATH",
                      str(Path(__file__).parent / "fixtures" / "ept_boundaries_sample.json"))
```

- [ ] **Step 8: Run test to verify it passes**

Run: `cd sidecar && SIDECAR_SHARED_SECRET=test-shared-secret uv run pytest tests/lidar/test_ept_index.py -v`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add sidecar/app/lidar/ept_index.py sidecar/app/flags.py sidecar/app/boot_checks.py sidecar/tests/conftest.py sidecar/tests/lidar/test_ept_index.py
git commit -m "feat(lidar): live+cached EPT boundaries index behind EPT_INDEX_FIXTURE opt-down"
```

---

## Task 5: Wire `ingest_lidar` Hop 2 to the spatial resolver (with name-guess degrade)

**Files:**
- Modify: `sidecar/app/lidar/ingest.py:113-166` (`PdalCropper.crop` accepts an explicit EPT url), `:322-359` (Hop 2)
- Test: `sidecar/tests/lidar/test_ingest_ept_resolution.py`

- [ ] **Step 1: Write the failing test (the Chicago regression)**

`sidecar/tests/lidar/test_ingest_ept_resolution.py`. Use the existing fixture cropper pattern (see `tests/` for `FixtureCropper`); the key behavior: a covering WESM unit whose NAME has no EPT, but the spatial index resolves a DIFFERENT real key that the cropper accepts.

```python
import json
from pathlib import Path

from app.lidar.ept_index import EptResourceIndex
from app.lidar.ingest import ingest_lidar, EptNotFound, CroppedCloud
from app.lidar.wesm import WorkUnit
import numpy as np

_FIXTURE = Path(__file__).parent.parent / "fixtures" / "ept_boundaries_sample.json"
_CHICAGO_POLY = {
    "type": "Polygon",
    "coordinates": [[
        [-87.660, 41.990], [-87.660, 41.99009],
        [-87.65988, 41.99009], [-87.65988, 41.990], [-87.660, 41.990],
    ]],
}


class _NameMissingSpatialOkCropper:
    """404s the WESM-name URL; succeeds only for the spatially-resolved key."""
    def crop(self, work_unit, polygon, buffer_m=1.0):
        if work_unit.name == "IL_Chicago_LiDAR_2017_published_key":
            pts = np.array([[0, 0, 10, 6], [1, 0, 10, 6], [0, 1, 11, 6]], float)
            return CroppedCloud(points=pts, src_epsg=3857)
        raise EptNotFound(f"no public EPT for {work_unit.name}")


class _FakeWesm:
    def query(self, bbox):
        return [WorkUnit(name="IL_Cook_2017_workunit_name", year=2017)]  # name != published key


def test_ingest_resolves_via_spatial_index_when_wesm_name_misses(monkeypatch):
    from app.lidar import ingest as ingest_mod
    idx = EptResourceIndex.from_geojson(json.loads(_FIXTURE.read_text()))
    monkeypatch.setattr(ingest_mod, "load_ept_index", lambda: idx)

    out = ingest_lidar(
        _CHICAGO_POLY,
        index=_FakeWesm(),
        cropper=_NameMissingSpatialOkCropper(),
        put_bytes=lambda key, data: key,
    )
    assert out.status.name == "AVAILABLE"
    assert out.reason is None
```

> Confirm `WorkUnit`'s constructor signature from `sidecar/app/lidar/wesm.py` and adjust kwargs. Confirm `LiDARStatus` member name (`AVAILABLE`).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd sidecar && SIDECAR_SHARED_SECRET=test-shared-secret uv run pytest tests/lidar/test_ingest_ept_resolution.py -v`
Expected: FAIL — today Hop 2 only tries WESM-name URLs, gets `EptNotFound` for all, returns `no_ept_resource` (status MISSING).

- [ ] **Step 3: Let the cropper take an explicit EPT url**

In `PdalCropper.crop` (line 113), change the signature + the resolution line (121) so the caller can pass the spatially-resolved url, defaulting to the name-guess for back-compat:

```python
    def crop(self, work_unit: WorkUnit, building_polygon_wgs84: dict, buffer_m: float = EAVE_BUFFER_M, ept_url: str | None = None) -> CroppedCloud:
        import json as _json
        import pdal  # conda-only; imported lazily so the module loads without it

        # Prefer an explicitly-resolved EPT key (spatial index); fall back to the
        # name-guess for back-compat / index-unavailable degrade.
        ept = ept_url or ept_url_for(work_unit.name)
```

> Update the `Cropper` Protocol (line 95-100) signature to add `ept_url: str | None = None`. Fixture croppers in tests can ignore it.

- [ ] **Step 4: Rewrite Hop 2**

Replace lines 340-359 with spatial-first, name-guess-degrade logic:

```python
    # Hop 2: resolve the PUBLISHED EPT resource(s) covering this bbox via the
    # entwine boundaries index (name-independent), and try each. If the index is
    # unavailable (infra), degrade to the legacy WESM-name guess so we're never
    # worse than before. Only after BOTH miss is it an honest coverage gap.
    work_unit = covering[0]
    cloud = None

    resolved_urls: list[str] = []
    try:
        bbox_resources = load_ept_index().resolve(bbox)
        resolved_urls = [r.ept_url() for r in bbox_resources]
    except Exception:  # index fetch/parse failure is infra, not a coverage gap
        warnings.append("ept_index_unavailable")

    # Try spatially-resolved keys first (paired with the most-recent WESM unit for
    # year metadata), then the legacy per-unit name guess.
    for url in resolved_urls:
        try:
            cloud = cropper.crop(work_unit, building_polygon_wgs84, ept_url=url)
            break
        except EptNotFound:
            continue
    if cloud is None:
        for candidate in covering:
            try:
                cloud = cropper.crop(candidate, building_polygon_wgs84)
                work_unit = candidate
                break
            except EptNotFound:
                continue
    if cloud is None:
        return IngestOutcome(
            status=LiDARStatus.MISSING,
            reason="no_ept_resource",
            work_unit=work_unit,
            warnings=warnings + ["no_ept_resource"],
        )
```

> Add the import at the top of `ingest.py`: `from .ept_index import load_ept_index`. Keep `ept_url_for` and `_EPT_ABSENT_MARKERS` — they still back the degrade path.

- [ ] **Step 5: Run test to verify it passes**

Run: `cd sidecar && SIDECAR_SHARED_SECRET=test-shared-secret uv run pytest tests/lidar/test_ingest_ept_resolution.py -v`
Expected: PASS.

- [ ] **Step 6: Run the full LiDAR ingest suite (no regressions; existing no_coverage / no_ept_resource honest paths intact)**

Run: `cd sidecar && SIDECAR_SHARED_SECRET=test-shared-secret uv run pytest tests/lidar -v`
Expected: PASS. Existing tests that inject a `FixtureCropper` succeed because `load_ept_index()` returns the fixture (empty for their bbox) and the name-guess degrade still runs.

- [ ] **Step 7: Commit**

```bash
git add sidecar/app/lidar/ingest.py sidecar/tests/lidar/test_ingest_ept_resolution.py
git commit -m "feat(lidar): resolve EPT spatially first, degrade to name-guess, then honest gap"
```

---

## Task 6: Rails — honest limitations copy + area-estimated label

**Files:**
- Modify: `app/views/reports/_limitations.html.erb:20-26`
- Modify: `app/helpers/reports_helper.rb:103-115` (add `area_estimated?` to the context)
- Test: `spec/helpers/reports_helper_spec.rb`, `spec/views/reports/_limitations.html.erb_spec.rb` (or a request spec asserting the rendered copy)

- [ ] **Step 1: Write the failing helper test**

Add to `spec/helpers/reports_helper_spec.rb` (mirror existing `report_limitations_context` specs):

```ruby
describe "#report_limitations_context area_estimated" do
  it "flags area_estimated when the measurement carries area_estimated_no_pitch" do
    m = build(:measurement, source: "imagery", warnings: %w[no_lidar_fallback area_estimated_no_pitch])
    expect(report_limitations_context(m).area_estimated).to be(true)
  end

  it "does not flag area_estimated on the LiDAR path" do
    m = build(:measurement, source: "fusion", warnings: [])
    expect(report_limitations_context(m).area_estimated).to be(false)
  end
end
```

> Confirm the measurement factory + how `warnings` is stored (it's a column — see `structure.sql:132`). Adjust `build(:measurement, ...)` to the real factory.

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/helpers/reports_helper_spec.rb -e "area_estimated"`
Expected: FAIL — `LimitationsContext` has no `area_estimated`.

- [ ] **Step 3: Extend the context struct + builder**

`app/helpers/reports_helper.rb` line 14:

```ruby
  LimitationsContext = Struct.new(:confidence_pct, :source, :has_lidar, :area_estimated)
```

In `report_limitations_context` (line 110-114), compute and pass it:

```ruby
  def report_limitations_context(measurement)
    confidence_pct = measurement.confidence.present? ? (measurement.confidence.to_f * 100).round : nil
    source = measurement.provenance&.dig("geometry_source") || measurement.source.to_s
    has_lidar = source.in?(%w[lidar fusion capture])
    area_estimated = Array(measurement.warnings).include?("area_estimated_no_pitch")
    LimitationsContext.new(confidence_pct, source, has_lidar, area_estimated)
  end
```

- [ ] **Step 4: Run helper test to verify it passes**

Run: `bundle exec rspec spec/helpers/reports_helper_spec.rb -e "area_estimated"`
Expected: PASS.

- [ ] **Step 5: Fix the limitations copy (the false pitch claim)**

`app/views/reports/_limitations.html.erb` — replace lines 17-26 so the point-cloud pitch claim lives ONLY in the LiDAR branch, and the imagery branch states pitch is not measured + area is estimated:

```erb
    <% if ctx.has_lidar %>
      Measurements derived from public LiDAR (USGS 3DEP) and satellite imagery;
      geometry computed by RANSAC plane fitting on building-classified points.
      Pitch values are derived from the point cloud.
    <% else %>
      Measurements derived from satellite imagery; LiDAR coverage was not
      available for this location. Roof pitch was not measured, so it is reported
      as unknown, and the roof area is a planimetric estimate.
    <% end %>
    Field verification is recommended for roofing-permit submissions.
    Roof-mounted features (vents, skylights) are detected by vision model and may
    require manual confirmation. This report is generated from publicly available
    data and does not constitute a licensed engineering survey.
```

- [ ] **Step 6: Add a view/request spec asserting the imagery copy**

Add to the appropriate spec (prefer an existing reports request/view spec). Assert that an imagery-source report renders "reported as unknown" and does NOT render "Pitch values are derived from the point cloud":

```ruby
it "states pitch is unknown and area estimated on the imagery path" do
  render partial: "reports/limitations", locals: { measurement: build(:measurement, source: "imagery", warnings: %w[area_estimated_no_pitch]) }
  expect(rendered).to include("reported as unknown")
  expect(rendered).not_to include("Pitch values are derived from the point cloud")
end
```

- [ ] **Step 7: Run the view + helper specs**

Run: `bundle exec rspec spec/helpers/reports_helper_spec.rb spec/views/reports`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add app/views/reports/_limitations.html.erb app/helpers/reports_helper.rb spec/helpers/reports_helper_spec.rb spec/views/reports
git commit -m "feat(reports): honest imagery-path limitations copy + area_estimated context"
```

---

## Task 7: React viewer — null pitch is "unknown", not 0/12

**Files:**
- Modify: `app/javascript/viewer/types.ts:7-8`
- Modify: `app/javascript/viewer/utils/colorByPitch.ts:16-25`
- Modify: `app/javascript/viewer/RoofViewer.tsx:345`
- Test: `app/javascript/viewer/utils/colorByPitch.test.ts` (create if absent; confirm vitest config)

- [ ] **Step 1: Write the failing test**

`app/javascript/viewer/utils/colorByPitch.test.ts`:

```ts
import { describe, it, expect } from "vitest";
import { colorByPitch, UNKNOWN_PITCH_RGBA } from "./colorByPitch";

describe("colorByPitch", () => {
  it("returns a distinct UNKNOWN color for null pitch (not the 0/12 bucket)", () => {
    const unknown = colorByPitch(null);
    const flat = colorByPitch(0);
    expect(unknown).not.toEqual(flat);
    expect(unknown.slice(0, 3)).toEqual(UNKNOWN_PITCH_RGBA.slice(0, 3));
  });

  it("still ramps a real pitch", () => {
    expect(colorByPitch(6)).not.toEqual(colorByPitch(0));
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run app/javascript/viewer/utils/colorByPitch.test.ts`
Expected: FAIL — `UNKNOWN_PITCH_RGBA` not exported; null currently coerces to 0/12 (equal to flat).

> If `npx vitest` isn't wired, check `package.json` scripts for the JS test runner and use that command throughout.

- [ ] **Step 3: Update `colorByPitch.ts`**

```ts
// A distinct neutral for "pitch not measured" — visually separate from the 0/12
// (flat) bucket, so an imagery-only facet never reads as a measured flat roof.
export const UNKNOWN_PITCH_RGBA: RGBA = [156, 163, 175, 90]; // muted, low-alpha

export function colorByPitch(pitchRatio: number | null, alpha: number = DEFAULT_ALPHA): RGBA {
  if (pitchRatio == null || !Number.isFinite(pitchRatio)) {
    return UNKNOWN_PITCH_RGBA;
  }
  const t = Math.min(Math.max(pitchRatio, 0), MAX_RATIO) / MAX_RATIO;
  return [
    lerp(PITCH_LIGHTEST[0], PITCH_DARKEST[0], t),
    lerp(PITCH_LIGHTEST[1], PITCH_DARKEST[1], t),
    lerp(PITCH_LIGHTEST[2], PITCH_DARKEST[2], t),
    alpha,
  ];
}
```

- [ ] **Step 4: Update the types**

`app/javascript/viewer/types.ts` lines 7-8:

```ts
  pitch_ratio: number | null;
  pitch_degrees: number | null;
```

- [ ] **Step 5: Update the tooltip**

`app/javascript/viewer/RoofViewer.tsx` line 345 — replace the pitch fragment:

```tsx
      {Math.round(f.area_sq_ft)} sq ft · {f.pitch_ratio == null ? "pitch unknown" : `${f.pitch_ratio}:12 pitch`}
```

- [ ] **Step 6: Run the JS test to verify it passes**

Run: `npx vitest run app/javascript/viewer/utils/colorByPitch.test.ts`
Expected: PASS.

- [ ] **Step 7: Typecheck the viewer island (catch any other non-null pitch assumptions)**

Run: `npx tsc --noEmit -p app/javascript/viewer` (or the project's JS typecheck script from `package.json`)
Expected: no errors. Fix any newly-surfaced `pitch_ratio`/`pitch_degrees` non-null usages (e.g. arithmetic) with explicit null guards.

- [ ] **Step 8: Commit**

```bash
git add app/javascript/viewer/types.ts app/javascript/viewer/utils/colorByPitch.ts app/javascript/viewer/utils/colorByPitch.test.ts app/javascript/viewer/RoofViewer.tsx
git commit -m "fix(viewer): render null pitch as unknown, not a flat 0/12 facet"
```

---

## Task 8: Full-suite validation + docs

**Files:**
- Modify: `docs/QA-FINDINGS.md:137-139` (mark B-7 follow-up done)

- [ ] **Step 1: Sidecar full suite**

Run: `cd sidecar && SIDECAR_SHARED_SECRET=test-shared-secret uv run pytest -v`
Expected: PASS (all green).

- [ ] **Step 2: Rails full suite (boots the real sidecar via `uv run`; needs PostGIS container + `uv sync`)**

Run (bare — no DATABASE_* prefix): `bin/rails db:test:prepare && bundle exec rspec`
Expected: PASS. The `/skeleton` round-trip and any imagery-fallback request spec reflect null pitch. If a request spec asserted `6:12` on an imagery report, update it to expect `—`/unknown (it was asserting the bug).

- [ ] **Step 3: Lint + JS**

Run: `bin/rubocop && bin/brakeman -q` and the JS test/typecheck scripts from `package.json`.
Expected: PASS.

- [ ] **Step 4: Mark the QA-FINDINGS follow-up done**

`docs/QA-FINDINGS.md` — update B-7's follow-up bullet (lines 137-139) to record that EPT resources are now resolved spatially via the entwine boundaries index (name-independent), with a name-guess degrade, recovering LiDAR for name-mismatched covered addresses.

- [ ] **Step 5: Commit**

```bash
git add docs/QA-FINDINGS.md
git commit -m "docs(qa): B-7 follow-up done — spatial EPT resolution recovers name-mismatched coverage"
```

- [ ] **Step 6: Manual verification of the original bug**

Run the app (`bin/dev`, which runs the sidecar as its Docker image with the real geo stack) and re-run the original address *5859 N Winthrop Ave, Chicago*. Confirm: (a) LiDAR now resolves (no `no_ept_resource`; real per-facet pitch), OR if it genuinely still misses, the report shows pitch as `—`/unknown and area labeled estimated — never a fabricated `6:12`. Capture a screenshot for the PR.

---

## Self-review notes

- **Spec coverage:** Section 1 (EPT spatial resolution) → Tasks 3,4,5. Section 2 (null pitch, estimated area, schema, warning, Rails copy, viewer) → Tasks 1,2,6,7. Section 3 (error handling: index-fetch degrade = Task 5 Step 4; fixture polarity = Task 4; null containment to fallback only = Task 2; tests throughout). All covered.
- **Type consistency:** `EptResource.key`/`.ept_url()`, `EptResourceIndex.from_geojson`/`.resolve`, `load_ept_index()`, `_cached_index`, `UNKNOWN_PITCH_RGBA`, `LimitationsContext(... , area_estimated)`, warning string `area_estimated_no_pitch` — used identically across tasks.
- **Ordering rationale:** schema/contract first (Task 1) so null validates before Task 2 emits it; resolver pure-unit (Task 3) before its loader (Task 4) before the wiring (Task 5); independent Rails (6) and JS (7) after the contract is null-safe; full-suite + manual verify last.
- **Confirm-at-implementation flags:** `SchemaVersion`/`Confidence` literals; `WorkUnit` constructor; `LiDARStatus.AVAILABLE`; the live `USGS_EPT_BOUNDARIES_URL`; the JS test/typecheck commands; the measurement factory + `warnings` column shape. Each is called out inline at its task.
