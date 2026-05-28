"""Pure-function accuracy metrics for the validation harness (ADR-017 / ADR-006).

Every function here is deterministic and side-effect free: no network, no file
I/O. The report generator (report.py) and the feature-detection scorer
(feature_detection/eval_models.py) compose these primitives so the published
numbers in docs/VALIDATION_REPORT.md have a single, unit-tested definition.

Conventions:
- Bounding boxes are normalized ``[x0, y0, x1, y1]`` in ``[0, 1]`` image space,
  matching the ``Feature.bbox_norm`` convention in shared/pipeline_schema.json.
- Detections are dicts with at least ``label`` and ``bbox_norm`` keys.
- Pitch validity uses degrees in ``[0, 70]`` (the structural bound from ADR-017).
"""

from __future__ import annotations

import math
from collections import defaultdict
from typing import Any

import numpy as np

# Per-facet pitch is structurally implausible outside this range (ADR-017).
PITCH_MIN_DEG = 0.0
PITCH_MAX_DEG = 70.0
# Perimeter is "consistent" with the LiDAR convex-hull perimeter within +/-5%.
PERIMETER_TOLERANCE = 0.05
# A plausible single-roof facet count (visual-inspection sanity bound, ADR-017).
FACET_COUNT_MIN = 1
FACET_COUNT_MAX = 40
# IoU at/above which a predicted box is considered to match a ground-truth box.
DEFAULT_IOU_THRESHOLD = 0.5


def mape(truth: list[float], pred: list[float]) -> float:
    """Mean Absolute Percentage Error as a fraction (0.05 == 5%).

    ``mean( |pred_i - truth_i| / |truth_i| )`` over all pairs where
    ``truth_i != 0``. Pairs with a zero truth value are skipped (percentage
    error is undefined there). Returns ``nan`` when no usable pair exists.
    """
    if len(truth) != len(pred):
        raise ValueError(f"length mismatch: {len(truth)} truth vs {len(pred)} pred")
    errors = [
        abs(p - t) / abs(t)
        for t, p in zip(truth, pred)
        if t != 0
    ]
    if not errors:
        return float("nan")
    return float(np.mean(errors))


def p90(values: list[float]) -> float:
    """90th percentile via numpy linear interpolation (``numpy.percentile``, q=90).

    The interpolation method is numpy's default ('linear'): P90 of 1..100 is
    90.1, not 90. Returns ``nan`` on an empty input.
    """
    if not values:
        return float("nan")
    return float(np.percentile(np.asarray(values, dtype=float), 90))


def per_complexity_breakdown(records: list[dict[str, Any]], key: str) -> dict[str, dict[str, Any]]:
    """Group ``records`` by their ``complexity`` field and aggregate ``key``.

    Returns ``{complexity: {"mean": float, "count": int}}`` for each complexity
    stratum that actually appears in the records.
    """
    groups: dict[str, list[float]] = defaultdict(list)
    for rec in records:
        complexity = rec.get("complexity")
        value = rec.get(key)
        if complexity is None or value is None:
            continue
        groups[complexity].append(float(value))
    return {
        complexity: {"mean": float(np.mean(vals)), "count": len(vals)}
        for complexity, vals in groups.items()
    }


def bbox_iou(box_a: list[float], box_b: list[float]) -> float:
    """Intersection-over-Union of two normalized ``[x0, y0, x1, y1]`` boxes.

    Returns 0.0 for disjoint boxes or a degenerate (zero-area) union.
    """
    ax0, ay0, ax1, ay1 = box_a
    bx0, by0, bx1, by1 = box_b

    ix0 = max(ax0, bx0)
    iy0 = max(ay0, by0)
    ix1 = min(ax1, bx1)
    iy1 = min(ay1, by1)

    iw = max(0.0, ix1 - ix0)
    ih = max(0.0, iy1 - iy0)
    inter = iw * ih
    if inter <= 0.0:
        return 0.0

    area_a = max(0.0, ax1 - ax0) * max(0.0, ay1 - ay0)
    area_b = max(0.0, bx1 - bx0) * max(0.0, by1 - by0)
    union = area_a + area_b - inter
    if union <= 0.0:
        return 0.0
    return float(inter / union)


