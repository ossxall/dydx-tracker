#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -f .env ]]; then
  echo "Falta .env. Ejecuta: cp .env.example .env y configura sus claves." >&2
  exit 1
fi

docker compose \
  --env-file .env \
  -f docker-compose.yml \
  -f docker-compose.indexer.yml \
  up -d --build

echo "Tracker iniciado: http://localhost:8080/healthz"
