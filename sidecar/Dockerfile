# syntax=docker/dockerfile:1.7
FROM python:3.12-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PROJECT_ENVIRONMENT=/usr/local

WORKDIR /app

# Install uv (fast, reproducible installs from the committed lockfile).
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# Install deps from the lockfile FIRST (cached layer until lock/pyproject
# change) — reproducible, no version drift between CI and the image.
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

# Copy source.
COPY app ./app

# Non-root user (defense in depth even though sidecar is internal-only).
RUN useradd --create-home --shell /bin/bash sidecar && chown -R sidecar:sidecar /app
USER sidecar

EXPOSE 8000

# Healthcheck (the docker-internal one; Kamal's healthcheck on the Rails side
# is what fronts /health to the world).
HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health',timeout=2).status==200 else 1)"

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
