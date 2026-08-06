#!/bin/bash
# =============================================================================
# entrypoint.sh — Container orchestrator (hardened)
#
# Boot order (each step fail-fast):
#   1. Apply baseline iptables DROP (closes boot-window leak)
#   2. Parse .ovpn → extract server hostname, port, proto
#   3. Pre-resolve hostname → IP (only once, via host DNS) → /etc/hosts
#   4. Apply full Kill Switch (locks DNS bootstrap path)
#   5. Inject DNS leak prevention via CLI args (redirect-gateway)
#   6. Launch OpenVPN
#   7. Wait for tun0 + validate exit IP
#   8. Launch tinyproxy (HTTP) and dante (SOCKS5)
#   9. Monitor loop
# =============================================================================
set -Eeo pipefail

# ── Argument parsing ──────────────────────────────────────────────────────────
if [ "${1:-}" = "openvpn" ]; then
    shift
    OVPN_FILE=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --config) shift; OVPN_FILE="${1:-}"; break ;;
            --*)      shift; [ $# -gt 0 ] && shift ;;
            *)        OVPN_FILE="$1"; break ;;
        esac
    done
    OVPN_FILE="${OVPN_FILE:-config.ovpn}"
else
    OVPN_FILE="${1:-config.ovpn}"
fi

# ── Constants ─────────────────────────────────────────────────────────────────
PROXY_HTTP_CONF="/etc/tinyproxy/tinyproxy.conf"
PROXY_SOCKS_CONF="/etc/dante/danted.conf"
OPENVPN_LOG="/var/log/1proxy2xvpn/openvpn.log"
OPENVPN_PID="/var/run/openvpn.pid"
TINYPROXY_PID="/var/run/tinyproxy/tinyproxy.pid"
TUN_WAIT_TIMEOUT="${TUN_WAIT_TIMEOUT:-90}"
# Monitor loop interval: 30s is plenty for detecting a dead process. At 285
# containers, a 5s interval means 285 bash loops waking 12×/min for no reason.
MONITOR_INTERVAL="${MONITOR_INTERVAL:-30}"
# SOCKS5 is opt-in: most workloads use the HTTP proxy. Running dante in every
# container wastes ~3MB RAM + a process slot per container (×285 = real cost).
# Set ENABLE_SOCKS5=true to turn it on.
ENABLE_SOCKS5="${ENABLE_SOCKS5:-false}"

# ── Colored logging ───────────────────────────────────────────────────────────
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
log()  { echo -e "${G}[1proxy2Xvpn]${N} $*"; }
warn() { echo -e "${Y}[1proxy2Xvpn][WARN]${N} $*"; }
die()  { echo -e "${R}[1proxy2Xvpn][ERROR]${N} $*" >&2; exit 1; }

# ── Step 0: Apply baseline DROP before doing anything else ───────────────────
log "Applying baseline iptables (deny-by-default)..."
if [ -f /etc/1proxy2xvpn/baseline.rules ]; then
    iptables-restore < /etc/1proxy2xvpn/baseline.rules || warn "baseline.rules apply failed"
fi

# ── Step 1: Validate input ────────────────────────────────────────────────────
log "Starting 1proxy2Xvpn"
log "OpenVPN config: ${OVPN_FILE}"
[ ! -f "${OVPN_FILE}" ] && die "Config file not found: ${OVPN_FILE}"

