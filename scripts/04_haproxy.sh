#!/bin/bash
# =============================================================================
# 04_haproxy.sh — Generate haproxy.cfg from running containers
# Features:
#   - Semantic health checks (verifies VPN actually works)
#   - Random password from credentials file (no hardcoded ham123)
#   - Region grouping (us, eu, asia, sa, oceania) when filename has country code
#   - SOCKS5 frontend in addition to HTTP
#   - Stats bound only to 127.0.0.1 by default (override via --public-stats)
# =============================================================================
set -e

PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
# shellcheck source=lib_common.sh
. "${PROJECT_ROOT}/scripts/lib_common.sh"

require_root
require_docker
require_haproxy
generate_haproxy_password
print_banner

# Health-check interval for the semantic (through-tunnel) checks. Spaced out to
# limit overhead at scale — each check is one small proxied request per server.
# With hundreds of containers, raise this (e.g. HAPROXY_CHECK_INTER=30s).
CHECK_INTER="${HAPROXY_CHECK_INTER:-10s}"

# ── Flags ─────────────────────────────────────────────────────────────────────
DRY_RUN=false
ONLY_UP=false
PUBLIC_STATS=false
for ARG in "$@"; do
    case "${ARG}" in
        --dry-run)     DRY_RUN=true ;;
        --only-up)     ONLY_UP=true ;;
        --public-stats) PUBLIC_STATS=true ;;
    esac
done

HAPROXY_CFG="/etc/haproxy/haproxy.cfg"
OUTPUT_CFG="${PROJECT_ROOT}/haproxy.cfg"
STATS_BIND="127.0.0.1"
[ "${PUBLIC_STATS}" = "true" ] && STATS_BIND="0.0.0.0"

# ── Collect running containers ────────────────────────────────────────────────
section "Discovery"
mapfile -t CONTAINERS < <(list_containers)
TOTAL=${#CONTAINERS[@]}
[ "${TOTAL}" -eq 0 ] && die "No running containers. Run: ./1proxy2xvpn up"
log "Found ${TOTAL} containers"

# ── Optional: verify VPN actually works on each ───────────────────────────────
if [ "${ONLY_UP}" = true ]; then
    log "Mode --only-up: verifying VPN connectivity (this takes ~5s per container)..."
    VERIFIED=(); SKIPPED=0
    TOTAL_CHECK=${#CONTAINERS[@]}
    DONE_CHECK=0
    for NAME in "${CONTAINERS[@]}"; do
        PORT=$(container_port "${NAME}")
        IP=$(curl -sf --max-time 5 -x "http://localhost:${PORT}" "https://api.ipify.org" 2>/dev/null || true)
        if [[ "${IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            VERIFIED+=("${NAME}")
        else
            printf "\r\033[K"  # clear progress line before the warning
            warn "Skipping ${NAME} — VPN not responding"
            SKIPPED=$((SKIPPED + 1))
        fi
        DONE_CHECK=$((DONE_CHECK + 1))
        progress_bar "${DONE_CHECK}" "${TOTAL_CHECK}" "verifying VPN connectivity"
    done
    CONTAINERS=("${VERIFIED[@]}")
    log "Verified: ${#CONTAINERS[@]} | Skipped: ${SKIPPED}"
fi

# ── Resolve ports for all containers ──────────────────────────────────────────
declare -A HTTP_PORTS SOCKS_PORTS REGIONS
for NAME in "${CONTAINERS[@]}"; do
    HTTP=$(container_port "${NAME}")
    SOCKS=$(container_socks_port "${NAME}")
    if [ -n "${HTTP}" ]; then
        HTTP_PORTS["${NAME}"]="${HTTP}"
        [ -n "${SOCKS}" ] && SOCKS_PORTS["${NAME}"]="${SOCKS}"

        # Detect region from container name prefix (e.g. "us-newyork" → us)
        # Provider prefixes: my_expressvpn_us_..., nordvpn_us12345, etc.
        PREFIX=""
        case "${NAME}" in
            *_us[-_]*|us[-_]*|*-us|*-us-*)   PREFIX="us" ;;
            *_uk[-_]*|uk[-_]*|*-uk|*-uk-*|*-gb[-_]*|gb[-_]*)   PREFIX="uk" ;;
            *_de[-_]*|de[-_]*|*-de|*-de-*|*germany*)   PREFIX="eu" ;;
            *_fr[-_]*|fr[-_]*|*-fr|*-fr-*|*france*)   PREFIX="eu" ;;
            *_nl[-_]*|nl[-_]*|*-nl|*-nl-*|*netherlands*) PREFIX="eu" ;;
            *_jp[-_]*|jp[-_]*|*japan*)                PREFIX="asia" ;;
            *_sg[-_]*|sg[-_]*|*singapore*)            PREFIX="asia" ;;
            *_hk[-_]*|hk[-_]*|*hong*kong*)            PREFIX="asia" ;;
            *_kr[-_]*|kr[-_]*|*south*korea*)          PREFIX="asia" ;;
            *_br[-_]*|br[-_]*|*-br|*brazil*)          PREFIX="sa" ;;
            *_au[-_]*|au[-_]*|*australia*)            PREFIX="oceania" ;;
            *_ca[-_]*|ca[-_]*|*canada*)               PREFIX="us" ;;
            *)                                         PREFIX="other" ;;
        esac
        REGIONS["${NAME}"]="${PREFIX}"
    else
        warn "Port not found for ${NAME} — skipping"
    fi
