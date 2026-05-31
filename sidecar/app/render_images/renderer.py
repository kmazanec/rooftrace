"""Top-down map PNG renderer (ADR-014).

Two paths:
  - ``render_png`` (the public entry): the REAL render is the default (dev + prod
    always use real data) — it drives a headless Chromium via Playwright against
    the self-contained MapLibre viewer (headless_viewer.py) using
    ``MAPBOX_PRIVATE_TOKEN`` and screenshots it. The deterministic placeholder is
    used ONLY under ``RENDER_IMAGES_FIXTURE=1`` (the test suites — see flags.py).
  - ``placeholder_png``: the deterministic fixture, reachable only via the
    fixture flag.

There is no silent degrade-to-placeholder in the running product: a missing
``MAPBOX_PRIVATE_TOKEN`` is caught loudly at boot (boot_checks.py), and a live
render failure RAISES rather than quietly shipping a blank diagram.

The CONTRACT is the PNG encoding + the requested pixel size + the storage
convention; the real render fills in the real pixels without changing it.
"""

from __future__ import annotations

import logging
import os
from collections.abc import Sequence
from io import BytesIO

from app import flags

logger = logging.getLogger(__name__)


class RenderError(RuntimeError):
    """A real map render failed (browser/tile/bundle problem)."""


def placeholder_png(width_px: int, height_px: int) -> bytes:
    """Deterministic light-gray PNG of the requested size (no browser)."""
    from PIL import Image

    img = Image.new("RGB", (width_px, height_px), (236, 236, 236))
    buf = BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def render_png(bbox: Sequence[float], width_px: int, height_px: int) -> bytes:
    """Render the top-down map PNG for the bbox at the requested size.

    Real render by default; the placeholder is returned ONLY under the fixture
    opt-down (`RENDER_IMAGES_FIXTURE=1`, the test suites). A real-render failure
    raises ``RenderError`` — no silent placeholder fallback in the running
    product (the Rails side may layer its own Mapbox Static fallback on top).
    """
    if flags.render_images_fixture():
        return placeholder_png(width_px, height_px)

    token = os.environ.get("MAPBOX_PRIVATE_TOKEN", "").strip()
    if not token:
        # Should be caught at boot; raise rather than silently placeholder.
        raise RenderError("MAPBOX_PRIVATE_TOKEN unset; cannot render the real map")

    try:
        return _render_with_playwright(bbox, width_px, height_px, token)
    except Exception as exc:
        raise RenderError(f"live map render failed: {type(exc).__name__}: {exc}") from exc


def _render_with_playwright(bbox: Sequence[float], width_px: int, height_px: int, token: str) -> bytes:
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
            # Wait past the viewer's 8s hard-timeout so a merely-slow tile fetch
            # resolves via map "idle" rather than the give-up path; +2s slack for
            # the round-trip. __mapReady flips on EITHER idle or timeout.
            page.wait_for_function("window.__mapReady === true", timeout=10000)
            # The viewer sets __mapFailed when the MapLibre bundle never loaded
            # (e.g. the CDN was unreachable). Screenshotting then would capture a
            # featureless gray div and still return HTTP 200 — a silent
            # degradation. Raise so the caller degrades to the placeholder PNG
            # (and Rails' own Mapbox Static fallback can engage on top).
            if page.evaluate("window.__mapFailed === true"):
                raise RuntimeError("MapLibre bundle failed to load in headless viewer")
            # __mapReady can also flip via the give-up timeout while tiles are
            # still fetching — screenshotting then yields a gray/partial map that
            # would be cached under artifacts/ for 30 min. Only __mapTilesLoaded
            # (set from map "idle") proves a real image; otherwise treat it as a
            # failed render and degrade rather than ship a blank diagram.
            if not page.evaluate("window.__mapTilesLoaded === true"):
                raise RuntimeError("map tiles did not finish loading before timeout")
            png = page.locator("#map").screenshot(type="png")
        finally:
            browser.close()
    return png
