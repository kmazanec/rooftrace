"""Satellite imagery fetcher (ADR-002).

Fetches a satellite tile for a given WGS84 bounding box from the Mapbox Static
Images API (the project's existing satellite vendor — see ADR-002), renders it to
a square PNG, and stores it under ``cache/imagery/<hash>.png`` in Spaces. The
returned tile's geo bounds are exactly the requested bbox.

The real Mapbox fetch is the DEFAULT (dev + prod always use real data). A
deterministic fixture PNG is generated in-process from the bbox hash ONLY under
``IMAGERY_FIXTURE=1`` — set by the test suites alone (see app/flags.py).

(History: this stage originally fetched NAIP from AWS on an "anonymous public"
assumption that was false — all NAIP S3 buckets are Requester Pays — so it never
worked on the real path. It now reuses Mapbox, already a hard dependency, rather
than adding an AWS account + a second imagery credential. Module file kept as
naip.py to limit import churn; it no longer touches NAIP.)

Mapbox attribution is emitted by the report surfaces per the Mapbox ToS.

Key-derivation: sha256(canonical_repr_of_bbox_padded)[0:24].png, where the
canonical repr is ``"{west:.7f},{south:.7f},{east:.7f},{north:.7f}"``.
The 24-hex prefix is collision-safe for any reasonable job volume.
"""

from __future__ import annotations

import hashlib
import io
import logging
from collections.abc import Callable
from dataclasses import dataclass, field

from app import flags

import numpy as np

logger = logging.getLogger(__name__)

# -------------------------------------------------
# Padding applied when expanding the polygon bbox.
# 15 % in each direction gives a comfortable margin
# around the building footprint.
# -------------------------------------------------
BBOX_PAD_FRACTION = 0.15

# Satellite imagery source: Mapbox Static Images API (ADR-002). Mapbox is already
# the project's satellite-tile vendor (the report viewer + the render_images stage
# use mapbox.satellite), so the geometry pipeline reuses it rather than adding a
# second imagery vendor. (The original AWS-hosted source was dropped because its
# S3 buckets are Requester Pays — anonymous reads are impossible, and an
# authenticated path would add an AWS account + a second credential for marginal
# resolution gain. One imagery source, one credential. See ADR-002.)
#
# The Static Images "bounding box" form returns a single image rendered for an
# explicit [minLon,minLat,maxLon,maxLat] in Web Mercator, so the returned tile's
# geo bounds ARE the requested bbox — exactly what the pipeline contract needs,
# with no reprojection. Docs: https://docs.mapbox.com/api/maps/static-images/
MAPBOX_STATIC_STYLE = "mapbox/satellite-v9"
MAPBOX_STATIC_BASE = "https://api.mapbox.com/styles/v1"
# Mapbox caps a static image dimension at 1280 px; the pipeline asks for 1024.
MAPBOX_MAX_DIM_PX = 1280


# -------------------------------------------------------------------------
# Public interface
# -------------------------------------------------------------------------


@dataclass
class ImageryOutcome:
    """Result of a render-imagery call."""

    image_key: str  # Spaces cache key, e.g. cache/imagery/<hash>.png
    geo_bounds: list[float]  # [west, south, east, north], padded
    png_bytes: bytes
    warnings: list[str] = field(default_factory=list)
    # Mapbox is the imagery source (ADR-002 amended). Its ToS requires the Mapbox
    # + imagery-provider (Maxar) credit; do NOT claim public domain.
    attribution_name: str = "Mapbox"
    attribution_license: str = "© Mapbox © Maxar"
    attribution_url: str = "https://www.mapbox.com/about/maps/"


