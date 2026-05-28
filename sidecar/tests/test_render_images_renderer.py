"""Tests for the render-images renderer (the placeholder + live-gate logic).

The live Playwright path is exercised only when RENDER_IMAGES_LIVE=1 and a token
is present; in CI the default is the deterministic placeholder, which is what we
assert here. The placeholder must be a valid PNG of exactly the requested size.
"""

from __future__ import annotations

from io import BytesIO

from PIL import Image

from app.render_images.renderer import placeholder_png, render_png


def test_placeholder_png_is_valid_and_correct_size():
    png = placeholder_png(64, 48)
    img = Image.open(BytesIO(png))
    assert img.format == "PNG"
    assert img.size == (64, 48)


def test_render_png_defaults_to_placeholder_when_live_disabled(monkeypatch):
    monkeypatch.delenv("RENDER_IMAGES_LIVE", raising=False)
    png = render_png([-104.995, 39.738, -104.994, 39.739], 80, 60)
    img = Image.open(BytesIO(png))
    assert img.format == "PNG"
    assert img.size == (80, 60)


def test_render_png_falls_back_to_placeholder_when_token_missing(monkeypatch):
    monkeypatch.setenv("RENDER_IMAGES_LIVE", "1")
    monkeypatch.delenv("MAPBOX_PUBLIC_TOKEN", raising=False)
    png = render_png([-104.995, 39.738, -104.994, 39.739], 32, 24)
    img = Image.open(BytesIO(png))
    assert img.size == (32, 24)
