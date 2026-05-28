"""F-05 Address & polygon resolver — endpoint stub.

Filled in by the F-05 workstream: POST /pipeline/resolve-address taking a
`ResolveAddressRequest` and returning a `ResolveAddressResponse` (Nominatim
geocode + MS Building Footprints + Regrid parcel)."""

from __future__ import annotations

from fastapi import APIRouter, HTTPException, status

router = APIRouter(prefix="/pipeline", tags=["resolve-address"])


@router.post("/resolve-address")
def resolve_address() -> None:
    raise HTTPException(status_code=status.HTTP_501_NOT_IMPLEMENTED, detail="F-05 not yet implemented")
