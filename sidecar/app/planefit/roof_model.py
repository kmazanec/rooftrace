"""Roof-model construction for LiDAR-derived measurements.

The model lives in local UTM coordinates and is converted to the legacy facet
contract only at the sidecar boundary. It constrains plane support to the
refined roof outline so total area is driven by a coherent roof footprint, not
by independent point-cloud bounding boxes.
"""

from __future__ import annotations

import math
import warnings
from dataclasses import dataclass, field
from typing import Any

import numpy as np
import numpy.typing as npt
from pyproj import Transformer
from shapely.geometry import GeometryCollection, MultiPoint, MultiPolygon, Polygon
from shapely.ops import unary_union

from .plane_fit import facet_confidence, point_density
from .topology import MergedPlane

_SQM_TO_SQFT = 10.7639
_PITCH_STEP = 0.5
_MIN_FACET_CONFIDENCE = 0.4
_MIN_MODEL_FACET_AREA_M2 = 0.25
_ADJACENCY_TOLERANCE_M = 0.08


@dataclass
class RoofModelFacet:
    facet_id: str
    plane_index: int
    plane: MergedPlane
    polygon_utm: Polygon
    plan_area_m2: float
    surface_area_m2: float
    pitch_degrees: float
    pitch_ratio: float
    confidence: float
    inlier_count: int
    point_density_per_m2: float
    boundary_method: str


@dataclass
class RoofModelEdge:
    facet_a: str
    facet_b: str
    kind: str
    length_m: float


@dataclass
class RoofModel:
    facets: list[RoofModelFacet]
    edges: list[RoofModelEdge]
    warnings: list[str] = field(default_factory=list)
    diagnostics: dict[str, Any] = field(default_factory=dict)


def _utm_epsg(utm_zone: int, northern: bool = True) -> int:
    if 32601 <= utm_zone <= 32660 or 32701 <= utm_zone <= 32760:
        return utm_zone
    if 1 <= utm_zone <= 60:
        return (32600 if northern else 32700) + utm_zone
    raise ValueError(f"utm_zone {utm_zone} is neither a UTM EPSG code nor a zone 1..60")


def _polygon_coordinates(poly: Any) -> list[list[list[float]]]:
    if hasattr(poly, "coordinates"):
        return poly.coordinates
    return poly["coordinates"]


def refined_outline_to_utm(refined_polygon: Any, utm_zone: int) -> Polygon:
    """Transform a contract WGS84 polygon into the local UTM model space."""
    epsg = _utm_epsg(utm_zone)
    transformer = Transformer.from_crs(4326, epsg, always_xy=True)
    rings = []
    for ring in _polygon_coordinates(refined_polygon):
        lons = [c[0] for c in ring]
        lats = [c[1] for c in ring]
        eastings, northings = transformer.transform(lons, lats)
        rings.append(list(zip(eastings, northings)))
    exterior = rings[0]
    holes = rings[1:] if len(rings) > 1 else None
    outline = Polygon(exterior, holes)
    if not outline.is_valid:
        outline = outline.buffer(0)
    if outline.is_empty or outline.area <= 0:
        raise ValueError("degenerate refined polygon: zero planimetric area")
    return _largest_polygon(outline)


def _largest_polygon(geom) -> Polygon:
    if geom.is_empty:
        return Polygon()
    if isinstance(geom, Polygon):
        return geom
    if isinstance(geom, MultiPolygon):
        return max(geom.geoms, key=lambda g: g.area, default=Polygon())
    if isinstance(geom, GeometryCollection):
        polygons = [g for g in geom.geoms if isinstance(g, Polygon)]
        return max(polygons, key=lambda g: g.area, default=Polygon())
    return Polygon()


def _normal_to_pitch(normal: npt.NDArray) -> tuple[float, float]:
    nz = float(np.clip(abs(normal[2]), 0.0, 1.0))
    pitch_rad = math.acos(nz)
    pitch_deg = math.degrees(pitch_rad)
    rise_per_12 = math.tan(pitch_rad) * 12.0
    pitch_ratio = round(rise_per_12 / _PITCH_STEP) * _PITCH_STEP
    return pitch_deg, pitch_ratio


