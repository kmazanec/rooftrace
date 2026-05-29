"""Tests for sidecar boot-time config validation.

`verify_stage_config` is a pure function that accepts an env-var mapping and
returns human-readable problem strings for every enabled-but-misconfigured
stage. Tested here without booting the FastAPI app.

The running product (dev + prod) always uses REAL data, so every stage's real
path is ENABLED BY DEFAULT and its requirements are checked by default. A stage
is skipped only when its fixture opt-down flag is set (the test suites):
IMAGERY_FIXTURE=1 / LIDAR_FIXTURE=1 / RENDER_IMAGES_FIXTURE=1 / SAM2_BACKEND=local
/ STORAGE_LOCAL_ROOT=<dir>. `run_boot_checks` RAISES on any problem in BOTH dev
and prod — a missing real-path prerequisite is a loud boot failure, never a
silent degrade. The test suites avoid it by setting the opt-down flags.
"""

from __future__ import annotations

import os
from pathlib import Path
from unittest.mock import patch

import pytest

from app.boot_checks import run_boot_checks, verify_stage_config

# A full set of fixture opt-down flags + local storage: the test-suite baseline
# that disables every credentialed real-path check. Individual test classes start
# from this and selectively re-enable ONE stage's real path to isolate its check.
_ALL_FIXTURE = {
    "IMAGERY_FIXTURE": "1",
    "LIDAR_FIXTURE": "1",
    "RENDER_IMAGES_FIXTURE": "1",
    "PROJECT_PHOTO_FIXTURE": "1",
    "SAM2_BACKEND": "local",
    "STORAGE_LOCAL_ROOT": "/tmp",
}


# ---------------------------------------------------------------------------
# verify_stage_config — pure-function tests
# ---------------------------------------------------------------------------


class TestVerifyStageConfigLidar:
    """LiDAR real path is default; needs WESM_GPKG_PATH (existing file) + pdal.
    LIDAR_FIXTURE=1 disables the check (the test suites)."""

    def test_real_lidar_missing_wesm_path(self, tmp_path: Path):
        # Opt down everything except lidar, so only lidar problems surface.
        env = {**_ALL_FIXTURE, "LIDAR_FIXTURE": "0"}
        problems = verify_stage_config(env)
        joined = " ".join(problems)
        assert "WESM_GPKG_PATH" in joined

    def test_real_lidar_nonexistent_wesm_path(self, tmp_path: Path):
        bogus = str(tmp_path / "does_not_exist.gpkg")
        env = {**_ALL_FIXTURE, "LIDAR_FIXTURE": "0", "WESM_GPKG_PATH": bogus}
        problems = verify_stage_config(env)
        assert "WESM_GPKG_PATH" in " ".join(problems)

    def test_real_lidar_valid_wesm_path_and_pdal(self, tmp_path: Path):
        # pdal is conda-only and absent in the plain uv test env, so the real
        # lidar path always reports the pdal problem here — assert WESM is happy
        # (the file exists) and that pdal is the only remaining lidar complaint.
        real_file = tmp_path / "wesm.gpkg"
        real_file.write_bytes(b"fake gpkg")
        env = {**_ALL_FIXTURE, "LIDAR_FIXTURE": "0", "WESM_GPKG_PATH": str(real_file)}
        problems = verify_stage_config(env)
        lidar_problems = [p for p in problems if p.startswith("[lidar]")]
        assert not any("WESM_GPKG_PATH" in p for p in lidar_problems)

    def test_lidar_fixture_disables_check(self):
        """LIDAR_FIXTURE=1 (the default test posture) → no lidar check."""
        problems = verify_stage_config(_ALL_FIXTURE)
        assert [p for p in problems if p.startswith("[lidar]")] == []


