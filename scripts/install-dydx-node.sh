#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_ENV_FILE="$ROOT_DIR/.env.node"

if [[ ! -f "$NODE_ENV_FILE" ]]; then
  echo "Falta .env.node. Ejecuta: cp .env.node.example .env.node y revisa la release." >&2
  exit 1
fi
# shellcheck disable=SC1090
set -a
source "$NODE_ENV_FILE"
set +a

: "${PROTOCOL_VERSION:?Configura la release compatible con mainnet en .env.node}"
if [[ ! "$PROTOCOL_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "PROTOCOL_VERSION debe tener formato vX.Y.Z (por ejemplo v9.9.0)." >&2
  exit 1
fi
NODE_NAME="${NODE_NAME:-dydx-tracker-fullnode}"
NODE_HOME="${NODE_HOME:-$HOME/.dydxprotocol}"
NODE_KAFKA_ADDR="${NODE_KAFKA_ADDR:-127.0.0.1:29092}"
NODE_RPC_LISTEN="${NODE_RPC_LISTEN:-tcp://0.0.0.0:26657}"
DAEMON_ALLOW_DOWNLOAD_BINARIES="${DAEMON_ALLOW_DOWNLOAD_BINARIES:-false}"
MIN_ARCHIVE_FREE_GB="${MIN_ARCHIVE_FREE_GB:-12000}"
ALLOW_UNDER_SPECCED="${ALLOW_UNDER_SPECCED:-false}"

if [[ "$EUID" -eq 0 ]]; then
  echo "No ejecutes este script como root; usa el usuario que operará el nodo." >&2
  exit 1
fi
if [[ "${NODE_SYNC_FROM_GENESIS:-true}" != "true" ]]; then
  echo "Este instalador prepara una sincronización desde genesis, sin snapshot." >&2
  exit 1
fi

for command in curl jq sha256sum tar python3 go sudo; do
  command -v "$command" >/dev/null || {
    echo "Falta dependencia: $command. Instálala siguiendo la guía oficial." >&2
    exit 1
  }
done

CPU_COUNT="$(nproc)"
RAM_GB="$(awk '/MemTotal/ { printf "%d", $2 / 1024 / 1024 }' /proc/meminfo)"
DISK_CHECK_PATH="$NODE_HOME"
while [[ ! -d "$DISK_CHECK_PATH" ]]; do
  DISK_CHECK_PATH="$(dirname "$DISK_CHECK_PATH")"
done
FREE_GB="$(df -BG --output=avail "$DISK_CHECK_PATH" | tail -n 1 | tr -dc '0-9')"
if (( CPU_COUNT < 16 || RAM_GB < 64 || FREE_GB < MIN_ARCHIVE_FREE_GB )); then
  cat >&2 <<EOF
Recursos insuficientes para el perfil archivístico:
  CPU: ${CPU_COUNT} (recomendado >= 16)
  RAM: ${RAM_GB} GiB (recomendado >= 64)
  Disco libre: ${FREE_GB} GiB (configurado mínimo ${MIN_ARCHIVE_FREE_GB} GiB)
EOF
  if [[ "$ALLOW_UNDER_SPECCED" != "true" ]]; then
    echo "No continúo. Revisa almacenamiento/recursos o marca ALLOW_UNDER_SPECCED=true." >&2
    exit 1
  fi
  echo "AVISO: continúo con recursos por debajo de lo recomendado." >&2
fi

if [[ -e "$NODE_HOME/config/config.toml" || -e "$NODE_HOME/config/genesis.json" || -e "$NODE_HOME/data" ]]; then
  echo "Ya hay datos de nodo en $NODE_HOME; no los modifico." >&2
  exit 1
fi

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *)
    echo "Arquitectura no soportada: $ARCH" >&2
    exit 1
    ;;
esac

RELEASE_TAG="protocol/${PROTOCOL_VERSION}"
ARCHIVE="dydxprotocold-${PROTOCOL_VERSION}-linux-${ARCH}.tar.gz"
RELEASE_JSON="$(mktemp)"
TMP_DIR="$(mktemp -d)"
trap 'rm -f "$RELEASE_JSON"; rm -rf "$TMP_DIR"' EXIT

curl -fsSL \
  "https://api.github.com/repos/dydxprotocol/v4-chain/releases/tags/${RELEASE_TAG//\//%2F}" \
  -o "$RELEASE_JSON"

EXPECTED_SHA="$(
  jq -r --arg archive "$ARCHIVE" \
    '.body | split("\n")[] | select(contains($archive)) |
      capture("(?<sha>[A-Fa-f0-9]{64})").sha' \
    "$RELEASE_JSON" | head -n 1
)"
if [[ ! "$EXPECTED_SHA" =~ ^[A-Fa-f0-9]{64}$ ]]; then
  echo "No pude validar el SHA-256 publicado para $ARCHIVE. Cancelo." >&2
  exit 1
fi

curl -fL \
  "https://github.com/dydxprotocol/v4-chain/releases/download/${RELEASE_TAG}/${ARCHIVE}" \
  -o "$TMP_DIR/$ARCHIVE"
