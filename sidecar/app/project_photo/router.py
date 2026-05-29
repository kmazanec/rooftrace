"""photo-projection stage — POST /pipeline/project-photo.

Projects the measured facets (and detected features) onto a captured photo via
pinhole projection with z-buffer occlusion, producing an overlay the report and
viewer surface as an on-site visualization. The solved fusion transform
(``arkit_to_utm`` + ``utm_epsg``) is carried forward from the capture-fusion
stage and reused when present; when absent, the projector recomputes it from
``world_mesh_ref`` as a fallback.

Rendered artifacts are written under the ``artifacts/<job_id>/projected/``
prefix (disjoint from the ``artifacts/<job_id>/evidence/`` prefix the evidence
stage owns, so the two never collide).

Auth: shared-secret bearer injected by main.py (Depends(require_bearer)).

NOTE: this module lands the endpoint CONTRACT (request/response shape, version
check, storage-key convention, pose-confidence + occlusion fields). The real
pinhole projection + z-buffer occlusion math is supplied by the AR-overlay
workstream; the contract-level renderer here emits a deterministic placeholder
so the shape and storage convention are exercised end-to-end.
"""

from __future__ import annotations

import logging

from fastapi import APIRouter, HTTPException, status

from app.storage import put_bytes

from contracts.pipeline import (
    PIPELINE_SCHEMA_VERSION,
    ProjectPhotoRequest,
    ProjectPhotoResponse,
)

router = APIRouter(prefix="/pipeline", tags=["project-photo"])
logger = logging.getLogger(__name__)

# 1x1 transparent PNG — a deterministic placeholder for the contract skeleton.
_PLACEHOLDER_PNG = (
    b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01"
    b"\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\nIDATx\x9cc\x00\x01"
    b"\x00\x00\x05\x00\x01\r\n-\xb4\x00\x00\x00\x00IEND\xaeB`\x82"
)
_PLACEHOLDER_SVG = b'<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>'


def _major(version: str) -> str:
    return version.split(".", 1)[0]


def _seq_token(photo_ref: str) -> str:
    """A stable per-photo token for the projected artifact keys, derived from the
    source photo's basename (without extension)."""
    base = photo_ref.rsplit("/", 1)[-1]
    return base.rsplit(".", 1)[0] or "0"


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

    # Either a solved fusion transform OR a mesh to recompute it from is needed to
    # place the facets; reject deterministically when neither is supplied.
    if req.arkit_to_utm is None and req.world_mesh_ref is None:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="one of arkit_to_utm or world_mesh_ref is required to project the photo",
        )

    seq = _seq_token(req.photo_ref)
    try:
        composite_ref = put_bytes(
            f"artifacts/{req.job_id}/projected/{seq}.png", _PLACEHOLDER_PNG
        )
        overlay_svg_ref = put_bytes(
            f"artifacts/{req.job_id}/projected/{seq}.svg", _PLACEHOLDER_SVG
        )
    except Exception as exc:  # noqa: BLE001
        logger.exception("project-photo failed: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"photo projection failed: {type(exc).__name__}",
        ) from exc

    return ProjectPhotoResponse(
        pipelineSchemaVersion=PIPELINE_SCHEMA_VERSION,
        job_id=req.job_id,
        overlay_ref=composite_ref,
        composite_ref=composite_ref,
        overlay_svg_ref=overlay_svg_ref,
        pose_confidence=req.pose_confidence,
        occluded_facet_ids=[],
    )
