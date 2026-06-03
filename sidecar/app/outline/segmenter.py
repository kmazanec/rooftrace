"""SAM2 inference dispatch — local stub and Modal GPU backend.

Backend selection is via SAM2_BACKEND env var:
  - "local"  (default): deterministic stub segmenter — no model weights, no GPU.
              Used in CI and tests. Produces a plausible mask by eroding the prior.
  - "modal":  calls the deployed Modal SAM2 function. Requires MODAL_TOKEN_ID and
              MODAL_TOKEN_SECRET environment variables. Not called in CI.

The public surface is `infer_sam2(image_bytes, prior_mask, image_size)` which
returns a 2-D boolean NumPy array (H x W) with the predicted roof mask.
"""

from __future__ import annotations

import os
from typing import TYPE_CHECKING

import numpy as np

from app import flags

if TYPE_CHECKING:
    from numpy.typing import NDArray

# Douglas–Peucker simplification tolerance (degrees lon/lat). Produces <=30
# vertices on typical residential roofs. Configurable via env var for tuning.
_DEFAULT_DP_TOLERANCE = float(os.environ.get("SAM2_DP_TOLERANCE", "1e-5"))


def _erode_mask(mask: "NDArray[np.bool_]", radius: int = 5) -> "NDArray[np.bool_]":
    """Shrink a binary mask by `radius` pixels (separable box erosion).

    Uses numpy cumulative sums — dependency-free (no scipy).
    A pixel survives iff every pixel in its (2r+1)×(2r+1) neighbourhood is True.
    """
    if not mask.any():
        return mask.copy()

    def _erode_1d(arr: "NDArray[np.bool_]", r: int, axis: int) -> "NDArray[np.bool_]":
        """Box erosion along one axis, half-width r."""
        n = arr.shape[axis]
        if n < 2 * r + 1:
            return np.zeros_like(arr, dtype=bool)

        # Pad with r zeros on each side, prepend one more zero for the cumsum.
        pad_widths = [(0, 0)] * arr.ndim
        pad_widths[axis] = (r, r)
        padded = np.pad(arr.astype(np.float32), pad_widths, mode="constant", constant_values=0)
        # Prepend a zero slice so cs[0] == 0 everywhere.
        zero_shape = list(padded.shape)
        zero_shape[axis] = 1
        cs = np.cumsum(
            np.concatenate([np.zeros(zero_shape, dtype=np.float32), padded], axis=axis),
            axis=axis,
        )
        # Window sum at output index i: cs[i + 2r + 1] - cs[i]  (window = 2r+1 wide)
        sl_hi = [slice(None)] * arr.ndim
        sl_lo = [slice(None)] * arr.ndim
        sl_hi[axis] = slice(2 * r + 1, 2 * r + 1 + n)
        sl_lo[axis] = slice(0, n)
        window_sum = cs[tuple(sl_hi)] - cs[tuple(sl_lo)]
        return window_sum >= (2 * r + 1)

    result = _erode_1d(mask, radius, axis=0)
    result = _erode_1d(result, radius, axis=1)
    return result


def _stub_segmenter(
    image_bytes: bytes,
    prior_mask: "NDArray[np.bool_]",
) -> "NDArray[np.bool_]":
    """Deterministic stub: erode the prior mask slightly.

    This intentionally produces a mask that has high IoU with the prior (>0.5),
    so the happy-path tests pass. To trigger the fallback-to-prior path, callers
    can pass an empty (all-False) prior — `_stub_segmenter` then returns empty too.

    The stub makes both `modal` and `local` paths produce identical results in
    tests, which is exactly what the parity test needs to assert.
    """
    if not prior_mask.any():
        # No signal — return empty mask to trigger the fallback-to-prior guard.
        return np.zeros_like(prior_mask, dtype=bool)
    return _erode_mask(prior_mask, radius=3)


class ModalUnavailable(RuntimeError):
    """Raised when SAM2_BACKEND=modal but the Modal path can't actually run."""


def infer_sam2(
    image_bytes: bytes,
    prior_mask: "NDArray[np.bool_]",
) -> tuple["NDArray[np.bool_]", str]:
    """Run SAM2 inference (or the stub) and return (mask, backend_actually_used).

    The second element is the backend that *actually produced* the mask — "modal"
    or "local" — NOT merely what was requested. So when SAM2_BACKEND=modal but
    Modal is unavailable, the caller learns the result is really the local stub
    and can report it honestly (instead of mislabelling stub geometry as GPU SAM2).

    Args:
        image_bytes: raw PNG/JPEG bytes of the image tile.
        prior_mask:  boolean H×W array derived from the prior_polygon.

    Returns:
        (mask, backend) where mask is a boolean H×W array and backend is the
        backend that produced it.
    """
    backend = flags.sam2_backend()
    if backend == flags.SAM2_REAL_BACKEND:  # "modal" — the real GPU segmenter (default)
        return _run_modal(image_bytes, prior_mask), "modal"
    return _stub_segmenter(image_bytes, prior_mask), "local"


def _run_modal(
    image_bytes: bytes,
    prior_mask: "NDArray[np.bool_]",
) -> "NDArray[np.bool_]":
    """Call the deployed Modal SAM2 function.

    Deployed separately via `modal deploy sidecar/app/outline/sam2_modal.py`;
    needs MODAL_TOKEN_ID/MODAL_TOKEN_SECRET. Never invoked in CI (SAM2_BACKEND
    defaults to "local").

    Raises ModalUnavailable when `modal` isn't installed or no token is present,
    so the caller can decide policy (warn + fall back, or fail closed) rather
    than this silently returning stub geometry under a "modal" label.
    """
    token_id = os.environ.get("MODAL_TOKEN_ID")
    try:
        import modal  # type: ignore[import-untyped]
    except ImportError as exc:
        raise ModalUnavailable("modal package not installed") from exc

    if not token_id:
        raise ModalUnavailable("MODAL_TOKEN_ID not set")

    # Serialize prior as a flat bytes blob (uint8 0/1) + shape metadata.
    h, w = prior_mask.shape
    prior_bytes = prior_mask.astype(np.uint8).tobytes()

    # modal.Function.lookup was removed in the Modal 1.x SDK; from_name is the
    # current API (returns a lazy handle, hydrated on the first .remote()).
    fn = modal.Function.from_name("rooftrace-sam2", "segment_roof")
    try:
        result: dict = fn.remote(
            image_bytes=image_bytes,
            prior_bytes=prior_bytes,
            height=h,
            width=w,
        )
    except modal.exception.NotFoundError as exc:
        # The lazy handle hydrates here; an undeployed app surfaces as NotFound.
        # That's an availability problem (deploy the Modal function), not an
        # inference bug — signal it as such so the router reports it precisely.
        raise ModalUnavailable(f"Modal app/function not deployed: {exc}") from exc
    except (modal.exception.AuthError, modal.exception.ConnectionError) as exc:
        raise ModalUnavailable(f"Modal not reachable: {type(exc).__name__}: {exc}") from exc
    mask_flat = np.frombuffer(result["mask_bytes"], dtype=np.uint8)
    return mask_flat.reshape(h, w).astype(bool)
