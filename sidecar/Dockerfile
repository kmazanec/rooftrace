# syntax=docker/dockerfile:1.7
#
# The sidecar needs PDAL (with COPC support) + GDAL for the LiDAR ingest stage
# (ADR-003) and rasterio for the live NAIP imagery stage. PDAL is not a pip
# package — it ships via conda-forge — so the image is built on micromamba and
# the geo stack (PDAL/GDAL/rasterio) is installed from conda-forge so all three
# link the SAME GDAL. The Python application deps still come from the committed
# uv lockfile, so CI (which runs pytest under plain python via uv, with the PDAL
# import guarded) and the image stay in sync; the conda-forge rasterio overlays
# the lockfile's pip rasterio in the image (see the conda step below).
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
