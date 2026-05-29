"""Visual-regression test for the committed photo-projection fixtures (ADR-019).

Re-renders the synthetic_house scene (the SAME scene generate_fixtures.py pins)
and compares against the committed artifacts under spec/fixtures/projections/:
  - the SVG must match EXACTLY (the primary regression artifact; a stable text
    diff catches any projection-math / styling drift), and
  - the composite PNG must match within a small per-pixel tolerance (encoders can
    vary by a bit; the overlay geometry must not).

If the render legitimately changes, regenerate the fixtures:
    uv run python tests/fixtures/projections/generate_fixtures.py
and review the diff.
"""

from __future__ import annotations

import io
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

from tests.fixtures.projections.generate_fixtures import build

REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURES = REPO_ROOT / "spec" / "fixtures" / "projections"

# Mean absolute per-channel pixel difference allowed between the committed and
# freshly-rendered composite (encoder slack; the overlay geometry is exact).
_MEAN_ABS_TOLERANCE = 2.0


@pytest.fixture(scope="module")
def rendered():
    return build()


def test_committed_fixtures_exist():
    assert (FIXTURES / "synthetic_house.svg").is_file()
    assert (FIXTURES / "synthetic_house.png").is_file()


def test_svg_matches_committed_exactly(rendered):
    svg, _ = rendered
    committed = (FIXTURES / "synthetic_house.svg").read_text()
    assert svg == committed, "SVG overlay drifted; regenerate the fixtures if intended"


def test_composite_png_within_tolerance(rendered):
    _, composite = rendered
    committed = (FIXTURES / "synthetic_house.png").read_bytes()

    a = np.asarray(Image.open(io.BytesIO(composite)).convert("RGB"), dtype=np.float64)
    b = np.asarray(Image.open(io.BytesIO(committed)).convert("RGB"), dtype=np.float64)
    assert a.shape == b.shape, (a.shape, b.shape)
    assert float(np.mean(np.abs(a - b))) <= _MEAN_ABS_TOLERANCE
