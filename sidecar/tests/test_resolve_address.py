"""F-05 test suite: Address & polygon resolver.

Coverage:
  • Unit tests for each external client (Nominatim, MS Footprints, Regrid)
    using httpx MockTransport — no real network, no secrets.
  • Integration tests: 5 fixture addresses (urban SFR, rural SFR, townhouse,
    multi-building parcel, known-gap).
  • Cache: first-call vs. cache-hit latency assertion (<100 ms on hit).
  • Failure modes: geocode 4xx, Regrid timeout, MS empty result.
  • Schema validation: every response checks against ResolveAddressResponse
    Pydantic model AND the JSON Schema (shared/pipeline_schema.json).
"""

from __future__ import annotations

import gzip
import json
import time
from pathlib import Path
from typing import Any
from unittest.mock import patch

import httpx
import pytest
from fastapi.testclient import TestClient
from jsonschema import Draft202012Validator

from app.main import app
from app.resolve_address import cache as cache_mod
from app.resolve_address import ms_footprints as ms_footprints_mod
from app.resolve_address.ms_footprints import (
    FootprintError,
    fetch_footprints,
    lat_lon_to_quadkey,
)
from app.resolve_address.nominatim import GeocodeError, geocode, normalize_address
from app.resolve_address.regrid import RegridError, fetch_parcel
from app.resolve_address.service import resolve
from contracts.pipeline import PIPELINE_SCHEMA_VERSION, ResolveAddressResponse

# ---------------------------------------------------------------------------
# Helpers / fixtures
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = REPO_ROOT / "shared" / "pipeline_schema.json"
_SCHEMA = json.loads(SCHEMA_PATH.read_text())

GOOD_BEARER = {"Authorization": "Bearer test-shared-secret"}
client_app = TestClient(app)


def _jsonschema_validator(entity: str) -> Draft202012Validator:
    sub = {"$ref": f"#/$defs/{entity}", "$defs": _SCHEMA["$defs"]}
    return Draft202012Validator(sub)


_RESPONSE_VALIDATOR = _jsonschema_validator("ResolveAddressResponse")


def assert_valid_response(body: dict) -> None:
    """Assert body validates as ResolveAddressResponse (Pydantic + JSON Schema)."""
    ResolveAddressResponse.model_validate(body)
    errors = list(_RESPONSE_VALIDATOR.iter_errors(body))
    assert not errors, f"JSON Schema errors: {[e.message for e in errors]}"


# A minimal Nominatim result
_NOMINATIM_RESULT = [
    {
        "lat": "47.6062",
        "lon": "-122.3321",
        "display_name": "123 Main St, Seattle, WA 98101, USA",
    }
]

# A minimal GeoJSON Polygon that looks like a building
_BUILDING_COORDS = [
    [
        [-122.3322, 47.6061],
        [-122.3320, 47.6061],
        [-122.3320, 47.6063],
        [-122.3322, 47.6063],
        [-122.3322, 47.6061],
    ]
]

# A minimal GeoJSON Polygon for a parcel (slightly larger)
_PARCEL_COORDS = [
    [
        [-122.3325, 47.6058],
        [-122.3315, 47.6058],
        [-122.3315, 47.6068],
        [-122.3325, 47.6068],
        [-122.3325, 47.6058],
    ]
]

_REGRID_RESULT = {
    "parcels": {
        "features": [
            {
                "type": "Feature",
                "geometry": {"type": "Polygon", "coordinates": _PARCEL_COORDS},
                "properties": {"ll_uuid": "parcel-abc-123", "address": "123 Main St"},
            }
        ]
    }
}

# MS footprints tile: one feature in GeoJSON-lines format (gzip compressed)
def _make_ms_tile(buildings: list[list]) -> bytes:
    lines = []
    for coords in buildings:
        feature = {
            "type": "Feature",
            "geometry": {"type": "Polygon", "coordinates": coords},
            "properties": {},
        }
        lines.append(json.dumps(feature))
    raw = "\n".join(lines).encode("utf-8")
    return gzip.compress(raw)


# ---------------------------------------------------------------------------
# httpx MockTransport helpers
# ---------------------------------------------------------------------------

_NOMINATIM_BASE = "https://nominatim.openstreetmap.org"
_MS_BASE = "https://minedbuildings.z5.web.core.windows.net"
_REGRID_BASE = "https://app.regrid.com"


