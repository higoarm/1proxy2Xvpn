#!/bin/bash
# =============================================================================
# 10_uninstall.sh — Completely remove 1proxy2Xvpn from the host
#
# Removes everything the tool installs or creates:
#   - all proxy containers + the observability stack
#   - the Docker image, networks, and observability volumes
#   - system files (sysctl, modules-load, limits block, global symlink)
#   - systemd units
#   - config/credentials in ~/.config/1proxy2xvpn
#
# Preserves by default:
#   - your .ovpn files (in ovpns/)
#   - the project directory itself
#   - /etc/haproxy/haproxy.cfg is restored from the .bak backup if present
#
# Usage:
#   sudo ./1proxy2xvpn uninstall            # interactive, asks before removing
#   sudo ./1proxy2xvpn uninstall --yes      # non-interactive (assume yes)
#   sudo ./1proxy2xvpn uninstall --purge    # also delete ~/.config + project dir
# =============================================================================
set -e

PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
# shellcheck source=lib_common.sh
. "${PROJECT_ROOT}/scripts/lib_common.sh"

ASSUME_YES=false
PURGE=false
for arg in "$@"; do
    case "${arg}" in
        --yes|-y)  ASSUME_YES=true ;;
        --purge)   PURGE=true ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "Uninstall requires root: sudo ./1proxy2xvpn uninstall"

print_banner
section "Uninstall 1proxy2Xvpn"

# The user who invoked sudo (so we clean THEIR ~/.config, not root's).
TARGET_USER="${SUDO_USER:-${USER}}"
TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
CONFIG_DIR_USER="${TARGET_HOME}/.config/1proxy2xvpn"

echo "This will remove:"
echo "  • All proxy containers and the observability stack"
echo "  • The Docker image (1proxy2xvpn:latest) and observability volumes"
echo "  • System files: sysctl, modules-load, limits.conf block, global symlink"
echo "  • systemd units (1proxy2xvpn.service, 1proxy2xvpn-router.service)"
echo "  • Config and credentials: ${CONFIG_DIR_USER}"
echo
echo "Preserved: your .ovpn files and the project directory."
${PURGE} && echo "${Y}--purge: will ALSO delete ${CONFIG_DIR_USER} and the project directory.${N}"
echo

if ! ${ASSUME_YES}; then
    printf "Continue? [y/N] "
    read -r ANSWER
    case "${ANSWER}" in
        y|Y|yes|YES) ;;
        *) die "Aborted. Nothing was removed." ;;
    esac
fi

# ── 1. Stop and remove containers ─────────────────────────────────────────────
section "Removing containers"
MANAGED=$(docker ps -aq --filter "label=1proxy2xvpn.managed=true" 2>/dev/null || true)
if [ -n "${MANAGED}" ]; then
    docker rm -f ${MANAGED} >/dev/null 2>&1 && ok "Proxy containers removed" || warn "Some containers could not be removed"
else
    ok "No proxy containers found"
fi

# Observability stack (both lite and full)
if [ -d "${PROJECT_ROOT}/observability" ]; then
    cd "${PROJECT_ROOT}/observability"
    docker compose -f docker-compose.observability.yml down -v >/dev/null 2>&1 || true
    docker compose -f docker-compose.observability.full.yml down -v >/dev/null 2>&1 || true
    cd "${PROJECT_ROOT}"
fi
# Belt and suspenders: remove any leftover 1p2v-* containers
LEFTOVER=$(docker ps -aq --filter "name=1p2v-" 2>/dev/null || true)
[ -n "${LEFTOVER}" ] && docker rm -f ${LEFTOVER} >/dev/null 2>&1 || true
ok "Observability stack removed"

# ── 2. Remove image, network, volumes ─────────────────────────────────────────
section "Removing Docker image and volumes"
docker image rm 1proxy2xvpn:latest >/dev/null 2>&1 && ok "Image removed" || ok "Image not present"
docker network rm 1proxy2xvpn-observability >/dev/null 2>&1 || true
for vol in $(docker volume ls -q 2>/dev/null | grep -E "observability|prometheus-data|grafana-data|loki-data|alertmanager-data" || true); do
    docker volume rm "${vol}" >/dev/null 2>&1 || true
