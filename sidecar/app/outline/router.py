"""F-07 Roof outline refinement (SAM2).

POST /pipeline/refine-outline:
  - Fetches the image tile via `get_bytes(image_tile_ref)`.
  - Converts the prior_polygon (WGS84) -> pixel mask using image_geo_bounds.
  - Runs SAM2 (or the deterministic local stub) via `infer_sam2()`.
  - Simplifies the resulting mask boundary via Douglas–Peucker (shapely).
  - Checks IoU(refined vs prior): if < 0.5, falls back to the prior with a
    "sam2_low_confidence" warning.
  - Returns RefineOutlineResponse (WGS84 polygon, iou_with_prior, sam2_backend,
    warnings).

Backend selection: SAM2_BACKEND env var ("local" default | "modal").
DP tolerance:      SAM2_DP_TOLERANCE env var (default 1e-5 degrees).
"""

from __future__ import annotations

import io
import logging
import os

import numpy as np
from fastapi import APIRouter, HTTPException, status
from shapely.geometry import Polygon as ShapelyPolygon

from app.storage import StorageError, get_bytes
from contracts.pipeline import (
    PIPELINE_SCHEMA_VERSION,
    GeometrySource,
    Polygon,
    RefineOutlineRequest,
    RefineOutlineResponse,
    SAM2Backend,
)

from .segmenter import ModalUnavailable, _stub_segmenter, infer_sam2

router = APIRouter(prefix="/pipeline", tags=["outline"])

logger = logging.getLogger(__name__)

# IoU threshold below which the refined mask is considered a catastrophic leak
# and we fall back to the prior.
_LOW_CONFIDENCE_THRESHOLD = 0.5

# Douglas–Peucker tolerance in degrees (lon/lat). Tune via env for different
# tile resolutions. 1e-5 degrees ≈ 1 m at mid-latitudes.
_DP_TOLERANCE = float(os.environ.get("SAM2_DP_TOLERANCE", "1e-5"))


# ---------------------------------------------------------------------------
# Coordinate conversion helpers
# ---------------------------------------------------------------------------


def _geo_bounds_to_image_size(image_bytes: bytes) -> tuple[int, int]:
    """Return (width, height) of a PNG/JPEG image without full decode."""
    from PIL import Image

    with Image.open(io.BytesIO(image_bytes)) as img:
        return img.width, img.height


def _polygon_to_mask(
    polygon: Polygon,
    img_width: int,
    img_height: int,
    geo_bounds: list[float],
) -> "np.ndarray":
    """Rasterise a WGS84 Polygon into a boolean H×W pixel mask.

    geo_bounds = [west, south, east, north] in degrees.
    Pixel (0,0) is top-left; row 0 is north, col 0 is west.
    """
    west, south, east, north = geo_bounds
    lon_range = east - west
    lat_range = north - south

    def _lonlat_to_px(lon: float, lat: float) -> tuple[float, float]:
        px = (lon - west) / lon_range * img_width
        py = (north - lat) / lat_range * img_height
        return px, py

    # Rasterise the polygon in pixel space with Pillow's C polygon fill — O(area)
    # in compiled code — rather than a per-pixel Python/Shapely contains() scan
    # (which was O(H*W) Shapely allocations per request).
    from PIL import Image, ImageDraw

    exterior = polygon.coordinates[0]  # [[lon, lat], ...]
    px_ring = [_lonlat_to_px(c[0], c[1]) for c in exterior]

    img = Image.new("1", (img_width, img_height), 0)
    drawer = ImageDraw.Draw(img)
    drawer.polygon(px_ring, fill=1)
    # Punch out interior rings (holes) by drawing them as 0.
    for ring in polygon.coordinates[1:]:
        hole_px = [_lonlat_to_px(c[0], c[1]) for c in ring]
        drawer.polygon(hole_px, fill=0)

    return np.array(img, dtype=bool)


def _mask_to_polygon(
    mask: "np.ndarray",
    img_width: int,
    img_height: int,
    geo_bounds: list[float],
    dp_tolerance: float,
) -> Polygon:
    """Convert a boolean H×W mask -> simplified WGS84 Polygon.

    Uses shapely to find the exterior contour, then Douglas–Peucker simplification.
    Raises ValueError if the mask is empty or produces no valid polygon.
    """
    west, south, east, north = geo_bounds
    lon_range = east - west
    lat_range = north - south

    def _px_to_lonlat(px: float, py: float) -> list[float]:
        lon = west + px / img_width * lon_range
        lat = north - py / img_height * lat_range
        return [lon, lat]

    if not mask.any():
        raise ValueError("empty mask — cannot convert to polygon")

    # Build shapely polygon via row run-length encoding: each row of True pixels
    # becomes one or more horizontal strip rectangles, then union.  This produces
    # an exact pixel-boundary polygon in O(H*W) without subsampling.
    from shapely.ops import unary_union

    strips = []
    for row_idx, row in enumerate(mask):
        if not row.any():
            continue
        changes = np.diff(row.astype(np.int8), prepend=0, append=0)
        starts = np.where(changes == 1)[0]
        ends = np.where(changes == -1)[0]
        for s, e in zip(starts, ends):
            strips.append(ShapelyPolygon([
                (s, row_idx), (e, row_idx), (e, row_idx + 1), (s, row_idx + 1),
            ]))

    if not strips:
        raise ValueError("no pixels in mask")

    merged = unary_union(strips)
    if merged.is_empty:
        raise ValueError("merged polygon is empty")

    # Take the largest polygon if multipolygon (keep biggest by area)
    if merged.geom_type == "MultiPolygon":
        merged = max(merged.geoms, key=lambda g: g.area)

    # Simplify in pixel space. dp_tolerance is in degrees; convert to pixels.
    # pixels_per_degree ≈ img_width / lon_range.  1 pixel tolerance minimum.
    pixels_per_degree = img_width / lon_range if lon_range > 0 else img_width
    px_tolerance = max(1.0, dp_tolerance * pixels_per_degree)
    simplified = merged.simplify(px_tolerance, preserve_topology=True)
    if simplified.is_empty or simplified.geom_type not in ("Polygon", "MultiPolygon"):
        simplified = merged

    if simplified.geom_type == "MultiPolygon":
        simplified = max(simplified.geoms, key=lambda g: g.area)

    # Convert exterior ring to lon/lat
    exterior_coords = []
    for px, py in simplified.exterior.coords:
        exterior_coords.append(_px_to_lonlat(px, py))

    # Ensure closed ring
    if exterior_coords[0] != exterior_coords[-1]:
        exterior_coords.append(exterior_coords[0])

    return Polygon(
        type="Polygon",
        coordinates=[exterior_coords],
        source=GeometrySource.IMAGERY,
        confidence=0.9,
    )


