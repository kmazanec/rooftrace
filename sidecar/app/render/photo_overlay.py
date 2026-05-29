"""SVG facet overlay + PNG composite for the photo-overlay stage (ADR-019).

Given facets already projected to pixel coordinates (``photo_projection``) and
classified for occlusion (``photo_occlusion``), this builds:

  - ``build_overlay_svg`` — an SVG layer: each visible facet a 2px-stroked
    polygon colored by pitch (the SAME gray ramp the web viewer uses, NOT a
    stoplight hue), a 12pt sans area label at the centroid, partially-occluded
    facets dashed, fully-occluded / behind-camera facets omitted. The SVG is the
    PRIMARY visual-regression artifact (a stable text diff).
  - ``composite_png`` — the source RGB at source resolution with the SAME
    primitives rasterized on top via Pillow's ImageDraw (no cairo/native SVG
    renderer: we draw from the projected primitives, not by parsing the SVG, so
    the composite stays a pure-Python, deterministic tolerance-diff artifact).

Pitch -> color mirrors app/javascript/viewer/utils/colorByPitch.ts: pitch 0/12 ->
lightest gray #9CA3AF, pitch >=10/12 -> darkest gray #374151, linear between.
"""

from __future__ import annotations

import io
import xml.sax.saxutils as sax

# Viewer pitch ramp endpoints (brandColors.ts PITCH_LIGHTEST / PITCH_DARKEST).
_PITCH_LIGHTEST = (0x9C, 0xA3, 0xAF)  # #9CA3AF gray-400 (low pitch)
_PITCH_DARKEST = (0x37, 0x41, 0x51)   # #374151 gray-700 (high pitch)
_MAX_RATIO = 10.0                     # 10/12 and above clamp to darkest

_STROKE_WIDTH = 2
_LABEL_FONT_SIZE = 12
_FILL_OPACITY = 0.25
_DASH_PATTERN = "8,4"


def _lerp(a: int, b: int, t: float) -> int:
    return round(a + (b - a) * t)


def pitch_color(pitch_ratio: float) -> tuple[int, int, int]:
    """Pitch (rise per 12) -> (r, g, b) on the viewer's gray ramp."""
    ratio = pitch_ratio if pitch_ratio == pitch_ratio else 0.0  # NaN -> 0
    t = min(max(ratio, 0.0), _MAX_RATIO) / _MAX_RATIO
    return (
        _lerp(_PITCH_LIGHTEST[0], _PITCH_DARKEST[0], t),
        _lerp(_PITCH_LIGHTEST[1], _PITCH_DARKEST[1], t),
        _lerp(_PITCH_LIGHTEST[2], _PITCH_DARKEST[2], t),
    )


def pitch_color_hex(pitch_ratio: float) -> str:
    r, g, b = pitch_color(pitch_ratio)
    return f"#{r:02x}{g:02x}{b:02x}"


def _drawable(facet: dict) -> bool:
    """A facet is drawn only when it's in front of the camera and not fully
    occluded (fully-occluded / behind-camera facets are omitted per the spec)."""
    if facet.get("in_front") is False:
        return False
    if facet.get("occlusion_state") == "occluded":
        return False
    pts = facet.get("points_px") or []
    return len(pts) >= 3


def _centroid(points: list) -> tuple[float, float]:
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    return sum(xs) / len(xs), sum(ys) / len(ys)


def _label_text(facet: dict) -> str:
    area = facet.get("area_sq_ft")
    if area is None:
        return str(facet.get("facet_id") or "")
    return f"{round(float(area))} sq ft"


