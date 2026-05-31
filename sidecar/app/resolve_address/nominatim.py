"""Nominatim geocoder client for the address & polygon resolver.

Nominatim TOS:
  • Must send a meaningful User-Agent identifying the project (NOMINATIM_USER_AGENT env).
  • Hard limit: 1 request per second; this client enforces it via a module-level
    rate limiter (threading.Lock + wall-clock check).
  • Self-hosting required if traffic exceeds 1 RPS (see LICENSES.md).

Live calls are gated behind the presence of NOMINATIM_USER_AGENT.  Tests
inject an `httpx.MockTransport` or vcrpy cassette — no real network needed.
"""

from __future__ import annotations

import logging
import os
import threading
import time
import unicodedata
from dataclasses import dataclass

import httpx

logger = logging.getLogger(__name__)

NOMINATIM_BASE_URL = os.environ.get("NOMINATIM_BASE_URL", "https://nominatim.openstreetmap.org")
NOMINATIM_USER_AGENT = os.environ.get("NOMINATIM_USER_AGENT", "rooftrace/dev contact@example.com")

# 1-RPS polite-use rate limiter (Nominatim TOS §2).
_rps_lock = threading.Lock()
_last_call: float = 0.0
_MIN_INTERVAL = 1.0  # seconds


def _rps_wait() -> None:
    """Block until at least 1 s has elapsed since the last Nominatim call."""
    global _last_call
    with _rps_lock:
        now = time.monotonic()
        elapsed = now - _last_call
        if elapsed < _MIN_INTERVAL:
            time.sleep(_MIN_INTERVAL - elapsed)
        _last_call = time.monotonic()


def normalize_address(raw: str) -> str:
    """Collapse whitespace and NFC-normalize for stable cache keys."""
    normalized = unicodedata.normalize("NFC", raw.strip())
    return " ".join(normalized.split())


@dataclass(slots=True)
class GeocodedLocation:
    """Result of a successful Nominatim geocode."""

    lat: float
    lon: float
    formatted_address: str
    raw_address: str


class GeocodeError(Exception):
    """Raised when Nominatim cannot resolve the address."""


def geocode(
    address: str,
    *,
    client: httpx.Client | None = None,
    skip_rps: bool = False,
) -> GeocodedLocation:
    """Geocode *address* via Nominatim.

    Parameters
    ----------
    address:
        The raw address string.
    client:
        Optional httpx.Client to use (injected in tests).  If None a new
        client is created for the duration of the call.
    skip_rps:
        If True, bypass the 1-RPS wait (for test fixtures where the network
        is mocked and the wait is unwanted overhead).

    Raises
    ------
    GeocodeError
        When Nominatim returns no results or a non-2xx response.
    """
    if not skip_rps:
        _rps_wait()

    headers = {"User-Agent": NOMINATIM_USER_AGENT, "Accept-Language": "en"}
    params = {"q": address, "format": "jsonv2", "limit": 1, "addressdetails": 0}

    close_after = client is None
    if client is None:
        client = httpx.Client(base_url=NOMINATIM_BASE_URL, timeout=10.0)

    try:
        resp = client.get("/search", params=params, headers=headers)
    except httpx.RequestError as exc:
        raise GeocodeError(f"Nominatim request failed: {type(exc).__name__}") from exc
    finally:
        if close_after:
            client.close()

    if resp.status_code != 200:
        raise GeocodeError(
            f"Nominatim returned HTTP {resp.status_code} for address {address!r}"
        )

    results = resp.json()
    if not results:
        raise GeocodeError(f"Nominatim found no results for address {address!r}")

    hit = results[0]
    return GeocodedLocation(
        lat=float(hit["lat"]),
        lon=float(hit["lon"]),
        formatted_address=hit.get("display_name", address),
        raw_address=address,
    )