printf '%s  %s\n' "$EXPECTED_SHA" "$TMP_DIR/$ARCHIVE" | sha256sum --check -
tar -xzf "$TMP_DIR/$ARCHIVE" -C "$TMP_DIR"

DAEMON_BIN="$(find "$TMP_DIR" -type f -name "dydxprotocold-${PROTOCOL_VERSION}-linux-${ARCH}" -print -quit)"
if [[ -z "$DAEMON_BIN" ]]; then
  echo "El release no contiene el binario esperado." >&2
  exit 1
fi

install -d "$HOME/go/bin"
COSMOVISOR_BIN="$HOME/go/bin/cosmovisor"
if [[ ! -x "$COSMOVISOR_BIN" ]]; then
  GOBIN="$HOME/go/bin" go install cosmossdk.io/tools/cosmovisor/cmd/cosmovisor@latest
fi
if [[ ! -x "$COSMOVISOR_BIN" ]]; then
  echo "No se encontró Cosmovisor en $COSMOVISOR_BIN." >&2
  exit 1
fi

mkdir -p "$NODE_HOME/cosmovisor/genesis/bin" "$NODE_HOME/cosmovisor/upgrades"
install -m 0755 "$DAEMON_BIN" \
  "$NODE_HOME/cosmovisor/genesis/bin/dydxprotocold"
"$NODE_HOME/cosmovisor/genesis/bin/dydxprotocold" \
  init --home "$NODE_HOME" --chain-id=dydx-mainnet-1 "$NODE_NAME"

curl -fsSL \
  https://raw.githubusercontent.com/dydxopsdao/networks/main/dydx-mainnet-1/genesis.json \
  -o "$NODE_HOME/config/genesis.json"
if [[ "$(jq -r '.chain_id' "$NODE_HOME/config/genesis.json")" != "dydx-mainnet-1" ]]; then
  echo "El genesis descargado no corresponde a dydx-mainnet-1." >&2
  exit 1
fi

NETWORK_JSON="$TMP_DIR/chain.json"
curl -fsSL \
  https://raw.githubusercontent.com/dydxopsdao/networks/main/dydx-mainnet-1/chain.json \
  -o "$NETWORK_JSON"
SEEDS="$(jq -er '[.peers.seeds[] | "\(.id)@\(.address)"] | join(",")' "$NETWORK_JSON")"

python3 - "$NODE_HOME/config/config.toml" "$NODE_HOME/config/app.toml" \
  "$SEEDS" "$NODE_RPC_LISTEN" <<'PY'
import pathlib
import re
import sys

config_path, app_path, seeds, rpc_listen = sys.argv[1:]
config = pathlib.Path(config_path)
lines = config.read_text().splitlines()
section = ""
seed_count = 0
rpc_count = 0
for index, line in enumerate(lines):
    header = re.match(r'^\s*\[([^\]]+)\]\s*$', line)
    if header:
        section = header.group(1)
        continue
    if section == "p2p" and re.match(r'^\s*seeds\s*=', line):
        lines[index] = f'seeds = "{seeds}"'
        seed_count += 1
    if section == "rpc" and re.match(r'^\s*laddr\s*=', line):
        lines[index] = f'laddr = "{rpc_listen}"'
        rpc_count += 1
if seed_count != 1 or rpc_count != 1:
    raise SystemExit("No encontré seeds en [p2p] y laddr en [rpc]; revisa el formato del release.")
config.write_text("\n".join(lines) + "\n")

app = pathlib.Path(app_path)
app_text, pruning_count = re.subn(
    r'(?m)^pruning\s*=.*$',
    'pruning = "nothing"',
    app.read_text(),
    count=1,
)
if pruning_count != 1:
    raise SystemExit("No encontré pruning en app.toml.")
app.write_text(app_text)
PY

SERVICE_FILE="$(mktemp)"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=dYdX mainnet non-validating full node
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=$(id -un)
WorkingDirectory=$NODE_HOME
Environment="DAEMON_HOME=$NODE_HOME"
Environment="DAEMON_NAME=dydxprotocold"
Environment="DAEMON_ALLOW_DOWNLOAD_BINARIES=$DAEMON_ALLOW_DOWNLOAD_BINARIES"
Environment="DAEMON_RESTART_AFTER_UPGRADE=true"
Environment="PATH=$HOME/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin"
ExecStart=$COSMOVISOR_BIN run start --non-validating-full-node=true --indexer-kafka-conn-str=$NODE_KAFKA_ADDR --indexer-send-offchain-data=true
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
sudo install -m 0644 "$SERVICE_FILE" /etc/systemd/system/dydxprotocold.service
rm -f "$SERVICE_FILE"
sudo systemctl daemon-reload
sudo systemctl enable dydxprotocold

cat <<EOF
Nodo preparado en $NODE_HOME con $RELEASE_TAG.
El servicio está habilitado, pero NO iniciado.

Antes de arrancarlo:
  1. Inicia el Indexer y Kafka: scripts/start-indexer.sh
  2. Asegura que el usuario de este nodo puede acceder a 127.0.0.1:29092.
  3. Protege el RPC $NODE_RPC_LISTEN con firewall; no lo publiques a Internet.

Luego:
  sudo systemctl start dydxprotocold
  sudo journalctl -u dydxprotocold -f
EOF
