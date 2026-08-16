#!/usr/bin/env bash
# Control center for Immich (Docker) — install, update, backup, status, uninstall.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
# shellcheck source=deps.sh
source "${ROOT}/deps.sh"

TITLE="Immich"
CMD="${1:-}"
shift || true

usage() {
  cat <<EOF
${UI_BOLD}${TITLE} · manage.sh${UI_RESET}

Usage:
  ./manage.sh                 Interactive menu
  ./manage.sh install         Run install / reconfigure
  ./manage.sh update          Safe update (pre-backup)
  ./manage.sh backup [args]   Pass-through to backup.sh
  ./manage.sh status|doctor   Health check
  ./manage.sh uninstall       Interactive uninstall
  ./manage.sh features        Show differentiators
  ./manage.sh help            This help

Tip: most people only need ${UI_BOLD}./manage.sh${UI_RESET}
EOF
}

case "${CMD}" in
  ""|menu) manage_menu_docker "$TITLE" ;;
  install) exec "${ROOT}/install.sh" "$@" ;;
  update) exec "${ROOT}/update.sh" "$@" ;;
  backup) exec "${ROOT}/backup.sh" "$@" ;;
  status|doctor) doctor_docker "$TITLE" ;;
  uninstall) uninstall_docker_stack "$TITLE" ;;
  features) ui_banner "$TITLE" "Features"; print_homelab_features ;;
  help|-h|--help) usage ;;
  *) ui_err "Unknown command: ${CMD}"; usage; exit 1 ;;
esac
