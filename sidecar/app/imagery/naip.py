"""F-10.1 NAIP imagery fetcher.

Fetches a NAIP (USDA National Agriculture Imagery Program) tile for a given
WGS84 bounding box from AWS Open Data (s3://naip-visualization/, anonymous
reads) via a public STAC/COG approach, renders it to a square PNG, and stores
it under ``cache/imagery/<hash>.png`` in Spaces.

Real path gated by ``IMAGERY_LIVE=1``.  When unset (default / CI), a
deterministic fixture PNG is generated in-process from the bbox hash.

NAIP is public domain (USDA); attribution is always emitted so downstream
stages can surface it in the report.

Key-derivation: sha256(canonical_repr_of_bbox_padded)[0:24].png, where the
canonical repr is ``"{west:.7f},{south:.7f},{east:.7f},{north:.7f}"``.
The 24-hex prefix is collision-safe for any reasonable job volume.
"""

from __future__ import annotations

import hashlib
import io
import logging
from dataclasses import dataclass, field

from app import flags

import numpy as np

logger = logging.getLogger(__name__)

# -------------------------------------------------
# Padding applied when expanding the polygon bbox.
# 15 % in each direction gives a comfortable margin
# without stretching beyond NAIP tile boundaries.
# -------------------------------------------------
BBOX_PAD_FRACTION = 0.15

# NAIP on AWS Open Data — anonymous HTTPS endpoint.
# The visualisation layer (natural colour JPEG2000 COGs, 1 m GSD) is the
# simplest publicly-accessible form: no auth, no account required.
#
# The bucket is requester-pays for us-west-2 egress, BUT the
# naip-visualization bucket is listed as Open Data (free egress for public
# access over HTTPS).  We use the public S3 endpoint, not an s3:// URI, so
# no AWS credentials are needed.
NAIP_S3_BUCKET = "naip-visualization"
NAIP_S3_REGION = "us-west-2"

