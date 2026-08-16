#!/usr/bin/env bash
# First-run Immich install (interactive) — official images + Valkey + Immich Postgres.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/deps.sh
source "${ROOT}/scripts/deps.sh"

ui_banner "Immich" "Docker Compose · official Immich images + Valkey + Postgres"
ui_steps_init 5

ui_step "Preparing configuration"
if [[ ! -f .env ]]; then
  cp .env.example .env
  ui_ok "Created .env from .env.example"
else
  ui_ok "Using existing .env"
fi

configure_container_engine

ui_step "Checking host dependencies"
ensure_host_deps docker

configure_host_port IMMICH_PORT "Immich HTTP" 2283

if grep -q '^DB_PASSWORD=CHANGE_ME' .env; then
  PASS="$(openssl rand -base64 36 | tr -d '\n/+=\n' | tr -cd 'A-Za-z0-9' | head -c 32)"
  sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${PASS}|" .env
  ui_ok "Generated DB_PASSWORD in .env (keep this file private)"
else
  ui_ok "DB_PASSWORD already set — leaving it alone"
fi

if grep -q '^TZ=America/New_York' .env && [[ -f /etc/timezone ]]; then
  TZ_VAL="$(cat /etc/timezone)"
  sed -i "s|^TZ=.*|TZ=${TZ_VAL}|" .env
  ui_ok "Set TZ=${TZ_VAL} from /etc/timezone"
fi

mkdir -p data/library data/postgres data/model-cache data/redis

ui_step "Pulling official Immich images"
ui_run "compose pull" compose pull

ui_step "Starting Immich stack"
ui_run "compose up -d" compose up -d

ensure_host_owned_dir data/library data/postgres data/model-cache data/redis

ui_step "Waiting for API"
PORT="$(grep -E '^IMMICH_PORT=' .env | cut -d= -f2 || echo 2283)"
ok=0
if ui_progress_wait "Immich API" 180 \
  bash -c "curl -fsS \"http://127.0.0.1:${PORT}/api/server/ping\" 2>/dev/null | grep -q pong"; then
  ok=1
fi

IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo YOUR_IP)"
echo
ui_ok "Immich is starting"
ui_info "Open: ${UI_BOLD}http://${IP}:${PORT}${UI_RESET}"
ui_info "1) Create your admin account"
ui_info "2) Install the Immich mobile app and point it at that URL"
ui_info "3) Later: ./manage.sh update   ·   ./manage.sh backup --dest /path/to/external-drive"
if [[ "$ok" -ne 1 ]]; then
  ui_warn "API not ready yet — wait a minute and refresh the URL"
  compose ps || true
fi
