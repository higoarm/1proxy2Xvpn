#!/bin/bash
# =============================================================================
# iptables_killswitch.sh — Full Kill Switch via iptables
# This script runs INSIDE the container at startup.
# =============================================================================
set -e

VPN_IP="${1}"
VPN_PORT="${2:-1194}"
VPN_PROTO="${3:-udp}"

DEFAULT_IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -1)
DEFAULT_IFACE="${DEFAULT_IFACE:-eth0}"

log() { echo "[killswitch] $*"; }

log "Default interface: ${DEFAULT_IFACE}"
log "VPN server: ${VPN_IP}:${VPN_PORT}/${VPN_PROTO}"

# Flush all existing rules
iptables -F; iptables -X; iptables -Z
iptables -t nat    -F; iptables -t nat    -X
iptables -t mangle -F; iptables -t mangle -X

# Default policies: DROP everything
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  DROP
log "Default policies: DROP."

# Loopback
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Established/related connections
iptables -A INPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# DNS bootstrap — needed to resolve VPN hostname before tun0 exists
log "Allowing DNS bootstrap (1.1.1.1, 8.8.8.8)..."
for DNS_IP in 1.1.1.1 8.8.8.8 1.0.0.1 8.8.4.4; do
    iptables -A OUTPUT -d "${DNS_IP}" -p udp --dport 53 -j ACCEPT
    iptables -A OUTPUT -d "${DNS_IP}" -p tcp --dport 53 -j ACCEPT
done

# Allow outbound to VPN server
if [ -n "${VPN_IP}" ] && [ -n "${VPN_PORT}" ]; then
    log "Allowing outbound to ${VPN_IP}:${VPN_PORT}/${VPN_PROTO}..."
    iptables -A OUTPUT -d "${VPN_IP}" -p "${VPN_PROTO}" --dport "${VPN_PORT}" -j ACCEPT
    [ "${VPN_PROTO}" = "udp" ] && \
        iptables -A OUTPUT -d "${VPN_IP}" -p tcp --dport "${VPN_PORT}" -j ACCEPT 2>/dev/null || true
fi

# Allow all traffic through tun0
iptables -A INPUT  -i tun0 -j ACCEPT
iptables -A OUTPUT -o tun0 -j ACCEPT

# tinyproxy: accept incoming on port 3128
iptables -A INPUT -p tcp --dport 3128 -j ACCEPT

# NAT: masquerade outbound through tun0
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE

# Forward: proxy → tun0
iptables -A FORWARD -i "${DEFAULT_IFACE}" -o tun0 -j ACCEPT
iptables -A FORWARD -i tun0 -o "${DEFAULT_IFACE}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

log "Kill Switch ACTIVE."
log "  Outbound ${DEFAULT_IFACE}: BLOCKED"
log "  tun0 (VPN): ALLOWED"
log "  DNS bootstrap: ALLOWED"
log "  Port 3128 (tinyproxy): OPEN"
