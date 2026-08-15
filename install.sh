#!/usr/bin/env bash
# First-run Immich install using Immich’s official images + Valkey + Immich Postgres.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
# shellcheck source=deps.sh
source "${ROOT}/deps.sh"
ensure_host_deps docker

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "Created .env from .env.example"
fi

# Strong DB password (alphanumeric only — Immich requirement)
if grep -q '^DB_PASSWORD=CHANGE_ME' .env; then
  PASS="$(openssl rand -base64 36 | tr -d '\n/+=\n' | tr -cd 'A-Za-z0-9' | head -c 32)"
  sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${PASS}|" .env
  echo "Generated DB_PASSWORD in .env (keep this file private)."
fi

# Timezone hint
if grep -q '^TZ=America/New_York' .env; then
  if [[ -f /etc/timezone ]]; then
    TZ_VAL="$(cat /etc/timezone)"
    sed -i "s|^TZ=.*|TZ=${TZ_VAL}|" .env
    echo "Set TZ=${TZ_VAL} from /etc/timezone (edit .env if wrong)."
  fi
fi

mkdir -p data/library data/postgres data/model-cache data/redis
echo "Pulling official Immich images (first time can take a while)..."
docker compose pull
docker compose up -d

# Wait for API
echo "Waiting for Immich to become ready..."
ok=0
for i in $(seq 1 90); do
  if curl -fsS "http://127.0.0.1:${IMMICH_PORT:-2283}/api/server/ping" 2>/dev/null | grep -q pong; then
    ok=1
    break
  fi
  # port from .env
  PORT="$(grep -E '^IMMICH_PORT=' .env | cut -d= -f2 || echo 2283)"
  if curl -fsS "http://127.0.0.1:${PORT}/api/server/ping" 2>/dev/null | grep -q pong; then
    ok=1
    break
  fi
  sleep 2
done

IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo YOUR_IP)"
PORT="$(grep -E '^IMMICH_PORT=' .env | cut -d= -f2 || echo 2283)"

cat <<MSG

Immich is starting.

Open:  http://${IP}:${PORT}

1) Create your admin account in the browser
2) Install the Immich mobile app and point it at that URL
3) Later updates:  ./update.sh
4) Backups:        ./backup.sh --dest /path/to/external-drive

Data lives under ./data/ (library + postgres + redis + model-cache).
Keep .env private — it has your database password.

MSG
if [[ "$ok" -ne 1 ]]; then
  echo "Note: API not ready yet — wait a minute and refresh the URL."
  docker compose ps
fi