def _compute_iou(mask_a: "np.ndarray", mask_b: "np.ndarray") -> float:
    """Compute intersection-over-union of two boolean masks."""
    intersection = np.logical_and(mask_a, mask_b).sum()
    union = np.logical_or(mask_a, mask_b).sum()
    if union == 0:
        return 1.0  # both empty — trivially identical
    return float(intersection) / float(union)


# ---------------------------------------------------------------------------
# Endpoint
# ---------------------------------------------------------------------------


@router.post("/refine-outline", response_model=RefineOutlineResponse, response_model_exclude_none=True)
def refine_outline(req: RefineOutlineRequest) -> RefineOutlineResponse:
    """Refine a building footprint prior into a pixel-accurate roof outline (F-07).

    Uses SAM2 zero-shot segmentation on the NAIP/satellite tile, then simplifies
    via Douglas–Peucker. Falls back to the prior if SAM2 produces a catastrophic
    result (IoU < 0.5 vs prior).
    """
    # 1. Version check
    req_major = req.pipelineSchemaVersion.split(".", 1)[0]
    our_major = PIPELINE_SCHEMA_VERSION.split(".", 1)[0]
    if req_major != our_major:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                f"pipeline schema major mismatch: request {req.pipelineSchemaVersion} "
                f"vs sidecar {PIPELINE_SCHEMA_VERSION}"
            ),
        )

    # 2. Fetch image tile
    try:
        image_bytes = get_bytes(req.image_tile_ref)
    except StorageError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"could not fetch image tile: {exc}",
        ) from exc

    # 3. Determine image dimensions
    try:
        img_width, img_height = _geo_bounds_to_image_size(image_bytes)
    except Exception as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"could not read image tile dimensions: {exc}",
        ) from exc

    geo_bounds = list(req.image_geo_bounds)  # [west, south, east, north]
    west, south, east, north = geo_bounds
    if east - west == 0 or north - south == 0:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="image_geo_bounds is degenerate (zero width or height)",
        )

    warnings: list[str] = []

    # 4. Rasterise prior polygon to pixel mask
    try:
        prior_mask = _polygon_to_mask(req.prior_polygon, img_width, img_height, geo_bounds)
    except Exception as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"could not rasterise prior polygon: {exc}",
        ) from exc

    # 5. Run SAM2 inference (or local stub). infer_sam2 reports the backend it
    # ACTUALLY used; if modal was requested but unavailable, fall back to the
    # local stub (the spec's "demo doesn't die during a Modal outage") and report
    # the honest backend + a warning rather than mislabelling stub geometry.
    try:
        refined_mask, used_backend = infer_sam2(image_bytes, prior_mask)
    except ModalUnavailable as exc:
        logger.warning("SAM2 modal requested but unavailable, using local stub: %s", exc)
        warnings.append("sam2_modal_unavailable")
        refined_mask, used_backend = _stub_segmenter(image_bytes, prior_mask), "local"
    except Exception as exc:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"SAM2 inference failed: {exc}",
        ) from exc

    backend = SAM2Backend.MODAL if used_backend == "modal" else SAM2Backend.LOCAL

    # 6. Compute IoU(refined, prior)
    iou = _compute_iou(refined_mask, prior_mask)

    # 7. Fallback to prior if catastrophic leak (IoU < 0.5)
    if iou < _LOW_CONFIDENCE_THRESHOLD or not refined_mask.any():
        warnings.append("sam2_low_confidence")
        # Return prior polygon unchanged
        return RefineOutlineResponse(
            pipelineSchemaVersion=PIPELINE_SCHEMA_VERSION,
            refined_polygon=req.prior_polygon,
            iou_with_prior=iou,
            sam2_backend=backend,
            warnings=warnings,
        )

    # 8. Convert refined mask -> simplified WGS84 polygon (Douglas–Peucker)
    try:
        refined_polygon = _mask_to_polygon(
            refined_mask,
            img_width,
            img_height,
            geo_bounds,
            _DP_TOLERANCE,
        )
    except Exception:
        # Conversion failed — fall back to prior
        warnings.append("sam2_low_confidence")
        return RefineOutlineResponse(
            pipelineSchemaVersion=PIPELINE_SCHEMA_VERSION,
            refined_polygon=req.prior_polygon,
            iou_with_prior=iou,
            sam2_backend=backend,
            warnings=warnings,
        )

    # 9. Re-check IoU with the vectorised polygon mask for reporting
    # (The iou already computed from pixel masks is the canonical value)

    return RefineOutlineResponse(
        pipelineSchemaVersion=PIPELINE_SCHEMA_VERSION,
        refined_polygon=refined_polygon,
        iou_with_prior=iou,
        sam2_backend=backend,
        warnings=warnings,
    )
