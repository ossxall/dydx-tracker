#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INDEXER_REF="${INDEXER_REF:-indexer/v9.5.11}"
CHAIN_REPO_DIR="${CHAIN_REPO_DIR:-$ROOT_DIR/.vendor/v4-chain}"

if [[ ! "$INDEXER_REF" =~ ^indexer/v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "INDEXER_REF debe ser una release indexer/vX.Y.Z." >&2
  exit 1
fi

if [[ ! -f "$ROOT_DIR/.env" ]]; then
  echo "Falta .env. Ejecuta: cp .env.example .env y configura sus claves." >&2
  exit 1
fi

for command in git docker; do
  command -v "$command" >/dev/null || {
    echo "Falta dependencia: $command" >&2
    exit 1
  }
done

if [[ -e "$CHAIN_REPO_DIR" ]]; then
  if [[ ! -d "$CHAIN_REPO_DIR/.git" ]] \
    || [[ "$(git -C "$CHAIN_REPO_DIR" remote get-url origin 2>/dev/null || true)" \
      != "https://github.com/dydxprotocol/v4-chain.git" ]] \
    || [[ "$(git -C "$CHAIN_REPO_DIR" describe --tags --exact-match HEAD 2>/dev/null || true)" \
      != "$INDEXER_REF" ]]; then
    echo "$CHAIN_REPO_DIR existe, pero no es el checkout esperado ($INDEXER_REF); no lo modifico." >&2
    exit 1
  fi
else
  git clone --depth 1 --branch "$INDEXER_REF" \
    https://github.com/dydxprotocol/v4-chain.git "$CHAIN_REPO_DIR"
fi

INDEXER_DIR="$CHAIN_REPO_DIR/indexer"
if [[ -s "$INDEXER_DIR/.nvmrc" ]]; then
  NODE_VERSION="$(tr -d '[:space:]' < "$INDEXER_DIR/.nvmrc")"
else
  echo "No se encontró indexer/.nvmrc en el tag $INDEXER_REF." >&2
  exit 1
fi

if [[ -s "$HOME/.nvm/nvm.sh" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/.nvm/nvm.sh"
elif [[ -s "${NVM_DIR:-}/nvm.sh" ]]; then
  # shellcheck disable=SC1091
  source "${NVM_DIR}/nvm.sh"
else
  echo "Instala nvm desde https://github.com/nvm-sh/nvm y vuelve a ejecutar." >&2
  exit 1
fi

cd "$INDEXER_DIR"
nvm install "$NODE_VERSION"
nvm use "$NODE_VERSION"
npm install --global pnpm@6.34.0
pnpm install
pnpm run build:all

cat <<EOF
Indexer preparado en:
  $INDEXER_DIR

Siguiente paso:
  $ROOT_DIR/scripts/start-indexer.sh
EOF
