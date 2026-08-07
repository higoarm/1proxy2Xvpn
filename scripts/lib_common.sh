#!/bin/bash
# =============================================================================
# lib_common.sh — Shared functions across all CLI subcommands
# Source via: . "$(dirname "$0")/lib_common.sh"
# =============================================================================
# This file defines shared variables (colors, paths) that are consumed by the
# scripts that source it, so shellcheck can't see their use from here.
# shellcheck disable=SC2034  # vars used by sourcing scripts

# Resolve project root regardless of where the CLI is invoked from
if [ -z "${PROJECT_ROOT:-}" ]; then
    PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
fi

# Resolve the config directory to the INVOKING user's home, not root's.
# When run under sudo, ${HOME} is /root — but credentials belong to the real
# user so they can read them without sudo. SUDO_USER holds the original user.
if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    _REAL_HOME="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
    CONFIG_DIR="${_REAL_HOME:-${HOME}}/.config/1proxy2xvpn"
else
    CONFIG_DIR="${HOME}/.config/1proxy2xvpn"
fi
STATE_FILE="${CONFIG_DIR}/state.json"
CREDS_FILE="${CONFIG_DIR}/credentials"
ENV_FILE="${PROJECT_ROOT}/.env"

IMAGE_NAME="${IMAGE_NAME:-1proxy2xvpn}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

# ── Load .env if present (allows override of defaults) ────────────────────────
# shellcheck source=/dev/null
[ -f "${ENV_FILE}" ] && set -a && . "${ENV_FILE}" && set +a

BASE_PORT="${BASE_PORT:-20000}"
HAPROXY_FRONTEND_PORT="${HAPROXY_FRONTEND_PORT:-9999}"
HAPROXY_SOCKS_PORT="${HAPROXY_SOCKS_PORT:-9998}"
HAPROXY_STATS_PORT="${HAPROXY_STATS_PORT:-9997}"
OVPN_DIR="${OVPN_DIR:-${PROJECT_ROOT}/ovpns}"
SECRETS_DIR="${SECRETS_DIR:-${PROJECT_ROOT}/secrets}"

# ── Colors and logging ────────────────────────────────────────────────────────
if [ -t 1 ]; then
    G=$'\033[0;32m'; Y=$'\033[1;33m'; R=$'\033[0;31m'
    B=$'\033[1;34m'; C=$'\033[0;36m'; M=$'\033[0;35m'
    N=$'\033[0m'; BOLD=$'\033[1m'
else
    G='' Y='' R='' B='' C='' M='' N='' BOLD=''
fi

log()     { echo "${G}[1proxy2xvpn]${N} $*"; }
info()    { echo "${C}[info]${N} $*"; }
warn()    { echo "${Y}[warn]${N} $*" >&2; }
error()   { echo "${R}[error]${N} $*" >&2; }
die()     { error "$*"; exit 1; }
section() { echo; echo "${B}━━━ $* ━━━${N}"; }
ok()      { echo "  ${G}✓${N} $*"; }
fail()    { echo "  ${R}✗${N} $*"; }

# ── Pre-flight checks ─────────────────────────────────────────────────────────
require_docker() {
    command -v docker >/dev/null 2>&1 || die "Docker not installed. Run: sudo ./1proxy2xvpn setup"
    docker info >/dev/null 2>&1 || die "Docker daemon not running. Start it and try again."
}

require_haproxy() {
    command -v haproxy >/dev/null 2>&1 || die "HAProxy not installed. Run: sudo ./1proxy2xvpn setup"
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "This subcommand requires root. Run with sudo."
}

require_image() {
    docker image inspect "${IMAGE}" >/dev/null 2>&1 || \
        die "Image '${IMAGE}' not found. Run: ./1proxy2xvpn build"
}

# ── Container helpers ─────────────────────────────────────────────────────────
list_containers() {
    docker ps --filter "ancestor=${IMAGE}" --format "{{.Names}}"
}

list_containers_all() {
    docker ps -a --filter "ancestor=${IMAGE}" --format "{{.Names}}"
}

container_port() {
    docker inspect \
        --format='{{range $p,$b:=.NetworkSettings.Ports}}{{if eq $p "3128/tcp"}}{{(index $b 0).HostPort}}{{end}}{{end}}' \
        "$1" 2>/dev/null
}

container_socks_port() {
    docker inspect \
        --format='{{range $p,$b:=.NetworkSettings.Ports}}{{if eq $p "1080/tcp"}}{{(index $b 0).HostPort}}{{end}}{{end}}' \
        "$1" 2>/dev/null
}

container_state() {
    docker inspect --format='{{.State.Status}}' "$1" 2>/dev/null || echo "missing"
}

container_health() {
    docker inspect --format='{{.State.Health.Status}}' "$1" 2>/dev/null || echo "none"
}

# ── Config dir ────────────────────────────────────────────────────────────────
ensure_config_dir() {
    mkdir -p "${CONFIG_DIR}" 2>/dev/null
    chmod 0700 "${CONFIG_DIR}" 2>/dev/null || true
    # When created under sudo, hand ownership back to the real user so they can
    # read their own credentials without root.
    if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
        chown -R "${SUDO_USER}":"$(id -gn "${SUDO_USER}" 2>/dev/null || echo "${SUDO_USER}")" \
            "${CONFIG_DIR}" 2>/dev/null || true
    fi
}

# ── Credential generation ─────────────────────────────────────────────────────
generate_haproxy_password() {
    ensure_config_dir
    if [ ! -f "${CREDS_FILE}" ]; then
        local PASS
        PASS=$(openssl rand -base64 18 2>/dev/null | tr -d '/=+' | head -c 18) || \
        PASS=$(head -c 24 /dev/urandom | base64 | tr -d '/=+' | head -c 18)
        cat > "${CREDS_FILE}" << EOF
HAPROXY_USER=admin
HAPROXY_PASSWORD=${PASS}
EOF
        chmod 0600 "${CREDS_FILE}"
        # Match ownership to the real user (see ensure_config_dir).
        if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
            chown "${SUDO_USER}":"$(id -gn "${SUDO_USER}" 2>/dev/null || echo "${SUDO_USER}")" \
                "${CREDS_FILE}" 2>/dev/null || true
        fi
        log "Generated HAProxy credentials → ${CREDS_FILE}"
    fi
    # shellcheck source=/dev/null
    . "${CREDS_FILE}"
}

# ── OVPN file listing ─────────────────────────────────────────────────────────
list_ovpn_files() {
    if [ -d "${OVPN_DIR}" ]; then
        find "${OVPN_DIR}" -maxdepth 1 -name "*.ovpn" -type f | sort
    fi
}

count_ovpn_files() {
    list_ovpn_files | wc -l
}

# Sanitize a filename for use as container name (Docker-compatible)
ovpn_to_container_name() {
    basename "$1" .ovpn | tr '.' '-' | tr ' ' '_' | tr -cd 'a-zA-Z0-9_-' | cut -c1-60
}

# ── Host IP detection (for leak prevention) ───────────────────────────────────
get_host_public_ip() {
    curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || \
    curl -sf --max-time 5 https://ifconfig.me 2>/dev/null || \
    echo ""
}

# ── Print banner ──────────────────────────────────────────────────────────────
print_banner() {
    cat << 'BANNER'
   ┌─────────────────────────────────────────────────┐
   │              1proxy2Xvpn                         │
   │  Distributed HTTP/SOCKS Proxy over OpenVPN      │
   │  Multi-location Proxy Infrastructure            │
   └─────────────────────────────────────────────────┘
BANNER
}