done

# Group counts
declare -A REGION_COUNTS
for NAME in "${!REGIONS[@]}"; do
    R="${REGIONS[$NAME]}"
    REGION_COUNTS["${R}"]=$((${REGION_COUNTS["${R}"]:-0} + 1))
done

log "Region distribution:"
for R in "${!REGION_COUNTS[@]}"; do
    echo "  ${R}: ${REGION_COUNTS[$R]}"
done

# ── Generate config ───────────────────────────────────────────────────────────
section "Generating ${OUTPUT_CFG}"

# Hash password for HAProxy (use SHA-512 crypt for "stats auth")
# HAProxy actually accepts plain-text, but we use it for the runtime API auth.
{
cat << HEADER
# =============================================================================
# haproxy.cfg — Auto-generated by 1proxy2xvpn
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# Containers: ${#HTTP_PORTS[@]}
# =============================================================================

global
    log /dev/log local0
    log /dev/log local1 notice
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s
    user haproxy
    group haproxy
    daemon
    maxconn 100000
    nbthread 8
    tune.ssl.default-dh-param 2048

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    option  redispatch
    retries 3
    timeout connect  10s
    timeout client   5m
    timeout server   5m
    timeout check    5s
    timeout queue    30s

# ── HTTP Frontend ──────────────────────────────────────────────────────────────
frontend http_proxy_entrypoint
    bind *:${HAPROXY_FRONTEND_PORT}
    default_backend http_vpn_pool

# ── SOCKS5 Frontend ────────────────────────────────────────────────────────────
frontend socks_proxy_entrypoint
    bind *:${HAPROXY_SOCKS_PORT}
    default_backend socks_vpn_pool

# ── HTTP Backend (all containers, sequential round-robin rotation) ─────────────
# balance roundrobin: cycles through every server in order before repeating any.
# This guarantees maximum IP diversity — all N IPs are used once before the
# first one is reused, unlike "random" which could pick the same IP twice in
# a row. Rotation happens per NEW CONNECTION. Tools that reuse a keep-alive
# connection for many requests will keep the same IP for that connection's
# lifetime; disable keep-alive client-side for per-request rotation.
backend http_vpn_pool
    mode    tcp
    balance roundrobin
    option  redispatch
    # Semantic health check: send a real proxied request THROUGH tinyproxy and
    # expect a 204. This verifies the VPN tunnel actually works — a container
    # whose tinyproxy is up but whose tun0 is dead will fail this check and be
    # pulled from rotation (a plain TCP check would keep it in, sending traffic
    # into a dead tunnel). Interval is spaced out to limit tunnel overhead at
    # scale; tune with HAPROXY_CHECK_INTER (default 10s).
    option  httpchk
    http-check send meth GET uri http://cp.cloudflare.com/generate_204 ver HTTP/1.1 hdr Host cp.cloudflare.com hdr Connection close
    http-check expect status 204
HEADER

for NAME in "${!HTTP_PORTS[@]}"; do
    PORT="${HTTP_PORTS[$NAME]}"
    printf "    server %-50s 127.0.0.1:%-5s check inter %s rise 2 fall 3 weight 100\n" \
        "${NAME}" "${PORT}" "${CHECK_INTER}"
done

cat << FOOTER

# ── SOCKS5 Backend ─────────────────────────────────────────────────────────────
backend socks_vpn_pool
    mode    tcp
    balance roundrobin
    option  redispatch
FOOTER

for NAME in "${!SOCKS_PORTS[@]}"; do
    PORT="${SOCKS_PORTS[$NAME]}"
    printf "    server %-50s 127.0.0.1:%-5s check inter %s rise 2 fall 3 weight 100\n" \
        "${NAME}" "${PORT}" "${CHECK_INTER}"
done

# ── Regional backends (optional) ──────────────────────────────────────────────
for REGION in us uk eu asia sa oceania; do
    HAVE_ANY=false
    for NAME in "${!REGIONS[@]}"; do
        if [ "${REGIONS[$NAME]}" = "${REGION}" ]; then HAVE_ANY=true; break; fi
    done
    if [ "${HAVE_ANY}" = true ]; then
        echo
        echo "# ── Region: ${REGION} ──────────────────────────────────────────────"
        echo "backend http_vpn_pool_${REGION}"
        echo "    mode    tcp"
        echo "    balance roundrobin"
        echo "    option  redispatch"
        echo "    option  httpchk"
        echo "    http-check send meth GET uri http://cp.cloudflare.com/generate_204 ver HTTP/1.1 hdr Host cp.cloudflare.com hdr Connection close"
        echo "    http-check expect status 204"
        for NAME in "${!REGIONS[@]}"; do
            if [ "${REGIONS[$NAME]}" = "${REGION}" ] && [ -n "${HTTP_PORTS[$NAME]:-}" ]; then
                printf "    server %-50s 127.0.0.1:%-5s check inter %s rise 2 fall 3\n" \
                    "${NAME}" "${HTTP_PORTS[$NAME]}" "${CHECK_INTER}"
            fi
        done
    fi
done

cat << STATS

# ── Stats dashboard ────────────────────────────────────────────────────────────
listen stats
    bind ${STATS_BIND}:${HAPROXY_STATS_PORT}
    mode http
    stats enable
    stats uri /
    stats refresh 10s
    stats show-legends
    stats show-node
    stats auth ${HAPROXY_USER}:${HAPROXY_PASSWORD}
    stats admin if TRUE

# ── Prometheus metrics endpoint ────────────────────────────────────────────────
# Bind on all interfaces so the observability stack (Prometheus running inside
# a Docker container) can scrape via host.docker.internal:8404.
# Access is restricted to localhost + private RFC1918 ranges (Docker bridges),
# so this is NOT exposed to the public internet from this listener.
frontend prometheus_metrics
    bind *:8404
    mode http
    # Only allow scrapers from localhost or Docker bridge networks
    acl from_localhost  src 127.0.0.0/8
    acl from_docker     src 172.16.0.0/12 192.168.0.0/16 10.0.0.0/8
    http-request deny if !from_localhost !from_docker
    http-request use-service prometheus-exporter if { path /metrics }
    no log
STATS
} > "${OUTPUT_CFG}"