done
ok "Networks and volumes cleaned"

# ── 3. Remove system files ────────────────────────────────────────────────────
section "Removing system files"
rm -f /etc/sysctl.d/99-1proxy2xvpn.conf   && ok "sysctl config removed"        || true
rm -f /etc/modules-load.d/1proxy2xvpn.conf && ok "modules-load config removed" || true

# Remove the limits.conf block we appended (between our marker and the two lines)
if grep -q "1proxy2xvpn" /etc/security/limits.conf 2>/dev/null; then
    # Delete our comment line and the two nofile lines that follow our marker.
    sed -i '/# 1proxy2xvpn — per-process file descriptor limits/,+2d' /etc/security/limits.conf
    # Also drop any now-orphaned blank line left behind (best effort).
    ok "limits.conf entry removed"
fi

# Global symlink
if [ -L /usr/local/bin/1proxy2xvpn ]; then
    rm -f /usr/local/bin/1proxy2xvpn && ok "Global symlink removed"
fi

# ── 4. Restore HAProxy config ─────────────────────────────────────────────────
section "Restoring HAProxy"
if [ -f /etc/haproxy/haproxy.cfg.bak ]; then
    mv /etc/haproxy/haproxy.cfg.bak /etc/haproxy/haproxy.cfg && ok "Original haproxy.cfg restored from backup"
    systemctl reload haproxy 2>/dev/null || systemctl restart haproxy 2>/dev/null || true
else
    warn "No haproxy.cfg.bak backup found — leaving /etc/haproxy/haproxy.cfg as is"
    warn "If you don't use HAProxy for anything else, you may: sudo systemctl stop haproxy"
fi

# ── 5. Remove systemd units ───────────────────────────────────────────────────
section "Removing systemd units"
REMOVED_UNIT=false
for unit in 1proxy2xvpn.service 1proxy2xvpn-router.service; do
    if [ -f "/etc/systemd/system/${unit}" ]; then
        systemctl disable --now "${unit}" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/${unit}"
        REMOVED_UNIT=true
    fi
done
${REMOVED_UNIT} && { systemctl daemon-reload 2>/dev/null || true; ok "systemd units removed"; } || ok "No systemd units installed"

# ── 6. Remove config / credentials ────────────────────────────────────────────
section "Removing config and credentials"
if [ -d "${CONFIG_DIR_USER}" ]; then
    rm -rf "${CONFIG_DIR_USER}" && ok "Removed ${CONFIG_DIR_USER}"
else
    ok "No config directory found"
fi

# ── 7. Purge (optional) ───────────────────────────────────────────────────────
if ${PURGE}; then
    section "Purging project directory"
    warn "Deleting the project directory: ${PROJECT_ROOT}"
    warn "This includes your ovpns/ folder. Make sure you have backups."
    if ! ${ASSUME_YES}; then
        printf "Type the word DELETE to confirm: "
        read -r CONFIRM
        [ "${CONFIRM}" = "DELETE" ] || { warn "Purge skipped (project directory kept)."; PURGE=false; }
    fi
    if ${PURGE}; then
        # Can't rm the dir we're running from cleanly; schedule after exit.
        TObeRemoved="${PROJECT_ROOT}"
        cd /tmp
        rm -rf "${TObeRemoved}" && ok "Project directory deleted"
    fi
fi

section "Uninstall complete"
log "1proxy2Xvpn has been removed from this host."
${PURGE} || log "Your project directory and .ovpn files were preserved."
echo
log "Not removed automatically (shared system packages — remove manually if unused):"
echo "  • Docker           : sudo apt-get remove docker.io"
echo "  • HAProxy          : sudo apt-get remove haproxy"
echo "  • Kernel tuning is reverted on next reboot (sysctl file already removed)."
