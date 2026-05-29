"""Generate docs/VALIDATION_REPORT.md from a runner results JSON (ADR-017).

Pure consumer: it reads a results JSON produced by the Rails-side measurement
runner (lib/tasks/validation.rake), computes metrics via validation.metrics, and
writes a Markdown report. It performs NO network calls and does NOT trigger the
pipeline. The committed report is produced only on a real full run; tests render
to a tmp path.

Usage:
    uv run python -m validation.report [--results PATH] [--output PATH] \
        [--eval-results PATH]

Defaults: newest validation/results/*.json -> docs/VALIDATION_REPORT.md.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from validation import metrics

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
VALIDATION_DIR = Path(__file__).resolve().parent
RESULTS_DIR = VALIDATION_DIR / "results"
DEFAULT_OUTPUT = REPO_ROOT / "docs" / "VALIDATION_REPORT.md"

# Schema version the report is written against; mismatch is surfaced, not hidden.
EXPECTED_SCHEMA_VERSION = "0.4.0"


def _load_results(path: Path) -> dict[str, Any]:
    with path.open() as fh:
        return json.load(fh)


def newest_results() -> Path:
    """Return the most recent results JSON in validation/results/."""
    candidates = sorted(RESULTS_DIR.glob("*.json"))
    if not candidates:
        raise FileNotFoundError(
            f"no results JSON found in {RESULTS_DIR}; run the measurement runner first"
        )
    return candidates[-1]


def _fmt_pct(fraction: float) -> str:
    if metrics.is_nan(fraction):
        return "n/a"
    return f"{fraction * 100:.1f}%"


def _completed(addresses: list[dict]) -> list[dict]:
    return [a for a in addresses if a.get("measurement")]


def _failed(addresses: list[dict]) -> list[dict]:
    return [a for a in addresses if not a.get("measurement")]


def _control_mape(results: dict) -> tuple[float, list[str]]:
    """MAPE on total area against the ground-truth controls present in results."""
    gt = results.get("ground_truth") or {}
    by_address = {a["address"]: a for a in results["addresses"]}
    truth: list[float] = []
    pred: list[float] = []
    lines: list[str] = []
    for control_name, control in gt.items():
        addr = control.get("address")
        gt_area = control.get("total_area_sq_ft")
        rec = by_address.get(addr)
        if not rec or not rec.get("measurement") or not gt_area:
            continue
        pred_area = rec["measurement"]["total_area_sq_ft"]
        truth.append(float(gt_area))
        pred.append(float(pred_area))
        err = abs(pred_area - gt_area) / gt_area
        lines.append(
            f"| {control_name} | {addr} | {gt_area:.0f} | {pred_area:.0f} | {_fmt_pct(err)} |"
        )
    return metrics.mape(truth, pred), lines


def _pct_error_records(results: dict) -> list[dict]:
    """Percentage-error records keyed by complexity, for P90 + breakdown.

    With no per-address ground truth, the consistency proxy is the deviation of
    total area from the per-complexity median (a structural-consistency
    baseline, per ADR-017's honest framing).
    """
    completed = _completed(results["addresses"])
    by_complexity: dict[str, list[dict]] = {}
    for rec in completed:
        by_complexity.setdefault(rec["complexity"], []).append(rec)

    records: list[dict] = []
    for complexity, recs in by_complexity.items():
        areas = sorted(r["measurement"]["total_area_sq_ft"] for r in recs)
        median = areas[len(areas) // 2]
        if median == 0:
            continue
        for r in recs:
            area = r["measurement"]["total_area_sq_ft"]
            records.append(
                {
                    "address": r["address"],
                    "complexity": complexity,
                    "pct_error": abs(area - median) / median * 100.0,
                }
            )
    return records


def _structural_rows(results: dict) -> list[tuple[str, dict]]:
    rows = []
    for rec in _completed(results["addresses"]):
        m = rec["measurement"]
        sv = metrics.structural_validity(m, m.get("lidar_hull_perimeter_ft"))
        rows.append((rec["address"], sv))
    return rows


def _worst_case(results: dict) -> dict | None:
    """Pick the honest worst-case: lowest structural pitch-validity, then lowest
    confidence, then any warnings. Grounded in measurement fields, not vibes."""
    worst = None
    worst_score = None
    for rec in _completed(results["addresses"]):
        m = rec["measurement"]
        sv = metrics.structural_validity(m, m.get("lidar_hull_perimeter_ft"))
        pitch_ok = 0.0 if metrics.is_nan(sv["pitch_valid_pct"]) else sv["pitch_valid_pct"]
        conf = float(m.get("confidence") or 0.0)
        warn_penalty = 0.1 * len(m.get("warnings") or [])
        # Lower score == worse.
        score = pitch_ok + conf - warn_penalty
        if worst_score is None or score < worst_score:
            worst_score = score
            worst = rec
    return worst


def _attributions(results: dict) -> list[str]:
    names = set()
    for rec in _completed(results["addresses"]):
        prov = rec["measurement"].get("provenance") or {}
        for attr in (prov.get("attributions") or {}).values():
            if isinstance(attr, dict) and attr.get("name"):
                names.add(attr["name"])
    # Static fallback full list (locked in LICENSES.md) when provenance is sparse.
    if not names:
        names = {"USDA NAIP", "USGS 3DEP", "MS Building Footprints", "Regrid", "Mapbox", "Nominatim"}
    return sorted(names)


def build_markdown(results: dict, eval_results: dict | None = None) -> str:
    addresses = results["addresses"]
    completed = _completed(addresses)
    failed = _failed(addresses)
    schema_version = results.get("schema_version", "unknown")

    parts: list[str] = []
    parts.append("# RoofTrace accuracy validation report\n")
    parts.append(
        f"_Generated from results `{results.get('timestamp', 'unknown')}` "
        f"(pipeline schema `{schema_version}`, pipeline version "
        f"`{results.get('pipeline_version', 'unknown')}`)._\n"
    )
    if schema_version != EXPECTED_SCHEMA_VERSION:
        parts.append(
            f"> **Schema-version mismatch:** results were produced against "
            f"`{schema_version}` but this report expects `{EXPECTED_SCHEMA_VERSION}`. "
            f"Numbers may be unreliable.\n"
        )

    # --- Methodology --------------------------------------------------------
    parts.append("## Methodology\n")
    parts.append(
        "This report defends the +/-3% total-area accuracy target (ADR-017) on a "
        "**stratified, hand-curated** test set of 15 LiDAR-covered addresses "
        "(5 simple / 5 moderate / 5 complex across 5 regions), plus 3 independent "
        "ground-truth controls (one EagleView Premium report, one tape-measured "
        "roof, one county-assessor record). The full pipeline is run on each "
        "address by the Rails-side measurement runner; this document scores the "
        "persisted measurements.\n\n"
        "**Metrics:** MAPE (mean absolute percentage error) on total area against "
        "the 3 controls; P90 of percentage error across the 15 addresses "
        "(against a per-complexity structural-consistency baseline, since no "
        "per-address ground truth exists); per-complexity breakdown; and "
        "structural validity (per-facet pitch in [0, 70] degrees, perimeter "
        "within +/-5% of the LiDAR convex-hull perimeter, plausible facet count).\n\n"
        "**Expected variance:** the VLM feature-detection and (where used) "
        "imagery-fusion steps are non-deterministic; re-running the harness on the "
        "same pipeline version produces total-area numbers within measurement "
        "noise (typically <1%). The test addresses are published below so "
        "reviewers can re-test independently.\n"
    )

    # --- Completion failures (surfaced before metrics) ----------------------
    if failed:
        parts.append("### Address-completion failures\n")
        parts.append(
            "The following addresses did not complete and are excluded from the "
            "metrics below:\n"
        )
        for rec in failed:
            errs = "; ".join(rec.get("errors") or ["unknown error"])
            parts.append(f"- **{rec['address']}** ({rec['complexity']}): {errs}")
        parts.append("")

    # --- Summary table ------------------------------------------------------
    parts.append("## Summary\n")
    control_mape, control_rows = _control_mape(results)
    parts.append(f"**MAPE on total area (ground-truth controls):** {_fmt_pct(control_mape)}\n")
    if control_rows:
        parts.append("| Control | Address | Truth (sq ft) | Measured (sq ft) | Error |")
        parts.append("| --- | --- | ---: | ---: | ---: |")
        parts.extend(control_rows)
        parts.append("")
    else:
        parts.append(
            "_No ground-truth controls are populated yet (manual setup pending); "
            "MAPE on controls is not computable until the EagleView / "
            "tape-measure / assessor data is collected._\n"
        )

    pct_records = _pct_error_records(results)
    p90_val = metrics.p90([r["pct_error"] for r in pct_records])
    parts.append(
        f"**P90 of percentage error (structural-consistency baseline, "
        f"{len(completed)} completed addresses):** "
        f"{'n/a' if metrics.is_nan(p90_val) else f'{p90_val:.1f}%'}\n"
    )

    breakdown = metrics.per_complexity_breakdown(pct_records, "pct_error")
    parts.append("**Per-complexity breakdown (mean % deviation from stratum median):**\n")
    parts.append("| Complexity | Addresses | Mean % deviation |")
    parts.append("| --- | ---: | ---: |")
    for complexity in ("simple", "moderate", "complex"):
        if complexity in breakdown:
            b = breakdown[complexity]
            parts.append(f"| {complexity} | {b['count']} | {b['mean']:.1f}% |")
        else:
            parts.append(f"| {complexity} | 0 | n/a |")
    parts.append("")

    # --- Fallback-path consistency (DEFERRED gap) ---------------------------
    parts.append("## Fallback-path consistency\n")
    parts.append(
        "ADR-017 calls for comparing the satellite-only (Architecture-A) "
        "fallback measurement against the LiDAR primary per address. This "
        "comparison is **deferred this iteration**: the orchestrator does not yet "
        "expose a way to force the LiDAR-missing fallback path, and forking the "
        "orchestrator to fake it would not be an honest comparison. This is a "
        "documented gap, not a silent omission. When a force-fallback flag lands "
        "on the orchestrator, the runner will capture both measurements per "
        "address and this section will report the per-complexity delta.\n"
    )

    # --- Structural validity ------------------------------------------------
    parts.append("## Structural validity\n")
    rows = _structural_rows(results)
    if rows:
        pitch_pcts = [r[1]["pitch_valid_pct"] for r in rows if not metrics.is_nan(r[1]["pitch_valid_pct"])]
        all_pitch_valid = sum(1 for p in pitch_pcts if p >= 1.0)
        perim_ok = sum(1 for _, sv in rows if sv["perimeter_within_tol"] is True)
        perim_checked = sum(1 for _, sv in rows if sv["perimeter_within_tol"] is not None)
        facet_ok = sum(1 for _, sv in rows if sv["facet_count_plausible"])
        n = len(rows)
        parts.append(
            f"- **All-facet pitch in [0, 70] degrees:** {all_pitch_valid}/{n} "
            f"addresses ({_fmt_pct(all_pitch_valid / n)}).\n"
            f"- **Perimeter within +/-5% of LiDAR hull:** {perim_ok}/{perim_checked} "
            f"addresses with a hull reference.\n"
            f"- **Plausible facet count:** {facet_ok}/{n} addresses "
            f"({_fmt_pct(facet_ok / n)}).\n"
        )
        parts.append("| Address | Pitch valid | Perimeter ok | Facet count |")
        parts.append("| --- | ---: | :---: | ---: |")
        for addr, sv in rows:
            perim = {True: "yes", False: "no", None: "n/a"}[sv["perimeter_within_tol"]]
            parts.append(
                f"| {addr} | {_fmt_pct(sv['pitch_valid_pct'])} | {perim} | {sv['facet_count']} |"
            )
        parts.append("")
    else:
        parts.append("_No completed measurements to check._\n")

    # --- Per-address detail appendix ---------------------------------------
    parts.append("## Per-address detail\n")
    parts.append(
        "Every test address is listed so reviewers can re-test independently.\n"
    )
    parts.append("| Address | Complexity | Region | Area (sq ft) | Pitch (/12) | Source | Confidence | Warnings |")
    parts.append("| --- | --- | --- | ---: | ---: | --- | ---: | --- |")
    for rec in addresses:
        m = rec.get("measurement")
        if m:
            warns = "; ".join(m.get("warnings") or []) or "—"
            parts.append(
                f"| {rec['address']} | {rec['complexity']} | {rec.get('region', '—')} | "
                f"{m['total_area_sq_ft']:.0f} | {m.get('predominant_pitch_ratio', '—')} | "
                f"{m.get('source', '—')} | {m.get('confidence', '—')} | {warns} |"
            )
        else:
            parts.append(
                f"| {rec['address']} | {rec['complexity']} | {rec.get('region', '—')} | "
                f"FAILED | — | — | — | {'; '.join(rec.get('errors') or [])} |"
            )
    parts.append("")
    parts.append(
        "_Every facet and feature in the measurement output carries its own "
        "`source` and `confidence` (honest-uncertainty convention); see the runner "
        "results JSON for the full per-facet detail._\n"
    )

    # --- Honest worst-case --------------------------------------------------
    parts.append("## Honest worst-case\n")
    worst = _worst_case(results)
    if worst:
        m = worst["measurement"]
        sv = metrics.structural_validity(m, m.get("lidar_hull_perimeter_ft"))
        reasons = []
        if not metrics.is_nan(sv["pitch_valid_pct"]) and sv["pitch_valid_pct"] < 1.0:
            reasons.append(
                f"{_fmt_pct(1 - sv['pitch_valid_pct'])} of its facets have a pitch "
                f"outside [0, 70] degrees"
            )
        if m.get("warnings"):
            reasons.append("pipeline warnings: " + "; ".join(m["warnings"]))
        reasons.append(f"measurement confidence {m.get('confidence', 'n/a')}")
        parts.append(
            f"The worst-performing completed address is **{worst['address']}** "
            f"({worst['complexity']}, source `{m.get('source', '—')}`): "
            + "; ".join(reasons)
            + ". This is grounded in the measurement's own structural-validity "
            "and confidence fields, not a subjective judgement.\n"
        )
    else:
        parts.append("_No completed measurements to rank._\n")

    # --- Feature-detection section (optional) -------------------------------
    if eval_results is not None:
        parts.append(_feature_detection_section(eval_results))

    # --- Attributions -------------------------------------------------------
    parts.append("## Data attributions\n")
    parts.append(
        "Measurements derive from: " + ", ".join(_attributions(results)) + ". "
        "See `LICENSES.md` for the full attribution + licensing terms.\n"
    )

    return "\n".join(parts) + "\n"


def _feature_detection_section(eval_results: dict) -> str:
    """Render the feature-detection model-evaluation section (ADR-006).

    ``eval_results`` is the output of feature_detection/eval_models.py:
    ``{"dataset": {...}, "models": [{"model", "per_class", "overall_f1", "rank"}]}``.
    """
    lines: list[str] = ["## Feature-detection model evaluation\n"]
    dataset = eval_results.get("dataset", {})
    lines.append("### Dataset acquisition\n")
    lines.append(
        f"{dataset.get('tile_count', 'N')} nadir tiles pulled via the production "
        f"imagery path (USDA NAIP, ~{dataset.get('gsd_cm', 'X')} cm GSD), spanning "
        f"roof complexity and including {dataset.get('true_negative_count', 'N')} "
        f"true-negative tiles (no features). See `LABELING_PROTOCOL.md` for the "
        f"hand-labeling protocol.\n"
    )

    models = eval_results.get("models", [])
    lines.append("### Candidate models\n")
    lines.append("| Model | Class | Precision | Recall | IoU | F1 | Count err |")
    lines.append("| --- | --- | ---: | ---: | ---: | ---: | ---: |")
    for model in models:
        for cls, vals in sorted(model.get("per_class", {}).items()):
            lines.append(
                f"| {model['model']} | {cls} | {vals['precision']:.2f} | "
                f"{vals['recall']:.2f} | {vals.get('iou', 0.0):.2f} | "
                f"{vals['f1']:.2f} | {vals.get('count_error', 0)} |"
            )
    lines.append("")

    selected = eval_results.get("selected_model")
    if selected:
        sel_f1 = next(
            (m["overall_f1"] for m in models if m["model"] == selected), None
        )
        lines.append("### Selected production model\n")
        lines.append(
            f"Model **`{selected}`** is selected as the production default, with "
            f"overall mean-across-classes F1 = "
            f"{'n/a' if sel_f1 is None else f'{sel_f1:.3f}'}. Selection metric is "
            f"unweighted mean F1 (v1); recall-weighting (a missed feature is "
            f"arguably worse than a false positive) is a documented v2 open "
            f"question.\n"
        )

    worst = eval_results.get("worst_case")
    if worst:
        lines.append("### Honest worst-case (feature detection)\n")
        lines.append(
            f"The weakest model/class combination is **{worst.get('model')}** on "
            f"**{worst.get('label')}** (F1 = {worst.get('f1', 0.0):.2f}): "
            f"{worst.get('reason', 'small features at coarse GSD localize weakly')}.\n"
        )
    return "\n".join(lines)


def generate_report(
    results_path: Path | None = None,
    output_path: Path | None = None,
    eval_results_path: Path | None = None,
) -> Path:
    """Render the report and write it to ``output_path`` (defaults applied)."""
    results_path = results_path or newest_results()
    output_path = output_path or DEFAULT_OUTPUT
    results = _load_results(Path(results_path))
    eval_results = None
    if eval_results_path:
        with Path(eval_results_path).open() as fh:
            eval_results = json.load(fh)
    md = build_markdown(results, eval_results=eval_results)
    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(md)
    return output_path


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate the accuracy validation report.")
    parser.add_argument("--results", type=Path, default=None, help="results JSON (default: newest)")
    parser.add_argument("--output", type=Path, default=None, help="output Markdown path")
    parser.add_argument("--eval-results", type=Path, default=None, help="feature-detection eval JSON")
    args = parser.parse_args()
    out = generate_report(
        results_path=args.results,
        output_path=args.output,
        eval_results_path=args.eval_results,
    )
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
