#!/usr/bin/env bash
# =============================================================================
# Container entrypoint for the Healthchecks Django application.
#
# Responsibilities:
#   1. Wait for the database to accept connections (RDS can take a moment to
#      become reachable right after it is provisioned or failed over).
#   2. Apply Django database migrations exactly once per container start.
#   3. Hand over control (exec) to the process supplied in CMD (gunicorn).
#
# All behaviour is controlled through environment variables so the very same
# image can run locally (docker run) and on ECS Fargate.
# =============================================================================
set -euo pipefail

log() {
  printf '%s [entrypoint] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

if [[ "${WAIT_FOR_DB:-true}" == "true" && -n "${DB_HOST:-}" ]]; then
  log "Waiting for database at ${DB_HOST}:${DB_PORT:-5432} ..."
  for attempt in $(seq 1 "${DB_WAIT_ATTEMPTS:-30}"); do
    if python - "${DB_HOST}" "${DB_PORT:-5432}" <<'PY'
import socket
import sys

host, port = sys.argv[1], int(sys.argv[2])
try:
    with socket.create_connection((host, port), timeout=3):
        pass
except OSError:
    sys.exit(1)
PY
    then
      log "Database is reachable."
      break
    fi
    if [[ "${attempt}" -eq "${DB_WAIT_ATTEMPTS:-30}" ]]; then
      log "ERROR: database not reachable after ${attempt} attempts."
      exit 1
    fi
    sleep 2
  done
fi

if [[ "${RUN_MIGRATIONS:-true}" == "true" ]]; then
  log "Applying Django migrations ..."
  python manage.py migrate --noinput
fi

log "Starting: $*"
exec "$@"