# ── Step 2: Sysctl ────────────────────────────────────────────────────────────
# Already set via docker --sysctl flag; retry from inside the container only
# if not already set (avoids cosmetic warning when capabilities don't allow it).
if [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" != "1" ]; then
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || warn "ip_forward sysctl failed"
fi

# ── Step 3: Parse .ovpn ───────────────────────────────────────────────────────
VPN_REMOTE=$(grep -m1 '^remote ' "${OVPN_FILE}" | awk '{print $2}')
VPN_PORT=$(  grep -m1 '^remote ' "${OVPN_FILE}" | awk '{print $3}')
VPN_PROTO=$( grep -m1 '^proto '  "${OVPN_FILE}" | awk '{print $2}' 2>/dev/null || echo "udp")
VPN_PROTO=$(echo "${VPN_PROTO}" | sed 's/-client//;s/6$//')
[ -z "${VPN_REMOTE}" ] && die "'remote' directive missing in ${OVPN_FILE}"
[ -z "${VPN_PORT}" ]   && VPN_PORT="1194"
log "VPN target: ${VPN_REMOTE}:${VPN_PORT}/${VPN_PROTO}"

# ── Step 4: Resolve hostname (must use host's DNS BEFORE killswitch) ──────────
log "Resolving VPN hostname (DNS bootstrap)..."
VPN_IP=""

# Try 1: getent (uses /etc/nsswitch.conf → /etc/resolv.conf)
VPN_IP=$(timeout 5 getent hosts "${VPN_REMOTE}" 2>/dev/null | awk '{print $1; exit}' || true)

# Try 2: dig with explicit nameserver
if [ -z "${VPN_IP}" ]; then
    warn "getent failed, trying dig..."
    VPN_IP=$(timeout 5 dig +short +time=2 +tries=2 "${VPN_REMOTE}" @1.1.1.1 2>/dev/null | head -1 || true)
fi

# Try 3: nslookup as last resort
if [ -z "${VPN_IP}" ]; then
    warn "dig failed, trying nslookup..."
    VPN_IP=$(timeout 5 nslookup "${VPN_REMOTE}" 1.1.1.1 2>/dev/null | awk '/^Address: / {print $2; exit}' || true)
fi

if [ -z "${VPN_IP}" ]; then
    warn "All DNS resolution methods failed for ${VPN_REMOTE}"
    warn "Container DNS config:"
    cat /etc/resolv.conf | sed 's/^/  /' >&2
    die "Cannot resolve VPN server hostname. Check container DNS connectivity."
fi
log "Resolved: ${VPN_REMOTE} → ${VPN_IP}"

# Pin the hostname → IP mapping in /etc/hosts
echo "${VPN_IP} ${VPN_REMOTE}" >> /etc/hosts

# ── Step 5: Apply full Kill Switch ────────────────────────────────────────────
log "Applying full Kill Switch..."
/usr/local/bin/iptables_killswitch.sh "${VPN_IP}" "${VPN_PORT}" "${VPN_PROTO}" \
    || die "Kill Switch application failed"

# ── Step 6: Build OpenVPN command-line directives (cross-platform safe) ───────
# We do NOT modify the .ovpn file (avoids breaking relative path references
# like `ca ca.rsa.4096.crt` and `auth-user-pass piavpn.txt`, which are
# critical for PIA-style multi-file configs).
# Instead, we inject directives via command-line flags, which take precedence
# over the config file and work cross-platform.
OPENVPN_EXTRA=()

# Force ALL traffic through the tunnel (DNS leak prevention).
# Only inject if the .ovpn doesn't already specify a redirect-gateway mode.
if ! grep -q '^redirect-gateway' "${OVPN_FILE}"; then
    OPENVPN_EXTRA+=(--redirect-gateway def1 bypass-dhcp)
fi

# NOTE: We intentionally do NOT inject `block-outside-dns` — it is a
# Windows-only directive that OpenVPN 2.6+ rejects on Linux. DNS leak
# prevention on Linux is achieved by:
#   1. redirect-gateway def1 (forces all routes through tun0)
#   2. iptables Kill Switch (blocks DNS on eth0)
#   3. /etc/hosts pinning for the VPN server itself

# ── Step 7: Launch OpenVPN ────────────────────────────────────────────────────
log "Launching OpenVPN..."
touch "${OPENVPN_LOG}"
openvpn \
    --config "${OVPN_FILE}" \
    "${OPENVPN_EXTRA[@]}" \
    --writepid "${OPENVPN_PID}" \
    --log "${OPENVPN_LOG}" \
    --script-security 2 \
    --connect-retry 5 30 \
    --connect-retry-max 20 \
    --resolv-retry infinite \
    --ping 10 \
    --ping-restart 60 \
    --mute-replay-warnings \
    --daemon openvpn

# ── Step 8: Wait for tun0 ─────────────────────────────────────────────────────
log "Waiting for tun0 (timeout: ${TUN_WAIT_TIMEOUT}s)..."
elapsed=0
while ! ip link show tun0 >/dev/null 2>&1; do
    sleep 1; elapsed=$((elapsed+1))
    [ $((elapsed % 10)) -eq 0 ] && log "  ...waiting tun0 (${elapsed}s)"
    if [ "${elapsed}" -ge "${TUN_WAIT_TIMEOUT}" ]; then
        warn "=== OPENVPN LOG ==="; tail -50 "${OPENVPN_LOG}" >&2
        die "Timeout: tun0 not up after ${TUN_WAIT_TIMEOUT}s"
    fi
done
log "tun0 UP"
ip addr show tun0 | awk '/inet /{print "[1proxy2Xvpn] tun0 IP: " $2}'

# ── Step 9: Force routing through tun0 ────────────────────────────────────────
DEFAULT_GW=$(ip route show default | awk 'NR==1{print $3}')
DEFAULT_IF=$(ip route show default | awk 'NR==1{print $5}')
if [ -n "${DEFAULT_GW}" ] && [ -n "${VPN_IP}" ]; then
    ip route replace "${VPN_IP}/32" via "${DEFAULT_GW}" dev "${DEFAULT_IF}" 2>/dev/null || true
fi
ip route replace default dev tun0 metric 10 2>/dev/null || \
ip route add     default dev tun0 metric 10 2>/dev/null || true

# ── Step 10: Validate exit IP (anti-leak verification) ───────────────────────
log "Validating exit IP..."
PUBLIC_IP="unknown"
for attempt in 1 2 3 4 5; do
    IP=$(curl -sf --max-time 5 --interface tun0 https://api.ipify.org 2>/dev/null || \
         curl -sf --max-time 5 --interface tun0 https://ifconfig.me 2>/dev/null || true)
    if [[ "${IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        PUBLIC_IP="${IP}"; break
    fi
    sleep 3
done

if [ "${PUBLIC_IP}" = "unknown" ]; then
    warn "Could not validate exit IP — VPN may still work, but cannot confirm"
elif [ -n "${HOST_IP:-}" ] && [ "${PUBLIC_IP}" = "${HOST_IP}" ]; then
    die "CRITICAL LEAK: exit IP == host IP (${PUBLIC_IP}). Killing container."
else
    log "Validated exit IP: ${PUBLIC_IP}"
fi

echo "${PUBLIC_IP}" > /var/run/1proxy2xvpn.exitip 2>/dev/null || true

# ── Step 11: Start tinyproxy (HTTP) ───────────────────────────────────────────
log "Starting tinyproxy on :3128..."
mkdir -p /var/run/tinyproxy
chown -R nobody:nogroup /var/run/tinyproxy 2>/dev/null || \
chown -R nobody /var/run/tinyproxy 2>/dev/null || true
tinyproxy -c "${PROXY_HTTP_CONF}"
sleep 2
if [ -f "${TINYPROXY_PID}" ] && kill -0 "$(cat ${TINYPROXY_PID})" 2>/dev/null; then
    log "tinyproxy UP (PID=$(cat ${TINYPROXY_PID}))"
else
    die "tinyproxy failed to start"
fi

# ── Step 12: Optionally start dante (SOCKS5) ──────────────────────────────────
SOCKS_PID=""
if [ "${ENABLE_SOCKS5}" = "true" ]; then
    log "Starting dante SOCKS5 on :1080..."
    # Run dante in FOREGROUND (no -D daemon mode) and let the shell put it
    # in the background. This way $! captures the actual long-running PID,
    # not the parent that exits after daemonization.
    danted -f "${PROXY_SOCKS_CONF}" >/var/log/1proxy2xvpn/dante.log 2>&1 &
    SOCKS_PID=$!
    sleep 2
    if kill -0 "${SOCKS_PID}" 2>/dev/null; then
        log "dante UP (PID=${SOCKS_PID})"
    else
        warn "dante failed to start. Last log lines:"
        tail -5 /var/log/1proxy2xvpn/dante.log 2>/dev/null | sed 's/^/  /' >&2
        warn "(SOCKS5 unavailable, HTTP still works)"
        SOCKS_PID=""
    fi
fi

# ── Signal handling ───────────────────────────────────────────────────────────
cleanup() {
    log "Shutting down..."
    [ -f "${TINYPROXY_PID}" ] && kill "$(cat ${TINYPROXY_PID})" 2>/dev/null || true
    [ -n "${SOCKS_PID}" ] && kill "${SOCKS_PID}" 2>/dev/null || true
    [ -f "${OPENVPN_PID}" ] && kill "$(cat ${OPENVPN_PID})" 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT SIGHUP

# ── Status banner ─────────────────────────────────────────────────────────────
log "═══════════════════════════════════════════════════════════"
log "  PROXY READY"
log "  HTTP   : 0.0.0.0:3128"
[ -n "${SOCKS_PID}" ] && log "  SOCKS5 : 0.0.0.0:1080"
log "  VPN IP : ${PUBLIC_IP}"
log "  Server : ${VPN_REMOTE} (${VPN_PROTO})"
log "═══════════════════════════════════════════════════════════"

# ── Monitor loop ──────────────────────────────────────────────────────────────
while true; do
    sleep "${MONITOR_INTERVAL}"

    # tinyproxy
    if [ ! -f "${TINYPROXY_PID}" ] || ! kill -0 "$(cat ${TINYPROXY_PID} 2>/dev/null)" 2>/dev/null; then
        warn "tinyproxy died, restarting..."
        tinyproxy -c "${PROXY_HTTP_CONF}"
    fi

    # dante (only if it was successfully started)
    if [ -n "${SOCKS_PID}" ] && ! kill -0 "${SOCKS_PID}" 2>/dev/null; then
        warn "dante died, restarting..."
        danted -f "${PROXY_SOCKS_CONF}" >>/var/log/1proxy2xvpn/dante.log 2>&1 &
        SOCKS_PID=$!
    fi

    # OpenVPN
    OVPN_PID_VAL=""
    [ -f "${OPENVPN_PID}" ] && OVPN_PID_VAL=$(cat "${OPENVPN_PID}" 2>/dev/null)
    if [ -z "${OVPN_PID_VAL}" ] || ! kill -0 "${OVPN_PID_VAL}" 2>/dev/null; then
        warn "OpenVPN died, Kill Switch is active — no traffic leaks."
        /usr/local/bin/iptables_killswitch.sh "${VPN_IP}" "${VPN_PORT}" "${VPN_PROTO}" 2>/dev/null || true
    fi
done
