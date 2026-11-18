# dydx-tracker

Replica a una base de datos propia todos los fills individuales de `BTC-USD`
que el Indexer oficial de dYdX v4 guarda en PostgreSQL. El histórico comienza
el **17/11/2024 (UTC)**; el replicador sigue el Indexer y captura nuevos bloques
automáticamente.

Cada fila representa un lado de una ejecución (maker o taker), con wallet,
subcuenta, mercado, lado, precio, cantidad, comisión, fecha, altura, `eventId`
y hash de transacción. Esto mantiene los dos registros de las dos cuentas que
participan en una operación, tal como hace el Indexer.

## Arquitectura

```text
nodo dYdX no validador → Indexer oficial (Ender → Kafka → PostgreSQL)
                                             ↓ solo lectura
                                   dydx-tracker → PostgreSQL propio
```

Este proyecto no sustituye a Ender ni decodifica bloques: usa el esquema del
Indexer oficial. El repositorio incluye scripts para descargar/preparar el
full node y clonar/desplegar el Indexer oficial. Los binarios, imágenes,
dependencias, blockchain y bases de datos se descargan al instalarse; no se
incluyen en Git.

## Requisitos previos

- Linux; como referencia inicial para nodo + Indexer: 16 CPU, 64 GB RAM y SSD
  NVMe. El espacio depende de la retención y la configuración de archivo.
- Nodo dYdX V4 mainnet no validador, sincronizado con `dydx-mainnet-1`.
- Indexer oficial conectado a ese nodo y con su PostgreSQL accesible.
- Docker Engine y Docker Compose v2.

## Instalación sencilla

Instala primero Docker Compose, Go y nvm. Luego, desde la raíz del repositorio,
ejecuta:

```sh
./setup.sh
```

El asistente crea `.env` y `.env.node` con contraseñas aleatorias, te pide
confirmar la versión de mainnet y el despliegue histórico, y después prepara
Indexer, nodo y tracker en orden. Si el servidor no tiene los recursos
archivísticos necesarios, se detiene antes de iniciar el nodo. La primera
instalación puede tardar bastante.

## Despliegue completo

### Requisitos reales para el histórico

Para procesar desde genesis hacen falta, como mínimo, 16 CPU, 64 GiB de RAM y
SSD local. **500 GiB no bastan para un nodo archivístico**: snapshots archivísticos
publicados recientemente superan los 10 TiB y siguen creciendo. El catch-up de
más de 100 millones de bloques puede tardar mucho y requiere los binarios de
upgrade históricos. Reserva espacio y comprueba los requisitos del operador
antes de empezar; los scripts no formatean discos ni borran datos existentes.

El nodo se inicializa desde genesis, sin snapshot, para emitir los bloques a
Kafka mientras sincroniza. Cosmovisor está configurado para descargar los
binarios referenciados por upgrades on-chain (`DAEMON_ALLOW_DOWNLOAD_BINARIES`).
Esto confía en la información de upgrade de la cadena. Si tu política no permite
descargas automáticas, instala y verifica manualmente cada binario de upgrade
antes de sincronizar.

### 1. Dependencias y configuración

