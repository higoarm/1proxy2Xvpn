#!/bin/bash
# =============================================================================
# 09_rotate.sh — Force IP rotation by restarting one or more containers
# Usage:
#   ./1proxy2xvpn rotate                  # rotate ALL containers
#   ./1proxy2xvpn rotate <container>      # rotate specific container
#   ./1proxy2xvpn rotate --burned         # rotate all blacklisted
# =============================================================================
set -e

PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
# shellcheck source=lib_common.sh
. "${PROJECT_ROOT}/scripts/lib_common.sh"

require_docker

TARGET="${1:-}"

if [ "${TARGET}" = "--burned" ]; then
    BLACKLIST_FILE="${CONFIG_DIR}/blacklist"
    [ ! -s "${BLACKLIST_FILE}" ] && die "Blacklist is empty"
    mapfile -t TARGETS < "${BLACKLIST_FILE}"
    log "Rotating ${#TARGETS[@]} burned containers..."
elif [ -z "${TARGET}" ]; then
    mapfile -t TARGETS < <(list_containers)
    log "Rotating ALL ${#TARGETS[@]} containers — this will take a while..."
else
    if ! docker inspect "${TARGET}" >/dev/null 2>&1; then
        die "Container '${TARGET}' not found"
    fi
    TARGETS=("${TARGET}")
fi

for NAME in "${TARGETS[@]}"; do
    [ -z "${NAME}" ] && continue
    BEFORE_IP=$(curl -sf --max-time 3 -x "http://localhost:$(container_port "${NAME}")" \
                https://api.ipify.org 2>/dev/null || echo "?")
    docker restart "${NAME}" >/dev/null 2>&1
    log "Restarted ${NAME} (previous IP: ${BEFORE_IP}, will reconnect in ~30s)"
done

ok "Rotation initiated. Run './1proxy2xvpn status' in ~60s to see new IPs."
