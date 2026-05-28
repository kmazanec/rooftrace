"""Per-facet geometry: pitch, pitch-corrected area, vertices, WGS84 conversion.

All UTM work is done in the coordinate system of the point cloud (EPSG derived
from utm_zone). Output vertices are transformed to WGS84 [lon, lat].
"""

from __future__ import annotations

import math
import uuid

import numpy as np
import numpy.typing as npt
from pyproj import Transformer
from shapely.geometry import MultiPoint

from contracts.pipeline import Facet, GeometrySource, MeasurementGeometry, PIPELINE_SCHEMA_VERSION
from .plane_fit import facet_confidence, point_density
from .topology import MergedPlane

# Square metres → square feet.
_SQM_TO_SQFT = 10.7639
# Metres → feet.
_M_TO_FT = 3.28084
# Pitch rounding: nearest 0.5 rise-per-12 step.
_PITCH_STEP = 0.5


def _utm_epsg(utm_zone: int, northern: bool = True) -> int:
    """Resolve the request's `utm_zone` field to a full UTM EPSG code.

    The pipeline contract carries `utm_zone` as a FULL EPSG code (e.g. 32614 for
    UTM 14N), which is what F-06 (the upstream LiDAR stage) emits. We also accept
    a bare zone number 1..60 defensively and expand it (32600/32700 + zone), so a
    caller that passes a zone rather than an EPSG still works.
    """
    if 32601 <= utm_zone <= 32660 or 32701 <= utm_zone <= 32760:
        return utm_zone  # already a full WGS84/UTM EPSG code
    if 1 <= utm_zone <= 60:
        return (32600 if northern else 32700) + utm_zone
    raise ValueError(f"utm_zone {utm_zone} is neither a UTM EPSG code nor a zone 1..60")


def _normal_to_pitch(normal: npt.NDArray) -> tuple[float, float]:
    """Return (pitch_degrees, pitch_ratio) from a plane unit normal.

    pitch_degrees: angle of the plane from horizontal (0 = flat, 90 = vertical).
    pitch_ratio:   contractor convention, rise per 12 run, e.g. 6.0 for "6/12".
                   Rounded to nearest 0.5 step.
    """
    nz = float(np.clip(abs(normal[2]), 0.0, 1.0))
    # normal is a unit vector; nz = cos(pitch_angle).
    pitch_rad = math.acos(nz)
    pitch_deg = math.degrees(pitch_rad)
    # rise/run = tan(pitch_rad).
    rise_per_12 = math.tan(pitch_rad) * 12.0
    # Round to nearest 0.5.
    rise_per_12_rounded = round(rise_per_12 / _PITCH_STEP) * _PITCH_STEP
    return pitch_deg, rise_per_12_rounded


def _project_to_plane(
    points: npt.NDArray, normal: npt.NDArray, origin: npt.NDArray
) -> npt.NDArray:
    """Project 3-D points onto a plane (defined by normal + origin), return 3-D coords."""
    # Each point p projects to p - dot(p-origin, normal)*normal
    offsets = points - origin  # (N, 3)
    dists = (offsets * normal).sum(axis=1, keepdims=True)  # (N, 1)
    return points - dists * normal  # (N, 3)


def _facet_area_2d(pts_2d: npt.NDArray) -> float:
    """Estimate area of a 2-D point set using the minimum bounding rectangle
    of its convex hull (oriented bounding box), in m².

    The minimum bounding rectangle (MBR) is much more accurate than a plain
    convex hull for rectangular facets: uniform sampling underestimates the
    hull by ~O(N^{-1/2}), whereas the MBR of the hull correctly recovers the
    rectangle's area to within the half-point-spacing boundary.

    For irregular (non-rectangular) facets the MBR over-estimates; that is
    acceptable since real roofs are roughly rectangular panels.
    """
    from shapely.geometry import MultiPoint as MP

    mp = MP(pts_2d.tolist())
    hull = mp.convex_hull
    # minimum_rotated_rectangle gives the tightest-fit bounding rectangle.
    mbr = hull.minimum_rotated_rectangle
    return float(mbr.area)


