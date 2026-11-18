#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHAIN_REPO_DIR="${CHAIN_REPO_DIR:-$ROOT_DIR/.vendor/v4-chain}"
INDEXER_DIR="$CHAIN_REPO_DIR/indexer"
PROJECT_NAME="${INDEXER_PROJECT_NAME:-dydx-indexer}"
COMPOSE_FILE="$INDEXER_DIR/docker-compose-local-deployment.yml"
OVERRIDE_FILE="$ROOT_DIR/deploy/indexer/docker-compose.override.yml"

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "No existe $COMPOSE_FILE." >&2
  exit 1
fi

docker compose \
  --project-name "$PROJECT_NAME" \
  --project-directory "$INDEXER_DIR" \
  --env-file "$ROOT_DIR/.env" \
  -f "$COMPOSE_FILE" \
  -f "$OVERRIDE_FILE" \
  down
