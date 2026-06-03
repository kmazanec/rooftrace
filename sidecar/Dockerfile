# syntax=docker/dockerfile:1.7
#
# The sidecar needs PDAL (with COPC support) + GDAL for the LiDAR ingest stage
# (ADR-003). PDAL is not a pip package — it ships via conda-forge — so the image
# is built on micromamba and the geo stack (PDAL/GDAL/rasterio) is installed from
# conda-forge so they link the SAME GDAL. (rasterio is retained as a declared dep
# but no longer drives imagery: ADR-002 was amended to fetch satellite imagery
# from Mapbox, not NAIP COGs.) The Python application deps still come from the
# committed uv lockfile, so CI (which runs pytest under plain python via uv, with
# the PDAL import guarded) and the image stay in sync; the conda-forge rasterio
# overlays the lockfile's pip rasterio in the image (see the conda step below).
FROM mambaorg/micromamba:1.5-bookworm-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PROJECT_ENVIRONMENT=/opt/conda

USER root
WORKDIR /app

# PDAL (COPC/EPT readers) + GDAL + a matching Python from conda-forge. This is
# the base interpreter the app runs on; uv installs the pip deps into it.
RUN micromamba install -y -n base -c conda-forge \
      python=3.12 pdal python-pdal gdal && \
    micromamba clean --all --yes

# Point GDAL/PROJ at the conda PROJ data dir. Without it, PDAL's PROJ context
# logs noisy `pj_obj_create: Open of /opt/conda/share/proj failed` lines on every
# reprojection (the transform still succeeds via fallback, but the noise hides
# real errors). pyproj uses its own bundled data dir and is unaffected either way.
ENV PROJ_DATA=/opt/conda/share/proj

# uv for the pip-managed application deps (fastapi, numpy, shapely, pyproj, ...).
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# Install the pip app-deps INTO the conda env (UV_PROJECT_ENVIRONMENT=/opt/conda).
# --inexact is load-bearing: without it `uv sync` prunes everything not in the
# lockfile, which would delete the conda-installed pdal/gdal/python-pdal and
# leave the LiDAR stage unable to import pdal at runtime.
#
# This installs the lockfile's pip rasterio (which bundles its own GDAL). We
# OVERLAY it with conda-forge rasterio in the next step so the runtime rasterio
# links the SAME GDAL as the conda pdal/gdal — avoiding two GDAL copies in one
# process. The pip rasterio is left in pyproject/uv.lock so CI (plain uv, no
# conda) can resolve and import it for the hermetic imagery tests.
#
# The base stage installs the PROD (--no-dev) dependency set: this is the lean
# runtime closure AND it provides the `playwright` pip package that the browser
# install below needs. The `test` stage layers the dev group (pytest/...) on top
# with an incremental `uv sync` (no --no-dev); the `prod` stage adds nothing.
# Everything in `base` — conda geo stack, this sync, the conda-rasterio overlay,
# playwright+Chromium, the app COPYs — is a shared layer built once.
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project --inexact

# Overlay rasterio from conda-forge AFTER uv sync so the conda build (linked to
# the conda GDAL/PDAL stack) is the one that wins at runtime. Ordering matters:
# conda last → conda rasterio + its GDAL are authoritative and mutually
# consistent with pdal/gdal.
RUN micromamba install -y -n base -c conda-forge rasterio && \
    micromamba clean --all --yes

# Playwright's Chromium + its apt system libraries for the headless top-down map
# render (ADR-014, gated by RENDER_IMAGES_LIVE=1). Installed as root so
# --with-deps can apt-get the browser's shared libs; the browser is dropped into
# a shared location all users can read.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/playwright
RUN /opt/conda/bin/python -m playwright install --with-deps chromium && \
    chmod -R a+rX /opt/playwright

COPY app ./app
COPY contracts ./contracts

# ---------------------------------------------------------------------------
# test target: same geo/runtime stack as prod PLUS the dev dependency-group
# (pytest, jsonschema, pytest-recording, ruff, httpx, pillow) so the suite runs
# INSIDE this image in CI — testing the real conda geo path, not a divergent
# slim env. CI runs pytest in this image and ALSO boots it as the sibling
# sidecar for the Rails suite (it has a runnable uvicorn + the app + fixtures).
# The contract tests read repo-root files (shared/pipeline_schema.json,
# spec/fixtures/pipeline/) that live OUTSIDE the sidecar build context, so CI
# mounts the repo root read-only at run time and points the conftest paths at
# it — this image is not widened to the repo root. Runs as root (no USER switch)
# so pytest can write caches/tmp freely.
# ---------------------------------------------------------------------------
FROM base AS test
# Incremental sync WITHOUT --no-dev adds the dev group (pytest/jsonschema/...) on
# top of base's prod closure. --inexact keeps the conda pdal/gdal/rasterio.
RUN uv sync --frozen --no-install-project --inexact
# tests/ is the suite; validation/ is the eval+report harness it imports as a
# top-level package (pythonpath=["."], pyproject.toml). Both are test-only and
# must NOT be in the prod image. (The 3.3GB data/WESM.gpkg is never copied — it's
# bind-mounted at runtime in prod; the suite uses the fixture wesm_index.json.)
COPY tests ./tests
COPY validation ./validation
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]

# ---------------------------------------------------------------------------
# prod target (default — `docker build` with no --target builds this): lean,
# --no-dev, non-root. This is the image the deploy runs. base already synced the
# --no-dev closure, so there's nothing more to install here — prod just adds the
# non-root user + runtime healthcheck.
# ---------------------------------------------------------------------------
FROM base AS prod

RUN useradd --create-home --shell /bin/bash sidecar && chown -R sidecar:sidecar /app
USER sidecar

EXPOSE 8000

# Use the conda interpreter by ABSOLUTE path: Docker healthchecks run the CMD
# via /bin/sh with the image's base PATH (the micromamba entrypoint that puts
# /opt/conda/bin on PATH does NOT run for healthchecks), so bare `python` is not
# found on this conda base image.
HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD /opt/conda/bin/python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health',timeout=2).status==200 else 1)"

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
