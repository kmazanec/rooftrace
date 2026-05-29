"""Tests for sidecar boot-time config validation (F-10.4).

`verify_stage_config` is a pure function that accepts an env-var mapping and
returns human-readable problem strings for every enabled-but-misconfigured
stage. Tested here without booting the FastAPI app.

`run_boot_checks` wraps the pure function: RAISES (RuntimeError) when
SIDECAR_ENV=production and there are problems; logs a WARNING and returns
normally when SIDECAR_ENV=development (or unset).

Test env baseline: no live flags set → zero problems → app boots fine in CI.
"""

from __future__ import annotations

import logging
import os
from pathlib import Path
from unittest.mock import patch

import pytest

# ---------------------------------------------------------------------------
# Helpers to isolate run_boot_checks from os.environ at call time
# ---------------------------------------------------------------------------

from app.boot_checks import run_boot_checks, verify_stage_config


# ---------------------------------------------------------------------------
# verify_stage_config — pure-function tests
# ---------------------------------------------------------------------------


class TestVerifyStageConfigLidar:
    """LiDAR: LIDAR_LIVE=1 requires WESM_GPKG_PATH pointing to a real file."""

    def test_lidar_live_missing_wesm_path(self, tmp_path: Path):
        # Use STORAGE_LOCAL_ROOT to silence the storage check — focus on lidar only
        env = {"LIDAR_LIVE": "1", "STORAGE_LOCAL_ROOT": str(tmp_path)}
        problems = verify_stage_config(env)
        joined = " ".join(problems)
        assert "WESM_GPKG_PATH" in joined
        lidar_problems = [p for p in problems if "WESM_GPKG_PATH" in p]
        assert len(lidar_problems) == 1

    def test_lidar_live_nonexistent_wesm_path(self, tmp_path: Path):
        bogus = str(tmp_path / "does_not_exist.gpkg")
        env = {"LIDAR_LIVE": "1", "WESM_GPKG_PATH": bogus, "STORAGE_LOCAL_ROOT": str(tmp_path)}
        problems = verify_stage_config(env)
        joined = " ".join(problems)
        assert "WESM_GPKG_PATH" in joined
        lidar_problems = [p for p in problems if "WESM_GPKG_PATH" in p]
        assert len(lidar_problems) == 1

    def test_lidar_live_valid_wesm_path(self, tmp_path: Path):
        real_file = tmp_path / "wesm.gpkg"
        real_file.write_bytes(b"fake gpkg")
        env = {"LIDAR_LIVE": "1", "WESM_GPKG_PATH": str(real_file), "STORAGE_LOCAL_ROOT": str(tmp_path)}
        problems = verify_stage_config(env)
        assert problems == []

    def test_lidar_not_live_no_problems(self, tmp_path: Path):
        problems = verify_stage_config({"STORAGE_LOCAL_ROOT": str(tmp_path)})
        assert problems == []

    def test_lidar_live_zero_not_enabled(self, tmp_path: Path):
        """LIDAR_LIVE=0 means not enabled — no check."""
        problems = verify_stage_config({"LIDAR_LIVE": "0", "STORAGE_LOCAL_ROOT": str(tmp_path)})
        assert problems == []


class TestVerifyStageConfigStorage:
    """Storage: live Spaces enabled when STORAGE_LOCAL_ROOT is NOT set.

    Required vars: STORAGE_BUCKET, STORAGE_ENDPOINT, STORAGE_ACCESS_KEY,
    STORAGE_SECRET_KEY (matching storage.py's _client() and _bucket()).
    """

    _FULL_LIVE_STORAGE = {
        "STORAGE_BUCKET": "rooftrace",
        "STORAGE_ENDPOINT": "https://nyc3.digitaloceanspaces.com",
        "STORAGE_ACCESS_KEY": "key",
        "STORAGE_SECRET_KEY": "secret",
    }

    def test_no_local_root_missing_all_creds(self):
        """Empty env → live storage path, all four vars missing."""
        problems = verify_stage_config({})
        storage_problems = [p for p in problems if "storage" in p.lower() or "STORAGE_" in p]
        assert len(storage_problems) >= 4 or any(
            v in " ".join(problems)
            for v in ("STORAGE_BUCKET", "STORAGE_ENDPOINT", "STORAGE_ACCESS_KEY", "STORAGE_SECRET_KEY")
        )

    def test_no_local_root_missing_some_creds(self):
        problems = verify_stage_config({
            "STORAGE_BUCKET": "rooftrace",
            "STORAGE_ENDPOINT": "https://nyc3.digitaloceanspaces.com",
            # STORAGE_ACCESS_KEY and STORAGE_SECRET_KEY missing
        })
        joined = " ".join(problems)
        assert "STORAGE_ACCESS_KEY" in joined
        assert "STORAGE_SECRET_KEY" in joined
        assert "STORAGE_BUCKET" not in joined
        assert "STORAGE_ENDPOINT" not in joined

    def test_local_root_set_no_problems(self, tmp_path: Path):
        """STORAGE_LOCAL_ROOT set → local path → no live-Spaces check needed."""
        problems = verify_stage_config({"STORAGE_LOCAL_ROOT": str(tmp_path)})
        storage_problems = [p for p in problems if "STORAGE_" in p]
        assert storage_problems == []

    def test_all_live_creds_present_no_problems(self):
        problems = verify_stage_config(self._FULL_LIVE_STORAGE)
        storage_problems = [p for p in problems if "STORAGE_" in p]
        assert storage_problems == []


