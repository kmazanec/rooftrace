"""photo-projection stage — POST /pipeline/project-photo (ADR-019).

Projects the measured facets onto a captured iOS photo via pinhole projection
with trimesh ray-cast z-buffer occlusion, then composites an SVG facet overlay
onto the source RGB. The solved fusion transform (``arkit_to_utm`` + ``utm_epsg``)
places the WGS84 facets into the photo's native ARKit-local frame; the world mesh
(``world_mesh_ref``, faces-aware) drives occlusion when supplied.

Rendered artifacts are written under the ``artifacts/<job_id>/projected/`` prefix
(disjoint from the ``artifacts/<job_id>/evidence/`` prefix the evidence stage
owns, so the two never collide): ``<seq>.png`` (composite) + ``<seq>.svg``
(overlay layer / primary visual-regression artifact).

Auth: shared-secret bearer injected by main.py (Depends(require_bearer)).

Coordinate-frame note (ADR-019): facets are brought INTO the ARKit-local frame
(WGS84 -> local UTM -> inverse(arkit_to_utm)) rather than transforming the camera
+ mesh out, because both are native to ARKit-local. ``arkit_to_utm`` + ``utm_epsg``
are therefore REQUIRED to place facets; the contract carries no LiDAR ref, so the
"recompute from mesh" fallback cannot re-run ICP here — a request lacking the
solved transform is rejected (Rails persists the transform at fusion time, so a
converged job always has it).
"""

from __future__ import annotations

import logging
import os

import numpy as np
from fastapi import APIRouter, HTTPException, status

from app.storage import StorageError, get_bytes, put_bytes

from contracts.pipeline import (
    PIPELINE_SCHEMA_VERSION,
    ProjectPhotoRequest,
    ProjectPhotoResponse,
)

router = APIRouter(prefix="/pipeline", tags=["project-photo"])
logger = logging.getLogger(__name__)

# Per-blob size guard (mirrors fuse_capture): a bearer holder could otherwise
# point a ref at a multi-GB object and exhaust memory.
_MAX_BLOB_BYTES = 256 * 1024 * 1024  # 256 MiB

# 1x1 transparent PNG — the deterministic placeholder used when the live render
# path is disabled (PROJECT_PHOTO_LIVE != "1"), so hermetic tests and the
# contract round-trip exercise the storage + shape without Pillow/trimesh work.
_PLACEHOLDER_PNG = (
    b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01"
    b"\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\nIDATx\x9cc\x00\x01"
    b"\x00\x00\x05\x00\x01\r\n-\xb4\x00\x00\x00\x00IEND\xaeB`\x82"
)
_PLACEHOLDER_SVG = '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>'


def _major(version: str) -> str:
    return version.split(".", 1)[0]


def _live_enabled() -> bool:
    return os.environ.get("PROJECT_PHOTO_LIVE", "") == "1"


def _seq_token(photo_ref: str) -> str:
    """A stable per-photo token for the projected artifact keys, derived from the
    source photo's basename (without extension)."""
    base = photo_ref.rsplit("/", 1)[-1]
    return base.rsplit(".", 1)[0] or "0"


def _load_blob(ref: str, what: str) -> bytes:
    try:
        raw = get_bytes(ref)
    except StorageError as exc:
        logger.warning("%s ref not found: %s", what, ref)
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"{what} could not be read",
        ) from exc
    if len(raw) > _MAX_BLOB_BYTES:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail=f"{what} exceeds the maximum allowed size",
        )
    return raw


