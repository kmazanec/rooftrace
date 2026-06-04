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
from shapely.geometry import GeometryCollection, MultiPoint, MultiPolygon, Polygon, box
from shapely.ops import unary_union

from .plane_fit import facet_confidence, point_density
from .topology import MergedPlane

_SQM_TO_SQFT = 10.7639
_PITCH_STEP = 0.5
_MIN_FACET_CONFIDENCE = 0.4
_MIN_MODEL_FACET_AREA_M2 = 0.25
_ADJACENCY_TOLERANCE_M = 0.08
# Two planes' supports this close (metres) are treated as a shared roof feature
# (ridge/hip/valley) and partitioned against each other; farther apart they are
# independent roof sections that never reassign each other's area.
_PARTITION_NEIGHBOR_BUFFER_M = 0.5


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


def _plane_z_coeffs(plane: MergedPlane) -> tuple[float, float, float]:
    """(a, b, c) s.t. the plane's elevation is z = a*x + b*y + c (UTM metres).

    From normal·p + d = 0: z = -(nx·x + ny·y + d) / nz.
    """
    n = plane.normal
    nz = float(n[2])
    if abs(nz) < 1e-9:
        nz = math.copysign(1e-9, nz) if nz != 0 else 1e-9
    return (-float(n[0]) / nz, -float(n[1]) / nz, -float(plane.d) / nz)


def _halfplane_polygon(alpha: float, beta: float, gamma: float, bbox: tuple) -> Polygon:
    """A polygon covering the half-plane {alpha·x + beta·y + gamma >= 0}, large
    enough to span (and be clipped by) a region inside ``bbox``."""
    minx, miny, maxx, maxy = bbox
    cx, cy = (minx + maxx) / 2.0, (miny + maxy) / 2.0
    reach = math.hypot(maxx - minx, maxy - miny) * 4.0 + 10.0
    norm = math.hypot(alpha, beta)
    if norm < 1e-12:
        # No gradient: the inequality is constant (gamma) across the plane.
        return box(cx - reach, cy - reach, cx + reach, cy + reach) if gamma >= 0 else Polygon()
    nx, ny = alpha / norm, beta / norm  # unit normal, points INTO the kept side
    dx, dy = -ny, nx  # along the boundary line
    dist = (alpha * cx + beta * cy + gamma) / norm
    fx, fy = cx - dist * nx, cy - dist * ny  # foot of perpendicular onto the line
    a = (fx + dx * reach, fy + dy * reach)
    b = (fx - dx * reach, fy - dy * reach)
    c = (b[0] + nx * 2 * reach, b[1] + ny * 2 * reach)
    d = (a[0] + nx * 2 * reach, a[1] + ny * 2 * reach)
    return Polygon([a, b, c, d])


def _support_clusters(supports: list[Polygon], buffer_m: float) -> list[list[int]]:
    """Group support polygons that touch/overlap (within ``buffer_m``) into shared
    roof features. Planes in different clusters are independent sections and never
    partition each other's area. Simple union-find over pairwise distance."""
    n = len(supports)
    parent = list(range(n))

    def find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for i in range(n):
        for j in range(i + 1, n):
            if supports[i].distance(supports[j]) <= buffer_m:
                parent[find(i)] = find(j)

    groups: dict[int, list[int]] = {}
    for i in range(n):
        groups.setdefault(find(i), []).append(i)
    return list(groups.values())


def _partition_cell(
    plane: MergedPlane,
    others: list[MergedPlane],
    coverage: Polygon | MultiPolygon,
    bbox: tuple,
) -> Polygon:
    """The part of ``coverage`` this plane owns: where its surface is the roof,
    among the planes it shares the feature with. The boundary against each other
    plane is their intersection line z_i == z_j (the ridge/hip/valley); this plane
    keeps the side its OWN points sit on — so the sign auto-adapts to ridges
    (peak) vs valleys, and an over-extended neighbour is cut back to the seam
    while a starved one grows out to it."""
    cell: Polygon | MultiPolygon = coverage
    ai, bi, ci = _plane_z_coeffs(plane)
    cx, cy = float(plane.centroid[0]), float(plane.centroid[1])
    for other in others:
        aj, bj, cj = _plane_z_coeffs(other)
        alpha, beta, gamma = ai - aj, bi - bj, ci - cj  # z_i - z_j
        side = alpha * cx + beta * cy + gamma  # sign of (z_i - z_j) at this plane's centroid
        if abs(side) < 1e-9:
            continue  # centroid sits on the seam — no usable orientation, skip
        if side < 0:
            alpha, beta, gamma = -alpha, -beta, -gamma  # keep the centroid's side
        cell = cell.intersection(_halfplane_polygon(alpha, beta, gamma, bbox))
        if cell.is_empty:
            break
    if not cell.is_valid:
        cell = cell.buffer(0)
    return _largest_polygon(cell)