class TestVerifyStageConfigSam2:
    """SAM2/Outline: SAM2_BACKEND=modal requires MODAL_TOKEN_ID + MODAL_TOKEN_SECRET."""

    def test_modal_missing_both_tokens(self):
        # Need live storage too so only modal problems surface cleanly
        problems = verify_stage_config({
            "SAM2_BACKEND": "modal",
            "STORAGE_LOCAL_ROOT": "/tmp",
        })
        joined = " ".join(problems)
        assert "MODAL_TOKEN_ID" in joined
        assert "MODAL_TOKEN_SECRET" in joined

    def test_modal_missing_one_token(self):
        problems = verify_stage_config({
            "SAM2_BACKEND": "modal",
            "MODAL_TOKEN_ID": "id123",
            "STORAGE_LOCAL_ROOT": "/tmp",
        })
        joined = " ".join(problems)
        assert "MODAL_TOKEN_SECRET" in joined
        assert "MODAL_TOKEN_ID" not in joined

    def test_modal_both_tokens_present_no_problems(self):
        problems = verify_stage_config({
            "SAM2_BACKEND": "modal",
            "MODAL_TOKEN_ID": "id123",
            "MODAL_TOKEN_SECRET": "sec456",
            "STORAGE_LOCAL_ROOT": "/tmp",
        })
        modal_problems = [p for p in problems if "MODAL_" in p]
        assert modal_problems == []

    def test_sam2_local_backend_no_modal_check(self):
        problems = verify_stage_config({
            "SAM2_BACKEND": "local",
            "STORAGE_LOCAL_ROOT": "/tmp",
        })
        modal_problems = [p for p in problems if "MODAL_" in p]
        assert modal_problems == []

    def test_sam2_unset_backend_no_modal_check(self):
        """Default (unset) SAM2_BACKEND behaves as local."""
        problems = verify_stage_config({"STORAGE_LOCAL_ROOT": "/tmp"})
        modal_problems = [p for p in problems if "MODAL_" in p]
        assert modal_problems == []


