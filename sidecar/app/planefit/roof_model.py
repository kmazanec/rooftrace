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
from shapely.geometry import GeometryCollection, MultiPoint, MultiPolygon, Point, Polygon, box
from shapely.ops import nearest_points, unary_union

from .plane_fit import facet_confidence, point_density
from .topology import MergedPlane

_SQM_TO_SQFT = 10.7639
_PITCH_STEP = 0.5
_MIN_FACET_CONFIDENCE = 0.5
_MIN_MODEL_FACET_AREA_M2 = 12.0
_ADJACENCY_TOLERANCE_M = 0.08
# Two planes' supports this close (metres) are treated as a shared roof feature
# (ridge/hip/valley) and partitioned against each other; farther apart they are
# independent roof sections that never reassign each other's area.
_PARTITION_NEIGHBOR_BUFFER_M = 0.5
_SUPPORT_POINT_BUFFER_M = 0.6
_SUPPORT_BRIDGE_RATIO = 0.35
_PARALLEL_PARTITION_ANGLE_DEG = 3.0
_SEAM_ELEVATION_TOLERANCE_M = 0.25
_MAX_PARTITION_ANCHOR_ELEVATION_GAP_M = 1.0
_POINT_ELEVATION_OVERLAP_TOLERANCE_M = 0.05


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


@dataclass
class _CandidateFacet:
    plane_index: int
    plane: MergedPlane
    inlier_pts: npt.NDArray
    support: Polygon
    confidence: float
    density: float
    anchor_xy: tuple[float, float]


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


def _support_polygons(inlier_pts: npt.NDArray) -> list[Polygon]:
    """Return connected plan-view support polygons for a plane's inlier points."""
    if len(inlier_pts) < 3:
        return []
    points_2d = inlier_pts[:, :2]
    point_buffers = [
        Point(float(x), float(y)).buffer(_SUPPORT_POINT_BUFFER_M)
        for x, y in points_2d
    ]
    support = unary_union(point_buffers).buffer(-_SUPPORT_POINT_BUFFER_M * _SUPPORT_BRIDGE_RATIO)
    if not support.is_valid:
        support = support.buffer(0)

    polygons: list[Polygon] = []
    if isinstance(support, Polygon):
        polygons = [support]
    elif isinstance(support, MultiPolygon):
        polygons = list(support.geoms)
    elif isinstance(support, GeometryCollection):
        polygons = [g for g in support.geoms if isinstance(g, Polygon)]

    supports: list[Polygon] = []
    for region in polygons:
        component_pts = points_2d[
            np.array(
                [region.covers(Point(float(p[0]), float(p[1]))) for p in points_2d],
                dtype=bool,
            )
        ]
        if len(component_pts) < 3:
            continue
        hull = MultiPoint(component_pts.tolist()).convex_hull
        if isinstance(hull, Polygon) and not hull.is_empty:
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", RuntimeWarning)
                support = hull.minimum_rotated_rectangle
            if support.area > 0:
                supports.append(support)
    if supports:
        return supports

    hull = MultiPoint(points_2d.tolist()).convex_hull
    if isinstance(hull, Polygon) and not hull.is_empty:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", RuntimeWarning)
            return [hull.minimum_rotated_rectangle]
    return []


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


def _partition_coverage(supports: list[Polygon]) -> Polygon | MultiPolygon:
    coverage = unary_union(supports)
    if isinstance(coverage, MultiPolygon):
        closed = coverage.buffer(_PARTITION_NEIGHBOR_BUFFER_M).buffer(-_PARTITION_NEIGHBOR_BUFFER_M)
        if not closed.is_empty:
            coverage = closed
    return coverage


def _seam_crosses_coverage(
    a: _CandidateFacet,
    b: _CandidateFacet,
    coverage: Polygon | MultiPolygon,
    tolerance_m: float,
) -> bool:
    ai, bi, ci = _plane_z_coeffs(a.plane)
    aj, bj, cj = _plane_z_coeffs(b.plane)
    alpha, beta, gamma = ai - aj, bi - bj, ci - cj

    geometries = [coverage] if isinstance(coverage, Polygon) else list(coverage.geoms)
    values: list[float] = []
    for geom in geometries:
        if not isinstance(geom, Polygon) or geom.is_empty:
            continue
        for x, y in geom.exterior.coords:
            values.append(alpha * x + beta * y + gamma)
        values.append(alpha * geom.centroid.x + beta * geom.centroid.y + gamma)

    return bool(values) and min(values) <= tolerance_m and max(values) >= -tolerance_m


def _anchor_elevation(plane: MergedPlane, anchor_xy: tuple[float, float]) -> float | None:
    ai, bi, ci = _plane_z_coeffs(plane)
    x, y = anchor_xy
    return ai * x + bi * y + ci


def _nearest_support_elevation_gap(a: _CandidateFacet, b: _CandidateFacet) -> float | None:
    if a.support.is_empty or b.support.is_empty:
        return None
    pa, pb = nearest_points(a.support, b.support)
    za = _anchor_elevation(a.plane, (float(pa.x), float(pa.y)))
    zb = _anchor_elevation(b.plane, (float(pb.x), float(pb.y)))
    if za is None or zb is None:
        return None
    return abs(za - zb)


def _point_elevation_ranges_overlap(
    a: _CandidateFacet,
    b: _CandidateFacet,
    tolerance_m: float,
) -> bool:
    a_min, a_max = float(np.min(a.inlier_pts[:, 2])), float(np.max(a.inlier_pts[:, 2]))
    b_min, b_max = float(np.min(b.inlier_pts[:, 2])), float(np.max(b.inlier_pts[:, 2]))
    return max(a_min, b_min) <= min(a_max, b_max) + tolerance_m