class TestVerifyStageConfigStorage:
    """Storage: live Spaces is the real default (active when STORAGE_LOCAL_ROOT
    is NOT set). STORAGE_LOCAL_ROOT=<dir> is the test opt-down."""

    _FULL_LIVE_STORAGE = {
        "IMAGERY_FIXTURE": "1",
        "LIDAR_FIXTURE": "1",
        "RENDER_IMAGES_FIXTURE": "1",
        "SAM2_BACKEND": "local",
        "STORAGE_BUCKET": "rooftrace",
        "STORAGE_ENDPOINT": "https://nyc3.digitaloceanspaces.com",
        "STORAGE_ACCESS_KEY": "key",
        "STORAGE_SECRET_KEY": "secret",
    }

    def test_no_local_root_missing_all_creds(self):
        """No STORAGE_LOCAL_ROOT → live storage path, all four vars required."""
        env = {k: v for k, v in _ALL_FIXTURE.items() if k != "STORAGE_LOCAL_ROOT"}
        problems = verify_stage_config(env)
        joined = " ".join(problems)
        assert all(
            v in joined
            for v in ("STORAGE_BUCKET", "STORAGE_ENDPOINT", "STORAGE_ACCESS_KEY", "STORAGE_SECRET_KEY")
        )

    def test_no_local_root_missing_some_creds(self):
        env = {k: v for k, v in _ALL_FIXTURE.items() if k != "STORAGE_LOCAL_ROOT"}
        env |= {
            "STORAGE_BUCKET": "rooftrace",
            "STORAGE_ENDPOINT": "https://nyc3.digitaloceanspaces.com",
        }
        joined = " ".join(verify_stage_config(env))
        assert "STORAGE_ACCESS_KEY" in joined
        assert "STORAGE_SECRET_KEY" in joined
        assert "STORAGE_BUCKET" not in joined
        assert "STORAGE_ENDPOINT" not in joined

    def test_local_root_set_no_problems(self, tmp_path: Path):
        problems = verify_stage_config({**_ALL_FIXTURE, "STORAGE_LOCAL_ROOT": str(tmp_path)})
        assert [p for p in problems if "STORAGE_" in p] == []

    def test_all_live_creds_present_no_problems(self):
        problems = verify_stage_config(self._FULL_LIVE_STORAGE)
        assert [p for p in problems if "STORAGE_" in p] == []


class TestVerifyStageConfigSam2:
    """SAM2 real path (modal) is default; needs MODAL_TOKEN_ID + MODAL_TOKEN_SECRET.
    SAM2_BACKEND=local is the test opt-down."""

    def _real_sam2(self, extra: dict[str, str]) -> dict[str, str]:
        env = {**_ALL_FIXTURE, "SAM2_BACKEND": "modal"}
        env.update(extra)
        return env

    def test_real_sam2_missing_both_tokens(self):
        joined = " ".join(verify_stage_config(self._real_sam2({})))
        assert "MODAL_TOKEN_ID" in joined
        assert "MODAL_TOKEN_SECRET" in joined

    def test_real_sam2_missing_one_token(self):
        joined = " ".join(verify_stage_config(self._real_sam2({"MODAL_TOKEN_ID": "id123"})))
        assert "MODAL_TOKEN_SECRET" in joined
        assert "MODAL_TOKEN_ID" not in joined

    def test_real_sam2_both_tokens_present_no_problems(self):
        env = self._real_sam2({"MODAL_TOKEN_ID": "id123", "MODAL_TOKEN_SECRET": "sec456"})
        assert [p for p in verify_stage_config(env) if "MODAL_" in p] == []

    def test_sam2_local_backend_no_modal_check(self):
        """SAM2_BACKEND=local (the test opt-down) → no Modal check."""
        assert [p for p in verify_stage_config(_ALL_FIXTURE) if "MODAL_" in p] == []

    def test_sam2_unset_backend_defaults_to_real(self):
        """Unset SAM2_BACKEND defaults to the REAL (modal) path → Modal tokens checked."""
        env = {k: v for k, v in _ALL_FIXTURE.items() if k != "SAM2_BACKEND"}
        joined = " ".join(verify_stage_config(env))
        assert "MODAL_TOKEN_ID" in joined


class TestVerifyStageConfigImagery:
    """Imagery real path (Mapbox Static Images, ADR-002) is default; needs
    MAPBOX_PUBLIC_TOKEN. IMAGERY_FIXTURE=1 is the test opt-down. (No AWS/rasterio
    dependency — the stage no longer reads NAIP COGs.)"""

    def test_imagery_fixture_disables_check(self):
        problems = verify_stage_config(_ALL_FIXTURE)
        assert [p for p in problems if "imagery" in p.lower()] == []

    def test_real_imagery_with_token_zero_problems(self):
        """Real imagery (IMAGERY_FIXTURE unset) + Mapbox token → zero imagery problems."""
        env = {**_ALL_FIXTURE, "IMAGERY_FIXTURE": "0", "MAPBOX_PUBLIC_TOKEN": "pk.test"}
        problems = verify_stage_config(env)
        assert [p for p in problems if "imagery" in p.lower()] == [], f"got: {problems}"

    def test_real_imagery_missing_token_is_a_problem(self):
        """Real imagery without MAPBOX_PUBLIC_TOKEN → flagged (fail fast at boot)."""
        env = {**_ALL_FIXTURE, "IMAGERY_FIXTURE": "0"}  # no MAPBOX_PUBLIC_TOKEN
        joined = " ".join(verify_stage_config(env))
        assert "MAPBOX_PUBLIC_TOKEN" in joined


