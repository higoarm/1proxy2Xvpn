#!/bin/bash
# =============================================================================
# 2-start_containers.sh — Start one container per .ovpn file in ./ovpns/
# Run this AFTER 1-build.sh.
#
# Usage:
#   ./2-start_containers.sh                   # uses ./ovpns/, ports from 3100
#   ./2-start_containers.sh ./ovpns 4000      # custom folder and start port
# =============================================================================

OVPN_DIR="${1:-./ovpns}"
BASE_PORT="${2:-3100}"
IMAGE="1proxy2xvpn"
BATCH_SIZE=10
BATCH_DELAY=5

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; B='\033[1;34m'; N='\033[0m'
log()     { echo -e "${G}[start]${N} $*"; }
warn()    { echo -e "${Y}[start][WARN]${N} $*"; }
error()   { echo -e "${R}[start][ERROR]${N} $*"; }
section() { echo -e "\n${B}━━━ $* ━━━${N}"; }

# ── Validation ────────────────────────────────────────────────────────────────
[ ! -d "${OVPN_DIR}" ] && { error "Directory '${OVPN_DIR}' not found."; exit 1; }

mapfile -t OVPN_FILES < <(ls "${OVPN_DIR}"/*.ovpn 2>/dev/null | sort)
TOTAL=${#OVPN_FILES[@]}
[ ${TOTAL} -eq 0 ] && { error "No .ovpn files found in '${OVPN_DIR}'."; exit 1; }

if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    error "Image '${IMAGE}' not found. Run ./1-build.sh first."
    exit 1
fi

# ── Cleanup — 3-layer approach ────────────────────────────────────────────────
# Layer 1: by image ancestor (current image)
# Layer 2: by container name derived from .ovpn files (catches orphaned/rebuilt)
# Layer 3: by port range (catches containers from any image using same ports)
# This guarantees zero "name already in use" or "port already allocated" errors.
section "Cleanup"
REMOVED=0

# Layer 1 — containers from current image (including stopped/exited)
log "Layer 1: removing containers from image '${IMAGE}'..."
BYIMAGE=$(docker ps -aq --filter "ancestor=${IMAGE}" 2>/dev/null)
if [ -n "${BYIMAGE}" ]; then
    docker rm -f ${BYIMAGE} >/dev/null 2>&1
    COUNT=$(echo "${BYIMAGE}" | wc -w)
    log "  Removed ${COUNT} container(s) by image."
    REMOVED=$((REMOVED + COUNT))
fi

# Layer 2 — containers whose name matches our .ovpn filenames
# (survives image rebuilds — old containers keep the name but lose ancestor link)
log "Layer 2: removing containers by name (orphaned after image rebuild)..."
for OVPN_PATH in "${OVPN_FILES[@]}"; do
    OVPN_FILE=$(basename "${OVPN_PATH}")
    CONTAINER_NAME=$(echo "${OVPN_FILE%.ovpn}" | tr '.' '-')
    if docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
        docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1
        log "  Removed orphaned: ${CONTAINER_NAME}"
        REMOVED=$((REMOVED + 1))
    fi
done

# Layer 3 — containers occupying ports in our range
log "Layer 3: freeing ports ${BASE_PORT}→$((BASE_PORT + TOTAL - 1))..."
END_PORT=$((BASE_PORT + TOTAL - 1))
BYPORT=$(docker ps -aq --filter "publish=${BASE_PORT}-${END_PORT}" 2>/dev/null)
if [ -n "${BYPORT}" ]; then
    docker rm -f ${BYPORT} >/dev/null 2>&1
    COUNT=$(echo "${BYPORT}" | wc -w)
    log "  Removed ${COUNT} container(s) by port range."
    REMOVED=$((REMOVED + COUNT))
fi

if [ ${REMOVED} -eq 0 ]; then
    log "No existing containers found. Clean start."
else
    log "✓ Cleanup complete. Total removed: ${REMOVED} container(s)."
fi

# ── Summary ───────────────────────────────────────────────────────────────────
section "Execution plan"
log "Image        : ${IMAGE}"
log "OVPN folder  : ${OVPN_DIR}"
log "Total        : ${TOTAL} containers"
log "Port range   : ${BASE_PORT} → $((BASE_PORT + TOTAL - 1))"
log "Batch size   : ${BATCH_SIZE} containers / ${BATCH_DELAY}s pause"
echo ""

# ── Start containers ──────────────────────────────────────────────────────────
section "Starting containers"
STARTED=0; FAILED=0; FAILED_NAMES=()
PORT=${BASE_PORT}; BATCH_COUNT=0

for OVPN_PATH in "${OVPN_FILES[@]}"; do
    OVPN_FILE=$(basename "${OVPN_PATH}")
    CONTAINER_NAME=$(echo "${OVPN_FILE%.ovpn}" | tr '.' '-')

    # Capture stderr to show the real error reason if it fails
    DOCKER_ERR=$(docker run -d \
        --privileged \
        --cap-add=NET_ADMIN \
        --device /dev/net/tun:/dev/net/tun \
        --dns=1.1.1.1 --dns=8.8.8.8 \
        -p "${PORT}:3128" \
        -v "$(realpath ${OVPN_DIR}):/ovpn:ro" \
        -w /ovpn \
        --name "${CONTAINER_NAME}" \
        --restart=unless-stopped \
        "${IMAGE}" openvpn "${OVPN_FILE}" 2>&1 >/dev/null)

    if [ $? -eq 0 ]; then
        log "✓ [${PORT}] ${CONTAINER_NAME}"
        STARTED=$((STARTED+1))
    else
        # Show the real Docker error reason
        REASON=$(echo "${DOCKER_ERR}" | tail -1 | sed 's/.*Error response from daemon: //')
        error "✗ [${PORT}] ${CONTAINER_NAME}"
        error "     Reason: ${REASON}"
        FAILED=$((FAILED+1))
        FAILED_NAMES+=("${CONTAINER_NAME}|${REASON}")
    fi

    PORT=$((PORT+1)); BATCH_COUNT=$((BATCH_COUNT+1))

    if [ $((BATCH_COUNT % BATCH_SIZE)) -eq 0 ] && [ ${BATCH_COUNT} -lt ${TOTAL} ]; then
        log "--- Batch of ${BATCH_SIZE} done. Waiting ${BATCH_DELAY}s... ---"
        sleep ${BATCH_DELAY}
    fi
done

# ── Results ───────────────────────────────────────────────────────────────────
section "Results"
log "Started : ${STARTED}/${TOTAL}"
if [ ${FAILED} -gt 0 ]; then
    warn "Failed  : ${FAILED}"
    echo ""
    warn "Failed containers and reasons:"
    for entry in "${FAILED_NAMES[@]}"; do
        NAME="${entry%%|*}"
        REASON="${entry##*|}"
        warn "  ✗ ${NAME}"
        warn "    → ${REASON}"
    done
    echo ""
    warn "To investigate a specific failure:"
    warn "  docker logs <container-name>"
fi

echo ""
log "Waiting 15s for VPNs to connect..."
sleep 15

# ── Connectivity spot check ───────────────────────────────────────────────────
section "Connectivity check (first 5)"
CHECKED=0; PORT=${BASE_PORT}
for OVPN_PATH in "${OVPN_FILES[@]}"; do
    [ ${CHECKED} -ge 5 ] && break
    OVPN_FILE=$(basename "${OVPN_PATH}")
    NAME=$(echo "${OVPN_FILE%.ovpn}" | tr '.' '-')
    STATUS=$(docker inspect --format='{{.State.Status}}' "${NAME}" 2>/dev/null || echo "not found")
    if [ "${STATUS}" = "running" ]; then
        IP=$(curl -sf --max-time 5 -x "http://localhost:${PORT}" https://ifconfig.me 2>/dev/null || echo "connecting...")
        log "  :${PORT} ${NAME} → ${IP}"
    else
        warn "  :${PORT} ${NAME} → ${STATUS}"
    fi
    PORT=$((PORT+1)); CHECKED=$((CHECKED+1))
done

echo ""
log "Next step → run: sudo ./3-generate_haproxy.sh"
log "Check status  → run: ./4-status_proxies.sh"