def _should_partition_against(a: _CandidateFacet, b: _CandidateFacet, buffer_m: float) -> bool:
    if a.plane_index == b.plane_index:
        return False
    if a.support.distance(b.support) > buffer_m:
        return False
    cos_angle = float(np.clip(abs(np.dot(a.plane.normal, b.plane.normal)), 0.0, 1.0))
    angle_deg = math.degrees(math.acos(cos_angle))
    if angle_deg < _PARALLEL_PARTITION_ANGLE_DEG:
        return False
    nearest_gap = _nearest_support_elevation_gap(a, b)
    if (
        nearest_gap is not None
        and nearest_gap > _MAX_PARTITION_ANCHOR_ELEVATION_GAP_M
        and not _point_elevation_ranges_overlap(a, b, _POINT_ELEVATION_OVERLAP_TOLERANCE_M)
    ):
        return False
    coverage = _partition_coverage([a.support, b.support])
    return _seam_crosses_coverage(a, b, coverage, _SEAM_ELEVATION_TOLERANCE_M)


def _partition_cell(
    plane: MergedPlane,
    others: list[MergedPlane],
    coverage: Polygon | MultiPolygon,
    bbox: tuple,
    anchor_xy: tuple[float, float] | None = None,
) -> Polygon:
    """The part of ``coverage`` this plane owns: where its surface is the roof,
    among the planes it shares the feature with. The boundary against each other
    plane is their intersection line z_i == z_j (the ridge/hip/valley); this plane
    keeps the side its OWN points sit on — so the sign auto-adapts to ridges
    (peak) vs valleys, and an over-extended neighbour is cut back to the seam
    while a starved one grows out to it."""
    cell: Polygon | MultiPolygon = coverage
    ai, bi, ci = _plane_z_coeffs(plane)
    cx, cy = anchor_xy if anchor_xy is not None else (float(plane.centroid[0]), float(plane.centroid[1]))
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
    candidates: list[_CandidateFacet] = []
    for plane_index, plane in enumerate(planes):
        inlier_pts = points[plane.inlier_indices]
        supports = _support_polygons(inlier_pts)
        if not supports:
            warnings.append("facet_support_too_small")
            continue
        for support in supports:
            clipped, clip_warnings = _clip_support(support, outline)
            warnings.extend(clip_warnings)
            if clipped.is_empty or clipped.area < _MIN_MODEL_FACET_AREA_M2:
                warnings.append("facet_support_too_small")
                continue
            component_mask = np.array(
                [clipped.covers(Point(float(p[0]), float(p[1]))) for p in inlier_pts],
                dtype=bool,
            )
            component_pts = inlier_pts[component_mask]
            if len(component_pts) < 3:
                warnings.append("facet_support_too_small")
                continue
            density = point_density(len(component_pts), clipped.area)
            confidence = facet_confidence(plane.inlier_ratio, density)
            if confidence < _MIN_FACET_CONFIDENCE:
                warnings.append("low_confidence_facet_dropped")
                continue
            centroid = component_pts[:, :2].mean(axis=0)
            candidates.append(
                _CandidateFacet(
                    plane_index=plane_index,
                    plane=plane,
                    inlier_pts=component_pts,
                    support=clipped,
                    confidence=confidence,
                    density=density,
                    anchor_xy=(float(centroid[0]), float(centroid[1])),
                )
            )

    # 2. Cluster supports into shared roof features; partition each cluster's
    #    coverage among its planes by plane-intersection seams.
    supports = [c.support for c in candidates]
    clusters = _support_clusters(supports, _PARTITION_NEIGHBOR_BUFFER_M)
    cell_for: dict[int, Polygon] = {}
    for cluster in clusters:
        for i in cluster:
            candidate = candidates[i]
            neighbor_indexes = [
                j
                for j in cluster
                if i != j
                and _should_partition_against(
                    candidate, candidates[j], _PARTITION_NEIGHBOR_BUFFER_M
                )
            ]
            coverage = _partition_coverage(
                [candidate.support] + [candidates[j].support for j in neighbor_indexes]
            )
            bbox = coverage.bounds if not coverage.is_empty else outline.bounds
            others = [candidates[j].plane for j in neighbor_indexes]
            cell = _partition_cell(candidate.plane, others, coverage, bbox, candidate.anchor_xy)
            cell = cell.intersection(outline)
            if not cell.is_valid:
                cell = cell.buffer(0)
            cell_for[i] = _largest_polygon(cell)

    # 3. Emit facets from the partitioned cells.
    facets: list[RoofModelFacet] = []
    for i, candidate in enumerate(candidates):
        cell = cell_for.get(i, Polygon())
        if cell.is_empty or cell.area < _MIN_MODEL_FACET_AREA_M2:
            warnings.append("facet_cell_too_small")
            continue
        if not cell.intersects(candidate.support):
            warnings.append("facet_cell_off_support")
            continue
        pitch_deg, pitch_ratio = _normal_to_pitch(candidate.plane.normal)
        nz = float(np.clip(abs(candidate.plane.normal[2]), 1e-6, 1.0))
        plan_area_m2 = float(cell.area)
        surface_area_m2 = plan_area_m2 / nz
        facets.append(
            RoofModelFacet(
                facet_id=f"F{len(facets) + 1}",
                plane_index=candidate.plane_index,
                plane=candidate.plane,
                polygon_utm=cell,
                plan_area_m2=plan_area_m2,
                surface_area_m2=surface_area_m2,
                pitch_degrees=pitch_deg,
                pitch_ratio=pitch_ratio,
                confidence=candidate.confidence,
                inlier_count=len(candidate.inlier_pts),
                point_density_per_m2=candidate.density,
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
