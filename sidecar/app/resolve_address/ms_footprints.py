"""Microsoft Building Footprints client for F-05.

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

import gzip
import json
import logging
import math
import os
from collections.abc import Generator

import httpx
from shapely.affinity import scale
from shapely.geometry import Point, mapping, shape
from shapely.geometry import Polygon as ShapelyPolygon

logger = logging.getLogger(__name__)

# Public tile endpoint — no credentials needed.
_MS_BASE_URL = os.environ.get(
    "MS_FOOTPRINTS_BASE_URL",
    "https://minedbuildings.z5.web.core.windows.net/global-buildings",
)

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

def _fetch_tile_geojsonl(
    quadkey: str,
    *,
    client: httpx.Client | None = None,
) -> bytes:
    """Download the raw bytes of the GeoJSON-lines file for *quadkey*.

    The public MS dataset serves gzip-compressed GeoJSON-lines.
    Raises httpx.HTTPStatusError on a non-2xx response.
    """
    url = f"{_MS_BASE_URL}/{quadkey}.geojsonl.gz"
    close_after = client is None
    if client is None:
        client = httpx.Client(timeout=30.0)
    try:
        resp = client.get(url)
        resp.raise_for_status()
        return resp.content
    finally:
        if close_after:
            client.close()


def _parse_geojsonl(raw: bytes) -> Generator[dict, None, None]:
    """Decompress and parse a GeoJSON-lines blob, yielding one feature dict
    per line.  Lines that fail to parse are skipped with a warning."""
    try:
        text = gzip.decompress(raw).decode("utf-8")
    except OSError:
        # Not gzip — try raw UTF-8
        text = raw.decode("utf-8")

    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            yield json.loads(line)
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
    except Exception as exc:
        raise FootprintError(f"MS Building Footprints tile fetch error: {exc}") from exc

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

    results = []
    for feature in _parse_geojsonl(raw):
        geom_data = feature.get("geometry") or feature  # handle both Feature and bare geom
        if geom_data.get("type") != "Polygon":
            continue
        coords = geom_data.get("coordinates")
        if not coords:
            continue
        try:
            footprint = _polygon_to_shapely(coords)
        except Exception as exc:
            logger.warning("ms_footprints: invalid polygon, skipping: %s", exc)
            continue

        if parcel_shape is not None:
            if footprint.intersects(parcel_shape):
                results.append(coords)
        else:
            if footprint.intersects(fallback_zone):
                results.append(coords)

    return results
