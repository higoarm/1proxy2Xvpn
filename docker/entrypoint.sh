#!/bin/bash
# =============================================================================
# entrypoint.sh — Orchestrates OpenVPN + tinyproxy with Kill Switch
# This script runs INSIDE the container at startup.
# =============================================================================
set -Ee

# Argument parsing — accepts: "openvpn config.ovpn"  or  "config.ovpn"
if [ "${1}" = "openvpn" ]; then
    shift
    OVPN_FILE=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --config) shift; OVPN_FILE="$1"; break ;;
            --*)      shift; [ $# -gt 0 ] && shift ;;
            *)        OVPN_FILE="$1"; break ;;
        esac
    done
    OVPN_FILE="${OVPN_FILE:-config.ovpn}"
else
    OVPN_FILE="${1:-config.ovpn}"
fi

PROXY_CONF="/etc/tinyproxy/tinyproxy.conf"
OPENVPN_LOG="/var/log/openvpn.log"
OPENVPN_PID="/var/run/openvpn.pid"
TINYPROXY_PID="/var/run/tinyproxy/tinyproxy.pid"
TUN_WAIT_TIMEOUT=90
MONITOR_INTERVAL=5

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
log()  { echo -e "${G}[1proxy2Xvpn]${N} $*"; }
warn() { echo -e "${Y}[1proxy2Xvpn][WARN]${N} $*"; }
die()  { echo -e "${R}[1proxy2Xvpn][ERROR]${N} $*" >&2; exit 1; }

# 1. Validate .ovpn file
log "Starting 1proxy2Xvpn..."
log "OpenVPN file: ${OVPN_FILE}"
[ ! -f "${OVPN_FILE}" ] && die "File '${OVPN_FILE}' not found. Mount with: -v ./ovpns:/ovpn -w /ovpn"

# 2. Kernel settings
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || warn "ip_forward failed, continuing..."

# 3. Parse VPN server from .ovpn
VPN_REMOTE=$(grep -m1 '^remote ' "${OVPN_FILE}" | awk '{print $2}')
VPN_PORT=$(  grep -m1 '^remote ' "${OVPN_FILE}" | awk '{print $3}')
VPN_PROTO=$( grep -m1 '^proto '  "${OVPN_FILE}" | awk '{print $2}' 2>/dev/null || echo "udp")
VPN_PROTO=$(echo "${VPN_PROTO}" | sed 's/-client//;s/6$//')
[ -z "${VPN_REMOTE}" ] && die "'remote' directive not found in ${OVPN_FILE}"
[ -z "${VPN_PORT}" ]   && VPN_PORT="1194"
log "VPN server: ${VPN_REMOTE}:${VPN_PORT} (${VPN_PROTO})"

VPN_IP=$(getent hosts "${VPN_REMOTE}" 2>/dev/null | awk '{print $1}' | head -1)
[ -z "${VPN_IP}" ] && VPN_IP="${VPN_REMOTE}" && warn "DNS resolution failed, using hostname directly."
log "VPN server IP: ${VPN_IP}"

# 4. Apply Kill Switch
log "Applying Kill Switch..."
/usr/local/bin/iptables_killswitch.sh "${VPN_IP}" "${VPN_PORT}" "${VPN_PROTO}" \
    || die "Kill Switch failed."

# 5. Start OpenVPN
log "Starting OpenVPN..."
touch "${OPENVPN_LOG}"
openvpn \
    --config "${OVPN_FILE}" \
    --writepid "${OPENVPN_PID}" \
    --log "${OPENVPN_LOG}" \
    --script-security 2 \
    --connect-retry 5 30 \
    --connect-retry-max 20 \
    --resolv-retry infinite \
    --ping 10 \
    --ping-restart 60 \
    --daemon openvpn
log "OpenVPN daemonized."

