"""Orchestration logic for F-05: Address & polygon resolver.

This module glues together the three external clients (Nominatim, MS Building
Footprints, Regrid) with the in-process TTL cache and assembles the
ResolveAddressResponse contract object.

Failure modes (per spec):
  • Geocode fails                → raise HTTPException 422
  • Building footprints missing  → raise HTTPException 422
  • Regrid fails / no coverage   → parcel_polygon = None + warning (200 OK)
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone

import httpx
from fastapi import HTTPException, status

from contracts.pipeline import (
    PIPELINE_SCHEMA_VERSION,
    Address,
    AttributionItem,
    GeometrySource,
    Polygon,
    ResolveAddressResponse,
)

from .cache import (
    FOOTPRINT_TTL,
    GEOCODE_TTL,
    PARCEL_TTL,
    footprint_cache,
    geocode_cache,
    parcel_cache,
)
from .ms_footprints import FootprintError, fetch_footprints
from .nominatim import GeocodedLocation, GeocodeError, geocode, normalize_address
from .regrid import RegridError, RegridParcel, fetch_parcel

logger = logging.getLogger(__name__)

# Attribution constants — match the display_name the spec expects
_NOMINATIM_ATTRIBUTION = AttributionItem(
    name="Nominatim / OpenStreetMap",
    license="ODbL 1.0",
    url="https://nominatim.org/",
)
_MS_FOOTPRINTS_ATTRIBUTION = AttributionItem(
    name="Microsoft Building Footprints",
    license="ODbL 1.0",
    url="https://github.com/microsoft/GlobalMLBuildingFootprints",
)
_REGRID_ATTRIBUTION = AttributionItem(
    name="Regrid",
    license=None,
    url="https://regrid.com/",
)


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _polygon_from_coords(coords: list) -> Polygon:
    """Build a contract Polygon from GeoJSON coordinate rings."""
    return Polygon(
        type="Polygon",
        coordinates=coords,
        source=GeometrySource.IMAGERY,
        confidence=0.9,
    )


def resolve(
    raw_address: str,
    *,
    nominatim_client: httpx.Client | None = None,
    ms_client: httpx.Client | None = None,
    regrid_client: httpx.Client | None = None,
    regrid_api_key: str | None = None,
    skip_rps: bool = False,
) -> ResolveAddressResponse:
    """Full resolution: geocode → parcel → building footprints.

    All cacheable results are read from / written to the module-level
    `geocode_cache`, `parcel_cache`, `footprint_cache` singletons.

    Parameters
    ----------
    raw_address:
        The address string as the contractor typed it.
    nominatim_client, ms_client, regrid_client:
        Injected httpx.Client instances (used in tests to mock HTTP).
    regrid_api_key:
        Override REGRID_API_KEY (used in tests).
    skip_rps:
        Bypass the Nominatim 1-RPS limiter (for tests).
    """
    normalized = normalize_address(raw_address)

    # ------------------------------------------------------------------
    # 1. Geocode (Nominatim)
    # ------------------------------------------------------------------
    geo: GeocodedLocation | None = geocode_cache.get(normalized)
    geo_from_cache = geo is not None

    if geo is None:
        try:
            geo = geocode(
                raw_address,
                client=nominatim_client,
                skip_rps=skip_rps,
            )
        except GeocodeError as exc:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail=f"Geocode failed: {exc}",
            ) from exc
        geocode_cache.set(normalized, geo, GEOCODE_TTL)

    nominatim_attr = AttributionItem(
        name=_NOMINATIM_ATTRIBUTION.name,
        license=_NOMINATIM_ATTRIBUTION.license,
        url=_NOMINATIM_ATTRIBUTION.url,
        retrieved_at=_now_iso() if not geo_from_cache else None,
    )

    # ------------------------------------------------------------------
    # 2. Parcel boundary (Regrid) — graceful-degrade on failure
    # ------------------------------------------------------------------
    parcel_key = f"{geo.lat:.6f},{geo.lon:.6f}"
    parcel: RegridParcel | None = parcel_cache.get(parcel_key)
    parcel_from_cache = parcel is not None
    warnings: list[str] = []
    parcel_polygon: Polygon | None = None
    regrid_attr: AttributionItem | None = None

    if parcel is None:
        try:
            parcel = fetch_parcel(
                geo.lat,
                geo.lon,
                api_key=regrid_api_key,
                client=regrid_client,
            )
            if parcel is not None:
                parcel_cache.set(parcel_key, parcel, PARCEL_TTL)
            else:
                # Key absent or no coverage — not a hard error
                if regrid_api_key or __import__("os").environ.get("REGRID_API_KEY"):
                    warnings.append("parcel_unavailable: Regrid found no parcel for this location")
                else:
                    warnings.append("parcel_unavailable: REGRID_API_KEY not set")
        except RegridError as exc:
            logger.warning("Regrid degraded: %s", exc)
            warnings.append(f"parcel_unavailable: {exc}")

    if parcel is not None:
        parcel_polygon = _polygon_from_coords(parcel.polygon_coords)
        regrid_attr = AttributionItem(
            name=_REGRID_ATTRIBUTION.name,
            license=_REGRID_ATTRIBUTION.license,
            url=_REGRID_ATTRIBUTION.url,
            retrieved_at=_now_iso() if not parcel_from_cache else None,
        )

    # ------------------------------------------------------------------
    # 3. Building footprints (MS Building Footprints)
    # ------------------------------------------------------------------
    footprint_key = f"ms:{normalized}"
    cached_footprints: list[list] | None = footprint_cache.get(footprint_key)
    footprints_from_cache = cached_footprints is not None

    if cached_footprints is None:
        parcel_coords = parcel.polygon_coords if parcel is not None else None
        try:
            raw_footprints = fetch_footprints(
                geo.lat,
                geo.lon,
                parcel_polygon_coords=parcel_coords,
                client=ms_client,
            )
        except FootprintError as exc:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail=f"Building footprint fetch failed: {exc}",
            ) from exc
        cached_footprints = raw_footprints
        footprint_cache.set(footprint_key, raw_footprints, FOOTPRINT_TTL)

    if not cached_footprints:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="No building footprints found for this address.",
        )

    building_polygons = [_polygon_from_coords(coords) for coords in cached_footprints]

    ms_attr = AttributionItem(
        name=_MS_FOOTPRINTS_ATTRIBUTION.name,
        license=_MS_FOOTPRINTS_ATTRIBUTION.license,
        url=_MS_FOOTPRINTS_ATTRIBUTION.url,
        retrieved_at=_now_iso() if not footprints_from_cache else None,
    )

    # ------------------------------------------------------------------
    # 4. Assemble response
    # ------------------------------------------------------------------
    attribution = [nominatim_attr, ms_attr]
    if regrid_attr is not None:
        attribution.append(regrid_attr)

    geocode_address = Address(
        raw=raw_address,
        normalized=geo.formatted_address,
        lat=geo.lat,
        lon=geo.lon,
        source=GeometrySource.IMAGERY,
        confidence=0.95,
    )

    return ResolveAddressResponse(
        pipelineSchemaVersion=PIPELINE_SCHEMA_VERSION,
        geocode=geocode_address,
        parcel_polygon=parcel_polygon,
        building_polygons=building_polygons,
        attribution=attribution,
        warnings=warnings,
    )
