#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHAIN_REPO_DIR="${CHAIN_REPO_DIR:-$ROOT_DIR/.vendor/v4-chain}"
INDEXER_DIR="$CHAIN_REPO_DIR/indexer"
PROJECT_NAME="${INDEXER_PROJECT_NAME:-dydx-indexer}"
COMPOSE_FILE="$INDEXER_DIR/docker-compose-local-deployment.yml"
OVERRIDE_FILE="$ROOT_DIR/deploy/indexer/docker-compose.override.yml"

if [[ ! -f "$ROOT_DIR/.env" ]]; then
  echo "Falta .env." >&2
  exit 1
fi
# .env contiene contraseñas URL-safe generadas/configuradas por el operador.
# shellcheck disable=SC1091
set -a
source "$ROOT_DIR/.env"
set +a

: "${INDEXER_DB_PASSWORD:?Configura INDEXER_DB_PASSWORD en .env}"

compose() {
  docker compose \
    --project-name "$PROJECT_NAME" \
    --project-directory "$INDEXER_DIR" \
    --env-file "$ROOT_DIR/.env" \
    -f "$COMPOSE_FILE" \
    -f "$OVERRIDE_FILE" \
    "$@"
}

READY=false
for _ in $(seq 1 120); do
  if [[ "$(compose exec -T postgres psql -U dydx_dev -d dydx_dev -Atqc \
    "SELECT to_regclass('public.blocks') IS NOT NULL AND to_regclass('public.fills') IS NOT NULL AND to_regclass('public.subaccounts') IS NOT NULL AND to_regclass('public.perpetual_markets') IS NOT NULL" \
    2>/dev/null || true)" == "t" ]]; then
    READY=true
    break
  fi
  sleep 5
done
if [[ "$READY" != "true" ]]; then
  echo "PostgreSQL del Indexer no terminó las migraciones en 10 minutos." >&2
  echo "Comprueba: scripts/start-indexer.sh y sus logs." >&2
  exit 1
fi

compose exec -T postgres \
  psql -v ON_ERROR_STOP=1 -v tracker_password="$INDEXER_DB_PASSWORD" \
    -U dydx_dev -d dydx_dev <<'SQL'
SELECT format(
  'CREATE ROLE tracker_reader LOGIN PASSWORD %L',
  :'tracker_password'
)
WHERE NOT EXISTS (
  SELECT 1 FROM pg_roles WHERE rolname = 'tracker_reader'
)
\gexec

SELECT format(
  'ALTER ROLE tracker_reader PASSWORD %L',
  :'tracker_password'
)
\gexec

GRANT CONNECT ON DATABASE dydx_dev TO tracker_reader;
GRANT USAGE ON SCHEMA public TO tracker_reader;
GRANT SELECT ON TABLE blocks, fills, subaccounts, perpetual_markets
  TO tracker_reader;
SQL

echo "Usuario tracker_reader creado con permisos de solo lectura."
