"""Known-answer tests for the validation metric primitives (ADR-017 / ADR-006).

These pin the formulas the accuracy report depends on so a refactor of
metrics.py cannot silently change a published number.
"""

import math

import pytest

from validation import metrics


# --- MAPE -------------------------------------------------------------------


def test_mape_known_answer():
    # |0|/100 + |10|/100 + |5|/100 = 0 + 0.10 + 0.05 = 0.15, /3 = 0.05
    assert metrics.mape([100, 100, 100], [100, 110, 95]) == pytest.approx(0.05)


def test_mape_zero_error():
    assert metrics.mape([50.0, 200.0], [50.0, 200.0]) == pytest.approx(0.0)


def test_mape_skips_zero_truth():
    # A zero truth value is undefined for percentage error; it must be skipped,
    # not divide-by-zero. Only the second pair counts: |80-100|/100 = 0.20.
    assert metrics.mape([0.0, 100.0], [10.0, 80.0]) == pytest.approx(0.20)


def test_mape_empty_is_nan():
    assert math.isnan(metrics.mape([], []))


def test_mape_length_mismatch_raises():
    with pytest.raises(ValueError):
        metrics.mape([1.0, 2.0], [1.0])


# --- P90 --------------------------------------------------------------------


def test_p90_of_1_to_100():
    # numpy.percentile linear interpolation: P90 of 1..100 == 90.1.
    assert metrics.p90(list(range(1, 101))) == pytest.approx(90.1)


def test_p90_single_value():
    assert metrics.p90([7.0]) == pytest.approx(7.0)


def test_p90_empty_is_nan():
    assert math.isnan(metrics.p90([]))


# --- per-complexity breakdown ----------------------------------------------


def test_per_complexity_breakdown_groups_and_means():
    records = [
        {"complexity": "simple", "pct_error": 1.0},
        {"complexity": "simple", "pct_error": 3.0},
        {"complexity": "complex", "pct_error": 10.0},
    ]
    out = metrics.per_complexity_breakdown(records, "pct_error")
    assert out["simple"]["mean"] == pytest.approx(2.0)
    assert out["simple"]["count"] == 2
    assert out["complex"]["mean"] == pytest.approx(10.0)
    assert out["complex"]["count"] == 1
    assert "moderate" not in out


# --- bbox IoU ---------------------------------------------------------------


def test_bbox_iou_identical():
    assert metrics.bbox_iou([0, 0, 1, 1], [0, 0, 1, 1]) == pytest.approx(1.0)


def test_bbox_iou_quarter_contained():
    # B is the bottom-left quarter of A. intersection = 0.25, union = 1.0.
    assert metrics.bbox_iou([0, 0, 1, 1], [0, 0, 0.5, 0.5]) == pytest.approx(0.25)


def test_bbox_iou_disjoint():
    assert metrics.bbox_iou([0, 0, 0.4, 0.4], [0.6, 0.6, 1.0, 1.0]) == pytest.approx(0.0)


# --- precision / recall / f1 ------------------------------------------------


def _det(label, box, conf=0.9):
    return {"label": label, "bbox_norm": box, "confidence": conf}


def test_precision_recall_perfect_detector():
    gt = [_det("chimney", [0, 0, 0.2, 0.2]), _det("vent", [0.5, 0.5, 0.6, 0.6])]
    pred = [_det("chimney", [0, 0, 0.2, 0.2]), _det("vent", [0.5, 0.5, 0.6, 0.6])]
    out = metrics.precision_recall_f1(pred, gt)
    assert out["chimney"]["precision"] == pytest.approx(1.0)
    assert out["chimney"]["recall"] == pytest.approx(1.0)
    assert out["chimney"]["f1"] == pytest.approx(1.0)
    assert out["vent"]["recall"] == pytest.approx(1.0)


def test_precision_drops_with_false_positive():
    gt = [_det("chimney", [0, 0, 0.2, 0.2])]
    # Two predictions, only one matches -> precision 0.5, recall 1.0.
    pred = [_det("chimney", [0, 0, 0.2, 0.2]), _det("chimney", [0.8, 0.8, 0.9, 0.9])]
    out = metrics.precision_recall_f1(pred, gt)
    assert out["chimney"]["precision"] == pytest.approx(0.5)
    assert out["chimney"]["recall"] == pytest.approx(1.0)


def test_recall_drops_with_false_negative():
    gt = [_det("chimney", [0, 0, 0.2, 0.2]), _det("chimney", [0.8, 0.8, 0.9, 0.9])]
    pred = [_det("chimney", [0, 0, 0.2, 0.2])]
    out = metrics.precision_recall_f1(pred, gt)
    assert out["chimney"]["precision"] == pytest.approx(1.0)
    assert out["chimney"]["recall"] == pytest.approx(0.5)


def test_pr_values_in_unit_interval():
    gt = [_det("vent", [0, 0, 0.1, 0.1])]
    pred = [_det("vent", [0, 0, 0.1, 0.1]), _det("dormer", [0.5, 0.5, 0.7, 0.7])]
    out = metrics.precision_recall_f1(pred, gt)
    for cls, vals in out.items():
        for k in ("precision", "recall", "f1"):
            assert 0.0 <= vals[k] <= 1.0, f"{cls}.{k} out of [0,1]: {vals[k]}"


def test_iou_threshold_below_match_is_false_positive():
    # Boxes overlap but IoU < 0.5 -> no match, so precision and recall drop.
    gt = [_det("vent", [0, 0, 0.2, 0.2])]
    pred = [_det("vent", [0.15, 0.15, 0.35, 0.35])]
    out = metrics.precision_recall_f1(pred, gt, iou_threshold=0.5)
    assert out["vent"]["precision"] == pytest.approx(0.0)
    assert out["vent"]["recall"] == pytest.approx(0.0)


# --- count error ------------------------------------------------------------


def test_count_error():
    assert metrics.count_error(3, 5) == -2
    assert metrics.count_error(5, 5) == 0


# --- structural validity ----------------------------------------------------


def test_structural_validity_all_valid():
    measurement = {
        "facets": [
            {"pitch_degrees": 20.0},
            {"pitch_degrees": 35.0},
        ],
        "total_perimeter_ft": 100.0,
    }
    out = metrics.structural_validity(measurement, lidar_hull_perimeter_ft=102.0)
    assert out["pitch_valid_pct"] == pytest.approx(1.0)
    assert out["perimeter_within_tol"] is True
    assert out["facet_count_plausible"] is True


def test_structural_validity_flags_bad_pitch():
    measurement = {
        "facets": [
            {"pitch_degrees": 20.0},
            {"pitch_degrees": 85.0},  # > 70, invalid
        ],
        "total_perimeter_ft": 100.0,
    }
    out = metrics.structural_validity(measurement, lidar_hull_perimeter_ft=100.0)
    assert out["pitch_valid_pct"] == pytest.approx(0.5)


def test_structural_validity_perimeter_out_of_tol():
    measurement = {
        "facets": [{"pitch_degrees": 20.0}],
        "total_perimeter_ft": 100.0,
    }
    # 100 vs 200 is way outside +/-5%.
    out = metrics.structural_validity(measurement, lidar_hull_perimeter_ft=200.0)
    assert out["perimeter_within_tol"] is False
