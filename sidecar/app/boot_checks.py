"""Fail-fast boot-time config checks for the RoofTrace sidecar.

Mirrors the Rails `after_initialize` raise-in-prod / warn-in-dev pattern from
`config/initializers/pipeline_schema.rb` and `config/initializers/demo_login.rb`.

Rule: when a pipeline stage's live path is ENABLED but its required config is
MISSING, fail at sidecar boot rather than booting green and 502-ing every call.

Prod vs dev behaviour is controlled by ``SIDECAR_ENV``:
  - ``production``  → problems RAISE RuntimeError at boot.
  - anything else (``development``, unset, …) → problems log a WARNING; the
    sidecar starts anyway (so local work without live credentials is not blocked).

Design: ``verify_stage_config`` is a pure function that accepts a ``Mapping``
(so tests can pass a crafted dict, no os.environ side effects).  Adding a new
stage's check is a one-line addition to the ``_CHECKS`` table.
"""

from __future__ import annotations

import logging
import os
from collections.abc import Mapping
from pathlib import Path
from typing import NamedTuple

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Prod/dev flag
# ---------------------------------------------------------------------------

_SIDECAR_ENV_VAR = "SIDECAR_ENV"
_PROD_VALUE = "production"


def _is_production(env: Mapping[str, str]) -> bool:
    return env.get(_SIDECAR_ENV_VAR, "development").lower() == _PROD_VALUE


# ---------------------------------------------------------------------------
# Check primitives
# ---------------------------------------------------------------------------


class _StageCheck(NamedTuple):
    """One row in the check table."""

    stage: str          # human-readable stage name for error messages
    is_enabled: object  # callable(env) -> bool
    required_vars: object  # callable(env) -> list[str] of MISSING vars


def _lidar_enabled(env: Mapping[str, str]) -> bool:
    return env.get("LIDAR_LIVE", "") == "1"


def _lidar_missing(env: Mapping[str, str]) -> list[str]:
    """LIDAR_LIVE=1 requires WESM_GPKG_PATH pointing to an existing file."""
    path_val = env.get("WESM_GPKG_PATH", "")
    if not path_val or not Path(path_val).is_file():
        return ["WESM_GPKG_PATH (must be set and point to an existing .gpkg file)"]
    return []


def _storage_enabled(env: Mapping[str, str]) -> bool:
    """Live Spaces is the active path when STORAGE_LOCAL_ROOT is NOT set."""
    return not env.get("STORAGE_LOCAL_ROOT", "")


def _storage_missing(env: Mapping[str, str]) -> list[str]:
    """Live Spaces requires STORAGE_BUCKET, STORAGE_ENDPOINT, STORAGE_ACCESS_KEY,
    STORAGE_SECRET_KEY (matching storage.py's _client() and _bucket())."""
    required = [
        "STORAGE_BUCKET",
        "STORAGE_ENDPOINT",
        "STORAGE_ACCESS_KEY",
        "STORAGE_SECRET_KEY",
    ]
    return [v for v in required if not env.get(v, "").strip()]


def _sam2_enabled(env: Mapping[str, str]) -> bool:
    return env.get("SAM2_BACKEND", "local").lower() == "modal"


def _sam2_missing(env: Mapping[str, str]) -> list[str]:
    """SAM2_BACKEND=modal requires MODAL_TOKEN_ID + MODAL_TOKEN_SECRET."""
    required = ["MODAL_TOKEN_ID", "MODAL_TOKEN_SECRET"]
    return [v for v in required if not env.get(v, "").strip()]


def _render_images_enabled(env: Mapping[str, str]) -> bool:
    return env.get("RENDER_IMAGES_LIVE", "") == "1"


def _render_images_missing(env: Mapping[str, str]) -> list[str]:
    """RENDER_IMAGES_LIVE=1 (the real top-down map render, ADR-014) requires a
    MAPBOX_PUBLIC_TOKEN for the satellite tiles and a working Playwright/Chromium
    install. A missing token or browser means the live render path would fall
    back to a plain placeholder on every call — fail fast at boot instead."""
    missing: list[str] = []
    if not env.get("MAPBOX_PUBLIC_TOKEN", "").strip():
        missing.append("MAPBOX_PUBLIC_TOKEN")
    try:
        import playwright  # type: ignore[import]  # noqa: F401
    except ImportError:
        missing.append("playwright (declared dependency not importable)")
    return missing


def _fuse_capture_enabled(env: Mapping[str, str]) -> bool:
    return env.get("FUSE_CAPTURE_LIVE", "") == "1"


def _fuse_capture_missing(env: Mapping[str, str]) -> list[str]:
    """FUSE_CAPTURE_LIVE=1 (the real ICP fusion path, ADR-007) requires open3d to
    be importable. open3d ships a compiled pip wheel; a failed import means the
    sidecar image is broken — fail fast at boot rather than 502 on the first
    fuse-capture call. (Mirrors _imagery_missing's rasterio import check.)"""
    try:
        import open3d  # type: ignore[import]  # noqa: F401
    except ImportError:
        return ["open3d (declared dependency not importable; live ICP fusion path would fail)"]
    return []