def build_overlay_svg(projected_facets: list[dict], width_px: int, height_px: int) -> str:
    """Build the SVG overlay layer for the projected facets.

    Returns an SVG document string (the primary visual-regression artifact)."""
    parts: list[str] = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width_px}" '
        f'height="{height_px}" viewBox="0 0 {width_px} {height_px}">',
    ]

    for facet in projected_facets:
        if not _drawable(facet):
            continue
        points = facet["points_px"]
        color = pitch_color_hex(float(facet.get("pitch_ratio") or 0.0))
        point_str = " ".join(f"{x:.1f},{y:.1f}" for x, y in points)
        dash = f' stroke-dasharray="{_DASH_PATTERN}"' if facet.get("occlusion_state") == "partial" else ""
        # A partially-occluded facet is also dimmed (lower fill opacity).
        fill_opacity = _FILL_OPACITY * (0.5 if facet.get("occlusion_state") == "partial" else 1.0)
        parts.append(
            f'<polygon points="{point_str}" fill="{color}" '
            f'fill-opacity="{fill_opacity:.3f}" stroke="{color}" '
            f'stroke-width="{_STROKE_WIDTH}"{dash}/>'
        )
        cx, cy = _centroid(points)
        label = sax.escape(_label_text(facet))
        parts.append(
            f'<text x="{cx:.1f}" y="{cy:.1f}" font-size="{_LABEL_FONT_SIZE}px" '
            f'font-family="sans-serif" fill="{color}" text-anchor="middle" '
            f'dominant-baseline="middle">{label}</text>'
        )

    parts.append("</svg>")
    return "\n".join(parts)


def composite_png(
    source_png: bytes, overlay_svg: str, width_px: int, height_px: int
) -> bytes:
    """Rasterize the overlay over the source RGB at source resolution.

    The overlay primitives are re-derived from the SVG markup (polygons + labels)
    and drawn with Pillow — no cairo / native SVG rasterizer. The output is a
    deterministic PNG (EXIF-free, fixed encode) at (width_px, height_px).
    """
    from PIL import Image, ImageDraw

    base = Image.open(io.BytesIO(source_png)).convert("RGBA")
    if base.size != (width_px, height_px):
        base = base.resize((width_px, height_px))

    overlay = Image.new("RGBA", (width_px, height_px), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)

    for poly in _parse_svg_polygons(overlay_svg):
        rgb = poly["color"]
        fill = (*rgb, round(255 * poly["fill_opacity"]))
        outline = (*rgb, 255)
        draw.polygon(poly["points"], fill=fill, outline=outline, width=_STROKE_WIDTH)
        cx, cy = poly["centroid"]
        draw.text((cx, cy), poly["label"], fill=outline, anchor="mm")

    flat = Image.alpha_composite(base, overlay).convert("RGB")
    out = io.BytesIO()
    # Fixed encode (no EXIF, deterministic) so the composite is a stable artifact.
    flat.save(out, format="PNG", optimize=False)
    return out.getvalue()


def _parse_svg_polygons(svg: str) -> list[dict]:
    """Re-read the polygons + labels this module emitted so the composite draws
    the EXACT same primitives. A tiny, format-specific reader (NOT a general SVG
    parser) over our own deterministic output."""
    import re

    polys: list[dict] = []
    poly_re = re.compile(
        r'<polygon points="([^"]+)" fill="(#[0-9a-fA-F]{6})" '
        r'fill-opacity="([0-9.]+)"[^/]*?/>'
    )
    text_re = re.compile(r'<text x="([0-9.]+)" y="([0-9.]+)"[^>]*>([^<]*)</text>')
    texts = [(float(m.group(1)), float(m.group(2)), m.group(3)) for m in text_re.finditer(svg)]

    for i, m in enumerate(poly_re.finditer(svg)):
        coords = [tuple(float(v) for v in pair.split(",")) for pair in m.group(1).split()]
        rgb = (int(m.group(2)[1:3], 16), int(m.group(2)[3:5], 16), int(m.group(2)[5:7], 16))
        centroid = texts[i][:2] if i < len(texts) else (0.0, 0.0)
        label = sax.unescape(texts[i][2]) if i < len(texts) else ""
        polys.append(
            {
                "points": coords,
                "color": rgb,
                "fill_opacity": float(m.group(3)),
                "centroid": centroid,
                "label": label,
            }
        )
    return polys
