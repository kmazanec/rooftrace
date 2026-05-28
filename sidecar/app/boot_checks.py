"""Fail-fast boot-time config checks for the RoofTrace sidecar (F-10.4).

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


def _imagery_enabled(env: Mapping[str, str]) -> bool:
    return env.get("IMAGERY_LIVE", "") == "1"


def _imagery_missing(env: Mapping[str, str]) -> list[str]:
    """IMAGERY_LIVE=1 — F-10.1 imagery stage config requirements.

    TODO (F-10.1 integrator): replace this stub with the real required-var list
    once the imagery stage env vars are finalised. The current stub always
    reports a placeholder problem so a deploy with IMAGERY_LIVE=1 fails fast
    rather than silently allowing an unconfigured stage.
    """
    # F-10.1 is built in parallel; its exact env var names are not final in this
    # worktree. When the imagery stage lands, add its required vars here analogous
    # to _storage_missing / _sam2_missing above. For now, report a clear TODO so
    # CI catches any premature IMAGERY_LIVE=1 in the env file.
    return [
        "IMAGERY_LIVE is set but no imagery stage config check is implemented yet "
        "(TODO F-10.1: add required env vars to _imagery_missing in app/boot_checks.py)"
    ]


# ---------------------------------------------------------------------------
# Check table — add one row per new stage
# ---------------------------------------------------------------------------

_CHECKS: list[_StageCheck] = [
    _StageCheck(stage="lidar",   is_enabled=_lidar_enabled,   required_vars=_lidar_missing),
    _StageCheck(stage="storage", is_enabled=_storage_enabled, required_vars=_storage_missing),
    _StageCheck(stage="sam2",    is_enabled=_sam2_enabled,    required_vars=_sam2_missing),
    # F-10.1: imagery row — stub until imagery stage env vars are finalised
    _StageCheck(stage="imagery", is_enabled=_imagery_enabled, required_vars=_imagery_missing),
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
