#!/usr/bin/env bash
# Repair greyed-out / broken Immich assets (corrupt uploads, missing video metadata).
# Standalone tool — not part of manage.sh. Safe to run while Immich is up.
#
# Usage:
#   ./fix-library/fix-library.sh scan
#   ./fix-library/fix-library.sh fix              # dry-run (report only)
#   ./fix-library/fix-library.sh fix --apply      # delete broken, queue repair jobs
#   ./fix-library/fix-library.sh fix --apply --wait-metadata
#   ./fix-library/fix-library.sh thumbnails --apply
#
# Auto-detects Docker Compose (this repo) vs Kubernetes (immich-k8s deploy.yaml).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/fix-library"
JS="${LIB}/fix-library.js"

usage() {
  cat <<EOF
Immich library repair (fix greyed-out photos/videos and corrupt uploads)

Usage:
  ./fix-library/fix-library.sh scan
  ./fix-library/fix-library.sh fix [--apply] [--wait-metadata] [--skip-trash] [--json]
  ./fix-library/fix-library.sh thumbnails [--apply]

Commands:
  scan         Report broken / fixable assets (no changes)
  fix          Remove corrupt assets, restore good trash, queue metadata/thumbnails
  thumbnails   Queue thumbnail jobs for videos that already have metadata

Options:
  --apply           Make changes (default for fix/thumbnails is dry-run)
  --wait-metadata   Wait for metadata jobs, then queue thumbnails (fix --apply only)
  --skip-trash      Do not restore good trash or delete broken trash
  --json            Machine-readable scan output

Environment (Kubernetes):
  IMMICH_NAMESPACE   Namespace (default: immich)

Requires a running immich-server container/pod.
EOF
}

if [[ ! -f "${JS}" ]]; then
  echo "Missing ${JS}" >&2
  exit 1
fi

detect_mode() {
  if [[ -f "${ROOT}/docker-compose.yml" || -f "${ROOT}/compose.yaml" ]]; then
    echo docker
  elif [[ -f "${ROOT}/deploy.yaml" ]]; then
    echo k8s
  else
    echo unknown
  fi
}

server_container_id() {
  local svc="immich-server"
  local cid=""
  load_container_engine
  case "${CONTAINER_ENGINE}" in
    podman)
      if command -v podman-compose >/dev/null 2>&1; then
        local workdir="${ROOT}"
        cid="$(podman ps --filter "status=running" \
          --filter "label=com.docker.compose.project.working_dir=${workdir}" \
          --filter "label=com.docker.compose.service=${svc}" \
          --format '{{.ID}}' 2>/dev/null | head -1)"
        if [[ -z "${cid}" ]]; then
          local project
          project="${COMPOSE_PROJECT_NAME:-$(basename "${ROOT}")}"
          project="$(printf '%s' "${project}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
          cid="$(podman ps --filter "status=running" \
            --filter "label=com.docker.compose.project=${project}" \
            --filter "label=com.docker.compose.service=${svc}" \
            --format '{{.ID}}' 2>/dev/null | head -1)"
        fi
        if [[ -z "${cid}" ]]; then
          cid="$(podman ps --filter "status=running" \
            --filter "label=io.podman.compose.service=${svc}" \
            --format '{{.ID}}' 2>/dev/null | head -1)"
        fi
      else
        cid="$(compose ps -q "${svc}" 2>/dev/null | head -1)"
      fi
      ;;
    *)
      cid="$(compose ps -q "${svc}" 2>/dev/null | head -1)"
      ;;
  esac
  [[ -n "${cid}" ]] || return 1
  printf '%s\n' "${cid}"
}

run_in_server() {
  local mode="$1"
  shift
  if [[ "${mode}" == docker ]]; then
    # shellcheck source=scripts/deps.sh
    source "${ROOT}/scripts/deps.sh"
    cd "${ROOT}"
    load_container_engine
    if ! compose_service_running immich-server; then
      echo "immich-server is not running. Start the stack first: ./manage.sh" >&2
      exit 1
    fi
    local cid engine
    cid="$(server_container_id)" || { echo "Could not find immich-server container." >&2; exit 1; }
    engine="$(env_file_get CONTAINER_ENGINE docker "${ROOT}/.env" 2>/dev/null || echo docker)"
    ${engine} cp "${JS}" "${cid}:/usr/src/app/server/fix-library.js" >/dev/null
    ${engine} exec -w /usr/src/app/server "${cid}" node fix-library.js "$@"
  elif [[ "${mode}" == k8s ]]; then
    command -v kubectl >/dev/null 2>&1 || { echo "Missing: kubectl" >&2; exit 1; }
    local ns="${IMMICH_NAMESPACE:-immich}"
    local pod
    pod="$(kubectl -n "${ns}" get pod -l app=immich-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    [[ -n "${pod}" ]] || { echo "No immich-server pod in namespace ${ns}." >&2; exit 1; }
    kubectl cp "${JS}" "${ns}/${pod}:/usr/src/app/server/fix-library.js" >/dev/null
    kubectl exec -n "${ns}" "${pod}" -w /usr/src/app/server -- node fix-library.js "$@"
  else
    echo "Could not detect deployment mode (need docker-compose.yml or deploy.yaml)." >&2
    exit 1
  fi
}

MODE="$(detect_mode)"
CMD="${1:-}"
shift || true

if [[ -z "${CMD}" || "${CMD}" == "-h" || "${CMD}" == "--help" ]]; then
  usage
  exit 0
fi

case "${CMD}" in
  scan)
    run_in_server "${MODE}" scan "$@"
    ;;
  fix)
    if [[ " $* " != *" --apply "* ]]; then
      run_in_server "${MODE}" fix --dry-run "$@"
    else
      run_in_server "${MODE}" fix "$@"
    fi
    ;;
  thumbnails)
    if [[ " $* " != *" --apply "* ]]; then
      run_in_server "${MODE}" thumbnails --dry-run "$@"
    else
      run_in_server "${MODE}" thumbnails --apply "$@"
    fi
    ;;
  *)
    echo "Unknown command: ${CMD}" >&2
    usage >&2
    exit 1
    ;;
esac