class TestVerifyStageConfigImagery:
    """Imagery: IMAGERY_LIVE gate.

    The live NAIP path needs no extra env vars beyond storage (already checked
    by _storage_missing). rasterio is now a declared, installed dependency
    (pyproject + conda-forge in the image), so a correctly-deployed
    IMAGERY_LIVE=1 sidecar has it and yields zero imagery problems. The check
    verifies rasterio importability so a broken image fails fast at boot rather
    than 502-ing on the first live call.
    """

    def test_imagery_not_live_no_problems(self):
        """IMAGERY_LIVE unset → no imagery check → no problems."""
        problems = verify_stage_config({"STORAGE_LOCAL_ROOT": "/tmp"})
        imagery_problems = [p for p in problems if "IMAGERY" in p.upper()]
        assert imagery_problems == []

    def test_imagery_live_with_storage_yields_zero_imagery_problems(self):
        """IMAGERY_LIVE=1 with storage configured + rasterio installed → zero
        imagery problems.

        The NAIP stage uses only anonymous public AWS Open Data and the storage
        vars already validated by the storage check — no additional secrets
        needed. rasterio is a declared dependency present in the test env.
        """
        problems = verify_stage_config({
            "IMAGERY_LIVE": "1",
            "STORAGE_LOCAL_ROOT": "/tmp",
        })
        imagery_problems = [p for p in problems if "imagery" in p.lower()]
        assert imagery_problems == [], (
            f"IMAGERY_LIVE=1 with storage configured should yield zero imagery "
            f"problems; got: {imagery_problems}"
        )

    def test_imagery_live_zero_not_enabled(self):
        """IMAGERY_LIVE=0 means not enabled — no check fires."""
        problems = verify_stage_config({
            "IMAGERY_LIVE": "0",
            "STORAGE_LOCAL_ROOT": "/tmp",
        })
        imagery_problems = [p for p in problems if "imagery" in p.lower()]
        assert imagery_problems == []

    def test_imagery_live_missing_rasterio_is_a_problem(self):
        """If rasterio cannot be imported, IMAGERY_LIVE=1 reports a problem.

        Simulates a broken image (rasterio absent). The boot check should flag
        it so the deploy fails fast instead of 502-ing every live imagery call.
        """
        import builtins

        real_import = builtins.__import__

        def fake_import(name, *args, **kwargs):
            if name == "rasterio":
                raise ImportError("simulated: rasterio not installed")
            return real_import(name, *args, **kwargs)

        with patch("builtins.__import__", side_effect=fake_import):
            problems = verify_stage_config({
                "IMAGERY_LIVE": "1",
                "STORAGE_LOCAL_ROOT": "/tmp",
            })
        imagery_problems = [p for p in problems if "imagery" in p.lower()]
        assert any("rasterio" in p for p in imagery_problems), (
            f"expected a rasterio importability problem; got: {problems}"
        )


class TestVerifyStageConfigRenderImages:
    """Render-images: RENDER_IMAGES_LIVE gate (the real top-down map render)."""

    def test_render_images_not_live_no_problems(self):
        """RENDER_IMAGES_LIVE unset → no check fires."""
        problems = verify_stage_config({"STORAGE_LOCAL_ROOT": "/tmp"})
        assert [p for p in problems if "render_images" in p.lower()] == []

    def test_render_images_live_missing_token_is_a_problem(self):
        """RENDER_IMAGES_LIVE=1 without MAPBOX_PUBLIC_TOKEN reports a problem."""
        problems = verify_stage_config({
            "RENDER_IMAGES_LIVE": "1",
            "STORAGE_LOCAL_ROOT": "/tmp",
        })
        joined = " ".join(problems)
        assert "MAPBOX_PUBLIC_TOKEN" in joined

    def test_render_images_live_with_token_and_playwright_zero_problems(self):
        """RENDER_IMAGES_LIVE=1 with the token set + playwright installed → zero
        render_images problems (playwright is a declared dependency)."""
        problems = verify_stage_config({
            "RENDER_IMAGES_LIVE": "1",
            "MAPBOX_PUBLIC_TOKEN": "pk.test",
            "STORAGE_LOCAL_ROOT": "/tmp",
        })
        render_problems = [p for p in problems if "render_images" in p.lower()]
        assert render_problems == [], f"unexpected: {problems}"


class TestVerifyStageConfigFuseCapture:
    """Fuse-capture: FUSE_CAPTURE_LIVE gate (the real Open3D ICP fusion path)."""

    def test_fuse_capture_not_live_no_problems(self):
        """FUSE_CAPTURE_LIVE unset → no check fires."""
        problems = verify_stage_config({"STORAGE_LOCAL_ROOT": "/tmp"})
        assert [p for p in problems if "fuse_capture" in p.lower()] == []

    def test_fuse_capture_live_with_open3d_zero_problems(self):
        """FUSE_CAPTURE_LIVE=1 with open3d installed → zero fuse_capture problems
        (open3d is a declared dependency present in the synced env)."""
        problems = verify_stage_config({
            "FUSE_CAPTURE_LIVE": "1",
            "STORAGE_LOCAL_ROOT": "/tmp",
        })
        fuse_problems = [p for p in problems if "fuse_capture" in p.lower()]
        assert fuse_problems == [], f"unexpected: {problems}"

    def test_fuse_capture_live_without_open3d_is_a_problem(self, monkeypatch):
        """FUSE_CAPTURE_LIVE=1 with open3d not importable reports a problem
        (simulates a broken image where the wheel failed to install)."""
        import builtins

        real_import = builtins.__import__

        def fake_import(name, *args, **kwargs):
            if name == "open3d":
                raise ImportError("simulated missing open3d")
            return real_import(name, *args, **kwargs)

        monkeypatch.setattr(builtins, "__import__", fake_import)
        problems = verify_stage_config({
            "FUSE_CAPTURE_LIVE": "1",
            "STORAGE_LOCAL_ROOT": "/tmp",
        })
        joined = " ".join(problems)
        assert "open3d" in joined


