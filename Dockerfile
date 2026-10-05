# syntax=docker/dockerfile:1.7
# =============================================================================
# Multi-stage Dockerfile for the Healthchecks Django application.
#
# Stage 1 (builder): compiles Python dependencies that need a C toolchain
#                    (psycopg, pycurl, cryptography, ...) into an isolated
#                    virtualenv under /opt/venv.
# Stage 2 (runtime): minimal image containing only the virtualenv, the
#                    application code and the shared libraries required at
#                    run time (libpq for PostgreSQL, libcurl for pycurl).
#
# The image runs as a non-root user and serves the app with gunicorn.
# =============================================================================

########################
# Stage 1: builder
########################
FROM python:3.12-slim-bookworm AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Build-time system dependencies:
#   build-essential, pkg-config -> compiling C extensions
#   libpq-dev                   -> psycopg (PostgreSQL)
#   libcurl4-openssl-dev, libssl-dev -> pycurl, cryptography
#   libffi-dev, zlib1g-dev      -> cffi / compression
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        pkg-config \
        libpq-dev \
        libcurl4-openssl-dev \
        libssl-dev \
        libffi-dev \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

WORKDIR /build
COPY requirements.txt requirements-prod.txt ./
# hadolint ignore=DL3013
RUN pip install --upgrade pip setuptools wheel \
    && pip install -r requirements.txt -r requirements-prod.txt

########################
# Stage 2: runtime
########################
FROM python:3.12-slim-bookworm AS runtime

LABEL org.opencontainers.image.title="django-sample-app" \
      org.opencontainers.image.description="Healthchecks Django application (containerized)" \
      org.opencontainers.image.source="https://github.com/musaxasmammedov7/django-sample-app"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:${PATH}" \
    DJANGO_SETTINGS_MODULE=hc.settings

# Runtime system dependencies only:
#   libpq5  -> psycopg PostgreSQL client library
#   libcurl4-> pycurl
#   tzdata  -> correct timezone handling (USE_TZ=True)
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libpq5 \
        libcurl4 \
        ca-certificates \
        tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 1000 app \
    && useradd --system --uid 1000 --gid app --create-home --home-dir /app --shell /usr/sbin/nologin app

# Bring in the prepared virtualenv
COPY --from=builder /opt/venv /opt/venv

WORKDIR /app
COPY --chown=app:app . .
RUN chmod +x /app/docker/entrypoint.sh

# Build the offline static assets at image build time. SECRET_KEY is a
# throw-away placeholder here only so that Django can load settings; the real
# secret is injected at run time from AWS Secrets Manager.
USER 1000:1000
RUN SECRET_KEY=build-time-placeholder python manage.py collectstatic --noinput \
    && SECRET_KEY=build-time-placeholder python manage.py compress --force

EXPOSE 8000

ENTRYPOINT ["/app/docker/entrypoint.sh"]
CMD ["gunicorn", "hc.wsgi:application", \
     "--bind", "0.0.0.0:8000", \
     "--workers", "3", \
     "--threads", "2", \
     "--timeout", "60", \
     "--access-logfile", "-", \
     "--error-logfile", "-"]
