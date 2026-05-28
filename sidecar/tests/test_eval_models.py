"""Tests the feature-detection model scorer (ADR-006).

Deterministic fixtures: a tiny labels.json + two predictions JSONs (one perfect,
one with a known FP/FN). No live VLM calls. Asserts per-class metrics are in
range, overall F1 is computed, ranks are assigned, and the perfect model wins.
"""

from __future__ import annotations

import json

import pytest

from validation.feature_detection import eval_models


@pytest.fixture
def labels(tmp_path):
    data = {
        "tiles": {
            "t1": {
                "image_path": "imagery/t1.png",
                "features": [
                    {"label": "chimney", "bbox_norm": [0.1, 0.1, 0.2, 0.2]},
                    {"label": "vent", "bbox_norm": [0.5, 0.5, 0.55, 0.55]},
                ],
            },
            "t2": {"image_path": "imagery/t2.png", "features": []},
        }
    }
    p = tmp_path / "labels.json"
    p.write_text(json.dumps(data))
    return p


def _write_predictions(tmp_path, slug, tiles):
    p = tmp_path / f"predictions_{slug}.json"
    p.write_text(json.dumps({"model": slug, "tiles": tiles}))
    return p


@pytest.fixture
def perfect_predictions(tmp_path):
    return _write_predictions(
        tmp_path,
        "perfect",
        {
            "t1": [
                {"label": "chimney", "bbox_norm": [0.1, 0.1, 0.2, 0.2], "confidence": 0.9},
                {"label": "vent", "bbox_norm": [0.5, 0.5, 0.55, 0.55], "confidence": 0.9},
            ],
            "t2": [],
        },
    )


@pytest.fixture
def flawed_predictions(tmp_path):
    # Misses the vent on t1 (FN) and hallucinates a chimney on t2 (FP).
    return _write_predictions(
        tmp_path,
        "flawed",
        {
            "t1": [
                {"label": "chimney", "bbox_norm": [0.1, 0.1, 0.2, 0.2], "confidence": 0.8},
            ],
            "t2": [
                {"label": "chimney", "bbox_norm": [0.7, 0.7, 0.8, 0.8], "confidence": 0.6},
            ],
        },
    )


def test_score_perfect_model_all_ones(labels, perfect_predictions):
    result = eval_models.score_model(labels, perfect_predictions)
    assert result["model"] == "perfect"
    for cls in ("chimney", "vent"):
        pc = result["per_class"][cls]
        assert pc["precision"] == pytest.approx(1.0)
        assert pc["recall"] == pytest.approx(1.0)
        assert pc["f1"] == pytest.approx(1.0)
    assert result["overall_f1"] == pytest.approx(1.0)


def test_score_flawed_model_penalized(labels, flawed_predictions):
    result = eval_models.score_model(labels, flawed_predictions)
    # chimney: 1 TP (t1) + 1 FP (t2) -> precision 0.5, recall 1.0.
    chimney = result["per_class"]["chimney"]
    assert chimney["precision"] == pytest.approx(0.5)
    assert chimney["recall"] == pytest.approx(1.0)
    # vent: 0 TP, 1 FN -> recall 0.0.
    vent = result["per_class"]["vent"]
    assert vent["recall"] == pytest.approx(0.0)
    assert result["overall_f1"] < 1.0


def test_metrics_in_unit_interval(labels, flawed_predictions):
    result = eval_models.score_model(labels, flawed_predictions)
    for cls, vals in result["per_class"].items():
        for k in ("precision", "recall", "f1", "iou"):
            assert 0.0 <= vals[k] <= 1.0, f"{cls}.{k} out of [0,1]: {vals[k]}"


def test_evaluate_ranks_and_selects_best(tmp_path, labels, perfect_predictions, flawed_predictions):
    out_path = tmp_path / "eval_results.json"
    result = eval_models.evaluate(
        labels_path=labels,
        prediction_paths=[flawed_predictions, perfect_predictions],
        output_path=out_path,
    )
    models = {m["model"]: m for m in result["models"]}
    assert models["perfect"]["rank"] == 1
    assert models["flawed"]["rank"] == 2
    assert result["selected_model"] == "perfect"
    # Worst-case names a real model/class combination with a number.
    assert result["worst_case"]["model"] in ("perfect", "flawed")
    assert "f1" in result["worst_case"]
    # Output JSON was written.
    written = json.loads(out_path.read_text())
    assert written["selected_model"] == "perfect"
    assert "dataset" in written


def test_error_tile_excluded_not_scored_as_misses(tmp_path, labels):
    # A tile whose prediction is an error record (upload/detection failure) must
    # be excluded from scoring, not counted as all-FN. Here t1 errored; only t2
    # (a true negative the model got right) contributes, so chimney/vent recall
    # is NOT dragged to 0 by phantom FNs.
    preds = _write_predictions(
        tmp_path,
        "with_error",
        {
            "t1": {"error": "Aws::S3::Errors::ServiceError: timeout"},
            "t2": [],
        },
    )
    with pytest.warns(UserWarning, match="excluded from scoring"):
        result = eval_models.score_model(labels, preds)
    assert result["excluded_tile_count"] == 1
    # t1's chimney + vent GT boxes were excluded, not scored as FN.
    assert "chimney" not in result["per_class"]
    assert "vent" not in result["per_class"]


def test_dataset_summary_counts_true_negatives(tmp_path, labels, perfect_predictions):
    out_path = tmp_path / "eval_results.json"
    result = eval_models.evaluate(
        labels_path=labels,
        prediction_paths=[perfect_predictions],
        output_path=out_path,
    )
    assert result["dataset"]["tile_count"] == 2
    assert result["dataset"]["true_negative_count"] == 1
