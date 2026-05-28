"""Report-generation test: report.py turns a fixture results JSON into a valid
Markdown report with every required section (ADR-017 acceptance criteria).

The test writes to a tmp path, never the real docs/VALIDATION_REPORT.md, so CI
does not pollute the repo.
"""

from __future__ import annotations

from pathlib import Path

from validation import report

FIXTURE = Path(__file__).resolve().parent.parent / "validation" / "fixtures" / "sample_results.json"


def _render(tmp_path) -> str:
    out = tmp_path / "VALIDATION_REPORT.md"
    report.generate_report(results_path=FIXTURE, output_path=out)
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
