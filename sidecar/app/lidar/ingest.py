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
ASPRS_GROUND_CLASS = 2
ASPRS_NOISE_CLASSES = (7, 18)  # low/high noise — never roof
EAVE_BUFFER_M = 1.0
STALE_YEARS = 5
_current_year = date.today().year  # only gates the stale_lidar warning

# Public 3DEP point clouds are served as Entwine Point Tiles (EPT) from the USGS
# open-data bucket, keyed by work-unit name. WESM's `lpc_link` points at a staged-
# products *folder* (not a readable COPC), so we resolve the EPT endpoint by name
# instead (the convention the entwine/USGS 3DEP public index uses). EPT is in
# EPSG:3857 regardless of the source-collection CRS.
USGS_EPT_BASE = "https://s3-us-west-2.amazonaws.com/usgs-lidar-public"
EPT_SRS_EPSG = 3857
# Minimum height (m) above local ground for a return to count as roof when a
# collection carries no class-6 (building) points — most public 3DEP only
# classifies ground (2) vs unclassified (1).
MIN_ROOF_HEIGHT_M = 2.0


def ept_url_for(work_unit_name: str) -> str:
    """The USGS public EPT endpoint for a WESM work-unit name."""
    return f"{USGS_EPT_BASE}/{work_unit_name}/ept.json"


class EptNotFound(Exception):
    """The work-unit's EPT resource doesn't exist in the USGS public bucket.

    A WESM work-unit NAME does not always match the entwine/EPT resource key
    (some projects are published under a different name, or not at all in the
    public EPT bucket). That's a COVERAGE gap for our purposes — handled as
    LIDAR_MISSING (graceful imagery fallback), NOT an infra error / 502.
    """


# S3/PDAL signatures that mean "this EPT key/bucket isn't there" (coverage gap)
# rather than a transient IO failure.
_EPT_ABSENT_MARKERS = ("NoSuchKey", "NoSuchBucket", "AccessDenied", "404", "Not Found")


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
    """Real 3DEP reader via PDAL over USGS public EPT (conda-only; live path).

    Reads from the USGS open-data EPT endpoint (resolved from the work-unit name),
    cropping to the building polygon + eave buffer. Classification is kept in the
    returned array (NOT filtered in PDAL) so the ingest core can fall back to
    height-based roof extraction when a collection has no class-6 points. EPT is
    EPSG:3857, so the returned `src_epsg` is 3857.
    """

    def crop(self, work_unit: WorkUnit, building_polygon_wgs84: dict, buffer_m: float = EAVE_BUFFER_M) -> CroppedCloud:
        import json as _json

        import pdal  # conda-only; imported lazily so the module loads without it

        # Resolve the EPT endpoint from the work-unit NAME. WESM's lpc_link
        # (carried on work_unit.copc_url) is a staged-products folder, not a
        # readable EPT/COPC, so it is deliberately NOT used as the reader source.
        ept = ept_url_for(work_unit.name)

        # Crop polygon must be in the reader's CRS (EPT = EPSG:3857). Apply the
        # eave buffer in meters via the local UTM, then reproject the buffered ring
        # into 3857 (also meters, so the buffer magnitude is preserved well enough
        # for a 1 m eave at building scale).
        ring = building_polygon_wgs84["coordinates"][0]
        poly = shape(building_polygon_wgs84)
        centroid = poly.centroid
        utm = crs.utm_epsg_for(centroid.x, centroid.y)
        ring_utm = crs.reproject_ring(ring, 4326, utm)
        buffered = shape({"type": "Polygon", "coordinates": [ring_utm]}).buffer(buffer_m)
        buffered_ring = list(buffered.exterior.coords)
        crop_ring_3857 = crs.reproject_ring([list(c) for c in buffered_ring], utm, EPT_SRS_EPSG)
        wkt = "POLYGON((" + ", ".join(f"{x} {y}" for x, y in crop_ring_3857) + "))"

        pipeline = {
            "pipeline": [
                {"type": "readers.ept", "filename": ept, "polygon": wkt},
            ]
        }
        # Stream the EPT over S3. Retry once on a transient read failure before
        # giving up (the spec's "S3 read timeout -> retry once, then 5xx").
        last_err: Exception | None = None
        for attempt in range(2):
            try:
                p = pdal.Pipeline(_json.dumps(pipeline))
                p.execute()
                arr = p.arrays[0] if p.arrays else np.empty(0)
                if len(arr) == 0:
                    return CroppedCloud(points=np.empty((0, 4)), src_epsg=EPT_SRS_EPSG)
                pts = np.column_stack(
                    [arr["X"], arr["Y"], arr["Z"], arr["Classification"]]
                ).astype(np.float64)
                return CroppedCloud(points=pts, src_epsg=EPT_SRS_EPSG)
            except RuntimeError as err:  # PDAL surfaces S3/IO errors as RuntimeError
                last_err = err
                # A missing EPT resource is a coverage gap, not a transient error —
                # don't retry, signal LIDAR_MISSING so the pipeline degrades cleanly.
                if any(marker in str(err) for marker in _EPT_ABSENT_MARKERS):
                    raise EptNotFound(
                        f"no public EPT for work unit {work_unit.name}"
                    ) from err
                if attempt == 1:
                    raise RuntimeError(f"EPT read failed after retry: {last_err}") from last_err
        raise RuntimeError(f"EPT read failed: {last_err}")