def polygon_to_padded_bbox(building_polygon: dict, pad_fraction: float = BBOX_PAD_FRACTION) -> tuple[float, float, float, float]:
    """Compute a padded [west, south, east, north] bbox from a GeoJSON Polygon.

    Adds ``pad_fraction`` of the span in each direction so the whole roof
    footprint sits well within the tile rather than touching the edges.

    Returns: (west, south, east, north) as plain floats.
    """
    coords: list[list[float]] = building_polygon["coordinates"][0]
    lons = [c[0] for c in coords]
    lats = [c[1] for c in coords]
    raw_west, raw_east = min(lons), max(lons)
    raw_south, raw_north = min(lats), max(lats)

    lon_span = raw_east - raw_west
    lat_span = raw_north - raw_south

    # Guard against degenerate (point/line) polygons — apply a minimum span
    # of 0.001 degrees (~100 m) so the tile is always non-degenerate.
    lon_span = max(lon_span, 0.001)
    lat_span = max(lat_span, 0.001)

    pad_lon = lon_span * pad_fraction
    pad_lat = lat_span * pad_fraction

    west = max(-180.0, raw_west - pad_lon)
    east = min(180.0, raw_east + pad_lon)
    south = max(-90.0, raw_south - pad_lat)
    north = min(90.0, raw_north + pad_lat)

    return west, south, east, north


def bbox_cache_key(west: float, south: float, east: float, north: float, size_px: int) -> str:
    """Deterministic cache key for a padded bbox + target size.

    Hash: sha256 of the canonical bbox+size string, hex prefix [0:24].
    """
    canonical = f"{west:.7f},{south:.7f},{east:.7f},{north:.7f},{size_px}"
    digest = hashlib.sha256(canonical.encode()).hexdigest()[:24]
    return f"cache/imagery/{digest}.png"


def generate_fixture_png(
    west: float,
    south: float,
    east: float,
    north: float,
    size_px: int,
) -> bytes:
    """Generate a deterministic fixture PNG from the bbox hash.

    The image is a small gradient whose colours are seeded by the bbox so
    different requests produce visually distinct but reproducible tiles.
    Used only under IMAGERY_FIXTURE=1 (the test suites).
    """
    canonical = f"{west:.7f},{south:.7f},{east:.7f},{north:.7f}"
    seed = int(hashlib.sha256(canonical.encode()).hexdigest()[:8], 16)
    rng = np.random.default_rng(seed)

    # Generate a plausible-looking aerial imagery gradient (greens/browns).
    r_base = int(rng.integers(60, 140))
    g_base = int(rng.integers(80, 160))
    b_base = int(rng.integers(40, 100))

    # Gradient across the image.  Add in float before clipping so the channel
    # offset can't overflow uint8 mid-expression (e.g. r_base=200 + uint8(55) wraps
    # to 255 before clip; in float it computes 255 correctly then clips).
    gradient = np.linspace(0, 1, size_px)
    r_row = np.clip(r_base + gradient * 40, 0, 255).astype(np.uint8)
    g_row = np.clip(g_base + gradient * 30, 0, 255).astype(np.uint8)
    b_row = np.clip(b_base + gradient * 20, 0, 255).astype(np.uint8)

    # Each *_row is shape (size_px,) — one value per column.  Broadcast to
    # (size_px, size_px) by tiling the single row across all rows.
    rgb = np.stack(
        [
            np.broadcast_to(r_row[np.newaxis, :], (size_px, size_px)).copy(),
            np.broadcast_to(g_row[np.newaxis, :], (size_px, size_px)).copy(),
            np.broadcast_to(b_row[np.newaxis, :], (size_px, size_px)).copy(),
        ],
        axis=-1,
    ).astype(np.uint8)

    # Add a subtle noise layer to make it look less synthetic.
    noise = rng.integers(-15, 15, (size_px, size_px, 3)).astype(np.int16)
    rgb_noised = np.clip(rgb.astype(np.int16) + noise, 0, 255).astype(np.uint8)

    from PIL import Image

    img = Image.fromarray(rgb_noised, mode="RGB")
    buf = io.BytesIO()
    img.save(buf, format="PNG", optimize=False)
    return buf.getvalue()