def _support_polygon(inlier_pts: npt.NDArray) -> Polygon:
    """Return a robust plan-view support polygon for a plane's inlier points."""
    if len(inlier_pts) < 3:
        return Polygon()
    points_2d = inlier_pts[:, :2]
    hull = MultiPoint(points_2d.tolist()).convex_hull
    if hull.is_empty:
        return Polygon()
    if isinstance(hull, Polygon):
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", RuntimeWarning)
            return hull.minimum_rotated_rectangle
    return Polygon()


def _clip_support(support: Polygon, outline: Polygon) -> tuple[Polygon, list[str]]:
    warnings: list[str] = []
    if support.is_empty or support.area <= 0:
        return Polygon(), warnings
    clipped = support.intersection(outline)
    if support.area > 0 and clipped.area < support.area * 0.98:
        warnings.append("outline_clipped")
    clipped = _largest_polygon(clipped)
    if not clipped.is_valid:
        clipped = clipped.buffer(0)
    return _largest_polygon(clipped), warnings


def _facet_kind(a: RoofModelFacet, b: RoofModelFacet) -> str:
    cos_angle = float(np.clip(abs(np.dot(a.plane.normal, b.plane.normal)), 0.0, 1.0))
    angle_deg = math.degrees(math.acos(cos_angle))
    if angle_deg < 1.0:
        return "coplanar"
    return "ridge"


def _build_edges(facets: list[RoofModelFacet]) -> list[RoofModelEdge]:
    edges: list[RoofModelEdge] = []
    for i, a in enumerate(facets):
        for b in facets[i + 1:]:
            shared = a.polygon_utm.boundary.intersection(b.polygon_utm.boundary)
            length = float(shared.length)
            if length <= 0 and a.polygon_utm.distance(b.polygon_utm) <= _ADJACENCY_TOLERANCE_M:
                length = 0.0
            if length > _ADJACENCY_TOLERANCE_M or (
                length == 0.0 and a.polygon_utm.distance(b.polygon_utm) <= _ADJACENCY_TOLERANCE_M
            ):
                edges.append(
                    RoofModelEdge(
                        facet_a=a.facet_id,
                        facet_b=b.facet_id,
                        kind=_facet_kind(a, b),
                        length_m=round(length, 4),
                    )
                )
    return edges


