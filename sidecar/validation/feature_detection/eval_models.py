"""Score feature-detection candidate models against the hand-labeled set (ADR-006).

Pure Python: loads labels.json + each model's predictions JSON, computes per-class
precision / recall / F1 (IoU >= 0.5 greedy match, via validation.metrics), mean
bbox IoU on true positives, and count error, then ranks the models and selects a
production default by highest unweighted mean-across-classes F1. NO live VLM
calls — the Rails-side sweep (rake validation:eval_features) produces the
predictions JSONs this consumes.

Selection metric is unweighted mean F1 (v1). Recall-weighting (a missed feature
is arguably worse than a false positive for the report) is a documented v2 open
question; no model is named the production default without a number behind it.
"""

from __future__ import annotations

import argparse
import json
import warnings
from pathlib import Path
from typing import Any

from validation import metrics

FD_DIR = Path(__file__).resolve().parent
LABELS_PATH = FD_DIR / "labels.json"
KNOWN_LABELS_PATH = FD_DIR / "known_labels.json"
DEFAULT_OUTPUT = FD_DIR / "eval_results.json"


def _load(path: Path) -> dict[str, Any]:
    with Path(path).open() as fh:
        return json.load(fh)


def known_labels() -> list[str]:
    return list(_load(KNOWN_LABELS_PATH)["labels"])


def _gt_detections(label_tile: dict) -> list[dict]:
    return label_tile.get("features", [])


def score_model(labels_path: Path, predictions_path: Path) -> dict[str, Any]:
    """Score one model's predictions against the ground-truth labels.

    Returns ``{"model", "per_class": {label: {...}}, "overall_f1"}`` where each
    per-class dict has precision, recall, f1, iou (mean IoU on TPs), count_error.
    """
    labels = _load(labels_path)["tiles"]
    preds = _load(predictions_path)
    model = preds.get("model", Path(predictions_path).stem.replace("predictions_", ""))
    pred_tiles = preds["tiles"]
    vocab = known_labels()

    # Accumulate per-class tp/fp/fn and IoU samples across all tiles.
    agg: dict[str, dict[str, float]] = {
        cls: {"tp": 0.0, "fp": 0.0, "fn": 0.0, "iou_sum": 0.0, "iou_n": 0.0,
              "pred_count": 0.0, "gt_count": 0.0}
        for cls in vocab
    }

    excluded_tiles: list[str] = []
    for tile_id, label_tile in labels.items():
        gt = _gt_detections(label_tile)
        pred = pred_tiles.get(tile_id, [])
        # A non-list prediction entry signals an upload/detection failure for
        # that tile (the Rails sweep records ``{"error": ...}`` on failure).
        # Scoring it as an empty detection would turn every GT box into a
        # phantom FN and bias recall downward, so exclude the tile from scoring
        # entirely and surface the count to the caller.
        if not isinstance(pred, list):
            excluded_tiles.append(tile_id)
            continue
        pr = metrics.precision_recall_f1(pred, gt, iou_threshold=metrics.DEFAULT_IOU_THRESHOLD)
        for cls in vocab:
            stats = pr.get(cls)
            if stats:
                agg[cls]["tp"] += stats["tp"]
                agg[cls]["fp"] += stats["fp"]
                agg[cls]["fn"] += stats["fn"]
            agg[cls]["pred_count"] += sum(1 for d in pred if d["label"] == cls)
            agg[cls]["gt_count"] += sum(1 for d in gt if d["label"] == cls)
        # Mean IoU on matched same-class pairs (best IoU per gt box).
        for cls in vocab:
            gt_cls = [d for d in gt if d["label"] == cls]
            pred_cls = [d for d in pred if d["label"] == cls]
            for gtb in gt_cls:
                best = max(
                    (metrics.bbox_iou(p["bbox_norm"], gtb["bbox_norm"]) for p in pred_cls),
                    default=0.0,
                )
                if best >= metrics.DEFAULT_IOU_THRESHOLD:
                    agg[cls]["iou_sum"] += best
                    agg[cls]["iou_n"] += 1

    per_class: dict[str, dict[str, Any]] = {}
    f1s: list[float] = []
    for cls, a in agg.items():
        # Skip classes absent from both predictions and ground truth.
        if a["tp"] + a["fp"] + a["fn"] == 0:
            continue
        precision = a["tp"] / (a["tp"] + a["fp"]) if (a["tp"] + a["fp"]) > 0 else 0.0
        recall = a["tp"] / (a["tp"] + a["fn"]) if (a["tp"] + a["fn"]) > 0 else 0.0
        f1 = 2 * precision * recall / (precision + recall) if (precision + recall) > 0 else 0.0
        iou = a["iou_sum"] / a["iou_n"] if a["iou_n"] > 0 else 0.0
        per_class[cls] = {
            "precision": precision,
            "recall": recall,
            "f1": f1,
            "iou": iou,
            "count_error": metrics.count_error(int(a["pred_count"]), int(a["gt_count"])),
        }
        f1s.append(f1)

    if excluded_tiles:
        warnings.warn(
            f"{model}: {len(excluded_tiles)} tile(s) excluded from scoring due to "
            f"recorded upload/detection errors: {', '.join(sorted(excluded_tiles))}",
            stacklevel=2,
        )

    overall_f1 = sum(f1s) / len(f1s) if f1s else 0.0
    return {
        "model": model,
        "per_class": per_class,
        "overall_f1": overall_f1,
        "excluded_tile_count": len(excluded_tiles),
    }


