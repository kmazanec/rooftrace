"""Top-down map PNG renderer (ADR-014).

Two paths:
  - ``render_png`` (the public entry): when ``RENDER_IMAGES_LIVE=1`` and a
    ``MAPBOX_PUBLIC_TOKEN`` is present, drives a headless Chromium via Playwright
    against the self-contained MapLibre viewer (headless_viewer.py) and
    screenshots it. Otherwise (the default, and all hermetic tests) returns a
    deterministic placeholder PNG of the requested size.
  - ``placeholder_png``: the deterministic fallback used when the live path is
    disabled or fails.

The CONTRACT is the PNG encoding + the requested pixel size + the storage
convention; the live render fills in the real pixels without changing it.
"""

from __future__ import annotations

import logging
import os
from io import BytesIO

logger = logging.getLogger(__name__)


def placeholder_png(width_px: int, height_px: int) -> bytes:
    """Deterministic light-gray PNG of the requested size (no browser)."""
    from PIL import Image

    img = Image.new("RGB", (width_px, height_px), (236, 236, 236))
    buf = BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def _live_enabled() -> bool:
    return os.environ.get("RENDER_IMAGES_LIVE", "") == "1"


def render_png(bbox: list[float], width_px: int, height_px: int) -> bytes:
    """Render the top-down map PNG for the bbox at the requested size.

    Falls back to the placeholder when the live path is disabled. A live-path
    failure is logged and degrades to the placeholder rather than raising, so a
    transient browser/tile problem still yields a (plain) diagram; the Rails
    side additionally has its own Mapbox Static fallback.
    """
    if not _live_enabled():
        return placeholder_png(width_px, height_px)

    token = os.environ.get("MAPBOX_PUBLIC_TOKEN", "").strip()
    if not token:
        logger.warning("RENDER_IMAGES_LIVE=1 but MAPBOX_PUBLIC_TOKEN unset; using placeholder")
        return placeholder_png(width_px, height_px)

    try:
        return _render_with_playwright(bbox, width_px, height_px, token)
    except Exception as exc:  # noqa: BLE001
        logger.warning("live map render failed (%s); using placeholder", type(exc).__name__)
        return placeholder_png(width_px, height_px)


def _render_with_playwright(bbox: list[float], width_px: int, height_px: int, token: str) -> bytes:
    from playwright.sync_api import sync_playwright

    from .headless_viewer import viewer_html

    html = viewer_html(bbox, width_px, height_px, token)
    with sync_playwright() as p:
        browser = p.chromium.launch(args=["--no-sandbox", "--disable-dev-shm-usage"])
        try:
            page = browser.new_page(
                viewport={"width": int(width_px), "height": int(height_px)},
                device_scale_factor=1,
            )
            page.set_content(html, wait_until="load")
            page.wait_for_function("window.__mapReady === true", timeout=3000)
            # The viewer sets __mapFailed when the MapLibre bundle never loaded
            # (e.g. the CDN was unreachable). Screenshotting then would capture a
            # featureless gray div and still return HTTP 200 — a silent
            # degradation. Raise so the caller degrades to the placeholder PNG
            # (and Rails' own Mapbox Static fallback can engage on top).
            if page.evaluate("window.__mapFailed === true"):
                raise RuntimeError("MapLibre bundle failed to load in headless viewer")
            png = page.locator("#map").screenshot(type="png")
        finally:
            browser.close()
    return png
