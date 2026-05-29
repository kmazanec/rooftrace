"""Fixture opt-down flags — the single source of truth for the stage gates.

RoofTrace's running product (dev AND prod) always uses REAL data. Fixtures /
deterministic stubs exist ONLY as an explicit opt-DOWN, set by the automated test
suites (CI's `sidecar_test`/`rails_test`, local `pytest`/`rspec`) so they stay
hermetic — no network, no credentials, no heavy native deps.

So every per-stage gate reads "is the fixture flag set?" (default False ⇒ real),
NOT "is the live flag set?". A missing real-path prerequisite (rasterio, pdal, a
WESM file, an API key, Spaces creds) is a LOUD failure at boot, never a silent
fixture fallback — see boot_checks.py.

These helpers are the only place the flag names/polarity live; stage modules and
boot_checks import from here so the two can never drift.
"""

from __future__ import annotations

import os
from collections.abc import Mapping

# Per-stage fixture opt-down env vars. Set (to "1") ONLY by the test suites.
IMAGERY_FIXTURE_VAR = "IMAGERY_FIXTURE"
LIDAR_FIXTURE_VAR = "LIDAR_FIXTURE"
RENDER_IMAGES_FIXTURE_VAR = "RENDER_IMAGES_FIXTURE"
PROJECT_PHOTO_FIXTURE_VAR = "PROJECT_PHOTO_FIXTURE"

# SAM2 is selected by backend name (not a boolean fixture flag): the real path is
# the Modal GPU segmenter; the deterministic local stub is the test opt-down.
SAM2_BACKEND_VAR = "SAM2_BACKEND"
SAM2_REAL_BACKEND = "modal"
SAM2_FIXTURE_BACKEND = "local"


def _is_set(env: Mapping[str, str], var: str) -> bool:
    return env.get(var, "") == "1"


def imagery_fixture(env: Mapping[str, str] = os.environ) -> bool:
    return _is_set(env, IMAGERY_FIXTURE_VAR)


def lidar_fixture(env: Mapping[str, str] = os.environ) -> bool:
    return _is_set(env, LIDAR_FIXTURE_VAR)


def render_images_fixture(env: Mapping[str, str] = os.environ) -> bool:
    return _is_set(env, RENDER_IMAGES_FIXTURE_VAR)


def project_photo_fixture(env: Mapping[str, str] = os.environ) -> bool:
    return _is_set(env, PROJECT_PHOTO_FIXTURE_VAR)


def sam2_backend(env: Mapping[str, str] = os.environ) -> str:
    """The selected SAM2 backend, defaulting to the REAL Modal segmenter."""
    return env.get(SAM2_BACKEND_VAR, SAM2_REAL_BACKEND).lower()


def sam2_is_fixture(env: Mapping[str, str] = os.environ) -> bool:
    return sam2_backend(env) == SAM2_FIXTURE_BACKEND