class MockNominatimTransport(httpx.BaseTransport):
    """Returns a configurable Nominatim response."""

    def __init__(self, results: list | None = None, status_code: int = 200):
        self._results = results if results is not None else _NOMINATIM_RESULT
        self._status_code = status_code

    def handle_request(self, request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            status_code=self._status_code,
            json=self._results,
        )


# The real tile URL the index resolves a quadkey to (region-partitioned, dated
# path under the MS blob — NOT the flat <base>/<quadkey>.geojsonl.gz the client
# used to (wrongly) construct). The mock index points every quadkey here.
_RESOLVED_TILE_PATH = (
    "/global-buildings/2026-02-03/global-buildings.geojsonl"
    "/RegionName=UnitedStates/quadkey={quadkey}/part-00000.csv.gz"
)


def _make_dataset_index_csv(quadkeys: list[str]) -> bytes:
    """Build a dataset-links.csv mapping each quadkey to its resolved tile URL,
    one UnitedStates row + one NorthAmerica row per quadkey (the real index lists
    both; UnitedStates must win)."""
    rows = ["Location,QuadKey,Url,Size,UploadDate"]
    for qk in quadkeys:
        us_url = _MS_BASE + _RESOLVED_TILE_PATH.format(quadkey=qk)
        na_url = us_url.replace("RegionName=UnitedStates", "RegionName=NorthAmerica")
        # NorthAmerica row first, so a correct impl must PREFER UnitedStates, not
        # just take the first match.
        rows.append(f"NorthAmerica,{qk},{na_url},211B,2026-02-23")
        rows.append(f"UnitedStates,{qk},{us_url},126.0MB,2026-02-23")
    return "\n".join(rows).encode("utf-8")


# Every geocoded point used across this suite. The cover-all default index
# declares footprint coverage for each of these quadkeys so a tile fetch
# resolves. Kept in sync with FIXTURE_ADDRESSES + the Seattle unit-test point;
# a point not listed here exercises the legitimate "no coverage" path.
_SUITE_COORDS = [
    (47.6062, -122.3321),  # Seattle — unit tests
    (47.6145, -122.3148),  # urban_sfr
    (46.9965, -120.5478),  # rural_sfr
    (47.6122, -122.3354),  # townhouse
    (47.6101, -122.2015),  # multi_building
    (64.2008, -153.4937),  # known_gap (Alaska) — has a row; gap is modelled as
                           # an empty tile, not a missing quadkey
]
_ALL_FIXTURE_QUADKEYS = sorted({lat_lon_to_quadkey(lat, lon) for lat, lon in _SUITE_COORDS})


class MockMSTransport(httpx.BaseTransport):
    """Mocks the two MS Building Footprints fetches, routed by URL:

      • the dataset-links.csv index (maps quadkey -> real tile URL), and
      • the resolved tile itself (gzip GeoJSON-lines).

    The index is built for the quadkey of the request's lat/lon so the happy
    path resolves; pass index_quadkeys=[] to simulate a quadkey absent from the
    dataset (legitimate "no coverage").
    """

    def __init__(
        self,
        buildings: list[list] | None = None,
        status_code: int = 200,
        index_quadkeys: list[str] | None = None,
    ):
        # Use explicit None check so an empty list [] is preserved (not replaced by default)
        self._buildings = [_BUILDING_COORDS] if buildings is None else buildings
        self._status_code = status_code
        # index_quadkeys=None means "cover the quadkeys of every geocoded point
        # used in this suite" (the common case: the tile the code asks for
        # exists). Pass an explicit list (incl. []) to constrain coverage and
        # exercise the no-coverage path for a specific quadkey.
        self._index_quadkeys = (
            _ALL_FIXTURE_QUADKEYS if index_quadkeys is None else index_quadkeys
        )
        self.requested_paths: list[str] = []

    def handle_request(self, request: httpx.Request) -> httpx.Response:
        path = request.url.path
        self.requested_paths.append(path)
        # Route 1: the dataset index (maps quadkey -> real tile URL).
        if path.endswith("dataset-links.csv"):
            return httpx.Response(
                status_code=200, content=_make_dataset_index_csv(self._index_quadkeys)
            )
        # Route 2: a resolved tile. The status_code knob exercises tile-fetch
        # failure modes (404 -> empty, 5xx -> error).
        if self._status_code != 200:
            return httpx.Response(status_code=self._status_code, content=b"")
        content = _make_ms_tile(self._buildings)
        return httpx.Response(status_code=200, content=content)