def _facet_surface_area_m2(
    inlier_pts: npt.NDArray,
    normal: npt.NDArray,
    centroid: npt.NDArray,
) -> tuple[float, float]:
    """Compute true surface area and planimetric area of a roof facet, both in m².

    Approach:
      1. Project inlier points onto the fitted plane (removing out-of-plane noise).
      2. Build a 2-D local coordinate system (u, v) on the plane.
      3. Compute convex hull area in (u, v) → this IS the true surface area,
         because u and v are unit vectors lying on the plane.
      4. Planimetric (horizontal projected) area = true_area * cos(pitch).

    Returns:
      (true_area_m2, planimetric_area_m2)
    """
    if len(inlier_pts) < 3:
        return 0.0, 0.0
    # Project onto plane.
    proj_3d = _project_to_plane(inlier_pts, normal, centroid)
    # Build 2-D coordinate system on the plane.
    u = _perp_vector(normal)
    v = np.cross(normal, u)
    # Project onto (u, v) — u, v are unit vectors on the plane, so area is in m².
    centered = proj_3d - centroid
    pts_2d = np.column_stack([centered @ u, centered @ v])
    true_area = _facet_area_2d(pts_2d)
    # Planimetric area = true_area * cos(pitch); nz = cos(pitch_angle).
    nz = float(np.clip(abs(normal[2]), 0.0, 1.0))
    planimetric_area = true_area * nz
    return true_area, planimetric_area


def _perp_vector(normal: npt.NDArray) -> npt.NDArray:
    """Return a unit vector perpendicular to `normal`."""
    if abs(normal[0]) <= abs(normal[1]) and abs(normal[0]) <= abs(normal[2]):
        candidate = np.array([1.0, 0.0, 0.0])
    elif abs(normal[1]) <= abs(normal[2]):
        candidate = np.array([0.0, 1.0, 0.0])
    else:
        candidate = np.array([0.0, 0.0, 1.0])
    perp = candidate - np.dot(candidate, normal) * normal
    norm = np.linalg.norm(perp)
    return perp / norm if norm > 1e-9 else candidate


def _convex_hull_vertices_utm(
    inlier_pts: npt.NDArray,
    normal: npt.NDArray,
    centroid: npt.NDArray,
) -> npt.NDArray:
    """Return convex hull vertices of the projected facet in UTM 3-D coordinates."""
    if len(inlier_pts) < 3:
        return inlier_pts

    proj_3d = _project_to_plane(inlier_pts, normal, centroid)
    u = _perp_vector(normal)
    v = np.cross(normal, u)
    centered = proj_3d - centroid
    pts_2d = np.column_stack([centered @ u, centered @ v])

    from shapely.geometry import MultiPoint as MP

    hull = MP(pts_2d.tolist()).convex_hull
    if hull.geom_type == "Polygon":
        hull_coords = np.array(hull.exterior.coords)
    elif hull.geom_type == "LineString":
        hull_coords = np.array(hull.coords)
    else:
        hull_coords = pts_2d[:1]

    # Back-project to UTM 3-D.
    result = centroid + hull_coords[:, 0:1] * u + hull_coords[:, 1:2] * v
    return result


def _utm_to_wgs84(
    utm_pts: npt.NDArray, utm_epsg: int
) -> list[list[float]]:
    """Transform UTM (easting, northing) → WGS84 [lon, lat]."""
    transformer = Transformer.from_crs(utm_epsg, 4326, always_xy=True)
    result = []
    for pt in utm_pts:
        lon, lat = transformer.transform(float(pt[0]), float(pt[1]))
        result.append([lon, lat])
    return result


def _polygon_area_m2_utm(
    polygon_coords: list[list[float]],
    utm_epsg: int,
) -> float:
    """Compute area in m² for a WGS84 polygon via UTM projection.

    polygon_coords: list of [lon, lat] rings (first is exterior).
    """
    from pyproj import Transformer
    from shapely.geometry import Polygon

    transformer = Transformer.from_crs(4326, utm_epsg, always_xy=True)
    exterior_wgs = polygon_coords[0]  # [[lon, lat], ...]
    exterior_utm = [transformer.transform(c[0], c[1]) for c in exterior_wgs]
    poly = Polygon(exterior_utm)
    return float(poly.area)


def build_facets_from_planes(
    planes: list[MergedPlane],
    points: npt.NDArray,
    utm_zone: int,
    source: GeometrySource = GeometrySource.LIDAR,
) -> list[Facet]:
    """Convert merged planes into Facet objects with WGS84 vertices."""
    epsg = _utm_epsg(utm_zone)
    facets: list[Facet] = []

    for plane in planes:
        inlier_pts = points[plane.inlier_indices]
        if len(inlier_pts) < 3:
            continue

        pitch_deg, pitch_ratio = _normal_to_pitch(plane.normal)

        # True surface area: computed directly in the plane coordinate frame.
        # The convex hull of points projected onto the plane = true surface area.
        # No cos(pitch) division needed — it's already pitch-corrected.
        true_area_m2, planimetric_area_m2 = _facet_surface_area_m2(
            inlier_pts, plane.normal, plane.centroid
        )
        area_sq_ft = true_area_m2 * _SQM_TO_SQFT

        # Convex hull vertices in UTM → WGS84.
        hull_utm = _convex_hull_vertices_utm(inlier_pts, plane.normal, plane.centroid)
        vertices_wgs84 = _utm_to_wgs84(hull_utm, epsg)

        # Per-facet confidence: use planimetric area for density (point count per m² ground).
        pts_per_m2 = point_density(len(inlier_pts), planimetric_area_m2)
        conf = facet_confidence(plane.inlier_ratio, pts_per_m2)

        facets.append(
            Facet(
                facet_id=str(uuid.uuid4()),
                vertices=vertices_wgs84,
                pitch_ratio=pitch_ratio,
                pitch_degrees=round(pitch_deg, 2),
                area_sq_ft=round(area_sq_ft, 2),
                source=source,
                confidence=round(conf, 4),
            )
        )

    return facets


