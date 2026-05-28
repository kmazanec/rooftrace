"""F-08 Plane fit + measurement — endpoint stubs.

Filled in by the F-08 workstream:
- POST /pipeline/fit-planes (LiDAR path): `FitPlanesRequest` -> `MeasurementGeometry`.
- POST /pipeline/fallback-measurement (no-LiDAR path): `FallbackMeasurementRequest`
  -> `MeasurementGeometry`.
RANSAC multi-plane fit, pitch from normals, pitch-corrected area, topology merge."""

from __future__ import annotations

from fastapi import APIRouter, HTTPException, status

router = APIRouter(prefix="/pipeline", tags=["planefit"])


@router.post("/fit-planes")
def fit_planes() -> None:
    raise HTTPException(status_code=status.HTTP_501_NOT_IMPLEMENTED, detail="F-08 not yet implemented")


@router.post("/fallback-measurement")
def fallback_measurement() -> None:
    raise HTTPException(status_code=status.HTTP_501_NOT_IMPLEMENTED, detail="F-08 not yet implemented")
