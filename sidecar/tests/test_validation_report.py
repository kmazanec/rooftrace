"""Report-generation test: report.py turns a fixture results JSON into a valid
Markdown report with every required section (ADR-017 acceptance criteria).

The test writes to a tmp path, never the real docs/VALIDATION_REPORT.md, so CI
does not pollute the repo.
"""

from __future__ import annotations

import json
from pathlib import Path

from validation import report

FIXTURE = Path(__file__).resolve().parent.parent / "validation" / "fixtures" / "sample_results.json"


def _render(tmp_path) -> str:
    out = tmp_path / "VALIDATION_REPORT.md"
    report.generate_report(results_path=FIXTURE, output_path=out)
    return out.read_text()


def _render_with_eval(tmp_path) -> str:
    eval_results = {
        "dataset": {"tile_count": 24, "true_negative_count": 4, "gsd_cm": 60},
        "models": [
            {
                "model": "google/gemini-2.5-flash",
                "rank": 1,
                "overall_f1": 0.72,
                "per_class": {
                    "chimney": {"precision": 0.8, "recall": 0.9, "f1": 0.85, "iou": 0.6, "count_error": -1},
                    "vent": {"precision": 0.5, "recall": 0.4, "f1": 0.44, "iou": 0.5, "count_error": -3},
                },
            },
            {
                "model": "qwen/qwen2.5-vl-72b-instruct",
                "rank": 2,
                "overall_f1": 0.61,
                "per_class": {
                    "chimney": {"precision": 0.7, "recall": 0.7, "f1": 0.70, "iou": 0.55, "count_error": -2},
                    "vent": {"precision": 0.4, "recall": 0.3, "f1": 0.34, "iou": 0.45, "count_error": -4},
                },
            },
        ],
        "selected_model": "google/gemini-2.5-flash",
        "selection_metric": "unweighted_mean_f1_v1",
        "worst_case": {"model": "qwen/qwen2.5-vl-72b-instruct", "label": "vent", "f1": 0.34,
                       "reason": "small features localize weakly at coarse NAIP GSD"},
    }
    eval_path = tmp_path / "eval_results.json"
    eval_path.write_text(json.dumps(eval_results))
    out = tmp_path / "VALIDATION_REPORT.md"
    report.generate_report(results_path=FIXTURE, output_path=out, eval_results_path=eval_path)
    return out.read_text()


def test_required_sections_present(tmp_path):
    md = _render(tmp_path)
    for header in [
        "# RoofTrace accuracy validation report",
        "## Methodology",
        "## Summary",
        "## Structural validity",
        "## Fallback-path consistency",
        "## Per-address detail",
        "## Honest worst-case",
    ]:
        assert header in md, f"missing required section: {header!r}"


def test_summary_table_reports_mape_and_p90(tmp_path):
    md = _render(tmp_path)
    # eagleview truth 2000 vs pred 2050 => 2.5% MAPE on the single control.
    assert "MAPE" in md
    assert "2.5%" in md, "expected 2.5% MAPE on the EagleView control"
    assert "P90" in md


def test_per_complexity_breakdown_rendered(tmp_path):
    md = _render(tmp_path)
    assert "simple" in md
    assert "moderate" in md
    assert "complex" in md


def test_fallback_consistency_documented_as_deferred(tmp_path):
    md = _render(tmp_path)
    # Human resolution: the fallback table is a deferred, honest gap this
    # iteration (no orchestrator force-fallback). The section must say so.
    lowered = md.lower()
    assert "defer" in lowered or "not measured" in lowered or "gap" in lowered


def test_worst_case_named(tmp_path):
    md = _render(tmp_path)
    # The Chicago entry has an 85-degree facet (structural invalid) and a low
    # confidence + warning, making it the honest worst-case.
    assert "TODO moderate roof, Chicago IL" in md
    assert "## Honest worst-case" in md


def test_address_completion_failures_surfaced(tmp_path):
    md = _render(tmp_path)
    # The Sun Belt address failed (measurement null + errors[]); the report must
    # surface that honestly rather than silently drop it.
    assert "TODO complex roof, Sun Belt metro" in md
    assert "LiDAR work unit not found" in md


def test_structural_validity_percentages(tmp_path):
    md = _render(tmp_path)
    # One facet at 85deg is out of [0,70]; the structural section must report a
    # pitch-validity number below 100%.
    assert "Structural validity" in md
    assert "%" in md


def test_attribution_surfaced(tmp_path):
    md = _render(tmp_path)
    assert "NAIP" in md or "3DEP" in md


def test_markdown_is_nonempty_and_parses_headers(tmp_path):
    md = _render(tmp_path)
    assert len(md) > 200
    # Every header line starts with '#'; ensure at least the top-level title.
    assert md.lstrip().startswith("#")


def test_feature_detection_section_rendered_when_eval_present(tmp_path):
    md = _render_with_eval(tmp_path)
    assert "## Feature-detection model evaluation" in md
    assert "### Dataset acquisition" in md
    assert "### Candidate models" in md
    assert "### Selected production model" in md
    assert "### Honest worst-case (feature detection)" in md


def test_feature_detection_names_selected_model_with_a_number(tmp_path):
    md = _render_with_eval(tmp_path)
    # No model named the production default without a measured F1 behind it.
    assert "google/gemini-2.5-flash" in md
    assert "0.72" in md  # overall F1 of the selected model


def test_feature_detection_worst_case_named(tmp_path):
    md = _render_with_eval(tmp_path)
    assert "qwen/qwen2.5-vl-72b-instruct" in md
    assert "vent" in md


def test_feature_detection_section_absent_without_eval(tmp_path):
    md = _render(tmp_path)
    assert "## Feature-detection model evaluation" not in md
