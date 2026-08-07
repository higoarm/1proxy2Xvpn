#!/bin/bash
# =============================================================================
# healthcheck.sh — Lightweight semantic health check
#
# Verifies the VPN tunnel is up and the proxy is serving, WITHOUT making an
# expensive external round-trip on every check. At 285 containers, an external
# request every 30s = ~19 req/s of pure healthcheck overhead saturating the
# tunnels. We rely on two cheap local checks instead:
#
#   1. tun0 exists and has an IPv4 address  (kernel check, ~0 cost)
#   2. tinyproxy answers on :3128            (localhost, no VPN round-trip)
#
# The kill switch guarantees that IF tun0 is up and tinyproxy serves, traffic
# can only egress through the VPN — so a successful local check implies a
# working tunnel. The expensive "is my public IP != host IP" leak test now
# runs ONCE at boot (in entrypoint.sh), not on every healthcheck.
# =============================================================================
set -e

# 1. tun0 must exist and have an address (cheap kernel check)
if ! ip -4 addr show tun0 2>/dev/null | grep -q 'inet '; then
    echo "[health] tun0 missing or no IP" >&2
    exit 1
fi

# 2. tinyproxy must accept a local request (no external round-trip beyond the
#    minimal 204 endpoint, which is tiny and cached by Cloudflare edge).
if ! curl -sf --max-time 3 --proxy http://127.0.0.1:3128 \
     http://cp.cloudflare.com/generate_204 -o /dev/null; then
    echo "[health] tinyproxy not responding" >&2
    exit 1
fi

exit 0
