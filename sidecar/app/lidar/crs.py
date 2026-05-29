"""CRS helpers for the LiDAR ingest stage.

The boundary convention (ADR-003): WGS84 (EPSG:4326) crosses the contract; the
sidecar works internally in a local UTM zone (meters) for metric geometry. This
module owns the one piece of that the ingest stage needs: picking the right local
UTM zone for a building and reprojecting between WGS84 and it.

pyproj is a pip dependency (always available); PDAL is conda-only and guarded
elsewhere, so nothing here imports it.
"""

from __future__ import annotations

from pyproj import Transformer


def utm_epsg_for(lon: float, lat: float) -> int:
    """The EPSG code of the WGS84/UTM zone containing (lon, lat).

    Northern hemisphere zones are 326xx, southern 327xx, where xx is the zone
    number 1..60. This is the zone the cropped points are reprojected into so
    area/pitch math is in meters with minimal distortion for a single building.
    """
    if not (-180.0 <= lon <= 180.0):
        raise ValueError(f"lon out of range: {lon}")
    if not (-90.0 <= lat <= 90.0):
        raise ValueError(f"lat out of range: {lat}")
    zone = int((lon + 180.0) // 6.0) + 1
    zone = min(max(zone, 1), 60)
    return (32600 if lat >= 0 else 32700) + zone


def transformer(src_epsg: int, dst_epsg: int) -> Transformer:
    """A pyproj Transformer in always-(x, y) = (lon/easting, lat/northing) order."""
    return Transformer.from_crs(src_epsg, dst_epsg, always_xy=True)


def reproject_ring(ring: list[list[float]], src_epsg: int, dst_epsg: int) -> list[list[float]]:
    """Reproject a GeoJSON linear ring [[lon, lat], ...] between EPSG codes."""
    t = transformer(src_epsg, dst_epsg)
    return [list(t.transform(x, y)) for x, y in ((p[0], p[1]) for p in ring)]