class TestVerifyStageConfigRenderImages:
    """Render-images real path is default; needs MAPBOX_PUBLIC_TOKEN + playwright.
    RENDER_IMAGES_FIXTURE=1 is the test opt-down."""

    def test_render_images_fixture_disables_check(self):
        assert [p for p in verify_stage_config(_ALL_FIXTURE) if "render_images" in p.lower()] == []

    def test_real_render_images_missing_token_is_a_problem(self):
        env = {**_ALL_FIXTURE, "RENDER_IMAGES_FIXTURE": "0"}
        assert "MAPBOX_PUBLIC_TOKEN" in " ".join(verify_stage_config(env))

    def test_real_render_images_with_token_and_playwright_zero_problems(self):
        env = {**_ALL_FIXTURE, "RENDER_IMAGES_FIXTURE": "0", "MAPBOX_PUBLIC_TOKEN": "pk.test"}
        problems = verify_stage_config(env)
        assert [p for p in problems if "render_images" in p.lower()] == [], f"got: {problems}"


class TestVerifyStageConfigFuseCapture:
    """Fuse-capture is always real (no fixture path); open3d must be importable.
    open3d IS present in the synced test env."""

    def test_fuse_capture_with_open3d_zero_problems(self):
        problems = verify_stage_config(_ALL_FIXTURE)
        assert [p for p in problems if "fuse_capture" in p.lower()] == [], f"got: {problems}"

    def test_fuse_capture_without_open3d_is_a_problem(self, monkeypatch):
        """open3d unimportable → flagged even with all fixture flags set (it's always-real)."""
        import builtins

        real_import = builtins.__import__

        def fake_import(name, *args, **kwargs):
            if name == "open3d":
                raise ImportError("simulated missing open3d")
            return real_import(name, *args, **kwargs)

        monkeypatch.setattr(builtins, "__import__", fake_import)
        assert "open3d" in " ".join(verify_stage_config(_ALL_FIXTURE))


class TestVerifyStageConfigProjectPhoto:
    """Project-photo real path is default; needs trimesh + rtree + svgwrite
    importable. PROJECT_PHOTO_FIXTURE=1 is the test opt-down (the 1x1 placeholder).
    All three deps ARE installed in the synced test env. The `_REAL_PP` baseline
    opts down everything EXCEPT project_photo, so only its problems surface."""

    # Opt down everything except project_photo (mirrors the lidar/imagery classes).
    _REAL_PP = {**_ALL_FIXTURE, "PROJECT_PHOTO_FIXTURE": "0"}

    def test_project_photo_fixture_disables_check(self):
        """PROJECT_PHOTO_FIXTURE=1 (the default test posture) → no project_photo check."""
        assert [p for p in verify_stage_config(_ALL_FIXTURE) if "project_photo" in p.lower()] == []

    def test_real_project_photo_with_deps_zero_problems(self):
        """Real project_photo (fixture flag unset) + deps installed → zero problems."""
        problems = verify_stage_config(self._REAL_PP)
        proj_problems = [p for p in problems if "project_photo" in p.lower()]
        assert proj_problems == [], f"unexpected: {problems}"

    def test_real_project_photo_without_trimesh_is_a_problem(self, monkeypatch):
        """Real project_photo with trimesh unimportable → flagged (broken image)."""
        import builtins

        real_import = builtins.__import__

        def fake_import(name, *args, **kwargs):
            if name == "trimesh":
                raise ImportError("simulated missing trimesh")
            return real_import(name, *args, **kwargs)

        monkeypatch.setattr(builtins, "__import__", fake_import)
        assert "trimesh" in " ".join(verify_stage_config(self._REAL_PP))

    def test_real_project_photo_without_rtree_is_a_problem(self, monkeypatch):
        """Real project_photo with rtree unimportable → flagged."""
        import builtins

        real_import = builtins.__import__

        def fake_import(name, *args, **kwargs):
            if name == "rtree":
                raise ImportError("simulated missing rtree")
            return real_import(name, *args, **kwargs)

        monkeypatch.setattr(builtins, "__import__", fake_import)
        assert "rtree" in " ".join(verify_stage_config(self._REAL_PP))

    def test_real_project_photo_without_svgwrite_is_a_problem(self, monkeypatch):
        """Real project_photo with svgwrite unimportable → flagged."""
        import builtins

        real_import = builtins.__import__

        def fake_import(name, *args, **kwargs):
            if name == "svgwrite":
                raise ImportError("simulated missing svgwrite")
            return real_import(name, *args, **kwargs)

        monkeypatch.setattr(builtins, "__import__", fake_import)
        assert "svgwrite" in " ".join(verify_stage_config(self._REAL_PP))


