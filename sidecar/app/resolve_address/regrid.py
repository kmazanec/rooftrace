"""Regrid parcel-boundary client for the address & polygon resolver.

Regrid provides parcel data via their API (free tier).  The endpoint used is:
  GET /api/v1/parcel/point?lat=<lat>&lng=<lon>&token=<key>

Auth: REGRID_API_KEY environment variable.  When the key is absent the client
returns None immediately (graceful degradation — parcel_polygon becomes null
in the response, per the spec).

Live calls are gated behind REGRID_API_KEY being set.  Tests use an
httpx.MockTransport so they never hit the real API.

Failure modes:
  • Key absent                   → returns None (no warning from this layer)
  • HTTP 4xx (auth / rate-limit) → raises RegridError
  • HTTP timeout                 → raises RegridError
  • No parcel in response        → returns None (caller logs warning)
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass

import httpx

logger = logging.getLogger(__name__)

REGRID_BASE_URL = os.environ.get("REGRID_BASE_URL", "https://app.regrid.com")
REGRID_API_KEY: str | None = os.environ.get("REGRID_API_KEY")

_TIMEOUT = 10.0  # seconds; Regrid SLA is relaxed for free-tier


class RegridError(Exception):
    """Raised when Regrid returns a non-retryable error."""


@dataclass(slots=True)
class RegridParcel:
    """A parcel boundary from Regrid."""

    parcel_id: str
    polygon_coords: list  # GeoJSON Polygon coordinates (list of rings)
    address: str | None = None


def _extract_parcel(data: dict) -> RegridParcel | None:
    """Parse the Regrid point-lookup response into a RegridParcel.

    Regrid v1 /parcel/point wraps results in:
      {"parcels": {"features": [{"type": "Feature", "geometry": {...}, "properties": {...}}]}}

    Returns None when no parcel is present in the response.
    """
    parcels = data.get("parcels") or {}
    features = parcels.get("features") or []
    if not features:
        return None

    feature = features[0]
    geom = feature.get("geometry") or {}
    props = feature.get("properties") or {}

    if geom.get("type") != "Polygon":
        return None

    coords = geom.get("coordinates")
    if not coords:
        return None

    parcel_id = props.get("ll_uuid") or props.get("id") or "unknown"
    address = props.get("address")

    return RegridParcel(parcel_id=str(parcel_id), polygon_coords=coords, address=address)


def fetch_parcel(
    lat: float,
    lon: float,
    *,
    api_key: str | None = None,
    client: httpx.Client | None = None,
) -> RegridParcel | None:
    """Fetch the parcel boundary containing (lat, lon) from Regrid.

    Returns None when:
      • no API key is available (graceful degradation), or
      • Regrid has no parcel for this location.

    Raises RegridError on HTTP errors or network failures.

    Parameters
    ----------
    lat, lon:
        WGS84 coordinates of the geocoded point.
    api_key:
        Regrid API key.  Defaults to the REGRID_API_KEY env var.
    client:
        Optional httpx.Client (injected in tests).
    """
    key = api_key or REGRID_API_KEY
    if not key:
        logger.debug("regrid: REGRID_API_KEY not set, skipping parcel lookup")
        return None

    params = {"lat": lat, "lng": lon, "token": key}

    close_after = client is None
    if client is None:
        client = httpx.Client(base_url=REGRID_BASE_URL, timeout=_TIMEOUT)

    # Regrid free-tier auth is a `token` query param (no header option), so the
    # key rides in the URL. Keep it out of exception messages: httpx errors can
    # embed the full request URL (with the token), which would then land in
    # RegridError text and any log that records it. Report only the error class.
    try:
        resp = client.get("/api/v1/parcel/point", params=params)
    except httpx.TimeoutException as exc:
        raise RegridError(f"Regrid request timed out ({type(exc).__name__})") from exc
    except Exception as exc:
        raise RegridError(f"Regrid request failed ({type(exc).__name__})") from exc
    finally:
        if close_after:
            client.close()

    if resp.status_code in (401, 403):
        raise RegridError(f"Regrid authentication failed (HTTP {resp.status_code})")
    if resp.status_code != 200:
        raise RegridError(f"Regrid returned HTTP {resp.status_code}")

    try:
        data = resp.json()
    except Exception as exc:
        raise RegridError(f"Regrid returned invalid JSON: {exc}") from exc

    return _extract_parcel(data)