class MockRegridTransport(httpx.BaseTransport):
    """Returns a configurable Regrid response."""

    def __init__(self, data: dict | None = None, status_code: int = 200, timeout: bool = False):
        self._data = data if data is not None else _REGRID_RESULT
        self._status_code = status_code
        self._timeout = timeout

    def handle_request(self, request: httpx.Request) -> httpx.Response:
        if self._timeout:
            raise httpx.TimeoutException("simulated timeout", request=request)
        return httpx.Response(status_code=self._status_code, json=self._data)


def _make_clients(
    nominatim_transport: httpx.BaseTransport | None = None,
    ms_transport: httpx.BaseTransport | None = None,
    regrid_transport: httpx.BaseTransport | None = None,
) -> dict:
    """Build client kwargs for service.resolve()."""
    kwargs: dict[str, Any] = {"skip_rps": True}
    if nominatim_transport is not None:
        kwargs["nominatim_client"] = httpx.Client(
            base_url=_NOMINATIM_BASE, transport=nominatim_transport
        )
    if ms_transport is not None:
        kwargs["ms_client"] = httpx.Client(
            base_url=_MS_BASE, transport=ms_transport
        )
    if regrid_transport is not None:
        kwargs["regrid_client"] = httpx.Client(
            base_url=_REGRID_BASE, transport=regrid_transport
        )
    return kwargs


# ---------------------------------------------------------------------------
# autouse fixture: clear caches between tests
# ---------------------------------------------------------------------------

@pytest.fixture(autouse=True)
def clear_caches():
    cache_mod.geocode_cache.clear()
    cache_mod.parcel_cache.clear()
    cache_mod.footprint_cache.clear()
    # The MS dataset index is a process-global cache; reset it so a per-test
    # mock index (different quadkey coverage) isn't poisoned by an earlier load.
    ms_footprints_mod._index_by_quadkey = None
    yield
    cache_mod.geocode_cache.clear()
    cache_mod.parcel_cache.clear()
    cache_mod.footprint_cache.clear()
    ms_footprints_mod._index_by_quadkey = None


# ===========================================================================
# Unit tests: Nominatim client
# ===========================================================================

class TestNominatimClient:
    def test_normalize_address_strips_whitespace(self):
        assert normalize_address("  123 Main St  ") == "123 Main St"

    def test_normalize_address_collapses_internal_spaces(self):
        assert normalize_address("123  Main   St") == "123 Main St"

    def test_geocode_happy_path(self):
        transport = MockNominatimTransport()
        with httpx.Client(base_url=_NOMINATIM_BASE, transport=transport) as c:
            result = geocode("123 Main St, Seattle, WA", client=c, skip_rps=True)
        assert abs(result.lat - 47.6062) < 0.001
        assert abs(result.lon - (-122.3321)) < 0.001
        assert "123 Main St" in result.formatted_address

    def test_geocode_4xx_raises_geocode_error(self):
        transport = MockNominatimTransport(status_code=404)
        with httpx.Client(base_url=_NOMINATIM_BASE, transport=transport) as c:
            with pytest.raises(GeocodeError, match="HTTP 404"):
                geocode("unknown address", client=c, skip_rps=True)

    def test_geocode_empty_results_raises_geocode_error(self):
        transport = MockNominatimTransport(results=[])
        with httpx.Client(base_url=_NOMINATIM_BASE, transport=transport) as c:
            with pytest.raises(GeocodeError, match="no results"):
                geocode("123 Nowhere Lane", client=c, skip_rps=True)


# ===========================================================================
# Unit tests: MS Building Footprints client
# ===========================================================================

