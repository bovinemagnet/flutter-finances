#!/usr/bin/env bash
# Runs the Dart sync client end-to-end tests against the real server.
#
# Starts PostgreSQL and MinIO containers with podman on free ports, builds
# and starts the server with the `e2e` profile, waits for its health check,
# runs packages/finance_store/test/e2e with FINANCE_E2E_BASE_URL set, and
# always removes the containers and stops the server. Extra arguments are
# passed to `dart test` (for example `--name 'A10'`).
#
# Environment:
#   FINANCE_E2E_SKIP_BUILD=1  reuse the existing boot jar
#   FINANCE_E2E_KEEP_LOGS=1   keep the server log directory afterwards
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KEYS="$ROOT/tool/e2e/keys"
POSTGRES_IMAGE="${FINANCE_E2E_POSTGRES_IMAGE:-docker.io/library/postgres:18}"
MINIO_IMAGE="${FINANCE_E2E_MINIO_IMAGE:-docker.io/pgsty/minio:RELEASE.2026-08-04T00-00-00Z}"
RUN_ID="finance-e2e-$$-$RANDOM"
WORK="$(mktemp -d -t finance-e2e.XXXXXX)"
SERVER_PID=""

log() { printf '[e2e] %s\n' "$*" >&2; }

free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

cleanup() {
  local status=$?
  set +e
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    log "stopping server"
    kill "$SERVER_PID" 2>/dev/null
    for _ in $(seq 1 30); do
      kill -0 "$SERVER_PID" 2>/dev/null || break
      sleep 1
    done
    kill -9 "$SERVER_PID" 2>/dev/null
  fi
  log "removing containers"
  podman rm -f "$RUN_ID-postgres" "$RUN_ID-minio" >/dev/null 2>&1
  if [[ $status -ne 0 && -f "$WORK/server.log" ]]; then
    log "server log tail:"
    tail -n 80 "$WORK/server.log" >&2
  fi
  if [[ "${FINANCE_E2E_KEEP_LOGS:-}" == 1 ]]; then
    log "logs kept in $WORK"
  else
    rm -rf "$WORK"
  fi
  exit $status
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

wait_for() {
  local what=$1 attempts=$2
  shift 2
  for _ in $(seq 1 "$attempts"); do
    if "$@" >/dev/null 2>&1; then
      return 0
    fi
    if [[ -n "$SERVER_PID" ]] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
      log "server exited while waiting for $what"
      return 1
    fi
    sleep 1
  done
  log "timed out waiting for $what"
  return 1
}

PG_PORT=$(free_port)
MINIO_PORT=$(free_port)
APP_PORT=$(free_port)

log "starting PostgreSQL on $PG_PORT and MinIO on $MINIO_PORT"
podman run -d --rm --name "$RUN_ID-postgres" \
  -e POSTGRES_USER=finance -e POSTGRES_PASSWORD=finance -e POSTGRES_DB=finance \
  -p "127.0.0.1:$PG_PORT:5432" "$POSTGRES_IMAGE" >/dev/null
podman run -d --rm --name "$RUN_ID-minio" \
  -e MINIO_ROOT_USER=minioadmin -e MINIO_ROOT_PASSWORD=minioadmin \
  -p "127.0.0.1:$MINIO_PORT:9000" "$MINIO_IMAGE" server /data >/dev/null

if [[ "${FINANCE_E2E_SKIP_BUILD:-}" != 1 ]]; then
  log "building the server"
  (cd "$ROOT" && gradle25w --quiet :server:app:bootJar)
fi
JAR="$ROOT/server/app/build/libs/app-0.0.0.jar"

wait_for "PostgreSQL" 60 podman exec "$RUN_ID-postgres" pg_isready -U finance -d finance
wait_for "MinIO" 60 curl -fsS "http://127.0.0.1:$MINIO_PORT/minio/health/live"

log "starting the server on $APP_PORT"
FINANCE_DB_URL="jdbc:postgresql://127.0.0.1:$PG_PORT/finance" \
FINANCE_S3_ENDPOINT="http://127.0.0.1:$MINIO_PORT" \
FINANCE_E2E_PUBLIC_KEY="file:$KEYS/test-only-public.pem" \
  java -jar "$JAR" --spring.profiles.active=e2e --server.port="$APP_PORT" \
  >"$WORK/server.log" 2>&1 &
SERVER_PID=$!
wait_for "the server health check" 120 curl -fsS "http://127.0.0.1:$APP_PORT/actuator/health"

log "running the end-to-end tests"
cd "$ROOT/packages/finance_store"
FINANCE_E2E_BASE_URL="http://127.0.0.1:$APP_PORT" \
FINANCE_E2E_PRIVATE_KEY="$KEYS/test-only-private.pem" \
  dart test -P e2e test/e2e "$@"
