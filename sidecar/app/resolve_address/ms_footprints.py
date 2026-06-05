"""Microsoft Building Footprints client for the address & polygon resolver.

Source: Microsoft's global building footprints dataset hosted as anonymous
public objects on Azure Blob Storage (aka the "ML Building Footprints" dataset,
https://github.com/microsoft/GlobalMLBuildingFootprints).

The dataset is partitioned into tiles keyed by a quadkey (Bing Maps tile
scheme) at zoom level 9.  Given a lat/lon we:

  1. Derive the quadkey for the containing zoom-9 tile.
  2. Download the GeoJSON-lines file for that tile from the public URL.
  3. Filter to polygons within the parcel boundary (if provided) or within a
     50 m radius fallback.

Cache key: ``ms_footprints:<quadkey>``  (TTL: 30 d per spec).

No credentials required — the data is publicly accessible without auth.

Implementation notes
--------------------
* We use quadkey (Bing Maps) at zoom 9, matching the MS dataset tile scheme.
* Footprint coordinates are already WGS84, so no reprojection needed at the
  contract boundary.
* Shapely is used for the intersection/distance filtering; all metric
  operations (50 m buffer) are approximated in degrees via a simple
  lat-dependent conversion (good enough at this scale — real UTM reprojection
  lives inside the sidecar and never crosses the contract per ADR-003).
"""

from __future__ import annotations

import csv
import gzip
import io
import json
import logging
import math
import os
import threading
from collections.abc import Iterator

import httpx
from shapely.affinity import scale
from shapely.errors import ShapelyError
from shapely.geometry import Point
from shapely.geometry import Polygon as ShapelyPolygon

logger = logging.getLogger(__name__)

# Public blob host — no credentials needed.
_MS_BASE_URL = os.environ.get(
    "MS_FOOTPRINTS_BASE_URL",
    "https://minedbuildings.z5.web.core.windows.net/global-buildings",
)

# The dataset is NOT a flat <base>/<quadkey>.geojsonl.gz layout. Tile files live
# at region-partitioned, dated paths whose exact URLs are listed in an index CSV
# (Location,QuadKey,Url,Size,UploadDate). We must resolve a quadkey to its real
# URL through this index — constructing the URL from the quadkey alone 404s.
_MS_INDEX_URL = os.environ.get(
    "MS_FOOTPRINTS_INDEX_URL",
    f"{_MS_BASE_URL}/dataset-links.csv",
)

# US addresses are RoofTrace's footprint, so prefer the UnitedStates region row
# for a quadkey when several regions list it (the index also has continent-level
# rows like NorthAmerica that are coarser / partial for the same tile).
_PREFERRED_REGIONS = ("UnitedStates",)

# Process-cached index: {quadkey: {region: url}}. The CSV is ~tens of MB and
# changes rarely; parsing it on every request would be wasteful, so load once.
_index_lock = threading.Lock()
_index_by_quadkey: dict[str, dict[str, str]] | None = None

# Approximate degrees per metre at the equator (used for the 50 m buffer
# fallback; fine enough for disambiguation at building scale).
_DEG_PER_METRE_LAT = 1.0 / 111_320.0
_FALLBACK_RADIUS_M = 50.0


# ---------------------------------------------------------------------------
# Quadkey helpers (Bing Maps tile scheme, zoom 9)
# ---------------------------------------------------------------------------

def _lat_lon_to_tile_xy(lat: float, lon: float, zoom: int) -> tuple[int, int]:
    """Convert WGS84 lat/lon to tile X/Y at the given zoom level."""
    lat_rad = math.radians(lat)
    n = 2 ** zoom
    x = int((lon + 180.0) / 360.0 * n)
    y = int((1.0 - math.log(math.tan(lat_rad) + 1.0 / math.cos(lat_rad)) / math.pi) / 2.0 * n)
    # Clamp to valid tile range
    x = max(0, min(n - 1, x))
    y = max(0, min(n - 1, y))
    return x, y


def _tile_xy_to_quadkey(tile_x: int, tile_y: int, zoom: int) -> str:
    """Convert tile X/Y/zoom to a Bing Maps quadkey string."""
    quadkey = []
    for i in range(zoom, 0, -1):
        digit = 0
        mask = 1 << (i - 1)
        if tile_x & mask:
            digit += 1
        if tile_y & mask:
            digit += 2
        quadkey.append(str(digit))
    return "".join(quadkey)


