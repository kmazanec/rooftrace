import os
from pathlib import Path

# Force a deterministic test secret BEFORE app.main (and thus app.auth, which
# reads SIDECAR_SHARED_SECRET once at import) is imported. Use `=`, NOT
# setdefault: CI sets SIDECAR_SHARED_SECRET=ci-shared-secret in the job env, and
# setdefault would leave that in place while the test's bearer header is the
# fixed value — a guaranteed 401. Owning the secret here makes the suite
# independent of the ambient env.
os.environ["SIDECAR_SHARED_SECRET"] = "test-shared-secret"

# Default the storage local-root to the F-07 image-tile fixtures so the suite is
# self-sufficient under a plain `uv run pytest` (CI doesn't pass STORAGE_LOCAL_ROOT).
# setdefault so a test/run that points it elsewhere still wins.
os.environ.setdefault("STORAGE_LOCAL_ROOT", str(Path(__file__).resolve().parent / "fixtures" / "f07"))

# Default the WESM fixture index too, so the LiDAR coverage tests resolve it
# without the caller exporting WESM_FIXTURE_PATH.
os.environ.setdefault("WESM_FIXTURE_PATH", str(Path(__file__).resolve().parent / "fixtures" / "f06" / "wesm_index.json"))