def _dataset_summary(labels_path: Path) -> dict[str, Any]:
    tiles = _load(labels_path)["tiles"]
    true_negatives = sum(1 for t in tiles.values() if not t.get("features"))
    return {
        "tile_count": len(tiles),
        "true_negative_count": true_negatives,
        "gsd_cm": 60,
    }


def _worst_case(models: list[dict]) -> dict[str, Any] | None:
    """The weakest model/class combination (lowest per-class F1)."""
    worst = None
    for m in models:
        for cls, vals in m["per_class"].items():
            if worst is None or vals["f1"] < worst["f1"]:
                worst = {
                    "model": m["model"],
                    "label": cls,
                    "f1": vals["f1"],
                    "reason": "small features localize weakly at coarse NAIP GSD",
                }
    return worst


def evaluate(
    labels_path: Path | None = None,
    prediction_paths: list[Path] | None = None,
    output_path: Path | None = None,
) -> dict[str, Any]:
    """Score every model, rank by overall F1, select the best, write the JSON."""
    labels_path = labels_path or LABELS_PATH
    output_path = output_path or DEFAULT_OUTPUT
    if not prediction_paths:
        prediction_paths = sorted(FD_DIR.glob("predictions_*.json"))
    if not prediction_paths:
        raise FileNotFoundError(
            f"no predictions_*.json found in {FD_DIR}; run the candidate sweep first"
        )

    models = [score_model(labels_path, p) for p in prediction_paths]
    models.sort(key=lambda m: m["overall_f1"], reverse=True)
    for rank, m in enumerate(models, start=1):
        m["rank"] = rank

    selected = models[0]["model"] if models else None
    result = {
        "dataset": _dataset_summary(labels_path),
        "models": models,
        "selected_model": selected,
        "selection_metric": "unweighted_mean_f1_v1",
        "worst_case": _worst_case(models),
    }
    Path(output_path).write_text(json.dumps(result, indent=2) + "\n")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description="Score feature-detection candidate models.")
    parser.add_argument("--labels", type=Path, default=None)
    parser.add_argument("--predictions", type=Path, nargs="*", default=None)
    parser.add_argument("--output", type=Path, default=None)
    args = parser.parse_args()
    result = evaluate(
        labels_path=args.labels,
        prediction_paths=args.predictions,
        output_path=args.output,
    )
    print(f"selected model: {result['selected_model']} "
          f"(overall F1 {result['models'][0]['overall_f1']:.3f})")


if __name__ == "__main__":
    main()
