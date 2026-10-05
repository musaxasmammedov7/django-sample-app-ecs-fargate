# syntax=docker/dockerfile:1.7
# =============================================================================
# Hardened multi-stage Dockerfile for the Healthchecks Django application.
#
# Security controls applied (mapped to CIS Docker Benchmark / OWASP Docker
# Top 10, see docs/DOCKER-SECURITY.md for the full rationale):
#
#   4.1  Base image pinned by immutable digest (supply-chain integrity)
#   4.2  Minimal, multi-stage image: build tools never reach the runtime image
#   4.3  Only required runtime packages installed, apt lists removed
#   4.4  No package manager / build toolchain in the runtime image
#   4.6  Application runs as an unprivileged, numeric non-root user (UID 1000)
#   4.7  setuid/setgid bits stripped; /app not writable by group/other
#   4.8  HEALTHCHECK defined so orchestrators can detect a broken container
#   4.9  Secrets are NEVER baked into layers (injected at runtime)
#   5.x  Writable files are limited to explicitly mounted tmpfs at runtime
#
# The image is scanned in CI with Trivy and Anchore (Syft + Grype).
# =============================================================================

########################
# Stage 1: builder
########################
# Pinned by digest so a compromised or retagged upstream tag cannot silently
# change what we build. To update: replace the digest with the new one printed
# by `docker buildx imagetools inspect python:3.12-slim-bookworm`.
FROM python:3.12-slim-bookworm@sha256:9901e0a8d75037d8242ed43155cbcb2d1f61be1356383d8054afb59fd50e39c4 AS builder

# Reproducible, quiet, cache-free builds.
    #Обычно Python при импорте модулей создаёт папки __pycache__ с файлами .pyc (скомпилированный байт-код), чтобы в следующий раз запускаться чуть быстрее.При запуске имейджа это не имеет смысла
ENV PYTHONDONTWRITEBYTECODE=1 \
    # #По умолчанию Python копит вывод print() и логов в буфере и выдаёт его порциями.А это наполняте докер логс
    PYTHONUNBUFFERED=1 \
    #pip обычно сохраняет скачанные пакеты в кеш (~/.cache/pip),а в имейдже кеш не нужен
    PIP_NO_CACHE_DIR=1 \
    #отключает проверку обновлений самого pip.Если после каждого pip install это будет выходить то будет засоряться логи
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Build-time system dependencies:
#   build-essential, pkg-config      -> compiling C extensions
#   libpq-dev                        -> psycopg (PostgreSQL)
#   libcurl4-openssl-dev, libssl-dev -> pycurl, cryptography
#   libffi-dev, zlib1g-dev           -> cffi / compression
# hadolint ignore=DL3008
RUN set -eux; \
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
# hadolint ignore=DL3013
RUN pip install --upgrade pip setuptools wheel \
    && pip install -r requirements.txt -r requirements-prod.txt

########################
# Stage 2: runtime
########################
FROM python:3.12-slim-bookworm@sha256:9901e0a8d75037d8242ed43155cbcb2d1f61be1356383d8054afb59fd50e39c4 AS runtime

LABEL org.opencontainers.image.title="django-sample-app" \
      org.opencontainers.image.description="Healthchecks Django application (hardened, containerized)" \
      org.opencontainers.image.source="https://github.com/musaxasmammedov7/django-sample-app-ecs-fargate" \
      org.opencontainers.image.licenses="BSD-3-Clause"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:${PATH}" \
    HOME=/app \
    DJANGO_SETTINGS_MODULE=hc.settings

# Runtime system dependencies only:
#   libpq5   -> psycopg PostgreSQL client library
#   libcurl4 -> pycurl
#   tzdata   -> correct timezone handling (USE_TZ=True)
#   ca-certificates -> TLS trust store
# hadolint ignore=DL3008
RUN set -eux; \
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

# Harden the filesystem: strip setuid/setgid bits (privilege-escalation vectors).
RUN set -eux; \
    find / -xdev -type f -perm /6000 -exec chmod a-s {} + 2>/dev/null || true

# Bring in the prepared virtualenv (owned by root, read-only for the app user).
COPY --from=builder /opt/venv /opt/venv

# Minimise attack surface: the runtime never installs packages, so the package
# manager and its vendored tooling (pip -> urllib3/msgpack) are removed, along
# with the unused copies in the base interpreter.
RUN set -eux; \
    rm -rf /opt/venv/lib/python3.12/site-packages/pip \
           /opt/venv/lib/python3.12/site-packages/pip-*.dist-info; \
    rm -rf /usr/local/lib/python3.12/site-packages/pip* \
           /usr/local/lib/python3.12/site-packages/setuptools* \
           /usr/local/lib/python3.12/site-packages/msgpack* \
           /usr/local/lib/python3.12/site-packages/urllib3* 2>/dev/null || true; \
    chmod -R go-w /opt/venv

WORKDIR /app
# COPY (never ADD) + explicit ownership.
COPY --chown=app:app . .
RUN chmod +x /app/docker/entrypoint.sh \
    && chmod -R go-w /app

# Build the offline static assets at image build time. SECRET_KEY is a
# throw-away placeholder only so that Django can load settings; the real
# secret is injected at run time from AWS Secrets Manager.
USER 1000:1000
RUN SECRET_KEY=build-time-placeholder python manage.py collectstatic --noinput \
    && SECRET_KEY=build-time-placeholder python manage.py compress --force

# Fail fast if the WSGI app stops serving.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD ["python", "-c", "import sys,urllib.request; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/api/v3/status/', timeout=4).status == 200 else 1)"]

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