# ── Validate ──────────────────────────────────────────────────────────────────
log "Validating config..."
if ! haproxy -c -f "${OUTPUT_CFG}" >/dev/null 2>&1; then
    error "Generated config is INVALID:"
    haproxy -c -f "${OUTPUT_CFG}" 2>&1 | tail -20
    die "Aborting — see errors above"
fi
ok "Config valid ($(grep -c '^\s*server ' "${OUTPUT_CFG}") servers)"

# ── Dry run? ──────────────────────────────────────────────────────────────────
if [ "${DRY_RUN}" = true ]; then
    warn "Dry-run mode — not applied"
    echo; cat "${OUTPUT_CFG}"
    exit 0
fi

# ── Apply ─────────────────────────────────────────────────────────────────────
section "Applying"
[ -f "${HAPROXY_CFG}" ] && cp "${HAPROXY_CFG}" "${HAPROXY_CFG}.bak" && ok "Backup → ${HAPROXY_CFG}.bak"
cp "${OUTPUT_CFG}" "${HAPROXY_CFG}"
ok "Installed → ${HAPROXY_CFG}"

if systemctl reload haproxy 2>/dev/null; then
    ok "HAProxy reloaded (zero downtime)"
elif systemctl restart haproxy 2>/dev/null; then
    ok "HAProxy restarted"
else
    warn "Could not reload — try manually: sudo systemctl restart haproxy"
fi

section "Endpoints"
kv     "HTTP proxy"   "http://localhost:${HAPROXY_FRONTEND_PORT}"
kv     "SOCKS5 proxy" "socks5://localhost:${HAPROXY_SOCKS_PORT}"
kv     "Stats"        "http://${STATS_BIND}:${HAPROXY_STATS_PORT}"
kv_sub "User"         "${HAPROXY_USER}"
kv_sub "Pass"         "${HAPROXY_PASSWORD}"
kv     "Prometheus"   "http://127.0.0.1:8404/metrics"
echo
echo "Regional pools available:"
for R in us uk eu asia sa oceania; do
    [ -n "${REGION_COUNTS[$R]:-}" ] && echo "  ${R}: ${REGION_COUNTS[$R]} containers"
done
echo
log "Test — 10 requests should show rotating exit IPs:"
echo "  for i in {1..10}; do curl -s -x http://localhost:${HAPROXY_FRONTEND_PORT} https://api.ipify.org; echo; done"