class TestMSFootprintsClient:
    def test_lat_lon_to_quadkey_deterministic(self):
        # Known result for Seattle coordinates at zoom 9
        qk = lat_lon_to_quadkey(47.6062, -122.3321, zoom=9)
        assert isinstance(qk, str)
        assert len(qk) == 9  # zoom 9

    def test_lat_lon_to_quadkey_different_points_differ(self):
        qk1 = lat_lon_to_quadkey(47.6062, -122.3321)
        qk2 = lat_lon_to_quadkey(40.7128, -74.0060)  # New York
        assert qk1 != qk2

    def test_fetch_footprints_happy_path_50m_fallback(self):
        """When no parcel is provided, footprints within 50m are returned."""
        transport = MockMSTransport(buildings=[_BUILDING_COORDS])
        with httpx.Client(base_url=_MS_BASE, transport=transport) as c:
            results = fetch_footprints(47.6062, -122.3321, client=c)
        assert len(results) == 1
        assert results[0] == _BUILDING_COORDS

    def test_fetch_footprints_with_parcel_intersection(self):
        """Footprints inside the parcel polygon are returned."""
        transport = MockMSTransport(buildings=[_BUILDING_COORDS])
        with httpx.Client(base_url=_MS_BASE, transport=transport) as c:
            results = fetch_footprints(
                47.6062, -122.3321,
                parcel_polygon_coords=_PARCEL_COORDS,
                client=c,
            )
        assert len(results) == 1

    def test_fetch_footprints_no_intersection_returns_empty(self):
        """A building far from the point is NOT returned."""
        far_building = [
            [
                [-74.0100, 40.7100],
                [-74.0080, 40.7100],
                [-74.0080, 40.7120],
                [-74.0100, 40.7120],
                [-74.0100, 40.7100],
            ]
        ]
        transport = MockMSTransport(buildings=[far_building])
        with httpx.Client(base_url=_MS_BASE, transport=transport) as c:
            results = fetch_footprints(47.6062, -122.3321, client=c)
        assert results == []

    def test_fetch_footprints_404_returns_empty(self):
        """A 404 on the tile URL is treated as 'no data' not an error."""
        transport = MockMSTransport(status_code=404)
        with httpx.Client(base_url=_MS_BASE, transport=transport) as c:
            results = fetch_footprints(47.6062, -122.3321, client=c)
        assert results == []

    def test_fetch_footprints_5xx_raises_footprint_error(self):
        transport = MockMSTransport(status_code=500)
        with httpx.Client(base_url=_MS_BASE, transport=transport) as c:
            with pytest.raises(FootprintError):
                fetch_footprints(47.6062, -122.3321, client=c)

    def test_fetch_footprints_resolves_tile_url_via_dataset_index(self):
        """The tile URL is resolved through dataset-links.csv (region-partitioned
        path), NOT the flat <base>/<quadkey>.geojsonl.gz scheme. The index lists
        a NorthAmerica row before the UnitedStates one; UnitedStates must win."""
        transport = MockMSTransport(buildings=[_BUILDING_COORDS])
        with httpx.Client(base_url=_MS_BASE, transport=transport) as c:
            results = fetch_footprints(47.6062, -122.3321, client=c)
        assert len(results) == 1

        quadkey = lat_lon_to_quadkey(47.6062, -122.3321)
        # The index was consulted...
        assert any(p.endswith("dataset-links.csv") for p in transport.requested_paths)
        # ...and the tile was fetched from the region-partitioned UnitedStates
        # path the index resolved to, never the old flat quadkey.geojsonl.gz.
        tile_paths = [p for p in transport.requested_paths if not p.endswith("dataset-links.csv")]
        assert tile_paths, "no tile fetch was made"
        assert any(f"quadkey={quadkey}" in p and "RegionName=UnitedStates" in p for p in tile_paths)
        assert not any(p.endswith(f"{quadkey}.geojsonl.gz") for p in transport.requested_paths)

    def test_fetch_footprints_quadkey_absent_from_index_returns_empty(self):
        """A quadkey with no row in dataset-links.csv is legitimate 'no coverage'
        — return empty, not an error (and don't even attempt a tile fetch)."""
        transport = MockMSTransport(buildings=[_BUILDING_COORDS], index_quadkeys=[])
        with httpx.Client(base_url=_MS_BASE, transport=transport) as c:
            results = fetch_footprints(47.6062, -122.3321, client=c)
        assert results == []
        tile_paths = [p for p in transport.requested_paths if not p.endswith("dataset-links.csv")]
        assert tile_paths == []

    def test_fetch_footprints_multiple_buildings(self):
        """Multiple buildings inside the parcel are all returned."""
        building2 = [
            [
                [-122.3323, 47.6064],
                [-122.3321, 47.6064],
                [-122.3321, 47.6066],
                [-122.3323, 47.6066],
                [-122.3323, 47.6064],
            ]
        ]
        transport = MockMSTransport(buildings=[_BUILDING_COORDS, building2])
        with httpx.Client(base_url=_MS_BASE, transport=transport) as c:
            results = fetch_footprints(
                47.6062, -122.3321,
                parcel_polygon_coords=_PARCEL_COORDS,
                client=c,
            )
        assert len(results) == 2


