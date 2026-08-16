#!/usr/bin/env bash
# Immich disaster-recovery backup/restore with incremental rsync snapshots.
# - PostgreSQL: verified logical dump (never live datadir rsync)
# - Library: incremental hardlink snapshots (large media tree)
# - SHA256: full checksums for dumps/config; library uses a fast size+path fingerprint
#   (full per-file hashing of hundreds of GB would take forever / thrash the disk)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/deps.sh
source "${ROOT}/scripts/deps.sh"
# shellcheck source=scripts/backup-encrypt.sh
source "${ROOT}/scripts/backup-encrypt.sh"
STACK_ID="immich-docker"

need() { command -v "$1" >/dev/null || { echo "Missing: $1" >&2; exit 1; }; }
need_rsync() {
  command -v rsync >/dev/null 2>&1 || {
    echo "Missing: rsync (needed for incremental snapshots)." >&2
    exit 1
  }
}

usage() {
  cat <<'EOF'
Usage:
  ./manage.sh backup --dest /path/to/backup-root [--keep N] [--include-model-cache]
  ./manage.sh backup --restore --from /path/to/backup-root-or-snapshot
  ./manage.sh backup --help

  --dest DIR               Create incremental snapshot under DIR
  --keep N                 Keep only newest N snapshots after backup
  --include-model-cache    Also snapshot data/model-cache (re-downloadable; optional)
  --restore --from PATH    Restore into this Immich install

  Optional offsite exports (see README / repo-framework docs/BACKUP_ENCRYPTION.md):
  --archive tar.gz|tar.xz|zip [--archive-password]
  --encrypt [--export-dir DIR] [--age-recipient R] [--passphrase]

Fresh machine:
  1) Place compose + .env here and compose up once (or restore .env from snapshot)
  2) ./manage.sh backup --restore --from /mnt/usb/immich-backups
EOF
}

MODE=""
DEST=""
FROM=""
KEEP=""

