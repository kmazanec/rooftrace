import os
from pathlib import Path

# Force a deterministic test secret BEFORE app.main (and thus app.auth, which
# reads SIDECAR_SHARED_SECRET once at import) is imported. Use `=`, NOT
# setdefault: CI sets SIDECAR_SHARED_SECRET=ci-shared-secret in the job env, and
# setdefault would leave that in place while the test's bearer header is the
# fixed value — a guaranteed 401. Owning the secret here makes the suite
# independent of the ambient env.
os.environ["SIDECAR_SHARED_SECRET"] = "test-shared-secret"

# RoofTrace's running product (dev + prod) always uses REAL data; fixtures are an
# explicit opt-DOWN that ONLY the test suites set (see app/flags.py). The default
# flipped from "fixture unless *_LIVE=1" to "real unless *_FIXTURE=1", so the
# hermetic suite must now opt down explicitly: real satellite-imagery/LiDAR/map-render
# would otherwise hit Mapbox/3DEP + need pdal/Modal/Mapbox creds. Set with
# `=` (not setdefault) so the suite is hermetic regardless of an ambient real env.
os.environ["IMAGERY_FIXTURE"] = "1"
os.environ["LIDAR_FIXTURE"] = "1"
os.environ["RENDER_IMAGES_FIXTURE"] = "1"
os.environ["PROJECT_PHOTO_FIXTURE"] = "1"  # serve the 1x1 placeholder, not the real render
os.environ["SAM2_BACKEND"] = "local"  # the deterministic local stub (not Modal)
os.environ["EPT_INDEX_FIXTURE"] = "1"

# Default the storage local-root to the image-tile fixtures so the suite is
# self-sufficient under a plain `uv run pytest` (CI doesn't pass STORAGE_LOCAL_ROOT).
# setdefault so a test/run that points it elsewhere still wins.
os.environ.setdefault("STORAGE_LOCAL_ROOT", str(Path(__file__).resolve().parent / "fixtures" / "f07"))

# Default the WESM fixture index too, so the LiDAR coverage tests resolve it
# without the caller exporting WESM_FIXTURE_PATH.
os.environ.setdefault("WESM_FIXTURE_PATH", str(Path(__file__).resolve().parent / "fixtures" / "f06" / "wesm_index.json"))

# Default the EPT boundaries fixture path so the loader test and boot-check test
# resolve it without the caller exporting EPT_INDEX_FIXTURE_PATH.
os.environ.setdefault("EPT_INDEX_FIXTURE_PATH", str(Path(__file__).resolve().parent / "fixtures" / "ept_boundaries_sample.json"))
