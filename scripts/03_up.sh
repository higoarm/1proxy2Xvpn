#!/bin/bash
# =============================================================================
# 03_up.sh — Start containers from .ovpn files
# Hardened: no --privileged, minimal capabilities, secrets isolated per-container
# =============================================================================
set -e

PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
# shellcheck source=lib_common.sh
. "${PROJECT_ROOT}/scripts/lib_common.sh"

require_docker
require_image
print_banner

# ── Args ──────────────────────────────────────────────────────────────────────
BATCH_SIZE="${BATCH_SIZE:-10}"
BATCH_DELAY="${BATCH_DELAY:-5}"
ENABLE_SOCKS5="${ENABLE_SOCKS5:-true}"

# ── Validation ────────────────────────────────────────────────────────────────
[ ! -d "${OVPN_DIR}" ] && die "OVPN dir not found: ${OVPN_DIR}"

mapfile -t OVPN_FILES < <(list_ovpn_files)
TOTAL=${#OVPN_FILES[@]}
[ "${TOTAL}" -eq 0 ] && die "No .ovpn files in ${OVPN_DIR}"

# Detect host public IP for leak validation inside containers
HOST_IP=$(get_host_public_ip)
[ -n "${HOST_IP}" ] && log "Host public IP (for leak detection): ${HOST_IP}" \
    || warn "Could not determine host IP — leak validation disabled"

# ── Cleanup (scoped to project only) ─────────────────────────────────────────
section "Cleanup"
REMOVED=0

# Layer 1: containers from current image
BYIMAGE=$(docker ps -aq --filter "ancestor=${IMAGE}" 2>/dev/null)
if [ -n "${BYIMAGE}" ]; then
    docker rm -f ${BYIMAGE} >/dev/null 2>&1
    COUNT=$(echo "${BYIMAGE}" | wc -w)
    ok "Layer 1: removed ${COUNT} containers by image"
    REMOVED=$((REMOVED + COUNT))
fi

# Layer 2: orphaned containers (same names but different image — survives rebuild)
ORPHANED=0
for OVPN_PATH in "${OVPN_FILES[@]}"; do
    NAME=$(ovpn_to_container_name "${OVPN_PATH}")
    if docker inspect "${NAME}" >/dev/null 2>&1; then
        docker rm -f "${NAME}" >/dev/null 2>&1
        ORPHANED=$((ORPHANED + 1))
    fi
done
[ "${ORPHANED}" -gt 0 ] && ok "Layer 2: removed ${ORPHANED} orphaned containers" \
    && REMOVED=$((REMOVED + ORPHANED))

[ "${REMOVED}" -eq 0 ] && info "Clean start — no existing containers"

# ── Plan ──────────────────────────────────────────────────────────────────────
END_PORT=$((BASE_PORT + TOTAL - 1))
section "Execution plan"
echo "  Image          : ${IMAGE}"
echo "  OVPN dir       : ${OVPN_DIR}"
echo "  Total          : ${TOTAL} containers"
echo "  HTTP ports     : ${BASE_PORT} → ${END_PORT}"
if [ "${ENABLE_SOCKS5}" = "true" ]; then
    SOCKS_BASE=$((BASE_PORT + 10000))
    SOCKS_END=$((SOCKS_BASE + TOTAL - 1))
    echo "  SOCKS5 ports   : ${SOCKS_BASE} → ${SOCKS_END}"
fi
echo "  Batch          : ${BATCH_SIZE} containers / ${BATCH_DELAY}s pause"
echo "  Mode           : Hardened (no --privileged)"

# ── Pre-flight checks ─────────────────────────────────────────────────────────
section "Pre-flight checks"

# Check 1: TUN module / device must be present (often missing after reboot)
if [ ! -c /dev/net/tun ]; then
    warn "/dev/net/tun not found — attempting to load the module..."
    if sudo modprobe tun 2>/dev/null; then
        ok "tun module loaded"
    else
        die "Cannot load tun module. Run: sudo modprobe tun"
    fi
else
    ok "/dev/net/tun present"
fi

# Check 2: scan the HTTP port range for conflicts (e.g. Loki on :3100,
# Grafana on :3000). A single conflicting port aborts the first container.
CONFLICTS=$(ss -tln 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -un | \
    awk -v lo="${BASE_PORT}" -v hi="${END_PORT}" '$1>=lo && $1<=hi' | head -5)
if [ -n "${CONFLICTS}" ]; then
    warn "These ports in range ${BASE_PORT}-${END_PORT} are already in use:"
    echo "${CONFLICTS}" | sed 's/^/    :/' >&2
    warn "Containers on those ports will fail to start."
    warn "Fix: set a different BASE_PORT in .env (e.g. BASE_PORT=25000)"
    warn "Continuing anyway — conflicting containers will be reported below."
else
    ok "HTTP port range ${BASE_PORT}-${END_PORT} is free"
fi

# Check 3: file descriptor headroom for large deployments
FD_MAX=$(cat /proc/sys/fs/file-max 2>/dev/null || echo 0)
if [ "${TOTAL}" -gt 100 ] && [ "${FD_MAX}" -lt 1000000 ]; then
    warn "fs.file-max is ${FD_MAX}; for ${TOTAL} containers, 2097152+ is recommended."
    warn "Fix: sudo ./1proxy2xvpn setup   (applies kernel tuning)"
fi

# ── Start ─────────────────────────────────────────────────────────────────────
section "Starting containers"
STARTED=0; FAILED=0; FAILED_NAMES=()
PORT=${BASE_PORT}
BATCH_COUNT=0

for OVPN_PATH in "${OVPN_FILES[@]}"; do
    OVPN_FILE=$(basename "${OVPN_PATH}")
    NAME=$(ovpn_to_container_name "${OVPN_PATH}")
    SOCKS_PORT=$((PORT + 10000))

    # Look for matching auth file (per-VPN, isolated)
    # Note: many providers (PIA, NordVPN with bulk download) reference shared
    # files (CA certs, CRL, auth file) from within the .ovpn — these MUST be
    # mountable alongside the .ovpn. We mount the whole ovpns/ directory
    # read-only and pass the specific .ovpn filename as the command.
    AUTH_FLAG=""
    AUTH_NAME="${OVPN_FILE%.ovpn}.auth"
    if [ -f "${SECRETS_DIR}/${AUTH_NAME}" ]; then
        AUTH_FLAG="-v $(realpath "${SECRETS_DIR}/${AUTH_NAME}"):/ovpn/auth.txt:ro"
    fi

    # Build SOCKS port mapping conditionally
    SOCKS_MAP=""
    [ "${ENABLE_SOCKS5}" = "true" ] && SOCKS_MAP="-p ${SOCKS_PORT}:1080"

    # ── Hardened docker run ──────────────────────────────────────────────────
    # No --privileged: only the capabilities OpenVPN actually needs.
    # The ovpns/ dir is mounted read-only so .ovpn files can reference adjacent
    # files (piavpn.txt, ca.rsa.4096.crt, crl.rsa.4096.pem, etc.)
    # set +e around docker run: a single container failure must NOT abort the
    # whole batch — we capture the error and continue to the next .ovpn.
    set +e
    DOCKER_ERR=$(docker run -d \
        --name "${NAME}" \
        --restart=on-failure:10 \
        --cap-add=NET_ADMIN \
        --cap-add=NET_RAW \
        --security-opt=no-new-privileges \
        --device /dev/net/tun:/dev/net/tun \
        --sysctl net.ipv4.ip_forward=1 \
        --sysctl net.ipv4.conf.all.src_valid_mark=1 \
        --dns=1.1.1.1 --dns=8.8.8.8 \
        -p "${PORT}:3128" \
        ${SOCKS_MAP} \
        -v "$(realpath "${OVPN_DIR}")":/ovpn:ro \
        ${AUTH_FLAG} \
        -w /ovpn \
        -e HOST_IP="${HOST_IP}" \
        -e ENABLE_SOCKS5="${ENABLE_SOCKS5}" \
        --label "1proxy2xvpn.managed=true" \
        --label "1proxy2xvpn.ovpn=${OVPN_FILE}" \
        --label "1proxy2xvpn.http_port=${PORT}" \
        --label "1proxy2xvpn.socks_port=${SOCKS_PORT}" \
        --log-driver json-file \
        --log-opt max-size=10m --log-opt max-file=3 \
        "${IMAGE}" "${OVPN_FILE}" 2>&1 1>/dev/null)
    RUN_RC=$?
    set -e

    if [ "${RUN_RC}" -eq 0 ]; then
        ok "[${PORT}] ${NAME}"
        STARTED=$((STARTED + 1))
    else
        REASON=$(echo "${DOCKER_ERR}" | tail -1 | sed 's/.*Error response from daemon: //')
        fail "[${PORT}] ${NAME} — ${REASON}"
        FAILED=$((FAILED + 1))
        FAILED_NAMES+=("${NAME}")
    fi

    PORT=$((PORT + 1))
    BATCH_COUNT=$((BATCH_COUNT + 1))

    if [ $((BATCH_COUNT % BATCH_SIZE)) -eq 0 ] && [ "${BATCH_COUNT}" -lt "${TOTAL}" ]; then
        info "Batch of ${BATCH_SIZE} done — pausing ${BATCH_DELAY}s..."
        sleep "${BATCH_DELAY}"
    fi
done

# ── Results ───────────────────────────────────────────────────────────────────
section "Results"
echo "  Started: ${STARTED}/${TOTAL}"
[ "${FAILED}" -gt 0 ] && echo "  Failed : ${FAILED}"

echo
log "Containers are connecting to VPNs in the background (~30-60s typical)."
log "Check status: ./1proxy2xvpn status"
log "Generate HAProxy: sudo ./1proxy2xvpn haproxy --only-up"
