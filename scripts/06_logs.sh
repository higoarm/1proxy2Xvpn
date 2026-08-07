#!/bin/bash
# =============================================================================
# 06_logs.sh — Stream logs from one or all containers
# =============================================================================
set -e

PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
# shellcheck source=lib_common.sh
. "${PROJECT_ROOT}/scripts/lib_common.sh"

require_docker

TARGET="${1:-}"
FOLLOW="${FOLLOW:-true}"

if [ -z "${TARGET}" ] || [ "${TARGET}" = "all" ]; then
    log "Streaming logs from ALL containers (Ctrl+C to stop)..."
    log "Tip: prefix each line with container name for clarity"
    mapfile -t CONTAINERS < <(list_containers)
    for NAME in "${CONTAINERS[@]}"; do
        docker logs -f --tail 5 "${NAME}" 2>&1 | sed "s/^/[${NAME}] /" &
    done
    wait
else
    if ! docker inspect "${TARGET}" >/dev/null 2>&1; then
        die "Container '${TARGET}' not found. List with: ./1proxy2xvpn status"
    fi
    if [ "${FOLLOW}" = "true" ]; then
        docker logs -f "${TARGET}"
    else
        docker logs --tail 100 "${TARGET}"
    fi
fi