def _extract_building_points(points: np.ndarray) -> tuple[np.ndarray, str]:
    """Isolate roof points within the already-footprint-cropped cloud.

    Returns (points, method). points[:, 3] is ASPRS classification.

    Strategy, in order:
      1. If the collection has class-6 (building) points, trust them — that's the
         authoritative label ("class6").
      2. Otherwise — the common case for public 3DEP, which often classifies only
         ground (2) vs unclassified (1) — extract by HEIGHT: drop noise, estimate
         local ground from the ground (class-2) returns (or a low percentile if
         none), and keep non-ground returns that sit >= MIN_ROOF_HEIGHT_M above it
         ("height_above_ground"). Because the cloud is already cropped to the
         building footprint + a 1 m eave, the elevated returns there are the roof.
    """
    if points.size == 0:
        return points, "empty"

    cls = points[:, 3]
    building = points[cls == ASPRS_BUILDING_CLASS]
    if building.shape[0] > 0:
        return building, "class6"

    # Height-based fallback. Remove noise classes first.
    noise_mask = np.isin(cls, ASPRS_NOISE_CLASSES)
    clean = points[~noise_mask]
    if clean.shape[0] == 0:
        return clean, "empty"

    ground = clean[clean[:, 3] == ASPRS_GROUND_CLASS]
    if ground.shape[0] >= 10:
        ground_z = float(np.percentile(ground[:, 2], 50))
    else:
        # No usable ground class — approximate ground as a low percentile of all
        # returns in the footprint.
        ground_z = float(np.percentile(clean[:, 2], 10))

    non_ground = clean[clean[:, 3] != ASPRS_GROUND_CLASS]
    roof = non_ground[non_ground[:, 2] >= ground_z + MIN_ROOF_HEIGHT_M]
    return roof, "height_above_ground"


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


# Meters -> US survey feet is negligibly different from international feet at roof
# scale; use the international-foot factor the report's pitch/area math uses.
_M_TO_FT = 3.280839895

# Default cap on points returned to the browser overlay. A roof crop can be tens
# of thousands of returns; capping protects the JSON size and the GPU. Overridable
# per-request via max_points.
DEFAULT_MAX_OVERLAY_POINTS = 20_000

# Cap on the cached .npy we'll decode (defense against a bearer-authenticated
# caller pointing point_array_ref at a huge object — see storage.get_bytes_capped).
MAX_POINT_ARRAY_BYTES = 64 * 1024 * 1024  # 64 MiB


@dataclass
class OverlayPoints:
    """WGS84 points for the report overlay: [lon, lat, elev_ft] rows."""

    points: list[list[float]]
    point_count: int  # total in the cached array, before downsampling
    returned_count: int
    bounds: list[float] | None  # [minLon, minLat, maxLon, maxLat] or None


def load_overlay_points(
    npy_bytes: bytes,
    *,
    utm_zone: int,
    max_points: int = DEFAULT_MAX_OVERLAY_POINTS,
) -> OverlayPoints:
    """Decode a cached cropped point array (local UTM meters) into WGS84 overlay
    points: uniformly downsample to <=max_points, reproject x,y to EPSG:4326, and
    convert z meters->feet. Rounds to shrink the JSON (6 dp lon/lat ~ 0.1m; 1 dp ft).
    """
    arr = np.load(io.BytesIO(npy_bytes))
    if arr.ndim != 2 or arr.shape[1] < 3:
        raise ValueError(f"point array has unexpected shape {arr.shape}")
    total = int(arr.shape[0])
    if total == 0:
        return OverlayPoints(points=[], point_count=0, returned_count=0, bounds=None)

    # Uniform stride downsample (deterministic, preserves spatial spread better
    # than head-slicing a spatially-sorted array).
    if total > max_points:
        idx = np.linspace(0, total - 1, num=max_points).astype(np.int64)
        sample = arr[idx]
    else:
        sample = arr

    t = crs.transformer(utm_zone, 4326)
    lons, lats = t.transform(sample[:, 0], sample[:, 1])
    elev_ft = sample[:, 2] * _M_TO_FT

    lons = np.round(lons, 6)
    lats = np.round(lats, 6)
    elev_ft = np.round(elev_ft, 1)

    points = np.column_stack([lons, lats, elev_ft]).tolist()
    bounds = [
        float(lons.min()),
        float(lats.min()),
        float(lons.max()),
        float(lats.max()),
    ]
    return OverlayPoints(
        points=points,
        point_count=total,
        returned_count=len(points),
        bounds=bounds,
    )


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

    # Hop 2: fetch + crop. WESM may list several covering work units (most-recent
    # first); a unit's NAME doesn't always have a public EPT resource, so try each
    # in turn and only declare MISSING once none resolve — a real coverage gap,
    # not a 502.
    work_unit = covering[0]
    cloud = None
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
            warnings=["no_ept_resource"],
        )

    if work_unit.year is not None and (_current_year - work_unit.year) > STALE_YEARS:
        warnings.append("stale_lidar")

    # Hop 3: isolate roof points (class-6 if labeled, else height-above-ground).
    building_pts, extract_method = _extract_building_points(cloud.points)
    if building_pts.shape[0] == 0:
        return IngestOutcome(
            status=LiDARStatus.MISSING,
            reason="no_building_points",
            work_unit=work_unit,
            warnings=warnings + ["no_building_points"],
        )
    if extract_method == "height_above_ground":
        # Honest signal that the roof came from height extraction, not a building
        # classification — slightly lower geometric confidence than class-6.
        warnings.append("lidar_height_extracted")

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
