# Docker Compose — Local Development

One-command local stack for the **Django (Healthchecks)** application and its
**PostgreSQL** database, using the same Docker image that is used in
production (ECS Fargate).

## Why Docker Compose

Without Compose, every developer would have to run several `docker run`
commands with the right flags, network links and volumes, in the right order —
and results would differ between machines. Compose declares the whole stack
once:

- **one command** starts everything: `docker compose up --build`;
- **reproducible** — the same YAML, same image, same env for every teammate;
- **isolated** — services run on a private Compose network (`app` reaches `db`
  simply by the service name);
- **persistent data** — the Postgres data lives in the named `pgdata` volume,
  so it survives `docker compose down`;
- **ordering** — the app starts only after the DB healthcheck passes;
- **prod-like** — the same container, same non-root / hardened settings as ECS.

## Prerequisites

- Docker with the Compose v2 plugin (`docker compose version`).
- `~2 GB` of free memory; the PostgreSQL image is pulled on first run.

## Files

| File | Purpose |
|---|---|
| `docker-compose.yaml` | defines `db` and `app` services |
| `.env.example` | template of configuration variables (git-ignored `.env` copies it) |

## Quick start

From this directory (`docker-compose-local/`):

```bash
# 1. Create your local env file from the template and adjust values
cp .env.example .env

# 2. Build and start
docker compose up --build

# 3. Open the app
#    http://localhost:8000
```

The app waits for PostgreSQL, runs Django migrations automatically
(`docker/entrypoint.sh`), then serves with gunicorn.

## Verify it works

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8000/api/v3/status/   # 200
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8000/static/img/badges.png  # 200
# http://localhost:8000  -> redirect to login (302) is normal
# http://localhost:8000/admin/  -> Django admin
```

## Environment variables (`.env`)

| Variable | Description | Example |
|---|---|---|
| `DB_NAME` | database name | `django_db` |
| `DB_USER` | database user | `django_user` |
| `DB_PASSWORD` | database password (local dev only) | `django_pass_dev` |
| `DB_SSLMODE` | disable locally (TLS is used in prod) | `disable` |
| `SECRET_KEY` | Django secret key (local dev) | `local_dev_secret_key_change_me` |
| `DEBUG` | Django debug flag | `False` |
| `SITE_ROOT` | base URL | `http://localhost:8000` |
| `ALLOWED_HOSTS` | allowed hosts | `localhost,127.0.0.1` |

## Handy commands

```bash
docker compose up --build -d    # start detached
docker compose ps               # status
docker compose logs -f app      # follow app logs
docker compose exec app sh      # shell inside the app container
docker compose exec db psql -U django_user -d django_db   # SQL console
docker compose config           # validate the compose file
docker compose down             # stop (keeps the DB volume)
docker compose down -v          # stop AND delete the DB volume (reset data)
```

## Troubleshooting

- **Port already in use (8000)** — stop another service/container using the
  port, or change the `ports:` mapping in `docker-compose.yaml`. (The database
  is not exposed on the host by default, so it will not collide with your ports.)
- **App cannot reach the database** — the `db` healthcheck + `WAIT_FOR_DB`
  logic retries; check `docker compose logs db` if Postgres failed to start.
- **Apple Silicon / platform warning** — the image is built for
  `linux/amd64`; Docker Desktop emulates it. Runs slower but works.
- **Empty variable warnings** — you did not copy `.env`; run
  `cp .env.example .env` first.

## Security note

This stack is **for local development only**:

- `.env` is git-ignored and never pushed to the repository;
- values in `.env.example` are generic dev placeholders — **do not reuse them
  in production**;
- production secrets live in **AWS Secrets Manager** and are injected by ECS at
  runtime, not in any Compose file.