#!/bin/bash
# =============================================================================
# healthcheck.sh — Lightweight local health check (no external round-trip)
#
# Verifies the VPN tunnel is up and the proxy is serving, WITHOUT making an
# external request on every check. At scale (hundreds of containers) an external
# request per check would duplicate the HAProxy semantic check and waste exactly
# the tunnel capacity we want to preserve. We use cheap LOCAL checks only:
#
#   1. tun0 exists and has an IPv4 address   (kernel check, ~0 cost)
#   2. the tinyproxy process is alive        (pgrep, no I/O)
#   3. tinyproxy's port accepts a local TCP connection (no VPN round-trip)
#   4. if SOCKS5 is enabled, dante is alive too
#
# The kill switch guarantees that if tun0 is up and the proxy serves, traffic
# can only egress through the VPN. The "is my public IP != host IP" leak test
# runs ONCE at boot (entrypoint.sh), not here. The HAProxy semantic check
# (through-tunnel 204) is what decides rotation — this check just keeps Docker's
# restart policy honest without adding tunnel traffic.
# =============================================================================
set -e

# 1. tun0 must exist and have an address (cheap kernel check).
if ! ip -4 addr show tun0 2>/dev/null | grep -q 'inet '; then
    echo "[health] tun0 missing or no IP" >&2
    exit 1
fi

# 2. tinyproxy process must be alive.
if ! pgrep -x tinyproxy >/dev/null 2>&1; then
    echo "[health] tinyproxy process not running" >&2
    exit 1
fi

# 3. tinyproxy port must accept a local TCP connection (no external request —
#    this does NOT egress through the VPN).
if ! timeout 2 bash -c 'echo > /dev/tcp/127.0.0.1/3128' 2>/dev/null; then
    echo "[health] tinyproxy not accepting connections on :3128" >&2
    exit 1
fi

# 4. If SOCKS5 is enabled, dante must be alive and listening too.
if [ "${ENABLE_SOCKS5:-false}" = "true" ]; then
    if ! pgrep -x danted >/dev/null 2>&1 && ! pgrep -x sockd >/dev/null 2>&1; then
        echo "[health] SOCKS5 enabled but dante process not running" >&2
        exit 1
    fi
    if ! timeout 2 bash -c 'echo > /dev/tcp/127.0.0.1/1080' 2>/dev/null; then
        echo "[health] dante not accepting connections on :1080" >&2
        exit 1
    fi
fi

exit 0