# Naip COG S3 key pattern (yearly mosaic, natural colour):
#   <year>/<state>/<resolution_m>cm/<lat>/<lon>/m_<10x>_<q>_<zone>_<year>.tif
# Rather than guessing the exact key for every polygon, we query the public
# STAC endpoint (Element84 Earth Search) which indexes NAIP COGs directly.
EARTH_SEARCH_STAC_URL = "https://earth-search.aws.element84.com/v1"


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
    attribution_name: str = "USDA NAIP"
    attribution_license: str = "Public Domain (USDA)"
    attribution_url: str = "https://www.fsa.usda.gov/programs-and-services/aerial-photography/imagery-programs/naip-imagery/"


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
    Used when IMAGERY_LIVE is unset (default in CI / tests).
    """
    canonical = f"{west:.7f},{south:.7f},{east:.7f},{north:.7f}"
    seed = int(hashlib.sha256(canonical.encode()).hexdigest()[:8], 16)
    rng = np.random.default_rng(seed)

    # Generate a plausible-looking aerial imagery gradient (greens/browns).
    r_base = int(rng.integers(60, 140))
    g_base = int(rng.integers(80, 160))
    b_base = int(rng.integers(40, 100))

    # Gradient across the image
    gradient = np.linspace(0, 1, size_px)
    r_row = np.clip(r_base + (gradient * 40).astype(np.uint8), 0, 255).astype(np.uint8)
    g_row = np.clip(g_base + (gradient * 30).astype(np.uint8), 0, 255).astype(np.uint8)
    b_row = np.clip(b_base + (gradient * 20).astype(np.uint8), 0, 255).astype(np.uint8)

    rgb = np.zeros((size_px, size_px, 3), dtype=np.uint8)
    for col in range(size_px):
        rgb[:, col, 0] = r_row[col]
        rgb[:, col, 1] = g_row[col]
        rgb[:, col, 2] = b_row[col]

    # Add a subtle noise layer to make it look less synthetic.
    noise = rng.integers(-15, 15, (size_px, size_px, 3)).astype(np.int16)
    rgb_noised = np.clip(rgb.astype(np.int16) + noise, 0, 255).astype(np.uint8)

    from PIL import Image

    img = Image.fromarray(rgb_noised, mode="RGB")
    buf = io.BytesIO()
    img.save(buf, format="PNG", optimize=False)
    return buf.getvalue()


def project_bounds(src_crs, transform, wgs84_bounds: tuple[float, float, float, float]):
    """Compute the pixel-space read window for a WGS84 bbox against a COG.

    ``wgs84_bounds`` is ``(west, south, east, north)`` in EPSG:4326 lon/lat
    degrees.  NAIP COGs are stored in a projected CRS (UTM), so the bounds must
    be transformed from EPSG:4326 into ``src_crs`` *before* computing the read
    window — otherwise raw degrees are interpreted as projected map units and
    the window lands on the wrong pixels (or off the raster entirely).

    Returns a ``rasterio.windows.Window`` in pixel space matching the projected
    extent. ``transform`` is the COG's affine (``src.transform``).
    """
    from rasterio.warp import transform_bounds  # type: ignore[import]
    from rasterio.windows import from_bounds as win_from_bounds  # type: ignore[import]

    west, south, east, north = wgs84_bounds
    # transform_bounds is a no-op when src_crs is already EPSG:4326; densify_pts
    # follows the curved edges so the projected envelope fully covers the bbox.
    projected = transform_bounds("EPSG:4326", src_crs, west, south, east, north, densify_pts=21)
    return win_from_bounds(*projected, transform=transform)


def fetch_naip_png(
    west: float,
    south: float,
    east: float,
    north: float,
    size_px: int,
    timeout_s: float = 30.0,
) -> bytes:
    """Fetch a NAIP tile from AWS Open Data via the Earth Search STAC + COG.

    Queries Element84 Earth Search for NAIP items intersecting the bbox,
    picks the most recent item, reads the visual band COG via rasterio
    windowed read, and returns PNG bytes.

    Raises RuntimeError on any fetch/decode failure (caller converts to 502).
    """
    try:
        import rasterio  # type: ignore[import]
    except ImportError as exc:
        raise RuntimeError(
            "rasterio is not installed; cannot fetch live NAIP. "
            "Set IMAGERY_LIVE=1 only when rasterio is available."
        ) from exc

    import httpx

    # Step 1: STAC search for NAIP items covering this bbox.
    stac_url = f"{EARTH_SEARCH_STAC_URL}/search"
    payload = {
        "collections": ["naip"],
        "bbox": [west, south, east, north],
        "limit": 5,
        "sortby": [{"field": "datetime", "direction": "desc"}],
    }
    try:
        resp = httpx.post(stac_url, json=payload, timeout=timeout_s)
        resp.raise_for_status()
        items = resp.json().get("features", [])
    except Exception as exc:
        raise RuntimeError(f"STAC search failed: {exc}") from exc

    if not items:
        raise RuntimeError(
            f"No NAIP coverage found for bbox [{west},{south},{east},{north}]. "
            "The fixture fallback runs when IMAGERY_LIVE is unset."
        )

    # Step 2: pick the most-recent item's 'image' (visual/RGB) COG asset.
    item = items[0]
    assets = item.get("assets", {})
    # Earth Search NAIP items use "image" or "visual" as the RGB asset key.
    cog_href = None
    for key in ("image", "visual", "thumbnail"):
        asset = assets.get(key)
        if asset:
            href = asset.get("href", "")
            # Prefer COG (GeoTIFF), skip thumbnail.
            if key != "thumbnail" or cog_href is None:
                cog_href = href
            break
    if not cog_href:
        raise RuntimeError(f"No usable asset in NAIP STAC item {item.get('id')}")

    # Step 3: windowed read from the COG.
    try:
        with rasterio.open(cog_href) as src:
            window = project_bounds(src.crs, src.transform, (west, south, east, north))
            data = src.read([1, 2, 3], window=window, out_shape=(3, size_px, size_px))
    except Exception as exc:
        raise RuntimeError(f"COG windowed read failed for {cog_href}: {exc}") from exc

    # Step 4: encode to PNG.
    from PIL import Image

    # data shape: (3, size_px, size_px) — convert to HWC uint8
    arr = np.moveaxis(data, 0, -1)
    arr = np.clip(arr, 0, 255).astype(np.uint8)
    img = Image.fromarray(arr, mode="RGB")
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def render_imagery(
    building_polygon: dict,
    size_px: int,
    put_bytes,
    target_gsd_m: float | None = None,
) -> ImageryOutcome:
    """Top-level entry point.  Returns an ``ImageryOutcome`` after writing to storage.

    The REAL NAIP fetch path is the default (dev + prod always use real data).
    A deterministic fixture PNG is used only when ``IMAGERY_FIXTURE=1`` — set by
    the test suites alone (see app/flags.py). Either way the PNG is stored via
    ``put_bytes`` and the outcome carries the key + bounds + warnings.
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
        png_bytes = fetch_naip_png(west, south, east, north, size_px)

    put_bytes(key, png_bytes)

    return ImageryOutcome(
        image_key=key,
        geo_bounds=[west, south, east, north],
        png_bytes=png_bytes,
        warnings=warnings,
    )
