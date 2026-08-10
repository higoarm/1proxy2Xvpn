#!/bin/bash
# =============================================================================
# iptables_killswitch.sh — Full Kill Switch (DNS-leak-proof)
#
# Improvements over previous version:
#   - No outbound DNS allowed at the network layer (DNS goes via tun0 only).
#     Hostname resolution of the VPN server is done BEFORE this runs, by
#     the entrypoint, using a pre-resolved IP injected via /etc/hosts.
#   - Default DROP policy applied first; rules then added incrementally.
#   - All non-tun0 outbound is logged at LOG level (for forensic analysis).
# =============================================================================
set -euo pipefail

VPN_IP="${1:?VPN_IP required}"
VPN_PORT="${2:-1194}"
VPN_PROTO="${3:-udp}"

# Detect default network interface dynamically
DEFAULT_IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
DEFAULT_IFACE="${DEFAULT_IFACE:-eth0}"

log() { echo "[killswitch] $*"; }

log "Default iface: ${DEFAULT_IFACE} | VPN: ${VPN_IP}:${VPN_PORT}/${VPN_PROTO}"

# ── Reset chains ──────────────────────────────────────────────────────────────
iptables -F
iptables -X
iptables -Z
iptables -t nat    -F; iptables -t nat    -X
iptables -t mangle -F; iptables -t mangle -X

# ── Deny-by-default ───────────────────────────────────────────────────────────
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  DROP

# ── Loopback ──────────────────────────────────────────────────────────────────
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# ── Established connections ───────────────────────────────────────────────────
iptables -A INPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# ── VPN server reachability (single IP, no DNS) ───────────────────────────────
iptables -A OUTPUT -d "${VPN_IP}" -p "${VPN_PROTO}" --dport "${VPN_PORT}" -j ACCEPT
if [ "${VPN_PROTO}" = "udp" ]; then
    # TCP fallback (some providers support it for failover)
    iptables -A OUTPUT -d "${VPN_IP}" -p tcp --dport "${VPN_PORT}" -j ACCEPT 2>/dev/null || true
fi

# ── tun0 — full access (this is the VPN tunnel) ──────────────────────────────
iptables -A INPUT  -i tun0 -j ACCEPT
iptables -A OUTPUT -o tun0 -j ACCEPT

# ── Proxy ports (incoming from host network) ─────────────────────────────────
iptables -A INPUT -p tcp --dport 3128 -j ACCEPT    # tinyproxy (HTTP)
iptables -A INPUT -p tcp --dport 1080 -j ACCEPT    # dante-server (SOCKS5)

# ── NAT through tun0 ─────────────────────────────────────────────────────────
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE

# ── Forwarding from proxy to VPN ─────────────────────────────────────────────
iptables -A FORWARD -i "${DEFAULT_IFACE}" -o tun0 -j ACCEPT
iptables -A FORWARD -i tun0 -o "${DEFAULT_IFACE}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# ── Log dropped outbound (forensic, rate-limited to avoid spam) ──────────────
iptables -A OUTPUT -o "${DEFAULT_IFACE}" -m limit --limit 1/min --limit-burst 5 \
    -j LOG --log-prefix "[killswitch-drop] " --log-level 4 2>/dev/null || true

log "Kill Switch ACTIVE"
log "  Outbound ${DEFAULT_IFACE}: DENIED (no DNS, no fallback)"
log "  Outbound tun0           : ALLOWED"
log "  VPN handshake to ${VPN_IP}:${VPN_PORT}/${VPN_PROTO}: ALLOWED"
log "  Inbound :3128 (HTTP) / :1080 (SOCKS5): ALLOWED"