ENCRYPT="${BACKUP_ENCRYPT:-0}"
EXPORT_DIR="${BACKUP_EXPORT_DIR:-}"
ENCRYPT_PASSPHRASE=0
ARCHIVE_FORMAT="${BACKUP_ARCHIVE:-}"
ARCHIVE_PASSWORD="${BACKUP_ARCHIVE_PASSWORD:-0}"
AGE_RECIPIENTS=()
AGE_IDENTITY="${BACKUP_AGE_IDENTITY:-}"
INCLUDE_MODEL_CACHE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest)
      [[ $# -ge 2 ]] || { echo "--dest needs a path" >&2; exit 1; }
      DEST="$2"; MODE="${MODE:-backup}"; shift 2 ;;
    --from)
      [[ $# -ge 2 ]] || { echo "--from needs a path" >&2; exit 1; }
      FROM="$2"; shift 2 ;;
    --restore) MODE="restore"; shift ;;
    --archive)
      [[ $# -ge 2 ]] || { echo "--archive needs tar.gz|tar.xz|zip" >&2; exit 1; }
      ARCHIVE_FORMAT="$2"; shift 2 ;;
    --archive-password)
      ARCHIVE_PASSWORD=1; shift ;;
    --encrypt)
      ENCRYPT=1; shift ;;
    --export-dir)
      [[ $# -ge 2 ]] || { echo "--export-dir needs a path" >&2; exit 1; }
      EXPORT_DIR="$2"; shift 2 ;;
    --age-recipient)
      [[ $# -ge 2 ]] || { echo "--age-recipient needs a value" >&2; exit 1; }
      AGE_RECIPIENTS+=("$2"); shift 2 ;;
    --age-identity)
      [[ $# -ge 2 ]] || { echo "--age-identity needs a path" >&2; exit 1; }
      AGE_IDENTITY="$2"; shift 2 ;;
    --passphrase)
      ENCRYPT=1; ENCRYPT_PASSPHRASE=1; shift ;;
    --keep)
      [[ $# -ge 2 ]] || { echo "--keep needs a number" >&2; exit 1; }
      KEEP="$2"; shift 2 ;;
    --include-model-cache) INCLUDE_MODEL_CACHE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

stamp_now() { date +%Y%m%d-%H%M%S; }

resolve_snapshot_dir() {
  local path="$1"
  [[ -e "$path" ]] || { echo "Not found: $path" >&2; exit 1; }
  path="$(cd "$path" && pwd)"
  if [[ -f "${path}/META.txt" ]]; then
    printf '%s\n' "$path"; return 0
  fi
  if [[ -L "${path}/latest" ]]; then
    local target=""
    if target="$(readlink -f "${path}/latest" 2>/dev/null)"; then :; else
      target="$(readlink "${path}/latest")"
      [[ "$target" == /* ]] || target="${path}/${target}"
    fi
    if [[ -f "${target}/META.txt" ]]; then
      printf '%s\n' "$(cd "$target" && pwd)"; return 0
    fi
  fi
  local newest
  newest="$(ls -1dt "${path}"/snapshots/* 2>/dev/null | head -1 || true)"
  if [[ -n "$newest" && -f "${newest}/META.txt" ]]; then
    printf '%s\n' "$(cd "$newest" && pwd)"; return 0
  fi
  echo "No usable snapshot under: $path" >&2
  exit 1
}

prepare_snapshot_dirs() {
  local dest="$1"
  mkdir -p "${dest}/snapshots"
  SNAP_NAME="$(stamp_now)"
  SNAP_DIR="${dest}/snapshots/${SNAP_NAME}"
  mkdir -p "${SNAP_DIR}"
  PREV_LINK=""
  if [[ -L "${dest}/latest" ]]; then
    PREV_LINK="$(readlink "${dest}/latest")"
    [[ "${PREV_LINK}" == /* ]] || PREV_LINK="${dest}/${PREV_LINK}"
  fi
}

finalize_snapshot() {
  local dest="$1"
  ln -sfn "snapshots/${SNAP_NAME}" "${dest}/latest"
  echo "Snapshot ready: ${SNAP_DIR}"
  echo "Latest pointer: ${dest}/latest -> snapshots/${SNAP_NAME}"
}

prune_snapshots() {
  local dest="$1" keep="$2"
  [[ -n "$keep" ]] || return 0
  keep="$(printf '%s' "$keep" | tr -dc '0-9')"
  [[ -n "$keep" && "$keep" -ge 1 ]] || return 0
  mapfile -t snaps < <(ls -1dt "${dest}"/snapshots/* 2>/dev/null || true)
  local total="${#snaps[@]}"
  if (( total <= keep )); then
    echo "Retention: keeping all ${total} snapshot(s) (limit ${keep})."
    return 0
  fi
  local i
  for (( i = keep; i < total; i++ )); do
    echo "Pruning old snapshot: ${snaps[$i]}"
    rm -rf "${snaps[$i]}"
  done
}

rsync_incremental() {
  local src="$1" dst="$2" prev="${3:-}"
  mkdir -p "$dst"
  local -a args=(-aH --delete --info=stats2)
  if [[ -n "$prev" && -d "$prev" ]]; then
    args+=(--link-dest="$prev")
    echo "    Incremental vs: $prev"
  else
    echo "    Full copy (first snapshot or no previous tree)."
  fi
  # Prefer progress when interactive
  if [[ -t 1 ]]; then
    args+=(--info=progress2)
  fi
  rsync "${args[@]}" "${src}/" "${dst}/"
}

sha256_file() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    echo "unavailable"
  fi
}

verify_pg_dump() {
  local f="$1"
  if [[ ! -s "$f" ]]; then
    echo "PostgreSQL dump missing or empty: $f" >&2
    return 1
  fi
  # gzip or plain
  if [[ "$f" == *.gz ]]; then
    if ! gzip -t "$f" 2>/dev/null; then
      echo "PostgreSQL dump failed gzip integrity: $f" >&2
      return 1
    fi
    if ! gzip -dc "$f" | head -c 200 | grep -qE 'PostgreSQL|pg_dump|CREATE|SET'; then
      echo "PostgreSQL dump does not look like SQL: $f" >&2
      return 1
    fi
  else
    if ! grep -qE 'PostgreSQL database dump|CREATE TABLE|SET ' "$f"; then
      echo "PostgreSQL dump does not look valid: $f" >&2
      return 1
    fi
  fi
  echo "    Verified PostgreSQL dump ($(du -h "$f" | awk '{print $1}'))."
}

# Seal: checksum dumps/config; fingerprint library without reading every media byte
seal_snapshot() {
  local snap="$1"
  echo "==> Sealing snapshot (SHA256 for dumps/config; library fingerprint)..."
  (
    cd "$snap" || exit 1
    rm -f SHA256SUMS LIBRARY_FINGERPRINT
    if [[ -d files/library ]]; then
      # Fast inventory fingerprint (size + path). Detects missing/changed sizes without hashing 300G+.
      find files/library -type f -printf '%s\t%p\n' 2>/dev/null | sort \
        | sha256sum | awk '{print $1}' >LIBRARY_FINGERPRINT
      echo "    library_fingerprint=$(cat LIBRARY_FINGERPRINT)"
    fi
    if command -v sha256sum >/dev/null 2>&1; then
      find . -type f ! -name SHA256SUMS ! -name META.txt ! -path './files/library/*' -print0 \
        | sort -z \
        | xargs -0 -r sha256sum >SHA256SUMS
    else
      : >SHA256SUMS
    fi
  )
  local sum
  sum="$(sha256_file "${snap}/SHA256SUMS")"
  if [[ ! -f "${snap}/META.txt" ]]; then
    printf 'stack=%s\ncreated=%s\n' "$STACK_ID" "$(date -Iseconds)" >"${snap}/META.txt"
  fi
  local libfp=""
  [[ -f "${snap}/LIBRARY_FINGERPRINT" ]] && libfp="$(cat "${snap}/LIBRARY_FINGERPRINT")"
  if grep -q '^snapshot_sha256=' "${snap}/META.txt" 2>/dev/null; then
    sed -i "s|^snapshot_sha256=.*|snapshot_sha256=${sum}|" "${snap}/META.txt"
  else
    printf 'snapshot_sha256=%s\n' "$sum" >>"${snap}/META.txt"
  fi
  if [[ -n "$libfp" ]]; then
    if grep -q '^library_fingerprint=' "${snap}/META.txt" 2>/dev/null; then
      sed -i "s|^library_fingerprint=.*|library_fingerprint=${libfp}|" "${snap}/META.txt"
    else
      printf 'library_fingerprint=%s\n' "$libfp" >>"${snap}/META.txt"
    fi
  fi
  echo "    snapshot_sha256=${sum}"
}

verify_snapshot_integrity() {
  local snap="$1"
  local warn=0
  echo "==> Checking snapshot integrity..."
  if [[ ! -f "${snap}/SHA256SUMS" ]]; then
    echo "WARNING: No SHA256SUMS — cannot verify dump/config integrity." >&2
    warn=1
  elif command -v sha256sum >/dev/null 2>&1; then
    set +e
    local out rc
    out="$(cd "$snap" && sha256sum -c SHA256SUMS 2>&1)"
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
      echo "WARNING: SHA256 verification FAILED for dump/config — integrity may be lost; restore may cause issues." >&2
      printf '%s\n' "$out" | grep -v ': OK$' | head -n 40 >&2 || true
      warn=1
    fi
    local expected actual
    expected="$(grep -E '^snapshot_sha256=' "${snap}/META.txt" 2>/dev/null | cut -d= -f2- || true)"
    actual="$(sha256_file "${snap}/SHA256SUMS")"
    if [[ -n "$expected" && "$expected" != "unavailable" && "$actual" != "$expected" ]]; then
      echo "WARNING: SHA256SUMS does not match META snapshot_sha256 — integrity may be lost." >&2
      warn=1
    fi
  fi
  if [[ -d "${snap}/files/library" && -f "${snap}/LIBRARY_FINGERPRINT" ]]; then
    local expected_fp actual_fp
    expected_fp="$(cat "${snap}/LIBRARY_FINGERPRINT")"
    actual_fp="$(find "${snap}/files/library" -type f -printf '%s\t%p\n' 2>/dev/null | sort | sha256sum | awk '{print $1}')"
    if [[ "$actual_fp" != "$expected_fp" ]]; then
      echo "WARNING: Library inventory fingerprint mismatch — files may have changed or been corrupted in transit." >&2
      warn=1
    else
      echo "    Library fingerprint OK."
    fi
  fi
  if [[ "$warn" -eq 0 ]]; then
    echo "    Integrity OK."
  else
    echo "    Continuing restore despite integrity warnings (not aborting)." >&2
  fi
  return 0
}

wait_immich_healthy() {
  local i port=2283
  [[ -f .env ]] && port="$(grep -E '^IMMICH_PORT=' .env | cut -d= -f2 || echo 2283)"
  echo "Waiting for Immich API..."
  for i in $(seq 1 60); do
    if curl -fsS "http://127.0.0.1:${port}/api/server/ping" 2>/dev/null | grep -q pong; then
      echo "Immich API healthy."
      return 0
    fi
    sleep 5
  done
  echo "Immich API did not become healthy in time." >&2
  compose ps >&2 || true
  return 1
}

do_backup() {
  need_container_engine
  need_rsync
  compose version >/dev/null
  [[ -n "$DEST" ]] || { echo "Provide --dest /path" >&2; exit 1; }
  [[ -f .env ]] || { echo "No .env found." >&2; exit 1; }
  DEST="$(mkdir -p "$DEST" && cd "$DEST" && pwd)"
  prepare_snapshot_dirs "$DEST"
  echo "==> Snapshot ${SNAP_NAME} -> ${SNAP_DIR}"
  echo "==> DB: logical PostgreSQL dump. Library: incremental rsync hardlinks."

  if ! compose ps -q database 2>/dev/null | grep -q .; then
    echo "database service not running — refusing backup." >&2
    rm -rf "${SNAP_DIR}"
    exit 1
  fi

  cleanup_failed() { rm -rf "${SNAP_DIR}"; }
  trap cleanup_failed EXIT

  echo "==> Dumping PostgreSQL (immich)..."
  local dump="${SNAP_DIR}/immich-db.sql.gz"
  # shellcheck disable=SC1091
  set -a; source .env; set +a
  compose exec -T database pg_dump \
    -U "${DB_USERNAME:-postgres}" \
    -d "${DB_DATABASE_NAME:-immich}" \
    --clean --if-exists \
    | gzip -c >"${dump}"
  verify_pg_dump "${dump}"

  [[ -f .env ]] && cp -a .env "${SNAP_DIR}/"
  [[ -f docker-compose.yml ]] && cp -a docker-compose.yml "${SNAP_DIR}/"

  echo "==> Syncing photo library (data/library) — may take a while on first run..."
  local prev_lib=""
  [[ -n "${PREV_LINK}" && -d "${PREV_LINK}/files/library" ]] && prev_lib="${PREV_LINK}/files/library"
  if [[ -d data/library ]]; then
    rsync_incremental "data/library" "${SNAP_DIR}/files/library" "${prev_lib}"
  else
    echo "data/library missing — refusing incomplete backup." >&2
    exit 1
  fi

  if [[ "${INCLUDE_MODEL_CACHE}" -eq 1 && -d data/model-cache ]]; then
    echo "==> Syncing model-cache..."
    local prev_mc=""
    [[ -n "${PREV_LINK}" && -d "${PREV_LINK}/files/model-cache" ]] && prev_mc="${PREV_LINK}/files/model-cache"
    rsync_incremental "data/model-cache" "${SNAP_DIR}/files/model-cache" "${prev_mc}"
  fi

  cat >"${SNAP_DIR}/META.txt" <<EOF
stack=${STACK_ID}
created=$(date -Iseconds)
host=$(hostname 2>/dev/null || echo unknown)
note=immich library + verified postgres dump
db_engine=postgresql
db_method=pg_dump --clean
library=data/library
datadir_excluded=data/postgres (logical dump only)
EOF

  trap - EXIT
  seal_snapshot "${SNAP_DIR}"
  maybe_encrypt_after_seal
  finalize_snapshot "$DEST"
  prune_snapshots "$DEST" "${KEEP}"
  echo
  echo "Backup OK. Tip: keep --dest on the 7TB disk or an external drive (hardlinks need one filesystem)."
}

do_restore() {
  need_container_engine
  need_rsync
  compose version >/dev/null
  [[ -n "$FROM" ]] || { echo "Provide --from /path" >&2; exit 1; }
  local snap src
  src="$(prepare_restore_from_arg "$FROM")"
  trap cleanup_restore_tmp EXIT
  snap="$(resolve_snapshot_dir "$src")"
  echo "Restoring from: $snap"
  verify_snapshot_integrity "$snap"
  [[ -f "${snap}/immich-db.sql.gz" || -f "${snap}/immich-db.sql" ]] || {
    echo "Missing PostgreSQL dump in snapshot." >&2
    exit 1
  }
  [[ -d "${snap}/files/library" ]] || { echo "Missing files/library in snapshot." >&2; exit 1; }

  echo
  cat <<'EOF'
This replaces Immich library + database so a fresh/rebuilt host matches the backup.

Recommended:
  1) Have compose + network ready in this directory
  2) Type 'restore' to continue
EOF
  if [[ -t 0 ]]; then
    read -r -p "Type 'restore' to continue: " confirm || true
    [[ "${confirm}" == "restore" ]] || { echo "Aborted."; exit 1; }
  else
    echo "Non-interactive: set CONFIRM_RESTORE=yes to proceed." >&2
    [[ "${CONFIRM_RESTORE:-}" == "yes" ]] || exit 1
  fi

  echo "==> Stopping Immich..."
  compose down || true

  echo "==> Restoring .env / compose..."
  save_host_install_env
  [[ -f "${snap}/.env" ]] && cp -a "${snap}/.env" .env
  # shellcheck disable=SC1091
  set -a; source .env; set +a
  apply_host_install_env

  echo "==> Restoring library..."
  mkdir -p data/library
  ensure_host_owned_dir data/library
  rsync -aH --delete --info=progress2 "${snap}/files/library/" data/library/

  if [[ -d "${snap}/files/model-cache" ]]; then
    echo "==> Restoring model-cache..."
    mkdir -p data/model-cache
    ensure_host_owned_dir data/model-cache
    rsync -aH --delete "${snap}/files/model-cache/" data/model-cache/
  fi

  echo "==> Rebuilding Postgres datadir and importing dump..."
  # Replace datadir so dump matches restored credentials
  if [[ -n "${DB_DATA_LOCATION:-}" ]]; then
    # resolve relative
    local dbpath="${DB_DATA_LOCATION}"
    [[ "$dbpath" == /* ]] || dbpath="${ROOT}/${dbpath#./}"
    sudo rm -rf "${dbpath}"
    mkdir -p "${dbpath}"
  else
    sudo rm -rf data/postgres
    mkdir -p data/postgres
  fi

  compose up -d database
  echo "Waiting for Postgres..."
  local i
  for i in $(seq 1 60); do
    if compose exec -T database pg_isready -U "${DB_USERNAME:-postgres}" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  compose exec -T database pg_isready -U "${DB_USERNAME:-postgres}"

  if [[ -f "${snap}/immich-db.sql.gz" ]]; then
    if ! gzip -dc "${snap}/immich-db.sql.gz" \
      | compose exec -T database psql -U "${DB_USERNAME:-postgres}" -d "${DB_DATABASE_NAME:-immich}"; then
      echo "SQL IMPORT FAILED — not starting Immich server." >&2
      exit 1
    fi
  else
    if ! compose exec -T database psql -U "${DB_USERNAME:-postgres}" -d "${DB_DATABASE_NAME:-immich}" \
        <"${snap}/immich-db.sql"; then
      echo "SQL IMPORT FAILED — not starting Immich server." >&2
      exit 1
    fi
  fi

  echo "==> Starting full stack..."
  export COMPOSE_HTTP_TIMEOUT="${COMPOSE_HTTP_TIMEOUT:-86400}"
  export DOCKER_CLIENT_TIMEOUT="${DOCKER_CLIENT_TIMEOUT:-86400}"
  compose up -d --remove-orphans --wait --wait-timeout 3600 || compose up -d --remove-orphans
  wait_immich_healthy || true
  compose ps
  echo "Restore finished from ${snap}."
}

case "${MODE}" in
  backup) do_backup ;;
  restore) do_restore ;;
  *) usage >&2; exit 1 ;;
esac
