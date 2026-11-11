#!/bin/bash
# =============================================================================
# 02_build.sh — Build the hardened Docker image
# =============================================================================
set -e

PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
# shellcheck source=lib_common.sh
. "${PROJECT_ROOT}/scripts/lib_common.sh"

require_docker
print_banner
section "Building image '${IMAGE}'"

[ ! -f "${PROJECT_ROOT}/docker/Dockerfile" ] && die "Dockerfile missing"

NO_CACHE=""
[ "${1:-}" = "--no-cache" ] && NO_CACHE="--no-cache"

log "Building from ${PROJECT_ROOT}/docker/"
log "This takes ~2-3 minutes on first run..."
echo

docker build ${NO_CACHE} \
    -t "${IMAGE}" \
    -f "${PROJECT_ROOT}/docker/Dockerfile" \
    "${PROJECT_ROOT}/docker"

if [ $? -eq 0 ]; then
    SIZE=$(docker image inspect "${IMAGE}" --format='{{.Size}}' | awk '{printf "%.1f MB", $1/1024/1024}')
    DIGEST=$(docker image inspect "${IMAGE}" --format='{{.Id}}' | cut -c1-19)
    section "Build complete"
    ok "Image  : ${IMAGE}"
    ok "Digest : ${DIGEST}"
    ok "Size   : ${SIZE}"
    echo
    log "Next: ./1proxy2xvpn up"
else
    die "Build failed"
fi