class TestVerifyStageConfigProjectPhoto:
    """Project-photo: PROJECT_PHOTO_LIVE gate (the real pinhole projection +
    ray-cast occlusion + SVG composite path)."""

    def test_project_photo_not_live_no_problems(self):
        """PROJECT_PHOTO_LIVE unset → no check fires."""
        problems = verify_stage_config({"STORAGE_LOCAL_ROOT": "/tmp"})
        assert [p for p in problems if "project_photo" in p.lower()] == []

    def test_project_photo_live_with_deps_zero_problems(self):
        """PROJECT_PHOTO_LIVE=1 with trimesh + svgwrite installed → zero
        project_photo problems (both are declared dependencies in the synced env)."""
        problems = verify_stage_config({
            "PROJECT_PHOTO_LIVE": "1",
            "STORAGE_LOCAL_ROOT": "/tmp",
        })
        proj_problems = [p for p in problems if "project_photo" in p.lower()]
        assert proj_problems == [], f"unexpected: {problems}"

    def test_project_photo_live_without_trimesh_is_a_problem(self, monkeypatch):
        """PROJECT_PHOTO_LIVE=1 with trimesh not importable reports a problem."""
        import builtins

        real_import = builtins.__import__

        def fake_import(name, *args, **kwargs):
            if name == "trimesh":
                raise ImportError("simulated missing trimesh")
            return real_import(name, *args, **kwargs)

        monkeypatch.setattr(builtins, "__import__", fake_import)
        problems = verify_stage_config({
            "PROJECT_PHOTO_LIVE": "1",
            "STORAGE_LOCAL_ROOT": "/tmp",
        })
        assert "trimesh" in " ".join(problems)

    def test_project_photo_live_without_svgwrite_is_a_problem(self, monkeypatch):
        """PROJECT_PHOTO_LIVE=1 with svgwrite not importable reports a problem."""
        import builtins

        real_import = builtins.__import__

        def fake_import(name, *args, **kwargs):
            if name == "svgwrite":
                raise ImportError("simulated missing svgwrite")
            return real_import(name, *args, **kwargs)

        monkeypatch.setattr(builtins, "__import__", fake_import)
        problems = verify_stage_config({
            "PROJECT_PHOTO_LIVE": "1",
            "STORAGE_LOCAL_ROOT": "/tmp",
        })
        assert "svgwrite" in " ".join(problems)


class TestVerifyStageConfigAllDisabled:
    """When no live flags are set and STORAGE_LOCAL_ROOT is set, zero problems."""

    def test_fully_local_env_zero_problems(self, tmp_path: Path):
        """This is the TEST env baseline: all stages using fixture/local paths."""
        env = {
            "STORAGE_LOCAL_ROOT": str(tmp_path),
            "WESM_FIXTURE_PATH": str(tmp_path / "wesm_index.json"),
            "SAM2_BACKEND": "local",
            # SIDECAR_SHARED_SECRET present (required for auth, not a boot check)
            "SIDECAR_SHARED_SECRET": "test-shared-secret",
        }
        problems = verify_stage_config(env)
        assert problems == [], f"unexpected problems: {problems}"

    def test_empty_env_still_reports_storage_problem(self):
        """Without STORAGE_LOCAL_ROOT and no live creds, storage IS a problem.

        This is the one case where an empty env is NOT OK — storage is always
        active (either local or live), so missing both paths is a misconfiguration.
        """
        problems = verify_stage_config({})
        # Should see at least storage problems
        storage_related = [
            p for p in problems
            if any(v in p for v in ("STORAGE_BUCKET", "STORAGE_ENDPOINT", "STORAGE_ACCESS_KEY", "STORAGE_SECRET_KEY"))
        ]
        assert len(storage_related) > 0


# ---------------------------------------------------------------------------
# run_boot_checks — raise/warn wrapper tests
# ---------------------------------------------------------------------------


