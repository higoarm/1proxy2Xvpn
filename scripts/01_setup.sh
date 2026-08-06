#!/bin/bash
# =============================================================================
# 01_setup.sh — Host pre-flight: install dependencies, tune kernel, validate
# Idempotent: safe to run multiple times.
# =============================================================================
set -e

PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
# shellcheck source=lib_common.sh
. "${PROJECT_ROOT}/scripts/lib_common.sh"

[ "$(id -u)" -eq 0 ] || die "Setup requires root: sudo 1proxy2xvpn setup"

print_banner
section "Host pre-flight"

# ── Detect OS ─────────────────────────────────────────────────────────────────
if [ -f /etc/os-release ]; then . /etc/os-release; OS_ID="${ID:-unknown}"; else OS_ID="unknown"; fi
log "Detected OS: ${OS_ID}"

# ── Install dependencies ──────────────────────────────────────────────────────
install_apt() {
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        docker.io docker-compose-plugin \
        haproxy curl jq openssl iproute2 ca-certificates \
        2>&1 | grep -v "^Reading\|^Building\|^Suggested" || true
}

install_dnf() {
    dnf install -y -q docker docker-compose haproxy curl jq openssl iproute
}

install_pacman() {
    pacman -S --noconfirm --needed docker docker-compose haproxy curl jq openssl iproute2
}

case "${OS_ID}" in
    ubuntu|debian|kali|raspbian) install_apt ;;
    fedora|rhel|centos|rocky)    install_dnf ;;
    arch|manjaro)                install_pacman ;;
    *) warn "Unknown distro — install manually: docker, haproxy, curl, jq, openssl" ;;
esac
ok "Dependencies installed"

# ── Kernel module: tun ────────────────────────────────────────────────────────
if ! lsmod 2>/dev/null | grep -q '^tun'; then
    modprobe tun 2>/dev/null || warn "modprobe tun failed (may already be built-in)"
fi
if [ ! -e /dev/net/tun ]; then
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200 2>/dev/null || true
    chmod 0666 /dev/net/tun
fi
[ -e /dev/net/tun ] && ok "/dev/net/tun ready" || fail "/dev/net/tun missing"

# ── Persistent tun module load ────────────────────────────────────────────────
echo "tun" > /etc/modules-load.d/1proxy2xvpn.conf 2>/dev/null || true

# ── Sysctl tuning ─────────────────────────────────────────────────────────────
cat > /etc/sysctl.d/99-1proxy2xvpn.conf << 'EOF'
# 1proxy2xvpn — kernel tuning for large container count
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=512
fs.file-max=2097152
net.ipv4.ip_forward=1
net.core.somaxconn=65535
net.ipv4.tcp_max_syn_backlog=65535
net.netfilter.nf_conntrack_max=1048576
EOF
sysctl -p /etc/sysctl.d/99-1proxy2xvpn.conf >/dev/null 2>&1 && ok "Kernel tuned for high scale" \
    || warn "Some sysctl parameters may not be available on this kernel"

# ── ulimits ───────────────────────────────────────────────────────────────────
if ! grep -q "1proxy2xvpn" /etc/security/limits.conf 2>/dev/null; then
    cat >> /etc/security/limits.conf << 'EOF'

# 1proxy2xvpn — per-process file descriptor limits
*           soft    nofile          65536
*           hard    nofile          1048576
EOF
    ok "ulimits configured"
fi

# ── Docker daemon ─────────────────────────────────────────────────────────────
systemctl enable --now docker 2>/dev/null || service docker start
if docker info >/dev/null 2>&1; then ok "Docker daemon active"; else fail "Docker not running"; fi

# ── Add invoking user to docker group ─────────────────────────────────────────
if [ -n "${SUDO_USER:-}" ]; then
    usermod -aG docker "${SUDO_USER}" 2>/dev/null && ok "User '${SUDO_USER}' added to docker group" \
        || warn "Could not add user to docker group"
fi

# ── HAProxy ───────────────────────────────────────────────────────────────────
if command -v haproxy >/dev/null 2>&1; then
    ok "HAProxy installed ($(haproxy -v 2>&1 | head -1 | awk '{print $3}'))"
else
    fail "HAProxy missing"
fi

# ── Generate credentials ──────────────────────────────────────────────────────
generate_haproxy_password

section "Setup complete"
log "Next steps:"
echo "  1. Place .ovpn files in: ${OVPN_DIR}/"
echo "  2. Build the image      : 1proxy2xvpn build"
echo "  3. Start containers     : 1proxy2xvpn up"
echo "  4. Generate HAProxy cfg : sudo 1proxy2xvpn haproxy"
echo "  5. Check status         : 1proxy2xvpn status"
echo
log "Stats dashboard:"
echo "  URL : http://localhost:${HAPROXY_STATS_PORT}"
echo "  User: ${HAPROXY_USER}"
echo "  Pass: (stored in ${CREDS_FILE})"
echo
log "Reboot or log out/in for docker group to take effect."
