"""evidence-thumbnails stage — POST /pipeline/render-evidence-thumbnails.

Renders normalized thumbnails of a job's capture photos for the report's on-site
evidence section. Source photos are referenced by Spaces ``uploads/`` key; the
rendered thumbnails are written under the ``artifacts/<job_id>/evidence/``
prefix (disjoint from the ``artifacts/<job_id>/projected/`` prefix the photo
projection stage owns, so the two never collide). Thumbnails are emitted in
``sequence_index`` order.

Auth: shared-secret bearer injected by main.py (Depends(require_bearer)).

NOTE: this module lands the endpoint CONTRACT (request/response shape, version
check, storage-key convention). The real image normalization (decode, EXIF
rotate, downscale, re-encode) is supplied by the report workstream; the
contract-level renderer here passes the source bytes through to the evidence
prefix so the shape and storage convention are exercised end-to-end.
"""

from __future__ import annotations

import logging

from fastapi import APIRouter, HTTPException, status

from app.pipeline_utils import check_pipeline_version
from app.storage import StorageError, get_bytes, put_bytes

from contracts.pipeline import (
    PIPELINE_SCHEMA_VERSION,
    EvidenceThumbnail,
    RenderEvidenceThumbnailsRequest,
    RenderEvidenceThumbnailsResponse,
)

router = APIRouter(prefix="/pipeline", tags=["evidence"])
logger = logging.getLogger(__name__)


def _thumbnail_key(job_id: str, sequence_index: int) -> str:
    """``artifacts/<job_id>/evidence/<seq>.jpg`` — disjoint from the
    ``projected/`` prefix the photo-projection stage owns."""
    return f"artifacts/{job_id}/evidence/{sequence_index}.jpg"


@router.post(
    "/render-evidence-thumbnails",
    response_model=RenderEvidenceThumbnailsResponse,
    response_model_exclude_none=True,
)
def render_evidence_thumbnails_endpoint(
    req: RenderEvidenceThumbnailsRequest,
) -> RenderEvidenceThumbnailsResponse:
    check_pipeline_version(req.pipelineSchemaVersion)

    thumbnails: list[EvidenceThumbnail] = []
    for photo in sorted(req.photos, key=lambda p: p.sequence_index):
        try:
            raw = get_bytes(photo.photo_ref)
            key = _thumbnail_key(req.job_id, photo.sequence_index)
            thumbnail_ref = put_bytes(key, raw)
        except StorageError as exc:
            logger.warning("evidence photo could not be read: seq=%s", photo.sequence_index)
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail=f"evidence photo {photo.sequence_index} could not be read",
            ) from exc
        thumbnails.append(
            EvidenceThumbnail(
                thumbnail_ref=thumbnail_ref,
                sequence_index=photo.sequence_index,
                caption=photo.caption,
            )
        )

    return RenderEvidenceThumbnailsResponse(
        pipelineSchemaVersion=PIPELINE_SCHEMA_VERSION,
        job_id=req.job_id,
        thumbnails=thumbnails,
    )