En Ubuntu instala Docker Engine/Compose v2, Git, `curl`, `jq`, `python3`, Go
compatible con la release, y [nvm](https://github.com/nvm-sh/nvm). No ejecutes
los scripts como root. Revisa la [guía oficial del nodo](https://docs.dydx.xyz/nodes/running-node/setup)
y la [configuración de red](https://docs.dydx.xyz/nodes/resources).

Para configurar manualmente o cambiar valores por defecto, copia:

```sh
cp .env.example .env
cp .env.node.example .env.node
```

Edita ambos archivos. Pon secretos propios (por ejemplo, valores
hexadecimales generados con `openssl rand -hex 32`) y confirma que
`PROTOCOL_VERSION` en `.env.node` ya es compatible con el software activo en
mainnet. El ejemplo se versiona como referencia; no se asume que siga siendo
la release vigente.

### 2. Preparar y arrancar el Indexer oficial

```sh
scripts/setup-indexer.sh
scripts/start-indexer.sh
```

Esto clona la release `indexer/v9.5.11` en `.vendor/v4-chain`, instala las
dependencias usando el `.nvmrc` oficial y arranca Ender, Vulcan, Kafka,
PostgreSQL, Comlink y Socks. Cambia el ref con `INDEXER_REF` al ejecutar el
script si necesitas otra release.

Espera a que el servicio `postgres-package` termine las migraciones; después
crea el usuario de lectura para el tracker:

```sh
scripts/create-indexer-reader.sh
```

El override conserva PostgreSQL en un volumen, no publica su puerto y limita
Kafka/Comlink/Socks a loopback. La red Docker para node y tracker es
`dydx-indexer_default`. Usa la composición local oficial de desarrollo en un
solo host; no es una configuración HA ni una distribución de producción con
TLS. Mantén los puertos privados, respalda PostgreSQL y monitoriza el disco de
Kafka durante el catch-up.

### 3. Instalar y arrancar el full node

Instala Go y Cosmovisor según la documentación oficial. Luego:

```sh
scripts/install-dydx-node.sh
sudo systemctl start dydxprotocold
sudo journalctl -u dydxprotocold -f
```

El instalador descarga el binario oficial de la release configurada y verifica
su SHA-256 contra GitHub; obtiene genesis y seeds del repositorio de red
`dydxopsdao/networks`; configura `dydx-mainnet-1`, pruning archivístico, RPC y
el flag de full node no validador. El servicio publica los eventos del nodo a
Kafka (`127.0.0.1:29092`), que Ender consume.

El RPC queda escuchando en la interfaz configurada por `NODE_RPC_LISTEN`
(predeterminado `0.0.0.0:26657`) para Comlink. **Configura el firewall para
permitirlo solo desde la red Docker/local; nunca lo expongas a Internet.**
Abre el puerto P2P que indique la guía oficial para que el nodo pueda sincronizar.
Comprueba el tip con `curl -s localhost:26657/status | jq`.

### 4. Arrancar el tracker

Una vez que el Indexer y PostgreSQL estén listos:

```sh
scripts/start-tracker.sh
docker compose --env-file .env \
  -f docker-compose.yml -f docker-compose.indexer.yml logs -f tracker
```

El cursor se reanuda desde `sync_state.last_height`; los reintentos usan
`UPSERT` y vuelven a escanear alturas recientes.

### Limitación histórica importante

Un Indexer nuevo **no recupera por sí solo** eventos anteriores a su arranque.
El diseño anterior sincroniza un nodo desde genesis mientras Kafka y Ender ya
están activos, para que el Indexer procese los bloques históricos, siempre que
Cosmovisor consiga aplicar cada upgrade histórico. Un snapshot actual o un nodo
ya sincronizado no vuelve a emitir todo el historial. Si el
nodo se detiene, Kafka pierde eventos o Ender empieza tarde, hay que recuperar
el hueco con una reproducción histórica compatible; este tracker no la realiza.
Verifica que `blocks` y `fills` cubran el período antes de considerar completo
el backfill.

No uses el Indexer público para esta aplicación: no permite leer directamente
su PostgreSQL y la API de fills es por subcuenta. Referencias:

- [Repositorio v4-chain](https://github.com/dydxprotocol/v4-chain)
- [Instalación del Indexer oficial](https://github.com/dydxprotocol/v4-chain/tree/main/indexer)
- [Arquitectura del Indexer](https://docs.dydx.exchange/concepts-architecture/indexer)
- [Instalación de full node](https://docs.dydx.xyz/nodes/running-node/setup)
- [Recursos de red y snapshots](https://docs.dydx.xyz/nodes/resources)

## API y consultas

- `GET http://localhost:8080/healthz`: estado del servicio y último bloque
  replicado.
- `GET http://localhost:8080/fills?limit=100&offset=0`: lista paginada.
- Filtros opcionales: `wallet`, `start_at`, `end_at` (ISO 8601).
- `GET http://localhost:8080/fills.csv`: descarga CSV, con los mismos filtros.

Ejemplo:

```sh
curl 'http://localhost:8080/fills?wallet=dydx1...&limit=100'
curl -OJ 'http://localhost:8080/fills.csv?start_at=2024-11-17T00:00:00Z'
```

Consulta directa al PostgreSQL destino (si cambiaste usuario/DB, adapta el
comando). Abre `psql` con:

```sh
docker compose exec db psql -U tracker -d dydx_tracker
```

```sql
SELECT wallet, subaccount_number, side, liquidity, price, size, fee,
       created_at, created_at_height, event_id, transaction_hash
FROM btc_usd_fills
WHERE created_at >= TIMESTAMPTZ '2024-11-17 00:00:00+00'
ORDER BY created_at_height, event_id;
```

La columna `event_id` se guarda como hexadecimal minúsculo sin prefijo `0x`.
Los importes se guardan como `NUMERIC` para evitar pérdida de precisión.
`source_fill_id` conserva el ID UUID del Indexer y distingue cada registro
maker/taker.

## Variables

| Variable | Predeterminado | Descripción |
| --- | --- | --- |
| `INDEXER_DB_PASSWORD` | — | Contraseña URL-safe del usuario de lectura del Indexer |
| `INDEXER_DOCKER_NETWORK` | `dydx-indexer_default` | Red Docker del Indexer oficial |
| `DATABASE_URL` | interna en Compose | URL PostgreSQL destino |
| `START_AT` | `2024-11-17T00:00:00Z` | Límite inferior UTC, inclusivo |
| `POLL_INTERVAL_SECONDS` | `5` | Intervalo de sincronización |
| `BATCH_SIZE` | `1000` | Filas por lote |
| `REPLAY_BLOCKS` | `20` | Alturas recientes que se re-escanean |
| `POSTGRES_DB` | `dydx_tracker` | DB destino |
| `POSTGRES_USER` | `tracker` | Usuario destino |
| `POSTGRES_PASSWORD` | `change-me` | Contraseña destino (**cambiar**) |
| `MIN_ARCHIVE_FREE_GB` | `12000` | Espacio libre exigido por el instalador del nodo |
| `ALLOW_UNDER_SPECCED` | `false` | Permite saltar el control de recursos del nodo |

`PROTOCOL_VERSION`, `NODE_NAME`, `NODE_HOME`, `NODE_KAFKA_ADDR`,
`NODE_RPC_LISTEN` y `DAEMON_ALLOW_DOWNLOAD_BINARIES` se configuran en
`.env.node`.

## Operación

```sh
docker compose --env-file .env \
  -f docker-compose.yml -f docker-compose.indexer.yml ps
docker compose --env-file .env \
  -f docker-compose.yml -f docker-compose.indexer.yml logs -f tracker
```

Para bajar solo tracker y su PostgreSQL:

```sh
docker compose --env-file .env \
  -f docker-compose.yml -f docker-compose.indexer.yml down
```

Para bajar el Indexer oficial sin borrar sus volúmenes:

```sh
scripts/stop-indexer.sh
```

No añadas `-v`: elimina los datos persistentes. El nodo se opera con
`sudo systemctl stop dydxprotocold`.
