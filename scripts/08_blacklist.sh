#!/bin/bash
# =============================================================================
# 08_blacklist.sh — Disable specific containers via HAProxy runtime API
# Use when an IP gets burned (banned by target) — removes from rotation
# without restarting anything.
#
# Usage:
#   1proxy2xvpn blacklist add <container-name|ip>
#   1proxy2xvpn blacklist remove <container-name|ip>
#   1proxy2xvpn blacklist list
#   1proxy2xvpn blacklist clear
# =============================================================================
set -e

PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
# shellcheck source=lib_common.sh
. "${PROJECT_ROOT}/scripts/lib_common.sh"

require_docker
ensure_config_dir

SOCKET="/run/haproxy/admin.sock"
BLACKLIST_FILE="${CONFIG_DIR}/blacklist"
touch "${BLACKLIST_FILE}"

[ ! -S "${SOCKET}" ] && die "HAProxy socket not found at ${SOCKET}. Is HAProxy running?"

ACTION="${1:-list}"
ARG="${2:-}"

# Send a runtime command to HAProxy
hp_cmd() {
    echo "$1" | sudo socat stdio "${SOCKET}" 2>/dev/null || \
    echo "$1" | sudo nc -U "${SOCKET}" 2>/dev/null
}

# Find container by IP or name
find_container() {
    local QUERY="$1"
    # First: exact name match
    if docker inspect "${QUERY}" >/dev/null 2>&1; then
        echo "${QUERY}"; return 0
    fi
    # Second: search by exit IP
    for NAME in $(list_containers); do
        PORT=$(container_port "${NAME}")
        IP=$(curl -sf --max-time 3 -x "http://localhost:${PORT}" https://api.ipify.org 2>/dev/null || true)
        [ "${IP}" = "${QUERY}" ] && echo "${NAME}" && return 0
    done
    return 1
}

case "${ACTION}" in
    add)
        [ -z "${ARG}" ] && die "Usage: 1proxy2xvpn blacklist add <container|ip>"
        NAME=$(find_container "${ARG}") || die "No container matches '${ARG}'"
        log "Disabling ${NAME} in HAProxy..."
        hp_cmd "disable server http_vpn_pool/${NAME}" >/dev/null
        hp_cmd "disable server socks_vpn_pool/${NAME}" >/dev/null 2>&1 || true
        grep -q "^${NAME}$" "${BLACKLIST_FILE}" || echo "${NAME}" >> "${BLACKLIST_FILE}"
        ok "${NAME} blacklisted (removed from rotation)"
        ;;
    remove)
        [ -z "${ARG}" ] && die "Usage: 1proxy2xvpn blacklist remove <container|ip>"
        NAME=$(find_container "${ARG}") || NAME="${ARG}"
        log "Re-enabling ${NAME} in HAProxy..."
        hp_cmd "enable server http_vpn_pool/${NAME}" >/dev/null
        hp_cmd "enable server socks_vpn_pool/${NAME}" >/dev/null 2>&1 || true
        sed -i "/^${NAME}$/d" "${BLACKLIST_FILE}"
        ok "${NAME} restored to rotation"
        ;;
    list)
        if [ -s "${BLACKLIST_FILE}" ]; then
            section "Blacklisted containers ($(wc -l < "${BLACKLIST_FILE}"))"
            cat "${BLACKLIST_FILE}"
        else
            log "Blacklist is empty"
        fi
        ;;
    clear)
        section "Clearing blacklist"
        while read -r NAME; do
            [ -n "${NAME}" ] && hp_cmd "enable server http_vpn_pool/${NAME}" >/dev/null 2>&1 || true
        done < "${BLACKLIST_FILE}"
        > "${BLACKLIST_FILE}"
        ok "All containers restored to rotation"
        ;;
    *)
        die "Unknown action '${ACTION}'. Use: add | remove | list | clear"
        ;;
esac