class TestRunBootChecks:
    """run_boot_checks reads os.environ. Patch it to a clean controlled dict."""

    def _run_with_env(self, env: dict[str, str]) -> None:
        with patch.dict(os.environ, env, clear=True):
            run_boot_checks()

    # -- production mode raises -----------------------------------------------

    def test_prod_with_problems_raises(self, tmp_path: Path):
        env = {
            "SIDECAR_ENV": "production",
            "LIDAR_LIVE": "1",
            # WESM_GPKG_PATH missing → problem
            "STORAGE_LOCAL_ROOT": str(tmp_path),
        }
        with pytest.raises(RuntimeError, match="WESM_GPKG_PATH"):
            self._run_with_env(env)

    def test_prod_clean_env_does_not_raise(self, tmp_path: Path):
        real_gpkg = tmp_path / "wesm.gpkg"
        real_gpkg.write_bytes(b"fake")
        env = {
            "SIDECAR_ENV": "production",
            "LIDAR_LIVE": "1",
            "WESM_GPKG_PATH": str(real_gpkg),
            "STORAGE_LOCAL_ROOT": str(tmp_path),
            "SAM2_BACKEND": "local",
        }
        # Should not raise
        self._run_with_env(env)

    # -- development mode warns -----------------------------------------------

    def test_dev_with_problems_logs_warning_no_raise(self, tmp_path: Path, caplog):
        env = {
            "SIDECAR_ENV": "development",
            "LIDAR_LIVE": "1",
            # WESM_GPKG_PATH missing → problem
            "STORAGE_LOCAL_ROOT": str(tmp_path),
        }
        with caplog.at_level(logging.WARNING, logger="app.boot_checks"):
            self._run_with_env(env)  # must not raise

        assert any("WESM_GPKG_PATH" in r.message for r in caplog.records), (
            f"expected warning about WESM_GPKG_PATH; got: {[r.message for r in caplog.records]}"
        )

    def test_unset_sidecar_env_defaults_to_dev_warns_not_raise(self, tmp_path: Path, caplog):
        """Default (SIDECAR_ENV unset) behaves as development — warns, no raise."""
        env = {
            "LIDAR_LIVE": "1",
            # no WESM_GPKG_PATH, no SIDECAR_ENV
            "STORAGE_LOCAL_ROOT": str(tmp_path),
        }
        with caplog.at_level(logging.WARNING, logger="app.boot_checks"):
            self._run_with_env(env)  # must not raise

        assert any("WESM_GPKG_PATH" in r.message for r in caplog.records)

    def test_dev_clean_env_no_warning(self, tmp_path: Path, caplog):
        env = {
            "SIDECAR_ENV": "development",
            "STORAGE_LOCAL_ROOT": str(tmp_path),
            "SAM2_BACKEND": "local",
        }
        with caplog.at_level(logging.WARNING, logger="app.boot_checks"):
            self._run_with_env(env)

        boot_warnings = [r for r in caplog.records if r.name == "app.boot_checks"]
        assert boot_warnings == []

    # -- the default test-env produces zero problems --------------------------

    def test_default_test_env_zero_problems(self):
        """Verify that the conftest.py defaults produce zero boot problems.

        This ensures the existing test suite can still boot the app (via
        TestClient) without triggering a raise in run_boot_checks.
        The conftest sets STORAGE_LOCAL_ROOT + WESM_FIXTURE_PATH + no live flags.
        """
        # Simulate the conftest defaults (already set in os.environ by conftest.py
        # when this module loads, but we test explicitly for documentation).
        assert os.environ.get("STORAGE_LOCAL_ROOT"), "conftest should have set STORAGE_LOCAL_ROOT"
        problems = verify_stage_config(dict(os.environ))
        assert problems == [], f"test env has boot problems: {problems}"

    def test_prod_raises_runtime_error_with_stage_name(self, tmp_path: Path):
        """Error message must name the stage (lidar/storage/sam2/imagery)."""
        env = {
            "SIDECAR_ENV": "production",
            "LIDAR_LIVE": "1",
            "STORAGE_LOCAL_ROOT": str(tmp_path),
        }
        with pytest.raises(RuntimeError) as exc_info:
            self._run_with_env(env)
        # Message should mention the stage name
        assert "lidar" in str(exc_info.value).lower() or "WESM_GPKG_PATH" in str(exc_info.value)