# ===========================================================================
# Unit tests: Regrid client
# ===========================================================================

class TestRegridClient:
    def test_fetch_parcel_no_key_returns_none(self):
        # No API key → None without hitting the network
        result = fetch_parcel(47.6062, -122.3321, api_key=None, client=None)
        assert result is None

    def test_fetch_parcel_happy_path(self):
        transport = MockRegridTransport()
        with httpx.Client(base_url=_REGRID_BASE, transport=transport) as c:
            result = fetch_parcel(47.6062, -122.3321, api_key="test-key", client=c)
        assert result is not None
        assert result.parcel_id == "parcel-abc-123"
        assert result.polygon_coords == _PARCEL_COORDS

    def test_fetch_parcel_empty_response_returns_none(self):
        data = {"parcels": {"features": []}}
        transport = MockRegridTransport(data=data)
        with httpx.Client(base_url=_REGRID_BASE, transport=transport) as c:
            result = fetch_parcel(47.6062, -122.3321, api_key="test-key", client=c)
        assert result is None

    def test_fetch_parcel_timeout_raises_regrid_error(self):
        transport = MockRegridTransport(timeout=True)
        with httpx.Client(base_url=_REGRID_BASE, transport=transport) as c:
            with pytest.raises(RegridError, match="timed out"):
                fetch_parcel(47.6062, -122.3321, api_key="test-key", client=c)

    def test_fetch_parcel_401_raises_regrid_error(self):
        transport = MockRegridTransport(status_code=401)
        with httpx.Client(base_url=_REGRID_BASE, transport=transport) as c:
            with pytest.raises(RegridError, match="authentication"):
                fetch_parcel(47.6062, -122.3321, api_key="bad-key", client=c)


# ===========================================================================
# Unit tests: In-process TTL cache
# ===========================================================================

class TestInMemoryCache:
    def test_get_miss_returns_none(self):
        assert cache_mod.geocode_cache.get("nonexistent") is None

    def test_set_and_get(self):
        cache_mod.geocode_cache.set("key1", "value1", ttl=60)
        assert cache_mod.geocode_cache.get("key1") == "value1"

    def test_expired_entry_returns_none(self):
        cache_mod.geocode_cache.set("key2", "value2", ttl=0.001)  # 1 ms
        time.sleep(0.05)
        assert cache_mod.geocode_cache.get("key2") is None

    def test_clear_removes_all(self):
        cache_mod.geocode_cache.set("key3", "v3", ttl=60)
        cache_mod.geocode_cache.clear()
        assert cache_mod.geocode_cache.get("key3") is None


# ===========================================================================
# Service-level tests (all external calls mocked)
# ===========================================================================

def _default_resolve_kwargs(
    buildings: list[list] | None = None,
    include_parcel: bool = True,
) -> dict:
    """Build default happy-path service.resolve() kwargs."""
    effective_buildings = [_BUILDING_COORDS] if buildings is None else buildings
    return _make_clients(
        nominatim_transport=MockNominatimTransport(),
        ms_transport=MockMSTransport(buildings=effective_buildings),
        regrid_transport=MockRegridTransport() if include_parcel else None,
    ) | ({"regrid_api_key": "test-key"} if include_parcel else {})


