#!/bin/bash
# =============================================================================
# 11_install_cli.sh — Install (or remove) the global `1proxy2xvpn` command
#
# Creates a symlink in /usr/local/bin so you can call `1proxy2xvpn` from any
# directory instead of `./1proxy2xvpn`. Also diagnoses the common
# "sudo: 1proxy2xvpn: command not found" problem, which happens when sudo's
# secure_path does not include /usr/local/bin.
#
# Usage:
#   sudo ./1proxy2xvpn install-cli          # install the global command
#   sudo ./1proxy2xvpn install-cli --remove # remove it
# =============================================================================
set -e

PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
# shellcheck source=lib_common.sh
. "${PROJECT_ROOT}/scripts/lib_common.sh"

require_root

CLI_SOURCE="${PROJECT_ROOT}/1proxy2xvpn"
LINK_TARGET="/usr/local/bin/1proxy2xvpn"

if [ "${1:-}" = "--remove" ]; then
    if [ -L "${LINK_TARGET}" ]; then
        rm -f "${LINK_TARGET}" && ok "Removed ${LINK_TARGET}"
    else
        ok "No global command installed (nothing to remove)"
    fi
    exit 0
fi

section "Installing global command"

# 1. Make sure the source CLI is executable (a lost +x is a common cause of
#    "command not found" via a symlink).
chmod +x "${CLI_SOURCE}" 2>/dev/null || true
ok "Made ${CLI_SOURCE} executable"

# 2. Create the symlink with an absolute path.
ln -sf "${CLI_SOURCE}" "${LINK_TARGET}"
ok "Linked ${LINK_TARGET} → ${CLI_SOURCE}"

# 3. Verify it resolves for a normal shell.
if command -v 1proxy2xvpn >/dev/null 2>&1; then
    ok "'1proxy2xvpn' is on your PATH"
else
    warn "/usr/local/bin is not on your PATH — add it to use the command."
fi

# 4. The important check: does SUDO see it? sudo resets PATH to secure_path,
#    which on some systems excludes /usr/local/bin. If so, `sudo 1proxy2xvpn`
#    fails with "command not found" even though the symlink is correct.
SECURE_PATH=$(sudo -n bash -c 'echo $PATH' 2>/dev/null || echo "")
if echo "${SECURE_PATH}" | tr ':' '\n' | grep -qx "/usr/local/bin"; then
    ok "sudo can find the command (secure_path includes /usr/local/bin)"
    echo
    log "You can now run it from anywhere, e.g.:  sudo 1proxy2xvpn setup"
else
    warn "sudo's secure_path does NOT include /usr/local/bin."
    warn "This is why 'sudo 1proxy2xvpn setup' returns 'command not found'."
    echo
    log "Two ways to fix it — pick one:"
    echo
    echo "  A) Use the full path for sudo commands (no config change needed):"
    echo "       sudo ${LINK_TARGET} setup"
    echo
    echo "  B) Add /usr/local/bin to sudo's secure_path (permanent):"
    echo "       sudo visudo"
    echo "       # find the line starting with 'Defaults secure_path=' and"
    echo "       # append ':/usr/local/bin' to it, then save."
    echo
    log "Non-sudo commands (status, logs, etc.) work as '1proxy2xvpn ...' already."
fi
