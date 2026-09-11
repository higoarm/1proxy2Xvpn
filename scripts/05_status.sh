#!/bin/bash
# =============================================================================
# 05_status.sh — Detailed status of all containers (parallel checks)
# =============================================================================
set -e

PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
# shellcheck source=lib_common.sh
. "${PROJECT_ROOT}/scripts/lib_common.sh"

require_docker

TIMEOUT="${TIMEOUT:-8}"
PARALLEL="${PARALLEL:-15}"
FORMAT="${FORMAT:-table}"   # table | json | csv

# Parse simple flags
while [ $# -gt 0 ]; do
    case "$1" in
        -t|--timeout)  TIMEOUT="$2"; shift 2 ;;
        -p|--parallel) PARALLEL="$2"; shift 2 ;;
        --json)        FORMAT="json"; shift ;;
        --csv)         FORMAT="csv"; shift ;;
        *)             shift ;;
    esac
done

mapfile -t CONTAINERS < <(list_containers)
TOTAL=${#CONTAINERS[@]}
[ "${TOTAL}" -eq 0 ] && die "No running containers"

[ "${FORMAT}" = "table" ] && {
    print_banner
    log "Checking ${TOTAL} containers (timeout=${TIMEOUT}s, parallel=${PARALLEL})..."
    echo
}

TMPDIR=$(mktemp -d)
OUTFILE="${TMPDIR}/results.txt"
touch "${OUTFILE}"
trap 'rm -rf "${TMPDIR}"' EXIT

check_one() {
    local NAME="$1"
    local PORT STATE HEALTH IP LATENCY
    PORT=$(container_port "${NAME}")
    STATE=$(container_state "${NAME}")
    HEALTH=$(container_health "${NAME}")

    if [ "${STATE}" != "running" ]; then
        echo "${NAME}|${PORT:-?}|${STATE}|${HEALTH}|-|-" >> "${OUTFILE}"
        return
    fi

    # Measure latency to a known endpoint via the proxy
    LATENCY=$(curl -o /dev/null -sf --max-time "${TIMEOUT}" \
        -x "http://localhost:${PORT}" \
        -w '%{time_total}' \
        "https://api.ipify.org" 2>/dev/null || echo "")

    IP=$(curl -sf --max-time "${TIMEOUT}" -x "http://localhost:${PORT}" \
        "https://api.ipify.org" 2>/dev/null || true)

    if [[ "${IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "${NAME}|${PORT}|UP|${HEALTH}|${IP}|${LATENCY}" >> "${OUTFILE}"
    else
        echo "${NAME}|${PORT}|CONNECTING|${HEALTH}|-|-" >> "${OUTFILE}"
    fi
}

export -f check_one container_port container_state container_health
export OUTFILE TIMEOUT

JOBS=0
for NAME in "${CONTAINERS[@]}"; do
    check_one "${NAME}" &
    JOBS=$((JOBS + 1))
    [ $((JOBS % PARALLEL)) -eq 0 ] && wait
done
wait

# ── Output formatting ─────────────────────────────────────────────────────────
case "${FORMAT}" in
    json)
        echo "["
        FIRST=true
        while IFS='|' read -r NAME PORT STATUS HEALTH IP LATENCY; do
            [ "${FIRST}" = false ] && echo ","
            FIRST=false
            printf '  {"name":"%s","port":%s,"status":"%s","health":"%s","ip":"%s","latency":%s}' \
                "${NAME}" "${PORT:-0}" "${STATUS}" "${HEALTH}" "${IP}" "${LATENCY:-0}"
        done < <(sort -t'|' -k2 -n "${OUTFILE}")
        echo
        echo "]"
        ;;
    csv)
        echo "name,port,status,health,ip,latency_seconds"
        sort -t'|' -k2 -n "${OUTFILE}" | tr '|' ','
        ;;
    *)
        printf "${BOLD}%-42s %-7s %-12s %-10s %-18s %-8s${N}\n" \
            "CONTAINER" "PORT" "STATUS" "HEALTH" "EXIT IP" "LATENCY"
        printf "%s\n" "─────────────────────────────────────────────────────────────────────────────────────────────────"
        sort -t'|' -k2 -n "${OUTFILE}" | while IFS='|' read -r NAME PORT STATUS HEALTH IP LATENCY; do
            LATENCY_FMT=""
            [ -n "${LATENCY}" ] && [ "${LATENCY}" != "-" ] && \
                LATENCY_FMT="$(printf '%.2fs' "${LATENCY}")"
            case "${STATUS}" in
                UP)         COLOR="${G}"; SYMBOL="✓" ;;
                CONNECTING) COLOR="${Y}"; SYMBOL="⟳" ;;
                *)          COLOR="${R}"; SYMBOL="✗" ;;
            esac
            printf "${COLOR}%-42s :%-6s ${SYMBOL} %-10s %-10s %-18s %-8s${N}\n" \
                "${NAME}" "${PORT}" "${STATUS}" "${HEALTH}" "${IP}" "${LATENCY_FMT}"
        done
        echo
        # Robust counters: grep|wc always returns a clean single integer.
        # The previous `grep -c ... || echo 0` produced "0\n0" when grep
        # found nothing (exit 1 with output 0, then `|| echo 0` appended).
        UP_COUNT=$(grep -c '|UP|' "${OUTFILE}" 2>/dev/null | head -1)
        CONN_COUNT=$(grep -c '|CONNECTING|' "${OUTFILE}" 2>/dev/null | head -1)
        UP_COUNT=${UP_COUNT:-0}
        CONN_COUNT=${CONN_COUNT:-0}
        DOWN_COUNT=$((TOTAL - UP_COUNT - CONN_COUNT))
        echo "${B}━━━ Summary ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
        echo "  ${G}✓ UP         : ${UP_COUNT}${N}"
        echo "  ${Y}⟳ CONNECTING : ${CONN_COUNT}${N}"
        echo "  ${R}✗ DOWN       : ${DOWN_COUNT}${N}"
        echo "    TOTAL        : ${TOTAL}"
        ;;
esac