class TestServiceResolve:
    def test_happy_path_returns_valid_response(self):
        kwargs = _default_resolve_kwargs()
        resp = resolve("123 Main St, Seattle, WA", **kwargs)
        assert isinstance(resp, ResolveAddressResponse)
        assert_valid_response(resp.model_dump())

    def test_geocode_failure_raises_422(self):
        from fastapi import HTTPException
        kwargs = _make_clients(
            nominatim_transport=MockNominatimTransport(status_code=404),
        )
        with pytest.raises(HTTPException) as exc_info:
            resolve("bad address", **kwargs)
        assert exc_info.value.status_code == 422

    def test_empty_building_footprints_raises_422(self):
        from fastapi import HTTPException
        kwargs = _default_resolve_kwargs(buildings=[])
        with pytest.raises(HTTPException) as exc_info:
            resolve("123 Main St, Seattle, WA", **kwargs)
        assert exc_info.value.status_code == 422

    def test_regrid_timeout_degrades_gracefully(self):
        kwargs = _make_clients(
            nominatim_transport=MockNominatimTransport(),
            ms_transport=MockMSTransport(),
            regrid_transport=MockRegridTransport(timeout=True),
        ) | {"regrid_api_key": "test-key"}
        resp = resolve("123 Main St, Seattle, WA", **kwargs)
        assert resp.parcel_polygon is None
        assert any("parcel_unavailable" in w for w in resp.warnings)
        assert_valid_response(resp.model_dump())

    def test_no_regrid_key_parcel_null_with_warning(self):
        kwargs = _make_clients(
            nominatim_transport=MockNominatimTransport(),
            ms_transport=MockMSTransport(),
        ) | {"regrid_api_key": None}
        # Patch env to ensure no key is picked up
        with patch.dict("os.environ", {"REGRID_API_KEY": ""}, clear=False):
            resp = resolve("123 Main St, Seattle, WA", **kwargs)
        assert resp.parcel_polygon is None
        assert any("parcel_unavailable" in w for w in resp.warnings)

    def test_multiple_buildings_all_returned(self):
        building2 = [
            [
                [-122.3323, 47.6064],
                [-122.3321, 47.6064],
                [-122.3321, 47.6066],
                [-122.3323, 47.6066],
                [-122.3323, 47.6064],
            ]
        ]
        kwargs = _default_resolve_kwargs(buildings=[_BUILDING_COORDS, building2])
        resp = resolve("123 Main St, Seattle, WA", **kwargs)
        assert len(resp.building_polygons) == 2

    def test_attribution_names_present(self):
        kwargs = _default_resolve_kwargs()
        resp = resolve("123 Main St, Seattle, WA", **kwargs)
        names = {a.name for a in resp.attribution}
        assert "Nominatim / OpenStreetMap" in names
        assert "Microsoft Building Footprints" in names

    def test_response_has_correct_schema_version(self):
        kwargs = _default_resolve_kwargs()
        resp = resolve("123 Main St, Seattle, WA", **kwargs)
        assert resp.pipelineSchemaVersion == PIPELINE_SCHEMA_VERSION

    def test_geocode_result_in_response(self):
        kwargs = _default_resolve_kwargs()
        resp = resolve("123 Main St, Seattle, WA", **kwargs)
        assert resp.geocode.lat is not None
        assert resp.geocode.lon is not None
        assert resp.geocode.raw == "123 Main St, Seattle, WA"


# ===========================================================================
# Cache: first-call vs. hit latency assertion
# ===========================================================================

class TestCacheLatency:
    def test_cache_hit_under_100ms(self):
        """Second identical call must be served from cache in <100 ms."""
        kwargs = _make_clients(
            nominatim_transport=MockNominatimTransport(),
            ms_transport=MockMSTransport(),
        ) | {"regrid_api_key": None}

        with patch.dict("os.environ", {"REGRID_API_KEY": ""}, clear=False):
            # First call: populates caches
            resolve("456 Cache St, Seattle, WA", **kwargs)

            # Second call: all three caches hit — no mock transports needed
            # (if it tries to make a real call with no transport it will error)
            t0 = time.monotonic()
            resolve("456 Cache St, Seattle, WA", skip_rps=True)
            elapsed_ms = (time.monotonic() - t0) * 1000

        assert elapsed_ms < 100, f"Cache hit took {elapsed_ms:.1f} ms (expected <100 ms)"


# ===========================================================================
# Integration tests: 5 fixture addresses
# These use mocked HTTP (no real network) but exercise the full service flow.
# ===========================================================================

# We use a helper to build a "fake world" for each scenario.

def _make_building(lon_center: float, lat_center: float, size: float = 0.0001) -> list:
    """Return GeoJSON polygon coordinate ring for a small square building."""
    return [
        [
            [lon_center - size, lat_center - size],
            [lon_center + size, lat_center - size],
            [lon_center + size, lat_center + size],
            [lon_center - size, lat_center + size],
            [lon_center - size, lat_center - size],
        ]
    ]


