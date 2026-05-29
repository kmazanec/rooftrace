"""Tests: SVG overlay + PNG composite (app/render/photo_overlay.py, ADR-019).

The overlay is an SVG layer (facet polygons stroked 2px, colored by pitch using
the viewer's gray ramp; 12pt labels at the facet centroid; occluded facets
dashed) rasterized over the source RGB at source resolution. These tests assert
the CONTRACT-level structure (valid SVG, expected polygon/label/dash markup) and
that the composite is a deterministic PNG at the source resolution — the exact
pixels are pinned by the committed visual-regression fixtures, not here.
"""

from __future__ import annotations

import io

from PIL import Image

from app.render.photo_overlay import build_overlay_svg, composite_png, pitch_color_hex


def _projected_facet(facet_id="F1", pitch_ratio=6.0, state="visible"):
    return {
        "facet_id": facet_id,
        "points_px": [[100.0, 100.0], [300.0, 100.0], [300.0, 250.0], [100.0, 250.0]],
        "pitch_ratio": pitch_ratio,
        "area_sq_ft": 1423.5,
        "occlusion_state": state,
        "in_front": True,
    }


class TestPitchColorHex:
    def test_low_pitch_is_lightest_gray(self):
        assert pitch_color_hex(0.0).lower() == "#9ca3af"

    def test_high_pitch_is_darkest_gray(self):
        assert pitch_color_hex(12.0).lower() == "#374151"

    def test_monotonic_darkening(self):
        # A steeper pitch is never lighter than a shallower one.
        c_low = int(pitch_color_hex(2.0)[1:], 16)
        c_high = int(pitch_color_hex(8.0)[1:], 16)
        assert c_high <= c_low


class TestBuildOverlaySvg:
    def test_emits_polygon_and_label_for_visible_facet(self):
        svg = build_overlay_svg([_projected_facet()], width_px=1024, height_px=768)
        assert svg.startswith("<?xml") or svg.lstrip().startswith("<svg")
        assert 'width="1024"' in svg and 'height="768"' in svg
        # A 2px-stroked polygon colored by pitch.
        assert "<polygon" in svg
        assert 'stroke-width="2"' in svg
        assert pitch_color_hex(6.0).lower() in svg.lower()
        # Area label at the centroid (12pt).
        assert "1424" in svg or "1423" in svg
        assert 'font-size="12' in svg

    def test_occluded_facet_omitted(self):
        # A fully-occluded facet is not drawn at all.
        svg = build_overlay_svg(
            [_projected_facet(state="occluded")], width_px=512, height_px=512
        )
        assert "<polygon" not in svg

    def test_partial_facet_is_dashed(self):
        svg = build_overlay_svg(
            [_projected_facet(state="partial")], width_px=512, height_px=512
        )
        assert "stroke-dasharray" in svg

    def test_behind_camera_facet_omitted(self):
        facet = _projected_facet()
        facet["in_front"] = False
        svg = build_overlay_svg([facet], width_px=512, height_px=512)
        assert "<polygon" not in svg


class TestCompositePng:
    def _src_png(self, w=320, h=240, color=(40, 90, 160)):
        img = Image.new("RGB", (w, h), color)
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        return buf.getvalue()

    def test_composite_matches_source_resolution(self):
        src = self._src_png(w=320, h=240)
        svg = build_overlay_svg([_projected_facet()], width_px=320, height_px=240)
        out = composite_png(src, svg, width_px=320, height_px=240)
        img = Image.open(io.BytesIO(out))
        assert img.format == "PNG"
        assert img.size == (320, 240)

    def test_composite_is_deterministic(self):
        src = self._src_png()
        svg = build_overlay_svg([_projected_facet()], width_px=320, height_px=240)
        a = composite_png(src, svg, width_px=320, height_px=240)
        b = composite_png(src, svg, width_px=320, height_px=240)
        assert a == b

    def test_composite_changes_when_overlay_drawn(self):
        # The overlay must actually alter the source pixels (not a no-op paste).
        src = self._src_png()
        empty_svg = build_overlay_svg([], width_px=320, height_px=240)
        drawn_svg = build_overlay_svg([_projected_facet()], width_px=320, height_px=240)
        bare = composite_png(src, empty_svg, width_px=320, height_px=240)
        drawn = composite_png(src, drawn_svg, width_px=320, height_px=240)
        assert bare != drawn
