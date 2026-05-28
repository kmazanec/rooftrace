"""F-07 Roof outline refinement (SAM2) — endpoint stub.

Filled in by the F-07 workstream: POST /pipeline/refine-outline taking a
`RefineOutlineRequest` and returning a `RefineOutlineResponse` (SAM2 zero-shot
with the footprint prior, Douglas–Peucker simplification, Modal/local backend)."""

from __future__ import annotations

from fastapi import APIRouter, HTTPException, status

router = APIRouter(prefix="/pipeline", tags=["outline"])


@router.post("/refine-outline")
def refine_outline() -> None:
    raise HTTPException(status_code=status.HTTP_501_NOT_IMPLEMENTED, detail="F-07 not yet implemented")
