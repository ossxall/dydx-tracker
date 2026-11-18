#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHAIN_REPO_DIR="${CHAIN_REPO_DIR:-$ROOT_DIR/.vendor/v4-chain}"
INDEXER_DIR="$CHAIN_REPO_DIR/indexer"
PROJECT_NAME="${INDEXER_PROJECT_NAME:-dydx-indexer}"
COMPOSE_FILE="$INDEXER_DIR/docker-compose-local-deployment.yml"
OVERRIDE_FILE="$ROOT_DIR/deploy/indexer/docker-compose.override.yml"

if [[ ! -f "$ROOT_DIR/.env" ]]; then
  echo "Falta .env. Ejecuta: cp .env.example .env y configura sus claves." >&2
  exit 1
fi
if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "No existe $COMPOSE_FILE. Ejecuta scripts/setup-indexer.sh primero." >&2
  exit 1
fi

docker compose \
  --project-name "$PROJECT_NAME" \
  --project-directory "$INDEXER_DIR" \
  --env-file "$ROOT_DIR/.env" \
  -f "$COMPOSE_FILE" \
  -f "$OVERRIDE_FILE" \
  up -d --build

cat <<EOF
Indexer iniciado. Red Docker: ${PROJECT_NAME}_default
Espera a que postgres-package termine sus migraciones.
Después crea el usuario de solo lectura:
  $ROOT_DIR/scripts/create-indexer-reader.sh
EOF
