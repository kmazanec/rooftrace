# syntax=docker/dockerfile:1.7
#
# The sidecar needs PDAL (with COPC support) + GDAL for the LiDAR ingest stage
# (F-06, ADR-003). PDAL is not a pip package — it ships via conda-forge — so the
# image is built on micromamba and PDAL/GDAL are installed from conda-forge.
# The Python application deps still come from the committed uv lockfile, so CI
# (which runs pytest under plain python via uv, with the PDAL import guarded)
# and the image stay in sync on everything except the conda-only geo stack.
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
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project --inexact

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
