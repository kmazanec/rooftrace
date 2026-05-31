"""LiDAR ingest core: WESM coverage -> COPC crop -> class-6 -> UTM.

The five-hop plumbing from a WGS84 building polygon to a cropped, classified,
reprojected NumPy point array:

  1. coverage: WESM tells us which work unit (and its native CRS) covers the
     building; no hit -> LIDAR_MISSING (fast-fail, no fetch).
  2. fetch+crop: PDAL streams the work unit's COPC, cropping to the building
     polygon (+ a small eave buffer) reprojected into the COPC's native CRS.
  3. classify: keep only ASPRS class 6 (building).
  4. reproject: transform the kept points into the building's local UTM zone
     (meters) so the downstream plane-fit stage does metric geometry.
  5. cache: write the array to the Spaces `cache/lidar/<hash>.npy` key.

PDAL is conda-only (image), not a pip dep, so the actual COPC read is isolated
behind `PdalCropper` whose import is lazy; tests inject a `FixtureCropper` that
returns a canned point cloud, exercising hops 1,3,4,5 + the contract without
PDAL or network.
"""

from __future__ import annotations

import hashlib
import io
from dataclasses import dataclass
from datetime import date
from typing import Protocol

import numpy as np
from shapely.geometry import shape

from app import flags
from contracts.pipeline import LiDARStatus

from . import crs
from .wesm import WesmIndex, WorkUnit

ASPRS_BUILDING_CLASS = 6
EAVE_BUFFER_M = 1.0
STALE_YEARS = 5
_current_year = date.today().year  # only gates the stale_lidar warning


@dataclass
class CroppedCloud:
    """A cropped point cloud in some CRS. `points` is (N, >=4): x, y, z, class."""

    points: np.ndarray
    src_epsg: int


class ByteWriter(Protocol):
    """Storage writer accepted by `ingest_lidar`. Matches `app.storage.put_bytes`."""

    def __call__(self, key: str, data: bytes) -> str: ...


class Cropper(Protocol):
    """Fetch + crop a work unit's COPC to a polygon. Backend interface."""

    def crop(
        self,
        work_unit: WorkUnit,
        building_polygon_wgs84: dict,
        buffer_m: float = EAVE_BUFFER_M,
    ) -> CroppedCloud: ...


class PdalCropper(Cropper):
    """Real COPC reader via PDAL (conda-only; live path)."""

    def crop(self, work_unit: WorkUnit, building_polygon_wgs84: dict, buffer_m: float = EAVE_BUFFER_M) -> CroppedCloud:
        import json as _json

        import pdal  # conda-only; imported lazily so the module loads without it

        if not work_unit.copc_url:
            raise RuntimeError(f"work unit {work_unit.name} has no copc_url")

        # Crop polygon must be in the COPC's native CRS; reproject the WGS84 ring
        # (with the eave buffer applied in meters via the local UTM, then back).
        ring = building_polygon_wgs84["coordinates"][0]
        poly = shape(building_polygon_wgs84)
        centroid = poly.centroid
        utm = crs.utm_epsg_for(centroid.x, centroid.y)
        ring_utm = crs.reproject_ring(ring, 4326, utm)
        buffered = shape({"type": "Polygon", "coordinates": [ring_utm]}).buffer(buffer_m)
        buffered_ring = list(buffered.exterior.coords)
        crop_ring_native = crs.reproject_ring([list(c) for c in buffered_ring], utm, work_unit.epsg)
        wkt = "POLYGON((" + ", ".join(f"{x} {y}" for x, y in crop_ring_native) + "))"

        pipeline = {
            "pipeline": [
                {"type": "readers.copc", "filename": work_unit.copc_url, "polygon": wkt},
                {"type": "filters.range", "limits": f"Classification[{ASPRS_BUILDING_CLASS}:{ASPRS_BUILDING_CLASS}]"},
            ]
        }
        # Stream the COPC over S3. Retry once on a transient read failure before
        # giving up (the spec's "S3 read timeout -> retry once, then 5xx").
        for attempt in range(2):
            try:
                p = pdal.Pipeline(_json.dumps(pipeline))
                p.execute()
                arr = p.arrays[0]
                pts = np.column_stack(
                    [arr["X"], arr["Y"], arr["Z"], arr["Classification"]]
                ).astype(np.float64)
                return CroppedCloud(points=pts, src_epsg=work_unit.epsg)
            except RuntimeError as err:  # PDAL surfaces S3/IO errors as RuntimeError
                last_err = err
                if attempt == 1:
                    raise RuntimeError(f"COPC read failed after retry: {last_err}") from last_err