@router.post(
    "/project-photo",
    response_model=ProjectPhotoResponse,
    response_model_exclude_none=True,
)
def project_photo_endpoint(req: ProjectPhotoRequest) -> ProjectPhotoResponse:
    if _major(req.pipelineSchemaVersion) != _major(PIPELINE_SCHEMA_VERSION):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                f"pipeline schema major mismatch: request {req.pipelineSchemaVersion} "
                f"vs sidecar {PIPELINE_SCHEMA_VERSION}"
            ),
        )

    # Placing WGS84 facets into the photo's ARKit-local frame REQUIRES the solved
    # arkit_to_utm + its EPSG. The contract carries no LiDAR ref, so there is no
    # in-stage ICP recompute; reject deterministically when the transform is
    # absent (Rails persists it at fusion time, so a converged job always has it).
    if req.arkit_to_utm is None or req.utm_epsg is None:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="arkit_to_utm and utm_epsg are required to place facets in the photo frame",
        )

    seq = _seq_token(req.photo_ref)
    png_key = f"artifacts/{req.job_id}/projected/{seq}.png"
    svg_key = f"artifacts/{req.job_id}/projected/{seq}.svg"

    if not _live_enabled():
        # Hermetic default: exercise the storage + response shape without the
        # Pillow/trimesh render. The pose_confidence is passed through unchanged
        # (the sidecar may only NARROW it; Rails is the authority).
        composite_ref = put_bytes(png_key, _PLACEHOLDER_PNG)
        overlay_svg_ref = put_bytes(svg_key, _PLACEHOLDER_SVG.encode())
        return ProjectPhotoResponse(
            pipelineSchemaVersion=PIPELINE_SCHEMA_VERSION,
            job_id=req.job_id,
            overlay_ref=composite_ref,
            composite_ref=composite_ref,
            overlay_svg_ref=overlay_svg_ref,
            pose_confidence=req.pose_confidence,
            occluded_facet_ids=[],
        )

    composite_ref, overlay_svg_ref, occluded_ids = _render_live(req, png_key, svg_key)
    return ProjectPhotoResponse(
        pipelineSchemaVersion=PIPELINE_SCHEMA_VERSION,
        job_id=req.job_id,
        overlay_ref=composite_ref,
        composite_ref=composite_ref,
        overlay_svg_ref=overlay_svg_ref,
        pose_confidence=req.pose_confidence,
        occluded_facet_ids=occluded_ids,
    )


def _render_live(
    req: ProjectPhotoRequest, png_key: str, svg_key: str
) -> tuple[str, str, list[str]]:
    """The real render: bridge facets into ARKit-local, project, occlude, compose."""
    from PIL import Image
    import io as _io

    from app.render.photo_occlusion import classify_facet_occlusion, load_world_mesh
    from app.render.photo_overlay import build_overlay_svg, composite_png
    from app.render.photo_projection import facets_wgs84_to_arkit, project_facets

    photo_bytes = _load_blob(req.photo_ref, "photo")
    try:
        with Image.open(_io.BytesIO(photo_bytes)) as img:
            width_px, height_px = img.size
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"photo is not a readable image: {type(exc).__name__}",
        ) from exc

    # Optional world mesh (faces-aware) for occlusion. Absent -> no occlusion.
    mesh_verts = np.empty((0, 3))
    mesh_faces = np.empty((0, 3), dtype=np.int64)
    if req.world_mesh_ref:
        try:
            mesh_verts, mesh_faces = load_world_mesh(_load_blob(req.world_mesh_ref, "world mesh"))
        except HTTPException:
            raise
        except Exception as exc:  # noqa: BLE001
            logger.warning("world mesh unreadable, projecting without occlusion: %s", type(exc).__name__)

    facet_dicts = [f.model_dump() for f in req.facets]
    bridged = facets_wgs84_to_arkit(facet_dicts, req.arkit_to_utm, req.utm_epsg)
    projected = project_facets(
        bridged, req.camera_pose.intrinsics, req.camera_pose.extrinsics
    )

    # Camera origin in ARKit-local = -R^T t from the world_to_camera extrinsic.
    M = np.asarray(req.camera_pose.extrinsics, dtype=np.float64).reshape(4, 4)
    cam_origin = -M[:3, :3].T @ M[:3, 3]

    occluded_ids: list[str] = []
    for proj, bridged_facet in zip(projected, bridged):
        samples = np.asarray(bridged_facet["vertices_arkit"], dtype=np.float64)
        if samples.size and mesh_faces.size:
            state, _ = classify_facet_occlusion(cam_origin, samples, mesh_verts, mesh_faces)
        else:
            state = "visible"
        proj["occlusion_state"] = state
        proj["pitch_ratio"] = bridged_facet.get("pitch_ratio")
        proj["area_sq_ft"] = bridged_facet.get("area_sq_ft")
        if state == "occluded" or proj["in_front"] is False:
            occluded_ids.append(proj["facet_id"])

    overlay_svg = build_overlay_svg(projected, width_px=width_px, height_px=height_px)
    composite = composite_png(photo_bytes, overlay_svg, width_px=width_px, height_px=height_px)

    try:
        composite_ref = put_bytes(png_key, composite)
        overlay_svg_ref = put_bytes(svg_key, overlay_svg.encode())
    except Exception as exc:  # noqa: BLE001
        logger.exception("project-photo upload failed: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"photo projection failed: {type(exc).__name__}",
        ) from exc

    return composite_ref, overlay_svg_ref, occluded_ids
