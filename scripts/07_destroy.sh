#!/bin/bash
# =============================================================================
# 07_destroy.sh — Tear down all containers (preserves image and config)
# =============================================================================
set -e

PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
# shellcheck source=lib_common.sh
. "${PROJECT_ROOT}/scripts/lib_common.sh"

require_docker

PURGE=false
[ "${1:-}" = "--purge" ] && PURGE=true

mapfile -t CONTAINERS < <(list_containers_all)
TOTAL=${#CONTAINERS[@]}

if [ "${TOTAL}" -eq 0 ]; then
    log "Nothing to destroy."
    exit 0
fi

print_banner
section "Destroying ${TOTAL} containers"
docker rm -f "${CONTAINERS[@]}" >/dev/null 2>&1
ok "Removed ${TOTAL} containers"

if [ "${PURGE}" = true ]; then
    section "Purge mode"
    docker rmi "${IMAGE}" 2>/dev/null && ok "Image '${IMAGE}' removed" || warn "Image was not present"
    rm -f "${PROJECT_ROOT}/haproxy.cfg" "${PROJECT_ROOT}/haproxy.cfg.bak" 2>/dev/null
    ok "Local haproxy.cfg removed"
fi

log "Done. To restart: ./1proxy2xvpn up"