def build_roof_model(
    planes: list[MergedPlane],
    points: npt.NDArray,
    refined_polygon: Any,
    utm_zone: int,
) -> RoofModel:
    """Build an outline-constrained roof model from merged fitted planes.

    Facet extent comes from partitioning each plane's point-support region by the
    plane-intersection seams it shares with adjacent planes (ridges/hips/valleys),
    not from a per-plane bounding rectangle claimed greedily. So adjacent facets
    meet exactly on their shared edge and split the contested area by which plane
    actually forms the roof there — fixing the "one facet over-extends, its
    neighbour is starved" failure of the old MBR + largest-claims-first approach.
    """
    outline = refined_outline_to_utm(refined_polygon, utm_zone)
    warnings: list[str] = []

    # 1. Per-plane support (point coverage) + quality gate. Confidence/density use
    #    the support area (actual coverage), independent of the final facet extent.
    candidates = []
    for plane_index, plane in enumerate(planes):
        inlier_pts = points[plane.inlier_indices]
        support = _support_polygon(inlier_pts)
        clipped, clip_warnings = _clip_support(support, outline)
        warnings.extend(clip_warnings)
        if clipped.is_empty or clipped.area < _MIN_MODEL_FACET_AREA_M2:
            warnings.append("facet_support_too_small")
            continue
        density = point_density(len(inlier_pts), clipped.area)
        confidence = facet_confidence(plane.inlier_ratio, density)
        if confidence < _MIN_FACET_CONFIDENCE:
            warnings.append("low_confidence_facet_dropped")
            continue
        candidates.append((plane_index, plane, inlier_pts, clipped, confidence, density))

    # 2. Cluster supports into shared roof features; partition each cluster's
    #    coverage among its planes by plane-intersection seams.
    supports = [c[3] for c in candidates]
    clusters = _support_clusters(supports, _PARTITION_NEIGHBOR_BUFFER_M)
    cell_for: dict[int, Polygon] = {}
    for cluster in clusters:
        coverage = unary_union([supports[i] for i in cluster])
        # Clustered supports can sit a hair apart (sampling gaps near the ridge),
        # leaving the union disconnected — which would strand the strip one facet
        # must hand to its neighbour. Close gaps up to the cluster buffer so the
        # coverage is a single connected region the seam can partition; the
        # dilate+erode preserves the outer extent (area stays accurate).
        if isinstance(coverage, MultiPolygon):
            closed = coverage.buffer(_PARTITION_NEIGHBOR_BUFFER_M).buffer(
                -_PARTITION_NEIGHBOR_BUFFER_M
            )
            if not closed.is_empty:
                coverage = closed
        bbox = coverage.bounds if not coverage.is_empty else outline.bounds
        for i in cluster:
            plane = candidates[i][1]
            others = [candidates[j][1] for j in cluster if j != i]
            cell = _partition_cell(plane, others, coverage, bbox)
            cell = cell.intersection(outline)
            if not cell.is_valid:
                cell = cell.buffer(0)
            cell_for[i] = _largest_polygon(cell)

    # 3. Emit facets from the partitioned cells.
    facets: list[RoofModelFacet] = []
    for i, (plane_index, plane, inlier_pts, support, confidence, density) in enumerate(candidates):
        cell = cell_for.get(i, Polygon())
        if cell.is_empty or cell.area < _MIN_MODEL_FACET_AREA_M2:
            warnings.append("facet_cell_too_small")
            continue
        if not cell.intersects(support):
            warnings.append("facet_cell_off_support")
            continue
        pitch_deg, pitch_ratio = _normal_to_pitch(plane.normal)
        nz = float(np.clip(abs(plane.normal[2]), 1e-6, 1.0))
        plan_area_m2 = float(cell.area)
        surface_area_m2 = plan_area_m2 / nz
        facets.append(
            RoofModelFacet(
                facet_id=f"F{len(facets) + 1}",
                plane_index=plane_index,
                plane=plane,
                polygon_utm=cell,
                plan_area_m2=plan_area_m2,
                surface_area_m2=surface_area_m2,
                pitch_degrees=pitch_deg,
                pitch_ratio=pitch_ratio,
                confidence=confidence,
                inlier_count=len(inlier_pts),
                point_density_per_m2=density,
                boundary_method="plane_intersection_partition_of_supports",
            )
        )

    edges = _build_edges(facets)
    assigned = unary_union([f.polygon_utm for f in facets]) if facets else Polygon()
    coverage_ratio = 0.0
    if outline.area > 0 and not assigned.is_empty:
        coverage_ratio = float(assigned.intersection(outline).area / outline.area)

    warnings = list(dict.fromkeys(warnings))
    diagnostics = {
        "model_version": "roof_model_v1",
        "plane_count": len(planes),
        "facet_count": len(facets),
        "edge_count": len(edges),
        "coverage_ratio": round(coverage_ratio, 4),
        "area_method": "outline_clipped_plan_area_div_cos_pitch",
        "boundary_method": "plane_intersection_partition_of_supports",
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