def assemble_measurement(
    facets: list[Facet],
    source: GeometrySource,
    warnings: list[str] | None = None,
) -> MeasurementGeometry:
    """Aggregate facet list into a MeasurementGeometry response."""
    warnings = warnings or []

    if not facets:
        return MeasurementGeometry(
            pipelineSchemaVersion=PIPELINE_SCHEMA_VERSION,
            facets=[],
            total_area_sq_ft=0.0,
            total_perimeter_ft=None,
            primary_pitch_ratio=0.0,
            primary_pitch_degrees=0.0,
            source=source,
            confidence=0.0,
            warnings=warnings,
        )

    total_area = sum(f.area_sq_ft for f in facets)
    # Primary pitch = largest-area facet.
    primary_facet = max(facets, key=lambda f: f.area_sq_ft)
    primary_pitch_ratio = primary_facet.pitch_ratio
    primary_pitch_degrees = primary_facet.pitch_degrees

    # Overall confidence: area-weighted average of per-facet confidences.
    if total_area > 0:
        overall_conf = sum(f.confidence * f.area_sq_ft for f in facets) / total_area
    else:
        overall_conf = float(np.mean([f.confidence for f in facets]))

    return MeasurementGeometry(
        pipelineSchemaVersion=PIPELINE_SCHEMA_VERSION,
        facets=facets,
        total_area_sq_ft=round(total_area, 2),
        total_perimeter_ft=None,  # not computed in this version
        primary_pitch_ratio=primary_pitch_ratio,
        primary_pitch_degrees=round(primary_pitch_degrees, 2),
        source=source,
        confidence=round(float(np.clip(overall_conf, 0.0, 1.0)), 4),
        warnings=warnings,
    )


def fallback_measurement_from_polygon(
    polygon_coords: list[list[float]],
    inferred_pitch_degrees: float,
    utm_zone: int,
) -> MeasurementGeometry:
    """No-LiDAR path: planimetric polygon area / cos(pitch), single imagery facet."""
    epsg = _utm_epsg(utm_zone)
    planimetric_area_m2 = _polygon_area_m2_utm(polygon_coords, epsg)

    pitch_rad = math.radians(inferred_pitch_degrees)
    cos_pitch = math.cos(pitch_rad)
    true_area_m2 = planimetric_area_m2 / cos_pitch if cos_pitch > 1e-6 else planimetric_area_m2
    area_sq_ft = true_area_m2 * _SQM_TO_SQFT

    # Pitch ratio rounded to nearest 0.5 step.
    rise_per_12 = math.tan(pitch_rad) * 12.0
    pitch_ratio = round(rise_per_12 / _PITCH_STEP) * _PITCH_STEP

    # Vertices: exterior ring of the polygon as-is (already WGS84).
    exterior = polygon_coords[0]
    # Remove closing duplicate if present.
    if exterior[0] == exterior[-1]:
        exterior = exterior[:-1]

    facet = Facet(
        facet_id=str(uuid.uuid4()),
        vertices=exterior,
        pitch_ratio=pitch_ratio,
        pitch_degrees=round(inferred_pitch_degrees, 2),
        area_sq_ft=round(area_sq_ft, 2),
        source=GeometrySource.IMAGERY,
        confidence=0.5,  # lower confidence for no-LiDAR path
    )

    return MeasurementGeometry(
        pipelineSchemaVersion=PIPELINE_SCHEMA_VERSION,
        facets=[facet],
        total_area_sq_ft=round(area_sq_ft, 2),
        total_perimeter_ft=None,
        primary_pitch_ratio=pitch_ratio,
        primary_pitch_degrees=round(inferred_pitch_degrees, 2),
        source=GeometrySource.IMAGERY,
        confidence=0.5,
        warnings=["no_lidar_fallback"],
    )
