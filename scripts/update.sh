#!/usr/bin/env bash
# Safely update Immich (waits for full pull + healthy recreate).
# Pre-update snapshot via ./manage.sh backup into ./backups (database-safe + incremental library).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/deps.sh
source "${ROOT}/scripts/deps.sh"

# Long client timeouts so cron never aborts mid-pull
export COMPOSE_HTTP_TIMEOUT="${COMPOSE_HTTP_TIMEOUT:-86400}"
export DOCKER_CLIENT_TIMEOUT="${DOCKER_CLIENT_TIMEOUT:-86400}"
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

KEEP_FILE=".backup-keep-count"
DEFAULT_KEEP=3
BACKUP_ROOT="${ROOT}/backups"

need() { command -v "$1" >/dev/null || { echo "Missing: $1" >&2; exit 1; }; }

print_offsite_tip() {
  cat <<'EOF'

Tip: Local backups under backups/ can fill your disk (Immich library is large).
Prefer --dest on an external drive/NAS for disaster copies, or copy backups/ off-box.
Restore: ./manage.sh backup --restore --from ./backups
EOF
}

prune_old_backups() {
  local keep="$1"
  mkdir -p "${BACKUP_ROOT}/snapshots"
  mapfile -t dirs < <(ls -1dt "${BACKUP_ROOT}"/snapshots/* 2>/dev/null || true)
  local total="${#dirs[@]}"
  if (( total > keep )); then
    local i
    for (( i = keep; i < total; i++ )); do
      echo "Removing old snapshot: ${dirs[$i]}"
      rm -rf "${dirs[$i]}"
    done
  else
    echo "Backup retention: keeping all ${total} snapshot(s) (limit ${keep})."
  fi
  local newest
  newest="$(ls -1dt "${BACKUP_ROOT}"/snapshots/* 2>/dev/null | head -1 || true)"
  if [[ -n "$newest" ]]; then
    ln -sfn "snapshots/$(basename "$newest")" "${BACKUP_ROOT}/latest"
  fi
}

ask_backup_retention() {
  local dir="$1"
  [[ -n "$dir" && -e "$dir" ]] || return 0
  if [[ ! -t 0 ]]; then
    echo "No interactive terminal - keeping backup at ${dir}"
    local keep="${DEFAULT_KEEP}"
    [[ -f "${KEEP_FILE}" ]] && keep="$(tr -dc '0-9' <"${KEEP_FILE}" || true)"
    [[ -z "${keep}" ]] && keep="${DEFAULT_KEEP}"
    echo "${keep}" >"${KEEP_FILE}"
    prune_old_backups "${keep}"
    print_offsite_tip
    return 0
  fi
  echo
  local reply=""
  read -r -p "Update succeeded. Keep rollback backup at ${dir}? [Y/n] " reply || true
  case "${reply:-Y}" in
    n|N|no|NO)
      rm -rf "${dir}"
      echo "Backup deleted."
      ;;
    *)
      echo "Backup kept."
      local default="${DEFAULT_KEEP}" keep=""
      [[ -f "${KEEP_FILE}" ]] && default="$(tr -dc '0-9' <"${KEEP_FILE}" || true)"
      [[ -z "${default}" ]] && default="${DEFAULT_KEEP}"
      read -r -p "How many local backups should we keep on this disk? [${default}] " keep || true
      keep="$(printf '%s' "${keep:-$default}" | tr -dc '0-9')"
      [[ -z "${keep}" || "${keep}" -lt 1 ]] && keep="${default}"
      echo "${keep}" >"${KEEP_FILE}"
      prune_old_backups "${keep}"
      print_offsite_tip
      echo "  Restore: ./manage.sh backup --restore --from ./backups"
      ;;
  esac
}

create_backup() {
  if [[ ! -x "${ROOT}/scripts/backup.sh" ]]; then
    echo "Missing executable backup.sh" >&2
    exit 1
  fi
  local keep="${DEFAULT_KEEP}"
  [[ -f "${KEEP_FILE}" ]] && keep="$(tr -dc '0-9' <"${KEEP_FILE}" || true)"
  [[ -z "${keep}" ]] && keep="${DEFAULT_KEEP}"
  echo "==> Pre-update snapshot via ./manage.sh backup --dest ${BACKUP_ROOT} ..."
  echo "    (Library uses hardlinks; first run can take a while.)"
  "${ROOT}/scripts/backup.sh" --dest "${BACKUP_ROOT}" --keep "${keep}"
  if [[ -L "${BACKUP_ROOT}/latest" ]]; then
    BACKUP_DIR="$(readlink -f "${BACKUP_ROOT}/latest")"
  else
    BACKUP_DIR="$(ls -1dt "${BACKUP_ROOT}"/snapshots/* 2>/dev/null | head -1 || true)"
  fi
  [[ -n "${BACKUP_DIR}" && -d "${BACKUP_DIR}" ]] || {
    echo "Pre-update backup failed." >&2
    exit 1
  }
  echo "Backup ready: ${BACKUP_DIR}"
}

need_container_engine
[[ -f .env ]] || { echo "No .env - Immich not configured here." >&2; exit 1; }

create_backup

echo "==> Pulling newer Immich images (waits until fully downloaded/extracted)..."
compose pull
echo "==> Recreating stack and waiting for healthy..."
# podman-compose has no --wait/--wait-timeout; passing them aborts the update.
# The API check below is the readiness gate on that engine.
if [[ "${CONTAINER_ENGINE:-docker}" == podman ]]; then
  compose up -d --remove-orphans
else
  compose up -d --remove-orphans --wait --wait-timeout 3600
fi
echo "==> Status:"
compose ps
echo "==> API check..."
ok=0
for i in $(seq 1 60); do
  PORT="$(grep -E '^IMMICH_PORT=' .env | cut -d= -f2 || echo 2283)"
  if curl -fsS "http://127.0.0.1:${PORT}/api/server/ping" 2>/dev/null | grep -q pong; then
    echo "API healthy."
    ok=1
    break
  fi
  sleep 5
done
[[ "$ok" -eq 1 ]] || {
  echo "API not healthy after update." >&2
  compose logs --tail=80 >&2 || true
  exit 1
}
echo "==> Pruning dangling images only..."
container_image_prune

echo
echo "Update finished."
ask_backup_retention "${BACKUP_DIR}"
