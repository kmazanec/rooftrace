# syntax=docker/dockerfile:1.7
FROM python:3.12-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# Install runtime deps first (cached layer until pyproject changes).
COPY pyproject.toml ./
RUN pip install --upgrade pip \
 && pip install \
      "fastapi>=0.115" \
      "uvicorn[standard]>=0.32" \
      "pydantic>=2.9"

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
