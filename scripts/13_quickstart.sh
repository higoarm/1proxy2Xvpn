#!/bin/bash
# =============================================================================
# 13_quickstart.sh — One-command onboarding: setup → build → up --wait → haproxy
#
# A convenience wrapper around the individual commands (which still exist and
# are the source of truth). It is idempotent and STOPS at the first real error
# rather than hiding failures — if a step fails, you see exactly which one.
#
# Prereq: put your .ovpn files (and their credentials, e.g. ovpns/authvpn.txt)
# in ovpns/ before running this.
#
# Usage:
#   sudo ./1proxy2xvpn quickstart              # full flow, then run a rotation test
#   sudo ./1proxy2xvpn quickstart --no-test    # skip the final curl test
# =============================================================================
set -Eeo pipefail

PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
# shellcheck source=lib_common.sh
. "${PROJECT_ROOT}/scripts/lib_common.sh"

require_root  # setup needs root; the docker steps are run as the invoking user below

CLI="${PROJECT_ROOT}/1proxy2xvpn"
RUN_TEST=true
for arg in "$@"; do
    [ "${arg}" = "--no-test" ] && RUN_TEST=false
done

print_banner
section "Quickstart"
log "This runs setup → build → up (waits for tunnels) → haproxy, then tests rotation."
echo

# Helper: run a CLI subcommand as the invoking user (not root) when needed, so
# Docker group membership and file ownership behave correctly. Falls back to a
# direct call when there's no SUDO_USER (already the right user).
run_as_user() {
    if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
        sudo -u "${SUDO_USER}" -H bash "${CLI}" "$@"
    else
        bash "${CLI}" "$@"
    fi
}

# ── Step 1: setup (idempotent — safe to re-run; installs only what's missing) ─
section "Step 1/4 — setup"
bash "${CLI}" setup

# ── Preflight: are there .ovpn files to work with? ────────────────────────────
shopt -s nullglob
OVPNS=( "${OVPN_DIR}"/*.ovpn )
shopt -u nullglob
if [ ${#OVPNS[@]} -eq 0 ]; then
    echo
    die "No .ovpn files in ${OVPN_DIR}/. Add your configs (and credentials, e.g. ovpns/authvpn.txt) there, then re-run quickstart."
fi
ok "Found ${#OVPNS[@]} .ovpn file(s) in ${OVPN_DIR}/"

# ── Step 2: build the image (run as the invoking user for docker) ─────────────
section "Step 2/4 — build"
run_as_user build

# ── Step 3: start containers and wait for tunnels to be healthy ───────────────
section "Step 3/4 — up (waiting for tunnels)"
run_as_user up --wait

# ── Step 4: generate and apply HAProxy (needs root for /etc/haproxy) ──────────
section "Step 4/4 — haproxy"
bash "${CLI}" haproxy --only-up

# ── Optional rotation test ────────────────────────────────────────────────────
if [ "${RUN_TEST}" = "true" ]; then
    section "Rotation test"
    log "10 requests — each should show a different exit IP:"
    for _ in $(seq 1 10); do
        curl -s -x "http://localhost:${HAPROXY_FRONTEND_PORT}" https://api.ipify.org 2>/dev/null || true
        echo
    done
fi

section "Quickstart complete"
log "HTTP proxy : http://localhost:${HAPROXY_FRONTEND_PORT}"
log "Status     : ./1proxy2xvpn status"
