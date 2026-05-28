"""F-06 LiDAR ingest — endpoint stub.

Filled in by the F-06 workstream: POST /pipeline/ingest-lidar taking an
`IngestLidarRequest` and returning an `IngestLidarResponse` (WESM coverage check
+ COPC/PDAL crop to the building polygon + UTM reproject)."""

from __future__ import annotations

from fastapi import APIRouter, HTTPException, status

router = APIRouter(prefix="/pipeline", tags=["lidar"])


@router.post("/ingest-lidar")
def ingest_lidar() -> None:
    raise HTTPException(status_code=status.HTTP_501_NOT_IMPLEMENTED, detail="F-06 not yet implemented")
