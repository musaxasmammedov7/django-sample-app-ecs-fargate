# syntax=docker/dockerfile:1.7
# =============================================================================
# Optimized multi-stage Dockerfile for the Healthchecks Django application.
#
# Optimization changes (details in image-optimization/README.md):
#   - venv is cleaned (pip/setuptools/wheel removed, __pycache__ purged,
#     permissions set) inside the BUILDER stage, so no dead weight is copied
#     into the runtime image and no chmod layer duplicates the venv.
#   - application files are copied with COPY --chown/--chmod (no extra chmod
#     RUN layer; entrypoint keeps its 0755 exec bit from git).
#   - only runtime directories are copied (hc/, templates/, static/, manage.py,
#     docker/entrypoint.sh) instead of the whole build context.
#   - BuildKit cache mounts for apt and pip speed up repeated builds.
#   - .dockerignore keeps the build context small (see .dockerignore).
#
# Security controls from Task 3 are preserved: digest-pinned base, minimal
# runtime packages, non-root user, secrets never baked into layers.
# =============================================================================

########################
# Stage 1: builder
########################
FROM python:3.12-slim-bookworm@sha256:9901e0a8d75037d8242ed43155cbcb2d1f61be1356383d8054afb59fd50e39c4 AS builder

# Reproducible, quiet builds. PIP cache is handled by a BuildKit cache mount,
# so it never lands in the image layer.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Build-time system dependencies (compile C extensions).
# hadolint ignore=DL3008
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential \
        pkg-config \
        libpq-dev \
        libcurl4-openssl-dev \
        libssl-dev \
        libffi-dev \
        zlib1g-dev; \
    rm -rf /var/lib/apt/lists/*

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

WORKDIR /build
COPY requirements.txt requirements-prod.txt ./
# Install dependencies, then clean the venv while we are still in the builder
# stage so the runtime image only receives the minimal virtualenv.
# hadolint ignore=DL3013
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --upgrade pip setuptools wheel \
    && pip install -r requirements.txt -r requirements-prod.txt \
    && pip uninstall -y pip setuptools wheel \
    && find /opt/venv -type d -name __pycache__ -prune -exec rm -rf {} + \
    && chmod -R go-w /opt/venv

########################
# Stage 2: runtime
########################
FROM python:3.12-slim-bookworm@sha256:9901e0a8d75037d8242ed43155cbcb2d1f61be1356383d8054afb59fd50e39c4 AS runtime

LABEL org.opencontainers.image.title="django-sample-app" \
      org.opencontainers.image.description="Healthchecks Django application (optimized, hardened)" \
      org.opencontainers.image.source="https://github.com/musaxasmammedov7/django-sample-app-ecs-fargate" \
      org.opencontainers.image.licenses="BSD-3-Clause"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:${PATH}" \
    HOME=/app \
    DJANGO_SETTINGS_MODULE=hc.settings

# Runtime system dependencies only.
# hadolint ignore=DL3008
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libpq5 \
        libcurl4 \
        ca-certificates \
        tzdata; \
    apt-get install -y --no-install-recommends --only-upgrade libpcre2-8-0; \
    rm -rf /var/lib/apt/lists/*; \
    groupadd --system --gid 1000 app; \
    useradd --system --uid 1000 --gid app --create-home --home-dir /app --shell /usr/sbin/nologin app

# Harden the filesystem: strip setuid/setgid bits and remove unused base
# interpreter tooling (whiteouts are cheap, no duplicated file copies).
RUN set -eux; \
    find / -xdev -type f -perm /6000 -exec chmod a-s {} + 2>/dev/null || true; \
    rm -rf /usr/local/lib/python3.12/site-packages/pip* \
           /usr/local/lib/python3.12/site-packages/setuptools* \
           /usr/local/lib/python3.12/site-packages/msgpack* \
           /usr/local/lib/python3.12/site-packages/urllib3* 2>/dev/null || true

# Bring in the prepared virtualenv (already cleaned in the builder stage).
COPY --from=builder /opt/venv /opt/venv

WORKDIR /app

# Copy only the files needed at runtime; chmod is applied atomically (no extra
# chmod RUN layer). A single COPY with many sources would FLATTEN directories
# (e.g. hc/* would land in /app directly), so each directory keeps its own line
# — this is also better for Docker layer caching.
COPY --chown=app:app --chmod=u=rwX,go=rX manage.py CHANGELOG.md ./
COPY --chown=app:app --chmod=u=rwX,go=rX hc/ ./hc/
COPY --chown=app:app --chmod=u=rwX,go=rX templates/ ./templates/
COPY --chown=app:app --chmod=u=rwX,go=rX static/ ./static/
COPY --chown=app:app --chmod=u=rwX,go=rX docker/ ./docker/

# Build the offline static assets at image build time. SECRET_KEY is a
# throw-away placeholder only so that Django can load settings; the real
# secret is injected at run time from AWS Secrets Manager.
USER 1000:1000
RUN SECRET_KEY=build-time-placeholder python manage.py collectstatic --noinput \
    && SECRET_KEY=build-time-placeholder python manage.py compress --force

EXPOSE 8000

# Terminate cleanly on `docker stop` / ECS task stop.
STOPSIGNAL SIGTERM

ENTRYPOINT ["/app/docker/entrypoint.sh"]
CMD ["gunicorn", "hc.wsgi:application", \
     "--bind", "0.0.0.0:8000", \
     "--workers", "3", \
     "--threads", "2", \
     "--timeout", "60", \
     "--access-logfile", "-", \
     "--error-logfile", "-"]