def build_roof_model(
    planes: list[MergedPlane],
    points: npt.NDArray,
    refined_polygon: Any,
    utm_zone: int,
) -> RoofModel:
    """Build an outline-constrained roof model from merged fitted planes."""
    outline = refined_outline_to_utm(refined_polygon, utm_zone)
    warnings: list[str] = []
    assigned = Polygon()
    facets: list[RoofModelFacet] = []

    candidates = []
    for plane_index, plane in enumerate(planes):
        inlier_pts = points[plane.inlier_indices]
        support = _support_polygon(inlier_pts)
        clipped, clip_warnings = _clip_support(support, outline)
        warnings.extend(clip_warnings)
        if clipped.is_empty or clipped.area < _MIN_MODEL_FACET_AREA_M2:
            warnings.append("facet_support_too_small")
            continue
        candidates.append((plane_index, plane, inlier_pts, clipped))

    # Largest supports get first claim; later overlapping supports are trimmed so
    # the plan-view roof model cannot double-count the same exterior area.
    candidates.sort(key=lambda item: item[3].area, reverse=True)
    for plane_index, plane, inlier_pts, clipped in candidates:
        if not assigned.is_empty:
            trimmed = clipped.difference(assigned)
            if trimmed.area < clipped.area * 0.98:
                warnings.append("facet_overlap_trimmed")
            clipped = _largest_polygon(trimmed)
        if clipped.is_empty or clipped.area < _MIN_MODEL_FACET_AREA_M2:
            warnings.append("facet_support_too_small")
            continue

        pitch_deg, pitch_ratio = _normal_to_pitch(plane.normal)
        nz = float(np.clip(abs(plane.normal[2]), 1e-6, 1.0))
        plan_area_m2 = float(clipped.area)
        surface_area_m2 = plan_area_m2 / nz
        pts_per_m2 = point_density(len(inlier_pts), plan_area_m2)
        confidence = facet_confidence(plane.inlier_ratio, pts_per_m2)
        if confidence < _MIN_FACET_CONFIDENCE:
            warnings.append("low_confidence_facet_dropped")
            continue

        facet = RoofModelFacet(
            facet_id=f"F{len(facets) + 1}",
            plane_index=plane_index,
            plane=plane,
            polygon_utm=clipped,
            plan_area_m2=plan_area_m2,
            surface_area_m2=surface_area_m2,
            pitch_degrees=pitch_deg,
            pitch_ratio=pitch_ratio,
            confidence=confidence,
            inlier_count=len(inlier_pts),
            point_density_per_m2=pts_per_m2,
            boundary_method="support_mbr_clipped_to_refined_outline",
        )
        facets.append(facet)
        assigned = clipped if assigned.is_empty else unary_union([assigned, clipped])

    edges = _build_edges(facets)
    coverage_ratio = 0.0
    if outline.area > 0 and not assigned.is_empty:
        coverage_ratio = float(assigned.intersection(outline).area / outline.area)
    if facets and coverage_ratio < 0.9:
        warnings.append("roof_model_partial_coverage")

    warnings = list(dict.fromkeys(warnings))
    diagnostics = {
        "model_version": "roof_model_v1",
        "plane_count": len(planes),
        "facet_count": len(facets),
        "edge_count": len(edges),
        "coverage_ratio": round(coverage_ratio, 4),
        "area_method": "outline_clipped_plan_area_div_cos_pitch",
        "boundary_method": "support_mbr_clipped_to_refined_outline",
        "warnings": warnings,
    }
    return RoofModel(facets=facets, edges=edges, warnings=warnings, diagnostics=diagnostics)


def roof_model_diagnostics(model: RoofModel) -> dict[str, Any]:
    return dict(model.diagnostics)


def plane_elevation_utm(normal: npt.NDArray, d: float, x: float, y: float) -> float | None:
    """Elevation (metres, UTM vertical) of the fitted plane at plan-view (x, y).

    The plane is ``normal·p + d = 0`` (see plane_fit), so the height at a given
    easting/northing is ``z = -(nx·x + ny·y + d) / nz``. Returns None for a
    (near-)vertical plane where nz≈0 (no single height) — callers then omit the z.
    """
    nz = float(normal[2])
    if abs(nz) < 1e-9:
        return None
    return -(float(normal[0]) * x + float(normal[1]) * y + d) / nz


def facet_vertices_wgs84(facet: RoofModelFacet, utm_zone: int) -> list[list[float]]:
    """Facet boundary as WGS84 ``[lon, lat, elev_m]`` vertices.

    The plan-view boundary lives in ``polygon_utm`` (easting/northing only); the
    third coordinate is the fitted plane's true elevation at each vertex, so the
    facet renders as a tilted plane (real pitch) downstream — not a flat slab.
    Elevation is metres in the UTM vertical datum (the LiDAR z), matching what the
    on-site photo-projection stage already reads from ``vertices[2]``.
    """
    epsg = _utm_epsg(utm_zone)
    transformer = Transformer.from_crs(epsg, 4326, always_xy=True)
    coords = list(facet.polygon_utm.exterior.coords)
    xs = [c[0] for c in coords]
    ys = [c[1] for c in coords]
    lons, lats = transformer.transform(xs, ys)
    normal, d = facet.plane.normal, facet.plane.d
    out: list[list[float]] = []
    for lon, lat, x, y in zip(np.atleast_1d(lons), np.atleast_1d(lats), xs, ys):
        vertex = [float(lon), float(lat)]
        elev = plane_elevation_utm(normal, d, x, y)
        if elev is not None:
            vertex.append(round(elev, 3))
        out.append(vertex)
    return out


def area_sq_ft(area_m2: float) -> float:
    return area_m2 * _SQM_TO_SQFT