def _project_photo_enabled(env: Mapping[str, str]) -> bool:
    return env.get("PROJECT_PHOTO_LIVE", "") == "1"


def _project_photo_missing(env: Mapping[str, str]) -> list[str]:
    """PROJECT_PHOTO_LIVE=1 (the real pinhole projection + ray-cast occlusion +
    SVG composite, ADR-019) requires trimesh (faces-aware mesh load for occlusion)
    and svgwrite (overlay composition) to be importable. Both ship pure-Python /
    pip wheels; a failed import means the sidecar image is broken — fail fast at
    boot rather than 502 on the first project-photo call. (Mirrors the
    open3d/rasterio import checks.)"""
    missing: list[str] = []
    try:
        import trimesh  # type: ignore[import]  # noqa: F401
    except ImportError:
        missing.append("trimesh (declared dependency not importable; ray-cast occlusion would fail)")
    try:
        import rtree  # type: ignore[import]  # noqa: F401
    except ImportError:
        missing.append("rtree (declared dependency not importable; mesh ray-cast index would fail)")
    try:
        import svgwrite  # type: ignore[import]  # noqa: F401
    except ImportError:
        missing.append("svgwrite (declared dependency not importable; overlay composition would fail)")
    return missing


def _imagery_enabled(env: Mapping[str, str]) -> bool:
    return env.get("IMAGERY_LIVE", "") == "1"


def _imagery_missing(env: Mapping[str, str]) -> list[str]:
    """IMAGERY_LIVE=1 imagery stage config requirements.

    The live NAIP path (naip.py) uses:
      - anonymous public AWS Open Data (no credentials, no extra env vars)
      - rasterio (a declared runtime dependency, installed from conda-forge in
        the image and as a pip dep for CI — see pyproject.toml / Dockerfile)
      - the storage vars already covered by _storage_missing

    No extra env vars are required beyond the storage check. We DO verify
    rasterio is importable: unlike the lidar/pdal case (where pdal is conda-only
    and deliberately not pip-declared, so an import check would falsely fail in
    CI), rasterio is now a first-class declared dependency. A correct deploy
    therefore always has it, and a missing rasterio means the image is broken —
    better to fail fast at boot than 502 on the first live imagery call.
    """
    try:
        import rasterio  # type: ignore[import]  # noqa: F401
    except ImportError:
        return ["rasterio (declared dependency not importable; live NAIP path would fail)"]
    return []


# ---------------------------------------------------------------------------
# Check table — add one row per new stage
# ---------------------------------------------------------------------------

_CHECKS: list[_StageCheck] = [
    _StageCheck(stage="lidar",   is_enabled=_lidar_enabled,   required_vars=_lidar_missing),
    _StageCheck(stage="storage", is_enabled=_storage_enabled, required_vars=_storage_missing),
    _StageCheck(stage="sam2",    is_enabled=_sam2_enabled,    required_vars=_sam2_missing),
    _StageCheck(stage="imagery", is_enabled=_imagery_enabled, required_vars=_imagery_missing),
    _StageCheck(stage="render_images", is_enabled=_render_images_enabled, required_vars=_render_images_missing),
    _StageCheck(stage="fuse_capture", is_enabled=_fuse_capture_enabled, required_vars=_fuse_capture_missing),
    _StageCheck(stage="project_photo", is_enabled=_project_photo_enabled, required_vars=_project_photo_missing),
]


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def verify_stage_config(env: Mapping[str, str]) -> list[str]:
    """Return human-readable problem strings for every enabled-but-misconfigured stage.

    Pure function — env is passed in, never reads os.environ. This makes it
    trivially testable with a crafted dict.

    An empty list means all enabled stages are fully configured.
    """
    problems: list[str] = []
    for check in _CHECKS:
        if not check.is_enabled(env):
            continue
        missing = check.required_vars(env)
        for var in missing:
            problems.append(f"[{check.stage}] {var}")
    return problems


def run_boot_checks() -> None:
    """Run all stage config checks against os.environ and raise or warn.

    Called once at sidecar startup (FastAPI lifespan). Behaviour:
    - SIDECAR_ENV=production  → RuntimeError if any problems (deploy dies with
      a clear message before /health ever goes green).
    - any other SIDECAR_ENV (or unset, defaulting to 'development') → WARNING
      logged per problem; sidecar continues (local dev without live creds works).
    """
    env = dict(os.environ)
    problems = verify_stage_config(env)
    if not problems:
        return

    prod = _is_production(env)
    if prod:
        joined = "; ".join(problems)
        raise RuntimeError(
            f"[boot_checks] sidecar misconfiguration detected (SIDECAR_ENV=production). "
            f"Fix before deploy: {joined}"
        )
    for problem in problems:
        logger.warning("[boot_checks] %s", problem)
