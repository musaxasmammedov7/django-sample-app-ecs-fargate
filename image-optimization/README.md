# Docker Image Optimization — django-sample-app

## Goal
Reduce the Docker image size and improve build time of the client's Django
(Healthchecks) image without losing functionality or the security hardening
from the previous tasks.

## Results (measured on Apple M1, Docker Desktop, LinuxKit backend)

| Metric | Before | After | Delta |
|---|---|---|---|
| Image size | 395 MB | 340 MB | **−55 MB (−14%)** |
| Cold build (`--no-cache`) | ~3 min | network-dependent (~3–9 min) | — |
| Incremental rebuild (warm cache) | full pip/apt re-run | **~17 s** | much faster |

> Note: cold-build time is dominated by compiling `pycurl` and by package
> download speed, so it varies run to run. The reliable, reproducible win is on
> **repeated builds**: layer caching + BuildKit cache mounts mean a code change
> rebuilds in seconds instead of minutes.

## What was changed and why

1. **venv cleaning moved to the builder stage.**
   After `pip install`, the builder removes `pip`, `setuptools`, `wheel`,
   purges `__pycache__` and sets permissions — all inside the builder, so none
   of it is copied into the final image. No separate `chmod` layer in runtime
   touches the venv afterwards.
2. **`COPY --chown --chmod` instead of a `RUN chmod` layer.**
   `COPY --chown=app:app --chmod=u=rwX,go=rX` applies ownership and permissions
   atomically; the `RUN chmod +x`+`chmod -R go-w /app` layer is gone.
   `docker/entrypoint.sh` keeps its `0755` exec bit from git.
3. **Only runtime files are copied.**
   Instead of `COPY . .`, the Dockerfile copies `manage.py`, `hc/`,
   `templates/`, `static/`, `docker/entrypoint.sh` and `CHANGELOG.md`
   (read by `hc/settings.py` at import). Smaller context, smaller app layer,
   better cache granularity.
4. **BuildKit cache mounts for apt and pip.**
   `RUN --mount=type=cache,target=/var/cache/apt` and
   `--mount=type=cache,target=/root/.cache/pip` reuse downloaded packages and
   wheels across builds — the biggest build-time win. The cache never lands in
   the image.
5. **Smaller build context via `.dockerignore`.**
   Added `docs/` and `image-optimization/`. `.dockerignore` already excluded
   `.git`, `.github`, `.venv`, `__pycache__`, `*.pyc`, `.env*`, terraform
   folders, `*.sqlite3` and secret material.
6. **Layer count reduced.**
   Combined consecutive build/hardening steps into single `RUN`s.

## What we deliberately did NOT do
- **No Alpine base image** — musl would complicate building `pycurl`,
  `cryptography` and `psycopg` for a small gain.
- **No stripping of `.so` files** — needs careful per-library verification.
- **No removal of app/test packages** — `django.test` is used by Django itself;
  removing static or templates breaks `collectstatic`/`compress`.

## How to reproduce
```bash
# size
docker images django-sample-app:optimized --format "{{.Size}}"

# cold build timing
time docker build --no-cache -t app:before .

# incremental (warm) build timing — change one file, then:
time docker build -t django-sample-app:optimized .

# layer analysis
docker history django-sample-app:optimized
dive django-sample-app:optimized
```

## Verification
- Container starts, PostgreSQL migrations run automatically.
- `GET /api/v3/status/` → `200`
- `/` → `302` (redirect to dashboard/login)
- Static assets served via Whitenoise: `/static/img/badges.png` → `200`
- Runs hardened: non-root (`UID 1000`), read-only rootfs, `--cap-drop ALL`,
  `no-new-privileges`.