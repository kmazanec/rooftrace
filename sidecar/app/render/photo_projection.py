"""Pinhole-camera projection math for the photo-overlay stage (ADR-019).

Projects 3D points / roof facets (in the ARKit session-local frame) onto a
captured photo's image plane via the standard pinhole model:

    p_cam = R @ p_world + t            (world_to_camera extrinsic, 4x4)
    u = fx * x_cam / z_cam + cx        (intrinsic K)
    v = fy * y_cam / z_cam + cy

Frame convention (OpenCV): the camera looks down +Z, x right, y down. A point
with ``z_cam <= 0`` is behind the image plane and is flagged ``in_front=False``
so a facet straddling the plane can be culled rather than projected to a wild
pixel.

This module is pure numpy — no storage, no mesh I/O, no FastAPI — so the frame
math is unit-tested in isolation (the highest-risk part of the feature: a wrong
inverse / axis order yields a plausible-but-misregistered overlay). Occlusion
(ray-cast against the world mesh) and the SVG composite live in sibling modules.
"""

from __future__ import annotations

import numpy as np
import numpy.typing as npt

# z_cam at or below this is treated as behind the image plane.
_MIN_DEPTH_M = 1e-6


def _as_4x4(flat: list[float] | npt.NDArray) -> npt.NDArray[np.float64]:
    arr = np.asarray(flat, dtype=np.float64)
    if arr.size != 16:
        raise ValueError(f"expected a 16-element row-major 4x4, got {arr.size}")
    return arr.reshape(4, 4)


def _as_3x3(flat: list[float] | npt.NDArray) -> npt.NDArray[np.float64]:
    arr = np.asarray(flat, dtype=np.float64)
    if arr.size != 9:
        raise ValueError(f"expected a 9-element row-major 3x3, got {arr.size}")
    return arr.reshape(3, 3)


def facets_wgs84_to_arkit(
    facets: list[dict],
    arkit_to_utm_4x4: list[float] | npt.NDArray,
    utm_epsg: int,
) -> list[dict]:
    """Bring WGS84 roof facets into the ARKit session-local frame.

    Each input facet carries ``vertices`` as GeoJSON [lon, lat] (optionally with
    a third elevation component, metres). The pipeline:

        WGS84 [lon, lat] --pyproj--> local UTM (easting, northing, elev)
                         --inverse(arkit_to_utm)--> ARKit-local [x, y, z]

    ``arkit_to_utm_4x4`` is the SOLVED fusion transform (ARKit frame -> local UTM,
    row-major 4x4); we invert it once and apply it to every vertex. The frame the
    camera + mesh natively live in is ARKit-local, so we transform the facets IN
    rather than transforming the (much larger) mesh / camera out — the ADR-019
    coordinate-frame decision.

    Returns facets with an added ``vertices_arkit`` ([[x,y,z], ...]); the original
    ``vertices`` is preserved. A vertex missing an elevation is placed on z=0 of
    the local UTM frame before the inverse transform (the roof's absolute height
    is carried by the transform's translation + the facet's own rise).
    """
    from pyproj import Transformer

    M = _as_4x4(arkit_to_utm_4x4)
    inv = np.linalg.inv(M)
    transformer = Transformer.from_crs("EPSG:4326", f"EPSG:{int(utm_epsg)}", always_xy=True)

    out: list[dict] = []
    for facet in facets:
        verts_arkit: list[list[float]] = []
        for v in facet.get("vertices", []):
            if not isinstance(v, (list, tuple)) or len(v) < 2:
                continue
            lon, lat = float(v[0]), float(v[1])
            elev = float(v[2]) if len(v) >= 3 else 0.0
            easting, northing = transformer.transform(lon, lat)
            utm_h = np.array([easting, northing, elev, 1.0])
            arkit = inv @ utm_h
            verts_arkit.append([float(arkit[0]), float(arkit[1]), float(arkit[2])])
        out.append({**facet, "vertices_arkit": verts_arkit})
    return out


def project_points(
    points: npt.NDArray,
    intrinsics_3x3: list[float] | npt.NDArray,
    world_to_camera_4x4: list[float] | npt.NDArray,
) -> tuple[npt.NDArray[np.float64], npt.NDArray[np.bool_]]:
    """Project (N, 3) world points to (N, 2) pixel coords.

    Returns ``(uv, in_front)`` where ``uv[i]`` is ``(u, v)`` in pixels and
    ``in_front[i]`` is False when the point is on/behind the image plane
    (``z_cam <= 0``). A behind-camera point's uv is still returned (computed with
    a clamped depth) but callers should treat it as invalid via ``in_front``.
    """
    pts = np.asarray(points, dtype=np.float64).reshape(-1, 3)
    K = _as_3x3(intrinsics_3x3)
    M = _as_4x4(world_to_camera_4x4)

    # Homogeneous world -> camera.
    homo = np.column_stack([pts, np.ones(len(pts))])
    cam = (homo @ M.T)[:, :3]

    z = cam[:, 2]
    in_front = z > _MIN_DEPTH_M
    # Clamp depth so a behind/at-plane point doesn't divide by ~0 and blow up;
    # the in_front flag is the authority on validity.
    safe_z = np.where(np.abs(z) < _MIN_DEPTH_M, _MIN_DEPTH_M, z)

    fx, fy = K[0, 0], K[1, 1]
    cx, cy = K[0, 2], K[1, 2]
    skew = K[0, 1]

    u = fx * cam[:, 0] / safe_z + skew * cam[:, 1] / safe_z + cx
    v = fy * cam[:, 1] / safe_z + cy
    return np.column_stack([u, v]), in_front


def project_facets(
    facets: list[dict],
    intrinsics_3x3: list[float] | npt.NDArray,
    world_to_camera_4x4: list[float] | npt.NDArray,
) -> list[dict]:
    """Project a list of facets (each with ``vertices_arkit``: list of [x,y,z]).

    Returns one dict per facet:
      - ``facet_id``: passed through.
      - ``points_px``: [[u, v], ...] projected pixel coords (one per vertex).
      - ``in_front``: True iff EVERY vertex is in front of the image plane (a
        facet with any vertex behind the plane is flagged so the caller can cull
        or clip it rather than draw a wild polygon).
    """
    out: list[dict] = []
    for facet in facets:
        verts = np.asarray(facet["vertices_arkit"], dtype=np.float64).reshape(-1, 3)
        uv, in_front = project_points(verts, intrinsics_3x3, world_to_camera_4x4)
        out.append(
            {
                "facet_id": facet.get("facet_id"),
                "points_px": uv.tolist(),
                "in_front": bool(in_front.all()),
            }
        )
    return out
