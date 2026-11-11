#!/bin/bash
# =============================================================================
# 06_logs.sh — Stream logs from one or all containers
# =============================================================================
set -e

PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
# shellcheck source=lib_common.sh
. "${PROJECT_ROOT}/scripts/lib_common.sh"

require_docker

# Parse args: a container name (or "all") plus an optional -f/--follow flag.
TARGET=""
FOLLOW="${FOLLOW:-false}"
for arg in "$@"; do
    case "${arg}" in
        -f|--follow) FOLLOW="true" ;;
        *) TARGET="${arg}" ;;
    esac
done

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
    # For a specific container, default to a one-shot dump of the last 100 lines
    # (so `logs <name> | tail -20` works). Pass -f to follow the stream live.
    if [ "${FOLLOW}" = "true" ]; then
        docker logs -f "${TARGET}"
    else
        docker logs --tail 100 "${TARGET}"
    fi
fi
