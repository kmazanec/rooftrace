"""Fail-fast boot-time config checks for the RoofTrace sidecar.

Mirrors the Rails `after_initialize` raise-in-prod / warn-in-dev pattern from
`config/initializers/pipeline_schema.rb` and `config/initializers/demo_login.rb`.

Rule: the running product (dev + prod) always uses REAL data, so every stage's
real path is ENABLED by default and its required config is checked by default. A
stage is only skipped here when its fixture opt-down flag is set (the test suites
— see app/flags.py). When a real-path requirement is MISSING, fail at sidecar boot
rather than booting green and 502-ing every call.

Behaviour is controlled by ``SIDECAR_ENV``:
  - ``production``  → problems RAISE RuntimeError at boot.
  - anything else (``development``, unset, …) → problems also RAISE: dev runs the
    real product, so a missing real-path prerequisite is a loud boot failure, not
    a silent degrade. The test suites avoid this by setting the fixture opt-down
    flags + STORAGE_LOCAL_ROOT, which disable the credentialed checks entirely.

Design: ``verify_stage_config`` is a pure function that accepts a ``Mapping``
(so tests can pass a crafted dict, no os.environ side effects).  Adding a new
stage's check is a one-line addition to the ``_CHECKS`` table.
"""

from __future__ import annotations

import logging
import os
from collections.abc import Callable, Mapping
from pathlib import Path
from typing import NamedTuple

from app import flags

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Env label (used only for the error message; dev and prod both raise)
# ---------------------------------------------------------------------------

_SIDECAR_ENV_VAR = "SIDECAR_ENV"


# ---------------------------------------------------------------------------
# Check primitives
# ---------------------------------------------------------------------------


class _StageCheck(NamedTuple):
    """One row in the check table."""

    stage: str          # human-readable stage name for error messages
    is_enabled: Callable[[Mapping[str, str]], bool]
    required_vars: Callable[[Mapping[str, str]], list[str]]  # returns MISSING items


def _importable(module: str) -> bool:
    """Return True if *module* can be imported; False on ImportError."""
    try:
        __import__(module)  # type: ignore[import]  # noqa: F401
    except ImportError:
        return False
    return True


def _lidar_enabled(env: Mapping[str, str]) -> bool:
    """Real 3DEP/PDAL LiDAR is the default; disabled only under the fixture flag."""
    return not flags.lidar_fixture(env)


def _lidar_missing(env: Mapping[str, str]) -> list[str]:
    """The real LiDAR path needs the WESM GeoPackage AND pdal (conda-forge). pdal
    is conda-only and deliberately NOT pip-declared, so we only import-check it on
    the real path (the fixture flag disables this whole check for hermetic tests)."""
    missing: list[str] = []
    path_val = env.get("WESM_GPKG_PATH", "")
    if not path_val or not Path(path_val).is_file():
        missing.append("WESM_GPKG_PATH (must point to an existing WESM.gpkg; bin/setup downloads it)")
    missing.extend(
        msg for mod, msg in [
            ("pdal", "pdal (conda-forge dep not importable; bin/setup installs it)"),
        ]
        if not _importable(mod)
    )
    return missing


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
    """Real (modal) SAM2 is the default; disabled only under the local fixture backend."""
    return not flags.sam2_is_fixture(env)


def _sam2_missing(env: Mapping[str, str]) -> list[str]:
    """Real SAM2 (modal) requires credentials and an importable Modal client."""
    required = ["MODAL_TOKEN_ID", "MODAL_TOKEN_SECRET"]
    missing = [v for v in required if not env.get(v, "").strip()]
    if not _importable("modal"):
        missing.append("modal (declared dependency not importable; real SAM2 path would fail)")
    return missing


def _render_images_enabled(env: Mapping[str, str]) -> bool:
    """The real top-down map render is the default; disabled only under the fixture flag."""
    return not flags.render_images_fixture(env)