def lat_lon_to_quadkey(lat: float, lon: float, zoom: int = 9) -> str:
    """Return the Bing Maps quadkey for the tile covering (lat, lon) at zoom."""
    x, y = _lat_lon_to_tile_xy(lat, lon, zoom)
    return _tile_xy_to_quadkey(x, y, zoom)


# ---------------------------------------------------------------------------
# HTTP fetch
# ---------------------------------------------------------------------------

def _parse_dataset_index(raw: bytes) -> dict[str, dict[str, str]]:
    """Parse dataset-links.csv into {quadkey: {region: url}}."""
    index: dict[str, dict[str, str]] = {}
    reader = csv.DictReader(io.StringIO(raw.decode("utf-8")))
    for row in reader:
        quadkey = row.get("QuadKey")
        url = row.get("Url")
        region = row.get("Location")
        if not (quadkey and url and region):
            continue
        index.setdefault(quadkey, {})[region] = url
    return index


def _load_dataset_index(client: httpx.Client) -> dict[str, dict[str, str]]:
    """Fetch + process-cache the dataset-links.csv index.

    Cached for the process lifetime (the index changes rarely and is large).
    Raises FootprintError if the index can't be fetched — without it no quadkey
    can be resolved, so this is a hard failure, not a soft "no coverage".
    """
    global _index_by_quadkey
    if _index_by_quadkey is not None:
        return _index_by_quadkey
    with _index_lock:
        if _index_by_quadkey is not None:  # another thread loaded it while we waited
            return _index_by_quadkey
        try:
            resp = client.get(_MS_INDEX_URL)
            resp.raise_for_status()
        except httpx.HTTPStatusError as exc:
            raise FootprintError(
                f"MS Building Footprints index fetch failed: HTTP {exc.response.status_code}"
            ) from exc
        except httpx.RequestError as exc:
            raise FootprintError(
                f"MS Building Footprints index request failed: {type(exc).__name__}"
            ) from exc
        _index_by_quadkey = _parse_dataset_index(resp.content)
        logger.info(
            "ms_footprints: loaded dataset index (%d quadkeys)", len(_index_by_quadkey)
        )
        return _index_by_quadkey


def _resolve_tile_url(quadkey: str, client: httpx.Client) -> str | None:
    """Resolve *quadkey* to its real tile URL via the dataset index, preferring a
    US region row. Returns None when the quadkey is absent (no coverage)."""
    regions = _load_dataset_index(client).get(quadkey)
    if not regions:
        return None
    for preferred in _PREFERRED_REGIONS:
        if preferred in regions:
            return regions[preferred]
    # No preferred region — fall back to any available region for the tile.
    return next(iter(regions.values()))


def _fetch_tile_geojsonl(
    quadkey: str,
    *,
    client: httpx.Client | None = None,
) -> bytes | None:
    """Download the raw bytes of the GeoJSON-lines file for *quadkey*.

    Resolves the real tile URL through the dataset index, then fetches it. The
    public MS dataset serves gzip-compressed GeoJSON-lines. Returns None when the
    quadkey has no row in the index (no coverage — not an error).
    Raises httpx.HTTPStatusError on a non-2xx tile response.
    """
    close_after = client is None
    if client is None:
        client = httpx.Client(timeout=30.0)
    try:
        url = _resolve_tile_url(quadkey, client)
        if url is None:
            logger.warning("ms_footprints: quadkey %s absent from dataset index", quadkey)
            return None
        resp = client.get(url)
        resp.raise_for_status()
        return resp.content
    finally:
        if close_after:
            client.close()


def _parse_geojsonl(raw: bytes) -> Iterator[dict]:
    """Decompress and parse a GeoJSON-lines blob, yielding one feature dict
    per line.  Lines that fail to parse are skipped with a warning."""
    try:
        text = gzip.decompress(raw).decode("utf-8")
    except OSError:
        # Not gzip — try raw UTF-8
        text = raw.decode("utf-8")

    for line in text.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        try:
            yield json.loads(stripped)
        except json.JSONDecodeError as exc:
            logger.warning("ms_footprints: skipping malformed GeoJSON line: %s", exc)