class TestVerifyStageConfigTestBaseline:
    """The test-suite opt-down baseline produces zero problems."""

    def test_all_fixture_flags_zero_problems(self, tmp_path: Path):
        env = {**_ALL_FIXTURE, "STORAGE_LOCAL_ROOT": str(tmp_path)}
        problems = verify_stage_config(env)
        assert problems == [], f"unexpected problems: {problems}"

    def test_empty_env_reports_real_path_problems(self):
        """A bare env (no fixture flags) runs the REAL defaults → many problems
        (storage creds, WESM/pdal, Modal tokens, Mapbox token)."""
        problems = verify_stage_config({})
        joined = " ".join(problems)
        assert "STORAGE_" in joined
        assert "MODAL_TOKEN_ID" in joined
        assert "MAPBOX_PUBLIC_TOKEN" in joined


# ---------------------------------------------------------------------------
# run_boot_checks — raises on any problem (dev AND prod)
# ---------------------------------------------------------------------------


class TestRunBootChecks:
    """run_boot_checks reads os.environ. Patch it to a clean controlled dict."""

    def _run_with_env(self, env: dict[str, str]) -> None:
        with patch.dict(os.environ, env, clear=True):
            run_boot_checks()

    def test_prod_with_problems_raises(self, tmp_path: Path):
        env = {**_ALL_FIXTURE, "SIDECAR_ENV": "production", "LIDAR_FIXTURE": "0",
               "STORAGE_LOCAL_ROOT": str(tmp_path)}
        with pytest.raises(RuntimeError, match="WESM_GPKG_PATH|pdal"):
            self._run_with_env(env)

    def test_dev_with_problems_also_raises(self, tmp_path: Path):
        """Dev runs the real product too — a missing real-path prereq RAISES (no
        silent warn-and-continue). This is the key inversion behavior."""
        env = {**_ALL_FIXTURE, "SIDECAR_ENV": "development", "LIDAR_FIXTURE": "0",
               "STORAGE_LOCAL_ROOT": str(tmp_path)}
        with pytest.raises(RuntimeError, match="WESM_GPKG_PATH|pdal"):
            self._run_with_env(env)

    def test_unset_sidecar_env_also_raises(self, tmp_path: Path):
        env = {**_ALL_FIXTURE, "LIDAR_FIXTURE": "0", "STORAGE_LOCAL_ROOT": str(tmp_path)}
        with pytest.raises(RuntimeError):
            self._run_with_env(env)

    def test_clean_fixture_env_does_not_raise(self, tmp_path: Path):
        """The test-suite opt-down baseline boots cleanly in any SIDECAR_ENV."""
        env = {**_ALL_FIXTURE, "SIDECAR_ENV": "production", "STORAGE_LOCAL_ROOT": str(tmp_path)}
        self._run_with_env(env)  # must not raise

    def test_default_test_env_zero_problems(self):
        """The conftest.py opt-down defaults produce zero boot problems, so the
        suite can boot the app (via TestClient) without tripping run_boot_checks."""
        assert os.environ.get("STORAGE_LOCAL_ROOT"), "conftest should have set STORAGE_LOCAL_ROOT"
        assert os.environ.get("IMAGERY_FIXTURE") == "1", "conftest should have opted down imagery"
        problems = verify_stage_config(dict(os.environ))
        assert problems == [], f"test env has boot problems: {problems}"

    def test_raise_message_names_the_stage(self, tmp_path: Path):
        env = {**_ALL_FIXTURE, "SIDECAR_ENV": "production", "LIDAR_FIXTURE": "0",
               "STORAGE_LOCAL_ROOT": str(tmp_path)}
        with pytest.raises(RuntimeError) as exc_info:
            self._run_with_env(env)
        assert "lidar" in str(exc_info.value).lower()
