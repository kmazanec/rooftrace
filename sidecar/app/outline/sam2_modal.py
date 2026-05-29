"""Modal SAM2 deployment stub (ADR-012).

Deploy once with:
    modal deploy sidecar/app/outline/sam2_modal.py

Then the sidecar's `infer_sam2()` (SAM2_BACKEND=modal) calls
`segment_roof.remote(...)` over the network.

This file is intentionally NOT imported by the sidecar at startup — it is a
standalone Modal app file. It is present so the Modal function can be deployed
and updated independently of the sidecar image.

NOTE: SAM2 weights download is handled inside the Modal image build (see the
image definition below). Pin the checkpoint hash for reproducibility.
Weights URL: https://dl.fbaipublicfiles.com/segment_anything_2/092824/
  sam2.1_hiera_large.pt  (Apache 2.0 — re-verify before a production deploy)
"""

from __future__ import annotations

# ---------------------------------------------------------------------------
# Real Modal wiring — only executed when `modal deploy` or `modal run` is used.
# CI never imports this file because `infer_sam2()` defaults to SAM2_BACKEND=local.
# ---------------------------------------------------------------------------

try:
    import modal  # type: ignore[import-untyped]

    _CHECKPOINT = "sam2.1_hiera_large.pt"
    _WEIGHTS_URL = (
        f"https://dl.fbaipublicfiles.com/segment_anything_2/092824/{_CHECKPOINT}"
    )

    _image = (
        modal.Image.debian_slim(python_version="3.12")
        .pip_install(
            "torch>=2.3",
            "torchvision",
            "segment-anything-2",
            "numpy>=1.26",
            "pillow>=10",
        )
        .run_commands(
            f"mkdir -p /weights && wget -q -O /weights/{_CHECKPOINT} {_WEIGHTS_URL}"
        )
    )

    _app = modal.App("rooftrace-sam2", image=_image)

    @_app.function(gpu="A10G", timeout=60)
    def segment_roof(
        image_bytes: bytes,
        prior_bytes: bytes,
        height: int,
        width: int,
    ) -> dict:
        """Run SAM2 on a single tile with a prior mask as a box prompt.

        Returns:
            dict with key "mask_bytes": flat uint8 H*W bytes (0 or 1).
        """
        import io

        import numpy as np
        import torch
        from PIL import Image
        from sam2.build_sam import build_sam2  # type: ignore[import-untyped]
        from sam2.sam2_image_predictor import SAM2ImagePredictor  # type: ignore[import-untyped]

        device = "cuda" if torch.cuda.is_available() else "cpu"

        prior_mask = np.frombuffer(prior_bytes, dtype=np.uint8).reshape(height, width).astype(bool)

        # Build a bounding-box prompt from the prior mask.
        ys, xs = np.where(prior_mask)
        if len(xs) == 0:
            # Empty prior — return empty mask.
            return {"mask_bytes": np.zeros(height * width, dtype=np.uint8).tobytes()}

        box = np.array([xs.min(), ys.min(), xs.max(), ys.max()], dtype=np.float32)

        pil_img = Image.open(io.BytesIO(image_bytes)).convert("RGB")

        sam2_model = build_sam2(
            "sam2_hiera_large.yaml",
            "/weights/sam2.1_hiera_large.pt",
            device=device,
        )
        predictor = SAM2ImagePredictor(sam2_model)
        predictor.set_image(np.array(pil_img))

        masks, _, _ = predictor.predict(
            point_coords=None,
            point_labels=None,
            box=box[None, :],
            multimask_output=False,
        )
        best_mask = masks[0].astype(np.uint8)
        return {"mask_bytes": best_mask.flatten().tobytes()}

except ImportError:
    # modal not installed — silently skip the Modal app definition.
    # This is expected in the local/test environment.
    pass