def _render_images_missing(env: Mapping[str, str]) -> list[str]:
    """The real top-down map render (ADR-014) requires a MAPBOX_PRIVATE_TOKEN for
    the satellite tiles and a working Playwright/Chromium install. There is no
    silent placeholder fallback anymore (renderer.py raises), so fail fast at boot."""
    missing: list[str] = []
    if not env.get("MAPBOX_PRIVATE_TOKEN", "").strip():
        missing.append("MAPBOX_PRIVATE_TOKEN")
    missing.extend(
        msg for mod, msg in [
            ("playwright", "playwright (declared dependency not importable)"),
        ]
        if not _importable(mod)
    )
    return missing


def _fuse_capture_enabled(env: Mapping[str, str]) -> bool:
    """ICP fusion is always real (no fixture path); the open3d import check always applies."""
    return True


def _fuse_capture_missing(env: Mapping[str, str]) -> list[str]:
    """FUSE_CAPTURE_LIVE=1 (the real ICP fusion path, ADR-007) requires open3d to
    be importable. open3d ships a compiled pip wheel; a failed import means the
    sidecar image is broken — fail fast at boot rather than 502 on the first
    fuse-capture call. (Mirrors _imagery_missing's rasterio import check.)"""
    return [
        msg for mod, msg in [
            ("open3d", "open3d (declared dependency not importable; live ICP fusion path would fail)"),
        ]
        if not _importable(mod)
    ]


def _project_photo_enabled(env: Mapping[str, str]) -> bool:
    """The real pinhole projection + ray-cast occlusion + SVG composite (ADR-019)
    is the default; disabled only under the fixture flag (the deterministic 1x1
    placeholder, used by the hermetic test suites)."""
    return not flags.project_photo_fixture(env)


def _project_photo_missing(env: Mapping[str, str]) -> list[str]:
    """The real photo-projection path (ADR-019) requires trimesh (faces-aware mesh
    load for occlusion), rtree (the mesh ray-cast index), and svgwrite (overlay
    composition) to be importable. All ship pure-Python / pip wheels; a failed
    import means the sidecar image is broken — fail fast at boot rather than 502
    on the first project-photo call. (Mirrors the open3d/rasterio import checks.)"""
    return [
        msg for mod, msg in [
            ("trimesh", "trimesh (declared dependency not importable; ray-cast occlusion would fail)"),
            ("rtree", "rtree (declared dependency not importable; mesh ray-cast index would fail)"),
            ("svgwrite", "svgwrite (declared dependency not importable; overlay composition would fail)"),
        ]
        if not _importable(mod)
    ]


def _imagery_enabled(env: Mapping[str, str]) -> bool:
    """The real satellite imagery path is the default; disabled only under the fixture flag."""
    return not flags.imagery_fixture(env)


def _imagery_missing(env: Mapping[str, str]) -> list[str]:
    """Real satellite imagery (Mapbox Static Images, ADR-002) requires a
    MAPBOX_PRIVATE_TOKEN — the same token the map render uses. Fail fast at boot
    rather than 502 on the first imagery call. (No AWS/rasterio dependency: the
    stage no longer reads NAIP COGs — see app/imagery/naip.py history note.)"""
    if not env.get("MAPBOX_PRIVATE_TOKEN", "").strip():
        return ["MAPBOX_PRIVATE_TOKEN"]
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
        problems.extend(f"[{check.stage}] {var}" for var in missing)
    return problems


def run_boot_checks() -> None:
    """Run all stage config checks against os.environ and raise on any problem.

    Called once at sidecar startup (FastAPI lifespan). The running product (dev +
    prod) always uses real data, so a missing real-path prerequisite RAISES at
    boot — the sidecar never starts half-real. The test suites disable the
    credentialed checks by setting the fixture opt-down flags + STORAGE_LOCAL_ROOT,
    so `verify_stage_config` returns empty for them and this is a no-op.
    """
    env = dict(os.environ)
    problems = verify_stage_config(env)
    if not problems:
        return

    joined = "; ".join(problems)
    raise RuntimeError(
        f"[boot_checks] sidecar misconfiguration detected (SIDECAR_ENV="
        f"{env.get(_SIDECAR_ENV_VAR, 'development')}). RoofTrace runs REAL data in "
        f"dev and prod; fix these (or set the fixture opt-down flags for tests): {joined}"
    )
