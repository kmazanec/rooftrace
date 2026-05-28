"""F-05 Address & polygon resolver — POST /pipeline/resolve-address.

Takes a `ResolveAddressRequest` (pipelineSchemaVersion + address string) and
returns a `ResolveAddressResponse` (geocode, parcel_polygon, building_polygons,
attribution, warnings).

Auth: shared-secret bearer injected by main.py (Depends(require_bearer)).
The endpoint delegates all logic to `service.resolve()`.
"""

from __future__ import annotations

from fastapi import APIRouter, HTTPException, status

from contracts.pipeline import (
    PIPELINE_SCHEMA_VERSION,
    ResolveAddressRequest,
    ResolveAddressResponse,
)

from .service import resolve

router = APIRouter(prefix="/pipeline", tags=["resolve-address"])


def _major(version: str) -> str:
    return version.split(".", 1)[0]


@router.post(
    "/resolve-address",
    response_model=ResolveAddressResponse,
    response_model_exclude_none=False,
)
def resolve_address(req: ResolveAddressRequest) -> ResolveAddressResponse:
    """Geocode an address and resolve its building footprint(s) + parcel.

    Failure modes
    -------------
    * 422 — geocode failed (address not found)
    * 422 — building footprints not found (can't proceed without a polygon)
    * 200 — parcel unavailable (parcel_polygon=null, warning in response)
    * 409 — schema major version mismatch
    """
    if _major(req.pipelineSchemaVersion) != _major(PIPELINE_SCHEMA_VERSION):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                f"pipeline schema major mismatch: request {req.pipelineSchemaVersion} "
                f"vs sidecar {PIPELINE_SCHEMA_VERSION}"
            ),
        )

    return resolve(req.address, skip_rps=False)
