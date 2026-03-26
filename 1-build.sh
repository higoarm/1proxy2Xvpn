#!/bin/bash
# =============================================================================
# 1-build.sh — Build the 1proxy2xvpn Docker image
# Run this FIRST before starting any containers.
# =============================================================================

IMAGE="1proxy2xvpn"
DOCKER_DIR="$(dirname "$0")/docker"

G='\033[0;32m'; R='\033[0;31m'; B='\033[1;34m'; N='\033[0m'
log() { echo -e "${G}[build]${N} $*"; }
die() { echo -e "${R}[build][ERROR]${N} $*" >&2; exit 1; }

# Validate docker/ directory
[ ! -d "${DOCKER_DIR}" ] && die "Directory 'docker/' not found. Are you in the project root?"
[ ! -f "${DOCKER_DIR}/Dockerfile" ] && die "Dockerfile not found inside docker/."

# Check if Docker is running
docker info >/dev/null 2>&1 || die "Docker is not running. Start Docker and try again."

echo -e "${B}"
echo "  ╔══════════════════════════════════════╗"
echo "  ║       1proxy2Xvpn — Image Build      ║"
echo "  ╚══════════════════════════════════════╝"
echo -e "${N}"

log "Building image '${IMAGE}' from ${DOCKER_DIR}..."
log "This may take a few minutes on the first run..."
echo ""

docker build \
    --no-cache \
    -t "${IMAGE}" \
    -f "${DOCKER_DIR}/Dockerfile" \
    "${DOCKER_DIR}"

if [ $? -eq 0 ]; then
    SIZE=$(docker image inspect "${IMAGE}" --format='{{.Size}}' | awk '{printf "%.0f MB", $1/1024/1024}')
    echo ""
    log "✓ Image '${IMAGE}' built successfully! (${SIZE})"
    log ""
    log "Next step → run: ./2-start_containers.sh"
else
    echo ""
    die "Build failed. Check the output above for errors."
fi