def precision_recall_f1(
    pred_dets: list[dict[str, Any]],
    gt_dets: list[dict[str, Any]],
    iou_threshold: float = DEFAULT_IOU_THRESHOLD,
) -> dict[str, dict[str, float]]:
    """Per-class precision / recall / F1 via greedy same-class IoU matching.

    A predicted detection matches a ground-truth detection when they share a
    ``label`` and their ``bbox_norm`` IoU is ``>= iou_threshold``. Matching is
    greedy: predictions are matched to the highest-IoU unused ground-truth box.

    Returns ``{label: {"precision", "recall", "f1", "tp", "fp", "fn"}}`` for
    every label appearing in either the predictions or the ground truth.
    """
    labels = {d["label"] for d in pred_dets} | {d["label"] for d in gt_dets}
    out: dict[str, dict[str, float]] = {}

    for label in labels:
        preds = [d for d in pred_dets if d["label"] == label]
        gts = [d for d in gt_dets if d["label"] == label]
        matched_gt: set[int] = set()
        tp = 0

        # Process predictions highest-confidence first so a greedy match is stable.
        preds_sorted = sorted(preds, key=lambda d: d.get("confidence", 0.0), reverse=True)
        for pred in preds_sorted:
            best_iou = 0.0
            best_idx = -1
            for gi, gt in enumerate(gts):
                if gi in matched_gt:
                    continue
                iou = bbox_iou(pred["bbox_norm"], gt["bbox_norm"])
                if iou >= iou_threshold and iou > best_iou:
                    best_iou = iou
                    best_idx = gi
            if best_idx >= 0:
                matched_gt.add(best_idx)
                tp += 1

        fp = len(preds) - tp
        fn = len(gts) - tp
        precision = tp / (tp + fp) if (tp + fp) > 0 else 0.0
        recall = tp / (tp + fn) if (tp + fn) > 0 else 0.0
        f1 = (
            2 * precision * recall / (precision + recall)
            if (precision + recall) > 0
            else 0.0
        )
        out[label] = {
            "precision": precision,
            "recall": recall,
            "f1": f1,
            "tp": float(tp),
            "fp": float(fp),
            "fn": float(fn),
        }
    return out


def count_error(pred_count: int, gt_count: int) -> int:
    """Signed count error ``pred - gt`` (negative == under-counted)."""
    return int(pred_count) - int(gt_count)


def structural_validity(
    measurement: dict[str, Any],
    lidar_hull_perimeter_ft: float | None = None,
) -> dict[str, Any]:
    """Structural-consistency checks for one measurement (ADR-017).

    - ``pitch_valid_pct``: fraction of facets whose ``pitch_degrees`` lies in
      ``[0, 70]``.
    - ``perimeter_within_tol``: whether ``total_perimeter_ft`` is within +/-5%
      of the LiDAR convex-hull perimeter (``None`` when no hull perimeter given).
    - ``facet_count_plausible``: whether the facet count is in a plausible range
      for a single roof.
    """
    facets = measurement.get("facets") or []
    if facets:
        valid = sum(
            1
            for f in facets
            if PITCH_MIN_DEG <= float(f.get("pitch_degrees", -1)) <= PITCH_MAX_DEG
        )
        pitch_valid_pct = valid / len(facets)
    else:
        pitch_valid_pct = float("nan")

    perimeter_within_tol: bool | None
    perimeter = measurement.get("total_perimeter_ft")
    if lidar_hull_perimeter_ft is None or perimeter is None or lidar_hull_perimeter_ft == 0:
        perimeter_within_tol = None
    else:
        rel = abs(float(perimeter) - lidar_hull_perimeter_ft) / abs(lidar_hull_perimeter_ft)
        perimeter_within_tol = rel <= PERIMETER_TOLERANCE

    facet_count_plausible = FACET_COUNT_MIN <= len(facets) <= FACET_COUNT_MAX

    return {
        "pitch_valid_pct": pitch_valid_pct,
        "perimeter_within_tol": perimeter_within_tol,
        "facet_count_plausible": facet_count_plausible,
        "facet_count": len(facets),
    }


def is_nan(x: float) -> bool:
    """Small helper so callers don't import math just for nan checks."""
    return isinstance(x, float) and math.isnan(x)