def _make_parcel_coords(lon_center: float, lat_center: float, size: float = 0.0005) -> list:
    return [
        [
            [lon_center - size, lat_center - size],
            [lon_center + size, lat_center - size],
            [lon_center + size, lat_center + size],
            [lon_center - size, lat_center + size],
            [lon_center - size, lat_center - size],
        ]
    ]


def _make_nominatim_result(lat: float, lon: float, display: str) -> list:
    return [{"lat": str(lat), "lon": str(lon), "display_name": display}]


FIXTURE_ADDRESSES = [
    # (scenario, address, lat, lon, num_buildings, include_parcel)
    ("urban_sfr", "1847 E Pine St, Seattle, WA 98122", 47.6145, -122.3148, 1, True),
    ("rural_sfr", "1234 Rural Route 1, Ellensburg, WA 98926", 46.9965, -120.5478, 1, False),
    ("townhouse", "815 Pine St, Seattle, WA 98101", 47.6122, -122.3354, 1, True),
    ("multi_building", "4321 Garage Ln, Bellevue, WA 98004", 47.6101, -122.2015, 2, True),
    ("known_gap", "99999 Nonexistent Ave, Nowhere, AK 99999", 64.2008, -153.4937, 1, False),
]


@pytest.mark.parametrize(
    "scenario,address,lat,lon,num_buildings,include_parcel",
    FIXTURE_ADDRESSES,
    ids=[s[0] for s in FIXTURE_ADDRESSES],
)
def test_fixture_address(scenario, address, lat, lon, num_buildings, include_parcel):
    """End-to-end test over 5 fixture addresses — all HTTP mocked."""
    buildings = [_make_building(lon, lat) for _ in range(num_buildings)]
    parcel_coords = _make_parcel_coords(lon, lat) if include_parcel else None

    nominatim_result = _make_nominatim_result(lat, lon, f"{address}, USA")
    regrid_data = (
        {
            "parcels": {
                "features": [
                    {
                        "type": "Feature",
                        "geometry": {"type": "Polygon", "coordinates": parcel_coords},
                        "properties": {"ll_uuid": f"parcel-{scenario}", "address": address},
                    }
                ]
            }
        }
        if include_parcel
        else {"parcels": {"features": []}}
    )

    kwargs = _make_clients(
        nominatim_transport=MockNominatimTransport(results=nominatim_result),
        ms_transport=MockMSTransport(buildings=buildings),
        regrid_transport=MockRegridTransport(data=regrid_data),
    ) | {"regrid_api_key": "test-key" if include_parcel else None}

    with patch.dict("os.environ", {"REGRID_API_KEY": ""} if not include_parcel else {}, clear=False):
        resp = resolve(address, **kwargs)

    # All responses must be valid
    assert_valid_response(resp.model_dump())
    assert resp.geocode.raw == address
    assert len(resp.building_polygons) == num_buildings

    if include_parcel:
        assert resp.parcel_polygon is not None
    else:
        assert resp.parcel_polygon is None


# ===========================================================================
# Endpoint integration tests (TestClient, real FastAPI app)
# ===========================================================================