# 6. Wait for tun0
log "Waiting for tun0 interface (max ${TUN_WAIT_TIMEOUT}s)..."
elapsed=0
while ! ip link show tun0 >/dev/null 2>&1; do
    sleep 1; elapsed=$((elapsed+1))
    [ $((elapsed % 10)) -eq 0 ] && log "  ...waiting for tun0 (${elapsed}s)"
    if [ ${elapsed} -ge ${TUN_WAIT_TIMEOUT} ]; then
        warn "=== OPENVPN LOG ==="; tail -50 "${OPENVPN_LOG}" >&2
        die "Timeout: tun0 did not appear after ${TUN_WAIT_TIMEOUT}s"
    fi
done
log "tun0 is UP!"
ip addr show tun0 | awk '/inet /{print "[1proxy2Xvpn] tun0 IP: " $2}'

# 7. Configure routing via tun0
log "Configuring routing through tun0..."
DEFAULT_GW=$(ip route show default | awk 'NR==1{print $3}')
DEFAULT_IF=$(ip route show default | awk 'NR==1{print $5}')
[ -n "${DEFAULT_GW}" ] && [ -n "${VPN_IP}" ] && \
    ip route replace "${VPN_IP}/32" via "${DEFAULT_GW}" dev "${DEFAULT_IF}" 2>/dev/null || true
ip route add    default dev tun0 metric 10 2>/dev/null || \
ip route replace default dev tun0 metric 10 2>/dev/null || true
log "Routing table:"; ip route show | while read -r l; do log "  ${l}"; done

# 8. Verify public IP via VPN
log "Checking public IP via VPN..."
PUBLIC_IP="N/A"
for i in 1 2 3 4; do
    IP=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null || \
         curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || true)
    [ -n "${IP}" ] && PUBLIC_IP="${IP}" && break
    sleep 5
done
log "Public IP via VPN: ${PUBLIC_IP}"

# 9. Start tinyproxy
log "Starting tinyproxy..."
mkdir -p /var/run/tinyproxy
chown nobody:nogroup /var/run/tinyproxy 2>/dev/null || \
chown nobody /var/run/tinyproxy 2>/dev/null || true
tinyproxy -c "${PROXY_CONF}"
sleep 2
if [ -f "${TINYPROXY_PID}" ] && kill -0 "$(cat ${TINYPROXY_PID})" 2>/dev/null; then
    log "tinyproxy started (PID=$(cat ${TINYPROXY_PID}))"
else
    die "tinyproxy failed to start."
fi

# 10. Signal handler
cleanup() {
    log "Shutting down services..."
    [ -f "${TINYPROXY_PID}" ] && kill "$(cat ${TINYPROXY_PID})" 2>/dev/null || true
    [ -f "${OPENVPN_PID}" ]   && kill "$(cat ${OPENVPN_PID})"   2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT SIGHUP

log "=================================================="
log "  PROXY ACTIVE  →  0.0.0.0:3128 (tinyproxy)"
log "  VPN IP        →  ${PUBLIC_IP}"
log "=================================================="

# 11. Monitoring loop
while true; do
    sleep ${MONITOR_INTERVAL}
    if [ ! -f "${TINYPROXY_PID}" ] || ! kill -0 "$(cat ${TINYPROXY_PID} 2>/dev/null)" 2>/dev/null; then
        warn "tinyproxy died. Restarting..."
        tinyproxy -c "${PROXY_CONF}"; sleep 2
        kill -0 "$(cat ${TINYPROXY_PID} 2>/dev/null)" 2>/dev/null && log "tinyproxy restarted." || warn "tinyproxy failed again."
    fi
    OVPN_PID_VAL=""
    [ -f "${OPENVPN_PID}" ] && OVPN_PID_VAL=$(cat "${OPENVPN_PID}" 2>/dev/null)
    if [ -z "${OVPN_PID_VAL}" ] || ! kill -0 "${OVPN_PID_VAL}" 2>/dev/null; then
        warn "OpenVPN died! Kill Switch active — all traffic blocked."
        /usr/local/bin/iptables_killswitch.sh "${VPN_IP}" "${VPN_PORT}" "${VPN_PROTO}" 2>/dev/null || true
    fi
done
