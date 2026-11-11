#!/bin/bash
# =============================================================================
# 01_setup.sh — Host pre-flight: install dependencies, tune kernel, validate
# Idempotent: safe to run multiple times.
# =============================================================================
set -e

PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
# shellcheck source=lib_common.sh
. "${PROJECT_ROOT}/scripts/lib_common.sh"

[ "$(id -u)" -eq 0 ] || die "Setup requires root: sudo ./1proxy2xvpn setup"

print_banner
section "Host pre-flight"

# ── Detect OS ─────────────────────────────────────────────────────────────────
if [ -f /etc/os-release ]; then . /etc/os-release; OS_ID="${ID:-unknown}"; else OS_ID="unknown"; fi
log "Detected OS: ${OS_ID}"

# ── Install dependencies ──────────────────────────────────────────────────────
# Critical packages that MUST be present for the tool to work at all.
# HAProxy and Docker are non-negotiable; the rest are runtime helpers.
CRITICAL_CMDS="haproxy docker curl openssl ip"

install_apt() {
    log "Updating package lists..."
    if ! apt-get update -qq; then
        die "apt-get update failed. Check your internet connection and APT sources, then re-run: sudo ./1proxy2xvpn setup"
    fi

    # Install packages ONE BY ONE so a single failure (e.g. a docker.io
    # conflict) does not prevent the others — notably HAProxy — from installing.
    # docker-compose-plugin is handled separately as it may not exist on all
    # releases (older Debian/Kali ship the standalone docker-compose instead).
    local pkgs="haproxy curl jq openssl iproute2 ca-certificates docker.io"
    for pkg in ${pkgs}; do
        log "Installing ${pkg}..."
        if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkg}" >/dev/null 2>&1; then
            ok "${pkg}"
        else
            warn "Failed to install ${pkg} (will verify criticality below)"
        fi
    done

    # Compose: only try to install if it's not already working. On many hosts
    # `docker compose` (the plugin) already ships with docker.io or was installed
    # earlier, so we shouldn't warn about installing what already works.
    if docker compose version >/dev/null 2>&1; then
        ok "docker compose (plugin) already available"
    elif docker-compose version >/dev/null 2>&1; then
        ok "docker-compose (standalone) already available"
    else
        log "Installing docker compose..."
        if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1; then
            ok "docker-compose-plugin"
        elif DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-compose >/dev/null 2>&1; then
            ok "docker-compose (standalone)"
        else
            warn "No docker compose found — the observability stack needs it."
            warn "Install manually later with: sudo apt-get install docker-compose-plugin"
        fi
    fi
}

install_dnf() {
    for pkg in haproxy curl jq openssl iproute docker docker-compose; do
        log "Installing ${pkg}..."
        dnf install -y -q "${pkg}" >/dev/null 2>&1 && ok "${pkg}" || warn "Failed: ${pkg}"
    done
}

install_pacman() {
    for pkg in haproxy curl jq openssl iproute2 docker docker-compose; do
        log "Installing ${pkg}..."
        pacman -S --noconfirm --needed "${pkg}" >/dev/null 2>&1 && ok "${pkg}" || warn "Failed: ${pkg}"
    done
}

case "${OS_ID}" in
    ubuntu|debian|kali|raspbian) install_apt ;;
    fedora|rhel|centos|rocky)    install_dnf ;;
    arch|manjaro)                install_pacman ;;
    *) warn "Unknown distro '${OS_ID}' — install manually: haproxy, docker, curl, jq, openssl, iproute2" ;;
esac

# ── Verify critical dependencies — ABORT if any is missing ────────────────────
# This is the guardrail that prevents "Setup complete" from ever printing while
# a required tool (like HAProxy) is absent. Uses die(), which aborts.
section "Verifying critical dependencies"
MISSING=""
for cmd in ${CRITICAL_CMDS}; do
    if command -v "${cmd}" >/dev/null 2>&1; then
        ok "${cmd} present"
    else
        fail "${cmd} MISSING"
        MISSING="${MISSING} ${cmd}"
    fi
done

if [ -n "${MISSING}" ]; then
    error "Setup could NOT install:${MISSING}"
    error "The tool will not work without these. Common fixes:"
    error "  • No internet / APT mirror down → check connectivity and retry"
    error "  • Package conflict (e.g. docker-ce already installed) → install the"
    error "    missing package manually, e.g.: sudo apt-get install haproxy"
    error "  • Universe/extra repo disabled → enable it, run apt-get update, retry"
    die "Aborting setup. Fix the above and re-run: sudo ./1proxy2xvpn setup"
fi
ok "All critical dependencies verified"

# ── Kernel module: tun ────────────────────────────────────────────────────────
if ! lsmod 2>/dev/null | grep -q '^tun'; then
    modprobe tun 2>/dev/null || warn "modprobe tun failed (may already be built-in)"
fi
if [ ! -e /dev/net/tun ]; then
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200 2>/dev/null || true
    chmod 0666 /dev/net/tun
fi
[ -e /dev/net/tun ] && ok "/dev/net/tun ready" || die "/dev/net/tun could not be created. The tun kernel module may be unavailable on this host/kernel."

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
systemctl enable --now docker 2>/dev/null || service docker start 2>/dev/null || true
if docker info >/dev/null 2>&1; then
    ok "Docker daemon active"
else
    die "Docker is installed but the daemon isn't running. Start it with: sudo systemctl start docker — then re-run setup."
fi

# ── Add invoking user to docker group ─────────────────────────────────────────
if [ -n "${SUDO_USER:-}" ]; then
    usermod -aG docker "${SUDO_USER}" 2>/dev/null && ok "User '${SUDO_USER}' added to docker group" \
        || warn "Could not add user to docker group"
fi

# ── Report HAProxy version (presence already verified above) ──────────────────
ok "HAProxy ready ($(haproxy -v 2>&1 | head -1 | awk '{print $3}'))"

# ── Generate credentials ──────────────────────────────────────────────────────
generate_haproxy_password

section "Setup complete"
log "Next steps:"
echo "  1. Place .ovpn files in: ${OVPN_DIR}/"
echo "  2. Build the image      : ./1proxy2xvpn build"
echo "  3. Start containers     : ./1proxy2xvpn up"
echo "  4. Generate HAProxy cfg : sudo ./1proxy2xvpn haproxy --only-up"
echo "  5. Check status         : ./1proxy2xvpn status"
echo
log "Stats dashboard:"
echo "  URL : http://localhost:${HAPROXY_STATS_PORT}"
echo "  User: ${HAPROXY_USER}"
echo "  Pass: (stored in ${CREDS_FILE})"
echo
log "Reboot or log out/in for docker group to take effect."