def _mapbox_token() -> str:
    import os

    token = os.environ.get("MAPBOX_PRIVATE_TOKEN", "").strip()
    if not token:
        # Should be caught at boot (boot_checks._imagery_missing); raise loudly
        # rather than fetch a 401 image.
        raise RuntimeError(
            "MAPBOX_PRIVATE_TOKEN unset; cannot fetch real satellite imagery "
            "(tests set IMAGERY_FIXTURE=1)."
        )
    return token


def fetch_satellite_png(
    west: float,
    south: float,
    east: float,
    north: float,
    size_px: int,
    timeout_s: float = 30.0,
) -> bytes:
    """Fetch a satellite tile for the WGS84 bbox via the Mapbox Static Images API.

    The bounding-box form renders one image for an explicit
    [minLon,minLat,maxLon,maxLat], so the returned tile's geo bounds ARE the
    requested bbox (no reprojection — the pipeline contract is unchanged).
    `@2x` doubles pixel density; we clamp the requested logical dimension to
    Mapbox's 1280 px cap. Returns PNG bytes.

    Raises RuntimeError on any fetch/decode failure (caller converts to 502).
    """
    import httpx

    token = _mapbox_token()
    dim = min(int(size_px), MAPBOX_MAX_DIM_PX)
    bbox = f"[{west},{south},{east},{north}]"
    # padding=0 keeps the rendered extent exactly the requested bbox.
    url = (
        f"{MAPBOX_STATIC_BASE}/{MAPBOX_STATIC_STYLE}/static/{bbox}/{dim}x{dim}@2x"
        f"?access_token={token}&attribution=false&logo=false&padding=0"
    )
    try:
        resp = httpx.get(url, timeout=timeout_s, follow_redirects=True)
        resp.raise_for_status()
    except Exception as exc:
        # Don't leak the token (it's in the URL) into the error/logs.
        raise RuntimeError(
            f"Mapbox static imagery fetch failed: {type(exc).__name__}"
        ) from exc

    raw = resp.content
    # Mapbox returns PNG/JPEG; normalise to a square PNG at the logical size_px so
    # the stored tile + downstream pixel math match the requested dimension.
    from PIL import Image

    try:
        img = Image.open(io.BytesIO(raw)).convert("RGB")
    except Exception as exc:
        raise RuntimeError(f"Mapbox imagery decode failed: {type(exc).__name__}") from exc
    if img.size != (size_px, size_px):
        img = img.resize((size_px, size_px), Image.BILINEAR)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def render_imagery(
    building_polygon: dict,
    size_px: int,
    put_bytes: Callable[[str, bytes], str],
    target_gsd_m: float | None = None,
) -> ImageryOutcome:
    """Top-level entry point.  Returns an ``ImageryOutcome`` after writing to storage.

    The REAL Mapbox satellite fetch is the default (dev + prod always use real
    data). A deterministic fixture PNG is used only when ``IMAGERY_FIXTURE=1`` —
    set by the test suites alone (see app/flags.py). Either way the PNG is stored
    via ``put_bytes`` and the outcome carries the key + bounds + warnings.
    """
    use_fixture = flags.imagery_fixture()
    warnings: list[str] = []

    # target_gsd_m is accepted by the schema but not yet honoured: the read
    # resolution is driven entirely by size_px. Surface a warning so callers
    # know their requested ground-sample-distance was not applied, rather than
    # silently dropping it.
    if target_gsd_m is not None:
        warnings.append("target_gsd_m_ignored")

    west, south, east, north = polygon_to_padded_bbox(building_polygon)
    key = bbox_cache_key(west, south, east, north, size_px)

    if use_fixture:
        png_bytes = generate_fixture_png(west, south, east, north, size_px)
        warnings.append("imagery_fixture_fallback")
    else:
        png_bytes = fetch_satellite_png(west, south, east, north, size_px)

    put_bytes(key, png_bytes)

    return ImageryOutcome(
        image_key=key,
        geo_bounds=[west, south, east, north],
        png_bytes=png_bytes,
        warnings=warnings,
    )