# ---------------------------------------------------------------------------
# Filtering + public API
# ---------------------------------------------------------------------------

class FootprintError(Exception):
    """Raised when the footprint tile cannot be fetched."""


def _polygon_to_shapely(coords: list) -> ShapelyPolygon:
    """Convert GeoJSON Polygon coordinates (list of rings) to a Shapely Polygon."""
    exterior = coords[0]
    holes = coords[1:] if len(coords) > 1 else []
    return ShapelyPolygon(exterior, holes)


def fetch_footprints(
    lat: float,
    lon: float,
    parcel_polygon_coords: list | None = None,
    *,
    client: httpx.Client | None = None,
) -> list[list]:
    """Return a list of building-polygon coordinate rings (GeoJSON format).

    Filters candidates to those that:
      • intersect the *parcel_polygon_coords* (list of rings, GeoJSON), if given, OR
      • lie within a 50 m radius of (lat, lon) as a fallback.

    Returns an empty list when no matching footprints are found for the tile.
    The caller (service.py) treats an empty list as a hard 422.

    Parameters
    ----------
    lat, lon:
        WGS84 coordinates of the geocoded point.
    parcel_polygon_coords:
        GeoJSON Polygon coordinate rings for the parcel boundary; used to
        select footprints that intersect the parcel.  When None the 50 m
        radius fallback is used.
    client:
        Optional httpx.Client (injected in tests).
    """
    quadkey = lat_lon_to_quadkey(lat, lon)

    try:
        raw = _fetch_tile_geojsonl(quadkey, client=client)
    except httpx.HTTPStatusError as exc:
        if exc.response.status_code == 404:
            logger.warning("ms_footprints: no tile for quadkey %s (404)", quadkey)
            return []
        raise FootprintError(
            f"MS Building Footprints tile fetch failed: HTTP {exc.response.status_code}"
        ) from exc
    except httpx.RequestError as exc:
        raise FootprintError(
            f"MS Building Footprints tile request failed: {type(exc).__name__}"
        ) from exc
    except FootprintError:
        raise  # index-fetch failure already wrapped; don't double-wrap

    # Quadkey absent from the dataset index — legitimate "no coverage".
    if raw is None:
        return []

    center = Point(lon, lat)

    if parcel_polygon_coords is not None:
        parcel_shape = _polygon_to_shapely(parcel_polygon_coords)
    else:
        parcel_shape = None

    # 50 m fallback zone in degrees. A degree of longitude shrinks with latitude
    # (~cos(lat)), so a fixed-radius circle in degree space would be too narrow
    # east-west at high latitudes and silently miss footprints. Build a proper
    # ellipse: a unit circle scaled by the per-axis degree radii.
    lat_rad = math.radians(lat)
    deg_per_m_lon = _DEG_PER_METRE_LAT / max(math.cos(lat_rad), 1e-9)
    fallback_buffer_deg_lat = _FALLBACK_RADIUS_M * _DEG_PER_METRE_LAT
    fallback_buffer_deg_lon = _FALLBACK_RADIUS_M * deg_per_m_lon
    fallback_zone = scale(
        center.buffer(1.0),
        xfact=fallback_buffer_deg_lon,
        yfact=fallback_buffer_deg_lat,
        origin=center,
    )

    scored_results = []
    for feature in _parse_geojsonl(raw):
        geom_data = feature.get("geometry") or feature  # handle both Feature and bare geom
        if geom_data.get("type") != "Polygon":
            continue
        coords = geom_data.get("coordinates")
        if not coords:
            continue
        try:
            footprint = _polygon_to_shapely(coords)
        except (ValueError, TypeError, ShapelyError) as exc:
            logger.warning("ms_footprints: invalid polygon, skipping: %s", exc)
            continue

        if parcel_shape is not None:
            matches = footprint.intersects(parcel_shape)
        else:
            matches = footprint.intersects(fallback_zone)

        if matches:
            scored_results.append(
                (
                    footprint.distance(center),
                    footprint.centroid.distance(center),
                    -footprint.area,
                    coords,
                )
            )

    scored_results.sort(key=lambda item: item[:3])
    return [coords for *_score, coords in scored_results]
