# Feature-detection labeling protocol (ADR-006)

The model evaluation scores each candidate VLM's detections against
hand-labeled ground truth. The trustworthiness of every model comparison is
bounded by the quality of these labels, so the labeling is done to a documented,
reproducible protocol. **Labeling is manual human work** (budget ~4–6 h); the
builder commits this protocol + a seed `labels.json`, and a human fills the real
labels.

## Vocabulary (fixed)

Only these five classes (mirrored in `known_labels.json`, the source of truth
being `FeatureDetector::KNOWN_LABELS` in `app/services/feature_detector.rb` and
the `Feature.label` enum in `shared/pipeline_schema.json`):

| Class            | Definition                                                        |
| ---------------- | ----------------------------------------------------------------- |
| `chimney`        | A masonry/metal chimney stack protruding above the roof plane.    |
| `vent`           | A roof vent, pipe boot, or turbine (small circular/box exhaust).  |
| `skylight`       | A glazed roof opening (flat or domed), distinct from a vent.      |
| `dormer`         | A roofed structure projecting from the roof with its own window.  |
| `satellite_dish` | A parabolic dish antenna mounted on or beside the roof.           |

Anything outside this set is **not labeled** (the schema enum has an `other`
class, but the eval scores only the five known labels, matching the runtime
detector's vocabulary).

## Bounding-box convention

- `bbox_norm = [x0, y0, x1, y1]`, each in `[0, 1]`, normalized by the tile's
  pixel width/height. `(x0, y0)` is the top-left, `(x1, y1)` the bottom-right;
  `x0 <= x1` and `y0 <= y1`. Same convention as `Feature.bbox_norm`.
- Draw the **tightest** box fully containing the visible feature.

## Occlusion & ambiguity

- **Occluded** (`occluded: true`): part of the feature is hidden (shadow, tree,
  adjacent structure) but it is still clearly identifiable. Label it, box the
  visible extent, set the flag.
- **Ambiguous** (`ambiguous: true`): the labeler is unsure of the class or
  whether it is a feature at all. Label the best guess, set the flag; ambiguous
  labels are reported separately and can be excluded in a sensitivity pass.
- If a feature cannot be identified at all, do **not** label it.

## True negatives

Include **at least one tile with no features** (a plain gable/hip roof). True
negatives make precision meaningful — a detector that hallucinates features on a
clean roof must be penalized. The integrity test fails if no true-negative tile
exists.

## Process & QA

1. Pull tiles with `pull_tiles.py` (writes `imagery/*.png` + `manifest.json`).
2. Label each tile per the above into `labels.json` (key = `tile_id`).
3. Record who labeled and when in the commit message.
4. QA spot-check: a second pass (or second person) re-reviews ~20% of tiles;
   resolve disagreements by the definitions above.
5. Run `uv run pytest tests/test_feature_dataset_integrity.py` — it enforces
   no orphans, in-bounds bboxes, the fixed vocabulary, and >= 1 true negative.

## Provenance

Every tile's provider, capture date, GSD, source URL, and license live in
`manifest.json`. The eval tiles are Mapbox imagery (© Mapbox/Maxar), not public
domain — reference them by their recorded provenance and do not assume they are
freely redistributable.
