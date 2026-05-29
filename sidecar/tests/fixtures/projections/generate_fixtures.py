"""Regenerate the committed photo-projection regression fixtures.

Run from sidecar/:  uv run python tests/fixtures/projections/generate_fixtures.py

Produces, under spec/fixtures/projections/ (repo-root, the cross-language fixture
home), a deterministic synthetic-house overlay:
  - synthetic_house.svg  — the SVG overlay layer (PRIMARY regression artifact;
    a stable text diff catches any projection/styling drift).
  - synthetic_house.png  — the rasterized composite over a flat source image
    (tolerance PNG diff; pinned by the test within a small per-pixel tolerance).

The scene is a known camera + a two-facet "house roof" already in ARKit-local
coords (so the test exercises projection + occlusion-free overlay + composite
without depending on a live WGS84/UTM transform). Keep this in sync with
test_projection_regression.py.
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image

from app.render.photo_overlay import build_overlay_svg, composite_png
from app.render.photo_projection import project_facets

WIDTH, HEIGHT = 640, 480

INTRINSICS = [600.0, 0.0, 320.0, 0.0, 600.0, 240.0, 0.0, 0.0, 1.0]
EXTRINSICS = [
    1.0, 0.0, 0.0, 0.0,
    0.0, 1.0, 0.0, 0.0,
    0.0, 0.0, 1.0, 0.0,
    0.0, 0.0, 0.0, 1.0,
]

# Two roof facets (a gable), in ARKit-local metres, in front of the camera.
FACETS = [
    {
        "facet_id": "F1",
        "vertices_arkit": [[-2.0, -1.0, 6.0], [0.0, -1.6, 6.0], [0.0, 1.6, 6.0], [-2.0, 1.0, 6.0]],
        "pitch_ratio": 6.0,
        "area_sq_ft": 1200.0,
    },
    {
        "facet_id": "F2",
        "vertices_arkit": [[0.0, -1.6, 6.0], [2.0, -1.0, 6.0], [2.0, 1.0, 6.0], [0.0, 1.6, 6.0]],
        "pitch_ratio": 3.0,
        "area_sq_ft": 1100.0,
    },
]


def build() -> tuple[str, bytes]:
    projected = project_facets(FACETS, INTRINSICS, EXTRINSICS)
    for proj, src in zip(projected, FACETS):
        proj["occlusion_state"] = "visible"
        proj["pitch_ratio"] = src["pitch_ratio"]
        proj["area_sq_ft"] = src["area_sq_ft"]
    svg = build_overlay_svg(projected, width_px=WIDTH, height_px=HEIGHT)

    import io

    base = Image.new("RGB", (WIDTH, HEIGHT), (120, 140, 160))
    buf = io.BytesIO()
    base.save(buf, format="PNG")
    composite = composite_png(buf.getvalue(), svg, width_px=WIDTH, height_px=HEIGHT)
    return svg, composite


def main() -> None:
    repo_root = Path(__file__).resolve().parents[4]
    out_dir = repo_root / "spec" / "fixtures" / "projections"
    out_dir.mkdir(parents=True, exist_ok=True)
    svg, composite = build()
    (out_dir / "synthetic_house.svg").write_text(svg)
    (out_dir / "synthetic_house.png").write_bytes(composite)
    print(f"wrote {out_dir}/synthetic_house.svg and .png")


if __name__ == "__main__":
    main()
