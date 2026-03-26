#!/bin/bash
# =============================================================================
# 4-status_proxies.sh — Check status and VPN IP of all running containers
#
# Usage:
#   ./4-status_proxies.sh           # default: 8s timeout, 10 parallel
#   ./4-status_proxies.sh 15        # 15s timeout (slow VPNs)
#   ./4-status_proxies.sh 8 20      # 8s timeout, 20 parallel workers
# =============================================================================

IMAGE="1proxy2xvpn"
TIMEOUT="${1:-8}"
PARALLEL="${2:-10}"

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; B='\033[1;34m'; C='\033[0;36m'; N='\033[0m'

TOTAL=$(docker ps -q --filter "ancestor=${IMAGE}" | wc -l)
if [ "${TOTAL}" -eq 0 ]; then
    echo -e "${R}No running containers found for image '${IMAGE}'.${N}"
    echo -e "Run: ${C}./2-start_containers.sh${N}"
    exit 1
fi

echo -e "${B}Checking ${TOTAL} containers (timeout=${TIMEOUT}s, parallel=${PARALLEL})...${N}"
echo ""

TMPDIR_RES=$(mktemp -d)
OUTFILE="${TMPDIR_RES}/results.txt"
touch "${OUTFILE}"

check_container() {
    local NAME="$1"
    local TIMEOUT="$2"
    local OUTFILE="$3"

    PORT=$(docker inspect \
        --format='{{range $p,$b:=.NetworkSettings.Ports}}{{if eq $p "3128/tcp"}}{{(index $b 0).HostPort}}{{end}}{{end}}' \
        "${NAME}" 2>/dev/null)

    STATE=$(docker inspect --format='{{.State.Status}}' "${NAME}" 2>/dev/null)

    if [ "${STATE}" != "running" ]; then
        echo "${NAME}|${PORT:-?}|DOWN|-" >> "${OUTFILE}"; return
    fi
    if [ -z "${PORT}" ]; then
        echo "${NAME}|?|NO-PORT|-" >> "${OUTFILE}"; return
    fi

    VPN_IP=$(curl -sf --max-time "${TIMEOUT}" -x "http://localhost:${PORT}" "https://ifconfig.me" 2>/dev/null)

    if echo "${VPN_IP}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        echo "${NAME}|${PORT}|UP|${VPN_IP}" >> "${OUTFILE}"
    else
        VPN_IP2=$(curl -sf --max-time "${TIMEOUT}" -x "http://localhost:${PORT}" "https://api.ipify.org" 2>/dev/null)
        if echo "${VPN_IP2}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            echo "${NAME}|${PORT}|UP|${VPN_IP2}" >> "${OUTFILE}"
        else
            echo "${NAME}|${PORT}|CONNECTING|-" >> "${OUTFILE}"
        fi
    fi
}

export -f check_container

JOBS=0
for NAME in $(docker ps -q --filter "ancestor=${IMAGE}" --format "{{.Names}}"); do
    check_container "${NAME}" "${TIMEOUT}" "${OUTFILE}" &
    JOBS=$((JOBS+1))
    [ $((JOBS % PARALLEL)) -eq 0 ] && wait
done
wait

printf "${B}%-40s %-8s %-14s %-20s${N}\n" "CONTAINER" "PORT" "STATUS" "VPN IP"
printf "%s\n" "─────────────────────────────────────────────────────────────────────────────"

sort -t'|' -k2 -n "${OUTFILE}" | while IFS='|' read -r NAME PORT STATUS IP; do
    case "${STATUS}" in
        UP)         printf "${G}%-40s %-8s %-14s %-20s${N}\n" "${NAME}" ":${PORT}" "✓ UP"         "${IP}" ;;
        CONNECTING) printf "${Y}%-40s %-8s %-14s %-20s${N}\n" "${NAME}" ":${PORT}" "⟳ CONNECTING" "waiting for VPN..." ;;
        DOWN)       printf "${R}%-40s %-8s %-14s %-20s${N}\n" "${NAME}" ":${PORT}" "✗ DOWN"       "-" ;;
        *)          printf "${C}%-40s %-8s %-14s %-20s${N}\n" "${NAME}" ":${PORT}" "${STATUS}"    "${IP}" ;;
    esac
done

UP_COUNT=$(grep -c '|UP|'         "${OUTFILE}" 2>/dev/null || echo 0)
CONN_COUNT=$(grep -c '|CONNECTING|' "${OUTFILE}" 2>/dev/null || echo 0)
DOWN_COUNT=$(grep -c '|DOWN|'      "${OUTFILE}" 2>/dev/null || echo 0)

echo ""
echo -e "${B}━━━ Summary ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
echo -e "  ${G}✓ UP          : ${UP_COUNT}${N}"
echo -e "  ${Y}⟳ CONNECTING  : ${CONN_COUNT}${N}"
echo -e "  ${R}✗ DOWN        : ${DOWN_COUNT}${N}"
echo -e "  ${B}  TOTAL        : ${TOTAL}${N}"
echo ""
echo -e "  Tip: 'CONNECTING' containers are still establishing the VPN tunnel."
echo -e "  Wait 30-60s and re-run: ${C}./4-status_proxies.sh${N}"
echo -e "  Increase timeout:       ${C}./4-status_proxies.sh 15${N}"

rm -rf "${TMPDIR_RES}"