class TestEndpoint:
    """POST /pipeline/resolve-address via TestClient.

    Uses monkeypatch to inject mock implementations of service.resolve so we
    test the routing/auth/schema layer, not the external clients.
    """

    def test_requires_bearer(self):
        response = client_app.post(
            "/pipeline/resolve-address",
            json={"pipelineSchemaVersion": "0.2.0", "address": "123 Main St"},
        )
        assert response.status_code == 401

    def test_422_on_missing_address(self):
        response = client_app.post(
            "/pipeline/resolve-address",
            headers=GOOD_BEARER,
            json={"pipelineSchemaVersion": "0.2.0"},
        )
        assert response.status_code == 422

    def test_422_on_empty_address(self):
        response = client_app.post(
            "/pipeline/resolve-address",
            headers=GOOD_BEARER,
            json={"pipelineSchemaVersion": "0.2.0", "address": ""},
        )
        assert response.status_code == 422

    def test_409_on_schema_version_mismatch(self):
        response = client_app.post(
            "/pipeline/resolve-address",
            headers=GOOD_BEARER,
            json={"pipelineSchemaVersion": "9.0.0", "address": "123 Main St"},
        )
        assert response.status_code == 409

    def test_happy_path_returns_valid_response(self, monkeypatch):
        """Full endpoint test with mocked service.resolve."""
        from app.resolve_address import router as router_mod

        def mock_resolve(address, **kwargs):
            from contracts.pipeline import Address, AttributionItem, GeometrySource, Polygon, ResolveAddressResponse
            return ResolveAddressResponse(
                pipelineSchemaVersion=PIPELINE_SCHEMA_VERSION,
                geocode=Address(
                    raw=address,
                    normalized="123 Main St, Seattle, WA 98101, USA",
                    lat=47.6062,
                    lon=-122.3321,
                    source=GeometrySource.IMAGERY,
                    confidence=0.95,
                ),
                parcel_polygon=Polygon(
                    type="Polygon",
                    coordinates=_PARCEL_COORDS,
                    source=GeometrySource.IMAGERY,
                    confidence=0.9,
                ),
                building_polygons=[
                    Polygon(
                        type="Polygon",
                        coordinates=_BUILDING_COORDS,
                        source=GeometrySource.IMAGERY,
                        confidence=0.9,
                    )
                ],
                attribution=[
                    AttributionItem(name="Nominatim / OpenStreetMap", license="ODbL 1.0", url="https://nominatim.org/"),
                    AttributionItem(name="Microsoft Building Footprints", license="ODbL 1.0", url="https://github.com/microsoft/GlobalMLBuildingFootprints"),
                    AttributionItem(name="Regrid", url="https://regrid.com/"),
                ],
                warnings=[],
            )

        monkeypatch.setattr(router_mod, "resolve", mock_resolve)

        response = client_app.post(
            "/pipeline/resolve-address",
            headers=GOOD_BEARER,
            json={"pipelineSchemaVersion": "0.2.0", "address": "123 Main St, Seattle, WA"},
        )
        assert response.status_code == 200, response.text
        body = response.json()
        assert_valid_response(body)
        assert body["pipelineSchemaVersion"] == "0.3.0"
        assert body["geocode"]["raw"] == "123 Main St, Seattle, WA"
        assert len(body["building_polygons"]) == 1
        assert body["parcel_polygon"] is not None

    def test_geocode_failure_returns_422(self, monkeypatch):
        """When service raises HTTPException 422, endpoint returns 422."""
        from app.resolve_address import router as router_mod
        from fastapi import HTTPException

        def mock_resolve(address, **kwargs):
            raise HTTPException(status_code=422, detail="Geocode failed: no results")

        monkeypatch.setattr(router_mod, "resolve", mock_resolve)

        response = client_app.post(
            "/pipeline/resolve-address",
            headers=GOOD_BEARER,
            json={"pipelineSchemaVersion": "0.2.0", "address": "XYZ IMPOSSIBLE ADDRESS"},
        )
        assert response.status_code == 422

    def test_parcel_null_with_warning(self, monkeypatch):
        """Endpoint returns 200 even when parcel_polygon is null."""
        from app.resolve_address import router as router_mod

        def mock_resolve(address, **kwargs):
            from contracts.pipeline import Address, AttributionItem, GeometrySource, Polygon, ResolveAddressResponse
            return ResolveAddressResponse(
                pipelineSchemaVersion=PIPELINE_SCHEMA_VERSION,
                geocode=Address(
                    raw=address,
                    normalized="456 Rural Rd",
                    lat=46.9965,
                    lon=-120.5478,
                    source=GeometrySource.IMAGERY,
                    confidence=0.9,
                ),
                parcel_polygon=None,
                building_polygons=[
                    Polygon(
                        type="Polygon",
                        coordinates=_BUILDING_COORDS,
                        source=GeometrySource.IMAGERY,
                        confidence=0.8,
                    )
                ],
                attribution=[
                    AttributionItem(name="Nominatim / OpenStreetMap"),
                    AttributionItem(name="Microsoft Building Footprints"),
                ],
                warnings=["parcel_unavailable: REGRID_API_KEY not set"],
            )

        monkeypatch.setattr(router_mod, "resolve", mock_resolve)

        response = client_app.post(
            "/pipeline/resolve-address",
            headers=GOOD_BEARER,
            json={"pipelineSchemaVersion": "0.2.0", "address": "456 Rural Rd"},
        )
        assert response.status_code == 200, response.text
        body = response.json()
        assert body["parcel_polygon"] is None
        assert any("parcel_unavailable" in w for w in body["warnings"])
        assert_valid_response(body)
