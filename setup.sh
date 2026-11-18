#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

if [[ "$EUID" -eq 0 ]]; then
  echo "Ejecuta ./setup.sh como usuario normal; solo systemd usará sudo." >&2
  exit 1
fi

for command in git docker curl jq python3 go openssl sudo systemctl nproc df; do
  command -v "$command" >/dev/null || {
    echo "Falta $command. Instala los requisitos y vuelve a ejecutar ./setup.sh." >&2
    exit 1
  }
done
if [[ -s "$HOME/.nvm/nvm.sh" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/.nvm/nvm.sh"
elif [[ -s "${NVM_DIR:-}/nvm.sh" ]]; then
  # shellcheck disable=SC1091
  source "${NVM_DIR}/nvm.sh"
else
  echo "Falta nvm. Instálalo desde https://github.com/nvm-sh/nvm." >&2
  exit 1
fi
docker info >/dev/null

if [[ ! -f .env ]]; then
  cp .env.example .env
fi
if [[ ! -f .env.node ]]; then
  cp .env.node.example .env.node
fi

set_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  if grep -q "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

if ! grep -q '^POSTGRES_PASSWORD=' .env \
  || grep -Eq '^POSTGRES_PASSWORD=(change-this-password|change-me)$' .env; then
  set_env_value .env POSTGRES_PASSWORD "$(openssl rand -hex 32)"
fi
if ! grep -q '^INDEXER_DB_PASSWORD=' .env \
  || grep -q '^INDEXER_DB_PASSWORD=replace-with-64-hex-characters$' .env; then
  set_env_value .env INDEXER_DB_PASSWORD "$(openssl rand -hex 32)"
fi

# shellcheck disable=SC1091
set -a
source .env.node
set +a
PROTOCOL_VERSION="${PROTOCOL_VERSION:-v9.9.0}"
NODE_HOME="${NODE_HOME:-$HOME/.dydxprotocol}"
MIN_ARCHIVE_FREE_GB="${MIN_ARCHIVE_FREE_GB:-12000}"
ALLOW_UNDER_SPECCED="${ALLOW_UNDER_SPECCED:-false}"
if [[ ! "$PROTOCOL_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "PROTOCOL_VERSION debe tener formato vX.Y.Z en .env.node." >&2
  exit 1
fi
CPU_COUNT="$(nproc)"
RAM_GB="$(awk '/MemTotal/ { printf "%d", $2 / 1024 / 1024 }' /proc/meminfo)"
DISK_CHECK_PATH="$NODE_HOME"
while [[ ! -d "$DISK_CHECK_PATH" ]]; do
  DISK_CHECK_PATH="$(dirname "$DISK_CHECK_PATH")"
done
FREE_GB="$(df -BG --output=avail "$DISK_CHECK_PATH" | tail -n 1 | tr -dc '0-9')"
if (( CPU_COUNT < 16 || RAM_GB < 64 || FREE_GB < MIN_ARCHIVE_FREE_GB )) \
  && [[ "$ALLOW_UNDER_SPECCED" != "true" ]]; then
  cat >&2 <<EOF
Este servidor no cumple el perfil archivístico:
  CPU: $CPU_COUNT (mínimo recomendado 16)
  RAM: $RAM_GB GiB (mínimo recomendado 64)
  Disco libre: $FREE_GB GiB (configurado: $MIN_ARCHIVE_FREE_GB GiB)
EOF
  echo "No continúo. Revisa .env.node y el almacenamiento antes de desplegar." >&2
  exit 1
fi
if [[ "${DAEMON_ALLOW_DOWNLOAD_BINARIES:-false}" == "true" ]]; then
  echo "Aviso: Cosmovisor descargará binarios indicados por upgrades on-chain."
fi
read -r -p "¿Confirmas PROTOCOL_VERSION=$PROTOCOL_VERSION compatible con mainnet? [s/N] " confirm
if [[ ! "$confirm" =~ ^[sS]$ ]]; then
  read -r -p "Escribe la versión compatible (vX.Y.Z): " PROTOCOL_VERSION
  if [[ ! "$PROTOCOL_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Versión inválida." >&2
    exit 1
  fi
  set_env_value .env.node PROTOCOL_VERSION "$PROTOCOL_VERSION"
fi

read -r -p "¿Continuar? El nodo se sincroniza desde genesis y puede requerir >12 TiB. Escribe SI: " confirm
if [[ "$confirm" != "SI" ]]; then
  echo "Cancelado. No se ha iniciado ningún servicio."
  exit 1
fi
sudo -v

read -r -p "Release Indexer [indexer/v9.5.11]: " INDEXER_REF
INDEXER_REF="${INDEXER_REF:-indexer/v9.5.11}"

INDEXER_REF="$INDEXER_REF" "$ROOT_DIR/scripts/setup-indexer.sh"
"$ROOT_DIR/scripts/start-indexer.sh"
"$ROOT_DIR/scripts/create-indexer-reader.sh"

if ! systemctl list-unit-files --no-legend | grep -q '^dydxprotocold.service'; then
  "$ROOT_DIR/scripts/install-dydx-node.sh"
fi
if ! systemctl is-active --quiet dydxprotocold; then
  sudo systemctl start dydxprotocold
fi

"$ROOT_DIR/scripts/start-tracker.sh"

cat <<EOF
Stack iniciado.
  Nodo:      sudo journalctl -u dydxprotocold -f
  Indexer:   http://localhost:3002
  WebSocket: ws://localhost:3003/v4/ws
  Tracker:   http://localhost:8080/healthz

El backfill comienza cuando el nodo publica bloques y Ender los guarda.
EOF