def _filter_building_class(points: np.ndarray) -> np.ndarray:
    """Keep only ASPRS class-6 (building) points. points[:, 3] is classification."""
    if points.size == 0:
        return points
    mask = points[:, 3] == ASPRS_BUILDING_CLASS
    return points[mask]


def _reproject_points(points: np.ndarray, src_epsg: int, dst_epsg: int) -> np.ndarray:
    """Reproject (N,>=3) points' x,y between EPSG codes; z and class untouched."""
    if points.size == 0:
        return points
    if src_epsg == dst_epsg:
        return points
    t = crs.transformer(src_epsg, dst_epsg)
    xs, ys = t.transform(points[:, 0], points[:, 1])
    out = points.copy()
    out[:, 0] = xs
    out[:, 1] = ys
    return out


def _address_hash(building_polygon_wgs84: dict) -> str:
    payload = repr(building_polygon_wgs84["coordinates"]).encode()
    return hashlib.sha256(payload).hexdigest()[:16]


def _points_to_npy_bytes(points: np.ndarray) -> bytes:
    buf = io.BytesIO()
    np.save(buf, points)
    return buf.getvalue()


@dataclass
class IngestOutcome:
    """Result of the ingest core, mapped to the contract by the router."""

    status: LiDARStatus
    reason: str | None = None
    point_array_ref: str | None = None
    point_count: int | None = None
    work_unit: WorkUnit | None = None
    utm_zone: int | None = None
    bounds_utm: list[float] | None = None
    warnings: list[str] | None = None


def ingest_lidar(
    building_polygon_wgs84: dict,
    *,
    index: WesmIndex,
    cropper: Cropper,
    put_bytes: ByteWriter,
) -> IngestOutcome:
    """Run the five-hop ingest. `put_bytes(key, data) -> key` is the storage writer."""
    warnings: list[str] = []
    poly = shape(building_polygon_wgs84)
    minx, miny, maxx, maxy = poly.bounds
    bbox = (minx, miny, maxx, maxy)

    # Hop 1: coverage check (fast-fail).
    covering = index.query(bbox)
    if not covering:
        return IngestOutcome(status=LiDARStatus.MISSING, reason="no_coverage", warnings=["no_coverage"])
    work_unit = covering[0]

    if work_unit.year is not None and (_current_year - work_unit.year) > STALE_YEARS:
        warnings.append("stale_lidar")

    # Hop 2: fetch + crop (real PDAL on the live path; fixture cloud in tests).
    cloud = cropper.crop(work_unit, building_polygon_wgs84)

    # Hop 3: classification filter (class 6 only).
    building_pts = _filter_building_class(cloud.points)
    if building_pts.shape[0] == 0:
        return IngestOutcome(
            status=LiDARStatus.MISSING,
            reason="no_building_points",
            work_unit=work_unit,
            warnings=warnings + ["no_building_points"],
        )

    # Hop 4: reproject into the building's local UTM zone (meters).
    centroid = poly.centroid
    utm = crs.utm_epsg_for(centroid.x, centroid.y)
    utm_pts = _reproject_points(building_pts, cloud.src_epsg, utm)
    bxmin, bymin = float(utm_pts[:, 0].min()), float(utm_pts[:, 1].min())
    bxmax, bymax = float(utm_pts[:, 0].max()), float(utm_pts[:, 1].max())

    # Hop 5: cache the array.
    key = f"cache/lidar/{_address_hash(building_polygon_wgs84)}.npy"
    put_bytes(key, _points_to_npy_bytes(utm_pts))

    return IngestOutcome(
        status=LiDARStatus.AVAILABLE,
        point_array_ref=key,
        point_count=int(utm_pts.shape[0]),
        work_unit=work_unit,
        utm_zone=utm,
        bounds_utm=[bxmin, bymin, bxmax, bymax],
        warnings=warnings,
    )


def default_cropper() -> Cropper:
    """The cropper for the current environment.

    Real PDAL is the default (dev + prod always use real data). Under the fixture
    opt-down (`LIDAR_FIXTURE=1`, the test suites) the caller injects a
    FixtureCropper instead, so reaching here with the fixture flag set is a test
    misconfiguration, not a real-path request.
    """
    if flags.lidar_fixture():
        raise RuntimeError(
            "LIDAR_FIXTURE=1 but no FixtureCropper was injected; tests must pass "
            "their own cropper rather than calling default_cropper()"
        )
    return PdalCropper()
